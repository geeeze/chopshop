"""Command line: run the service, and talk to one.

    python -m chopshop_flux serve                 # start the service
    python -m chopshop_flux health                # is it up, and what is loaded
    python -m chopshop_flux models                # the registry, licences included
    python -m chopshop_flux generate "a phoenix emblem" --style flat-poster
    python -m chopshop_flux edit source.png "flatten to 6 flat colours"
    python -m chopshop_flux gen2pipe "an owl crest" --out 00_source

Exit codes: 0 ok, 2 usage, 3 service unreachable, 4 model missing,
5 generation failed.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

from . import SERVICE_NAME, __version__
from .client import FluxClient, FluxError, run_pipeline
from .models import DEFAULT_MODEL_KEY, ModelError
from .styles import apply_style, style_sweep_json


def _print_json(payload) -> None:
    print(json.dumps(payload, indent=2, sort_keys=True))


def _cmd_serve(args) -> int:
    # Imported here rather than at module scope so every other subcommand works
    # on a machine that has no torch at all.
    from .server import serve
    serve(bind=args.bind, port=args.port, verbose=args.verbose)
    return 0


def _cmd_health(args) -> int:
    payload = FluxClient(args.url).health()
    _print_json(payload)
    return 0 if payload.get("ok") else 5


def _cmd_models(args) -> int:
    payload = FluxClient(args.url).models()
    for spec in payload.get("models", []):
        mark = "commercial OK" if spec["commercial_ok"] else "NON-COMMERCIAL"
        print("%-14s %-12s %6.1f GB VRAM  %s"
              % (spec["key"], spec["license"], spec["vram_gb"], mark))
        if spec.get("notes"):
            print("%-14s %s" % ("", spec["notes"]))
    return 0


def _generate_kwargs(args) -> dict:
    return {
        "model": args.model,
        "width": args.width,
        "height": args.height,
        "steps": args.steps,
        "guidance": args.guidance,
        "seed": args.seed,
        "images": args.images,
        "negative_prompt": args.negative_prompt,
        "strength": args.strength,
    }


def _emit(payload: dict, *, as_json: bool = False) -> int:
    """Report a generation response: raw JSON, or the numbers that matter."""
    for warning in payload.get("warnings") or []:
        print("warning: %s" % warning, file=sys.stderr)
    if as_json:
        _print_json(payload)
        return 0
    for entry in payload.get("images", []):
        print("%s  %dx%d  %d bytes  %.2fs"
              % (entry["name"], entry["width"], entry["height"],
                 entry["bytes"], entry["seconds"]))
    print("seed %s, %s steps, guidance %s, %.2fs total, load %s"
          % (payload.get("seed"), payload.get("steps"), payload.get("guidance"),
             payload.get("total_seconds") or 0.0,
             payload.get("load_seconds")))
    return 0


def _download(client: FluxClient, payload: dict, out_dir: str | None) -> None:
    """Fetch every image to disk, printing each path as it lands."""
    if not out_dir:
        return
    for entry in payload.get("images", []):
        print(client.download(entry["name"], out_dir))


def _styled_prompt(prompt: str, args) -> str:
    """Append a named style's prompt suffix, if one was asked for.

    A style is a prompt suffix plus a trace preset. The suffix belongs on the
    prompt for every generation; the preset only matters for the gen2pipe
    hand-off, where it becomes a single-preset sweep. This returns the prompt
    with the suffix applied, so generate/edit/gen2pipe share one code path.
    """
    if not getattr(args, "style", None):
        return prompt
    suffix, _preset = apply_style(args.style, getattr(args, "styles", None))
    return (prompt + suffix) if prompt else suffix.strip(", ")


def _cmd_generate(args) -> int:
    client = FluxClient(args.url)
    if args.prompt:
        prompt = args.prompt
    else:
        prompt = sys.stdin.read().strip()
    if not prompt:
        print("flux: a prompt is required", file=sys.stderr)
        return 2
    prompt = _styled_prompt(prompt, args)
    payload = client.generate(prompt, **_generate_kwargs(args))
    _download(client, payload, args.out)
    return _emit(payload, as_json=args.json)


def _cmd_edit(args) -> int:
    client = FluxClient(args.url)
    payload = client.edit(args.source, _styled_prompt(args.prompt, args),
                          **_generate_kwargs(args))
    _download(client, payload, args.out)
    return _emit(payload, as_json=args.json)


def _cmd_gen2pipe(args) -> int:
    """Generate a raster and hand it to chopshop-svg's front half.

    The forward trace of one image is the entire reason this service exists: a
    generated raster is a *source*, and the pipeline turns sources into
    candidates. This command is the seam, and the seam only runs one way — the
    pipeline never calls back into the service.
    """
    client = FluxClient(args.url)
    prompt = _styled_prompt(args.prompt, args)
    payload = client.generate(prompt, **_generate_kwargs(args))
    for warning in payload.get("warnings") or []:
        print("warning: %s" % warning, file=sys.stderr)
    images = payload.get("images") or []
    if not images:
        print("flux: generation returned no images", file=sys.stderr)
        return 5
    raster = client.download(images[0]["name"], args.out)
    print("flux: generated source %s (seed %s)" % (raster, payload.get("seed")))

    # A style also names a trace preset. When the caller asked for a style and
    # did not pass their own --sweep, write the single-preset sweep the style
    # wants and hand that to the front half — so "flat-poster" controls both
    # the prompt and the trace, exactly as the sibling bridge did.
    sweep = args.sweep
    if sweep is None and getattr(args, "style", None):
        _suffix, preset = apply_style(args.style, getattr(args, "styles", None))
        sweep = style_sweep_json(preset,
                                 os.path.join(args.out, "style_sweep.json"))

    code = run_pipeline(raster, sweep=sweep, skip_prep=args.skip_prep)
    if code not in (0, 1):
        print("flux: front_pipeline.sh exited %d" % code, file=sys.stderr)
        return 2
    return code


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m chopshop_flux",
        description="%s — a generation service for diffusers image models."
                    % SERVICE_NAME)
    parser.add_argument("--version", action="version",
                        version="%s %s" % (SERVICE_NAME, __version__))
    sub = parser.add_subparsers(dest="command", required=True)

    def add_generation_args(p):
        p.add_argument("--model", default=None,
                       help="model key (default: %s)" % DEFAULT_MODEL_KEY)
        p.add_argument("--width", type=int, default=1024)
        p.add_argument("--height", type=int, default=1024)
        p.add_argument("--steps", type=int, default=None,
                       help="inference steps (default: the model's own)")
        p.add_argument("--guidance", type=float, default=None,
                       help="guidance scale (default: the model's own)")
        p.add_argument("--seed", type=int, default=None,
                       help="seed (default: random, always reported back)")
        p.add_argument("--images", type=int, default=1)
        p.add_argument("--negative", dest="negative_prompt", default=None,
                       help="negative prompt (models that accept one; ignored "
                            "with a warning elsewhere)")
        p.add_argument("--strength", type=float, default=None,
                       help="img2img strength for SD-style models (0..1)")
        p.add_argument("--style", default=None,
                       help="named style recipe (prompt suffix + trace preset)")
        p.add_argument("--styles", default=None,
                       help="styles JSON (default: the bundled set)")
        p.add_argument("--url", default=None, help="service base URL")
        p.add_argument("--out", default=None, help="where to write the PNG(s)")
        p.add_argument("--json", action="store_true",
                       help="print the raw response instead of a summary")

    s = sub.add_parser("serve", help="run the HTTP service")
    s.add_argument("--bind", default=None)
    s.add_argument("--port", type=int, default=None)
    s.add_argument("--verbose", action="store_true", help="log every request")
    s.set_defaults(func=_cmd_serve)

    h = sub.add_parser("health", help="is the service up, and what is loaded")
    h.add_argument("--url", default=None)
    h.set_defaults(func=_cmd_health)

    m = sub.add_parser("models", help="list models, with licences")
    m.add_argument("--url", default=None)
    m.set_defaults(func=_cmd_models)

    g = sub.add_parser("generate", help="text -> image(s)")
    g.add_argument("prompt", nargs="?", default=None,
                   help="prompt (reads stdin when omitted)")
    add_generation_args(g)
    g.set_defaults(func=_cmd_generate)

    e = sub.add_parser("edit", help="image + text -> image(s)")
    e.add_argument("source", help="reference raster")
    e.add_argument("prompt")
    add_generation_args(e)
    e.set_defaults(func=_cmd_edit)

    p = sub.add_parser("gen2pipe",
                       help="text -> image -> front_pipeline.sh (prep->sweep->compare)")
    p.add_argument("prompt")
    p.add_argument("--sweep", default=None,
                   help="sweep config passed to front_pipeline.sh")
    p.add_argument("--skip-prep", action="store_true")
    add_generation_args(p)
    p.set_defaults(func=_cmd_gen2pipe)
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except FluxError as exc:
        print("%s: %s" % (SERVICE_NAME, exc), file=sys.stderr)
        return exc.exit_code
    except ModelError as exc:
        # A bad model name, bad size, or unknown style: the caller's mistake.
        print("%s: %s" % (SERVICE_NAME, exc), file=sys.stderr)
        return exc.exit_code
    except ValueError as exc:  # bad environment configuration
        print("%s: %s" % (SERVICE_NAME, exc), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130
    except Exception as exc:  # noqa: BLE001 - unexpected, surface honestly
        print("%s: unexpected error: %s: %s"
              % (SERVICE_NAME, type(exc).__name__, exc), file=sys.stderr)
        return 5


if __name__ == "__main__":
    sys.exit(main())
