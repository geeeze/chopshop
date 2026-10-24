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
import hashlib
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


def frame_digest(path):
    """The sha256 of a frame's bytes.

    What the multi-reference comparison asserts on, and it is deliberately the
    WHOLE FILE rather than a mean pixel difference: "the two frames are
    different" is a claim about the conditioning, and a mean can be a small
    number produced by a large difference in a few pixels. Equality of digests is
    the only way two frames are the same frame, so it is the only comparison that
    can fail.
    """
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def mean_abs_pixel_difference(left, right):
    """Mean per-channel |difference| between two frames of the same size.

    Reported alongside the digest comparison, not instead of it. It answers a
    question the digest cannot: a frame that differs by one pixel in one channel
    and a frame that is visibly a different image are both "different", and only
    the magnitude says which happened. ``None`` when the two frames are not the
    same size, which is itself a difference worth refusing to summarise.
    """
    from PIL import Image, ImageChops, ImageStat

    with Image.open(left) as one, Image.open(right) as two:
        if one.size != two.size:
            return None
        diff = ImageChops.difference(one.convert("RGB"), two.convert("RGB"))
        # ImageStat rather than a hand-rolled sum, so the reduction is the
        # library's and this is a measurement rather than an arithmetic opinion.
        return round(sum(ImageStat.Stat(diff).mean) / 3.0, 3)


# -- the multi-reference case -----------------------------------------------
#
# The capability this script exists to check: does the checkpoint really
# condition on ALL of its references, or does the pipeline take the first and
# quietly ignore the rest? Unit tests of the plumbing cannot answer that — the
# plumbing is correct by construction — and neither can an `inspect.signature`
# on a diffusers pipeline. The only thing that answers it is a real render whose
# result DIFFERS when a second reference is added and nothing else changes.
#
# So the comparison is built to be falsifiable in exactly one direction: the
# same model, the same prompt, the same seed, the same steps, the same output
# size, and the same FIRST reference. If adding the second reference changes
# nothing at all, the second image is not conditioning anything and the run
# FAILS. That is a real risk — dropping to `image[0]` is the obvious
# implementation of a list-typed parameter — so the check is worth its three
# extra generations.
#
# The seed is the load-bearing part. Diffusion sampling is a function of the
# latent, the prompt conditioning and the step schedule; the prompt conditioning
# is the only thing this case varies, so a fixed seed makes the two runs
# comparable and an unpinned one would make the difference indistinguishable from
# noise.

MULTI_REFERENCE_PROMPT = (
    "a flat high-contrast woodcut emblem: a single bold mark, "
    "pure white background")
# Two clearly different subjects. If the second reference were being ignored,
# using a subject that is nothing like the first is what makes the frame change;
# a second reference of the same kind would hide the fault in a different frame.
MULTI_REFERENCE_SECOND_PROMPT = (
    "a soft grey gradient sphere, photographic, smooth shading, plain background")


def multi_reference_case(engine, out_dir, model, size, steps, seed,
                         guidance=None):
    """Run the multi-reference comparison and return its report block.

    Four generations, all on one loaded model, in this order:

    1. the two reference frames (text-to-image, so neither depends on an edit);
    2. an edit conditioned on reference A ALONE;
    3. the same edit conditioned on A and B.

    (1) and (2) are the controls. Without (1) a difference between the two
    frames could be explained by the references being different from each other
    rather than by both being used; without (2) there is nothing to compare the
    two-reference frame against, since "differs from a text-to-image frame" is
    true of every edit.

    Returns a dict the caller writes into its JSON report. The `passed` key is
    the verdict; the digests and the mean difference are the evidence, so a
    reader can see the size of the change rather than being told it happened.
    """
    block = {
        "model": model, "size": size, "steps": steps, "seed": seed,
        "prompt": MULTI_REFERENCE_PROMPT,
        "second_prompt": MULTI_REFERENCE_SECOND_PROMPT,
        "runs": [], "passed": None,
    }

    # Asked FIRST, before any generation: on a family that takes one reference
    # the comparison is not runnable at all — the service would refuse the
    # second image, correctly — and four generations to reach a refusal the
    # registry already predicts is a waste of twenty minutes on a cold cache.
    if not spec_supports_multi(model):
        block["detail"] = (
            "%s does not declare multi_reference in the registry, so the "
            "comparison does not apply to it: the service would refuse a second "
            "reference, correctly. That is a real answer about this checkpoint "
            "rather than a failure of the check — run it against a klein model."
            % model)
        return block

    def _generate(**kwargs):
        started = time.time()
        result = engine.generate(model=model, **kwargs)
        return result, round(time.time() - started, 2)

    # 1. The two references. Fixed seeds of their own, distinct from the
    #    comparison seed so neither is the frame the comparison produces.
    made = {}
    for label, prompt, ref_seed in (("a", MULTI_REFERENCE_PROMPT, seed + 1),
                                    ("b", MULTI_REFERENCE_SECOND_PROMPT,
                                     seed + 2)):
        result, wall = _generate(prompt=prompt, width=size, height=size,
                                 steps=steps, seed=ref_seed, images=1)
        path = os.path.join(out_dir, result["images"][0]["name"])
        made[label] = path
        block["runs"].append(dict(
            _describe(path), role="reference-%s" % label, seed=result["seed"],
            name=result["images"][0]["name"], path=path, wall_seconds=wall))

    # 2 & 3. The comparison. Identical in every field except the reference list.
    variants = (("single", [made["a"]]), ("dual", [made["a"], made["b"]]))
    frames = {}
    for label, paths in variants:
        # Read the frames as BYTES, once, and hand the engine the list itself.
        # The engine's own contract is bytes-or-list-of-bytes, and re-encoding
        # through a file here would be a second definition of what a reference
        # is — one that could differ from the service's data-URL path and make
        # the comparison measure the encoding rather than the conditioning.
        blobs = []
        for path in paths:
            with open(path, "rb") as handle:
                blobs.append(handle.read())
        result, wall = _generate(prompt=MULTI_REFERENCE_PROMPT, width=size,
                                 height=size, steps=steps, seed=seed, images=1,
                                 reference=blobs, guidance=guidance)
        path = os.path.join(out_dir, result["images"][0]["name"])
        frames[label] = path
        block["runs"].append(dict(
            _describe(path), role="edit-%s" % label, references=len(blobs),
            seed=result["seed"], name=result["images"][0]["name"], path=path,
            wall_seconds=wall))

    single, dual = frames["single"], frames["dual"]
    digest_single = frame_digest(single)
    digest_dual = frame_digest(dual)
    try:
        difference = mean_abs_pixel_difference(single, dual)
    except ImportError:
        difference = None
    block["comparison"] = {
        "single_reference": single,
        "dual_reference": dual,
        "sha256_single": digest_single,
        "sha256_dual": digest_dual,
        "digests_differ": digest_single != digest_dual,
        "mean_abs_pixel_difference": difference,
    }
    block["passed"] = digest_single != digest_dual
    block["detail"] = (
        "the two-reference frame is a different frame from the one-reference "
        "frame at the same prompt, seed and steps%s, so the second reference "
        "conditioned the generation"
        % ("" if difference is None
           else " (mean per-channel |diff| %s)" % difference)) \
        if block["passed"] else (
        "the two-reference frame is BYTE-IDENTICAL to the one-reference frame "
        "at the same prompt, seed and steps: the second reference conditioned "
        "nothing. The pipeline is reading only the first image, so "
        "multi_reference is declared and not implemented on this checkpoint.")
    return block


def _describe(path):
    """The per-frame row the report carries. Digest, plus the blank-frame colour
    count WHEN IT CAN BE COMPUTED.

    The colour count is what catches this pipeline's real failure mode (NaN
    latents -> a uniform black PNG that looks like a success), and it needs
    Pillow. The digest does not. So the count is omitted rather than raised when
    Pillow is missing: this case's VERDICT is the digest comparison, and a box
    without an image library must still be able to run it and get a real
    answer. The repeat loop in ``main`` is the opposite case — it is a
    Pillow-having box by construction, and there a missing Pillow should be a
    hard error rather than a silently thinner report.
    """
    entry = {"sha256": frame_digest(path), "distinct_colours": None}
    try:
        entry["distinct_colours"] = frame_colours(path)
    except ImportError:
        pass
    return entry


def spec_supports_multi(model):
    """Whether the registry says this checkpoint may take several references."""
    try:
        return bool(models.resolve(model).multi_reference)
    except models.ModelError:
        return False


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
    # The multi-reference case (#flux-multi-reference). Off unless asked for,
    # because it is FOUR generations and its own comparison — the point of it is
    # the difference between two frames, and folding it into the repeat loop
    # would put that difference somewhere the report does not show it.
    parser.add_argument("--multi-reference", action="store_true",
                        help="prove multi-reference conditioning really happens: "
                             "the same prompt, seed and steps with one reference "
                             "and with two, and the assertion that the frames differ")
    parser.add_argument("--multi-reference-seed", type=int, default=4321,
                        help="seed for the multi-reference comparison (default 4321)")
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

    # The multi-reference case, after the repeat loop and before the summary,
    # so its four frames and their comparison are the LAST thing the report
    # shows rather than a row among the repeats. Its verdict is separate from
    # the blank-frame verdict on purpose: a run where nothing is blank and the
    # second reference conditioned nothing is still a failure of a claim this
    # repo makes, and folding the two would let either one hide the other.
    if args.multi_reference:
        print("\n=== multi-reference ===")
        case = multi_reference_case(
            engine, args.out, args.model, args.size, args.steps,
            args.multi_reference_seed, guidance=1.0)
        report["multi_reference"] = case
        for entry in case["runs"]:
            print("  %-16s seed %-6s %6.1fs  %s colours  %s"
                  % (entry["role"], entry["seed"], entry["wall_seconds"],
                     entry["distinct_colours"] if entry["distinct_colours"]
                     is not None else "?", entry["name"]))
        print("  %s" % case["detail"])
        if case["passed"] is False:
            print("  FAIL: multi-reference is declared and did not happen")

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
    # 5 when the multi-reference case ran and FAILED — the repo's "generation
    # failed" code, the one a caller already handles. A run that only skips the
    # case (`--multi-reference` not asked for) or that found it inapplicable
    # exits 0: not having run the check is not the check failing, and turning
    # every default smoke run red would make the code mean nothing.
    if report.get("multi_reference", {}).get("passed") is False:
        return 5
    return 0


if __name__ == "__main__":
    sys.exit(main())
