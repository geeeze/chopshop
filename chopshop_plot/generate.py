"""Geometry spec -> SVG (the ``generate`` operation of the contract)."""

from . import svg
from .spec import validate_generate


def _render_element(elem, ox=0, oy=0):
    """Render one contract element to an SVG element string, offset by (ox, oy)."""
    etype = elem["type"]
    fill = elem.get("fill")
    stroke = elem.get("stroke")
    stroke_width = elem.get("stroke_width")
    if etype == "rect":
        return svg.rect(
            ox + elem["x"], oy + elem["y"], elem["width"], elem["height"],
            fill=fill, stroke=stroke, stroke_width=stroke_width, rx=elem.get("rx"),
        )
    if etype == "circle":
        return svg.circle(
            ox + elem["cx"], oy + elem["cy"], elem["r"],
            fill=fill, stroke=stroke, stroke_width=stroke_width,
        )
    if etype == "ellipse":
        return svg.ellipse(
            ox + elem["cx"], oy + elem["cy"], elem["rx"], elem["ry"],
            fill=fill, stroke=stroke, stroke_width=stroke_width,
        )
    if etype == "polygon":
        pts = [[ox + x, oy + y] for x, y in elem["points"]]
        return svg.polygon(pts, fill=fill, stroke=stroke, stroke_width=stroke_width)
    if etype == "polyline":
        pts = [[ox + x, oy + y] for x, y in elem["points"]]
        return svg.polyline(pts, stroke=stroke, stroke_width=stroke_width)
    if etype == "line":
        return svg.line(
            ox + elem["x1"], oy + elem["y1"], ox + elem["x2"], oy + elem["y2"],
            stroke=stroke, stroke_width=stroke_width,
        )
    if etype == "path":
        return svg.path(elem["d"], fill=fill, stroke=stroke, stroke_width=stroke_width)
    raise ValueError(f"unknown element type {etype!r}")  # unreachable after validation


def _render_tiling(tiling):
    """Repeat a tiling element across a grid, returning the SVG element strings."""
    grid_x, grid_y = tiling["grid"]
    cell_w, cell_h = tiling["cell"]
    origin_x, origin_y = tiling["origin"]
    element = tiling["element"]
    out = []
    for row in range(grid_y):
        for col in range(grid_x):
            ox = origin_x + col * cell_w
            oy = origin_y + row * cell_h
            out.append(_render_element(element, ox, oy))
    return out


def generate(spec):
    """Render a generate spec to an SVG document string.

    ``spec`` may be a dict or a JSON string. Raises ``SpecError`` on invalid
    input. The returned SVG carries the canvas size and viewBox so the pipeline
    can consume it as a normal vector candidate.
    """
    if isinstance(spec, str):
        import json

        spec = json.loads(spec)
    validate_generate(spec)

    canvas = spec["canvas"]
    body = []

    tiling = spec.get("tiling")
    if tiling:
        body.extend(_render_tiling(tiling))

    for elem in spec.get("elements", []):
        body.append(_render_element(elem))

    return svg.svg_document(
        canvas["width"], canvas["height"], body, background=canvas.get("background")
    )
