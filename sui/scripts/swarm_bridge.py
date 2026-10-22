#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
swarm_bridge.py -- bridge the print pipeline to a running SwarmUI instance.

SwarmUI (https://github.com/mcmonkeyprojects/SwarmUI) is a separate C# server
with a ComfyUI backend and an HTTP API.  This bridge speaks that API so the
front half of the print pipeline can use SwarmUI as a *source* of raster images
as well as a *filter* on existing ones.  It never modifies SwarmUI, never picks
a trace winner, and never judges the art: it requests generations and hands the
resulting PNGs to the existing scripts.

Three modes (subcommands):

  generate   text -> image(s), saved to disk.  Raw generation, no tracing.
             Use it to eyeball outputs before committing to a trace.

  filter     source image + text -> img2img variant(s).  "A filter on existing
             sources": the source raster is passed as ``initimage`` and the
             text + creativity steer how far it is restyled.

  gen2pipe   text -> image -> front_pipeline.sh (prep -> sweep -> compare).
             The early-stage flow (generate a source example) and the
             end-of-line flow (the generated image is itself the artwork).

The bridge is a thin HTTP client plus a small template layer.  ``--style NAME``
selects a named recipe that (a) appends prompt terms and (b) favours a trace
sweep preset, so "flat poster" / "photo halftone" etc. become reusable,
categorised knobs instead of one-off flags.  Styles live in a JSON file
(default: ``swarm_styles.json`` next to this script) so new ones are added
without touching code.

Wire format (verified against SwarmUI 0.9.8.3, HOST-SPECIFIC install — see
~/SwarmUI/docs/API.md there):

  POST /API/GetNewSession        body {}  -> {"session_id": ...}
  POST /API/GenerateText2Image   flat body {session_id, images, prompt, model,
                                 width, height, initimage, initimagecreativity,
                                 ...} -> {"images": ["View/.../x.png"]}

Local source images are passed to ``initimage`` as a base64 ``data:`` URL
(SwarmUI's documented image format).  Generated images are downloaded from the
``View/...`` path and written to a local directory.

Exit codes: 0 = success, 2 = bad usage, 3 = SwarmUI unreachable,
4 = no models available, 5 = generation failed.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)
import front_common as fc  # noqa: E402

DEFAULT_BASE_URL = "http://127.0.0.1:7801"
DEFAULT_STYLES = os.path.join(SCRIPT_DIR, "swarm_styles.json")

# Built-in fallback when no styles file is present.  Each style maps a
# human name to prompt-suffix text plus a trace-sweep preset hint.  The prompt
# suffix is appended to the user's prompt; the preset hint is written into the
# sweep handed to front_pipeline.sh (as a single-preset sweep) when the user
# did not supply their own --sweep.
BUILTIN_STYLES = {
    "flat-poster": {
        "prompt_suffix": ", flat vector poster, limited flat color palette, "
                         "clean bold shapes, no gradients, high contrast, "
                         "print-friendly screen-print art",
        "trace_preset": "poster",
    },
    "mono-line": {
        "prompt_suffix": ", black and white line art, single color ink, "
                         "solid silhouette, no gray, no gradients",
        "trace_preset": "bw",
    },
    "photo-halftone": {
        "prompt_suffix": ", photographic, soft gradients, halftone-friendly "
                         "continuous tone, detailed",
        "trace_preset": "photo",
    },
}

# Subcommand name -> (function, help)
SUBCOMMANDS = {}


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class SwarmError(Exception):
    """A SwarmUI API or reachability problem, carrying an exit code."""

    def __init__(self, message, exit_code=5):
        super().__init__(message)
        self.exit_code = exit_code


class SwarmClient:
    """Minimal SwarmUI HTTP client.

    ``_post`` and ``_get_bytes`` are the only places the network is touched;
    tests stub those two to run without a server.
    """

    def __init__(self, base_url=DEFAULT_BASE_URL, timeout=60):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.session_id = None

    # -- network seams (stubbed in tests) -----------------------------------

    def _post(self, route, payload):
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            self.base_url + route, data=data,
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def _get_bytes(self, path):
        # SwarmUI image paths embed the prompt (spaces, commas, quotes); the
        # URL must be percent-encoded or urllib raises InvalidURL.
        quoted = urllib.parse.quote(str(path).lstrip("/"), safe="/")
        url = self.base_url + "/" + quoted
        with urllib.request.urlopen(url, timeout=self.timeout) as resp:
            return resp.read()

    # -- API ---------------------------------------------------------------

    def connect(self):
        """Create a session.  Raises SwarmError(3) when the server is down."""
        try:
            resp = self._post("/API/GetNewSession", {})
        except (urllib.error.URLError, ConnectionError, OSError) as exc:
            raise SwarmError(
                "cannot reach SwarmUI at %s (%s). Is it running? "
                "Start it with:  cd ~/SwarmUI && ./launch-linux.sh"
                % (self.base_url, exc), exit_code=3)
        if "session_id" not in resp:
            raise SwarmError("GetNewSession returned no session_id: %r"
                             % resp, exit_code=3)
        self.session_id = resp["session_id"]
        return self.session_id

    def list_models(self):
        """Return the ``models`` map from ListT2IParams (category -> entries)."""
        resp = self._post("/API/ListT2IParams", {"session_id": self.session_id})
        return resp.get("models", {})

    def generate(self, params, images=1):
        """Queue a generation; return the list of ``View/...`` image paths."""
        payload = dict(params)
        payload["session_id"] = self.session_id
        payload["images"] = int(images)
        resp = self._post("/API/GenerateText2Image", payload)
        if "error" in resp and "images" not in resp:
            raise SwarmError(
                "generation failed: %s" % (resp.get("error")
                                           or resp.get("error_id") or resp))
        return resp.get("images", [])

    def download(self, view_path, out_dir):
        """Fetch a ``View/...`` image and save it under ``out_dir``."""
        os.makedirs(out_dir, exist_ok=True)
        name = os.path.basename(str(view_path).replace("\\", "/"))
        out_path = os.path.join(out_dir, name)
        with open(out_path, "wb") as handle:
            handle.write(self._get_bytes(view_path))
        return out_path


def _image_data_url(path):
    """Encode a local image as a ``data:image/...;base64,`` URL for ``initimage``."""
    with open(path, "rb") as handle:
        raw = handle.read()
    # Pillow is already a project dependency; use it for a reliable MIME type.
    from PIL import Image
    import io
    fmt = (Image.open(io.BytesIO(raw)).format or "png").lower()
    mime = "image/%s" % ("jpeg" if fmt == "jpg" else fmt)
    return "data:%s;base64,%s" % (mime, base64.b64encode(raw).decode("ascii"))


def _load_styles(styles_path):
    """Merge the styles file (if any) over the built-ins."""
    styles = dict(BUILTIN_STYLES)
    if styles_path and os.path.exists(styles_path):
        try:
            extra = fc.load_json(styles_path)
            if isinstance(extra, dict):
                styles.update(extra)
        except Exception as exc:  # noqa: BLE001
            print("swarm_bridge: WARNING: cannot read styles %s: %s"
                  % (styles_path, exc), file=sys.stderr)
    return styles


def _model_note(models):
    """Return (ok, message) for whether any generation model is available."""
    sd = models.get("Stable-Diffusion") or models.get("diffusion_models") or []
    if sd:
        return True, None
    counts = {k: (len(v) if isinstance(v, list) else 0)
              for k, v in sorted(models.items())}
    return False, ("no generation model available (model folders are empty: "
                   "%s). Mount your model tree or download a checkpoint, "
                   "then refresh SwarmUI." % counts)


def _resolve_model(models, requested=None):
    """Return the model name to send to GenerateText2Image.

    An explicit --model wins. Otherwise fall back to the first available
    Stable-Diffusion model, because a fresh SwarmUI install selects no default
    and the API answers ``No model input given`` when the field is omitted.
    ListT2IParams model entries are ``[name, architecture]`` pairs.
    """
    if requested:
        return requested
    sd = models.get("Stable-Diffusion") or models.get("diffusion_models") or []
    for entry in sd:
        if isinstance(entry, (list, tuple)) and entry:
            return entry[0]
        if isinstance(entry, str):
            return entry
    return None


# --------------------------------------------------------------------------
# Payload builders (pure, unit-tested)
# --------------------------------------------------------------------------

def build_generate_payload(prompt, width, height, model=None, negative=None,
                           steps=None, cfg=None, seed=None):
    """Flat GenerateText2Image body (minus session_id/images, added later)."""
    payload = {"prompt": prompt, "width": int(width), "height": int(height)}
    if model:
        payload["model"] = model
    if negative:
        payload["negativeprompt"] = negative
    if steps is not None:
        payload["steps"] = int(steps)
    if cfg is not None:
        payload["cfgscale"] = float(cfg)
    if seed is not None:
        payload["seed"] = int(seed)
    return payload


def build_filter_payload(prompt, source_png, width, height, creativity=0.6,
                         model=None, negative=None, steps=None, cfg=None):
    """GenerateText2Image body for img2img (source raster as initimage)."""
    payload = build_generate_payload(prompt, width, height, model, negative,
                                     steps, cfg)
    payload["initimage"] = _image_data_url(source_png)
    payload["initimagecreativity"] = float(creativity)
    return payload


# --------------------------------------------------------------------------
# Style templates (the "categorise and template" seed)
# --------------------------------------------------------------------------

def apply_style(style_name, styles_path):
    """Return (prompt_suffix, sweep_hint) for a named style."""
    styles = _load_styles(styles_path)
    if style_name not in styles:
        names = ", ".join(sorted(styles))
        raise SwarmError("unknown style '%s' (available: %s)"
                         % (style_name, names), exit_code=2)
    entry = styles[style_name]
    return entry.get("prompt_suffix", ""), entry.get("trace_preset")


def style_sweep_json(trace_preset, target_path):
    """Write a single-preset sweep file so the style controls the trace preset.

    Returns the path to the written sweep file.
    """
    payload = {
        "version": 1,
        "presets": [trace_preset],
        "filter_speckle": [2, 8],
        "hierarchical": ["cutout", "stacked"],
        "use_palette": [False, True],
        "max_candidates": 8,
    }
    os.makedirs(os.path.dirname(target_path), exist_ok=True)
    fc.write_json(target_path, payload)
    return target_path


# --------------------------------------------------------------------------
# Subcommands
# --------------------------------------------------------------------------

# #sui-bridge-run-front-pipeline: the one cross-repo call site.  PROJECT is this
# repo's own root, so gen2pipe needs the pipeline checkout *here* -- neither the
# cwd nor PATH is consulted.
def _run_front_pipeline(raster, sweep=None, skip_prep=False):
    """Invoke front_pipeline.sh.  A seam so tests can stub it."""
    argv = [os.path.join(PROJECT, "front_pipeline.sh"), raster]
    if sweep:
        # front_pipeline.sh parses only the --sweep=FILE form.
        argv += ["--sweep=%s" % sweep]
    if skip_prep:
        argv += ["--skip-prep"]
    return subprocess.call(argv)


def cmd_generate(args):
    client = SwarmClient(args.base_url)
    client.connect()
    models = client.list_models()
    ok, note = _model_note(models)
    if not ok:
        raise SwarmError(note, exit_code=4)
    model = _resolve_model(models, args.model)

    payload = build_generate_payload(
        args.prompt, args.width, args.height, model=model,
        negative=args.negative, steps=args.steps, cfg=args.cfg, seed=args.seed)
    paths = client.generate(payload, images=args.images)
    if not paths:
        raise SwarmError("generation returned no images")

    out = []
    for p in paths:
        out.append(client.download(p, args.out_dir))
        print("swarm_bridge: %s" % out[-1])
    manifest = {
        "tool": "swarm_bridge.py", "generated": _now(), "mode": "generate",
        "base_url": args.base_url, "prompt": args.prompt,
        "images_requested": args.images, "files": out,
        "swarmui_version": client.session_id and "see server",
    }
    fc.write_json(os.path.join(args.out_dir, "swarm_generate.json"), manifest)
    return 0


def cmd_filter(args):
    if not os.path.exists(args.source):
        print("swarm_bridge: source not found: %s" % args.source,
              file=sys.stderr)
        return 2
    client = SwarmClient(args.base_url)
    client.connect()
    models = client.list_models()
    ok, note = _model_note(models)
    if not ok:
        raise SwarmError(note, exit_code=4)
    model = _resolve_model(models, args.model)

    # Resolve the output dimensions from the source so img2img keeps the
    # artwork's own shape unless explicitly overridden.
    from PIL import Image
    with Image.open(args.source) as im:
        src_w, src_h = im.size
    width = args.width or src_w
    height = args.height or src_h

    payload = build_filter_payload(
        args.prompt, args.source, width, height,
        creativity=args.creativity, model=model,
        negative=args.negative, steps=args.steps, cfg=args.cfg)
    paths = client.generate(payload, images=args.images)
    if not paths:
        raise SwarmError("generation returned no images")

    out = [client.download(p, args.out_dir) for p in paths]
    for p in out:
        print("swarm_bridge: %s" % p)
    manifest = {
        "tool": "swarm_bridge.py", "generated": _now(), "mode": "filter",
        "base_url": args.base_url, "prompt": args.prompt,
        "source": args.source, "creativity": args.creativity,
        "files": out,
    }
    fc.write_json(os.path.join(args.out_dir, "swarm_filter.json"), manifest)
    return 0


def cmd_gen2pipe(args):
    client = SwarmClient(args.base_url)
    client.connect()
    models = client.list_models()
    ok, note = _model_note(models)
    if not ok:
        raise SwarmError(note, exit_code=4)
    model = _resolve_model(models, args.model)

    prompt = args.prompt
    sweep_hint = None
    if args.style:
        suffix, sweep_hint = apply_style(args.style, args.styles)
        prompt = (prompt + suffix) if prompt else suffix.strip(", ")

    payload = build_generate_payload(
        prompt, args.width, args.height, model=model,
        negative=args.negative, steps=args.steps, cfg=args.cfg, seed=args.seed)
    paths = client.generate(payload, images=args.images)
    if not paths:
        raise SwarmError("generation returned no images")

    raster = client.download(paths[0], args.source_dir)
    print("swarm_bridge: generated source: %s" % raster)

    sweep = args.sweep
    if sweep is None and sweep_hint:
        sweep = style_sweep_json(
            sweep_hint, os.path.join(args.source_dir, "style_sweep.json"))

    code = _run_front_pipeline(raster, sweep=sweep, skip_prep=args.skip_prep)
    if code not in (0, 1):
        # 0 = candidates passed, 1 = candidates produced but none passed.
        # Anything else (2) is a pipeline step failure.
        raise SwarmError("front_pipeline.sh exited %d" % code, exit_code=2)
    return code


def build_argparser():
    parser = argparse.ArgumentParser(
        prog="swarm_bridge.py",
        description="Bridge the print pipeline to a running SwarmUI instance.")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common(p):
        p.add_argument("--base-url", default=DEFAULT_BASE_URL,
                       help="SwarmUI base URL (default: %s)" % DEFAULT_BASE_URL)
        p.add_argument("--model", default=None,
                       help="generation model name (default: SwarmUI default)")
        p.add_argument("--images", type=int, default=1,
                       help="number of images to generate")
        p.add_argument("--negative", default=None, help="negative prompt")
        p.add_argument("--steps", type=int, default=None)
        p.add_argument("--cfg", type=float, default=None,
                       help="CFG scale")
        p.add_argument("--seed", type=int, default=None)

    g = sub.add_parser("generate", help="text -> image(s), saved to disk")
    g.add_argument("prompt")
    g.add_argument("--width", type=int, default=1024)
    g.add_argument("--height", type=int, default=1024)
    g.add_argument("--out-dir", default=os.path.join(PROJECT, "00_source"))
    add_common(g)
    g.set_defaults(func=cmd_generate)

    f = sub.add_parser("filter",
                       help="source image + text -> img2img variant(s)")
    f.add_argument("source", help="source raster (PNG/JPG) to restyle")
    f.add_argument("prompt", help="style directive (applied to the source)")
    f.add_argument("--creativity", type=float, default=0.6,
                   help="img2img creativity 0..1 (0=keep, 1=recreate)")
    f.add_argument("--width", type=int, default=None)
    f.add_argument("--height", type=int, default=None)
    f.add_argument("--out-dir", default=os.path.join(PROJECT, "00_source"))
    add_common(f)
    f.set_defaults(func=cmd_filter)

    p = sub.add_parser("gen2pipe",
                       help="text -> image -> front_pipeline.sh (prep->sweep->compare)")
    p.add_argument("prompt")
    p.add_argument("--width", type=int, default=1024)
    p.add_argument("--height", type=int, default=1024)
    p.add_argument("--style", default=None,
                   help="named style recipe (prompt suffix + trace preset)")
    p.add_argument("--styles", default=DEFAULT_STYLES,
                   help="styles JSON (default: scripts/swarm_styles.json)")
    p.add_argument("--sweep", default=None,
                   help="sweep config passed to front_pipeline.sh")
    p.add_argument("--skip-prep", action="store_true",
                   help="pass --skip-prep through to front_pipeline.sh")
    p.add_argument("--source-dir", default=os.path.join(PROJECT, "00_source"))
    add_common(p)
    p.set_defaults(func=cmd_gen2pipe)

    return parser


def main(argv=None):
    parser = build_argparser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except SwarmError as exc:
        print("swarm_bridge: %s" % exc, file=sys.stderr)
        return exc.exit_code
    except Exception as exc:  # noqa: BLE001 - unexpected, surface honestly
        print("swarm_bridge: unexpected error: %s: %s"
              % (type(exc).__name__, exc), file=sys.stderr)
        return 5


if __name__ == "__main__":
    sys.exit(main())
