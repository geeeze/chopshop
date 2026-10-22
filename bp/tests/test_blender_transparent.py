#!/usr/bin/env python3
"""`render.background: "transparent"` -> a frame with an alpha channel.

The sprite path. A game engine compositing a prop over its own art needs an
alpha channel, and until now `scene.render.film_transparent` was hardcoded
False and the PNG was written RGB — every frame opaque, no way to ask for
otherwise. Three things are pinned here:

  1. THE DRIVER validates the sentinel and REFUSES a typo. `_colour` in the
     in-Blender script falls back to the default without saying so, so
     `"transparnet"` used to render the default background and report success —
     a silent no-op, which is the failure mode this repo keeps writing tests
     against.
  2. THE DEFAULT DOES NOT MOVE. An ordinary hex background must still produce
     an RGB frame, byte-identical to every cached render.
  3. THE RENDER REALLY HAS ALPHA — measured by decoding the PNG (stdlib zlib,
     same approach as `peak_red`) rather than by trusting the setup code.

The render tests skip when Blender is absent, as the rest of the suite does.
"""

import importlib
import os
import shutil
import struct
import tempfile
import unittest
import zlib

from chopshop_bp.blender import (BACKGROUND_TRANSPARENT, render_blender,
                                 resolve_render, validate_blender)
from chopshop_bp.spec import SpecError

HAVE_BLENDER = shutil.which("blender")


def read_png(png_bytes):
    """(colour_type, [alpha per pixel or None]) for an 8-bit non-interlaced PNG.

    colour_type 2 is truecolour (RGB, no alpha) and 6 is truecolour+alpha —
    the two Blender's PNG writer emits. Anything else raises rather than
    returning numbers nobody should trust, in the style of `peak_red`.
    """
    if not png_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        raise AssertionError("not a PNG")
    pos, header, idat = 8, None, bytearray()
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
    if (depth, interlace) != (8, 0) or colour not in (2, 6):
        raise AssertionError(
            f"expected 8-bit non-interlaced RGB/RGBA, got depth={depth} "
            f"colour={colour} interlace={interlace}")
    channels = 3 if colour == 2 else 4
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    alphas = []
    previous = bytearray(stride)
    pos = 0
    for _ in range(height):
        filter_type = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        for i in range(stride):                      # undo the scanline filter
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
        if colour == 6:
            alphas.extend(line[i] for i in range(3, stride, 4))
        previous = line
    return colour, (alphas if colour == 6 else None)


def spec_for(background, engine="workbench"):
    """A small, flat document: enough geometry to be visible, nothing exotic."""
    spec = {
        "elements": [
            {"type": "rect", "x": -8, "y": -8, "width": 16, "height": 16,
             "fill": "#e04030"},
        ],
        "extrude": {"depth": 1, "bevel_depth": 0},
        "render": {"size": {"width": 160, "height": 120}, "views": 1,
                   "elevation": 25, "engine": engine, "background": background},
    }
    validate_blender(spec)
    return spec


class SentinelValidationTest(unittest.TestCase):
    """The driver's half — no Blender needed."""

    def test_the_sentinel_is_accepted(self):
        validate_blender(spec_for(BACKGROUND_TRANSPARENT))   # raises if refused
        self.assertEqual(BACKGROUND_TRANSPARENT, "transparent")

    def test_a_hex_background_is_still_accepted(self):
        for value in ("#1a1a24", "#abc", "#FFFFFF"):
            with self.subTest(background=value):
                validate_blender(spec_for(value))

    def test_a_typo_is_refused_naming_both_accepted_forms(self):
        # The whole point of validating here: `_colour` substitutes the default
        # SILENTLY, so without this check a misspelling renders the default
        # background and reports success.
        spec = spec_for("#1a1a24")
        spec["render"]["background"] = "transparnet"
        with self.assertRaises(SpecError) as caught:
            validate_blender(spec)
        message = str(caught.exception)
        self.assertIn("transparent", message)
        self.assertIn("hex colour", message)
        self.assertIn("transparnet", message, "the message must show what was sent")

    def test_a_non_string_background_is_still_refused(self):
        spec = spec_for("#1a1a24")
        spec["render"]["background"] = 0xffffff
        with self.assertRaises(SpecError):
            validate_blender(spec)

    def test_resolve_render_passes_the_sentinel_through_untouched(self):
        # The in-Blender script reads the RESOLVED dict, so the sentinel has to
        # survive `resolve_render` rather than being replaced by a default.
        resolved = resolve_render({"render": {"background": BACKGROUND_TRANSPARENT}})
        self.assertEqual(resolved["background"], "transparent")

    def test_resolve_render_still_defaults_to_an_opaque_colour(self):
        resolved = resolve_render({})
        self.assertEqual(resolved["background"], "#1a1a24")
        self.assertNotEqual(resolved["background"], BACKGROUND_TRANSPARENT)


@unittest.skipUnless(HAVE_BLENDER, "the blender binary is not installed")
class TransparentRenderTest(unittest.TestCase):
    """The claim, on the artifact: decode the PNG and read the alpha channel."""

    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="bp-transparent-")
        self.addCleanup(shutil.rmtree, self.out, ignore_errors=True)

    def _render(self, background, engine="workbench"):
        names = render_blender(spec_for(background, engine), self.out)
        self.assertEqual(len(names), 1, f"expected one frame, got {names}")
        with open(os.path.join(self.out, names[0]), "rb") as handle:
            return read_png(handle.read())

    def test_a_transparent_background_writes_an_alpha_channel(self):
        for engine in ("workbench", "eevee"):
            with self.subTest(engine=engine):
                colour, alphas = self._render(BACKGROUND_TRANSPARENT, engine)
                self.assertEqual(colour, 6,
                                 f"{engine}: expected RGBA (type 6), got {colour}")
                assert alphas is not None, "an RGBA frame must decode to pixels"
                self.assertTrue(alphas, "no pixels were decoded")
                # The frame's corners are world, which film_transparent omits:
                # alpha 0 there is the compositor's way of seeing "no pixels".
                corners = [alphas[0], alphas[-1], alphas[0]]
                self.assertTrue(all(a == 0 for a in corners),
                                f"{engine}: corner alphas {corners} are not 0 — "
                                "the background was rendered, not omitted")

    def test_a_hex_background_is_still_an_opaque_rgb_frame(self):
        colour, alphas = self._render("#1a1a24")
        self.assertIsNone(alphas, "an opaque frame must carry no alpha channel")
        self.assertEqual(colour, 2,
                         "the default path changed to RGBA: every cached frame "
                         "and stored hash would move")
        self.assertIsNone(alphas, "an opaque frame must carry no alpha channel")

    def test_the_object_is_still_drawn_when_the_background_is_transparent(self):
        """Transparent background must not mean transparent subject — a sprite
        with nothing in it is the failure this test exists to catch."""
        colour, alphas = self._render(BACKGROUND_TRANSPARENT)
        self.assertEqual(colour, 6)
        assert alphas is not None, "an RGBA frame must decode to pixels"
        opaque = [a for a in alphas if a == 255]
        self.assertTrue(opaque,
                        "no fully-opaque pixel: the geometry did not render")


if __name__ == "__main__":
    unittest.main()
