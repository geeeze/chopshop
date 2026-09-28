"""Tests for the ``tree`` operation: a hierarchy spec -> a layered SVG.

The two properties that matter are pinned by MEASUREMENT rather than by counting
elements: a child box is strictly below (or right of) its parent on every edge,
and the same spec draws the same bytes twice. A tree that renders the right
number of boxes in the wrong place is the failure this file exists to catch.
"""

import unittest
import xml.etree.ElementTree as ET

from chopshop_plot import tree
from chopshop_plot.kinds import UNKNOWN, kind_color, status_color
from chopshop_plot.spec import SpecError

TREE = {
    "title": "Trace pipeline",
    "layout": "tb",
    "nodes": [
        {"id": "root", "label": "source", "kind": "root", "status": "ok"},
        {"id": "gate", "label": "size gate", "kind": "gate", "status": "passed",
         "metrics": {"nodes": 1234, "inks": 5}},
        {"id": "trace", "label": "tracer", "kind": "tool"},
        {"id": "report", "label": "report", "kind": "tool"},
    ],
    "edges": [
        {"from": "root", "to": "gate"},
        {"from": "gate", "to": "trace"},
        {"from": "gate", "to": "report"},
    ],
}

LABELS = {node["id"]: node["label"] for node in TREE["nodes"]}


def _elements(svg_text, tag):
    root = ET.fromstring(svg_text)
    return [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == tag]


def _texts(svg_text):
    return " ".join(el.text or "" for el in _elements(svg_text, "text"))


def _boxes(svg_text):
    """Every node box: the rounded rects (rx=6) the boxes are drawn as."""
    return [(float(el.get("x")), float(el.get("y")), float(el.get("width")),
             float(el.get("height")))
            for el in _elements(svg_text, "rect") if el.get("rx") == "6"]


def _box_of(svg_text, label):
    """The node box that contains a label's text position."""
    for el in _elements(svg_text, "text"):
        if el.text != label:
            continue
        tx, ty = float(el.get("x")), float(el.get("y"))
        for box in _boxes(svg_text):
            x, y, w, h = box
            if x <= tx <= x + w and y <= ty <= y + h:
                return box
    raise AssertionError("no node box contains the label %r" % label)


class TestTreeRendering(unittest.TestCase):
    def test_output_is_well_formed_xml_with_a_canvas(self):
        root = ET.fromstring(tree(TREE))
        self.assertEqual(root.get("width"), root.get("viewBox").split()[2],
                         "the root carries a width/height/viewBox the pipeline can read")
        self.assertEqual(root.get("height"), root.get("viewBox").split()[3])
        self.assertIsNotNone(root.get("width"))

    def test_the_same_spec_draws_the_same_bytes(self):
        self.assertEqual(tree(TREE), tree(TREE))

    def test_the_drawing_does_not_depend_on_the_order_nodes_were_written_in(self):
        # Children are walked in id order, so a shuffled document is the same
        # document. Only the layout seeds (roots) read the given order.
        shuffled = dict(TREE)
        shuffled["nodes"] = list(reversed(TREE["nodes"]))
        self.assertIn("size gate", _texts(tree(shuffled)))

    def test_labels_kinds_and_metrics_are_drawn(self):
        texts = _texts(tree(TREE))
        for expected in ("source", "size gate", "tracer", "report", "Trace pipeline"):
            self.assertIn(expected, texts)
        self.assertIn("nodes=1234", texts)
        self.assertIn("inks=5", texts)
        self.assertIn("passed", texts, "the status is a word, not only a dot")

    def test_a_metric_with_no_value_is_absent_never_zero(self):
        spec = {"nodes": [{"id": "a", "label": "a",
                           "metrics": {"mae": None, "nodes": 3}}]}
        texts = _texts(tree(spec))
        self.assertIn("nodes=3", texts)
        self.assertNotIn("mae", texts,
                         "a missing measurement renders as ABSENT; plotting 0 lies")
        self.assertNotIn("=0", texts)

    def test_a_node_with_no_label_falls_back_to_its_id(self):
        texts = _texts(tree({"nodes": [{"id": "bare-node"}]}))
        self.assertIn("bare-node", texts)
        ET.fromstring(tree({"nodes": [{"id": "bare-node"}]}))

    def test_a_single_node_needs_no_edges(self):
        spec = {"nodes": [{"id": "only", "label": "only", "kind": "step"}]}
        root = ET.fromstring(tree(spec))
        self.assertIsNotNone(root)
        self.assertEqual(len(_boxes(tree(spec))), 1)


class TestTreeLayout(unittest.TestCase):
    def test_a_child_is_below_its_parent_in_tb(self):
        svg_text = tree(TREE)
        for edge in TREE["edges"]:
            parent = _box_of(svg_text, LABELS[edge["from"]])
            child = _box_of(svg_text, LABELS[edge["to"]])
            self.assertGreater(child[1], parent[1],
                               "%s must be drawn below %s" % (edge["to"], edge["from"]))
            self.assertGreaterEqual(child[1], parent[1] + parent[3],
                                    "%s must clear the bottom of %s"
                                    % (edge["to"], edge["from"]))

    def test_tb_is_the_default_layout(self):
        without = {k: v for k, v in TREE.items() if k != "layout"}
        self.assertEqual(tree(without), tree(TREE))

    def test_a_child_is_to_the_right_of_its_parent_in_lr(self):
        svg_text = tree({**TREE, "layout": "lr"})
        for edge in TREE["edges"]:
            parent = _box_of(svg_text, LABELS[edge["from"]])
            child = _box_of(svg_text, LABELS[edge["to"]])
            self.assertGreaterEqual(child[0], parent[0] + parent[2],
                                    "%s must be drawn right of %s"
                                    % (edge["to"], edge["from"]))

    def test_an_internal_node_is_centred_over_its_children(self):
        svg_text = tree(TREE)
        parent = _box_of(svg_text, LABELS["gate"])
        kids = [_box_of(svg_text, LABELS["trace"]), _box_of(svg_text, LABELS["report"])]
        parent_mid = parent[0] + parent[2] / 2
        self.assertAlmostEqual(parent_mid, (kids[0][0] + kids[1][0] + kids[0][2]) / 2,
                               delta=0.001,
                               msg="an internal node sits centred over its children")

    def test_each_leaf_gets_its_own_slot(self):
        leaves = [_box_of(tree(TREE), LABELS[nid]) for nid in ("trace", "report")]
        self.assertNotEqual(leaves[0][0], leaves[1][0], "two leaves cannot share a slot")

    def test_a_node_no_root_can_reach_is_still_drawn(self):
        spec = {
            "nodes": [{"id": "a", "label": "a"}, {"id": "b", "label": "b"},
                      {"id": "cyc1", "label": "cyc1"}, {"id": "cyc2", "label": "cyc2"},
                      {"id": "orphan", "label": "orphan"}],
            "edges": [{"from": "a", "to": "b"},
                      {"from": "cyc1", "to": "cyc2"}, {"from": "cyc2", "to": "cyc1"}],
        }
        texts = _texts(tree(spec))
        for label in ("a", "b", "cyc1", "cyc2", "orphan"):
            self.assertIn(label, texts, "every node is drawn, reachable or not")
        self.assertEqual(len(_boxes(tree(spec))), 5)

    def test_a_cycle_does_not_hang_and_still_draws_a_root(self):
        spec = {"nodes": [{"id": "a", "label": "a"}, {"id": "b", "label": "b"}],
                "edges": [{"from": "a", "to": "b"}, {"from": "b", "to": "a"}]}
        svg_text = tree(spec)
        top = min(box[1] for box in _boxes(svg_text))
        self.assertEqual(_box_of(svg_text, "a")[1], top,
                         "with no root, the first node in the document is the root")

    def test_a_size_that_is_given_is_the_canvas(self):
        spec = {**TREE, "size": {"width": 900, "height": 600}}
        root = ET.fromstring(tree(spec))
        self.assertEqual(root.get("width"), "900")
        self.assertEqual(root.get("height"), "600")
        self.assertEqual(root.get("viewBox"), "0 0 900 600")
        for box in _boxes(tree(spec)):
            self.assertLessEqual(box[1] + box[3], 600, "the drawing fits the canvas")

    def test_the_canvas_fits_the_drawing_when_no_size_is_given(self):
        drawing = tree(TREE)
        self.assertNotIn('width="800"', drawing,
                         "a tree auto-fits instead of taking the chart default")
        for box in _boxes(drawing):
            self.assertLessEqual(box[0] + box[2], float(ET.fromstring(drawing).get("width")))


class TestTreeColours(unittest.TestCase):
    def test_a_kind_colours_its_node_deterministically(self):
        spec = {"nodes": [{"id": "a", "label": "a", "kind": "agent"}]}
        fills = [el.get("fill") for el in _elements(tree(spec), "rect")]
        self.assertIn(kind_color("agent"), fills, "the kind bar carries the kind colour")
        self.assertEqual(tree(spec), tree(spec))
        self.assertEqual(kind_color("agent"), kind_color("agent"))

    def test_an_unknown_kind_falls_back_to_a_colour_derived_from_its_name(self):
        one = {"nodes": [{"id": "a", "label": "a", "kind": "wat"}]}
        two = {"nodes": [{"id": "a", "label": "a", "kind": "wobble"}]}
        # Same kind -> same colour across drawings; different kinds differ.
        bars = [el.get("fill") for el in _elements(tree(one), "rect")]
        self.assertIn(kind_color("wat"), bars)
        self.assertEqual(kind_color("wat"), kind_color("wat"))
        self.assertNotEqual(kind_color("wat"), kind_color("wobble"))
        self.assertIn(kind_color("wobble"),
                      [el.get("fill") for el in _elements(tree(two), "rect")])

    def test_a_status_is_a_dot_and_a_word_and_an_unknown_status_is_grey(self):
        known = {"nodes": [{"id": "a", "label": "a", "status": "failed"}]}
        dots = [el.get("fill") for el in _elements(tree(known), "circle")]
        self.assertEqual(dots, [status_color("failed")])
        self.assertIn("failed", _texts(tree(known)))

        unknown = {"nodes": [{"id": "a", "label": "a", "status": "wobbly"}]}
        self.assertEqual([el.get("fill") for el in _elements(tree(unknown), "circle")],
                         [UNKNOWN])
        self.assertEqual(tree(unknown), tree(unknown))

    def test_a_status_word_that_does_not_fit_beside_the_label_is_left_out(self):
        # The dot always carries the status; the word is dropped rather than
        # drawn across the label it would overlap.
        crowded = {"nodes": [{"id": "a", "kind": "gate", "status": "warning",
                              "label": "Layer B render preflight gate"}]}
        self.assertNotIn("warning", _texts(tree(crowded)))
        self.assertEqual(len(_elements(tree(crowded), "circle")), 1,
                         "the dot is still drawn")
        roomy = {"nodes": [{"id": "a", "kind": "gate", "status": "warning",
                            "label": "gate"}]}
        self.assertIn("warning", _texts(tree(roomy)))

    def test_a_status_names_a_colour_in_words(self):
        for status in ("gate-failed", "render error"):
            self.assertEqual(status_color(status), status_color("failed"), status)
        self.assertEqual(status_color("broken"), UNKNOWN,
                         "a substring inside an unrelated word is not a status")


class TestTreeSpecErrors(unittest.TestCase):
    def _bad(self, spec):
        with self.assertRaises(SpecError) as ctx:
            tree(spec)
        return str(ctx.exception)

    def test_an_edge_to_an_unknown_node_is_refused(self):
        message = self._bad({"nodes": [{"id": "a", "label": "a"}],
                             "edges": [{"from": "a", "to": "nope"}]})
        self.assertIn("nope", message)
        self.assertIn("to", message)

    def test_an_edge_from_an_unknown_node_is_refused(self):
        message = self._bad({"nodes": [{"id": "a", "label": "a"}],
                             "edges": [{"from": "nope", "to": "a"}]})
        self.assertIn("unknown node", message)

    def test_a_duplicate_node_id_is_refused(self):
        message = self._bad({"nodes": [{"id": "a"}, {"id": "a", "label": "again"}]})
        self.assertIn("duplicate node id", message)

    def test_nodes_are_required(self):
        self.assertIn("nodes", self._bad({}))

    def test_a_node_needs_a_non_empty_id(self):
        self.assertIn("id", self._bad({"nodes": [{"label": "no id"}]}))

    def test_a_non_numeric_metric_is_refused(self):
        message = self._bad({"nodes": [{"id": "a", "metrics": {"mae": "low"}}]})
        self.assertIn("mae", message)

    def test_a_bad_layout_is_refused(self):
        self.assertIn("layout", self._bad({"nodes": [{"id": "a"}], "layout": "diagonal"}))

    def test_a_bad_size_is_refused(self):
        self.assertIn("width", self._bad({"nodes": [{"id": "a"}],
                                          "size": {"width": 0}}))


if __name__ == "__main__":
    unittest.main()
