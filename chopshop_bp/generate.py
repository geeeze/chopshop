"""Geometry spec -> SVG (the ``generate`` operation of the contract)"""

from . import svg
from .spec import SpecError, validate_generate


def _relief_opacity(elem, relief):
    """The flat reading of one element's height, as an SVG `fill-opacity`.

    The SVG-side equivalent of the relief rule, and the reason the issue's "the
    SVG-side equivalent if the rule is shared" has a narrow answer rather than
    none: the TONAL rule is shared, because a relief's whole visual point is
    that nearer things are lighter and further things darker under a raking
    light, and in a flat drawing that gradient is opacity. One normalised
    number (`luminance`, the same field, measured the same way by the caller)
    becomes a height in 3D and a tone in 2D, so a document traced once can be
    drawn both ways and the two pictures agree about which parts are near.

    The mapping is the SAME normalised position in the range as the 3D one —
    `z_min + value * (z_max - z_min)` is the height, and the fraction of the
    range that value sits at IS the opacity — computed here rather than by
    importing `blender.relief_height`, because `generate` must not depend on the
    3D half of this service and a flat drawing has no z to divide by.

    `layers` has NO flat reading and is refused. An ordinal stack's meaning is
    that the layers are at different heights; in a flat drawing the caller has
    already expressed that by the order they wrote the elements in, so applying
    the rule would be inventing an opacity ordering the spec did not ask for.
    """
    if relief.get("rule") != "luminance":
        raise SpecError(
            "spec.relief: the 'layers' rule has no flat reading, so `generate` "
            "refuses it. Layer order is expressed by the order the elements "
            "appear in; only the tonal ('luminance') rule means something in a "
            "2D drawing, where it becomes fill-opacity. Use the `blender` "
            "operation for a layered relief.")
    value = float(elem["luminance"])
    if relief.get("invert"):
        value = 1.0 - value
    # Clamped, not refused: opacity outside 0..1 has no SVG reading at all (it
    # is ignored by every renderer), and a measurement at the very edge of the
    # caller's normalisation is not an error worth failing a flat draw over.
    return min(1.0, max(0.0, value))


def _render_element(elem, ox=0, oy=0, relief=None):
    """Render one contract element to an SVG element string, offset by (ox, oy).

    ``relief`` is the document's tonal rule when there is one, and all it
    changes is `fill-opacity`: the relief decides how FAR BACK a shape sits and
    the element's own `fill` is still its colour. Those are different decisions
    that happen to be asked about together, so neither is derived from the
    other — a luminance of 0.4 on a red shape is a dark red at 40% opacity, not
    a red tinted towards the background.
    """
    etype = elem["type"]
    fill = elem.get("fill")
    stroke = elem.get("stroke")
    stroke_width = elem.get("stroke_width")
    dash = elem.get("stroke_dasharray")
    opacity = None if relief is None else _relief_opacity(elem, relief)
    if etype == "rect":
        return svg.rect(
            ox + elem["x"], oy + elem["y"], elem["width"], elem["height"],
            fill=fill, stroke=stroke, stroke_width=stroke_width, rx=elem.get("rx"),
            fill_opacity=opacity, stroke_dasharray=dash,
        )
    if etype == "circle":
        return svg.circle(
            ox + elem["cx"], oy + elem["cy"], elem["r"],
            fill=fill, stroke=stroke, stroke_width=stroke_width,
            fill_opacity=opacity, stroke_dasharray=dash,
        )
    if etype == "ellipse":
        return svg.ellipse(
            ox + elem["cx"], oy + elem["cy"], elem["rx"], elem["ry"],
            fill=fill, stroke=stroke, stroke_width=stroke_width,
            fill_opacity=opacity, stroke_dasharray=dash,
        )
    if etype == "polygon":
        pts = [[ox + x, oy + y] for x, y in elem["points"]]
        return svg.polygon(pts, fill=fill, stroke=stroke, stroke_width=stroke_width,
                           fill_opacity=opacity, stroke_dasharray=dash)
    if etype == "polyline":
        pts = [[ox + x, oy + y] for x, y in elem["points"]]
        # No `fill_opacity` here, and not by oversight: `validate_generate`
        # refuses a `luminance` on a `line` or `polyline` by name, so a document
        # that reaches this branch under a relief cannot exist and the opacity
        # is always None. Passing it anyway would need a parameter on a helper
        # whose only caller can never use it. No `stroke_dasharray` either: the
        # vocabulary scopes the dashed-boundary field to the five closed/open
        # stroked shapes (see _DASHARRAY_ELEMENTS), and polyline is not one.
        return svg.polyline(pts, stroke=stroke, stroke_width=stroke_width)
    if etype == "line":
        return svg.line(
            ox + elem["x1"], oy + elem["y1"], ox + elem["x2"], oy + elem["y2"],
            stroke=stroke, stroke_width=stroke_width, stroke_dasharray=dash,
        )
    if etype == "path":
        return svg.path(elem["d"], fill=fill, stroke=stroke, stroke_width=stroke_width,
                        fill_opacity=opacity)
    if etype == "text":
        # A label, rendered through the same svg.text() primitive tree/log/digest
        # use. fill defaults to the document's own text colour (None lets
        # svg.text apply its default, which the caller may have set on the doc);
        # font_size defaults 12 and anchor is unset (SVG start) unless given.
        return svg.text(
            ox + elem["x"], oy + elem["y"], elem["content"],
            fill=fill if fill is not None else "#000000",
            font_size=elem.get("font_size", 12),
            anchor=elem.get("anchor"),
            font_family=elem.get("font_family"),
        )
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
    # The tonal relief, if the document states one: a validated block or None,
    # read once here and handed down rather than re-read per element. The
    # validation already refused a `relief` whose elements lack a measurement, so
    # by the time this loop runs every element has the `luminance` the rule
    # reads.
    relief = spec.get("relief")

    tiling = spec.get("tiling")
    if tiling:
        body.extend(_render_tiling(tiling))

    for elem in spec.get("elements", []):
        body.append(_render_element(elem, relief=relief))

    return svg.svg_document(
        canvas["width"], canvas["height"], body, background=canvas.get("background")
    )
