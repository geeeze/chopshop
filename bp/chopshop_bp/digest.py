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
_MARGIN_TOP = 56  # title band (y=22) + legend band (y=40)
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


def _axis_range(vmin, vmax, target=5):
    """Round the value axis OUT to a nice step, never across the data (bp#5).

    The rule, stated because it was not: the axis maximum is the smallest
    multiple of the tick step that is >= the tallest data value, and the axis
    minimum is the largest multiple <= the lowest. Two failures this prevents:

      * rounding DOWN below the tallest value, where the bar overflows the plot
        area and the chart lies about its own scale;
      * an axis maximum that implies headroom the plot area does not have,
        where a tick sits above the top gridline -- the "97 against a 100"
        misreading.

    Consequences worth stating: the top gridline is at or above every data
    value, so a bar's top always lands inside the frame, and every tick the
    renderer draws falls on a gridline that is inside the plot area rather than
    in the title/legend band above it.
    """
    if vmax < vmin:
        # Defensive, not a renderer path: bar/line/scatter each build their
        # bounds from min/max, so this only happens when the helper is called
        # directly. Swapping is the honest reading, and it keeps `_nice_step`
        # off `log10` of a negative span, which is a crash rather than a chart.
        vmin, vmax = vmax, vmin
    if vmax == vmin:
        vmax = vmin + 1
    step = _nice_step(vmax - vmin, target)
    lo = math.floor(vmin / step) * step
    hi = math.ceil(vmax / step) * step
    if hi <= lo:            # a span narrower than one step (e.g. 0.4 .. 0.5)
        hi = lo + step
    return round(lo, 10), round(hi, 10)


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


# Approximate advance width per character, in em, for the sans-serif stack the
# SVG uses. MEASURED-ISH from the default UI sans metrics at 1px; it is an
# estimate and only has to be good enough to lay text out, which is why every
# placement below clamps to the frame rather than trusting it.
_EM_WIDE = 0.62   # capitals, digits, most punctuation
_EM_NARROW = 0.34  # i l j t f r I . , ' : ; | !


def _text_width(s, font_size):
    """Estimated rendered width of `s` at `font_size`, in px."""
    total = 0.0
    for ch in s:
        if ch in "iljtfrI.,':;|!":
            total += _EM_NARROW
        elif ch == " ":
            total += _EM_NARROW * 1.2
        else:
            total += _EM_WIDE
    return total * font_size


def _fit(s, max_px, font_size):
    """Truncate `s` with an ellipsis so it fits inside `max_px`."""
    if _text_width(s, font_size) <= max_px:
        return s
    ell = "\u2026"
    budget = max_px - _text_width(ell, font_size)
    out = ""
    for ch in s:
        if _text_width(out + ch, font_size) > budget:
            break
        out += ch
    return (out.rstrip() + ell) if out else ell


def _title(title, width, y=22):
    """Title band, centred. Kept on its own baseline so the legend can sit
    below it -- these two used to share y~21 and overprint each other."""
    if not title:
        return []
    return [svg.text(width / 2, y, _fit(str(title), width - 2 * _MARGIN_RIGHT, 15),
                     fill="#111111", font_size=15, anchor="middle")]


def _legend(series, width, y=40):
    """Legend band, right-aligned, on its OWN row beneath the title.

    Widths come from _text_width rather than a 6px-per-char guess, each entry is
    clamped so it cannot run past the left margin, and a name too wide for the
    space it has is truncated instead of overprinting its neighbour.
    """
    if len(series) <= 1:
        return []
    parts = []
    font_size = 10
    x = width - _MARGIN_RIGHT
    # Reserve room for the left margin so a long series name is clipped rather
    # than allowed to run off the left edge of the frame.
    floor = _MARGIN_LEFT + 4
    # Place entries right-to-left in REVERSE series order so the visual order
    # left-to-right matches the series (and bar) order.
    for i in range(len(series) - 1, -1, -1):
        s = series[i]
        name = str(s.get("name", f"series-{i}"))
        # 8px swatch + 4px gap before the text, plus 14px of padding between
        # this entry and the next one to its left. `avail` is the room between
        # the current text's RIGHT edge (x - 12) and the left margin floor, MINUS
        # the 14px of air that must survive to this entry's left neighbour --
        # without that subtraction the last entry eats the gap and crosses the
        # margin by a few px, which is what the geometry check caught.
        avail = (x - 12) - floor - 14
        if avail <= _text_width("M", font_size):
            break  # no room left for even a minimal label; stop rather than pile up
        label_text = _fit(name, avail, font_size)
        label_w = _text_width(label_text, font_size)
        swatch = svg.rect(x - 8, y - 8, 8, 8,
                          fill=_SERIES_COLORS[i % len(_SERIES_COLORS)])
        label = svg.text(x - 12, y, label_text, fill=_TEXT_COLOR,
                         font_size=font_size, anchor="end")
        parts.append(swatch)
        parts.append(label)
        x -= 12 + label_w + 14
    return parts


def _axis_labels(xs, labels, bottom, plot_w, font_size=11):
    """X-axis category labels, thinned so neighbours do not overprint.

    The pitch between adjacent label centres is the real constraint: at
    font_size 11 a label needs roughly 7px of air either side, so we keep every
    Nth label where N is chosen from the measured pitch. Long labels are
    truncated to the pitch they were allotted.
    """
    if not labels:
        return []
    n = len(labels)
    if n == 1 or plot_w <= 0:
        return [svg.text(xs[0], bottom + 16, _fit(str(labels[0]), plot_w, font_size),
                         fill=_TEXT_COLOR, font_size=font_size, anchor="middle")]
    pitch = plot_w / (n - 1) if n > 1 else plot_w
    # A label needs its own width plus a gap; measure the widest one.
    widest = max(_text_width(str(lb), font_size) for lb in labels)
    needed = widest + 6  # +6px minimum air between neighbours
    step = 1
    if pitch > 0:
        step = max(1, int(-(-needed // pitch)))  # ceil division
    out = []
    for i, label in enumerate(labels):
        if i % step:
            continue
        label = str(label)
        # Clamp the CENTRE into the plot area, then truncate to the pitch this
        # label was allotted. Clamping first is what stops an edge label being
        # sliced to a stub: the first draft truncated before clamping and
        # produced a bare "40" for a full label.
        half = _text_width(label, font_size) / 2
        if plot_w > half * 2:
            x = min(max(xs[i], half), plot_w + half)
        else:
            x = xs[i]
        allow = max(pitch * step - 4, 12)
        if _text_width(label, font_size) > allow:
            label = _fit(label, allow, font_size)
        out.append(svg.text(x, bottom + 16, label,
                            fill=_TEXT_COLOR, font_size=font_size, anchor="middle"))
    return out


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
    # Bars start at zero and must not overflow: round the axis OUT (bp#5).
    vmin, vmax = _axis_range(vmin, vmax)

    left, right, top, bottom, plot_w, plot_h = _plot_area(width, height)
    parts = _y_axis(vmin, vmax, left, top, plot_w, plot_h)
    parts += _x_axis(left, top, plot_w, plot_h)
    parts += _title(spec.get("title"), width)
    parts += _legend(series, width, y=40)

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
    # Category labels go through the SAME thinning helper the line renderer uses.
    # They used to be emitted here, one full-size <text> per group, so a crowded
    # axis overprinted itself; the bar geometry is already a regular pitch, so
    # handing the centres over is all that is needed.
    parts += _axis_labels([left + gi * group_w + group_w / 2 for gi in range(n)],
                          labels, bottom, plot_w, font_size=11)
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
    # Round OUT to a nice step so the top gridline clears the data (bp#5).
    vmin, vmax = _axis_range(vmin, vmax)

    left, right, top, bottom, plot_w, plot_h = _plot_area(width, height)
    parts = _y_axis(vmin, vmax, left, top, plot_w, plot_h)
    parts += _x_axis(left, top, plot_w, plot_h)
    parts += _title(spec.get("title"), width)
    parts += _legend(series, width, y=40)

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
    parts += _axis_labels(xs, labels, bottom, plot_w, font_size=11)
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
    # Both axes round OUT (bp#5): an x tick past xmax would be drawn past the
    # right margin, where nothing clips it.
    xmin, xmax = _axis_range(xmin, xmax)
    ymin, ymax = _axis_range(ymin, ymax)

    left, right, top, bottom, plot_w, plot_h = _plot_area(width, height)
    parts = _y_axis(ymin, ymax, left, top, plot_w, plot_h)
    parts += _x_axis(left, top, plot_w, plot_h)
    parts += _title(spec.get("title"), width)
    parts += _legend(series, width, y=40)

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
