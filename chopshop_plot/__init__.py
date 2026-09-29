"""chopshop-bp — the blend-plot service: it draws documents and renders 3D.

The ``plot`` half draws documents and the ``blender`` half renders geometry in
3D, behind one language-agnostic JSON contract (docs/contract.md). Six
operations:

- ``generate``: a geometry spec -> SVG (shapes, tiling, patterns).
- ``digest``:    a metrics spec  -> chart SVG (bar / scatter / line).
- ``query``:     run records + a chart spec -> SVG (cross-run scatter, Pareto
                 frontier, two-way diff).
- ``tree``:      a hierarchy spec (nodes + edges) -> a layered tree SVG.
- ``log``:       an event spec -> a vertical event-timeline SVG.
- ``blender``:   a geometry spec -> rendered 3D (PNG frames, optional GLB) via a
                 headless Blender process. The one operation that does not answer
                 with a document, and the one that needs something installed
                 (``CHOPSHOP_BLENDER_BINARY``); ``bpy`` is never imported here.

The reference implementation is stdlib-only and writes SVG directly, because
SVG is the pipeline's native vector format. See README.md for the why. The
operations also ride over HTTP (``chopshop_plot.server``, `cli.py serve`), which
is how chopshop-studio calls this service for the blend-plot work.
"""

# blend-plot: one service, two halves - `plot` draws documents, `blender` renders 3D.

from .svg import svg_document, rect, circle, ellipse, polygon, polyline, line, path, text
from .spec import (SpecError, validate_generate, validate_digest, validate_tree,
                   validate_log)
from .generate import generate
from .digest import digest
from .blender import (BlenderUnavailable, validate_blender, render_blender, blender)
from .metrics import METRICS_VERSION, NUMERIC_FIELDS, CATEGORICAL_FIELDS, flatten_run, recipe_hash
from .query import QueryError, validate_query, query
from .tree import tree
from .log import log

__all__ = [
    "svg_document", "rect", "circle", "ellipse", "polygon", "polyline", "line",
    "path", "text",
    "SpecError", "validate_generate", "validate_digest", "validate_tree",
    "validate_log",
    "generate", "digest", "tree", "log",
    "BlenderUnavailable", "validate_blender", "render_blender", "blender",
    "METRICS_VERSION", "NUMERIC_FIELDS", "CATEGORICAL_FIELDS",
    "flatten_run", "recipe_hash",
    "QueryError", "validate_query", "query",
]
