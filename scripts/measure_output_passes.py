#!/usr/bin/env python3
"""Measure the output-side passes on a REAL raster. Not a test.

``scripts/smoke.py`` needs the GPU; this needs Pillow and nothing else — it never
loads a model, so it can measure a frame that already exists on any machine. That
is the point: "the frame came out flat" is a claim, and ``colors_before`` /
``colors_present`` / ``pixels_moved`` / the mean absolute pixel difference are
numbers.

    python3 scripts/measure_output_passes.py some-frame.png [another.png ...]

Point it at a generated PNG to answer "what does the cap actually do to THIS
frame", and at a photographic or tonal reference to see the worst case. It prints
one block per file; nothing is ranked, and no verdict on the art is offered.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from chopshop_flux.postprocess import Frame, isolate_background, reduce_colors  # noqa: E402


def frame_of(path: str) -> Frame:
    from PIL import Image

    with Image.open(path) as image:
        if image.mode not in ("RGB", "RGBA"):
            image = image.convert("RGB")
        return Frame(image.mode, image.width, image.height, image.tobytes())


def mean_absolute_difference(left: Frame, right: Frame) -> float:
    """The metric, named: the mean absolute difference over every channel value."""
    return (sum(abs(a - b) for a, b in zip(left.data, right.data))
            / len(left.data))


def report(path: str) -> None:
    source = frame_of(path)
    print("%s" % path)
    print("  %s %dx%d  %d distinct colour(s)"
          % (source.mode, source.width, source.height, source.color_count()))
    for mode, caps in (("quantize", (16, 6, 3)), ("posterize", (16, 8))):
        for cap in caps:
            reduced, info = reduce_colors(source, cap, mode)
            if info["changed"] is False:
                print("  ink_cap %-9s cap %3d -> skipped (%s)"
                      % (mode, cap, info["note"]))
                continue
            print("  ink_cap %-9s cap %3d -> %d colour(s), mean abs pixel diff %.2f"
                  % (mode, cap, info["colors_present"],
                     mean_absolute_difference(source, reduced)))
    keyed, info = isolate_background(source, "key")
    if info["uniform"]:
        print("  background key -> %s x %d pixel(s) moved (mean abs pixel diff "
              "%.2f overall)" % (info["key_color"], info["pixels_moved"],
                                 mean_absolute_difference(source, keyed)))
    else:
        print("  background key -> %s (%d distinct border colours)"
              % (info["note"], info["border_colors"]))
    _flattened, info = isolate_background(source, "white")
    print("  background white -> %d transparent pixel(s), changed=%s"
          % (info["transparent_pixels"], info["changed"]))
    print()


def main(argv) -> int:
    if not argv:
        print(__doc__)
        return 2
    for path in argv:
        if not os.path.isfile(path):
            print("no such file: %s" % path)
            return 2
        report(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
