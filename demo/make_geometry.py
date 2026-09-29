#!/usr/bin/env python3
"""Generate a gallery of cool-geometry SVGs using the chopshop_plot operations.

Outputs land in ``demo/`` next to this script. Pure stdlib — the SVG writer
plus ``math``/``colorsys``.
"""

import colorsys
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from chopshop_plot import svg  # noqa: E402

OUT = os.path.dirname(os.path.abspath(__file__))


def _hex(r, g, b):
    return "#%02x%02x%02x" % (int(r * 255), int(g * 255), int(b * 255))


def _hue(i, n, s=0.85, v=1.0):
    t = i / max(1, n - 1)
    return _hex(*colorsys.hsv_to_rgb(t, s, v))


def _rot(p, cx, cy, ang):
    x, y = p
    dx, dy = x - cx, y - cy
    c, s = math.cos(ang), math.sin(ang)
    return (cx + dx * c - dy * s, cy + dx * s + dy * c)


# --- 1. Phyllotaxis (golden-angle sunflower spiral) -------------------------
def phyllotaxis(n=1400, size=1000, dot=2.4, spread=8.5):
    cx = cy = size / 2
    body = []
    for i in range(n):
        ang = i * math.radians(137.5)
        r = spread * math.sqrt(i)
        x = cx + r * math.cos(ang)
        y = cy + r * math.sin(ang)
        if 0 <= x < size and 0 <= y < size:
            body.append(svg.circle(x, y, dot, fill=_hue(i, n)))
    return svg.svg_document(size, size, body, background="#0b0b12")


# --- 2. Mandala (rotated petal motif) ---------------------------------------
def mandala(petals=18, size=1000, center=None):
    cx = cy = (center or size // 2)
    body = []
    for k in range(petals):
        ang = k * 2 * math.pi / petals
        inner = _rot((cx, cy - 90), cx, cy, ang)
        tip = _rot((cx, cy - 400), cx, cy, ang)
        lc = _rot((cx - 105, cy - 250), cx, cy, ang)
        rc = _rot((cx + 105, cy - 250), cx, cy, ang)
        fill = _hue(k, petals, s=0.75, v=0.95)
        d = (f"M {inner[0]:.2f} {inner[1]:.2f} "
             f"Q {lc[0]:.2f} {lc[1]:.2f} {tip[0]:.2f} {tip[1]:.2f} "
             f"Q {rc[0]:.2f} {rc[1]:.2f} {inner[0]:.2f} {inner[1]:.2f} Z")
        body.append(svg.path(d, fill=fill, stroke="#0b0b12", stroke_width=1))
    for r in (70, 160, 260, 360):
        body.append(svg.circle(cx, cy, r, fill="none",
                               stroke="#0b0b12", stroke_width=2))
    body.append(svg.circle(cx, cy, 34, fill="#0b0b12"))
    return svg.svg_document(size, size, body, background="#14121c")


# --- 3. Recursive tree ------------------------------------------------------
def tree(size=1000, depth=11, branch=170, spread=0.42):
    body = []

    def grow(x, y, theta, length, d):
        if d == 0:
            body.append(svg.circle(x, y, 3, fill="#9adf7f"))
            return
        x2 = x + length * math.cos(theta)
        y2 = y - length * math.sin(theta)
        w = max(1.0, d * 0.9)
        body.append(svg.line(x, y, x2, y2, stroke="#5b3a29", stroke_width=w))
        grow(x2, y2, theta + spread, length * 0.72, d - 1)
        grow(x2, y2, theta - spread, length * 0.72, d - 1)

    grow(size / 2, size - 60, math.pi / 2, branch, depth)
    return svg.svg_document(size, size, body, background="#f2efe6")


# --- 4. Koch snowflake ------------------------------------------------------
def koch(size=1000, depth=5):
    def segment(p, q, d, out):
        if d == 0:
            out.append(q)
            return
        dx = (q[0] - p[0]) / 3
        dy = (q[1] - p[1]) / 3
        a = (p[0] + dx, p[1] + dy)
        b = (p[0] + 2 * dx, p[1] + 2 * dy)
        # midpoint of the middle third
        m = (p[0] + 1.5 * dx, p[1] + 1.5 * dy)
        # equilateral peak: perpendicular to the segment, height sqrt(3)/2 * |third|
        peak = (m[0] - dy * math.sqrt(3) / 2, m[1] + dx * math.sqrt(3) / 2)
        segment(p, a, d - 1, out)
        segment(a, peak, d - 1, out)
        segment(peak, b, d - 1, out)
        segment(b, q, d - 1, out)

    cx = cy = size / 2
    r = size * 0.42
    pts = [(cx + r * math.cos(math.radians(90 + 120 * i)),
            cy - r * math.sin(math.radians(90 + 120 * i))) for i in range(3)]
    poly = [pts[0]]
    for i in range(3):
        segment(pts[i], pts[(i + 1) % 3], depth, poly)
    body = [svg.polygon(poly, fill="#0d1321", stroke="#eaf2ff", stroke_width=1.5)]
    return svg.svg_document(size, size, body, background="#eaf2ff")


# --- 5. Lissajous curves ----------------------------------------------------
def lissajous(size=1000):
    cx = cy = size / 2
    scale = size * 0.40
    body = []
    for (a, b, delta, color) in [
        (3, 4, 0.0, "#e05d5d"),
        (5, 6, math.pi / 4, "#3f8efc"),
        (7, 8, math.pi / 3, "#43b581"),
    ]:
        pts = []
        n = 1600
        for i in range(n + 1):
            t = 2 * math.pi * i / n
            x = cx + scale * math.sin(a * t + delta)
            y = cy + scale * math.sin(b * t)
            pts.append((x, y))
        body.append(svg.polyline(pts, stroke=color, stroke_width=2.2))
    return svg.svg_document(size, size, body, background="#0e0f13")


# --- 6. String art (circle envelope) ----------------------------------------
def string_art(size=1000, n=90, k=19):
    cx = cy = size / 2
    r = size * 0.46
    pts = [(cx + r * math.cos(2 * math.pi * i / n),
            cy + r * math.sin(2 * math.pi * i / n)) for i in range(n)]
    body = []
    for i in range(n):
        j = (i * k) % n
        body.append(svg.line(pts[i][0], pts[i][1], pts[j][0], pts[j][1],
                             stroke=_hue(i, n, s=0.6, v=0.95), stroke_width=0.7))
    return svg.svg_document(size, size, body, background="#0a0a0f")


GENERATORS = {
    "phyllotaxis.svg": phyllotaxis,
    "mandala.svg": mandala,
    "tree.svg": tree,
    "koch.svg": koch,
    "lissajous.svg": lissajous,
    "stringart.svg": string_art,
}


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, gen in GENERATORS.items():
        path = os.path.join(OUT, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(gen())
        print("wrote", path)


if __name__ == "__main__":
    main()
