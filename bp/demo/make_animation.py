#!/usr/bin/env python3
"""Animated time-series: cumulative metrics over a sequence of runs.

Renders N SVG frames (a fixed-axis line chart where the data accumulates
frame-by-frame), rasterises each with Inkscape, and stitches them into an MP4
and a GIF with ffmpeg. The frames use the same `chopshop_bp.svg` helpers as
the chart operations, but the axes are FIXED so the growing line does not rescale.

Outputs: ``demo/animation.mp4``, ``demo/animation.gif`` (plus ``frames/``).
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from chopshop_bp import svg  # noqa: E402

OUT = os.path.dirname(os.path.abspath(__file__))
FRAMES = os.path.join(OUT, "frames")

W, H = 800, 500
MARGIN_L, MARGIN_R, MARGIN_T, MARGIN_B = 60, 20, 50, 50
N_RUNS = 36


def _series():
    """Synthetic run history -> two cumulative 0..1 series.

    ``pass`` is a cumulative pass rate converging to ~0.85; ``ink`` a cumulative
    normalised ink coverage converging to ~0.55.  Both are monotone-ish walks so
    the animation reads as convergence, not noise.
    """
    import random
    rng = random.Random(7)
    passes = 0
    ink_total = 0.0
    pass_hist, ink_hist = [], []
    for i in range(N_RUNS):
        passes += 1 if rng.random() < 0.85 else 0
        ink = rng.uniform(0.30, 0.80)
        ink_total += ink
        pass_hist.append(passes / (i + 1))
        ink_hist.append(ink_total / (i + 1) / 1.0)
    # normalise ink into ~0..1 by its own max
    m = max(ink_hist)
    ink_hist = [v / m for v in ink_hist]
    return pass_hist, ink_hist


def _frame(k, pass_hist, ink_hist):
    left = MARGIN_L
    right = W - MARGIN_R
    top = MARGIN_T
    bottom = H - MARGIN_B
    pw, ph = right - left, bottom - top
    parts = []

    parts.append(svg.text(W / 2, 26, "Cumulative metrics over runs",
                          fill="#111111", font_size=17, anchor="middle"))

    # grid + y ticks (0..1, fixed)
    for v in (0.0, 0.25, 0.5, 0.75, 1.0):
        y = bottom - v * ph
        parts.append(svg.line(left, y, right, y, stroke="#e8e8e8", stroke_width=1))
        parts.append(svg.text(left - 8, y + 4, f"{v:.2f}", fill="#666",
                              font_size=11, anchor="end"))
    # x ticks (run index)
    for i in range(0, N_RUNS, 6):
        x = left + i / (N_RUNS - 1) * pw
        parts.append(svg.line(x, bottom, x, bottom + 4, stroke="#333", stroke_width=1))
        parts.append(svg.text(x, bottom + 18, str(i + 1), fill="#666",
                              font_size=11, anchor="middle"))
    # axis box
    parts.append(svg.line(left, top, left, bottom, stroke="#333", stroke_width=1))
    parts.append(svg.line(left, bottom, right, bottom, stroke="#333", stroke_width=1))

    def line_pts(series, n):
        return [[left + i / (N_RUNS - 1) * pw, bottom - series[i] * ph]
                for i in range(n)]

    # ink series first (under), then pass series
    parts.append(svg.polyline(line_pts(ink_hist, k + 1), stroke="#f58518", stroke_width=3))
    parts.append(svg.polyline(line_pts(pass_hist, k + 1), stroke="#4c78a8", stroke_width=3))

    # legend
    parts.append(svg.rect(right - 110, top - 26, 10, 10, fill="#4c78a8"))
    parts.append(svg.text(right - 95, top - 16, "pass rate", fill="#333", font_size=11))
    parts.append(svg.rect(right - 110, top - 10, 10, 10, fill="#f58518"))
    parts.append(svg.text(right - 95, top, "ink cov.", fill="#333", font_size=11))

    # progress caption
    parts.append(svg.text(left, bottom + 42, f"run {k + 1} / {N_RUNS}",
                          fill="#111111", font_size=13))
    return svg.svg_document(W, H, parts, background="#ffffff")


def main():
    os.makedirs(FRAMES, exist_ok=True)
    pass_hist, ink_hist = _series()

    for k in range(N_RUNS):
        svg_path = os.path.join(FRAMES, f"frame_{k:03d}.svg")
        png_path = os.path.join(FRAMES, f"frame_{k:03d}.png")
        with open(svg_path, "w", encoding="utf-8") as fh:
            fh.write(_frame(k, pass_hist, ink_hist))
        subprocess.run(
            ["inkscape", "--export-type=png", "--export-width=800",
             "--export-height=500", f"--export-filename={png_path}", svg_path],
            check=True, capture_output=True)
        print(f"frame {k + 1}/{N_RUNS}")

    mp4 = os.path.join(OUT, "animation.mp4")
    gif = os.path.join(OUT, "animation.gif")
    subprocess.run(["ffmpeg", "-y", "-framerate", "12",
                    "-i", os.path.join(FRAMES, "frame_%03d.png"),
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", mp4],
                   check=True, capture_output=True)
    subprocess.run(["ffmpeg", "-y", "-framerate", "12",
                    "-i", os.path.join(FRAMES, "frame_%03d.png"),
                    "-vf", "split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
                    gif], check=True, capture_output=True)
    print("wrote", mp4, "and", gif)


if __name__ == "__main__":
    main()
