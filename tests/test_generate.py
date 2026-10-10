"""Tests for the ``generate`` operation: geometry spec -> SVG."""

import unittest
import xml.etree.ElementTree as ET

from chopshop_bp import generate, svg
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

    # ------------------------------------------------------------------
    # text element
    # ------------------------------------------------------------------

    def test_text_happy_path(self):
        spec = {
            "canvas": {"width": 200, "height": 100},
            "elements": [
                {"type": "text", "x": 10, "y": 20, "content": "hello"},
            ],
        }
        svg_text = generate(spec)
        root = _root(svg_text)
        texts = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "text"]
        self.assertEqual(len(texts), 1)
        self.assertEqual(texts[0].get("x"), "10")
        self.assertEqual(texts[0].get("y"), "20")
        self.assertEqual(texts[0].text, "hello")

    def test_text_all_optional_fields(self):
        spec = {
            "canvas": {"width": 200, "height": 100},
            "elements": [
                {"type": "text", "x": 5, "y": 15, "content": "label",
                 "fill": "#ff0000", "font_size": 14, "anchor": "middle",
                 "font_family": "serif", "opacity": 0.5},
            ],
        }
        svg_text = generate(spec)
        root = _root(svg_text)
        texts = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "text"]
        self.assertEqual(len(texts), 1)
        self.assertEqual(texts[0].get("fill"), "#ff0000")
        self.assertEqual(texts[0].get("font-size"), "14")
        self.assertEqual(texts[0].get("text-anchor"), "middle")
        self.assertEqual(texts[0].get("font-family"), "serif")
        self.assertEqual(texts[0].get("fill-opacity"), "0.5")

    def test_text_default_font_size(self):
        spec = {
            "canvas": {"width": 200, "height": 100},
            "elements": [{"type": "text", "x": 1, "y": 2, "content": "x"}],
        }
        root = _root(generate(spec))
        texts = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "text"]
        self.assertEqual(texts[0].get("font-size"), "12")

    def test_text_default_fill(self):
        spec = {
            "canvas": {"width": 200, "height": 100},
            "elements": [{"type": "text", "x": 1, "y": 2, "content": "x"}],
        }
        root = _root(generate(spec))
        texts = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "text"]
        self.assertEqual(texts[0].get("fill"), "#000000")

    def test_text_content_must_be_string(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "text", "x": 1, "y": 2, "content": 123}],
            })
        self.assertIn("content", str(ctx.exception))

    def test_text_anchor_must_be_valid(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "text", "x": 1, "y": 2, "content": "x",
                              "anchor": "top"}],
            })
        self.assertIn("anchor", str(ctx.exception))

    def test_text_anchor_all_valid_values(self):
        for anchor in ("start", "middle", "end"):
            spec = {
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "text", "x": 1, "y": 2, "content": "x",
                              "anchor": anchor}],
            }
            root = _root(generate(spec))
            texts = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "text"]
            self.assertEqual(texts[0].get("text-anchor"), anchor)

    def test_text_opacity_clamped(self):
        # Above 1.0 clamps to 1.0
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [{"type": "text", "x": 1, "y": 2, "content": "x",
                          "opacity": 1.5}],
        }
        root = _root(generate(spec))
        texts = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "text"]
        self.assertEqual(texts[0].get("fill-opacity"), "1")

        # Below 0.0 clamps to 0.0
        spec["elements"][0]["opacity"] = -0.5
        root = _root(generate(spec))
        texts = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "text"]
        self.assertEqual(texts[0].get("fill-opacity"), "0")

    def test_text_unknown_field_rejected(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "text", "x": 1, "y": 2, "content": "x",
                              "colour": "#fff"}],
            })
        self.assertIn("colour", str(ctx.exception))

    def test_text_missing_required_fields(self):
        with self.assertRaises(SpecError):
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "text", "x": 1}],
            })

    def test_text_font_size_must_be_positive(self):
        # M2: a non-positive font-size is not a smaller label, it is invisible
        # text. Every other size in the contract is bounded positive.
        for bad in (0, -5, -0.5):
            with self.assertRaises(SpecError) as ctx:
                generate({
                    "canvas": {"width": 100, "height": 100},
                    "elements": [{"type": "text", "x": 1, "y": 2, "content": "x",
                                  "font_size": bad}],
                })
            self.assertIn("font_size", str(ctx.exception))

    def test_text_font_size_positive_accepted(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [{"type": "text", "x": 1, "y": 2, "content": "x",
                          "font_size": 0.5}],
        }
        root = _root(generate(spec))
        texts = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "text"]
        self.assertEqual(texts[0].get("font-size"), "0.5")

    # ------------------------------------------------------------------
    # stroke_dasharray
    # ------------------------------------------------------------------

    def test_dasharray_string_comma_separated(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10, "height": 10,
                          "stroke": "#000", "stroke_width": 1, "stroke_dasharray": "8,4"}],
        }
        root = _root(generate(spec))
        rects = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "rect"]
        self.assertEqual(rects[0].get("stroke-dasharray"), "8,4")

    def test_dasharray_string_space_separated(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [{"type": "circle", "cx": 5, "cy": 5, "r": 2,
                          "stroke": "#000", "stroke_width": 1, "stroke_dasharray": "8 4"}],
        }
        root = _root(generate(spec))
        circles = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "circle"]
        self.assertEqual(circles[0].get("stroke-dasharray"), "8 4")

    def test_dasharray_list_form(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [{"type": "line", "x1": 0, "y1": 0, "x2": 10, "y2": 10,
                          "stroke": "#000", "stroke_width": 1, "stroke_dasharray": [8, 4]}],
        }
        root = _root(generate(spec))
        lines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "line"]
        self.assertEqual(lines[0].get("stroke-dasharray"), "8,4")

    def test_dasharray_on_all_shape_types(self):
        for etype, extra in (
            ("rect", {"x": 0, "y": 0, "width": 10, "height": 10}),
            ("circle", {"cx": 5, "cy": 5, "r": 2}),
            ("ellipse", {"cx": 5, "cy": 5, "rx": 3, "ry": 2}),
            ("polygon", {"points": [[0, 0], [10, 0], [5, 10]]}),
            ("line", {"x1": 0, "y1": 0, "x2": 10, "y2": 10}),
        ):
            spec = {
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": etype, **extra,
                              "stroke": "#000", "stroke_width": 1,
                              "stroke_dasharray": "5,3"}],
            }
            root = _root(generate(spec))
            shapes = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == etype]
            self.assertEqual(shapes[0].get("stroke-dasharray"), "5,3", f"{etype} missing dasharray")

    def test_dasharray_zero_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10, "height": 10,
                              "stroke_dasharray": "8,0"}],
            })
        self.assertIn("stroke_dasharray", str(ctx.exception))

    def test_dasharray_negative_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10, "height": 10,
                              "stroke_dasharray": [8, -4]}],
            })
        self.assertIn("stroke_dasharray", str(ctx.exception))

    def test_dasharray_non_numeric_string_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10, "height": 10,
                              "stroke_dasharray": "8,abc"}],
            })
        self.assertIn("stroke_dasharray", str(ctx.exception))

    def test_dasharray_non_numeric_list_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10, "height": 10,
                              "stroke_dasharray": [8, "four"]}],
            })
        self.assertIn("stroke_dasharray", str(ctx.exception))

    def test_dasharray_wrong_type_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10, "height": 10,
                              "stroke_dasharray": 8}],
            })
        self.assertIn("stroke_dasharray", str(ctx.exception))

    def test_dasharray_not_on_path(self):
        # path: the 'd' string is path data, and a dash pattern on a path is
        # not part of this contract — refused rather than emitted as a style.
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "path", "d": "M 0 0 L 10 10",
                              "stroke_dasharray": "8,4"}],
            })
        self.assertIn("stroke_dasharray", str(ctx.exception))

    # -- non-finite and non-canonical tokens (H2) -------------------------
    # Every one of these parses as a number in Python and used to reach the
    # SVG stroke-dasharray attribute verbatim. float('inf') and float('nan')
    # are numbers; float('1e400') is inf; float('1_0') is 10.0 (a Python
    # underscore literal). SVG accepts none of them.

    def test_dasharray_inf_string_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10,
                              "height": 10, "stroke_dasharray": "8,inf"}],
            })
        self.assertIn("stroke_dasharray", str(ctx.exception))

    def test_dasharray_nan_string_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10,
                              "height": 10, "stroke_dasharray": "nan,4"}],
            })
        self.assertIn("stroke_dasharray", str(ctx.exception))

    def test_dasharray_overflow_exponent_string_refused(self):
        # float('1e400') parses to inf without raising — the regex is what
        # keeps it out, not the parse.
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10,
                              "height": 10, "stroke_dasharray": "1e400,4"}],
            })
        self.assertIn("stroke_dasharray", str(ctx.exception))

    def test_dasharray_underscore_literal_string_refused(self):
        # float('1_0') == 10.0: a Python literal that is not an SVG number.
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10,
                              "height": 10, "stroke_dasharray": "1_0,4"}],
            })
        self.assertIn("stroke_dasharray", str(ctx.exception))

    def test_dasharray_inf_in_list_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10,
                              "height": 10, "stroke_dasharray": [float("inf"), 4]}],
            })
        self.assertIn("stroke_dasharray", str(ctx.exception))

    def test_dasharray_nan_in_list_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10,
                              "height": 10, "stroke_dasharray": [float("nan"), 4]}],
            })
        self.assertIn("stroke_dasharray", str(ctx.exception))

    def test_dasharray_canonical_tokens_accepted(self):
        # The canonical forms the contract names, including a bare integer
        # and a bare decimal point form, pass through untouched.
        for dash in ("8,4", "8 4", "8", ".5", "0.5", "8, 4"):
            spec = {
                "canvas": {"width": 100, "height": 100},
                "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10,
                              "height": 10, "stroke_dasharray": dash}],
            }
            root = _root(generate(spec))
            rects = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "rect"]
            self.assertEqual(rects[0].get("stroke-dasharray"), dash)

    def test_polyline_dasharray_rendered(self):
        # L1: a polyline takes a stroke_dasharray on the same terms as a line.
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [{"type": "polyline", "points": [[0, 0], [10, 10], [20, 0]],
                          "stroke": "#000", "stroke_width": 2,
                          "stroke_dasharray": "5,3"}],
        }
        root = _root(generate(spec))
        polylines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "polyline"]
        self.assertEqual(polylines[0].get("stroke-dasharray"), "5,3")

    def test_polyline_dasharray_list_form_rendered(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [{"type": "polyline", "points": [[0, 0], [10, 10]],
                          "stroke": "#000", "stroke_width": 2,
                          "stroke_dasharray": [5, 3]}],
        }
        root = _root(generate(spec))
        polylines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "polyline"]
        self.assertEqual(polylines[0].get("stroke-dasharray"), "5,3")

    # ------------------------------------------------------------------
    # marker field (arrowheads on line / polyline)
    # ------------------------------------------------------------------

    def test_line_marker_end(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [
                {"type": "line", "x1": 10, "y1": 10, "x2": 50, "y2": 10,
                 "stroke": "#ff0000", "stroke_width": 3, "marker": "end"},
            ],
        }
        root = _root(generate(spec))
        lines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "line"]
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0].get("marker-end"), f"url(#{svg.marker_id('#ff0000', 3)})")
        self.assertIsNone(lines[0].get("marker-start"))
        defs = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "defs"]
        self.assertEqual(len(defs), 1)
        markers = [el for el in defs[0] if el.tag.rsplit("}", 1)[-1] == "marker"]
        self.assertEqual(len(markers), 1)
        self.assertEqual(markers[0].get("id"), svg.marker_id("#ff0000", 3))
        self.assertEqual(markers[0].get("orient"), "auto")
        # The marker path fill matches the line's stroke colour.
        path = markers[0][0]
        self.assertEqual(path.get("fill"), "#ff0000")

    def test_line_marker_start(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [
                {"type": "line", "x1": 10, "y1": 10, "x2": 50, "y2": 10,
                 "stroke": "#00ff00", "marker": "start"},
            ],
        }
        root = _root(generate(spec))
        lines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "line"]
        self.assertEqual(lines[0].get("marker-start"), f"url(#{svg.marker_id('#00ff00', 2)})")
        self.assertIsNone(lines[0].get("marker-end"))

    def test_line_marker_both(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [
                {"type": "line", "x1": 10, "y1": 10, "x2": 50, "y2": 10,
                 "stroke": "#0000ff", "marker": "both"},
            ],
        }
        root = _root(generate(spec))
        lines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "line"]
        mid = svg.marker_id("#0000ff", None)
        self.assertEqual(lines[0].get("marker-start"), f"url(#{mid})")
        self.assertEqual(lines[0].get("marker-end"), f"url(#{mid})")

    def test_line_marker_none_no_marker_attrs(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [
                {"type": "line", "x1": 10, "y1": 10, "x2": 50, "y2": 10,
                 "stroke": "#000", "marker": "none"},
            ],
        }
        root = _root(generate(spec))
        lines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "line"]
        self.assertIsNone(lines[0].get("marker-start"))
        self.assertIsNone(lines[0].get("marker-end"))
        # No defs emitted when marker is 'none'.
        defs = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "defs"]
        self.assertEqual(len(defs), 0)

    def test_line_no_marker_no_defs(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [
                {"type": "line", "x1": 10, "y1": 10, "x2": 50, "y2": 10,
                 "stroke": "#000"},
            ],
        }
        root = _root(generate(spec))
        lines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "line"]
        self.assertIsNone(lines[0].get("marker-start"))
        self.assertIsNone(lines[0].get("marker-end"))
        defs = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "defs"]
        self.assertEqual(len(defs), 0)

    def test_polyline_marker_end(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [
                {"type": "polyline", "points": [[0, 0], [50, 50], [100, 0]],
                 "stroke": "#ff0000", "stroke_width": 4, "marker": "end"},
            ],
        }
        root = _root(generate(spec))
        polylines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "polyline"]
        self.assertEqual(len(polylines), 1)
        self.assertEqual(polylines[0].get("marker-end"), f"url(#{svg.marker_id('#ff0000', 4)})")
        self.assertIsNone(polylines[0].get("marker-start"))
        defs = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "defs"]
        self.assertEqual(len(defs), 1)
        markers = [el for el in defs[0] if el.tag.rsplit("}", 1)[-1] == "marker"]
        self.assertEqual(len(markers), 1)
        path = markers[0][0]
        self.assertEqual(path.get("fill"), "#ff0000")

    def test_polyline_marker_start(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [
                {"type": "polyline", "points": [[0, 0], [50, 50]],
                 "stroke": "#00ff00", "marker": "start"},
            ],
        }
        root = _root(generate(spec))
        polylines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "polyline"]
        self.assertEqual(polylines[0].get("marker-start"), f"url(#{svg.marker_id('#00ff00', 2)})")
        self.assertIsNone(polylines[0].get("marker-end"))

    def test_polyline_marker_both(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [
                {"type": "polyline", "points": [[0, 0], [50, 50], [100, 0]],
                 "stroke": "#0000ff", "marker": "both"},
            ],
        }
        root = _root(generate(spec))
        polylines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "polyline"]
        mid = svg.marker_id("#0000ff", None)
        self.assertEqual(polylines[0].get("marker-start"), f"url(#{mid})")
        self.assertEqual(polylines[0].get("marker-end"), f"url(#{mid})")

    def test_polyline_marker_none(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [
                {"type": "polyline", "points": [[0, 0], [50, 50]],
                 "stroke": "#000", "marker": "none"},
            ],
        }
        root = _root(generate(spec))
        polylines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "polyline"]
        self.assertIsNone(polylines[0].get("marker-start"))
        self.assertIsNone(polylines[0].get("marker-end"))
        defs = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "defs"]
        self.assertEqual(len(defs), 0)

    def test_marker_invalid_value_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [
                    {"type": "line", "x1": 0, "y1": 0, "x2": 10, "y2": 10,
                     "stroke": "#000", "marker": "middle"},
                ],
            })
        self.assertIn("marker", str(ctx.exception))

    def test_marker_on_rect_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [
                    {"type": "rect", "x": 0, "y": 0, "width": 10, "height": 10,
                     "marker": "end"},
                ],
            })
        self.assertIn("marker", str(ctx.exception))

    def test_marker_on_circle_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [
                    {"type": "circle", "cx": 50, "cy": 50, "r": 10,
                     "marker": "end"},
                ],
            })
        self.assertIn("marker", str(ctx.exception))

    def test_marker_on_ellipse_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [
                    {"type": "ellipse", "cx": 50, "cy": 50, "rx": 20, "ry": 10,
                     "marker": "end"},
                ],
            })
        self.assertIn("marker", str(ctx.exception))

    def test_marker_on_polygon_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [
                    {"type": "polygon", "points": [[0, 0], [10, 0], [5, 10]],
                     "marker": "end"},
                ],
            })
        self.assertIn("marker", str(ctx.exception))

    def test_marker_on_path_refused(self):
        with self.assertRaises(SpecError) as ctx:
            generate({
                "canvas": {"width": 100, "height": 100},
                "elements": [
                    {"type": "path", "d": "M 0 0 L 10 10", "marker": "end"},
                ],
            })
        self.assertIn("marker", str(ctx.exception))

    def test_same_stroke_and_width_share_one_marker_def(self):
        """Two connectors with the SAME stroke and stroke_width share one def."""
        spec = {
            "canvas": {"width": 200, "height": 100},
            "elements": [
                {"type": "line", "x1": 10, "y1": 10, "x2": 50, "y2": 10,
                 "stroke": "#ff0000", "stroke_width": 3, "marker": "end"},
                {"type": "polyline", "points": [[0, 50], [50, 50], [100, 50]],
                 "stroke": "#ff0000", "stroke_width": 3, "marker": "start"},
            ],
        }
        root = _root(generate(spec))
        defs = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "defs"]
        self.assertEqual(len(defs), 1)
        markers = [el for el in defs[0] if el.tag.rsplit("}", 1)[-1] == "marker"]
        self.assertEqual(len(markers), 1)
        # Both elements reference the same marker id.
        lines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "line"]
        polylines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "polyline"]
        self.assertEqual(lines[0].get("marker-end"),
                         f"url(#{svg.marker_id('#ff0000', 3)})")
        self.assertEqual(polylines[0].get("marker-start"),
                         f"url(#{svg.marker_id('#ff0000', 3)})")

    def test_marker_size_follows_stroke_width(self):
        """The marker definition size reflects the element's stroke_width."""
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [
                {"type": "line", "x1": 10, "y1": 10, "x2": 50, "y2": 10,
                 "stroke": "#000", "stroke_width": 1, "marker": "end"},
            ],
        }
        root = _root(generate(spec))
        defs = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "defs"]
        markers = [el for el in defs[0] if el.tag.rsplit("}", 1)[-1] == "marker"]
        # stroke_width=1 → ref = max(min(1*3, 12), 1) = 3 (below clamp boundary)
        self.assertEqual(markers[0].get("markerWidth"), "3")

    def test_each_connectors_arrowhead_uses_its_own_stroke_and_width(self):
        """H1 regression: each connector's head matches its OWN stroke/width.

        A document with a red sw=3 line and a blue sw=6 line must emit two
        <marker> definitions — one red sized for sw=3, one blue sized for
        sw=6 — and each line must reference its own. Before the fix, both
        arrowheads rendered in the LAST marker-carrying element's colour and
        size (docs/contract.md: "The arrowhead is drawn in the element's own
        stroke colour, sized from stroke_width").
        """
        spec = {
            "canvas": {"width": 200, "height": 100},
            "elements": [
                {"type": "line", "x1": 10, "y1": 10, "x2": 50, "y2": 10,
                 "stroke": "#ff0000", "stroke_width": 3, "marker": "end"},
                {"type": "line", "x1": 10, "y1": 50, "x2": 50, "y2": 50,
                 "stroke": "#0000ff", "stroke_width": 6, "marker": "end"},
            ],
        }
        root = _root(generate(spec))
        lines = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "line"]
        self.assertEqual(len(lines), 2)
        red_mid = svg.marker_id("#ff0000", 3)
        blue_mid = svg.marker_id("#0000ff", 6)
        self.assertEqual(lines[0].get("marker-end"), f"url(#{red_mid})")
        self.assertEqual(lines[1].get("marker-end"), f"url(#{blue_mid})")

        defs = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "defs"]
        self.assertEqual(len(defs), 1)
        markers = {m.get("id"): m for m in defs[0]
                   if m.tag.rsplit("}", 1)[-1] == "marker"}
        self.assertEqual(set(markers), {red_mid, blue_mid})
        # Red head: fill #ff0000, size follows sw=3 (ref = 3*3 = 9)
        red_path = markers[red_mid][0]
        self.assertEqual(red_path.get("fill"), "#ff0000")
        self.assertEqual(markers[red_mid].get("markerWidth"), "9")
        # Blue head: fill #0000ff, size follows sw=6 (ref = min(6*3, 12) = 12)
        blue_path = markers[blue_mid][0]
        self.assertEqual(blue_path.get("fill"), "#0000ff")
        self.assertEqual(markers[blue_mid].get("markerWidth"), "12")

    def test_marker_default_stroke_width(self):
        """When stroke_width is absent, the marker uses a sane default."""
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [
                {"type": "line", "x1": 10, "y1": 10, "x2": 50, "y2": 10,
                 "stroke": "#000", "marker": "end"},
            ],
        }
        root = _root(generate(spec))
        defs = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "defs"]
        markers = [el for el in defs[0] if el.tag.rsplit("}", 1)[-1] == "marker"]
        # Default stroke_width=2 → ref = min(2*3, 12) = 6
        self.assertEqual(markers[0].get("markerWidth"), "6")

    def test_marker_well_formed_xml(self):
        spec = {
            "canvas": {"width": 100, "height": 100},
            "elements": [
                {"type": "line", "x1": 10, "y1": 10, "x2": 50, "y2": 10,
                 "stroke": "#ff0000", "stroke_width": 3, "marker": "end"},
                {"type": "polyline", "points": [[0, 50], [50, 50]],
                 "stroke": "#00ff00", "marker": "both"},
            ],
        }
        ET.fromstring(generate(spec))  # raises if malformed


if __name__ == "__main__":
    unittest.main()
