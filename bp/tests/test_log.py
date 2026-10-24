"""Tests for the ``log`` operation: an event spec -> a vertical timeline SVG.

The property this file exists to defend is ORDER: the spec order IS the time
order, so a log whose timestamps are out of order must still be drawn in the
order it was written. The rows are measured by y position, because a re-sorted
drawing is otherwise invisible — the same rows, one page up.
"""

import unittest
import xml.etree.ElementTree as ET

from chopshop_bp import log
from chopshop_bp.log import _ADVANCE, _LABEL_GAP
from chopshop_bp.kinds import kind_color
from chopshop_bp.spec import SpecError

# Deliberately out of timestamp order: a renderer that sorted by `t` would draw
# these three rows in a different order.
LOG = {
    "title": "Run events",
    "events": [
        {"t": "00:00:03", "kind": "start", "label": "pipeline started", "pos": 1},
        {"t": "00:00:01", "kind": "gate", "label": "size gate skipped"},
        {"t": "00:00:02", "kind": "warn", "label": "colour drift", "pos": 5},
    ],
}

ORDER = ["pipeline started", "size gate skipped", "colour drift"]


def _elements(svg_text, tag):
    root = ET.fromstring(svg_text)
    return [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == tag]


def _texts(svg_text):
    return [el.text or "" for el in _elements(svg_text, "text")]


def _y_of(svg_text, content):
    for el in _elements(svg_text, "text"):
        if el.text == content:
            return float(el.get("y"))
    raise AssertionError("no text %r in the drawing" % content)


class TestLogRendering(unittest.TestCase):
    def test_output_is_well_formed_xml_with_a_canvas(self):
        root = ET.fromstring(log(LOG))
        width, height = root.get("viewBox").split()[2:]
        self.assertEqual(root.get("width"), width)
        self.assertEqual(root.get("height"), height)

    def test_the_same_spec_draws_the_same_bytes(self):
        self.assertEqual(log(LOG), log(LOG))

    def test_one_row_per_event_in_spec_order(self):
        y = [_y_of(log(LOG), label) for label in ORDER]
        self.assertEqual(y, sorted(y),
                         "rows are drawn in the order given; a log sorted by `t` "
                         "is a log re-ordered behind the caller's back")
        self.assertEqual(len({yy for yy in y}), len(ORDER), "one row per event")

    def test_a_different_order_is_a_different_drawing(self):
        reversed_spec = {**LOG, "events": list(reversed(LOG["events"]))}
        self.assertNotEqual(log(LOG), log(reversed_spec))
        y = [_y_of(log(reversed_spec), label) for label in reversed(ORDER)]
        self.assertEqual(y, sorted(y))

    def test_every_row_has_a_marker_on_the_spine(self):
        circles = _elements(log(LOG), "circle")
        self.assertEqual(len(circles), len(LOG["events"]))
        self.assertEqual(len({el.get("cx") for el in circles}), 1,
                         "every marker sits on the one spine")
        lines = _elements(log(LOG), "line")
        self.assertEqual(len(lines), 1, "one spine joins the rows")
        self.assertEqual(float(lines[0].get("x1")), float(circles[0].get("cx")))

    def test_a_single_row_needs_no_spine(self):
        with_line = _elements(log(LOG), "line")
        self.assertTrue(with_line, "two or more rows are joined by a spine")
        self.assertFalse(_elements(log({"events": LOG["events"][:1]}), "line"),
                         "a spine out to nothing is not a spine")

    def test_timestamps_and_labels_are_drawn(self):
        texts = _texts(log(LOG))
        for expected in (*ORDER, "00:00:03", "00:00:01", "00:00:02", "Run events"):
            self.assertIn(expected, texts)

    def test_pos_is_drawn_as_a_hash_rank(self):
        texts = _texts(log(LOG))
        self.assertIn("#1", texts)
        self.assertIn("#5", texts)

    def test_pos_is_omitted_when_it_is_none(self):
        texts = _texts(log(LOG))
        ranks = [t for t in texts if t.startswith("#")]
        self.assertEqual(ranks, ["#1", "#5"],
                         "the event with no pos has no rank: two events have one, "
                         "the third omits it")
        none_at_all = log({"events": [{"label": "no rank", "pos": None}]})
        self.assertNotIn("#", " ".join(_texts(none_at_all)))

    def test_zero_is_a_rank_and_is_drawn(self):
        self.assertIn("#0", _texts(log({"events": [{"label": "zero", "pos": 0}]})))

    def test_a_missing_t_label_and_pos_render_as_absent(self):
        spec = {"events": [{"kind": "info"}, {"kind": "info", "label": "second"}]}
        svg_text = log(spec)
        self.assertEqual(_texts(svg_text), ["second"],
                         "only the label that exists is drawn - no placeholder, "
                         "no midnight, no #None")
        self.assertEqual(len(_elements(svg_text, "circle")), 2)

    def test_an_event_that_is_only_a_kind_still_draws(self):
        ET.fromstring(log({"events": [{"kind": "start"}]}))

    def test_no_events_is_an_empty_canvas_not_an_error(self):
        root = ET.fromstring(log({"events": []}))
        self.assertIsNotNone(root)

    def test_a_size_that_is_given_is_the_canvas(self):
        root = ET.fromstring(log({**LOG, "size": {"width": 640, "height": 300}}))
        self.assertEqual(root.get("width"), "640")
        self.assertEqual(root.get("height"), "300")
        self.assertEqual(root.get("viewBox"), "0 0 640 300")

    def test_the_canvas_grows_with_the_row_count(self):
        few = float(ET.fromstring(log({"events": [{"label": "one"}]})).get("height"))
        rows = [{"label": str(i)} for i in range(20)]
        many = float(ET.fromstring(log({"events": rows})).get("height"))
        self.assertGreater(many, few,
                           "an event log auto-fits its rows instead of clipping at 400")

    def test_a_label_with_xml_special_characters_is_escaped(self):
        svg_text = log({"events": [{"label": "a < b & c"}]})
        root = ET.fromstring(svg_text)
        self.assertIn("a < b & c", [el.text or "" for el in root.iter()
                                    if el.tag.endswith("text")])


class TestLogTimestampColumn(unittest.TestCase):
    """The timestamp column adapts to the actual timestamp string.

    A fixed _T_COL=92 was too narrow for a full ISO8601 timestamp (20 chars =
    132px at 6.6px/char), which overlapped the label column by 40px. The column
    width must be derived from the longest timestamp in the document.
    """

    def _x_of(self, svg_text, content):
        """The x position of the first <text> with the given content."""
        for el in _elements(svg_text, "text"):
            if el.text == content:
                return float(el.get("x"))
        raise AssertionError("no text %r in the drawing" % content)

    def test_a_short_timestamp_does_not_overlap_the_label(self):
        svg_text = log(LOG)
        t_x = self._x_of(svg_text, "00:00:03")
        l_x = self._x_of(svg_text, "pipeline started")
        t_w = len("00:00:03") * _ADVANCE
        self.assertGreaterEqual(l_x, t_x + t_w,
                                "the label overlaps the timestamp column")

    def test_a_full_iso8601_timestamp_does_not_overlap_the_label(self):
        spec = {"events": [
            {"t": "2026-10-08T14:57:40Z", "kind": "start",
             "label": "pipeline started", "pos": 1},
            {"t": "2026-10-08T14:57:41Z", "kind": "gate",
             "label": "size gate skipped"},
        ]}
        svg_text = log(spec)
        t_x = self._x_of(svg_text, "2026-10-08T14:57:40Z")
        l_x = self._x_of(svg_text, "pipeline started")
        t_w = len("2026-10-08T14:57:40Z") * _ADVANCE
        self.assertGreaterEqual(l_x, t_x + t_w,
                                "the label overlaps the timestamp column")

    def test_the_label_vs_number_column_still_clears_by_16px(self):
        svg_text = log(LOG)
        l_x = self._x_of(svg_text, "colour drift")
        n_x = self._x_of(svg_text, "#5")
        l_w = len("colour drift") * _ADVANCE
        gap = n_x - (l_x + l_w)
        self.assertGreaterEqual(gap, _LABEL_GAP - 0.01,
                                "the #N rank overlaps the label column")


class TestLogColours(unittest.TestCase):
    def test_a_kind_colours_its_marker_deterministically(self):
        markers = [el.get("fill") for el in _elements(log(LOG), "circle")]
        self.assertEqual(markers[0], kind_color("start"))
        self.assertEqual(markers[1], kind_color("gate"))
        self.assertEqual(markers[2], kind_color("warn"))
        self.assertEqual(log(LOG), log(LOG))

    def test_an_unknown_kind_falls_back_to_a_colour_derived_from_its_name(self):
        spec = {"events": [{"kind": "wobble", "label": "a"},
                           {"kind": "wobble", "label": "b"},
                           {"kind": "wat", "label": "c"}]}
        markers = [el.get("fill") for el in _elements(log(spec), "circle")]
        self.assertEqual(markers[0], markers[1], "the same kind is the same colour")
        self.assertEqual(markers[0], kind_color("wobble"))
        self.assertNotEqual(markers[0], markers[2])
        self.assertEqual(log(spec), log(spec))


class TestLogSpecErrors(unittest.TestCase):
    def _bad(self, spec):
        with self.assertRaises(SpecError) as ctx:
            log(spec)
        return str(ctx.exception)

    def test_events_are_required(self):
        message = self._bad({})
        self.assertIn("events", message)

    def test_events_must_be_a_list(self):
        self.assertIn("list", self._bad({"events": {"kind": "start"}}))

    def test_an_event_must_be_an_object(self):
        self.assertIn("object", self._bad({"events": ["not an event"]}))

    def test_a_timestamp_that_is_not_a_string_is_refused(self):
        message = self._bad({"events": [{"t": 1234, "label": "a"}]})
        self.assertIn("t", message)

    def test_a_pos_that_is_not_an_integer_is_refused(self):
        message = self._bad({"events": [{"pos": 1.5, "label": "a"}]})
        self.assertIn("pos", message)
        self.assertIn("integer", self._bad({"events": [{"pos": "first"}]}))

    def test_a_bad_size_is_refused(self):
        self.assertIn("height", self._bad({"events": [], "size": {"height": -1}}))


if __name__ == "__main__":
    unittest.main()
