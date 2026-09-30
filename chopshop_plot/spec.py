"""Validation for the chopshop-bp JSON contract (docs/contract.md).

A backend must reject an invalid spec with a clear error, never emit a wrong
SVG. ``validate_generate``, ``validate_digest``, ``validate_tree`` and
``validate_log`` raise ``SpecError`` with a message that names the offending
field; the CLI maps that to exit code 3.

``is_number``, ``check_element`` and ``check_tiling`` are public because the
``blender`` operation validates the SAME element vocabulary and the same tiling
block as ``generate`` (docs/contract.md): one implementation, so a spec that one
operation accepts cannot be silently a different shape on the other.
"""


class SpecError(ValueError):
    """The spec does not satisfy the contract."""


_ELEMENT_FIELDS = {
    "rect": {"x", "y", "width", "height", "rx", "fill", "stroke", "stroke_width"},
    "circle": {"cx", "cy", "r", "fill", "stroke", "stroke_width"},
    "ellipse": {"cx", "cy", "rx", "ry", "fill", "stroke", "stroke_width"},
    "polygon": {"points", "fill", "stroke", "stroke_width"},
    "polyline": {"points", "stroke", "stroke_width"},
    "line": {"x1", "y1", "x2", "y2", "stroke", "stroke_width"},
    "path": {"d", "fill", "stroke", "stroke_width"},
}

# Positional/defining fields each element type must carry. Coords are SVG user
# units; for a tiled element they are offsets within its cell.
_REQUIRED_FIELDS = {
    "rect": ["x", "y", "width", "height"],
    "circle": ["cx", "cy", "r"],
    "ellipse": ["cx", "cy", "rx", "ry"],
    "polygon": ["points"],
    "polyline": ["points"],
    "line": ["x1", "y1", "x2", "y2"],
    "path": ["d"],
}

# Of the required fields, which must be numbers (path 'd' is a string).
_NUMERIC_FIELDS = {
    "rect": {"x", "y", "width", "height", "rx"},
    "circle": {"cx", "cy", "r"},
    "ellipse": {"cx", "cy", "rx", "ry"},
    "polygon": set(),
    "polyline": set(),
    "line": {"x1", "y1", "x2", "y2"},
    "path": set(),
}


def _require(mapping, key, where):
    if key not in mapping or mapping[key] is None:
        raise SpecError(f"{where}: missing required field '{key}'")


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _is_points(value):
    return (
        isinstance(value, list)
        and all(
            isinstance(p, (list, tuple)) and len(p) == 2 and is_number(p[0]) and is_number(p[1])
            for p in value
        )
    )


def check_element(elem, where):
    """Check one contract element against the shared vocabulary.

    Public because ``blender`` (chopshop_plot/blender.py) accepts the same
    elements as ``generate``: a vocabulary is only shared if there is one
    implementation of it, and this one names the offending field.
    """
    if not isinstance(elem, dict):
        raise SpecError(f"{where}: element must be an object")
    etype = elem.get("type")
    if etype not in _ELEMENT_FIELDS:
        raise SpecError(f"{where}: unknown element type {etype!r}")
    allowed = _ELEMENT_FIELDS[etype]
    unknown = set(elem) - allowed - {"type"}
    if unknown:
        raise SpecError(f"{where}: unknown field(s) {sorted(unknown)} on {etype}")
    for field in _REQUIRED_FIELDS[etype]:
        _require(elem, field, where)
    for field in _NUMERIC_FIELDS[etype]:
        if field in elem and not is_number(elem[field]):
            raise SpecError(f"{where}: '{field}' must be a number")
    if etype in ("polygon", "polyline"):
        if not _is_points(elem["points"]):
            raise SpecError(f"{where}: 'points' must be a list of [x, y] pairs")
    if "stroke_width" in elem and not is_number(elem["stroke_width"]):
        raise SpecError(f"{where}: 'stroke_width' must be a number")
    return elem


def _check_canvas(spec, where):
    canvas = spec.get("canvas", {})
    if not isinstance(canvas, dict):
        raise SpecError(f"{where}: 'canvas' must be an object")
    _require(canvas, "width", f"{where}.canvas")
    _require(canvas, "height", f"{where}.canvas")
    for key in ("width", "height"):
        if not is_number(canvas[key]) or canvas[key] <= 0:
            raise SpecError(f"{where}: canvas '{key}' must be a positive number")


def _check_size(spec, where):
    """The optional ``size`` block: positive width/height when present."""
    size = spec.get("size", {})
    if not isinstance(size, dict):
        raise SpecError(f"{where}: 'size' must be an object")
    for key in ("width", "height"):
        if key in size and (not is_number(size[key]) or size[key] <= 0):
            raise SpecError(f"{where}: size '{key}' must be a positive number")


def unwrap_payload(payload, op):
    """Accept either the bare spec or an ``{"op": op, "spec": {...}}`` envelope.

    One envelope rule, shared by the CLI and the service so the two entry points
    cannot read the same document differently. An explicit ``op`` must MATCH the
    operation being asked for — a generate document sent to digest is a caller
    error, never a silent best-effort — while a document that carries no
    envelope is taken as the spec itself.
    """
    if isinstance(payload, dict) and payload.get("op") and payload["op"] != op:
        raise SpecError(f"{op}: spec has op={payload['op']!r}")
    if isinstance(payload, dict):
        return payload.get("spec", payload)
    return payload


def check_tiling(tiling, where):
    """Check an optional ``tiling`` block: grid, cell, origin, element.

    Shared with the ``blender`` operation so a tiling block means the same thing
    wherever it appears: ``grid`` is a [cols, rows] pair of integers, ``cell``
    and ``origin`` are [x, y] pairs, and the element's own coordinates are
    offsets within its cell.
    """
    if not isinstance(tiling, dict):
        raise SpecError(f"{where}: 'tiling' must be an object")
    for key in ("grid", "cell", "origin", "element"):
        _require(tiling, key, where)
    grid, cell = tiling["grid"], tiling["cell"]
    if (
        not isinstance(grid, (list, tuple))
        or len(grid) != 2
        or not all(isinstance(n, int) and n >= 0 for n in grid)
    ):
        raise SpecError(f"{where}: 'grid' must be a [cols, rows] pair of integers")
    if not _is_points([cell]) or not _is_points([tiling["origin"]]):
        raise SpecError(f"{where}: 'cell' and 'origin' must be [x, y] pairs")
    check_element(tiling["element"], f"{where}.element")
    return tiling


def validate_generate(spec):
    """Validate a generate spec, returning the canonical spec dict (or raising)."""
    if not isinstance(spec, dict):
        raise SpecError("spec must be an object")
    where = "generate spec"
    _check_canvas(spec, where)
    elements = spec.get("elements", [])
    if not isinstance(elements, list):
        raise SpecError(f"{where}: 'elements' must be a list")
    for i, elem in enumerate(elements):
        check_element(elem, f"{where}.elements[{i}]")

    tiling = spec.get("tiling")
    if tiling is not None:
        check_tiling(tiling, f"{where}.tiling")

    return spec




def validate_digest(spec):
    """Validate a digest spec, returning the canonical spec dict (or raising)."""
    if not isinstance(spec, dict):
        raise SpecError("spec must be an object")
    where = "digest spec"
    chart = spec.get("chart")
    if chart not in ("bar", "line", "scatter"):
        raise SpecError(f"{where}: 'chart' must be one of bar, line, scatter")
    _require(spec, "data", where)
    data = spec["data"]
    if not isinstance(data, dict):
        raise SpecError(f"{where}: 'data' must be an object")

    _check_size(spec, where)

    if chart in ("bar", "line"):
        labels = data.get("labels")
        if labels is not None and (
            not isinstance(labels, list) or not all(isinstance(s, str) for s in labels)
        ):
            raise SpecError(f"{where}: 'labels' must be a list of strings")
        series = data.get("series")
        if series is not None:
            if not isinstance(series, list):
                raise SpecError(f"{where}: 'series' must be a list")
            for i, s in enumerate(series):
                if not isinstance(s, dict) or "values" not in s:
                    raise SpecError(f"{where}.series[{i}]: must be an object with 'values'")
                if not isinstance(s["values"], list) or not all(
                    is_number(v) for v in s["values"]
                ):
                    raise SpecError(f"{where}.series[{i}]: 'values' must be a list of numbers")
        elif "values" in data and (
            not isinstance(data["values"], list)
            or not all(is_number(v) for v in data["values"])
        ):
            raise SpecError(f"{where}: 'values' must be a list of numbers")
        elif "values" not in data and series is None:
            raise SpecError(f"{where}: expected 'series' or 'values'")
    else:  # scatter
        points = data.get("points")
        if points is not None:
            if not isinstance(points, list) or not all(
                isinstance(p, dict) and is_number(p.get("x")) and is_number(p.get("y"))
                for p in points
            ):
                raise SpecError(f"{where}: 'points' must be a list of {{x, y}} objects")
        elif "series" in data:
            series = data["series"]
            if not isinstance(series, list):
                raise SpecError(f"{where}: 'series' must be a list")
            for i, s in enumerate(series):
                if not isinstance(s, dict) or "points" not in s:
                    raise SpecError(f"{where}.series[{i}]: must be an object with 'points'")
                if not isinstance(s["points"], list) or not all(
                    isinstance(p, dict) and is_number(p.get("x")) and is_number(p.get("y"))
                    for p in s["points"]
                ):
                    raise SpecError(f"{where}.series[{i}].points: must be a list of {{x, y}}")
        else:
            raise SpecError(f"{where}: expected 'points' or 'series'")
    return spec


# ---------------------------------------------------------------------------
# The diagram operations: tree (a hierarchy) and log (an event timeline).
# ---------------------------------------------------------------------------

_STRING_NODE_FIELDS = ("label", "kind", "status")
_STRING_EVENT_FIELDS = ("t", "kind", "label")


def _check_display_strings(mapping, fields, where):
    """Text fields are display-only, so they must be text — no coercion.

    A number where a string belongs is a caller error worth naming: silently
    printing ``1234`` in the place a label goes is how a diagram ends up lying
    about what it is showing.
    """
    for field in fields:
        value = mapping.get(field)
        if value is not None and not isinstance(value, str):
            raise SpecError(f"{where}: '{field}' must be a string")


def validate_tree(spec):
    """Validate a tree spec, returning the canonical spec dict (or raising).

    Nodes come first because an edge is only meaningful against the set of node
    ids: an edge to an id that is not there is a SpecError, never a line drawn
    out to nothing, and a duplicate node id is a SpecError, never one node
    silently replacing another.
    """
    if not isinstance(spec, dict):
        raise SpecError("spec must be an object")
    where = "tree spec"
    _check_size(spec, where)

    layout = spec.get("layout", "tb")
    if layout not in ("tb", "lr"):
        raise SpecError(f"{where}: 'layout' must be 'tb' or 'lr'")

    nodes = spec.get("nodes")
    if nodes is None:
        raise SpecError(f"{where}: missing required field 'nodes'")
    if not isinstance(nodes, list):
        raise SpecError(f"{where}: 'nodes' must be a list")
    ids = set()
    for i, node in enumerate(nodes):
        node_where = f"{where}.nodes[{i}]"
        if not isinstance(node, dict):
            raise SpecError(f"{node_where}: node must be an object")
        node_id = node.get("id")
        if not isinstance(node_id, str) or not node_id:
            raise SpecError(f"{node_where}: 'id' must be a non-empty string")
        if node_id in ids:
            raise SpecError(f"{node_where}: duplicate node id {node_id!r}")
        ids.add(node_id)
        _check_display_strings(node, _STRING_NODE_FIELDS, node_where)
        metrics = node.get("metrics")
        if metrics is not None:
            if not isinstance(metrics, dict):
                raise SpecError(f"{node_where}: 'metrics' must be an object")
            for key, value in metrics.items():
                # None is allowed and renders as absent (a missing measurement
                # is a state, not a zero); anything non-numeric is a caller
                # error, because a diagram cannot draw a string as a number.
                if value is not None and not is_number(value):
                    raise SpecError(f"{node_where}.metrics: '{key}' must be a number")

    edges = spec.get("edges", [])
    if not isinstance(edges, list):
        raise SpecError(f"{where}: 'edges' must be a list")
    for i, edge in enumerate(edges):
        edge_where = f"{where}.edges[{i}]"
        if not isinstance(edge, dict):
            raise SpecError(f"{edge_where}: edge must be an object")
        for field in ("from", "to"):
            _require(edge, field, edge_where)
            if not isinstance(edge[field], str) or not edge[field]:
                raise SpecError(f"{edge_where}: '{field}' must be a non-empty string")
            if edge[field] not in ids:
                raise SpecError(f"{edge_where}: '{field}' names unknown node "
                                f"{edge[field]!r}")
    return spec


def validate_log(spec):
    """Validate a log spec, returning the canonical spec dict (or raising).

    Order is the contract here, so validation only checks SHAPE: it never sorts
    the events and never reads ``t`` as a time. ``pos`` is an integer rank or
    nothing at all — ``None`` omits the ``#N`` rather than printing ``#None``.
    """
    if not isinstance(spec, dict):
        raise SpecError("spec must be an object")
    where = "log spec"
    _check_size(spec, where)

    events = spec.get("events")
    if events is None:
        raise SpecError(f"{where}: missing required field 'events'")
    if not isinstance(events, list):
        raise SpecError(f"{where}: 'events' must be a list")
    for i, event in enumerate(events):
        event_where = f"{where}.events[{i}]"
        if not isinstance(event, dict):
            raise SpecError(f"{event_where}: event must be an object")
        _check_display_strings(event, _STRING_EVENT_FIELDS, event_where)
        pos = event.get("pos")
        if pos is not None and (isinstance(pos, bool) or not isinstance(pos, int)):
            raise SpecError(f"{event_where}: 'pos' must be an integer")
    return spec
