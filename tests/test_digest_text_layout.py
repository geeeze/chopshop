#!/usr/bin/env python3
"""The digest text-layout assertions, as tests rather than as a script (bp#8).

What was wrong, because it is the reason this file exists in this shape:

  * It defined no `test_*` and no `TestCase`, so `python3 -m unittest discover
    -s tests` — the command in README and AGENTS.md — imported it, found
    nothing, and reported nothing about it. The 144 lines of assertions ran as
    an IMPORT SIDE EFFECT, printed PASS/FAIL lines into every run, and
    `sys.exit(1)` at the bottom aborted discovery outright when a check failed.
    Checks that cannot fail a green suite are not tests.
  * It did `sys.path.insert(0, …)` with an ABSOLUTE HOST PATH — the only one
    in the repo's code (repeated here only as a shape, not as the address), and
    the direct opposite of AGENTS.md's "host-agnostic; no absolute paths" rule.
    Discovery from the repo root already puts the package on the path, so the
    insert was both wrong and unnecessary.

The assertions themselves are kept: they read the emitted geometry back out of
the SVG markup with a regex, because the renderers return markup STRINGS, not
element dicts.
"""

import importlib
import re
import unittest

_DIGEST = importlib.import_module("chopshop_bp.digest")
digest = _DIGEST
R = _DIGEST._RENDERERS

# <text x="12" y="34" ... font-size="11" ...>label</text>  (attribute order varies)
TEXT_RE = re.compile(r"<text\b([^>]*)>(.*?)</text>", re.S)
ATTR_RE = re.compile(r'([a-zA-Z-]+)\s*=\s*"([^"]*)"')


def texts(parts):
    """[(attrs_dict, label)] for every <text> across a list of markup strings.

    The renderers return a LIST of markup strings (one per element), not a
    single document and not element dicts — both of which this got wrong first.
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


def base_spec():
    return {
        "kind": "line",
        "title": "Server CPU over time",
        "canvas": {"width": 720, "height": 320},
        "data": {"labels": [f"t{i}" for i in range(6)],
                 "series": [{"name": "cpu", "points": [[i, i * 2] for i in range(6)]},
                            {"name": "memory", "points": [[i, 10 - i] for i in range(6)]}]},
    }


class TitleAndLegendLayoutTest(unittest.TestCase):
    def test_title_and_legend_render_on_separate_baselines(self):
        svg = R["line"](base_spec(), 720, 320)
        title = by_font(svg, 15)
        legend = by_font(svg, 10)
        self.assertEqual(len(title), 1, f"title rendered {len(title)} times")
        self.assertEqual(len(legend), 2, f"legend rendered {len(legend)} entries")

        title_y = float(title[0][0]["y"])
        legend_ys = [float(a["y"]) for a, _ in legend]
        for ly in legend_ys:
            self.assertGreater(abs(title_y - ly), 8,
                               f"title y={title_y} overprints legend y={ly}")


class LongLegendNameTest(unittest.TestCase):
    def test_a_long_name_is_truncated_and_a_short_one_is_left_alone(self):
        # Two shapes on purpose: one that MUST be ellipsised and one that fits.
        # The first draft only had the roomy case, so it asserted an ellipsis
        # that correctly never appeared. 200 chars is ~1240px of glyph against
        # a ~640px budget, so truncation is forced; "cpu" must be left alone.
        spec = base_spec()
        for label, want_ellipsis in [
            ("extremely-long-series-name-" + "x" * 200, True),
            ("cpu", False),
        ]:
            with self.subTest(label=label[:24], want_ellipsis=want_ellipsis):
                spec["data"] = {
                    "labels": [f"t{i}" for i in range(6)],
                    "series": [{"name": label, "points": [[i, i] for i in range(6)]},
                               {"name": "second", "points": [[i, i] for i in range(6)]}],
                }
                svg = R["line"](spec, 720, 320)
                legend = by_font(svg, 10)
                self.assertEqual(len(legend), 2,
                                 f"expected both entries, got {len(legend)}")
                if not legend:
                    continue
                edges = [float(a["x"]) - 12 - digest._text_width(l, 10)
                         for a, l in legend]
                self.assertTrue(
                    all(e >= digest._MARGIN_LEFT - 1 for e in edges),
                    f"a legend glyph crosses the left margin: {edges} "
                    f"(margin {digest._MARGIN_LEFT}px)")
                got_ellipsis = any("\u2026" in l for _, l in legend)
                self.assertEqual(got_ellipsis, want_ellipsis,
                                 f"labels={[l for _, l in legend]}")


class CrowdedCategoryAxisTest(unittest.TestCase):
    def test_a_crowded_axis_thins_instead_of_overprinting(self):
        n = 40
        spec = {
            "kind": "bar",
            "title": "Crowded categories",
            "canvas": {"width": 720, "height": 320},
            "data": {"labels": [f"category-number-{i:02d}" for i in range(n)],
                     "series": [{"name": "count", "values": list(range(n))}]},
        }
        svg = R["bar"](spec, 720, 320)
        # Only the CATEGORY axis: the y-axis ticks are also font-size 11 but
        # anchored "end" at x < _MARGIN_LEFT. The first draft swept those in
        # and then measured a y tick ("40") against an x label — not an overlap
        # at all.
        axis = [(a, l) for a, l in by_font(svg, 11)
                if a.get("text-anchor") == "middle"
                and float(a["x"]) > digest._MARGIN_LEFT]
        self.assertTrue(0 < len(axis) < n,
                        f"kept {len(axis)} of {n} category labels")
        self.assertTrue(
            all(not l.replace(".", "").isdigit() for _, l in axis),
            f"y-axis ticks leaked into the category set: "
            f"{[l for _, l in axis][:3]}")
        if len(axis) > 1:
            points = sorted((float(a["x"]), l) for a, l in axis)
            worst_slack = min(
                (x2 - x1) - (digest._text_width(l1, 11)
                             + digest._text_width(l2, 11)) / 2
                for (x1, l1), (x2, l2) in zip(points, points[1:]))
            self.assertGreaterEqual(
                worst_slack, 0,
                f"the tightest kept pair overlaps by {-worst_slack:.1f}px")


class PlotAreaGeometryTest(unittest.TestCase):
    def test_the_plot_area_clears_both_header_bands(self):
        left, right, top, bottom, plot_w, plot_h = digest._plot_area(720, 320)
        self.assertGreater(top, 40, "the plot starts inside the legend band")
        self.assertGreater(plot_h, 100, "the plot has no usable height")
        self.assertLess(digest._text_width("Server CPU over time", 15),
                        720 - 2 * digest._MARGIN_RIGHT,
                        "the title does not fit the frame")


if __name__ == "__main__":
    unittest.main()
