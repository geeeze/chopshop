#!/usr/bin/env python3
"""Render fractal demonstrations (PNG via numpy, SVG for Sierpinski).

Outputs land in ``demo/`` next to this script.  Mandelbrot/Julia/fern need
numpy (the optional dependency); Sierpinski is stdlib SVG.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from chopshop_plot.fractals import (  # noqa: E402
    render_mandelbrot, render_julia, render_fern, sierpinski_svg,
)

OUT = os.path.dirname(os.path.abspath(__file__))


def main():
    os.makedirs(OUT, exist_ok=True)

    print("rendering mandelbrot (overview)...")
    render_mandelbrot(os.path.join(OUT, "mandelbrot.png"),
                      width=1400, height=1050, max_iter=512)
    print("rendering mandelbrot (seahorse valley zoom)...")
    render_mandelbrot(os.path.join(OUT, "mandelbrot_zoom.png"),
                      width=1400, height=1050, max_iter=1024,
                      xmin=-0.7475, xmax=-0.7395, ymin=0.1274, ymax=0.1334,
                      gamma=0.35)
    print("rendering julia...")
    render_julia(os.path.join(OUT, "julia.png"),
                 width=1000, height=1000, max_iter=512)
    print("rendering barnsley fern...")
    render_fern(os.path.join(OUT, "fern.png"),
                width=900, height=1200, n_points=900_000)

    print("rendering sierpinski (SVG)...")
    with open(os.path.join(OUT, "sierpinski.svg"), "w", encoding="utf-8") as fh:
        fh.write(sierpinski_svg(size=900, depth=7))

    print("done ->", OUT)


if __name__ == "__main__":
    main()
