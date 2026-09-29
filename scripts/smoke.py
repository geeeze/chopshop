#!/usr/bin/env python3
"""Prove the service runs on THIS box, with real weights and real timings.

    HF_HOME=/path/to/hf /path/to/gpu-venv/bin/python scripts/smoke.py --json report.json

Not a test — the test suite deliberately needs no GPU. This is the opposite:
it loads the real checkpoint, generates, and prints what the machine actually
did, so "it works" is a measurement rather than a claim.

Run it from the repository root with the interpreter that has torch + diffusers:

    /path/to/gpu-venv/bin/python scripts/smoke.py

It writes into its own output directory (`--out`, default a temp dir) and never
touches the pipeline's trees.
"""

import argparse
import json
import os
import platform
import sys
import tempfile
import time
import warnings

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from chopshop_flux import config, models  # noqa: E402
from chopshop_flux.engine import FluxEngine  # noqa: E402


def frame_colours(path):
    """How many distinct colours are in this PNG. 1 = a uniform (blank) frame."""
    from PIL import Image

    with Image.open(path) as image:
        return len(image.convert("RGB").getcolors(maxcolors=1 << 24) or [])


def environment_facts():
    """What machine is this, in the terms that decide whether it will work."""
    import torch

    facts = {
        "python": platform.python_version(),
        "torch": torch.__version__,
        "rocm": getattr(torch.version, "hip", None),
        "cuda_available": torch.cuda.is_available(),
    }
    if torch.cuda.is_available():
        # torch presents a ROCm GPU as "cuda", and an integrated GPU enumerates
        # too — so report what it says it is rather than assuming device 0.
        facts["device_name"] = torch.cuda.get_device_name(0)
        free, total = torch.cuda.mem_get_info(0)
        facts["vram_total_gb"] = round(total / 1024 ** 3, 2)
        facts["vram_free_gb"] = round(free / 1024 ** 3, 2)
    return facts


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default=models.DEFAULT_MODEL_KEY)
    parser.add_argument("--prompt", default="a woodcut phoenix emblem, high contrast, flat colours")
    parser.add_argument("--size", type=int, default=512, help="square edge")
    parser.add_argument("--steps", type=int, default=None, help="default: the model's")
    parser.add_argument("--images", type=int, default=1)
    parser.add_argument("--seed", type=int, default=None,
                        help="fix the seed; unset means the service picks and reports one")
    parser.add_argument("--repeat", type=int, default=2,
                        help="generations to run, to separate cold from warm (default 2)")
    parser.add_argument("--offload", default=config.offload(),
                        choices=("cpu", "none"),
                        help="'none' keeps everything resident — the measurement, "
                             "not the operating mode")
    parser.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "chopshop-flux-smoke"))
    parser.add_argument("--json", dest="json_path", default=None)
    # The output-side passes (#flux-hires #flux-ink-cap #flux-background
    # #flux-seeds). Off unless asked for, exactly as in the request body — and the
    # numbers they MEASURE (the count actually present, pixels moved, each pass's
    # seconds) are what this script exists to print on the real card.
    parser.add_argument("--ink-cap", dest="ink_cap", type=int, default=None,
                        help="reduce each frame to at most N flat colours")
    parser.add_argument("--ink-cap-mode", dest="ink_cap_mode", default=None,
                        choices=("quantize", "posterize"))
    parser.add_argument("--background", default=None,
                        choices=("white", "key", "keep"))
    parser.add_argument("--hires", action="store_true",
                        help="second pass: upscale, then img2img at low strength")
    parser.add_argument("--hires-scale", dest="hires_scale", type=float,
                        default=None)
    parser.add_argument("--hires-strength", dest="hires_strength", type=float,
                        default=None)
    parser.add_argument("--seeds", default=None, metavar="1,2,3",
                        help="a seed sweep (comma-separated)")
    parser.add_argument("--provenance", action="store_true")
    args = parser.parse_args(argv)

    # Only the keys that were asked for: a smoke run with no flags must be the
    # request this script always made.
    passes: dict = {}
    if args.ink_cap is not None:
        passes["ink_cap"] = args.ink_cap
    if args.ink_cap_mode:
        passes["ink_cap_mode"] = args.ink_cap_mode
    if args.background:
        passes["background"] = args.background
    if args.seeds:
        passes["seeds"] = [int(part) for part in args.seeds.split(",") if part]
    if args.provenance:
        passes["provenance"] = True
    if args.hires:
        block = {}
        if args.hires_scale is not None:
            block["scale"] = args.hires_scale
        if args.hires_strength is not None:
            block["strength"] = args.hires_strength
        passes["hires"] = block

    report = {"model": args.model, "size": args.size, "steps": args.steps,
              "images": args.images, "offload": args.offload, "seed": args.seed,
              "output_passes_requested": passes,
              "environment": environment_facts(), "runs": []}

    print("=== environment ===")
    for key, value in report["environment"].items():
        print("  %-16s %s" % (key, value))

    spec = models.resolve(args.model)
    print("\n=== model ===")
    print("  %-16s %s" % ("repo", spec.repo_id))
    print("  %-16s %s (commercial: %s)" % ("licence", spec.license, spec.commercial_ok))
    print("  %-16s %s" % ("weights", spec.notes.split(".")[0]))

    engine = FluxEngine(out_dir=args.out, offload=args.offload)
    print("\n=== running ===")
    for attempt in range(1, args.repeat + 1):
        started = time.time()
        # The NaN that makes a black frame is announced, once, as
        # RuntimeWarning("invalid value encountered in cast") while diffusers
        # converts latents to uint8. Catching it here detects the mechanism on
        # every frame instead of waiting for a rare blank one to show up.
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            result = engine.generate(
                model=args.model, prompt=args.prompt,
                width=args.size, height=args.size,
                steps=args.steps, images=args.images, seed=args.seed,
                **passes,
            )
        wall = time.time() - started
        run = {
            "attempt": attempt,
            "wall_seconds": round(wall, 2),
            "load_seconds": round(result["load_seconds"], 2),
            "total_seconds": round(result["total_seconds"], 2),
            "per_image_seconds": [round(i["seconds"], 2) for i in result["images"]],
            "seed": result["seed"],
            "steps": result["steps"],
            "guidance": result["guidance"],
            "names": [i["name"] for i in result["images"]],
            "warnings": result["warnings"],
            "nan_warnings": [str(w.message) for w in caught
                             if "invalid value" in str(w.message)],
        }
        # A run that "succeeds" and writes a uniform black frame is the failure
        # mode this pipeline actually has: diffusers logs only
        # "invalid value encountered in cast" while converting NaN latents, and
        # the caller gets a plausible-looking file. Count the colours.
        run["frame_colour_counts"] = [frame_colours(os.path.join(args.out, n))
                                     for n in run["names"]]
        run["blank_frames"] = [n for n, count in zip(run["names"], run["frame_colour_counts"])
                              if count <= 1]
        # What the output-side passes MEASURED on the frame they wrote, per frame:
        # the cap and the count actually present (or the skip), what was keyed and
        # how many pixels moved, and each hires pass's seconds.
        run["output_passes"] = [
            {key: entry[key] for key in
             ("ink_cap", "background", "hires", "provenance", "sidecar")
             if key in entry}
            for entry in result["images"]]
        if "hires" in result:
            run["hires"] = result["hires"]
        if "seed_files" in result:
            run["seed_files"] = result["seed_files"]
        report["runs"].append(run)
        print("  run %d: load %.1fs, generate %.1fs for %d image(s) [%s]"
              % (attempt, result["load_seconds"], result["total_seconds"],
                 len(result["images"]), ", ".join(run["names"])))
        if run["nan_warnings"]:
            print("    NaN: %s" % "; ".join(sorted(set(run["nan_warnings"]))))
        if run["blank_frames"]:
            print("    BLANK: %s (%d distinct colour(s)) — NaN in decode"
                  % (", ".join(run["blank_frames"]),
                     min(run["frame_colour_counts"])))
        for entry in run["output_passes"]:
            cap = entry.get("ink_cap")
            if cap:
                print("    ink_cap: %d -> %d colour(s) at most %d (%s)%s"
                      % (cap["colors_before"], cap["colors_present"],
                         cap["max_colors"], cap["mode"],
                         "" if cap["changed"] else "  [nothing was reduced]"))
            hires = entry.get("hires")
            if hires:
                print("    hires: %sx %s, %dx%d, passes %s s"
                      % (hires["scale"], hires["upscaler"], hires["target"][0],
                         hires["target"][1], hires["pass_seconds"]))
            background = entry.get("background")
            if background:
                print("    background: %s  [%s]"
                      % (background["mode"], background.get("note", "")))
        for warning in result["warnings"]:
            print("    warning: %s" % warning)

    cold = report["runs"][0]
    warm = report["runs"][-1]
    blank = sum(len(r["blank_frames"]) for r in report["runs"])
    total = sum(len(r["names"]) for r in report["runs"])
    nan = sum(len(r["nan_warnings"]) for r in report["runs"])
    print("\n  frames: %d generated, %d blank, %d NaN warning(s)"
          % (total, blank, nan))
    report["summary"] = {
        "frames": total,
        "blank_frames": blank,
        "nan_warnings": nan,
        "load_seconds": cold["load_seconds"],
        "first_generate_seconds": cold["total_seconds"],
        "warm_generate_seconds": warm["total_seconds"],
        "seconds_per_image_warm": (warm["total_seconds"] / max(1, args.images)),
    }
    import torch
    if torch.cuda.is_available():
        free, total = torch.cuda.mem_get_info(0)
        report["summary"]["vram_used_gb"] = round((total - free) / 1024 ** 3, 2)
        report["summary"]["vram_total_gb"] = round(total / 1024 ** 3, 2)

    print("\n=== summary ===")
    for key, value in report["summary"].items():
        print("  %-24s %s" % (key, value))
    print("\n  output: %s" % args.out)
    for name in cold["names"]:
        print("    %s" % os.path.join(args.out, name))

    if args.json_path:
        with open(args.json_path, "w") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
        print("\n  report: %s" % args.json_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
