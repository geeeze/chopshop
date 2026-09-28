"""Validation for the chopshop-plot JSON contract (docs/contract.md).

A backend must reject an invalid spec with a clear error, never emit a wrong
SVG. ``validate_generate`` and ``validate_digest`` raise ``SpecError`` with a
message that names the offending field; the CLI maps that to exit code 3.
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


def _is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _is_points(value):
    return (
        isinstance(value, list)
        and all(
            isinstance(p, (list, tuple)) and len(p) == 2 and _is_number(p[0]) and _is_number(p[1])
            for p in value
        )
    )


def _check_element(elem, where):
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
        if field in elem and not _is_number(elem[field]):
            raise SpecError(f"{where}: '{field}' must be a number")
    if etype in ("polygon", "polyline"):
        if not _is_points(elem["points"]):
            raise SpecError(f"{where}: 'points' must be a list of [x, y] pairs")
    if "stroke_width" in elem and not _is_number(elem["stroke_width"]):
        raise SpecError(f"{where}: 'stroke_width' must be a number")
    return elem


def _check_canvas(spec, where):
    canvas = spec.get("canvas", {})
    if not isinstance(canvas, dict):
        raise SpecError(f"{where}: 'canvas' must be an object")
    _require(canvas, "width", f"{where}.canvas")
    _require(canvas, "height", f"{where}.canvas")
    for key in ("width", "height"):
        if not _is_number(canvas[key]) or canvas[key] <= 0:
            raise SpecError(f"{where}: canvas '{key}' must be a positive number")


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
        _check_element(elem, f"{where}.elements[{i}]")

    tiling = spec.get("tiling")
    if tiling is not None:
        if not isinstance(tiling, dict):
            raise SpecError(f"{where}: 'tiling' must be an object")
        for key in ("grid", "cell", "origin", "element"):
            _require(tiling, key, f"{where}.tiling")
        grid, cell = tiling["grid"], tiling["cell"]
        if (
            not isinstance(grid, (list, tuple))
            or len(grid) != 2
            or not all(isinstance(n, int) and n >= 0 for n in grid)
        ):
            raise SpecError(f"{where}.tiling: 'grid' must be a [cols, rows] pair of integers")
        if not _is_points([cell]) or not _is_points([tiling["origin"]]):
            raise SpecError(f"{where}.tiling: 'cell' and 'origin' must be [x, y] pairs")
        _check_element(tiling["element"], f"{where}.tiling.element")
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

    size = spec.get("size", {})
    if not isinstance(size, dict):
        raise SpecError(f"{where}: 'size' must be an object")
    for key in ("width", "height"):
        if key in size and (not _is_number(size[key]) or size[key] <= 0):
            raise SpecError(f"{where}: size '{key}' must be a positive number")

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
                    _is_number(v) for v in s["values"]
                ):
                    raise SpecError(f"{where}.series[{i}]: 'values' must be a list of numbers")
        elif "values" in data and (
            not isinstance(data["values"], list)
            or not all(_is_number(v) for v in data["values"])
        ):
            raise SpecError(f"{where}: 'values' must be a list of numbers")
        elif "values" not in data and series is None:
            raise SpecError(f"{where}: expected 'series' or 'values'")
    else:  # scatter
        points = data.get("points")
        if points is not None:
            if not isinstance(points, list) or not all(
                isinstance(p, dict) and _is_number(p.get("x")) and _is_number(p.get("y"))
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
                    isinstance(p, dict) and _is_number(p.get("x")) and _is_number(p.get("y"))
                    for p in s["points"]
                ):
                    raise SpecError(f"{where}.series[{i}].points: must be a list of {{x, y}}")
        else:
            raise SpecError(f"{where}: expected 'points' or 'series'")
    return spec
