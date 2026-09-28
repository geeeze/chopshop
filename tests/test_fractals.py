"""Tests for the PNG writer and the fractal renderers.

Fractal rasters need numpy (the package's ONE optional dependency); those tests
skip when it is absent so the rest of the stdlib-only suite still runs.
Sierpinski is pure SVG and always runs.
"""

import struct
import unittest
import xml.etree.ElementTree as ET

from chopshop_plot import svg
from chopshop_plot.png import write_rgb_png
from chopshop_plot.fractals import sierpinski_svg

try:
    import numpy as np
    HAVE_NUMPY = True
except ImportError:
    HAVE_NUMPY = False


def _png_header(path):
    with open(path, "rb") as fh:
        data = fh.read(33)
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "bad PNG signature"
    # IHDR: length(4) + 'IHDR'(4) + width(4) + height(4) + bitdepth(1) + colourtype(1)
    _, _, width, height, bitdepth, colourtype = struct.unpack(">IIIIBB", data[8:26])
    return width, height, bitdepth, colourtype


class TestPngWriter(unittest.TestCase):
    @unittest.skipUnless(HAVE_NUMPY, "numpy not installed")
    def test_writes_valid_rgb_png(self):
        import tempfile, os
        pixels = np.zeros((4, 5, 3), dtype=np.uint8)
        pixels[1, 1] = (255, 0, 0)
        fd, path = tempfile.mkstemp(suffix=".png")
        os.close(fd)
        try:
            write_rgb_png(path, pixels)
            w, h, depth, ctype = _png_header(path)
            self.assertEqual((w, h), (5, 4))
            self.assertEqual(depth, 8)
            self.assertEqual(ctype, 2)  # truecolour RGB
        finally:
            os.unlink(path)


class TestMandelbrot(unittest.TestCase):
    @unittest.skipUnless(HAVE_NUMPY, "numpy not installed")
    def test_center_is_interior_black(self):
        from chopshop_plot.fractals import mandelbrot
        rgb = mandelbrot(width=64, height=64, max_iter=64)
        # the origin is in the set -> interior -> black
        h, w = rgb.shape[0], rgb.shape[1]
        self.assertEqual(tuple(rgb[h // 2, w // 2]), (0, 0, 0))

    @unittest.skipUnless(HAVE_NUMPY, "numpy not installed")
    def test_far_corner_escapes_nonblack(self):
        from chopshop_plot.fractals import mandelbrot
        rgb = mandelbrot(width=64, height=64, max_iter=64,
                         xmin=-2.2, xmax=0.8, ymin=-1.2, ymax=1.2)
        # top-left = (-2.2, +1.2) escapes immediately -> coloured, not black
        self.assertNotEqual(tuple(rgb[0, 0]), (0, 0, 0))

    @unittest.skipUnless(HAVE_NUMPY, "numpy not installed")
    def test_shape_is_h_w_3(self):
        from chopshop_plot.fractals import mandelbrot
        rgb = mandelbrot(width=32, height=20, max_iter=32)
        self.assertEqual(rgb.shape, (20, 32, 3))


class TestJulia(unittest.TestCase):
    @unittest.skipUnless(HAVE_NUMPY, "numpy not installed")
    def test_julia_renders(self):
        from chopshop_plot.fractals import julia
        rgb = julia(width=48, height=48, max_iter=64)
        self.assertEqual(rgb.shape, (48, 48, 3))
        self.assertEqual(rgb.dtype, np.uint8)


class TestFern(unittest.TestCase):
    @unittest.skipUnless(HAVE_NUMPY, "numpy not installed")
    def test_fern_has_structure(self):
        from chopshop_plot.fractals import barnsley_fern
        rgb = barnsley_fern(width=60, height=80, n_points=20_000, seed=1)
        self.assertEqual(rgb.shape, (80, 60, 3))
        # the fern accumulates mass around the stem (x mid, upper region) — not
        # all-black
        self.assertTrue((rgb[..., 1] > 0).any(), "fern rendered all-black")


class TestSierpinski(unittest.TestCase):
    def _tri_count(self, svg_text, depth):
        root = ET.fromstring(svg_text)
        polys = [el for el in root.iter() if el.tag.rsplit("}", 1)[-1] == "polygon"]
        return len(polys)

    def test_sierpinski_triangle_count(self):
        # depth d -> 3^d solid triangles
        depth = 4
        text = sierpinski_svg(size=600, depth=depth)
        self.assertEqual(self._tri_count(text, depth), 3 ** depth)

    def test_sierpinski_well_formed_with_viewbox(self):
        root = ET.fromstring(sierpinski_svg(size=600, depth=3))
        self.assertEqual(root.tag.rsplit("}", 1)[-1], "svg")
        self.assertIsNotNone(root.get("viewBox"))


if __name__ == "__main__":
    unittest.main()
