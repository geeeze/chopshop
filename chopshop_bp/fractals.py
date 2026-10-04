"""Fractals — raster (Mandelbrot, Julia, Barnsley fern) and vector (Sierpinski).

The raster fractals use **numpy** when available (the ONE optional dependency in
this package); the core SVG writer and everything else stay stdlib-only.
Sierpinski is naturally a recursive polygon, so it is emitted as SVG — a fractal
that stays inside the vector contract.

All raster functions return an HxWx3 uint8 array; ``render_*`` wrappers write a
PNG via ``chopshop_bp.png``.
"""

from __future__ import annotations

import math
import random

from . import svg as _svg
from .png import write_rgb_png

__all__ = [
    "mandelbrot", "julia", "barnsley_fern", "sierpinski_svg",
    "render_mandelbrot", "render_julia", "render_fern",
]

# Smooth-colour gradient stops: (position 0..1, (r, g, b)).
_DEFAULT_STOPS = [
    (0.00, (10, 6, 28)),
    (0.18, (28, 60, 140)),
    (0.40, (70, 150, 210)),
    (0.60, (250, 200, 90)),
    (0.80, (205, 70, 40)),
    (1.00, (255, 246, 230)),
]


def _numpy():
    try:
        import numpy as np
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "chopshop_bp.fractals raster needs numpy (pip install numpy)") from exc
    return np


def _colorize(t, stops=None, gamma=1.0):
    """Map a 0..1 escape-time array to RGB via gradient interpolation.

    ``gamma`` < 1 lifts the low end: escape times are dominated by points that
    diverge in a few iterations (smooth ≈ 1..5) while boundary points approach
    ``max_iter``, so a linear map crushes everything into the first gradient
    stop.  A gamma around 0.4 spreads the near-immediate escapes across the
    lower gradient, leaving the slow-escaping boundary detail in the upper end.
    """
    np = _numpy()
    stops = stops or _DEFAULT_STOPS
    t = np.asarray(t, dtype=float)
    if gamma != 1.0:
        t = np.power(t, gamma)
    pos = np.array([p for p, _ in stops])
    cols = np.array([[r, g, b] for _, (r, g, b) in stops], dtype=float)
    rgb = np.empty(t.shape + (3,), dtype=np.uint8)
    for ch in range(3):
        rgb[..., ch] = (np.interp(t, pos, cols[:, ch])).astype(np.uint8)
    return rgb


def _escape_iter(z0, c, max_iter):
    """Iterate z = z^2 + c from z0; return (smooth_iter, interior_mask).

    Smooth iteration count (continuous escape time) gives banding without the
    blocky steps of a raw count.  ``interior`` marks points that never escaped.
    """
    np = _numpy()
    z = np.array(z0, dtype=complex)
    smooth = np.zeros(z.shape, dtype=float)
    alive = np.ones(z.shape, dtype=bool)
    for i in range(max_iter):
        z[alive] = z[alive] * z[alive] + c[alive]
        mag2 = z.real * z.real + z.imag * z.imag
        fled = (mag2 > 4.0) & alive
        if fled.any():
            smooth[fled] = i + 1 - np.log2(np.log(np.sqrt(mag2[fled])))
            alive[fled] = False
    # ``alive`` marks points that never escaped within max_iter = the set's
    # interior.  (Returning ``~alive`` would invert it to the escaped exterior.)
    return smooth, alive


def _complex_grid(width, height, xmin, xmax, ymin, ymax):
    np = _numpy()
    y, x = np.ogrid[0:height, 0:width]
    re = xmin + (xmax - xmin) * x / (width - 1)
    im = ymax - (ymax - ymin) * y / (height - 1)  # y grows downward on screen
    return re + 1j * im


def mandelbrot(width=1000, height=1000, xmin=-2.2, xmax=0.8, ymin=-1.2, ymax=1.2,
               max_iter=256, stops=None, gamma=0.4):
    """Mandelbrot set as an HxWx3 uint8 RGB array (interior black)."""
    np = _numpy()
    c = _complex_grid(width, height, xmin, xmax, ymin, ymax)
    smooth, interior = _escape_iter(np.zeros(c.shape, dtype=complex), c, max_iter)
    rgb = _colorize(smooth / max_iter, stops, gamma=gamma)
    rgb[interior] = (0, 0, 0)
    return rgb


def julia(width=1000, height=1000, c=-0.8 + 0.156j, xmin=-1.6, xmax=1.6,
          ymin=-1.2, ymax=1.2, max_iter=256, stops=None, gamma=0.4):
    """Julia set for constant ``c`` as an HxWx3 uint8 RGB array."""
    np = _numpy()
    cgrid = np.full((height, width), c, dtype=complex)
    z0 = _complex_grid(width, height, xmin, xmax, ymin, ymax)
    smooth, interior = _escape_iter(z0, cgrid, max_iter)
    rgb = _colorize(smooth / max_iter, stops, gamma=gamma)
    rgb[interior] = (0, 0, 0)
    return rgb


_FERN_BOUNDS = (-2.182, 2.655, 0.0, 9.998)


def barnsley_fern(width=800, height=1000, n_points=500_000, seed=0):
    """Barnsley fern via the iterated-function-system, as HxWx3 uint8 RGB."""
    np = _numpy()
    rng = random.Random(seed)
    xmin, xmax, ymin, ymax = _FERN_BOUNDS
    hits = np.zeros((height, width), dtype=np.float32)

    x = y = 0.0
    for _ in range(n_points):
        r = rng.random()
        if r < 0.01:
            x, y = 0.0, 0.16 * y
        elif r < 0.86:
            x, y = 0.85 * x + 0.04 * y, -0.04 * x + 0.85 * y + 1.6
        elif r < 0.93:
            x, y = 0.20 * x - 0.26 * y, 0.23 * x + 0.22 * y + 1.6
        else:
            x, y = -0.15 * x + 0.28 * y, 0.26 * x + 0.24 * y + 0.44
        px = int((x - xmin) / (xmax - xmin) * (width - 1))
        py = int((ymax - y) / (ymax - ymin) * (height - 1))
        if 0 <= px < width and 0 <= py < height:
            hits[py, px] += 1.0

    # log-scaled density -> dark-green gradient
    hits /= hits.max() if hits.max() > 0 else 1.0
    d = np.log1p(hits * 200.0)
    d /= d.max() if d.max() > 0 else 1.0
    rgb = np.zeros((height, width, 3), dtype=np.uint8)
    rgb[..., 1] = (d * 235).astype(np.uint8)
    rgb[..., 0] = (d * 20).astype(np.uint8)
    rgb[..., 2] = (d * 15).astype(np.uint8)
    return rgb


def sierpinski_svg(size=900, depth=7):
    """Sierpinski triangle as SVG — a fractal inside the vector contract."""
    h = size * math.sqrt(3) / 2
    top = (size / 2, 20)
    left = (20, 20 + h)
    right = (size - 20, 20 + h)
    body = []

    def midpoint(p, q):
        return ((p[0] + q[0]) / 2, (p[1] + q[1]) / 2)

    def tri(a, b, c, d):
        if d == 0:
            body.append(_svg.polygon([a, b, c], fill="#141414"))
            return
        ab, bc, ca = midpoint(a, b), midpoint(b, c), midpoint(c, a)
        tri(a, ab, ca, d - 1)
        tri(ab, b, bc, d - 1)
        tri(ca, bc, c, d - 1)

    tri(top, left, right, depth)
    return _svg.svg_document(size, int(20 + h) + 20, body, background="#f4f1ea")


def render_mandelbrot(path, **kw):
    write_rgb_png(path, mandelbrot(**kw))
    return path


def render_julia(path, **kw):
    write_rgb_png(path, julia(**kw))
    return path


def render_fern(path, **kw):
    write_rgb_png(path, barnsley_fern(**kw))
    return path
