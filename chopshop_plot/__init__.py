"""chopshop-plot — a geometry source and a run reporter for the chopshop pipeline.

Five operations, one language-agnostic JSON contract (docs/contract.md):

- ``generate``: a geometry spec -> SVG (shapes, tiling, patterns).
- ``digest``:    a metrics spec  -> chart SVG (bar / scatter / line).
- ``query``:     run records + a chart spec -> SVG (cross-run scatter, Pareto
                 frontier, two-way diff).
- ``tree``:      a hierarchy spec (nodes + edges) -> a layered tree SVG.
- ``log``:       an event spec -> a vertical event-timeline SVG.

The reference implementation is stdlib-only and writes SVG directly, because
SVG is the pipeline's native vector format. See README.md for the why. The
operations also ride over HTTP (``chopshop_plot.server``, `cli.py serve`), which
is how the studio drives this repo as a runner.
"""

from .svg import svg_document, rect, circle, ellipse, polygon, polyline, line, path, text
from .spec import (SpecError, validate_generate, validate_digest, validate_tree,
                   validate_log)
from .generate import generate
from .digest import digest
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
    "METRICS_VERSION", "NUMERIC_FIELDS", "CATEGORICAL_FIELDS",
    "flatten_run", "recipe_hash",
    "QueryError", "validate_query", "query",
]
