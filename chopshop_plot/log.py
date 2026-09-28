"""Event spec -> SVG (the ``log`` operation of the contract).

A vertical timeline: one row per event, in the order the document gives them.
The spec order IS the time order — nothing here sorts by ``t``, because ``t`` is
display-only text and sorting on it would re-order the rows by something this
operation cannot read (a locale, a format, a partial time). Every row carries a
kind-coloured marker on the spine, a dim timestamp, the label, and the rank as
``#N`` when the event has one.

A missing field renders as ABSENT: an event with no timestamp has no timestamp,
not midnight, and an event with no rank has no rank, not ``#0``.
"""

from __future__ import annotations

import json

from . import svg
from .kinds import kind_color
from .spec import validate_log

# Geometry, in SVG user units (CSS pixels; y grows downward).
_MARGIN = 28
_TITLE_BAND = 34
_ROW_H = 26
_SPINE_GAP = 18           # the spine -> the timestamp column
_T_COL = 92               # the timestamp column, reserved when any row has one
_LABEL_GAP = 16           # the label column -> '#N'
_MARKER_R = 4
_MIN_W = 420
_MIN_H = 160
_MONO = "monospace"

# A monospace advance at 11px, used ONLY to size an auto canvas (an explicit
# `size` is honoured as given). An estimate is enough: the layout is a fixed
# grid of columns, and the estimate is a pure function of the document.
_ADVANCE = 6.6

_SPINE_STROKE = "#d0d7de"
_SPINE_OVER = "#ffffff"
_TEXT = "#111111"
_DIM = "#6a737d"


def _text_of(event, key):
    value = event.get(key)
    return "" if value is None else str(value)


def _columns(events):
    """The x of each column, and the width the longest row needs.

    Fixed columns rather than a gap after each timestamp: the rows are a list of
    events read down the page, and a list is only readable if the fields line up.
    """
    has_t = any(_text_of(event, "t") for event in events)
    x_t = _SPINE_GAP
    x_label = x_t + (_T_COL if has_t else 0)
    label_w = max((len(_text_of(event, "label")) for event in events), default=0) * _ADVANCE
    x_pos = x_label + label_w + _LABEL_GAP
    pos_w = max((len("#%s" % event["pos"]) for event in events
                 if event.get("pos") is not None), default=0) * _ADVANCE
    return {"x_t": x_t, "x_label": x_label, "x_pos": x_pos, "width": x_pos + pos_w}


def _row(event, cy, columns, x):
    """One event, at its row centre ``cy``. Absent fields draw nothing."""
    parts = [svg.circle(x, cy, _MARKER_R, fill=kind_color(event.get("kind")),
                        stroke=_SPINE_OVER, stroke_width=1)]
    t = _text_of(event, "t")
    if t:
        parts.append(svg.text(x + columns["x_t"], cy + 4, t, fill=_DIM,
                              font_size=11, font_family=_MONO))
    label = _text_of(event, "label")
    if label:
        parts.append(svg.text(x + columns["x_label"], cy + 4, label, fill=_TEXT,
                              font_size=11, font_family=_MONO))
    if event.get("pos") is not None:
        parts.append(svg.text(x + columns["x_pos"], cy + 4, "#%s" % event["pos"],
                              fill=_DIM, font_size=11, font_family=_MONO))
    return parts


def log(spec):
    """Render a log spec to an SVG document string.

    ``spec`` may be a dict or a JSON string. Raises ``SpecError`` on invalid
    input. Rows are drawn in the order the events are given — the spec order is
    the time order — and a missing ``t``, ``label`` or ``pos`` is absent rather
    than an error.
    """
    if isinstance(spec, str):
        spec = json.loads(spec)
    validate_log(spec)

    events = spec["events"]
    size = spec.get("size") or {}
    title = spec.get("title")
    columns = _columns(events)

    # An explicit `size` is the canvas; without one the canvas fits the rows.
    band = _TITLE_BAND if title else 0
    content_h = len(events) * _ROW_H
    rel_w = columns["width"] + _MARKER_R   # the marker pokes out left of the spine
    width = size.get("width") or max(_MIN_W, rel_w + 2 * _MARGIN)
    height = size.get("height") or max(_MIN_H, band + content_h + 2 * _MARGIN)
    ox = _MARKER_R + (width - rel_w) / 2
    oy = band + (height - band - content_h) / 2

    body = []
    if len(events) > 1:
        # The spine runs marker to marker: a line out to nothing is not a spine.
        body.append(svg.line(ox, oy + _ROW_H / 2, ox, oy + content_h - _ROW_H / 2,
                             stroke=_SPINE_STROKE, stroke_width=1))
    for i, event in enumerate(events):
        body.extend(_row(event, oy + i * _ROW_H + _ROW_H / 2, columns, ox))
    if title:
        body.append(svg.text(width / 2, 22, title, fill=_TEXT, font_size=15,
                             anchor="middle"))
    return svg.svg_document(width, height, body, background="#ffffff")
