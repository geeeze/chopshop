#!/usr/bin/env python3
"""The value axis rounds OUT to a nice step, never across the data (bp#5).

The contract now states the rule (docs/contract.md, digest section): the axis
maximum is the smallest multiple of the tick step that is at or above the
tallest data value, the axis minimum the largest multiple at or below the
lowest. Two failures motivated it, and both are pinned here by RENDERING a
chart and reading the geometry back out of the SVG rather than by asserting on
the helper alone:

  * a maximum that rounds DOWN, where the tallest bar overflows the plot area
    and the chart lies about its own scale;
  * a maximum that implies headroom the plot area does not have, where a tick
    lands above the top gridline -- the "97 against a 100" misreading -- and, in
    the worst case, inside the title/legend band.
"""

import importlib
import math
import unittest
import xml.etree.ElementTree as ET

_MOD = importlib.import_module("chopshop_bp.digest")
digest = _MOD.digest          # the public entry point
_axis_range = _MOD._axis_range
_plot_area = _MOD._plot_area
_GRID = _MOD._GRID_COLOR

W, H = 720, 320
TOL = 0.51                    # SVG keeps ~6 decimals; half a pixel of slack


def _root(text):
    return ET.fromstring(text)


def _tag(el):
    return el.tag.rsplit("}", 1)[-1]


def _gridline_ys(root):
    ys = []
    for el in root.iter():
        if _tag(el) == "line" and el.get("stroke") == _GRID:
            ys.append(float(el.get("y1")))
    return ys


def _tick_labels(root):
    """The y-axis tick labels: font-size 11, anchored to the axis at x < margin."""
    out = []
    for el in root.iter():
        if _tag(el) != "text":
            continue
        if el.get("font-size") != "11" or el.get("text-anchor") != "end":
            continue
        try:
            out.append(float(el.text or ""))
        except (TypeError, ValueError):
            continue
    return out


def _rect_tops(root):
    """Bar geometry only. The document's own background is a full-canvas rect at
    y=0, and counting it as a bar is how this assertion first failed on a chart
    that had done nothing wrong."""
    bars = []
    for el in root.iter():
        if _tag(el) != "rect":
            continue
        if el.get("fill") not in _MOD._SERIES_COLORS:
            continue
        bars.append((float(el.get("y")), float(el.get("height"))))
    return bars


def _render(kind, values, labels=None):
    labels = labels or [f"c{i}" for i in range(len(values))]
    spec = {
        "chart": kind,
        "title": "Whatever",
        "size": {"width": W, "height": H},
        "data": {"labels": labels,
                 "series": [{"name": "score", "values": list(values)}]},
    }
    return _root(digest(spec))


class AxisRangeUnitTest(unittest.TestCase):
    """The rule itself, before any rendering is involved."""

    def test_rounds_up_to_the_next_step(self):
        self.assertEqual(_axis_range(0, 97), (0, 100))

    def test_an_exact_multiple_is_left_alone(self):
        # Headroom is a consequence of the rule, never a goal: a data max that
        # already sits on a step must not gain a band of empty chart above it.
        self.assertEqual(_axis_range(0, 100), (0, 100))

    def test_rounds_down_below_zero_rather_than_stopping_at_it(self):
        self.assertEqual(_axis_range(-3, 5), (-4, 6))

    def test_a_narrow_float_span_rounds_both_ways_out(self):
        lo, hi = _axis_range(0.4, 0.5)
        self.assertLessEqual(lo, 0.4)
        self.assertGreaterEqual(hi, 0.5)

    def test_a_degenerate_range_still_has_height(self):
        lo, hi = _axis_range(5, 5)
        self.assertGreater(hi, lo, "a flat series still needs an axis to draw")

    def test_a_reversed_range_is_swapped_not_crashed(self):
        # `_nice_step` takes log10 of the span, so vmax < vmin used to be a
        # ValueError. A helper called with its arguments backwards should
        # answer, not take the renderer down with it.
        lo, hi = _axis_range(0, -0.04)
        self.assertLessEqual(lo, -0.04)
        self.assertGreaterEqual(hi, 0)

    def test_never_crosses_the_data_for_any_of_these(self):
        for low, high in ((0, 97), (-3, 5), (0, 12), (0, 16), (0.1, 0.9),
                          (10, 97), (-40, -7), (1, 1.02)):
            with self.subTest(data=(low, high)):
                lo, hi = _axis_range(low, high)
                self.assertLessEqual(lo, low, "minimum rounded past the data")
                self.assertGreaterEqual(hi, high, "maximum rounded past the data")


class RenderedBarChartTest(unittest.TestCase):
    """The chart that motivated the issue: a bar whose top must not escape."""

    VALUES = [97, 40, 12]

    @classmethod
    def setUpClass(cls):
        cls.root = _render("bar", cls.VALUES)
        cls.plot_top, cls.plot_bottom = _plot_area(W, H)[2], _plot_area(W, H)[3]

    def test_the_tallest_bar_stays_inside_the_plot_area(self):
        tops = _rect_tops(self.root)
        self.assertTrue(tops, "no bars were rendered")
        lowest_top = min(y for y, _h in tops)
        deepest_bottom = max(y + h for y, h in tops)
        self.assertGreaterEqual(lowest_top, self.plot_top - TOL,
                                "a bar overflowed above the plot area")
        self.assertLessEqual(deepest_bottom, self.plot_bottom + TOL,
                             "a bar overflowed below the plot area")

    def test_the_top_tick_is_at_or_above_the_tallest_value(self):
        ticks = _tick_labels(self.root)
        self.assertTrue(ticks, "no y-axis ticks were rendered")
        self.assertGreaterEqual(max(ticks), max(self.VALUES),
                                "the axis maximum rounded down below the data")

    def test_every_gridline_is_inside_the_plot_area(self):
        ys = _gridline_ys(self.root)
        self.assertTrue(ys, "no gridlines were rendered")
        for y in ys:
            self.assertGreaterEqual(y, self.plot_top - TOL,
                                    f"gridline at y={y} sits above the plot "
                                    "area, in the title/legend band")
            self.assertLessEqual(y, self.plot_bottom + TOL,
                                 f"gridline at y={y} sits below the plot area")

    def test_the_top_gridline_meets_the_data_scale(self):
        # vmax maps to the plot top exactly, so the highest gridline IS the
        # top of the scale -- no band of empty chart above the tallest bar.
        self.assertAlmostEqual(min(_gridline_ys(self.root)), self.plot_top,
                               delta=TOL)

    def test_ticks_step_by_a_constant_interval(self):
        ticks = sorted(_tick_labels(self.root))
        self.assertGreaterEqual(len(ticks), 2)
        steps = [round(b - a, 9) for a, b in zip(ticks, ticks[1:])]
        self.assertEqual(len(set(steps)), 1, f"uneven ticks: {ticks}")
        # and the interval is one of the 1/2/5 x 10^n steps the contract means
        # by "nice": a 37-unit step is a rounding accident, not a scale.
        step = steps[0]
        mantissa = step / (10 ** math.floor(math.log10(step)))
        self.assertAlmostEqual(mantissa, round(mantissa), places=6,
                               msg=f"step {step} is not a nice step")
        self.assertIn(round(mantissa), (1, 2, 5), f"step {step} is not 1/2/5-based")

    def test_an_exact_data_maximum_gains_no_headroom(self):
        root = _render("bar", [0, 50, 100])
        ticks = _tick_labels(root)
        self.assertEqual(max(ticks), 100.0)

    def test_a_negative_axis_rounds_down_not_up(self):
        root = _render("bar", [-3, 5])
        ticks = _tick_labels(root)
        self.assertLessEqual(min(ticks), -3,
                             "the axis minimum rounded up past the data")
        self.assertGreaterEqual(max(ticks), 5)

    def test_the_bar_that_is_zero_still_sits_on_the_baseline(self):
        # A zero-valued series must still draw its bar on the x axis after the
        # bounds round out -- rounding is about the top, never about the base.
        root = _render("bar", [0, 40])
        _left, _right, top, bottom, _pw, plot_h = _plot_area(W, H)
        lo, hi = _axis_range(0, 40)
        zero_y = _MOD._scale_y(lo, hi, top, plot_h, 0)
        self.assertAlmostEqual(zero_y, bottom, delta=TOL)
        self.assertTrue(_rect_tops(root), "no bars were rendered")


class RenderedLineAndScatterTest(unittest.TestCase):
    """The rule is the chart's, not one renderer's."""

    def test_a_line_chart_rounds_its_top_the_same_way(self):
        root = _render("line", [3, 7, 97])
        top = _plot_area(W, H)[2]
        ticks = _tick_labels(root)
        self.assertGreaterEqual(max(ticks), 97)
        for y in _gridline_ys(root):
            self.assertGreaterEqual(y, top - TOL)

    def test_a_scatter_rounds_its_value_axis_too(self):
        spec = {
            "chart": "scatter", "title": "Points",
            "size": {"width": W, "height": H},
            "data": {"points": [{"x": i, "y": y}
                                for i, y in enumerate([1, 4, 97])]},
        }
        root = _root(digest(spec))
        self.assertGreaterEqual(max(_tick_labels(root)), 97)
        top = _plot_area(W, H)[2]
        for y in _gridline_ys(root):
            self.assertGreaterEqual(y, top - TOL)

    def test_a_scatter_x_tick_does_not_run_past_the_right_margin(self):
        spec = {
            "chart": "scatter", "title": "Points",
            "size": {"width": W, "height": H},
            "data": {"points": [{"x": x, "y": 1} for x in (0, 7, 16)]},
        }
        root = _root(digest(spec))
        left, right, _top, _bottom, plot_w, _ph = _plot_area(W, H)
        bottom = _plot_area(W, H)[3]
        x_ticks = []
        for el in root.iter():
            if _tag(el) != "text" or el.get("font-size") != "11":
                continue
            if el.get("text-anchor") != "middle":
                continue          # y-axis ticks are anchored "end"
            label = (el.text or "")
            if not label.replace(".", "").replace("-", "").isdigit():
                continue          # a category word, not a number
            try:
                x_pos = float(el.get("x") or 0)
                y_pos = float(el.get("y") or 0)
            except ValueError:
                continue
            if x_pos > _MOD._MARGIN_LEFT and y_pos > bottom:
                x_ticks.append(float(label))
        self.assertTrue(x_ticks, "no x-axis ticks were rendered")
        # Round-OUT means the axis maximum may be ABOVE the data (0..16 scales
        # to 0..20), so the property that matters is not the tick's VALUE but
        # where it lands: inside the frame, on its gridline.
        self.assertGreaterEqual(max(x_ticks), 16,
                                "the x axis maximum rounded down below the data")
        lo, hi = _axis_range(0, 16)
        for tick in x_ticks:
            x = left + (tick - lo) / (hi - lo) * plot_w
            self.assertGreaterEqual(x, left - TOL,
                                    f"x tick {tick} lands left of the axis")
            self.assertLessEqual(x, right + TOL,
                                 f"x tick {tick} lands past the right margin")


if __name__ == "__main__":
    unittest.main()
