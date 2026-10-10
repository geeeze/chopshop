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


class TestGenerateText(unittest.TestCase):
    """The ``text`` element: a label on the shapes generate already draws.

    chopshop-bp#10 -- generate could draw every shape an architecture diagram
    needs but could not LABEL any of them, so the whole labelled-diagram class
    was unreachable. The rendering primitive (svg.text) already existed and was
    tested by tree/log/digest; this adds the vocabulary entry and dispatch.
    """

    def _spec(self, element):
        return {"canvas": {"width": 320, "height": 160}, "elements": [element]}

    def test_text_renders_its_content(self):
        svg_text = generate(self._spec(
            {"type": "text", "x": 80, "y": 75, "content": "API Server"}))
        root = _root(svg_text)
        texts = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "text"]
        self.assertEqual(len(texts), 1)
        self.assertEqual(texts[0].text, "API Server")
        # x/y are placed, y being the baseline as SVG defines it.
        self.assertEqual(texts[0].get("x"), "80")
        self.assertEqual(texts[0].get("y"), "75")

    def test_text_anchor_and_font_styling_pass_through(self):
        svg_text = generate(self._spec({
            "type": "text", "x": 240, "y": 75, "content": "Database",
            "fill": "#e2e8f0", "font_size": 14, "anchor": "middle",
            "font_family": "monospace",
        }))
        text_el = [el for el in _root(svg_text).iter()
                   if el.tag.rsplit("}", 1)[-1] == "text"][0]
        self.assertEqual(text_el.get("text-anchor"), "middle")
        self.assertEqual(text_el.get("font-size"), "14")
        self.assertEqual(text_el.get("fill"), "#e2e8f0")
        self.assertEqual(text_el.get("font-family"), "monospace")

    def test_text_defaults_font_size_and_omits_unset_anchor(self):
        # No anchor given -> SVG default (start), so the attribute is absent
        # rather than a spurious value; no font_size -> the 12 primitive default.
        svg_text = generate(self._spec(
            {"type": "text", "x": 5, "y": 5, "content": "hi"}))
        text_el = [el for el in _root(svg_text).iter()
                   if el.tag.rsplit("}", 1)[-1] == "text"][0]
        self.assertIsNone(text_el.get("text-anchor"))
        self.assertEqual(text_el.get("font-size"), "12")

    def test_a_labelled_diagram_renders_labels_beside_shapes(self):
        # The whole point of #10: a box AND its words, in one document.
        svg_text = generate({
            "canvas": {"width": 320, "height": 160},
            "elements": [
                {"type": "rect", "x": 20, "y": 40, "width": 120, "height": 60,
                 "rx": 6, "fill": "#1e293b", "stroke": "#38bdf8", "stroke_width": 2},
                {"type": "text", "x": 80, "y": 75, "content": "API Server",
                 "fill": "#e2e8f0", "font_size": 14, "anchor": "middle"},
            ],
        })
        self.assertIn("API Server", svg_text)

    def test_missing_content_rejected(self):
        with self.assertRaises(SpecError):
            generate(self._spec({"type": "text", "x": 1, "y": 1}))

    def test_numeric_content_rejected_by_name(self):
        # A number where a label belongs is a caller error, not a silent
        # str() coercion that would render "42" from an int meant as a
        # coordinate -- the same rule _check_display_strings enforces for
        # tree/log, now stated for generate too.
        with self.assertRaises(SpecError) as ctx:
            generate(self._spec({"type": "text", "x": 1, "y": 1, "content": 42}))
        self.assertIn("must be a string", str(ctx.exception))

    def test_unknown_field_on_text_rejected(self):
        with self.assertRaises(SpecError):
            generate(self._spec(
                {"type": "text", "x": 1, "y": 1, "content": "x", "stroke": "#000"}))


if __name__ == "__main__":
    unittest.main()
