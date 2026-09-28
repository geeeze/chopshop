"""Tests for the query-shaped engine: run records + chart spec -> SVG."""

import unittest
import xml.etree.ElementTree as ET

from chopshop_plot import query
from chopshop_plot.query import QueryError, validate_query

from fixtures import two_source_two_recipe_runs, make_candidate, make_run


def _tags(svg_text):
    return {el.tag.rsplit("}", 1)[-1] for el in ET.fromstring(svg_text).iter()}


class TestValidateQuery(unittest.TestCase):
    def test_scatter_requires_numeric_axes(self):
        with self.assertRaises(QueryError):
            validate_query({"chart": "scatter", "x": "preset", "y": "mae_art"})
        with self.assertRaises(QueryError):
            validate_query({"chart": "scatter", "x": "mae_art"})  # missing y

    def test_scatter_valid(self):
        validate_query({"chart": "scatter", "x": "node_count_max", "y": "mae_art",
                        "color": "fidelity_verdict"})

    def test_unknown_chart(self):
        with self.assertRaises(QueryError):
            validate_query({"chart": "pie"})

    def test_diff_selector_validation(self):
        with self.assertRaises(QueryError):
            validate_query({"chart": "diff", "left": {"candidate_id": "x"},
                            "right": {}})
        validate_query({"chart": "diff",
                        "left": {"recipe_hash": "r", "source_sha256": "s"},
                        "right": {"candidate_id": "c"}})


class TestScatter(unittest.TestCase):
    def test_scatter_renders_points_for_every_candidate(self):
        runs = two_source_two_recipe_runs()
        svg_text = query(runs, {"chart": "scatter", "x": "node_count_max",
                                "y": "mae_art"})
        root = ET.fromstring(svg_text)
        circles = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "circle"]
        # 4 candidates, 4 points
        self.assertEqual(len(circles), 4)

    def test_scatter_colour_by_categorical(self):
        runs = two_source_two_recipe_runs()
        svg_text = query(runs, {"chart": "scatter", "x": "node_count_max",
                                "y": "mae_art", "color": "preset"})
        self.assertIn("circle", _tags(svg_text))

    def test_missing_axis_value_skips_point(self):
        # A candidate with no fidelity still renders (its point is simply absent).
        runs = [make_run("s", "a" * 64, [
            make_candidate("c1", preset="x", speckle=0, hier=False, mae_art=None),
            make_candidate("c2", preset="x", speckle=1, hier=False, mae_art=0.01),
        ])]
        svg_text = query(runs, {"chart": "scatter", "x": "node_count_max",
                                "y": "mae_art"})
        root = ET.fromstring(svg_text)
        circles = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "circle"]
        self.assertEqual(len(circles), 1)

    def test_output_is_well_formed(self):
        svg_text = query(two_source_two_recipe_runs(),
                         {"chart": "scatter", "x": "hard", "y": "mae"})
        ET.fromstring(svg_text)


class TestPareto(unittest.TestCase):
    def test_pareto_marks_nondominated(self):
        runs = [make_run("s", "a" * 64, [
            # dominated, non-dominated mix
            make_candidate("c1", preset="p", speckle=0, hier=False,
                           nodes_max=10, mae_art=0.1),
            make_candidate("c2", preset="p", speckle=1, hier=False,
                           nodes_max=20, mae_art=0.05),
            make_candidate("c3", preset="p", speckle=2, hier=False,
                           nodes_max=30, mae_art=0.5),
        ])]
        svg_text = query(runs, {"chart": "pareto", "x": "node_count_max",
                                "y": "mae_art"})
        root = ET.fromstring(svg_text)
        circles = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "circle"]
        frontier = [c for c in circles if c.get("fill") == "#111111"]
        dominated = [c for c in circles if c.get("fill") == "#9aa5b1"]
        # c1 (10, 0.1) and c2 (20, 0.05) are non-dominated; c3 (30, 0.5) is
        # dominated by both.
        self.assertEqual(len(frontier), 2)
        self.assertEqual(len(dominated), 1)
        # the dominated one is the rightmost (largest node_count_max = c3)
        self.assertEqual(max(float(c.get("cx")) for c in dominated),
                         max(float(c.get("cx")) for c in circles))

    def test_pareto_well_formed(self):
        svg_text = query(two_source_two_recipe_runs(),
                         {"chart": "pareto", "x": "hard", "y": "mae_art"})
        ET.fromstring(svg_text)


class TestDiff(unittest.TestCase):
    def test_diff_by_candidate_id(self):
        runs = two_source_two_recipe_runs()
        svg_text = query(runs, {"chart": "diff",
                                "left": {"candidate_id": "a1"},
                                "right": {"candidate_id": "a2"}})
        root = ET.fromstring(svg_text)
        texts = [el.text for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "text"]
        joined = " ".join(t for t in texts if t)
        self.assertIn("a1", joined)
        self.assertIn("a2", joined)
        self.assertIn("mae_art", joined)

    def test_diff_by_recipe_on_source(self):
        from chopshop_plot.metrics import recipe_hash
        runs = two_source_two_recipe_runs()
        # the two recipes on source A: flat-poster/2/False and mono-line/4/True
        svg_text = query(runs, {"chart": "diff",
                                "left": {"recipe_hash": recipe_hash("flat-poster", 2, False, False),
                                         "source_sha256": "s" * 64},
                                "right": {"recipe_hash": recipe_hash("mono-line", 4, True, False),
                                          "source_sha256": "s" * 64}})
        ET.fromstring(svg_text)

    def test_diff_unknown_candidate_raises(self):
        with self.assertRaises(QueryError):
            query(two_source_two_recipe_runs(),
                  {"chart": "diff", "left": {"candidate_id": "nope"},
                   "right": {"candidate_id": "a1"}})

    def test_diff_well_formed(self):
        svg_text = query(two_source_two_recipe_runs(),
                         {"chart": "diff", "left": {"candidate_id": "a1"},
                          "right": {"candidate_id": "b2"}})
        ET.fromstring(svg_text)


if __name__ == "__main__":
    unittest.main()
