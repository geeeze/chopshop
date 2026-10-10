"""A minimal, stdlib-only SVG emitter.

SVG is text, so the sidecar writes it directly rather than round-tripping
through a plotting library. These helpers build a single <svg> document and the
shape/text elements the contract needs. Nothing here depends on anything beyond
the standard library.
"""

import hashlib

_XML_ESCAPES = {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"}


def escape(value):
    """Escape a value for use as an XML attribute or text node."""
    return "".join(_XML_ESCAPES.get(ch, ch) for ch in str(value))


def _fmt(value):
    """Format a number without float noise (0.30000000000000004 -> 0.3)."""
    if isinstance(value, float):
        if value.is_integer():
            return str(int(value))
        return f"{value:.6g}"
    return str(value)


def _attrs(attrs):
    parts = []
    for key, value in attrs.items():
        if value is None:
            continue
        parts.append(f'{key}="{escape(_fmt(value))}"')
    return (" " + " ".join(parts)) if parts else ""


def element(tag, attrs=None, text_content=None, self_closing=False):
    """Build an XML element string."""
    a = _attrs(attrs or {})
    if self_closing:
        return f"<{tag}{a}/>"
    body = escape(text_content) if text_content is not None else ""
    return f"<{tag}{a}>{body}</{tag}>"


def _fill_stroke(attrs, fill, stroke, stroke_width, fill_opacity=None, stroke_dasharray=None):
    """Add the shared fill/stroke/stroke_width/fill-opacity/stroke-dasharray attributes.

    ``fill_opacity`` is here rather than at each shape so the relief's tone is
    ONE rule applied in one place: a `fill-opacity` threaded through seven
    shape helpers is a rule that can be forgotten on the eighth. `None` means
    "not asked for" and emits nothing, so a document with no relief produces
    byte-identical SVG to the one before this parameter existed.
    """
    if fill is not None:
        attrs["fill"] = fill
    if stroke is not None:
        attrs["stroke"] = stroke
    if stroke_width is not None:
        attrs["stroke-width"] = stroke_width
    if fill_opacity is not None:
        attrs["fill-opacity"] = fill_opacity
    if stroke_dasharray is not None:
        if isinstance(stroke_dasharray, list):
            attrs["stroke-dasharray"] = ",".join(_fmt(v) for v in stroke_dasharray)
        else:
            attrs["stroke-dasharray"] = stroke_dasharray


# Per-(stroke, stroke_width) arrowhead marker ids. One <marker> definition is
# emitted per distinct (stroke, stroke_width) pair carried by a marker-carrying
# connector, so each connector's arrowhead is drawn in its OWN stroke colour
# and sized from its OWN stroke_width (docs/contract.md: "The arrowhead is
# drawn in the element's own stroke colour, sized from stroke_width").
# orient="auto" rotates the triangle to match the edge direction, so a single
# definition serves both 'start' and 'end' markers and any edge orientation.


def marker_id(stroke, stroke_width):
    """The marker id for one (stroke, stroke_width) pair.

    ``arrowhead-<hex>-<w>``: a short hash of the stroke colour (so ids stay
    unique per colour and deterministic across runs — no colour ever reads as
    another's) plus the stroke width. A colourless connector hashes None, so
    two colourless lines of the same width still share one definition.
    """
    fill = stroke if stroke is not None else "#000000"
    # Normalise the width to the same default marker_def uses, so the id a
    # connector references matches the id marker_def emits for that pair.
    width = stroke_width if stroke_width is not None else 2
    digest = hashlib.sha256(f"{fill}|{width}".encode("utf-8")).hexdigest()[:8]
    return f"arrowhead-{digest}-{width}"


def _marker_attrs(marker, mid):
    """Build marker-start / marker-end attrs for a line or polyline.

    ``mid`` is the id of the <marker> definition matching this element's own
    (stroke, stroke_width) pair (see :func:`marker_id`). Returns a dict of
    SVG attributes (possibly empty) referencing that definition.
    """
    attrs = {}
    if marker in ("start", "both"):
        attrs["marker-start"] = f"url(#{mid})"
    if marker in ("end", "both"):
        attrs["marker-end"] = f"url(#{mid})"
    return attrs


def marker_def(stroke=None, stroke_width=None):
    """Build the <marker> definition for one (stroke, stroke_width) pair.

    The marker is a triangle pointing right (the +x direction), with
    orient="auto" so it rotates to match the edge. The path is drawn in a
    coordinate space of markerWidth × markerHeight, with the tip at
    (ref, ref/2). The marker's fill matches the line's stroke colour so a
    connector in a semantic palette keeps that colour on its arrowhead.
    Size follows the line's stroke_width with a sane default.
    """
    size = stroke_width if stroke_width is not None else 2
    # Scale factor: arrowhead length ~ 3x stroke_width, clamped so a very
    # thick line doesn't get an absurd head.
    ref = max(1.0, min(size * 3.0, 12.0))
    fill = stroke if stroke is not None else "#000000"
    w = ref
    h = ref / 2
    return (
        f'<marker id="{marker_id(stroke, stroke_width)}" '
        f'viewBox="0 0 {_fmt(w)} {_fmt(h)}" '
        f'markerWidth="{_fmt(w)}" markerHeight="{_fmt(h)}" '
        f'refX="{_fmt(w)}" refY="{_fmt(h / 2)}" orient="auto" '
        f'markerUnits="userSpaceOnUse">'
        f'<path d="M 0 0 L {_fmt(w)} {_fmt(h / 2)} L 0 {_fmt(h)} Z" '
        f'fill="{escape(fill)}"/>'
        f'</marker>'
    )


def svg_document(width, height, body, background=None, defs=None):
    """Wrap element bodies in an <svg> root with width/height/viewBox.

    ``defs`` is an optional list of <defs> content strings (e.g. the shared
    marker definition) to emit inside a single <defs> block.
    """
    open_tag = (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{_fmt(width)}" '
        f'height="{_fmt(height)}" viewBox="0 0 {_fmt(width)} {_fmt(height)}">'
    )
    bg = ""
    if background is not None:
        bg = rect(0, 0, width, height, fill=background)
    defs_str = ""
    if defs:
        defs_str = f"<defs>{''.join(defs)}</defs>"
    return f"{open_tag}{bg}{defs_str}{''.join(body)}</svg>"


def rect(x, y, width, height, fill=None, stroke=None, stroke_width=None, rx=None, fill_opacity=None,
          stroke_dasharray=None):
    attrs = {"x": x, "y": y, "width": width, "height": height}
    if rx is not None:
        attrs["rx"] = rx
    _fill_stroke(attrs, fill, stroke, stroke_width, fill_opacity, stroke_dasharray)
    return element("rect", attrs, self_closing=True)


def circle(cx, cy, r, fill=None, stroke=None, stroke_width=None, fill_opacity=None,
            stroke_dasharray=None):
    attrs = {"cx": cx, "cy": cy, "r": r}
    _fill_stroke(attrs, fill, stroke, stroke_width, fill_opacity, stroke_dasharray)
    return element("circle", attrs, self_closing=True)


def ellipse(cx, cy, rx, ry, fill=None, stroke=None, stroke_width=None, fill_opacity=None,
             stroke_dasharray=None):
    attrs = {"cx": cx, "cy": cy, "rx": rx, "ry": ry}
    _fill_stroke(attrs, fill, stroke, stroke_width, fill_opacity, stroke_dasharray)
    return element("ellipse", attrs, self_closing=True)


def _points(points):
    return " ".join(f"{_fmt(x)},{_fmt(y)}" for x, y in points)


def polygon(points, fill=None, stroke=None, stroke_width=None, fill_opacity=None,
            stroke_dasharray=None):
    attrs = {"points": _points(points)}
    _fill_stroke(attrs, fill, stroke, stroke_width, fill_opacity, stroke_dasharray)
    return element("polygon", attrs, self_closing=True)


def polyline(points, stroke=None, stroke_width=None, fill="none", marker=None,
             stroke_dasharray=None):
    attrs = {"points": _points(points), "fill": fill}
    _fill_stroke(attrs, None, stroke, stroke_width, None, stroke_dasharray)
    if marker is not None and marker != "none":
        attrs.update(_marker_attrs(marker, marker_id(stroke, stroke_width)))
    return element("polyline", attrs, self_closing=True)


def line(x1, y1, x2, y2, stroke=None, stroke_width=None, stroke_dasharray=None,
         marker=None):
    attrs = {"x1": x1, "y1": y1, "x2": x2, "y2": y2}
    _fill_stroke(attrs, None, stroke, stroke_width, None, stroke_dasharray)
    if marker is not None and marker != "none":
        attrs.update(_marker_attrs(marker, marker_id(stroke, stroke_width)))
    return element("line", attrs, self_closing=True)


def path(d, fill=None, stroke=None, stroke_width=None, fill_opacity=None):
    attrs = {"d": d}
    _fill_stroke(attrs, fill, stroke, stroke_width, fill_opacity)
    return element("path", attrs, self_closing=True)


def text(x, y, content, fill="#000000", font_size=12, anchor=None, transform=None,
         font_family=None, opacity=None):
    attrs = {"x": x, "y": y, "fill": fill, "font-size": font_size}
    if font_family is not None:
        attrs["font-family"] = font_family
    if anchor is not None:
        attrs["text-anchor"] = anchor
    if transform is not None:
        attrs["transform"] = transform
    if opacity is not None:
        attrs["fill-opacity"] = opacity
    return element("text", attrs, text_content=content)
