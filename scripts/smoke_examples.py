#!/usr/bin/env python3
"""Run the bundled example set against a LIVE service and report what happened.

    python -m chopshop_flux serve &                       # or however you run it
    python scripts/smoke_examples.py --only sdxl-lightning-4step
    python scripts/smoke_examples.py --report examples-report

**Not a test, and must not become one.** The test suite runs with no GPU, no
torch, no models and no network; this is the opposite — it drives the real
service over HTTP, loads real weights, and writes down the numbers. Its whole
purpose is that "the examples work" is a measurement rather than a claim.

It talks HTTP, so it needs nothing but the stdlib and a reachable service: the
GPU box is the service's problem, not this script's. That is also why it does
not import torch and why the blank-frame check below is written from scratch
rather than borrowed from ``scripts/smoke.py`` — that script runs *on* the box
next to its own weights and has Pillow; this one may be running anywhere.

Two things it refuses to do:

* trust the exit code. A pipeline that returns a uniform black frame is
  announced by diffusers only as ``RuntimeWarning: invalid value encountered in
  cast``, and the caller gets a plausible-looking PNG. Every frame is decoded
  and counted, so a blank one is a FAIL with its colour count as the evidence.
* pass an example it never ran. A missing image, an unreadable one or a sketchy
  one is reported as FAIL row-by-row, and the exit code is the repo's 5.
"""

import argparse
import hashlib
import json
import os
import struct
import sys
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from chopshop_flux import config  # noqa: E402
from chopshop_flux.client import FluxClient, FluxError  # noqa: E402
from chopshop_flux.examples import (DEFAULT_EXAMPLES_PATH, load_examples,  # noqa: E402
                                    validate_examples)

# A frame with one distinct colour is the failure mode this pipeline actually
# has (NaN latents -> uniform black PNG -> byte-for-byte a successful-looking
# file). Anything at or below this is reported as blank.
BLANK_COLOUR_LIMIT = 1


# -- the content check, stdlib only ----------------------------------------
#
# Enough of a PNG decoder to count colours exactly, for the format the service
# writes: 8-bit RGB or RGBA, non-interlaced, which is what Pillow produces for
# an RGB image. A different format raises rather than being guessed at — a check
# that silently measures the wrong thing is worse than no check.

_PNG_CHANNELS = {2: 3, 6: 4, 0: 1}  # colour type -> channels per pixel


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def frame_colour_count(path):
    """Distinct colours in a PNG, decoded properly (filters and all).

    Counting decompressed *bytes* would be quicker and wrong: a smooth gradient
    and a flat fill can produce similar byte histograms, and the whole point of
    this check is to tell a real frame from a uniform one.
    """
    with open(path, "rb") as handle:
        raw = handle.read()
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("%s is not a PNG" % path)

    pos = 8
    width = height = bit_depth = colour_type = interlace = None
    idat = bytearray()
    while pos < len(raw):
        length = struct.unpack(">I", raw[pos:pos + 4])[0]
        kind = raw[pos + 4:pos + 8]
        body = raw[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            (width, height, bit_depth, colour_type, _c, _f,
             interlace) = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length

    if width is None or height is None:
        raise ValueError("%s has no IHDR chunk" % path)
    if bit_depth != 8 or colour_type not in _PNG_CHANNELS or interlace != 0:
        raise ValueError(
            "%s is not an 8-bit non-interlaced RGB/grey PNG (bit depth %s, "
            "colour type %s, interlace %s) — this check cannot measure it"
            % (path, bit_depth, colour_type, interlace))

    channels = _PNG_CHANNELS[colour_type]
    stride = width * channels
    data = zlib.decompress(bytes(idat))
    if len(data) < (stride + 1) * height:
        raise ValueError("%s is truncated" % path)

    colours = set()
    previous = bytearray(stride)
    offset = 0
    for _row in range(height):
        filter_type = data[offset]
        offset += 1
        line = bytearray(data[offset:offset + stride])
        offset += stride
        # Undo the per-row filter. Getting this wrong yields plausible-looking
        # noise rather than an error, which is exactly why it is done in full.
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up = previous[i]
            up_left = previous[i - channels] if i >= channels else 0
            if filter_type == 0:
                pass
            elif filter_type == 1:
                line[i] = (line[i] + left) & 0xFF
            elif filter_type == 2:
                line[i] = (line[i] + up) & 0xFF
            elif filter_type == 3:
                line[i] = (line[i] + ((left + up) >> 1)) & 0xFF
            elif filter_type == 4:
                line[i] = (line[i] + _paeth(left, up, up_left)) & 0xFF
            else:
                raise ValueError("%s has unknown PNG filter %d at row %d"
                                 % (path, filter_type, _row))
        for x in range(0, stride, channels):
            colours.add(bytes(line[x:x + channels]))
        previous = line
    return len(colours)


def content_check(path):
    """``(ok, detail)`` for one written PNG, without trusting its existence."""
    if not os.path.isfile(path):
        return False, "no file was written"
    size = os.path.getsize(path)
    if size == 0:
        return False, "0-byte file"
    try:
        colours = frame_colour_count(path)
    except (ValueError, OSError, zlib.error) as exc:
        return False, "unreadable frame: %s" % exc
    if colours <= BLANK_COLOUR_LIMIT:
        return False, "BLANK frame (%d distinct colour(s))" % colours
    return True, "%d distinct colours" % colours


# -- running the set -------------------------------------------------------


def example_request(entry, reference_path=None):
    """The arguments for one call, shared by /generate and /edit."""
    kwargs = {
        "model": entry["model"],
        "width": entry["width"],
        "height": entry["height"],
        "steps": entry["steps"],
        "guidance": entry["guidance"],
        "seed": entry["seed"],
        "modifiers": entry["modifiers"] or None,
        "vae": entry["vae"],
    }
    if entry.get("negative_prompt"):
        kwargs["negative_prompt"] = entry["negative_prompt"]
    return kwargs


def run_one(client, entry, out_dir, reference_path=None, timeout=1800.0):
    """Run a single example and return its report row."""
    row = {
        "id": entry["id"],
        "model": entry["model"],
        "modifiers": entry["modifiers"],
        "vae": entry["vae"],
        "style": entry["style"],
        "reference": entry.get("reference"),
        "width": entry["width"],
        "height": entry["height"],
        "steps": entry["steps"],
        "guidance": entry["guidance"],
        "requested_seed": entry["seed"],
        "edited": reference_path is not None,
        "what_it_proves": entry["what_it_proves"],
        "status": "FAIL",
        "detail": "",
        "images": [],
        "warnings": [],
        "seconds": None,
    }
    started = time.monotonic()
    try:
        if reference_path is not None:
            payload = client.edit(reference_path, entry["prompt"],
                                  **example_request(entry))
        else:
            payload = client.generate(entry["prompt"], **example_request(entry))
    except FluxError as exc:
        row["detail"] = "service error (exit %s): %s" % (exc.exit_code, exc)
        row["seconds"] = round(time.monotonic() - started, 2)
        return row
    except Exception as exc:  # noqa: BLE001 - a row, never a crash
        row["detail"] = "%s: %s" % (type(exc).__name__, exc)
        row["seconds"] = round(time.monotonic() - started, 2)
        return row

    row["seconds"] = round(time.monotonic() - started, 2)
    row["seed"] = payload.get("seed")
    row["warnings"] = payload.get("warnings") or []
    row["applied_modifiers"] = payload.get("modifiers") or []
    row["scheduler"] = payload.get("scheduler")

    failures = []
    for image in payload.get("images") or []:
        try:
            local = client.download(image["name"], out_dir)
        except FluxError as exc:
            failures.append("%s: download failed (%s)" % (image["name"], exc))
            continue
        okay, detail = content_check(local)
        # The sha256 is computed here, from the bytes on disk, rather than
        # copied from the response: the point of the column is to be able to
        # tell two runs apart later, and a digest of what the service *said*
        # would survive a service that wrote a different file.
        with open(local, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        row["images"].append({
            "name": image["name"],
            "path": local,
            "bytes": os.path.getsize(local) if os.path.isfile(local) else 0,
            "sha256": digest,
            "content_ok": okay,
            "content_detail": detail,
            "seconds": image.get("seconds"),
            "width": image.get("width"),
            "height": image.get("height"),
        })
        if not okay:
            failures.append("%s: %s" % (image["name"], detail))
    if not row["images"]:
        failures.append("the service returned no images")

    if failures:
        row["detail"] = "; ".join(failures)
    else:
        row["status"] = "PASS"
        row["detail"] = row["images"][0]["content_detail"]
    return row


def select(entries, only):
    """The examples to run, plus the references they need, in dependency order.

    ``--only`` is the point of this function: running one example must not
    require running all 27, but an edit example cannot run without the frame it
    edits, so its reference chain is pulled in and generated first.
    """
    by_id = {entry["id"]: entry for entry in entries}
    if only is None:
        return list(entries)

    if only not in by_id:
        raise SystemExit("no example with id '%s' (have: %s)"
                         % (only, ", ".join(sorted(by_id))))

    wanted = []
    seen = set()

    def add(example_id):
        if example_id in seen:
            return
        seen.add(example_id)
        entry = by_id[example_id]
        reference = entry.get("reference")
        if reference:
            add(reference)
        wanted.append(entry)

    add(only)
    return wanted


def write_reports(report, json_path, md_path):
    with open(json_path, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")

    rows = report["examples"]
    lines = [
        "# chopshop-flux example report",
        "",
        "Real weights, real service, one row per example. Generated by",
        "`scripts/smoke_examples.py` — not a test, and it is not run by the test",
        "suite.",
        "",
        "- service: `%s`" % report["service"],
        "- example set: `%s`" % report["examples_path"],
        "- offload: `%s`" % report["offload"],
        "- ack non-commercial: `%s`" % report["ack_noncommercial"],
        "- %d example(s): %d PASS, %d FAIL" % (len(rows), report["passed"],
                                               report["failed"]),
        "",
        "| example | model | modifiers | vae | size | steps / guidance | seconds |"
        " seed | sha256 | frame | status |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for row in rows:
        image = row["images"][0] if row["images"] else {}
        lines.append("| `%s` | %s | %s | %s | %dx%d | %s / %s | %s | %s | `%s` | %s | %s |"
                     % (row["id"], row["model"],
                        ", ".join(row["modifiers"]) or "—",
                        row["vae"] or "—", row["width"], row["height"],
                        row["steps"], row["guidance"], row["seconds"],
                        row.get("seed"),
                        (image.get("sha256") or "—")[:12],
                        image.get("content_detail") or row["detail"],
                        "**PASS**" if row["status"] == "PASS" else "**FAIL**"))
    lines += ["", "## What each example is for", ""]
    for row in rows:
        lines.append("- **%s** — %s" % (row["id"], row["what_it_proves"]))
    warnings = [(row["id"], warning) for row in rows for warning in row["warnings"]]
    lines += ["", "## Warnings the service reported", ""]
    if warnings:
        for example_id, warning in warnings:
            lines.append("- `%s`: %s" % (example_id, warning))
    else:
        lines.append("- none")
    failures = [(row["id"], row["detail"]) for row in rows if row["status"] != "PASS"]
    lines += ["", "## Failures", ""]
    if failures:
        for example_id, detail in failures:
            lines.append("- `%s`: %s" % (example_id, detail))
    else:
        lines.append("- none")

    with open(md_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--examples", default=DEFAULT_EXAMPLES_PATH,
                        help="example set (default: the bundled one)")
    parser.add_argument("--only", default=None,
                        help="run just this example id (an edit's reference chain "
                             "is pulled in and generated too)")
    parser.add_argument("--url", default=None,
                        help="service base URL (default: the configured one)")
    parser.add_argument("--out", default=os.path.join(os.getcwd(), "examples-out"),
                        help="where the generated PNGs are downloaded")
    parser.add_argument("--report", default="examples-report",
                        help="report path prefix; writes <prefix>.json and "
                             "<prefix>.md")
    parser.add_argument("--timeout", type=float, default=1800.0,
                        help="per-request timeout; a first call on a cold cache "
                             "loads ~16 GB of weights")
    args = parser.parse_args(argv)

    entries = load_examples(args.examples)
    validate_examples(entries, path=args.examples)

    client = FluxClient(args.url, timeout=args.timeout)
    os.makedirs(args.out, exist_ok=True)

    # Health first: a service that is not up should say so once, not 27 times.
    try:
        health = client.health()
    except FluxError as exc:
        print("smoke_examples: %s" % exc, file=sys.stderr)
        return exc.exit_code
    print("service %s (engine: %s)"
          % (args.url or client.base_url,
             (health.get("engine") or {}).get("loaded_model") or "nothing loaded"))

    report = {
        "service": args.url or client.base_url,
        "examples_path": os.path.abspath(args.examples),
        "out_dir": os.path.abspath(args.out),
        "offload": config.offload(),
        "ack_noncommercial": config.ack_noncommercial(),
        "health": health,
        "examples": [],
    }

    todo = select(entries, args.only)
    produced = {}  # example id -> local path of its first image, for references
    for entry in todo:
        reference_path = None
        if entry.get("reference"):
            reference_path = produced.get(entry["reference"])
            if reference_path is None:
                row = {"id": entry["id"], "status": "FAIL",
                       "detail": "reference example '%s' produced no frame to "
                                 "edit" % entry["reference"],
                       "model": entry["model"], "modifiers": entry["modifiers"],
                       "vae": entry["vae"], "style": entry["style"],
                       "reference": entry["reference"], "width": entry["width"],
                       "height": entry["height"], "steps": entry["steps"],
                       "guidance": entry["guidance"],
                       "requested_seed": entry["seed"], "edited": True,
                       "what_it_proves": entry["what_it_proves"],
                       "images": [], "warnings": [], "seconds": None}
                report["examples"].append(row)
                print("  %-32s FAIL  %s" % (entry["id"], row["detail"]))
                continue

        row = run_one(client, entry, args.out, reference_path=reference_path)
        report["examples"].append(row)
        if row["images"]:
            produced.setdefault(entry["id"], row["images"][0]["path"])
        print("  %-32s %s  %6ss  %s"
              % (entry["id"], row["status"], row["seconds"], row["detail"]))
        for warning in row["warnings"]:
            print("      warning: %s" % warning)

    report["passed"] = sum(1 for row in report["examples"] if row["status"] == "PASS")
    report["failed"] = len(report["examples"]) - report["passed"]
    json_path = args.report + ".json"
    md_path = args.report + ".md"
    write_reports(report, json_path, md_path)

    print("\n%d example(s): %d PASS, %d FAIL"
          % (len(report["examples"]), report["passed"], report["failed"]))
    print("frames: %s" % args.out)
    print("report: %s, %s" % (json_path, md_path))
    # 5 is the repo's "generation failed", shared with chopshop-sui's bridge: a
    # script that handles one handles the other.
    return 0 if report["failed"] == 0 else 5


if __name__ == "__main__":
    sys.exit(main())
