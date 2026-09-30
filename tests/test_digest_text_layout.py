#!/usr/bin/env python3
"""Prove the digest text-layout fixes, since the box has no pytest.

The renderers return an SVG markup STRING, so every assertion here reads the
emitted geometry out of the markup with a regex rather than inspecting element
dicts.
"""

import importlib
import re
import sys

sys.path.insert(0, "/home/unodos/chopshop-bp")
digest = importlib.import_module("chopshop_plot.digest")

failures = []
R = digest._RENDERERS

# <text x="12" y="34" ... font-size="11" ...>label</text>  (attribute order varies)
TEXT_RE = re.compile(r'<text\b([^>]*)>(.*?)</text>', re.S)
ATTR_RE = re.compile(r'([a-zA-Z-]+)\s*=\s*"([^"]*)"')


def texts(parts):
    """[(attrs_dict, label)] for every <text> across a list of markup strings.

    The renderers return a LIST of markup strings (one per element), not a
    single document and not element dicts -- both of which this got wrong first.
    """
    if isinstance(parts, str):
        parts = [parts]
    out = []
    for chunk in parts:
        if not isinstance(chunk, str):
            continue
        for attrs, label in TEXT_RE.findall(chunk):
            out.append((dict(ATTR_RE.findall(attrs)), label))
    return out


def by_font(parts, size):
    return [(a, l) for a, l in texts(parts) if a.get("font-size") == str(size)]


def check(name, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"  -- {detail}" if detail else ""))
    if not cond:
        failures.append(name)


print("case 1: title and legend on separate baselines?")
spec = {
    "kind": "line",
    "title": "Server CPU over time",
    "canvas": {"width": 720, "height": 320},
    "data": {"labels": [f"t{i}" for i in range(6)],
             "series": [{"name": "cpu", "points": [[i, i * 2] for i in range(6)]},
                        {"name": "memory", "points": [[i, 10 - i] for i in range(6)]}]},
}
svg = R["line"](spec, 720, 320)
title = by_font(svg, 15)
legend = by_font(svg, 10)
check("title rendered once", len(title) == 1, f"got {len(title)}")
check("legend rendered for 2 series", len(legend) == 2, f"got {len(legend)}")
if title and legend:
    ty = float(title[0][0]["y"])
    lys = [float(a["y"]) for a, _ in legend]
    check("no title/legend baseline collision", all(abs(ty - ly) > 8 for ly in lys),
          f"title y={ty}, legend y={lys}")

print("case 2: long legend name stays inside the frame?")
# Two shapes: one that genuinely has to be truncated, one where the full name
# fits and must be left alone. The first draft of this check only had the
# roomy case, so it asserted an ellipsis that correctly never appeared.
for label, want_ellipsis in [
    # 200 chars: at ~0.62em/char and font_size 10 that is ~1240px against a
    # ~640px budget, so it MUST be truncated. The first draft used a 58-char
    # name that genuinely fit and then asserted an ellipsis that was correct
    # never to appear.
    ("extremely-long-series-name-" + "x" * 200, True),
    ("cpu", False),
]:
    spec2 = dict(spec)
    spec2["data"] = {"labels": [f"t{i}" for i in range(6)],
                     "series": [{"name": label, "points": [[i, i] for i in range(6)]},
                                {"name": "second", "points": [[i, i] for i in range(6)]}]}
    svg2 = R["line"](spec2, 720, 320)
    leg2 = by_font(svg2, 10)
    check(f"both legend entries emitted ({label[:18]}...)", len(leg2) == 2, f"got {len(leg2)}")
    if not leg2:
        continue
    edges = [float(a["x"]) - 12 - digest._text_width(l, 10) for a, l in leg2]
    check("no legend glyph crosses the left margin",
          all(e >= digest._MARGIN_LEFT - 1 for e in edges),
          f"leftmost edge={min(edges):.1f}px, margin={digest._MARGIN_LEFT}px")
    got_ell = any("\u2026" in l for _, l in leg2)
    check(f"ellipsis {'present' if want_ellipsis else 'absent (name fits)'} as expected",
          got_ell == want_ellipsis, f"labels={[l for _, l in leg2]}")

print("case 3: crowded categorical axis thins instead of overprinting?")
n = 40
spec3 = {
    "kind": "bar",
    "title": "Crowded categories",
    "canvas": {"width": 720, "height": 320},
    "data": {"labels": [f"category-number-{i:02d}" for i in range(n)],
             "series": [{"name": "count", "values": [i for i in range(n)]}]},
}
svg3 = R["bar"](spec3, 720, 320)
# Only the CATEGORY axis: the y-axis ticks are also font-size 11 but anchored
# "end" at x < _MARGIN_LEFT. The first draft swept those in with an unfiltered
# font-size match and then measured a y tick ("40") against an x label, which
# is not an overlap at all.
axis = [(a, l) for a, l in by_font(svg3, 11)
        if a.get("text-anchor") == "middle" and float(a["x"]) > digest._MARGIN_LEFT]
check("fewer labels kept than categories", 0 < len(axis) < n,
      f"kept {len(axis)} of {n} category labels")
check("y-axis ticks excluded from the category set",
      all(not l.replace(".", "").isdigit() for _, l in axis),
      f"labels={[l for _, l in axis][:3]}...")
if len(axis) > 1:
    pts = sorted((float(a["x"]), l) for a, l in axis)
    worst = None
    for i in range(len(pts) - 1):
        (x1, l1), (x2, l2) = pts[i], pts[i + 1]
        need = (digest._text_width(l1, 11) + digest._text_width(l2, 11)) / 2
        slack = (x2 - x1) - need
        if worst is None or slack < worst[0]:
            worst = (slack, l1, l2)
    check("no adjacent kept labels overlap", worst[0] >= 0,
          f"tightest pair {worst[1]!r}/{worst[2]!r} slack={worst[0]:.1f}px")

print("case 4: plot area clears both header bands")
left, right, top, bottom, pw, ph = digest._plot_area(720, 320)
check("plot top clears the legend band (y=40)", top > 40, f"top={top}")
check("plot still has usable height", ph > 100, f"plot_h={ph}")
check("title fits the frame width",
      digest._text_width("Server CPU over time", 15) < 720 - 2 * digest._MARGIN_RIGHT)

print()
if failures:
    print(f"RESULT: {len(failures)} FAILED: {failures}")
    sys.exit(1)
print("RESULT: all checks passed")
