"""Tests for the ``digest`` operation: metrics spec -> chart SVG."""

import unittest
import xml.etree.ElementTree as ET

from chopshop_bp import digest
from chopshop_bp.spec import SpecError


def _root(svg_text):
    return ET.fromstring(svg_text)


def _tags(svg_text):
    return {el.tag.rsplit("}", 1)[-1] for el in _root(svg_text).iter()}


class TestDigest(unittest.TestCase):
    def test_bar_chart_renders_bars_and_labels(self):
        spec = {
            "chart": "bar",
            "title": "Scores",
            "data": {"labels": ["a", "b", "c"], "series": [{"name": "score", "values": [1, 2, 3]}]},
        }
        svg_text = digest(spec)
        tags = _tags(svg_text)
        self.assertIn("rect", tags)  # bars + axis fill
        root = _root(svg_text)
        texts = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "text"]
        labels = "".join(el.text or "" for el in texts)
        for expected in ("a", "b", "c", "Scores"):
            self.assertIn(expected, labels)

    def test_bare_values_without_series(self):
        spec = {"chart": "bar", "data": {"labels": ["x", "y"], "values": [3, 4]}}
        svg_text = digest(spec)
        self.assertIn("rect", _tags(svg_text))

    def test_scatter_renders_circles(self):
        spec = {
            "chart": "scatter",
            "data": {"points": [{"x": 0, "y": 0}, {"x": 1, "y": 2}, {"x": 2, "y": 1}]},
        }
        svg_text = digest(spec)
        root = _root(svg_text)
        circles = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "circle"]
        self.assertEqual(len(circles), 3)

    def test_line_renders_polyline(self):
        spec = {
            "chart": "line",
            "data": {"labels": ["a", "b"], "series": [{"values": [1, 2]}]},
        }
        self.assertIn("polyline", _tags(digest(spec)))

    def test_axis_is_auto_scaled_within_canvas(self):
        # Values far above the default would clip if not scaled; check bars stay
        # inside the plotted width.
        spec = {
            "chart": "bar",
            "size": {"width": 800, "height": 400},
            "data": {"labels": ["a", "b"], "values": [1000, 2000]},
        }
        root = _root(digest(spec))
        bars = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "rect"]
        for bar in bars:
            self.assertLessEqual(float(bar.get("x")) + float(bar.get("width")), 800)

    def test_legend_order_matches_series_order(self):
        spec = {
            "chart": "bar",
            "data": {"labels": ["a"], "series": [
                {"name": "first", "values": [1]},
                {"name": "second", "values": [2]},
            ]},
        }
        root = _root(digest(spec))
        legend = [
            (float(el.get("x")), el.text)
            for el in root.iter()
            if el.tag.rsplit("}", 1)[-1] == "text" and el.text in ("first", "second")
        ]
        legend.sort()
        self.assertEqual([name for _, name in legend], ["first", "second"])

    def test_output_is_well_formed_xml(self):
        spec = {
            "chart": "bar",
            "title": "T",
            "data": {"labels": ["a"], "values": [1]},
        }
        ET.fromstring(digest(spec))

    def test_unknown_chart_rejected(self):
        with self.assertRaises(SpecError):
            digest({"chart": "pie", "data": {"labels": ["a"], "values": [1]}})

    def test_missing_data_rejected(self):
        with self.assertRaises(SpecError):
            digest({"chart": "bar"})

    def test_non_numeric_values_rejected(self):
        with self.assertRaises(SpecError):
            digest({"chart": "bar", "data": {"labels": ["a"], "values": ["high"]}})


if __name__ == "__main__":
    unittest.main()
