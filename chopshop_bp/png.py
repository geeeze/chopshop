"""Minimal PNG writer — stdlib only (zlib + struct), no Pillow.

The pipeline sidecar stays stdlib-only; this tiny writer lets the fractal
raster renderer emit PNG without pulling in an imaging dependency.
"""

import struct
import zlib

_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def write_rgb_png(path, pixels):
    """Write an HxWx3 array of uint8 as an 8-bit RGB PNG.

    ``pixels`` is a numpy array (shape HxWx3, uint8) — the only caller is the
    fractal renderer, which already uses numpy for speed.
    """
    if not hasattr(pixels, "shape"):
        raise TypeError("write_rgb_png expects a numpy array (HxWx3, uint8)")
    h, w = pixels.shape[0], pixels.shape[1]
    raw = b"".join(b"\x00" + row.tobytes() for row in pixels)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)  # 8-bit, truecolour RGB
    out = (
        _SIGNATURE
        + _chunk(b"IHDR", ihdr)
        + _chunk(b"IDAT", zlib.compress(raw, 9))
        + _chunk(b"IEND", b"")
    )
    with open(path, "wb") as fh:
        fh.write(out)
