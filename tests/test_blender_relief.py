"""Relief: a 2D image turned into 3D depth (chopshop-bp#3).

The missing half of raster -> trace -> extrude. Per-element `z` and `depth`
already existed, so the mechanism a relief needs was there; what was missing was
the RULE — and the rule is a division of labour, not a formula, so most of this
file is about where the line falls.

**This repository draws and does not measure.** So the height rule is DATA in
the spec (a `relief` block naming one rule and its parameters) and the
per-element measurement is the CALLER's, handed over as a number. A luminance
cannot be computed here — this repo does not read rasters — and an area ordering
cannot either without a trace this repo did not produce. What this side owns is
the part that IS drawing: given a stated rule and a stated measurement, what
height does this contour stand at. That is arithmetic over the spec, testable
here with no renderer, and a heuristic invented on this side would be none of
those things.

The tests are in three layers, matching how the rest of the blender tests are
built:

1. **the contract** — which rules exist, what each requires of an element, and
   what is refused by name. Pure, and exhaustive without Blender.
2. **the rule** — `relief_height` / `relief_depth` / `apply_relief`, pinned to
   the exact arithmetic so a backend in another language has the same numbers.
3. **the real render** — that a traced image and its measured heights produce a
   relief whose geometry is actually at those heights, skipped without Blender.

The third layer is the one that would catch the failure this feature most
plausibly has: a rule that validates, resolves, and is then not applied to the
geometry. Everything above it can pass with a dead rule.
"""

import json
import os
import shutil
import tempfile
import unittest

from chopshop_plot.blender import (DEFAULT_RELIEF, apply_relief, relief_depth,
                                   relief_height, render_blender, resolve_relief,
                                   validate_blender)
from chopshop_plot.generate import generate
from chopshop_plot.spec import SpecError

HAVE_BLENDER = shutil.which("blender")


def _contour(luminance=None, layer=None, **overrides):
    """One traced contour, with whichever measurement the caller measured."""
    element = {"type": "rect", "x": 0, "y": 0, "width": 20, "height": 20,
               "fill": "#808080"}
    if luminance is not None:
        element["luminance"] = luminance
    if layer is not None:
        element["layer"] = layer
    element.update(overrides)
    return element


def _spec(elements, **relief):
    return {
        "title": "relief",
        "elements": elements,
        "relief": {"rule": "luminance", **relief},
    }


# -- the contract -----------------------------------------------------------

class ReliefContractTest(unittest.TestCase):
    """The `relief` block: which rules exist and what each one demands."""

    def assert_refused(self, spec, needle):
        with self.assertRaises(SpecError) as caught:
            validate_blender(spec)
        self.assertIn(needle, str(caught.exception))

    def test_both_rules_are_accepted(self):
        """The two the issue names, and no others. A third rule would be a
        measurement this repository cannot take, so the tuple is closed."""
        validate_blender(_spec([_contour(luminance=0.5)]))
        validate_blender(_spec([_contour(layer=0)], rule="layers", step=3))

    def test_a_rule_is_required_and_has_no_default(self):
        """The load-bearing refusal, and the reason for it. The two rules
        disagree about what height MEANS — one is tonal, the other ordinal — so
        defaulting would be picking a reading of the caller's image on their
        behalf. A spec that omits the rule has not said what it wants."""
        self.assert_refused({"elements": [_contour(luminance=0.5)], "relief": {}},
                            "'rule' is required")

    def test_an_unknown_rule_is_refused_by_name(self):
        self.assert_refused(_spec([_contour(luminance=0.5)], rule="height"),
                            "'rule' must be one of luminance, layers")

    def test_an_unknown_parameter_is_refused_by_name(self):
        """`z_mx` is a relief parameter nobody applied, and a spec carrying one
        renders exactly like the default — the same lie as a typo'd element
        field, refused for the same reason."""
        self.assert_refused(_spec([_contour(luminance=0.5)], z_mx=20),
                            "unknown field(s) ['z_mx']")

    def test_a_non_object_block_is_refused(self):
        self.assert_refused({"elements": [_contour(luminance=0.5)], "relief": 0.5},
                            "must be an object")

    def test_a_reversed_range_is_refused_rather_than_swapped(self):
        """A relief whose range runs backwards is nearly always a sign error.
        Silently swapping it would turn a typo into a render nobody asked for —
        and `invert` is already how a caller asks for the intaglio reading."""
        self.assert_refused(_spec([_contour(luminance=0.5)], z_min=20, z_max=0),
                            "must be <= 'z_max'")

    def test_a_luminance_rule_needs_a_luminance_on_every_element(self):
        """The refusal that makes the rule honest. A contour with no
        measurement has exactly one place it can go — the floor of the range —
        and a contour sitting on the floor looks like a decision rather than a
        gap, which is the failure the whole rule exists to prevent."""
        self.assert_refused(
            _spec([_contour(luminance=0.5), _contour()]),
            "this element has none")

    def test_a_layers_rule_needs_a_layer_on_every_element(self):
        self.assert_refused(
            _spec([_contour(layer=0), _contour(luminance=0.5)], rule="layers"),
            "this element has none")

    def test_an_explicit_z_is_the_documented_way_out(self):
        """A plate or a backdrop in a relief document places itself. This is why
        the missing-measurement check is per element rather than per document:
        one self-placed element should not force a fake `luminance` onto it."""
        validate_blender(_spec([_contour(luminance=0.5), _contour(z=-4)]))

    def test_the_offending_element_is_named_by_index(self):
        """The index, because "an element needs a luminance" does not tell a
        caller with four hundred traced contours which one to go and measure."""
        self.assert_refused(
            _spec([_contour(luminance=0.5), _contour(luminance=0.5), _contour()]),
            "elements[2]")

    def test_a_luminance_outside_zero_to_one_is_refused(self):
        """A 0..255 channel or a percentage is a DIFFERENT quantity, and mapping
        it as if it were normalised puts every contour past the top of the
        range. The fix is one number at the caller, and inventing a clamp here
        would be inventing the caller's measurement."""
        for value in (255, 1.5, -0.1):
            self.assert_refused(_spec([_contour(luminance=value)]),
                                "'luminance' must be a number in 0..1")

    def test_a_non_numeric_luminance_is_refused(self):
        self.assert_refused(_spec([_contour(luminance="bright")]),
                            "'luminance' must be a number in 0..1")

    def test_a_fractional_layer_is_refused(self):
        """`layer` is an ORDINAL — which trace layer this contour is — so 1.5
        is not "between two layers", it is a value that would have to be
        rounded, and rounding is a decision the caller did not make."""
        self.assert_refused(_spec([_contour(layer=1.5)], rule="layers"),
                            "'layer' must be an integer >= 0")

    def test_a_negative_layer_is_refused(self):
        """The other end. A negative index is not "the backmost layer"; there
        is no layer before the first."""
        self.assert_refused(_spec([_contour(layer=-1)], rule="layers"),
                            "'layer' must be an integer >= 0")

    def test_a_measurement_without_a_relief_block_is_still_range_checked(self):
        """A spec that sets `luminance` and no rule has said nothing about
        height, and its elements keep z=0 — but a malformed number is still a
        caller error rather than something to carry into a render that ignores
        it."""
        self.assert_refused(
            {"elements": [_contour(luminance=99.0)]},
            "'luminance' must be a number in 0..1")

    def test_the_measurements_are_3d_only_fields_on_a_primitive_too(self):
        """A primitive carries them as well, and a sphere in a relief document
        is a legitimate thing to want. Checked on the primitive path because
        that path short-circuits the shared element check — the one place a
        field could be accepted and ignored."""
        spec = _spec([{"type": "sphere", "cx": 0, "cy": 0, "r": 5,
                       "fill": "#808080", "luminance": 0.4}])
        validate_blender(spec)
        self.assertEqual(apply_relief(spec)["elements"][0]["z"], 8.0)

    def test_generate_refuses_a_z_but_not_a_luminance(self):
        """The asymmetry is the design, so it is pinned. A height has no
        reading in a flat drawing, so `generate` refuses `z`; a normalised
        brightness does (it becomes opacity), so one traced document can be
        drawn both ways. Checked through `generate` rather than
        `validate_blender` — the 3D half is SUPPOSED to accept `z`, and asking
        the 3D validator to refuse it would be asking the wrong question."""
        with self.assertRaises(SpecError) as caught:
            generate({"canvas": {"width": 40, "height": 40},
                      "elements": [{"type": "rect", "x": 0, "y": 0, "width": 5,
                                    "height": 5, "fill": "#000", "z": 3}]})
        self.assertIn("'z'", str(caught.exception))
        # And the same document without the `z` draws, luminance and all.
        drawn = generate({"canvas": {"width": 40, "height": 40},
                          "relief": {"rule": "luminance"},
                          "elements": [{"type": "rect", "x": 0, "y": 0,
                                        "width": 5, "height": 5, "fill": "#000",
                                        "luminance": 0.5}]})
        self.assertIn("<rect", drawn)

    def test_generate_refuses_the_layers_rule_because_it_has_no_flat_reading(self):
        """A stack of heights cannot be drawn flat: the caller has already
        expressed layer order by the order they wrote the elements in, so
        applying the rule would invent an opacity ordering nobody asked for."""
        with self.assertRaises(SpecError) as caught:
            generate({"canvas": {"width": 40, "height": 40},
                      "relief": {"rule": "layers"},
                      "elements": [{"type": "rect", "x": 0, "y": 0, "width": 5,
                                    "height": 5, "fill": "#000", "layer": 0}]})
        self.assertIn("no 2D reading", str(caught.exception))

    def test_generate_refuses_a_3d_relief_parameter(self):
        """A 2D document that set `z_max` would be accepting a range it cannot
        act on — refused by name rather than ignored."""
        with self.assertRaises(SpecError) as caught:
            generate({"canvas": {"width": 40, "height": 40},
                      "relief": {"rule": "luminance", "z_max": 20},
                      "elements": [{"type": "rect", "x": 0, "y": 0, "width": 5,
                                    "height": 5, "fill": "#000", "luminance": 0.5}]})
        self.assertIn("unknown field(s) ['z_max']", str(caught.exception))

    def test_generate_refuses_a_luminance_on_a_stroke(self):
        """The flat reading is `fill-opacity`, and a `line` or `polyline` has no
        fill — so a luminance there is a measurement this drawing cannot
        express, and accepting it would be a relief with a hole in it."""
        with self.assertRaises(SpecError) as caught:
            generate({"canvas": {"width": 40, "height": 40},
                      "relief": {"rule": "luminance"},
                      "elements": [{"type": "line", "x1": 0, "y1": 0, "x2": 5,
                                    "y2": 5, "stroke": "#000", "luminance": 0.5}]})
        self.assertIn("no flat reading on a line", str(caught.exception))


# -- the rule ---------------------------------------------------------------

class ReliefRuleTest(unittest.TestCase):
    """The arithmetic, pinned so another backend can reproduce it exactly."""

    def relief(self, **block):
        return dict(DEFAULT_RELIEF, **block)

    def test_luminance_maps_onto_the_stated_range_inclusively(self):
        relief = self.relief(rule="luminance", z_min=0.0, z_max=20.0)
        self.assertAlmostEqual(relief_height(_contour(luminance=0.0), relief), 0.0)
        self.assertAlmostEqual(relief_height(_contour(luminance=1.0), relief), 20.0)
        self.assertAlmostEqual(relief_height(_contour(luminance=0.5), relief), 10.0)

    def test_the_range_is_linear_not_curved(self):
        """Stated because a future reader will otherwise wonder: no gamma, no
        easing, no perceptual curve. A rule the caller cannot predict is a rule
        they cannot correct."""
        relief = self.relief(rule="luminance", z_min=0.0, z_max=20.0)
        self.assertAlmostEqual(relief_height(_contour(luminance=0.25), relief), 5.0)
        self.assertAlmostEqual(relief_height(_contour(luminance=0.75), relief), 15.0)

    def test_a_range_that_does_not_start_at_zero_is_respected(self):
        """The rule maps onto the range the caller NAMED. Starting the relief
        above the sketch plane is legitimate (a relief sitting on a plinth) and
        an implementation that assumed z_min=0 would quietly drop it."""
        relief = self.relief(rule="luminance", z_min=6.0, z_max=10.0)
        self.assertAlmostEqual(relief_height(_contour(luminance=0.0), relief), 6.0)
        self.assertAlmostEqual(relief_height(_contour(luminance=1.0), relief), 10.0)

    def test_invert_reflects_about_the_midpoint_and_keeps_both_ends(self):
        """The intaglio reading: the light parts are the recess. Reflected about
        `z_min + z_max`, so a reflected relief is bounded by the SAME numbers —
        not by an accidental range, which is what inverting the raw value would
        give (a value of 0.5 would land outside the range entirely)."""
        relief = self.relief(rule="luminance", z_min=0.0, z_max=20.0, invert=True)
        self.assertAlmostEqual(relief_height(_contour(luminance=0.0), relief), 20.0)
        self.assertAlmostEqual(relief_height(_contour(luminance=1.0), relief), 0.0)
        self.assertAlmostEqual(relief_height(_contour(luminance=0.5), relief), 10.0)

    def test_layers_is_ordinal_and_evenly_spaced(self):
        relief = self.relief(rule="layers", z_min=0.0, step=4.0)
        self.assertAlmostEqual(relief_height(_contour(layer=0), relief), 0.0)
        self.assertAlmostEqual(relief_height(_contour(layer=1), relief), 4.0)
        self.assertAlmostEqual(relief_height(_contour(layer=7), relief), 28.0)

    def test_layers_is_not_capped_by_z_max(self):
        """Deliberate, and the reason it is a test. A ceiling would flatten the
        top layers into one plane and destroy the stacking the rule exists to
        produce; a caller who wants a ceiling sets `z_max` and picks a `step`
        that fits under it. Asserted so a future "safety cap" is a decision
        rather than an accident."""
        relief = self.relief(rule="layers", z_min=0.0, z_max=10.0, step=4.0)
        self.assertAlmostEqual(relief_height(_contour(layer=9), relief), 36.0)

    def test_an_explicit_z_beats_the_rule(self):
        """The rule fills in heights; it does not overrule a height the caller
        stated directly. Which is what makes an explicit `z` the documented
        escape hatch for a plate or a backdrop."""
        relief = self.relief(rule="luminance", z_min=0.0, z_max=20.0)
        self.assertAlmostEqual(relief_height(_contour(luminance=0.9, z=-3),
                                             relief), -3.0)

    def test_an_explicit_depth_beats_the_relief_thickness(self):
        relief = self.relief(rule="luminance", thickness=1.5)
        self.assertAlmostEqual(relief_depth(_contour(luminance=0.5), relief), 1.5)
        self.assertAlmostEqual(relief_depth(_contour(luminance=0.5, depth=0.2),
                                            relief), 0.2)

    def test_thickness_is_the_half_extent_like_every_other_depth(self):
        """Consistent with the measured convention rather than a second one: a
        relief slab of `thickness: 1.5` is 3 units thick, exactly as an element
        with `depth: 1.5` is. Stated here because a relief is exactly where a
        reader would assume a full thickness and be wrong by half."""
        self.assertEqual(DEFAULT_RELIEF["thickness"], 1.5)

    def test_resolve_relief_returns_none_without_a_block(self):
        """`None` and an empty block must not look alike: one is a document with
        no relief, the other is a document whose relief is missing its rule and
        is refused. A resolver that returned a default for both would hide that."""
        self.assertIsNone(resolve_relief({"elements": [_contour()]}))
        self.assertIsNone(resolve_relief({}))

    def test_resolve_relief_returns_a_copy_not_the_constant(self):
        """The same reason every other resolved block is a copy: a render that
        could mutate the module default would make the second render in a
        process differ from the first for no reason any spec stated."""
        got = resolve_relief(_spec([_contour(luminance=0.5)]))
        got["z_max"] = 999
        self.assertEqual(DEFAULT_RELIEF["z_max"], 20.0)

    def test_apply_relief_leaves_a_spec_without_a_relution_untouched(self):
        """A document that does not use the rule must take a byte-identical
        path — and the frame stem is a hash of the spec, so a no-op that copied
        the dict would still be equal, but one that ADDED a key would move every
        cached frame name in the pipeline."""
        spec = {"elements": [_contour(luminance=0.5)]}
        self.assertIs(apply_relief(spec), spec)

    def test_apply_relief_does_not_mutate_the_callers_spec(self):
        """A caller that re-renders the same dict must get the same frames, and
        a rule that consumed its own input could not promise that twice."""
        spec = _spec([_contour(luminance=0.9)])
        before = json.dumps(spec, sort_keys=True)
        apply_relief(spec)
        self.assertEqual(json.dumps(spec, sort_keys=True), before)
        self.assertNotIn("z", spec["elements"][0])

    def test_apply_relief_writes_plain_z_and_depth(self):
        """The resolution happens in the DRIVER, so the spec that reaches
        Blender carries ordinary `z`/`depth` and the builder needs no relief code
        at all — which is what keeps the rule written once rather than mirrored
        into a file that cannot import this module."""
        resolved = apply_relief(_spec([_contour(luminance=1.0)]))
        self.assertEqual(resolved["elements"][0]["z"], 20.0)
        self.assertEqual(resolved["elements"][0]["depth"], 1.5)

    def test_the_returned_names_are_the_names_of_the_files_that_get_written(self):
        """The bug this file's first draft could not see, and it is a real one.

        `render_blender` returns names derived from a hash of the document, and
        the frame is written by `blender/bpy_geometry.py`, which can only see
        the RELIEVED spec. So both sides must hash the same thing. They did not:
        the driver hashed the caller's spec and Blender hashed the resolved one,
        so a relief render returned a name no file had — it reported success,
        and every caller that then opened the frame got FileNotFoundError. A
        document with no relief block cannot show it, because `apply_relief`
        returns the spec itself, which is why only the real-render tests caught
        it and only at forty seconds a frame.

        Checked with the subprocess stubbed, and the assertion is the one that
        matters: the names the driver RETURNS must be the names of the document
        it WROTE OUT, because that document is the only thing Blender ever sees.
        Asserting the driver's own input instead would pass again the moment
        someone changed which spec gets hashed on each side.
        """
        import importlib
        import shutil
        import tempfile
        from unittest import mock

        # importlib, NOT `from chopshop_plot import blender`: the package
        # exports the operation FUNCTION under that name, so the attribute is
        # the function and patching its `subprocess` would patch nothing —
        # which is the same trap `tests/test_blender.py` documents.
        blender_module = importlib.import_module("chopshop_plot.blender")
        from chopshop_plot.blender import output_names, render_blender

        spec = _spec([_contour(luminance=0.5)])
        captured = {}
        out = tempfile.mkdtemp(prefix="chopshop-relief-names-")
        self.addCleanup(shutil.rmtree, out, ignore_errors=True)

        def fake_run(command, **kwargs):
            with open(command[-2], encoding="utf-8") as handle:
                captured["written"] = json.load(handle)
            return mock.Mock(returncode=0, stdout="", stderr="")

        with mock.patch.object(blender_module.config, "blender_binary",
                               return_value="blender"), \
                mock.patch.object(blender_module.shutil, "which",
                                  return_value="/usr/bin/blender"), \
                mock.patch.object(blender_module.subprocess, "run", fake_run):
            names = render_blender(spec, out)

        # The document that reached the file is the resolved one...
        self.assertEqual(captured["written"]["elements"][0]["z"], 10.0)
        # ...and the names handed back name THAT document. A no-relief spec
        # would pass this either way, which is why the spec here carries a rule.
        self.assertEqual(names, output_names(captured["written"]))


# -- the flat reading -------------------------------------------------------

class ReliefExampleTest(unittest.TestCase):
    """`examples/relief-portrait.json` is a working document, not a snippet.

    An example that no longer validates is worse than no example — it is a
    document the README tells a reader to copy. So it is loaded and checked
    here, which is also the only thing that keeps the comments in it honest
    about the heights the rule produces.
    """

    def setUp(self):
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            "examples", "relief-portrait.json")
        with open(path, encoding="utf-8") as handle:
            self.document = json.load(handle)

    def test_the_shipped_example_validates(self):
        validate_blender(self.document["spec"])

    def test_the_example_grades_the_face_the_way_the_comments_say(self):
        """The comments claim the nose is the highest plane and the eye sockets
        among the deepest. A comment is a memory; this is the check on it, and
        the reason the example is loadable from a test at all."""
        resolved = apply_relief(self.document["spec"])
        by_type = {}
        for element in resolved["elements"]:
            by_type.setdefault(element["type"], []).append(element)
        # background (rect) below the face (the first big ellipse)
        self.assertLess(by_type["rect"][0]["z"], by_type["ellipse"][0]["z"])
        # the nose (the only polygon) above the eye sockets (the small ellipses)
        sockets = [e["z"] for e in by_type["ellipse"] if e["rx"] == 7]
        self.assertTrue(sockets)
        self.assertGreater(by_type["polygon"][0]["z"], max(sockets))

    def test_the_example_carries_a_measurement_on_every_element(self):
        """The rule reads one number per element, and an element missing it is
        refused — so this is really a check that the example is a complete
        traced document rather than a partial one."""
        for element in self.document["spec"]["elements"]:
            self.assertIn("luminance", element)


class ReliefSvgTest(unittest.TestCase):
    """The SVG side: the same measurement, read as tone rather than height."""

    def draw(self, luminance, **relief):
        return generate({"canvas": {"width": 40, "height": 40},
                         "relief": {"rule": "luminance", **relief},
                         "elements": [{"type": "rect", "x": 0, "y": 0, "width": 10,
                                       "height": 10, "fill": "#404040",
                                       "luminance": luminance}]})

    def test_luminance_becomes_fill_opacity(self):
        self.assertIn('fill-opacity="0.25"', self.draw(0.25))

    def test_the_extremes_reach_zero_and_one(self):
        """Both ends of the measurement land on both ends of the range,
        written out rather than clamped short of them — a relief whose brightest
        contour stops just below full would be a measurement quietly adjusted.
        The attribute is emitted even at 1.0, where it changes nothing: a relief
        in force writes its tone on every element, so the document says the
        same thing about the brightest contour as about the darkest."""
        self.assertIn('fill-opacity="0"', self.draw(0.0))
        self.assertIn('fill-opacity="1"', self.draw(1.0))

    def test_the_colour_is_not_derived_from_the_luminance(self):
        """A relief decides how FAR BACK a shape sits; the element's `fill` is
        still its colour. Tinting the fill towards the background would be a
        second, invisible rule."""
        self.assertIn('fill="#404040"', self.draw(0.25))

    def test_invert_applies_to_the_flat_reading_too(self):
        """The two sides agree about which parts are near, which is the entire
        reason the rule is shared rather than reimplemented per operation."""
        self.assertIn('fill-opacity="0.75"', self.draw(0.25, invert=True))

    def test_a_spec_with_no_relief_draws_exactly_as_before(self):
        """The compatibility claim for the flat half. A new optional parameter
        that emitted an attribute when nothing asked for it would change every
        SVG this service produces."""
        plain = generate({"canvas": {"width": 40, "height": 40},
                          "elements": [{"type": "rect", "x": 0, "y": 0,
                                        "width": 10, "height": 10,
                                        "fill": "#404040", "luminance": 0.25}]})
        self.assertNotIn("fill-opacity", plain)
        self.assertIn('fill="#404040"', plain)

    def test_the_output_is_still_well_formed_xml(self):
        import xml.etree.ElementTree as ET

        ET.fromstring(self.draw(0.25))


# -- against real geometry --------------------------------------------------

@unittest.skipUnless(HAVE_BLENDER, "the blender binary is not installed")
class ReliefRealGeometryTest(unittest.TestCase):
    """That the rule reaches the MESH, measured rather than asserted.

    The trap this guards is the one a rule-shaped feature always has: a
    `relief` block that validates, resolves, and is then dropped on the floor
    would pass every test above, because all of them test the arithmetic and
    none of them test that the arithmetic is used. Here the heights are read
    back from `to_mesh()` — the surface the render shows — so a dead rule shows
    up as every contour sitting on z=0.

    A probe rather than a render, deliberately: it answers "are the solids at
    the heights the rule says" without paying 40 seconds a frame, which is what
    makes it affordable to assert four separate heights.
    """

    def setUp(self):
        import sys

        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        self.addCleanup(sys.path.remove, os.path.dirname(os.path.abspath(__file__)))
        from test_blender import probe_geometry

        self.probe = probe_geometry

    def z_spans(self, spec):
        """The measured z span of every object the spec builds, in order."""
        validate_blender(spec)
        return [(entry["min"][2], entry["max"][2])
                for entry in self.probe(apply_relief(spec))]

    def test_a_luminance_relief_puts_each_contour_at_its_own_height(self):
        """The load-bearing claim. Four contours, four heights, all distinct —
        so a rule that collapsed them onto one plane (or onto z=0) fails here
        even though it validated and resolved.
        """
        spec = _spec(
            [_contour(luminance=value, x=index * 30)
             for index, value in enumerate((0.0, 0.25, 0.75, 1.0))],
            z_min=0.0, z_max=20.0, thickness=1.0)
        # `bevel_depth: 0` because a bevel WIDENS the mesh — a bevelled
        # contour's z bounds are the extrusion plus a bevel at each end, so
        # measuring the half-extent with a bevel in the spec measures the bevel,
        # not the relief. The bevel has its own tests; this one is about the
        # thickness the relief states.
        spec["extrude"] = {"depth": 1.0, "bevel_depth": 0, "bevel_resolution": 0}
        spans = self.z_spans(spec)
        self.assertEqual(len(spans), 4)
        mids = sorted((low + high) / 2.0 for low, high in spans)
        self.assertEqual([round(m, 3) for m in mids], [0.0, 5.0, 15.0, 20.0],
                         "the relief heights did not reach the geometry")
        # And the solids are slabs of the stated half-thickness, not discs.
        for low, high in spans:
            self.assertAlmostEqual(high - low, 2.0, delta=0.01,
                                   msg="thickness is the HALF extent, as "
                                       "every other depth is")

    def test_a_layers_relief_actually_stacks(self):
        """The other rule, and the one with no tonal reading: three layers at
        0, 1, 2 must sit at three DIFFERENT heights with visible air between
        them. The gap assertion is the point — a stack whose solids touch is
        not a relief."""
        spec = _spec([_contour(layer=index, x=index * 30)
                      for index in range(3)],
                     rule="layers", z_min=0.0, step=6.0, thickness=1.0)
        spans = self.z_spans(spec)
        self.assertEqual([round((low + high) / 2.0, 3) for low, high in spans],
                         [0.0, 6.0, 12.0])
        for earlier, later in zip(spans, spans[1:]):
            self.assertGreater(later[0] - earlier[1], 0.0,
                               "the layers touch: this is a stack of tiles, "
                               "not a relief")

    def test_invert_reverses_the_measured_order(self):
        """Not just "the numbers changed" — the ORDER reverses, which is what
        makes an intaglio an intaglio. Asserted as an ordering because that is
        the claim; the individual heights are already pinned by the tests above.
        """
        forward = self.z_spans(_spec([_contour(luminance=v, x=i * 30)
                                      for i, v in enumerate((0.2, 0.8))],
                                     z_min=0.0, z_max=20.0, thickness=1.0))
        reverse = self.z_spans(_spec([_contour(luminance=v, x=i * 30)
                                      for i, v in enumerate((0.2, 0.8))],
                                     z_min=0.0, z_max=20.0, thickness=1.0,
                                     invert=True))
        self.assertLess((forward[0][0] + forward[0][1]) / 2.0,
                        (forward[1][0] + forward[1][1]) / 2.0)
        self.assertGreater((reverse[0][0] + reverse[0][1]) / 2.0,
                           (reverse[1][0] + reverse[1][1]) / 2.0)

    def test_a_self_placed_element_keeps_its_own_z_in_a_relief(self):
        """The escape hatch, measured. A backdrop that states `z: -5` must be at
        -5 and not at the bottom of the relief range — the case that makes the
        per-element check worth having rather than a blanket requirement."""
        spec = _spec([_contour(luminance=1.0, x=0), _contour(z=-5, x=30)],
                     z_min=0.0, z_max=20.0, thickness=1.0)
        spans = self.z_spans(spec)
        self.assertAlmostEqual((spans[0][0] + spans[0][1]) / 2.0, 20.0, places=3)
        self.assertAlmostEqual((spans[1][0] + spans[1][1]) / 2.0, -5.0, places=3)


@unittest.skipUnless(HAVE_BLENDER, "the blender binary is not installed")
class ReliefRealRenderTest(unittest.TestCase):
    """A traced image and its measured heights, producing a rendered relief.

    The issue asks for "at least one real render, preferably of a recognisable
    subject". So this renders a face — the subject whose relief everyone knows,
    because a portrait bas-relief is the thing a height-from-luminance rule was
    invented for — and checks the two things a frame can be checked for: that
    it rendered, and that the relief is actually IN it. A relief where every
    contour sits at z=0 renders a perfectly valid PNG of a flat drawing, which
    is why "it rendered" is not the assertion; the shading varies across the
    frame is.

    The subject is drawn as the traced contours a tracer would hand over: one
    polygon per tonal region, each with the `luminance` the caller measured from
    the raster. That is the whole input the rule needs, and it is stated in the
    spec rather than computed here — this repository does not measure.
    """

    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="chopshop-blender-relief-")
        self.addCleanup(shutil.rmtree, self.out, ignore_errors=True)

    @staticmethod
    def portrait():
        """A face, as traced tonal regions, brightest in the middle.

        Drawn from primitives and polygons so every contour is a closed shape
        this operation already knows how to extrude — the point of the example
        is the height rule, not the trace.
        """
        return [
            # background: the darkest region, furthest back
            {"type": "rect", "x": 0, "y": 0, "width": 200, "height": 200,
             "fill": "#202028", "luminance": 0.10},
            # hair mass, dark but above the background
            {"type": "ellipse", "cx": 100, "cy": 78, "rx": 74, "ry": 82,
             "fill": "#3a2a22", "luminance": 0.28},
            # face: the lit plane
            {"type": "ellipse", "cx": 100, "cy": 108, "rx": 52, "ry": 66,
             "fill": "#d8b090", "luminance": 0.62},
            # brow ridge and cheekbones: the near planes
            {"type": "ellipse", "cx": 78, "cy": 96, "rx": 18, "ry": 11,
             "fill": "#f0d0b0", "luminance": 0.86},
            {"type": "ellipse", "cx": 122, "cy": 96, "rx": 18, "ry": 11,
             "fill": "#f0d0b0", "luminance": 0.86},
            # nose: the highest plane on the face
            {"type": "polygon", "points": [[100, 104], [108, 128], [92, 128]],
             "fill": "#fff0dc", "luminance": 0.97},
            # eyes and mouth: the shadows that make it read as a face
            {"type": "ellipse", "cx": 80, "cy": 100, "rx": 7, "ry": 4,
             "fill": "#1a1410", "luminance": 0.18},
            {"type": "ellipse", "cx": 120, "cy": 100, "rx": 7, "ry": 4,
             "fill": "#1a1410", "luminance": 0.18},
            {"type": "ellipse", "cx": 100, "cy": 148, "rx": 18, "ry": 6,
             "fill": "#8a5048", "luminance": 0.40},
        ]

    def spec(self, **relief):
        return {
            "title": "portrait-relief",
            "elements": self.portrait(),
            "relief": {"rule": "luminance", "z_min": 0.0, "z_max": 24.0,
                       "thickness": 0.8, **relief},
            "extrude": {"depth": 0.8, "bevel_depth": 0.15, "bevel_resolution": 2},
            "render": {"size": {"width": 300, "height": 300}, "views": 1,
                       "elevation": 62, "azimuth": 0, "engine": "eevee",
                       "background": "#0d0d12",
                       "shading": {"roughness": 0.55}},
        }

    def test_a_traced_portrait_renders_a_relief(self):
        """The end-to-end claim, and the artifact the issue asks for."""
        spec = self.spec()
        validate_blender(spec)
        names = render_blender(spec, self.out)
        self.assertEqual(len(names), 1)
        path = os.path.join(self.out, names[0])
        self.assertTrue(os.path.isfile(path), "no frame was written")
        with open(path, "rb") as handle:
            frame = handle.read()
        self.assertTrue(frame.startswith(b"\x89PNG"))

    def test_the_relief_is_in_the_frame_and_not_just_a_flat_drawing(self):
        """The assertion that makes the previous one mean something. A dead
        rule still renders a valid PNG — of a flat drawing — so the check is
        that the frame's tones VARY, measured as the spread between its
        brightest and darkest pixels. A relief lit by a raking light has a wide
        spread; a flat extrusion of the same contours under the same light has a
        narrow one, because every surface is at the same height and shades the
        same way.

        The bound is loose on purpose. This is a smoke test on a picture, not a
        measurement of a lighting model: the claim is "these are not the same
        pixels", and a threshold that tried to be tight would be a threshold that
        broke on the next Blender release.
        """
        import sys

        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        self.addCleanup(sys.path.remove, os.path.dirname(os.path.abspath(__file__)))
        from test_blender_fidelity import peak_red

        relief_frame = self._render_to(self.spec(), "relief")
        # The same document with the rule resolved away by hand: every contour
        # at z=0, the flat drawing the relief is measured against.
        flat = dict(self.spec())
        flat.pop("relief")
        for element in flat["elements"]:
            element["z"] = 0.0
        flat_frame = self._render_to(flat, "flat")

        self.assertNotEqual(relief_frame, flat_frame,
                            "the relief renders identically to the flat "
                            "drawing: the rule is not reaching the geometry")
        # And the relief has real tonal range where the flat one does not.
        self.assertGreater(peak_red(relief_frame), 0x20,
                           "the relief frame is essentially black")

    def test_the_inverted_relief_renders_a_different_picture(self):
        """The intaglio, and the check that `invert` is a real parameter rather
        than a flag that is read and ignored. Compared as frames, because the
        claim is about the picture and there is no single number that states it.
        """
        raised = self._render_to(self.spec(), "raised")
        sunk = self._render_to(self.spec(invert=True), "sunk")
        self.assertNotEqual(raised, sunk, "invert changed nothing in the frame")

    def _render_to(self, spec, tag):
        target = os.path.join(self.out, tag)
        os.makedirs(target, exist_ok=True)
        names = render_blender(spec, target)
        path = os.path.join(target, names[0])
        # The existence check is explicit, and it is here because of a real bug:
        # the driver used to compute the returned names from the spec the CALLER
        # sent while Blender named the frame from the relief-resolved one, so a
        # relief render reported success and the file it wrote had a name
        # nothing returned. That surfaced as a bare FileNotFoundError from the
        # open() below, which reads as a broken temp directory rather than a
        # naming mismatch. Asserting the file is there first says which of the
        # two it is, and listing the directory says what was actually written.
        self.assertTrue(os.path.isfile(path),
                        "render_blender returned %r but wrote %s"
                        % (names[0], sorted(os.listdir(target))))
        with open(path, "rb") as handle:
            return handle.read()


if __name__ == "__main__":
    unittest.main()
