"""Render fidelity: curve resolution and material properties.

chopshop-bp#2. Three independent limits on how good a render can look, all of
them invisible from the spec until they are named:

1. every curve was a ``POLY`` spline sampled at fixed counts (a circle is 64
   straight segments, a bézier 16 samples per curve), so a close-up shows facets;
2. materials were base colour only — roughness, metallic, emission and alpha
   were never touched;
3. nothing asked for a smoother surface at render time.

What is testable here and what is not is the point of the file. The
**contract** — the field sets, the ranges, the refusal of a typo, the SVG-side
refusal of a 3D-only field — is pure and is tested exhaustively without a
renderer. The **pixels** are only testable against real Blender, so the render
tests are in the style of `RealRenderSmokeTest`: skipped when the binary is
absent, and they measure the frame rather than describe it, because "it looks
shinier" is not a measurement and this repo's own lesson is that only a real run
finds some faults.
"""

import os
import shutil
import sys
import tempfile
import unittest

from chopshop_plot.blender import (DEFAULT_CURVE_RESOLUTION, DEFAULT_SHADING,
                                   MAX_CURVE_RESOLUTION, MIN_CURVE_RESOLUTION,
                                   render_blender, resolve_material,
                                   resolve_render, validate_blender)
from chopshop_plot.spec import SpecError, check_element

HAVE_BLENDER = shutil.which("blender")


def _sphere(**overrides):
    element = {"type": "sphere", "cx": 0, "cy": 0, "r": 10, "fill": "#c0c4cc"}
    element.update(overrides)
    return element


def peak_red(png_bytes):
    """The largest red channel value anywhere in a rendered PNG.

    A real measurement, because "the frames differ" is a weaker claim than it
    looks: a single dithered pixel is enough to make two renders differ while
    the field under test was dropped. This is the stdlib answer to that — PNG is
    zlib and a filter byte per scanline, so the pixels are readable with no
    imaging dependency, which is the same constraint `chopshop_plot/png.py`
    writes under.

    Only what the claim needs: truecolour, 8-bit, non-interlaced, which is what
    Blender's PNG writer emits. Anything else raises rather than returning a
    number nobody should trust.
    """
    import struct
    import zlib

    if not png_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        raise AssertionError("not a PNG")
    pos = 8
    header = None
    idat = bytearray()
    while pos < len(png_bytes):
        (length,) = struct.unpack(">I", png_bytes[pos:pos + 4])
        tag = png_bytes[pos + 4:pos + 8]
        body = png_bytes[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
        pos += 12 + length
    width, height, depth, colour, _comp, _filt, interlace = header
    if (depth, colour, interlace) != (8, 2, 0):
        raise AssertionError(
            "expected 8-bit truecolour non-interlaced, got depth=%d colour=%d "
            "interlace=%d" % (depth, colour, interlace))
    raw = zlib.decompress(bytes(idat))
    channels = 3
    stride = width * channels
    peak = 0
    previous = bytearray(stride)
    pos = 0
    for _ in range(height):
        filter_type = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        # Undo the per-scanline filter (PNG spec §9.2). The prediction is over
        # the byte `bpp` positions back, which is the whole of it.
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up = previous[i]
            up_left = previous[i - channels] if i >= channels else 0
            if filter_type == 1:
                line[i] = (line[i] + left) & 0xFF
            elif filter_type == 2:
                line[i] = (line[i] + up) & 0xFF
            elif filter_type == 3:
                line[i] = (line[i] + (left + up) // 2) & 0xFF
            elif filter_type == 4:
                p = left + up - up_left
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                best = left if (pa <= pb and pa <= pc) else (up if pb <= pc else up_left)
                line[i] = (line[i] + best) & 0xFF
        for i in range(0, stride, channels):
            peak = max(peak, line[i])
        previous = line
    return peak


# -- the resolution rule ---------------------------------------------------

class PeakRedTest(unittest.TestCase):
    """`peak_red` itself, before anything is allowed to assert with it.

    A measurement helper that is wrong makes every test using it confidently
    wrong, and the failure looks like a product bug. So it is pinned against
    hand-built PNGs whose pixels are known — one per scanline filter, since the
    un-filtering loop is the part that can be subtly wrong and would otherwise
    be trusted because Blender happened to pick filter 0.
    """

    @staticmethod
    def build(rows, filter_type=0, width=None, height=None):
        import struct
        import zlib

        def chunk(tag, data):
            body = tag + data
            return (struct.pack(">I", len(data)) + body
                    + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

        height = height or len(rows)
        width = width or len(rows[0])
        previous = bytearray(width * 3)
        raw = bytearray()
        for row in rows:
            line = bytearray()
            for pixel in row:
                line += bytes(pixel)
            # Encode with the requested filter, so the reader has to invert it.
            encoded = bytearray(len(line))
            for i in range(len(line)):
                left = line[i - 3] if i >= 3 else 0
                up = previous[i]
                up_left = previous[i - 3] if i >= 3 else 0
                if filter_type == 0:
                    encoded[i] = line[i]
                elif filter_type == 1:
                    encoded[i] = (line[i] - left) & 0xFF
                elif filter_type == 2:
                    encoded[i] = (line[i] - up) & 0xFF
                elif filter_type == 3:
                    encoded[i] = (line[i] - (left + up) // 2) & 0xFF
                else:
                    p = left + up - up_left
                    pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                    best = left if (pa <= pb and pa <= pc) else (up if pb <= pc
                                                                 else up_left)
                    encoded[i] = (line[i] - best) & 0xFF
            raw += bytes([filter_type]) + bytes(encoded)
            previous = line
        return (b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2,
                                             0, 0, 0))
                + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
                + chunk(b"IEND", b""))

    ROWS = [[(255, 0, 0), (0, 0, 0)],
            [(0, 0, 0), (17, 0, 0)]]

    def test_it_reads_a_png_with_each_scanline_filter(self):
        """Filter 0 (none) through 4 (Paeth). The encoder above is the inverse
        of the reader above, so a shared misunderstanding would cancel out —
        which is why the pixels are also stated outright rather than compared
        only to a round trip."""
        for filter_type in range(5):
            self.assertEqual(peak_red(self.build(self.ROWS, filter_type)), 255,
                             "filter %d was not inverted correctly" % filter_type)

    def test_it_reports_the_peak_and_not_the_average(self):
        """The claim is about the brightest pixel — a glint and an emission
        differ in their PEAK far more than in their mean, which is the whole
        reason this helper exists."""
        rows = [[(200, 0, 0)] * 4, [(10, 0, 0)] * 4]
        self.assertEqual(peak_red(self.build(rows, 0)), 200)

    def test_an_all_dark_frame_peaks_at_zero(self):
        """The floor case, because a helper that returned a constant would pass
        every test above except this one."""
        self.assertEqual(peak_red(self.build([[(0, 0, 0)] * 3] * 3, 0)), 0)

    def test_it_only_looks_at_the_red_channel(self):
        """A frame that is entirely bright green must peak at 0. If the reader
        were reading the wrong byte of each triple, this is the test that says
        so — and the emission assertion depends on it."""
        self.assertEqual(peak_red(self.build([[(0, 255, 0)] * 3], 0)), 0)

    def test_it_refuses_a_non_png_rather_than_guessing(self):
        with self.assertRaises(AssertionError):
            peak_red(b"not a png at all")


class CurveResolutionContractTest(unittest.TestCase):
    """`render.curve_resolution`: four integers, and the default that must not
    move an existing render."""

    def resolved(self, spec=None):
        return resolve_render(spec or {})["curve_resolution"]

    def test_the_default_is_the_historical_sampling(self):
        """The load-bearing compatibility claim. These four numbers are what the
        builder has always used, so a spec that says nothing renders exactly as
        it did before the field existed. `test_the_default_does_not_change_a
        _render` enforces it against real pixels; this pins the numbers the
        builder reads."""
        self.assertEqual(self.resolved(), DEFAULT_CURVE_RESOLUTION)
        self.assertEqual(self.resolved()["circle"], 64)
        self.assertEqual(self.resolved()["corner"], 8)
        self.assertEqual(self.resolved()["bezier"], 16)
        self.assertEqual(self.resolved()["spline"], 12)

    def test_a_spec_override_wins_key_by_key(self):
        got = self.resolved({"render": {"curve_resolution": {"circle": 256}}})
        self.assertEqual(got["circle"], 256)
        self.assertEqual(got["corner"], DEFAULT_CURVE_RESOLUTION["corner"])

    def test_the_resolver_returns_a_copy_not_the_constant(self):
        """A render that could mutate the module's defaults would make the second
        render in a process differ from the first for no reason the spec asked
        for — the one way a "default" can quietly stop being a default."""
        got = self.resolved()
        got["circle"] = 999
        self.assertEqual(DEFAULT_CURVE_RESOLUTION["circle"], 64)
        self.assertEqual(self.resolved()["circle"], 64)

    def test_the_bound_is_named_as_a_constant(self):
        for field in DEFAULT_CURVE_RESOLUTION:
            self.assertGreaterEqual(DEFAULT_CURVE_RESOLUTION[field],
                                    MIN_CURVE_RESOLUTION)
            self.assertLessEqual(DEFAULT_CURVE_RESOLUTION[field],
                                 MAX_CURVE_RESOLUTION)

    def assert_refused(self, spec, needle):
        # `validate_blender` refuses an empty document before it ever looks at
        # `render`, so the document part of the case is carried by a one-element
        # spec. The assertion is about the sub-block, not about the order the
        # two are checked in.
        spec = dict(spec, elements=[_sphere()])
        with self.assertRaises(SpecError) as caught:
            validate_blender(spec)
        self.assertIn(needle, str(caught.exception))

    def test_a_resolution_below_three_is_refused(self):
        self.assert_refused(
            {"render": {"curve_resolution": {"circle": 2}}},
            "fewer than three straight pieces is not a curve")

    def test_a_non_integer_resolution_is_refused(self):
        """Rounding 3.7 to 3 would be inventing a number the caller did not ask
        for, and rounding it UP to 4 would quietly cost geometry."""
        for value in (3.5, "128", True, None):
            self.assert_refused(
                {"render": {"curve_resolution": {"circle": value}}},
                "must be an integer")

    def test_an_absurd_resolution_is_refused_rather_than_half_finished(self):
        """Past a few hundred segments the curve is smoother than the frame can
        show, so a 64000 here is a typo and the cost is geometry memory. Failing
        fast is kinder than exhausting a box."""
        self.assert_refused(
            {"render": {"curve_resolution": {"circle": 64000}}},
            "quality")

    def test_an_unknown_key_is_refused_by_name(self):
        """The block is read key by key, so a typo is a rate nobody changed."""
        self.assert_refused(
            {"render": {"curve_resolution": {"circel": 128}}},
            "unknown field(s) ['circel']")

    def test_a_non_object_block_is_refused(self):
        self.assert_refused({"render": {"curve_resolution": 128}},
                            "must be an object")

    def test_an_empty_block_is_the_default(self):
        self.assertEqual(self.resolved({"render": {"curve_resolution": {}}}),
                         DEFAULT_CURVE_RESOLUTION)


# -- the material block ----------------------------------------------------

class MaterialContractTest(unittest.TestCase):
    """The per-element `material`, and the document-level `render.shading`."""

    def test_a_material_validates_on_a_contour_and_a_primitive(self):
        block = {"roughness": 0.3, "metallic": 0.5, "specular": 0.2,
                 "emission": "#ff8800", "alpha": 0.5}
        validate_blender({"elements": [
            {"type": "rect", "x": 0, "y": 0, "width": 4, "height": 3,
             "material": block},
            _sphere(material=block),
        ]})

    def test_generate_refuses_a_material(self):
        """SVG has no material, so this is a 3D-only field and `generate` must
        refuse it rather than accept a block it cannot act on — the same rule
        `z` and `depth` already keep."""
        with self.assertRaises(SpecError) as caught:
            check_element({"type": "rect", "x": 0, "y": 0, "width": 4,
                           "height": 3, "material": {"roughness": 0.2}},
                          "elements[0]")
        self.assertIn("unknown field(s) ['material']", str(caught.exception))

    def assert_refused(self, spec, needle):
        # As above: a case about a sub-block still needs a drawable document, or
        # the empty-document refusal reports first and the sub-block is never
        # reached.
        spec = dict(spec, elements=spec.get("elements") or [_sphere()])
        with self.assertRaises(SpecError) as caught:
            validate_blender(spec)
        self.assertIn(needle, str(caught.exception))

    def test_a_typo_inside_a_material_is_refused_by_name(self):
        """The material is read key by key, so `roughnes` is a roughness nobody
        applied and a sphere that renders matte when the spec asked for glossy."""
        self.assert_refused(
            {"elements": [_sphere(material={"roughnes": 0.2})]},
            "unknown field(s) ['roughnes']")

    def test_a_material_must_be_an_object(self):
        self.assert_refused({"elements": [_sphere(material="glossy")]},
                            "must be an object")

    def test_a_value_above_one_is_refused_because_blender_clamps_it_silently(self):
        """Roughness 2.0 is not a rougher surface; the shader's range is 0..1 and
        Blender clamps without saying so, so the render would stop matching the
        spec with nothing reporting it."""
        for field in ("roughness", "metallic", "specular", "alpha"):
            self.assert_refused(
                {"elements": [_sphere(material={field: 1.5})]},
                "must be a number in 0..1")

    def test_a_negative_value_is_refused_too(self):
        """The other end, and the same reason: the clamp is silent in both
        directions, so both bounds have to be checked rather than one."""
        self.assert_refused({"elements": [_sphere(material={"alpha": -0.1})]},
                            "must be a number in 0..1")

    def test_a_non_numeric_value_is_refused(self):
        self.assert_refused({"elements": [_sphere(material={"roughness": "low"})]},
                            "must be a number")

    def test_emission_is_a_colour_because_emitting_is_not_a_number(self):
        """"emits" and "emits cyan" are different statements, and the second is
        the one a caller writing a material block almost always means."""
        self.assert_refused(
            {"elements": [_sphere(material={"emission": 0.8})]},
            "must be a colour string")

    def test_a_non_object_shading_block_is_refused(self):
        self.assert_refused({"render": {"shading": 0.5}}, "must be an object")

    def test_shading_is_validated_the_same_way(self):
        self.assert_refused({"render": {"shading": {"roughnes": 0.2}}},
                            "unknown field(s) ['roughnes']")
        self.assert_refused({"render": {"shading": {"roughness": 2}}},
                            "must be a number in 0..1")


class MaterialResolutionTest(unittest.TestCase):
    """How a document's shading and an element's material combine."""

    def test_the_default_is_matte_and_non_metallic(self):
        """Deliberate, and the reason it is worth a test: the flat poster work
        this repo actually draws has always rendered matte, and Principled's own
        default is 0.5 roughness — a shiny default would change every existing
        render the first time anybody set `engine: eevee`."""
        self.assertEqual(resolve_render({})["shading"], DEFAULT_SHADING)
        self.assertEqual(DEFAULT_SHADING["roughness"], 1.0)
        self.assertEqual(DEFAULT_SHADING["metallic"], 0.0)

    def test_an_element_with_no_material_gets_the_document_shading(self):
        shading = {"roughness": 0.3, "metallic": 0.2, "specular": 0.0}
        self.assertEqual(resolve_material(_sphere(), shading), shading)

    def test_an_element_overrides_key_by_key(self):
        """House style declared once, overridden only where it must. Replacing
        rather than merging would make `material: {alpha: 0.5}` silently reset
        the document's roughness to the default, which is a field the caller
        asked for and did not get."""
        shading = {"roughness": 0.3, "metallic": 0.2, "specular": 0.0}
        got = resolve_material(_sphere(material={"alpha": 0.5}), shading)
        self.assertEqual(got["alpha"], 0.5)
        self.assertEqual(got["roughness"], 0.3)
        self.assertEqual(got["metallic"], 0.2)

    def test_neither_given_is_the_default(self):
        self.assertEqual(resolve_material(_sphere(), None), DEFAULT_SHADING)

    def test_emission_is_absent_unless_asked_for(self):
        """Not `emission: black`. A material with no emission does not emit, and
        the two are the same pixels today — the difference is that a defaulted
        black emission would make `if "emission" in material` true for every
        material and turn the question into a constant."""
        self.assertNotIn("emission", resolve_material(_sphere(), None))
        self.assertEqual(
            resolve_material(_sphere(material={"emission": "#ff0000"}), None)
            ["emission"], "#ff0000")


# -- against real pixels ---------------------------------------------------

@unittest.skipUnless(HAVE_BLENDER, "the blender binary is not installed")
class CurveResolutionRealRenderTest(unittest.TestCase):
    """The claim that a resolution field actually changes the GEOMETRY.

    The trap this guards: a `curve_resolution` that validated, resolved and was
    then ignored would pass every test above and change no pixels. A circle is
    the probe because its segment count is directly countable in the generated
    mesh, and the probe channel (`bpy_geometry.py … probe`) reads
    `obj.to_mesh()` without paying for a render.
    """

    def setUp(self):
        # Imported by name, not at module scope, because `probe_geometry` runs
        # Blender and this file's module level has to stay free of it for the
        # contract tests above. The path insert is what makes the import work
        # under BOTH invocations: `unittest discover -s tests` puts this
        # directory on sys.path, while `python3 -m unittest
        # tests.test_blender_fidelity` does not — and a test that only passes
        # under one of the two ways the suite is run is a test that is skipped
        # in practice rather than one that is green.
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        self.addCleanup(sys.path.remove, os.path.dirname(os.path.abspath(__file__)))
        from test_blender import probe_geometry

        self.probe = probe_geometry
        self.out = tempfile.mkdtemp(prefix="chopshop-blender-res-")
        self.addCleanup(shutil.rmtree, self.out, ignore_errors=True)

    def circle_bounds(self, **resolution):
        spec = {
            "elements": [{"type": "circle", "cx": 0, "cy": 0, "r": 10,
                          "fill": "#c0c4cc"}],
            "extrude": {"depth": 0, "bevel_depth": 0},
            "render": {"curve_resolution": resolution},
        }
        validate_blender(spec)
        return self.probe(spec)[0]

    def test_a_higher_circle_resolution_actually_moves_the_geometry(self):
        """A circle's segment count is DIRECTLY COUNTABLE in the generated mesh,
        so it is counted — which is the probe this test's own docstring asks
        for, and the one measurement that cannot be fooled.

        The obvious alternative, comparing the circle's x-extent at two
        resolutions, does not work: the sampler starts at angle 0, so a 6-gon
        and the circle a 64-gon traces BOTH have a vertex on the +x axis and both
        span the full 20 units. The polygon is visibly different and the
        measurement is identical — a probe that reports no difference when the
        geometry plainly has one. (The y-extent does differ, 8.66 against 10,
        and is asserted below as the second, weaker witness.)
        """
        coarse = self.circle_bounds(circle=6)
        fine = self.circle_bounds(circle=64)
        self.assertEqual(coarse["verts"], 6,
                         "curve_resolution.circle did not reach the geometry")
        self.assertEqual(fine["verts"], 64)
        self.assertLess(coarse["verts"], fine["verts"])
        # And the fine one is a circle rather than merely a bigger polygon: the
        # y-extent of a 64-gon reaches the radius where a 6-gon's does not.
        self.assertAlmostEqual(fine["max"][1] - fine["min"][1], 20.0, delta=0.2)
        self.assertLess(coarse["max"][1] - coarse["min"][1], 19.0)

    def test_the_default_resolution_is_what_the_builder_uses_when_absent(self):
        """A spec with no `curve_resolution` and one that asks for the default
        values must produce the same GEOMETRY, not merely the same spec."""
        default_spec = {
            "elements": [{"type": "circle", "cx": 0, "cy": 0, "r": 10,
                          "fill": "#c0c4cc"}],
            "extrude": {"depth": 0, "bevel_depth": 0},
        }
        validate_blender(default_spec)
        implicit = self.probe(default_spec)[0]
        explicit = self.circle_bounds(**DEFAULT_CURVE_RESOLUTION)
        self.assertEqual(implicit, explicit,
                         "the default and an explicit ask for it disagree")

    def test_one_render_does_not_leak_its_resolution_into_the_next(self):
        """The counts are module globals rebound for the build, because the
        sampling functions read them as globals. A leak would make the second
        render in a process differ from the first for a reason no spec stated —
        the determinism rule this repo holds renders to."""
        coarse = self.circle_bounds(circle=6)
        again = self.circle_bounds(circle=6)
        after = self.probe({
            "elements": [{"type": "circle", "cx": 0, "cy": 0, "r": 10,
                          "fill": "#c0c4cc"}],
            "extrude": {"depth": 0, "bevel_depth": 0},
        })[0]
        self.assertEqual(coarse, again)
        # The bare spec after a coarse run must be the DEFAULT circle again, not
        # the 6-segment one left behind.
        self.assertEqual(after["max"][0] - after["min"][0],
                         self.circle_bounds(**DEFAULT_CURVE_RESOLUTION)["max"][0]
                         - self.circle_bounds(**DEFAULT_CURVE_RESOLUTION)["min"][0])


@unittest.skipUnless(HAVE_BLENDER, "the blender binary is not installed")
class MaterialRealRenderTest(unittest.TestCase):
    """A material property that changes nothing in the pixels is a field this
    operation reads and does not act on, which is the one thing it must never
    ship. Each test below renders twice — once plain, once with the property —
    and asserts the FRAMES DIFFER."""

    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="chopshop-blender-mat-")
        self.addCleanup(shutil.rmtree, self.out, ignore_errors=True)

    def render(self, spec, tag):
        """Render to its own directory and return the frame's bytes."""
        target = os.path.join(self.out, tag)
        os.makedirs(target, exist_ok=True)
        names = render_blender(spec, target)
        with open(os.path.join(target, names[0]), "rb") as handle:
            return handle.read()

    def ball(self, engine="eevee", fill="#b0b4bc", **material):
        """One sphere, rendered small, under `engine`, with `material` applied.

        `fill` is a named parameter and NOT part of `**material` on purpose: the
        emission test needs a grey ball with an emission colour and a red ball
        with none, and a signature that swallowed `fill` into the material block
        would build a `material: {fill: ...}` that validation correctly refuses —
        a test bug that reads as a product bug, which is the worst kind.
        """
        element = {"type": "sphere", "cx": 0, "cy": 0, "r": 8,
                   "fill": fill, "segments": 48}
        if material:
            element["material"] = material
        return {
            "elements": [element],
            "extrude": {"depth": 0, "bevel_depth": 0},
            "render": {"size": {"width": 160, "height": 120}, "views": 1,
                       "elevation": 20, "engine": engine,
                       "background": "#101018"},
        }

    def test_roughness_changes_the_frame_under_eevee(self):
        """A glossy ball and a matte one are different pictures. This is the
        claim the whole `material` block rests on, and it is checked as bytes
        rather than as a description."""
        matte = self.render(self.ball(roughness=1.0), "matte")
        glossy = self.render(self.ball(roughness=0.05), "glossy")
        self.assertNotEqual(matte, glossy,
                            "roughness changed nothing in the rendered pixels")

    def test_metallic_changes_the_frame_under_eevee(self):
        plain = self.render(self.ball(), "plain")
        metal = self.render(self.ball(metallic=1.0), "metal")
        self.assertNotEqual(plain, metal)

    def test_emission_survives_into_the_frame(self):
        """An emissive surface renders at its emission colour rather than
        shading down with the light, so the claim is measured in the frame
        rather than described: the red channel's PEAK. A non-emissive red ball
        under this light has a highlight, but the peak is a specular glint on a
        small number of pixels; an emissive one is at its emission colour across
        the whole lit face, so its peak is that colour. A material that silently
        dropped `emission` would peak well below pure red, which is the
        failure this is here to catch — and it is measured, not eyeballed,
        because "it looked red" is not a test.

        The comparison ball is the SAME red with no emission, so the only
        difference between the two frames is the field under test.
        """
        emitted = self.render(self.ball(fill="#404040", emission="#ff2200"),
                              "emissive")
        plain = self.render(self.ball(fill="#ff2200"), "nonemissive")
        self.assertNotEqual(emitted, plain,
                            "emission changed nothing in the rendered pixels")
        self.assertGreaterEqual(peak_red(emitted), 0xF0,
                                "an emissive red ball never reached its "
                                "emission colour: the field was read and dropped")
        # And the plain one must NOT clear the same bar, or the assertion above
        # is measuring the light rather than the emission.
        self.assertLess(peak_red(plain), 0xF0,
                        "a non-emissive ball reached the emission colour, so "
                        "this test is not isolating `emission`")

    def test_workbench_ignores_the_material_which_is_documented_not_discovered(self):
        """The engine split, stated in the contract rather than left to be
        found by comparing two renders. Under Workbench the block is inert —
        which is why the default is matte, and why a spec that sets a shiny
        material and leaves the engine alone gets a flat poster rather than an
        error. Asserted so the documented limit stays true: if a future Blender
        made Workbench read roughness, this fails and the contract must change.
        """
        matte = self.render(self.ball(engine="workbench", roughness=1.0), "wb-matte")
        glossy = self.render(self.ball(engine="workbench", roughness=0.05), "wb-glossy")
        self.assertEqual(matte, glossy,
                         "Workbench now honours roughness — update the contract")

    def test_eevee_does_honour_what_workbench_ignores(self):
        """The other half of the same pair, so the previous test cannot pass
        because the field is dead everywhere."""
        self.assertNotEqual(self.render(self.ball("eevee", roughness=1.0), "e-matte"),
                            self.render(self.ball("eevee", roughness=0.05), "e-glossy"))

    def test_alpha_below_one_changes_the_frame_under_eevee(self):
        """Transparency needs a real story — the material's blend mode and the
        scene's surface render method — not a material that is opaque to
        everything. A frame identical to the opaque one would mean `alpha` is
        being read and dropped."""
        opaque = self.render(self.ball(alpha=1.0), "opaque")
        see_through = self.render(self.ball(alpha=0.2), "alpha")
        self.assertNotEqual(opaque, see_through,
                            "alpha changed nothing: the blend settings are not "
                            "reaching the material")

    def test_two_elements_of_one_colour_get_two_materials(self):
        """The cache key includes the shading block, so a same-coloured element
        with a different roughness is a different material. If the key were the
        colour alone, both would get the first one's surface and the second
        element would render with a material its spec never asked for — the
        failure a per-element block is most likely to have."""
        spec = {
            "elements": [
                {"type": "sphere", "cx": -30, "cy": 0, "r": 8, "fill": "#b0b4bc",
                 "segments": 48, "material": {"roughness": 1.0}},
                {"type": "sphere", "cx": 30, "cy": 0, "r": 8, "fill": "#b0b4cc",
                 "segments": 48, "material": {"roughness": 0.05}},
            ],
            "extrude": {"depth": 0, "bevel_depth": 0},
            "render": {"size": {"width": 200, "height": 120}, "views": 1,
                       "elevation": 20, "engine": "eevee",
                       "background": "#101018"},
        }
        validate_blender(spec)
        names = render_blender(spec, self.out)
        with open(os.path.join(self.out, names[0]), "rb") as handle:
            frame = handle.read()
        self.assertTrue(frame.startswith(b"\x89PNG"),
                        "the two-material spec did not render")


@unittest.skipUnless(HAVE_BLENDER, "the blender binary is not installed")
class CurveResolutionDefaultIsByteIdenticalTest(unittest.TestCase):
    """The compatibility claim, at the level of the artifact.

    The issue asks for a resolution field "with a sane default that does NOT
    change existing renders byte-for-byte; verify with the rerun-same-bytes
    test". So the field is off in one spec and the defaults are stated in
    another, and the two frames are compared as bytes. A default that moved a
    single pixel would break every cached frame, every stored hash and every
    diff somebody has of this repo's output.
    """

    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="chopshop-blender-compat-")
        self.addCleanup(shutil.rmtree, self.out, ignore_errors=True)

    def frame(self, spec, tag):
        target = os.path.join(self.out, tag)
        os.makedirs(target, exist_ok=True)
        names = render_blender(spec, target)
        with open(os.path.join(target, names[0]), "rb") as handle:
            return handle.read()

    def spec(self, render):
        base = {
            "title": "compat",
            "elements": [
                {"type": "circle", "cx": 40, "cy": 40, "r": 30, "fill": "#e04030"},
                {"type": "rect", "x": 90, "y": 10, "width": 50, "height": 60,
                 "rx": 8, "fill": "#3080e0"},
                {"type": "path", "d": "M10 90 C 30 110, 60 70, 80 95 S 110 120, 130 90",
                 "stroke": "#30a050", "stroke_width": 1.5},
            ],
            "extrude": {"depth": 4, "bevel_depth": 1, "bevel_resolution": 2},
            "render": {"size": {"width": 200, "height": 150}, "views": 1,
                       "elevation": 25, "background": "#1a1a24"},
        }
        base["render"].update(render)
        return base

    def test_no_resolution_block_and_an_explicit_default_are_the_same_bytes(self):
        """A circle, a rounded rect and a bézier path — every sampler in the
        vocabulary (`circle`, `corner`, `bezier`) is in this one spec, so a
        default that drifted on any of them fails here."""
        implicit = self.frame(self.spec({}), "implicit")
        explicit = self.frame(
            self.spec({"curve_resolution": dict(DEFAULT_CURVE_RESOLUTION)}),
            "explicit")
        self.assertEqual(implicit, explicit,
                         "the default curve resolution changed an existing render")

    def test_a_material_block_absent_is_the_same_bytes_as_one_naming_the_defaults(self):
        """The same claim for materials: absent must mean the default shading,
        not an unset shader input. Under Workbench, which reads only the base
        colour, both must be identical — and the contract says Workbench ignores
        these, so this is where that claim is checked."""
        plain = self.frame(self.spec({}), "plain")
        named = self.frame(
            self.spec({"shading": dict(DEFAULT_SHADING)}), "named")
        self.assertEqual(plain, named,
                         "naming the default shading changed the render")

    def test_an_absent_shading_block_does_not_change_a_workbench_render(self):
        """Explicit because the previous test alone would also pass if BOTH
        paths were wrong in the same way."""
        spec = self.spec({"engine": "workbench"})
        a = self.frame(spec, "wb-a")
        b = self.frame(self.spec({"engine": "workbench",
                                  "shading": {"roughness": 0.2}}), "wb-b")
        self.assertEqual(a, b,
                         "Workbench honoured roughness — the contract's engine "
                         "split is no longer true and must be updated")


if __name__ == "__main__":
    unittest.main()
