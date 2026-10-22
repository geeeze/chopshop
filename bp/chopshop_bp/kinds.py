"""Kind -> colour, shared by the diagram operations (`tree` and `log`).

Both operations carry a free-string ``kind`` on every element and colour it. A
diagram is only readable if a kind is ALWAYS the same colour — across the nodes
of one tree, across the rows of one log, and across two drawings of the same
document — so the table lives here once instead of once per module, and an
unknown kind falls back to a colour derived from its own name.

``zlib.crc32`` rather than the built-in ``hash()``: ``hash()`` is salted per
process, so the same document would draw a different colour in a second run —
the one thing a colour-by-kind rule must never do.
"""

import re
import zlib

# The shop's palette (the chart series colours), so a diagram and a chart of the
# same thing do not disagree about what a colour means.
from .digest import _SERIES_COLORS as _PALETTE

# Named kinds, a node's first and an event's second. Matched exactly and
# case-insensitively; anything else falls through to _palette_color.
KIND_COLORS = {
    # tree: what a NODE is
    "root": "#111111",
    "agent": "#f58518",
    "subagent": "#f58518",
    "tool": "#54a24b",
    "task": "#4c78a8",
    "model": "#72b7b2",
    "service": "#b279a2",
    "gate": "#e45756",
    "data": "#8c6d31",
    "store": "#8c6d31",
    "step": "#4c78a8",
    "input": "#54a24b",
    "output": "#b279a2",
    "note": "#9aa5b1",
    # log: what an EVENT is
    "start": "#54a24b",
    "end": "#4c78a8",
    "finish": "#4c78a8",
    "pass": "#54a24b",
    "ok": "#54a24b",
    "fail": "#e45756",
    "error": "#e45756",
    "warn": "#eeca3b",
    "warning": "#eeca3b",
    "info": "#4c78a8",
    "debug": "#9aa5b1",
    "retry": "#f58518",
    "skip": "#c3ccd6",
    "todo": "#eeca3b",
    "read": "#72b7b2",
    "write": "#8c6d31",
    "query": "#72b7b2",
}

# Statuses, keyed by the word they are written as. A status is a free string in
# the contract, so the tokens below are what a caller normally means by it.
STATUS_COLORS = {
    "pass": "#2f9e44", "passed": "#2f9e44", "ok": "#2f9e44",
    "done": "#2f9e44", "success": "#2f9e44",
    "fail": "#e03131", "failed": "#e03131", "error": "#e03131",
    "blocked": "#e03131",
    "warn": "#e8930c", "warning": "#e8930c", "stale": "#e8930c",
    "drift": "#e8930c",
    "run": "#1c7ed6", "running": "#1c7ed6", "active": "#1c7ed6",
    "queued": "#1c7ed6",
    "skip": "#868e96", "skipped": "#868e96", "pending": "#868e96",
    "idle": "#868e96",
}

# What a kind or a status nobody named gets. Deliberately not a data colour:
# "unknown" should not look like one of the categories.
UNKNOWN = "#868e96"


def _key(value):
    return str(value).strip().lower()


def _palette_color(key):
    return _PALETTE[zlib.crc32(key.encode("utf-8")) % len(_PALETTE)]


def kind_color(kind):
    """The accent colour for a free-string kind: the table, else its own name."""
    key = _key(kind)
    if not key:
        return UNKNOWN
    return KIND_COLORS.get(key) or _palette_color(key)


def status_color(status):
    """The dot colour for a free-string status."""
    key = _key(status)
    if not key:
        return UNKNOWN
    if key in STATUS_COLORS:
        return STATUS_COLORS[key]
    # "gate-failed" or "render error" name a status in words: a token match
    # reads that without letting a substring inside an unrelated word match
    # ("broken" contains "ok", and a green dot for a broken thing is a lie).
    for token in re.split(r"[^a-z0-9]+", key):
        if token in STATUS_COLORS:
            return STATUS_COLORS[token]
    return UNKNOWN
