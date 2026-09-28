"""chopshop-plot — a geometry source and a run reporter for the chopshop pipeline.

Two operations, one language-agnostic JSON contract (docs/contract.md):

- ``generate``: a geometry spec -> SVG (shapes, tiling, patterns).
- ``digest``:    a metrics spec  -> chart SVG (bar / scatter / line).

The reference implementation is stdlib-only and writes SVG directly, because
SVG is the pipeline's native vector format. See README.md for the why.
"""

from .svg import svg_document, rect, circle, ellipse, polygon, polyline, line, path, text
from .spec import SpecError, validate_generate, validate_digest
from .generate import generate
from .digest import digest

__all__ = [
    "svg_document", "rect", "circle", "ellipse", "polygon", "polyline", "line",
    "path", "text",
    "SpecError", "validate_generate", "validate_digest",
    "generate", "digest",
]
