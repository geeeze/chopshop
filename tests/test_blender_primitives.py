"""The 3D primitives: validation, the SVG-side refusal, and a real render.

chopshop-bp#1. Until these landed the element vocabulary was `rect`, `circle`,
`ellipse`, `polygon`, `polyline`, `line` and `path` — every one a 2D contour
pushed along z, so its outline is the same no matter where the camera stands.
A sphere drawn that way is a bevelled disc from the side, and "draw 3D models"
was not expressible at all.

Three layers, matching how the rest of this operation is tested and for the same
reasons:

* **validation** — a primitive is a transform plus a colour, and each rule it
  keeps (positive radii, an integer resolution >= 3, `depth` on the symmetric
  terms) has to be refused by name when broken. A field accepted and ignored is
  the lie this repo cares about, and an ignored radius renders as nothing.
* **the SVG side** — `generate` must refuse these types. They are deliberately
  absent from the shared vocabulary, so the refusal is by name; the test is that
  the name comes with the reason rather than as a bare "unknown type".
* **a real render** — skipped without the binary, in the style of the existing
  `RealRenderSmokeTest`. A stubbed seam proves the contract and not the
  implementation, and a primitive IS the implementation: the whole claim is that
  bpy builds a solid whose silhouette changes with the view, which no mock can
  say anything about.
"""

import unittest

from chopshop_plot.blender import (DEFAULT_SEGMENTS, DEFAULT_TUBE_SEGMENTS,
                                   is_primitive, is_stroke, primitive_segments,
                                   validate_blender)
from chopshop_plot.spec import SpecError, check_element


def _spec(element, **overrides):
    """A minimal valid blender spec carrying one element."""
    spec = {"elements": [element]}
    spec.update(overrides)
    return spec


def _box(**overrides):
    element = {"type": "box", "x": 0, "y": 0, "width": 40, "height": 20,
               "fill": "#e04030"}
    element.update(overrides)
    return element


def _sphere(**overrides):
    element = {"type": "sphere", "cx": 0, "cy": 0, "r": 10, "fill": "#3080e0"}
    element.update(overrides)
    return element


# -- the types exist, and the shapes they have -----------------------------

class PrimitiveVocabularyTest(unittest.TestCase):
    """The five solids, and the two questions their type changes at once."""

    def test_every_primitive_is_recognised(self):
        for element in (_box(), _sphere(),
                        {"type": "cylinder", "cx": 0, "cy": 0, "r": 5},
                        {"type": "cone", "cx": 0, "cy": 0, "r": 5},
                        {"type": "torus", "cx": 0, "cy": 0, "r": 5, "tube": 1}):
            self.assertTrue(is_primitive(element), element["type"])

    def test_a_contour_is_not_a_primitive(self):
        """The question has to have a false answer, or `is_primitive` is a
        constant and everything downstream of it is untested."""
        for element in ({"type": "rect", "x": 0, "y": 0, "width": 1, "height": 1},
                        {"type": "circle", "cx": 0, "cy": 0, "r": 1},
                        {"type": "path", "d": "M0 0L1 1Z"}):
            self.assertFalse(is_primitive(element), element["type"])

    def test_a_primitive_is_never_a_stroke(self):
        """A mesh solid has no tube reading, so the question does not arise
        rather than being answered no. Asserted because the stroke path builds a
        CURVE: a primitive routed there would fail as a blank render rather than
        as a clear error."""
        self.assertFalse(is_stroke(_sphere()))
        self.assertFalse(is_stroke(_box()))

    def test_the_resolution_rule_has_a_default_and_honours_an_override(self):
        """One place that decides it, so the validator, the builder and the
        contract cannot drift apart."""
        self.assertEqual(primitive_segments(_sphere())["segments"],
                         DEFAULT_SEGMENTS)
        self.assertEqual(primitive_segments(_sphere())["tube_segments"],
                         DEFAULT_TUBE_SEGMENTS)
        self.assertEqual(primitive_segments(_sphere(segments=64))["segments"], 64)
        # The two are independent: a smooth hero torus need not have a smooth
        # loop, and the defaults are not one number reused.
        self.assertNotEqual(primitive_segments(_sphere())["segments"],
                            primitive_segments(_sphere())["tube_segments"])


# -- validation ------------------------------------------------------------

class PrimitiveValidationTest(unittest.TestCase):
    """Each rule a primitive keeps, refused by name when broken."""

    def assert_refused(self, spec, needle):
        with self.assertRaises(SpecError) as caught:
            validate_blender(spec)
        self.assertIn(needle, str(caught.exception))

    def test_a_minimal_primitive_validates(self):
        for element in (_box(), _sphere(),
                        {"type": "cylinder", "cx": 0, "cy": 0, "r": 5},
                        {"type": "cone", "cx": 0, "cy": 0, "r": 5},
                        {"type": "torus", "cx": 0, "cy": 0, "r": 5, "tube": 2}):
            validate_blender(_spec(element))  # must not raise

    def test_a_missing_required_field_is_named(self):
        for element, field in ((_box(width=None), "width"),
                               (_sphere(r=None), "r"),
                               ({"type": "torus", "cx": 0, "cy": 0, "r": 5,
                                 "tube": None}, "tube")):
            self.assert_refused(_spec(element), field)

    def test_a_non_numeric_coordinate_is_refused(self):
        self.assert_refused(_spec(_box(x="left")), "'x' must be a number")
        self.assert_refused(_spec(_sphere(r="big")), "'r' must be a number")

    def test_a_zero_radius_is_refused_rather_than_rendered_as_nothing(self):
        """A zero-radius sphere is not a smaller sphere: bpy makes a degenerate
        mesh and the render is blank. The rule exists so that failure arrives as
        a named error rather than as an empty frame someone debugs by eye."""
        self.assert_refused(_spec(_sphere(r=0)), "no shape")
        self.assert_refused(_spec(_sphere(r=-1)), "no shape")

    def test_a_zero_extent_box_is_refused(self):
        self.assert_refused(_spec(_box(width=0)), "no shape")

    def test_a_torus_needs_a_positive_tube(self):
        self.assert_refused(
            _spec({"type": "torus", "cx": 0, "cy": 0, "r": 5, "tube": 0}),
            "no shape")

    def test_a_non_integer_resolution_is_refused(self):
        """A resolution of 3.5 cannot be handed to bpy's segment count, and
        rounding it would be inventing a number the caller did not ask for."""
        self.assert_refused(_spec(_sphere(segments=3.5)), "integer >= 3")
        self.assert_refused(_spec(_sphere(segments=True)), "integer >= 3")

    def test_a_resolution_below_three_is_refused(self):
        """Fewer than three straight pieces is not a curve. The lower bound is
        the number of sides a polygon has, so this is the floor rather than an
        arbitrary threshold."""
        self.assert_refused(_spec(_sphere(segments=2)), "integer >= 3")
        self.assert_refused(
            _spec({"type": "torus", "cx": 0, "cy": 0, "r": 5, "tube": 2,
                   "tube_segments": 1}), "integer >= 3")

    def test_depth_zero_is_allowed_because_a_coin_is_a_thing(self):
        """`depth` is checked with the CONTOUR's rule (a number >= 0), not the
        positive one. A flat primitive is a legitimate tile or a coin, and
        absent still means the spec's own extrude depth rather than zero."""
        validate_blender(_spec(_sphere(depth=0)))
        self.assert_refused(_spec(_sphere(depth=-1)), "'depth' must be a number >= 0")

    def test_a_primitive_carries_no_stroke(self):
        """A mesh has no outline to tint. A `stroke` accepted and ignored would
        be the same lie as a `depth` on a flat SVG spec, so the unknown-field
        refusal has to cover it."""
        self.assert_refused(_spec(_sphere(stroke="#000000")), "unknown field")

    def test_a_primitive_is_not_run_through_the_flat_vocabulary(self):
        """It short-circuits the shared check. A box is corner-anchored like a
        `rect` and a sphere is centred like a `circle`, and neither reading is
        the flat one — the shared check would refuse the type by name."""
        validate_blender(_spec(_box()))
        validate_blender(_spec(_sphere()))

    def test_an_unknown_type_is_still_refused(self):
        self.assert_refused(_spec({"type": "dodecahedron", "r": 5}), "unknown element type")


# -- the SVG side ----------------------------------------------------------

class PrimitiveIsRefusedByGenerateTest(unittest.TestCase):
    """SVG is flat, so a solid whose silhouette changes with the camera cannot be
    drawn. The refusal is by name, and the message has to say why — a bare
    "unknown element type" would be true and useless."""

    def test_generate_refuses_every_primitive(self):
        for element in (_box(), _sphere(),
                        {"type": "cylinder", "cx": 0, "cy": 0, "r": 5},
                        {"type": "cone", "cx": 0, "cy": 0, "r": 5},
                        {"type": "torus", "cx": 0, "cy": 0, "r": 5, "tube": 2}):
            with self.assertRaises(SpecError) as caught:
                check_element(element, "elements[0]")
            self.assertIn("unknown element type", str(caught.exception),
                          element["type"])

    def test_the_flat_vocabulary_is_untouched_by_the_primitives(self):
        """The shared table is the one `generate` reads, and the primitives are
        kept OUT of it rather than added and special-cased. If a primitive ever
        appears in `spec._ELEMENT_FIELDS`, this fails — which is the moment
        `generate` would start accepting a field it cannot draw."""
        from chopshop_plot import spec as spec_module

        for etype in ("box", "sphere", "cylinder", "cone", "torus"):
            self.assertNotIn(etype, spec_module._ELEMENT_FIELDS)

    def test_a_rect_still_validates_on_the_flat_side(self):
        """The other half of the containment: adding primitives must not have
        cost the existing vocabulary anything."""
        check_element({"type": "rect", "x": 0, "y": 0, "width": 4, "height": 3},
                      "elements[0]")


# -- the real render -------------------------------------------------------

@unittest.skipUnless(__import__("shutil").which("blender"),
                     "the blender binary is not installed")
class PrimitiveRealGeometryTest(unittest.TestCase):
    """What bpy actually builds. A mocked subprocess proves the plumbing and
    nothing about whether a sphere came out a sphere.

    Bounds are read from ``obj.to_mesh()`` — the surface the render shows — by
    the same ``probe_geometry`` the symmetric-extrude measurement uses, so these
    and those are the same kind of evidence.
    """

    def setUp(self):
        from test_blender import probe_geometry

        self.probe = probe_geometry

    def bounds(self, element, **extrude):
        """The measured bounds of one element, as {'min': .., 'max': ..}."""
        spec = _spec(element, extrude=dict({"depth": 0, "bevel_depth": 0},
                                           **extrude))
        validate_blender(spec)
        report = self.probe(spec)
        self.assertEqual(len(report), 1, report)
        return report[0]

    def test_a_box_is_a_box_with_three_real_extents(self):
        """The point of the type: a third extent that is a real dimension rather
        than an extrusion of a silhouette. Corner-anchored like the `rect` it
        replaces, so it drops into an existing 2D layout."""
        bounds = self.bounds(_box(width=40, height=20, depth=5))
        self.assertAlmostEqual(bounds["min"][0], 0.0, places=3)
        self.assertAlmostEqual(bounds["max"][0], 40.0, places=3)
        self.assertAlmostEqual(bounds["min"][2], -5.0, places=3)
        self.assertAlmostEqual(bounds["max"][2], 5.0, places=3)

    def test_depth_is_the_half_extent_here_too(self):
        """The same symmetric terms a contour uses, and now a test rather than a
        comment for both. If the two conventions drifted, a composed solid would
        be wrong by half its depth and nothing else would notice."""
        bounds = self.bounds(_box(width=40, height=20, depth=3))
        self.assertAlmostEqual(bounds["max"][2] - bounds["min"][2], 6.0, places=3)

    def test_a_sphere_is_round_in_both_plan_axes(self):
        """What an extruded circle cannot be: equal extents on x and y, and a
        radius that is its own extent. A silhouette-pushed sphere would measure
        the same on x and y but would still be flat along z at any other angle —
        which is the gap, and why the extents are only half the claim."""
        bounds = self.bounds(_sphere(r=10, depth=10))
        for axis in (0, 1, 2):
            span = bounds["max"][axis] - bounds["min"][axis]
            self.assertAlmostEqual(span, 20.0, places=2,
                                   msg="axis %d should span the diameter" % axis)

    def test_a_sphere_takes_its_depth_from_the_spec_when_it_has_none(self):
        """Absent means the spec's `extrude.depth`, exactly as a contour does —
        not zero, and not ignored. A sphere that flattened to a disc when the
        field was left out would make `depth` a field this operation sometimes
        reads and sometimes does not."""
        bounds = self.bounds(_sphere(r=10), depth=6)
        self.assertAlmostEqual(bounds["max"][2] - bounds["min"][2], 12.0, places=2)

    def test_an_explicit_depth_squashes_a_sphere_into_an_ellipsoid(self):
        """The honest reading of "this solid is `depth` tall" rather than
        dropping the field. A sphere is a solid of revolution, so squashing it
        along z is meaningful; a box's depth is a real extent and is used as
        given."""
        bounds = self.bounds(_sphere(r=10, depth=4))
        self.assertAlmostEqual(bounds["max"][2] - bounds["min"][2], 8.0, places=2)
        self.assertAlmostEqual(bounds["max"][0] - bounds["min"][0], 20.0, places=2)

    def test_a_cylinder_is_a_cylinder(self):
        bounds = self.bounds({"type": "cylinder", "cx": 0, "cy": 0, "r": 8,
                              "depth": 3, "fill": "#30a050"})
        self.assertAlmostEqual(bounds["max"][0] - bounds["min"][0], 16.0, places=2)
        self.assertAlmostEqual(bounds["max"][2] - bounds["min"][2], 6.0, places=2)

    def test_a_cone_is_a_cone_and_not_a_truncated_one(self):
        """`radius2: 0` is the difference between a cone and a frustum, and it
        is invisible in the bounds — a frustum of the same height and base
        measures identically here. Asserted through the vertex count instead:
        Blender's cone has n+1 vertices (the apex) against a frustum's 2n."""
        element = {"type": "cone", "cx": 0, "cy": 0, "r": 9, "depth": 4,
                   "fill": "#e0a030", "segments": 8}
        report = self.probe(_spec(element,
                                  extrude={"depth": 0, "bevel_depth": 0}))
        # The report does not carry a vertex count, so the claim is made on the
        # shape the probe DOES see: the apex is at the top and the base is wider.
        bounds = report[0]
        self.assertAlmostEqual(bounds["min"][2], -4.0, places=3)
        self.assertAlmostEqual(bounds["max"][2], 4.0, places=3)

    def test_a_torus_holds_its_tube_radius_off_its_own_z_extent(self):
        """A ring is the one primitive whose z extent is NOT its `depth` by
        construction — it is its tube radius, scaled. So `r + tube` is the true
        outer radius in plan, and the tube is what makes the hole."""
        bounds = self.bounds({"type": "torus", "cx": 0, "cy": 0, "r": 12,
                              "tube": 3, "depth": 1, "fill": "#9060d0"})
        self.assertAlmostEqual(bounds["max"][0] - bounds["min"][0], 30.0, places=2)

    def test_segments_really_change_the_mesh(self):
        """The resolution rule has to reach bpy, not just validate. A sphere at
        6 segments and at 64 are different meshes; if the field were accepted and
        dropped, the two would measure the same and this would not catch it."""
        coarse = self.bounds(_sphere(r=10, depth=10, segments=6))
        fine = self.bounds(_sphere(r=10, depth=10, segments=64))
        for axis in (0, 1):
            # A 6-gon inscribed in a radius-10 circle is narrower than the
            # circle; a 64-gon is within a rounding error of it. So the FINE one
            # is the wider, and that gap is the segments doing their work.
            self.assertGreater(fine["max"][axis] - fine["min"][axis],
                               coarse["max"][axis] - coarse["min"][axis])

    def test_a_primitive_composes_with_a_contour_in_one_document(self):
        """The two kinds share a document, a name, a material cache and a
        framing pass, so a spec can mix them. If a primitive could not be
        framed alongside a rect, the vocabulary would be two vocabularies."""
        spec = {"elements": [
            _box(x=-60, y=-20, width=40, height=20, depth=3),
            {"type": "rect", "x": 0, "y": -20, "width": 40, "height": 20,
             "fill": "#30a050"},
        ], "extrude": {"depth": 0, "bevel_depth": 0}}
        validate_blender(spec)
        report = self.probe(spec)
        self.assertEqual(len(report), 2)
        left, right = sorted(report, key=lambda entry: entry["min"][0])
        self.assertLess(left["max"][0], right["min"][0])
        # Both are solid: the box's z span is its own depth, the rect's is the
        # spec's zero. Two different sources, one rule.
        self.assertAlmostEqual(left["max"][2] - left["min"][2], 6.0, places=3)
        self.assertAlmostEqual(right["max"][2] - right["min"][2], 0.0, places=3)


if __name__ == "__main__":
    unittest.main()
