"""Metrics spec -> chart SVG (the ``digest`` operation of the contract).

Hand-rolls a minimal bar / scatter / line chart in SVG. Auto-scales the value
axis to the data, renders an axis line and a few ticks, and draws a title when
one is given. No plotting library — the contract only promises a readable chart.
"""

import math

from . import svg
from .spec import validate_digest

_SERIES_COLORS = ["#4c78a8", "#f58518", "#54a24b", "#e45756", "#72b7b2", "#b279a2", "#eeca3b"]

_MARGIN_LEFT = 52
_MARGIN_RIGHT = 14
_MARGIN_TOP = 40
_MARGIN_BOTTOM = 40

_AXIS_COLOR = "#333333"
_GRID_COLOR = "#e0e0e0"
_TEXT_COLOR = "#444444"


def _nice_step(span, target=5):
    raw = span / max(1, target)
    mag = 10 ** math.floor(math.log10(raw))
    for m in (1, 2, 5, 10):
        if raw <= m * mag:
            return m * mag
    return 10 * mag


def _ticks(vmin, vmax, target=5):
    if vmin == vmax:
        vmax = vmin + 1
    step = _nice_step(vmax - vmin, target)
    lo = math.floor(vmin / step) * step
    out = []
    t = lo
    while t <= vmax + step / 2:
        out.append(round(t, 10))
        t += step
    return out


def _fmt(value):
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, float):
        return f"{value:.6g}"
    return str(value)


def _scale_y(vmin, vmax, plot_top, plot_h, value):
    if vmax == vmin:
        return plot_top
    return plot_top + (vmax - value) / (vmax - vmin) * plot_h


def _plot_area(width, height):
    left = _MARGIN_LEFT
    right = width - _MARGIN_RIGHT
    top = _MARGIN_TOP
    bottom = height - _MARGIN_BOTTOM
    return left, right, top, bottom, right - left, bottom - top


def _y_axis(vmin, vmax, left, top, plot_w, plot_h):
    """Return axis line, gridlines and tick labels for the value axis."""
    parts = []
    ticks = _ticks(vmin, vmax)
    for tick in ticks:
        y = _scale_y(vmin, vmax, top, plot_h, tick)
        parts.append(svg.line(left, y, left + plot_w, y, stroke=_GRID_COLOR, stroke_width=1))
        parts.append(svg.text(left - 6, y + 4, _fmt(tick), fill=_TEXT_COLOR,
                              font_size=11, anchor="end"))
    parts.append(svg.line(left, top, left, top + plot_h, stroke=_AXIS_COLOR, stroke_width=1))
    return parts


def _x_axis(left, top, plot_w, plot_h):
    return [svg.line(left, top + plot_h, left + plot_w, top + plot_h,
                     stroke=_AXIS_COLOR, stroke_width=1)]


def _title(title, width):
    if not title:
        return []
    return [svg.text(width / 2, 22, title, fill="#111111", font_size=15, anchor="middle")]


def _legend(series, width):
    if len(series) <= 1:
        return []
    parts = []
    x = width - _MARGIN_RIGHT
    # Place entries right-to-left in REVERSE series order so the visual order
    # left-to-right matches the series (and bar) order.
    for i in range(len(series) - 1, -1, -1):
        s = series[i]
        name = s.get("name", f"series-{i}")
        swatch = svg.rect(x - 8, 12, 8, 8, fill=_SERIES_COLORS[i % len(_SERIES_COLORS)])
        label = svg.text(x - 12, 20, name, fill=_TEXT_COLOR, font_size=10, anchor="end")
        parts.append(swatch)
        parts.append(label)
        x -= 16 + 6 * len(name)
    return parts


def _categorical_series(data):
    """Normalise bar/line data to (labels, list-of-series) shape."""
    labels = data.get("labels", [])
    if "series" in data:
        series = data["series"]
    else:
        series = [{"name": None, "values": data["values"]}]
    return labels, series


def _render_bar(spec, width, height):
    data = spec["data"]
    labels, series = _categorical_series(data)
    n = max(len(labels), *[len(s.get("values", [])) for s in series], 1)
    if not labels:
        labels = [str(i + 1) for i in range(n)]

    all_values = [v for s in series for v in s.get("values", [])]
    vmax = max(all_values) if all_values else 1
    vmin = min(0, min(all_values)) if all_values else 0

    left, right, top, bottom, plot_w, plot_h = _plot_area(width, height)
    parts = _y_axis(vmin, vmax, left, top, plot_w, plot_h)
    parts += _x_axis(left, top, plot_w, plot_h)
    parts += _title(spec.get("title"), width)
    parts += _legend(series, width)

    group_w = plot_w / n
    bar_w = group_w * 0.7 / max(1, len(series))
    for gi in range(n):
        x = left + gi * group_w
        for si, s in enumerate(series):
            values = s.get("values", [])
            value = values[gi] if gi < len(values) else 0
            y0 = _scale_y(vmin, vmax, top, plot_h, vmin)
            y1 = _scale_y(vmin, vmax, top, plot_h, value)
            bx = x + group_w * 0.15 + si * bar_w
            color = _SERIES_COLORS[si % len(_SERIES_COLORS)]
            parts.append(svg.rect(bx, min(y0, y1), bar_w, abs(y1 - y0), fill=color))
        parts.append(svg.text(x + group_w / 2, bottom + 16, labels[gi],
                              fill=_TEXT_COLOR, font_size=11, anchor="middle"))
    return parts


def _render_line(spec, width, height):
    data = spec["data"]
    labels, series = _categorical_series(data)
    n = max(len(labels), *[len(s.get("values", [])) for s in series], 1)
    if not labels:
        labels = [str(i + 1) for i in range(n)]

    all_values = [v for s in series for v in s.get("values", [])]
    vmax = max(all_values) if all_values else 1
    vmin = min(all_values) if all_values else 0
    if vmin == vmax:
        vmax = vmin + 1

    left, right, top, bottom, plot_w, plot_h = _plot_area(width, height)
    parts = _y_axis(vmin, vmax, left, top, plot_w, plot_h)
    parts += _x_axis(left, top, plot_w, plot_h)
    parts += _title(spec.get("title"), width)
    parts += _legend(series, width)

    xs = [left + (i + 0.5) * plot_w / n for i in range(n)]
    for si, s in enumerate(series):
        values = s.get("values", [])
        pts = [
            [xs[i], _scale_y(vmin, vmax, top, plot_h, values[i])]
            for i in range(min(n, len(values)))
        ]
        if pts:
            parts.append(svg.polyline(pts, stroke=_SERIES_COLORS[si % len(_SERIES_COLORS)],
                                      stroke_width=2))
    for i, label in enumerate(labels):
        parts.append(svg.text(xs[i], bottom + 16, label, fill=_TEXT_COLOR,
                              font_size=11, anchor="middle"))
    return parts


def _render_scatter(spec, width, height):
    data = spec["data"]
    if "series" in data:
        series = data["series"]
        points = [p for s in series for p in s["points"]]
    else:
        series = [{"name": None, "points": data["points"]}]
        points = data["points"]

    xs = [p["x"] for p in points]
    ys = [p["y"] for p in points]
    xmin, xmax = (min(xs), max(xs)) if xs else (0, 1)
    ymin, ymax = (min(ys), max(ys)) if ys else (0, 1)
    if xmin == xmax:
        xmax = xmin + 1
    if ymin == ymax:
        ymax = ymin + 1

    left, right, top, bottom, plot_w, plot_h = _plot_area(width, height)
    parts = _y_axis(ymin, ymax, left, top, plot_w, plot_h)
    parts += _x_axis(left, top, plot_w, plot_h)
    parts += _title(spec.get("title"), width)
    parts += _legend(series, width)

    for tick in _ticks(xmin, xmax):
        x = left + (tick - xmin) / (xmax - xmin) * plot_w
        parts.append(svg.text(x, bottom + 16, _fmt(tick), fill=_TEXT_COLOR,
                              font_size=11, anchor="middle"))

    for si, s in enumerate(series):
        color = _SERIES_COLORS[si % len(_SERIES_COLORS)]
        for p in s["points"]:
            cx = left + (p["x"] - xmin) / (xmax - xmin) * plot_w
            cy = _scale_y(ymin, ymax, top, plot_h, p["y"])
            parts.append(svg.circle(cx, cy, 4, fill=color))
    return parts


_RENDERERS = {
    "bar": _render_bar,
    "line": _render_line,
    "scatter": _render_scatter,
}


def digest(spec):
    """Render a digest spec to an SVG document string.

    ``spec`` may be a dict or a JSON string. Raises ``SpecError`` on invalid
    input. The value axis is auto-scaled to the data so a chart is never clipped.
    """
    if isinstance(spec, str):
        import json

        spec = json.loads(spec)
    validate_digest(spec)

    size = spec.get("size", {})
    width = size.get("width", 800)
    height = size.get("height", 400)

    body = _RENDERERS[spec["chart"]](spec, width, height)
    return svg.svg_document(width, height, body, background="#ffffff")
