"""Tests for the ``generate`` operation: geometry spec -> SVG."""

import unittest
import xml.etree.ElementTree as ET

from chopshop_bp import generate
from chopshop_bp.spec import SpecError

NS = {"s": "http://www.w3.org/2000/svg"}


def _root(svg_text):
    return ET.fromstring(svg_text)


class TestGenerate(unittest.TestCase):
    def test_rect_circle_polygon_path_all_render(self):
        spec = {
            "canvas": {"width": 1000, "height": 1000, "background": "#ffffff"},
            "elements": [
                {"type": "rect", "x": 10, "y": 10, "width": 100, "height": 50},
                {"type": "circle", "cx": 200, "cy": 200, "r": 40},
                {"type": "ellipse", "cx": 300, "cy": 300, "rx": 20, "ry": 30},
                {"type": "polygon", "points": [[0, 0], [10, 0], [5, 10]]},
                {"type": "polyline", "points": [[0, 0], [5, 5]], "stroke": "#000"},
                {"type": "line", "x1": 0, "y1": 0, "x2": 5, "y2": 5, "stroke": "#000"},
                {"type": "path", "d": "M 0 0 L 5 5"},
            ],
        }
        svg_text = generate(spec)
        root = _root(svg_text)
        tags = {el.tag.rsplit("}", 1)[-1] for el in root.iter()}
        for expected in ("rect", "circle", "ellipse", "polygon", "polyline", "line", "path"):
            self.assertIn(expected, tags)

    def test_canvas_size_and_viewbox(self):
        svg_text = generate({"canvas": {"width": 640, "height": 480}, "elements": []})
        root = _root(svg_text)
        self.assertEqual(root.get("width"), "640")
        self.assertEqual(root.get("height"), "480")
        self.assertEqual(root.get("viewBox"), "0 0 640 480")

    def test_tiling_repeats_element_across_grid(self):
        spec = {
            "canvas": {"width": 500, "height": 500},
            "elements": [],
            "tiling": {
                "grid": [3, 2],
                "cell": [100, 100],
                "origin": [10, 10],
                "element": {"type": "circle", "cx": 50, "cy": 50, "r": 10, "fill": "#333"},
            },
        }
        svg_text = generate(spec)
        root = _root(svg_text)
        circles = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "circle"]
        self.assertEqual(len(circles), 6)

    def test_tiling_offset_moves_elements(self):
        spec = {
            "canvas": {"width": 500, "height": 500},
            "tiling": {
                "grid": [2, 1],
                "cell": [100, 100],
                "origin": [50, 0],
                "element": {"type": "circle", "cx": 0, "cy": 0, "r": 5},
            },
        }
        root = _root(generate(spec))
        circles = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "circle"]
        cxs = sorted(float(c.get("cx")) for c in circles)
        self.assertEqual(cxs, [50.0, 150.0])

    def test_output_is_well_formed_xml(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [
                {"type": "rect", "x": 0, "y": 0, "width": 10, "height": 10, "fill": "#fff"},
                {"type": "circle", "cx": 5, "cy": 5, "r": 2, "stroke": "#000", "stroke_width": 1},
            ],
        }
        ET.fromstring(generate(spec))  # raises if malformed

    def test_accepts_json_string(self):
        import json

        svg_text = generate(json.dumps({"canvas": {"width": 1, "height": 1}, "elements": []}))
        self.assertIn("<svg", svg_text)

    def test_unknown_element_type_rejected(self):
        with self.assertRaises(SpecError):
            generate({"canvas": {"width": 1, "height": 1}, "elements": [{"type": "spiral"}]})

    def test_missing_canvas_rejected(self):
        with self.assertRaises(SpecError):
            generate({"elements": []})

    def test_bad_points_rejected(self):
        with self.assertRaises(SpecError):
            generate({
                "canvas": {"width": 1, "height": 1},
                "elements": [{"type": "polygon", "points": [[0, 0], "not-a-pair"]}],
            })


if __name__ == "__main__":
    unittest.main()
