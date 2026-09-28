"""A minimal, stdlib-only SVG emitter.

SVG is text, so the sidecar writes it directly rather than round-tripping
through a plotting library. These helpers build a single <svg> document and the
shape/text elements the contract needs. Nothing here depends on anything beyond
the standard library.
"""

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


def _fill_stroke(attrs, fill, stroke, stroke_width):
    """Add the shared fill/stroke/stroke_width attributes when present."""
    if fill is not None:
        attrs["fill"] = fill
    if stroke is not None:
        attrs["stroke"] = stroke
    if stroke_width is not None:
        attrs["stroke-width"] = stroke_width


def svg_document(width, height, body, background=None):
    """Wrap element bodies in an <svg> root with width/height/viewBox."""
    open_tag = (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{_fmt(width)}" '
        f'height="{_fmt(height)}" viewBox="0 0 {_fmt(width)} {_fmt(height)}">'
    )
    bg = ""
    if background is not None:
        bg = rect(0, 0, width, height, fill=background)
    return f"{open_tag}{bg}{''.join(body)}</svg>"


def rect(x, y, width, height, fill=None, stroke=None, stroke_width=None, rx=None):
    attrs = {"x": x, "y": y, "width": width, "height": height}
    if rx is not None:
        attrs["rx"] = rx
    _fill_stroke(attrs, fill, stroke, stroke_width)
    return element("rect", attrs, self_closing=True)


def circle(cx, cy, r, fill=None, stroke=None, stroke_width=None):
    attrs = {"cx": cx, "cy": cy, "r": r}
    _fill_stroke(attrs, fill, stroke, stroke_width)
    return element("circle", attrs, self_closing=True)


def ellipse(cx, cy, rx, ry, fill=None, stroke=None, stroke_width=None):
    attrs = {"cx": cx, "cy": cy, "rx": rx, "ry": ry}
    _fill_stroke(attrs, fill, stroke, stroke_width)
    return element("ellipse", attrs, self_closing=True)


def _points(points):
    return " ".join(f"{_fmt(x)},{_fmt(y)}" for x, y in points)


def polygon(points, fill=None, stroke=None, stroke_width=None):
    attrs = {"points": _points(points)}
    _fill_stroke(attrs, fill, stroke, stroke_width)
    return element("polygon", attrs, self_closing=True)


def polyline(points, stroke=None, stroke_width=None, fill="none"):
    attrs = {"points": _points(points), "fill": fill}
    _fill_stroke(attrs, None, stroke, stroke_width)
    return element("polyline", attrs, self_closing=True)


def line(x1, y1, x2, y2, stroke=None, stroke_width=None):
    attrs = {"x1": x1, "y1": y1, "x2": x2, "y2": y2}
    _fill_stroke(attrs, None, stroke, stroke_width)
    return element("line", attrs, self_closing=True)


def path(d, fill=None, stroke=None, stroke_width=None):
    attrs = {"d": d}
    _fill_stroke(attrs, fill, stroke, stroke_width)
    return element("path", attrs, self_closing=True)


def text(x, y, content, fill="#000000", font_size=12, anchor=None, transform=None):
    attrs = {"x": x, "y": y, "fill": fill, "font-size": font_size}
    if anchor is not None:
        attrs["text-anchor"] = anchor
    if transform is not None:
        attrs["transform"] = transform
    return element("text", attrs, text_content=content)
