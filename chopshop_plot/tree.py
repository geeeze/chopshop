"""Hierarchy spec -> SVG (the ``tree`` operation of the contract).

A technical-drawing tree — the shape an agent or architecture diagram wants:
thin 1px strokes, rounded boxes with a kind-coloured left bar, a monospace
label, a status dot and the node's metrics as dim ``key=value`` lines under the
label.

The layout is the classic one: depth is the distance from the root, every leaf
takes one slot, and an internal node sits centred over its children. Children
are walked in id order, so the drawing is a function of the DOCUMENT rather than
of the order the nodes happened to be written in. A node no root can reach is
still drawn — it becomes the root of its own little tree — because a diagram
that silently drops a node is lying about the graph it claims to show.
"""

from __future__ import annotations

import json

from . import svg
from .digest import _fmt
from .kinds import kind_color, status_color
from .spec import validate_tree

# Geometry, in SVG user units (CSS pixels; y grows downward).
_NODE_W = 168
_NODE_H = 40              # a node with no metrics line
_METRIC_LINE_H = 12       # every metric adds one line under the label
_LEVEL_GAP = 52           # between one depth and the next
_SLOT_GAP = 26            # between two leaf slots
_MARGIN = 32
_TITLE_BAND = 34
_MIN_W = 380
_MIN_H = 220
_RX = 6

_NODE_FILL = "#ffffff"
_NODE_STROKE = "#c3ccd6"
_EDGE_STROKE = "#aeb8c2"
_TEXT = "#111111"
_DIM = "#6a737d"
_MONO = "monospace"
# Monospace advances at 12px and 9px, used for the ONE fit decision below (the
# layout itself is a fixed grid, so nothing else needs measuring).
_LABEL_ADVANCE = 7.2
_STATUS_ADVANCE = 5.4

# "kind drives the accent colour AND the glyph": a second channel, so two kinds
# that hash to neighbouring colours are still told apart. An unnamed kind shows
# its own first letter rather than a generic dot — deterministic, and it says
# something.
_GLYPHS = {
    "root": "◆", "agent": "◇", "subagent": "◇", "tool": "▸", "task": "▪",
    "model": "▣", "service": "▣", "gate": "▷", "data": "▤", "store": "▤",
    "step": "▸", "input": "▸", "output": "◂", "note": "▪", "start": "▸",
    "end": "◂", "check": "▷",
}
_DEFAULT_GLYPH = "•"


def _glyph(kind):
    key = str(kind or "").strip().lower()
    return _GLYPHS.get(key) or key[:1].upper() or _DEFAULT_GLYPH


def _metric_lines(node):
    """A node's metrics as ordered (key, value) pairs.

    Sorted by key so the drawing is a function of the document, and a metric
    with no value is ABSENT (never ``0``) — the rule the whole package lives by.
    """
    metrics = node.get("metrics") or {}
    return [(str(key), value)
            for key, value in sorted(metrics.items(), key=lambda kv: str(kv[0]))
            if value is not None]


def _box_height(node):
    return _NODE_H + _METRIC_LINE_H * len(_metric_lines(node))


# ---------------------------------------------------------------------------
# Hierarchy: who is a root, who is whose child, which slot is whose.
# ---------------------------------------------------------------------------

def _children(nodes, edges):
    """parent id -> sorted, de-duplicated child ids.

    A self-edge is dropped: it carries no hierarchy and a node cannot own its
    own slot. Sorted by id because the layout must not depend on the order the
    edges were written in, and a repeated edge is one edge.
    """
    kids = {node["id"]: set() for node in nodes}
    for edge in edges:
        if edge["from"] != edge["to"]:
            kids[edge["from"]].add(edge["to"])
    return {nid: sorted(children) for nid, children in kids.items()}


def _roots(nodes, edges):
    """The nodes no edge points at, in document order.

    If every node has an incoming edge (a cycle), the first node in the document
    is the root: something has to sit at the top, and "first" is the only choice
    that does not rank the nodes by degree — this engine ranks, it does not
    choose.
    """
    ids = [node["id"] for node in nodes]
    pointed_at = {edge["to"] for edge in edges if edge["from"] != edge["to"]}
    return [nid for nid in ids if nid not in pointed_at] or ids[:1]


def _walk(order_seeds, children):
    """Walk the forest: (post-order, walked children, depth).

    Post-order — every child before its parent — is what the slot pass needs.
    ``order_seeds`` is the roots first and then every node id: a node that is
    already drawn is skipped, so a node no root reaches is drawn as the root of
    its own subtree instead of vanishing, and a cycle cannot walk forever.
    """
    order, walked, depth, drawn = [], {}, {}, set()
    for seed in order_seeds:
        if seed in drawn:
            continue
        drawn.add(seed)
        depth[seed] = 0
        stack = [(seed, False)]
        while stack:
            nid, expanded = stack.pop()
            if expanded:
                order.append(nid)
                continue
            walked[nid] = [child for child in children.get(nid, ())
                           if child not in drawn]
            for child in walked[nid]:
                drawn.add(child)
                depth[child] = depth[nid] + 1
            stack.append((nid, True))
            for child in reversed(walked[nid]):
                stack.append((child, False))
    return order, walked, depth


def _slots(order, walked):
    """One slot per leaf; an internal node centred over its children."""
    slots, next_slot = {}, 0
    for nid in order:                      # children first: their slots exist
        placed = [slots[child] for child in walked[nid]]
        if placed:
            slots[nid] = (min(placed) + max(placed)) / 2
        else:
            slots[nid] = next_slot
            next_slot += 1
    return slots, next_slot


def _geometry(nodes, edges, layout):
    """Boxes, edge pairs and the size of the drawing.

    Boxes are in content coordinates (origin at the top-left of the drawing);
    the canvas pass is what translates them. ``tb`` stacks levels downward and
    spreads leaf slots across; ``lr`` does the same with the two axes swapped,
    so a parent is always at the depth its distance from the root earns it.
    """
    kids = _children(nodes, edges)
    roots = _roots(nodes, edges)
    order, walked, depth = _walk(roots + [node["id"] for node in nodes], kids)
    slots, slot_count = _slots(order, walked)
    heights = {node["id"]: _box_height(node) for node in nodes}

    boxes = {}
    if layout == "tb":
        level_h = {}
        for nid, level in depth.items():
            level_h[level] = max(level_h.get(level, 0), heights[nid])
        level_y, y = {}, 0
        for level in range(max(level_h) + 1 if level_h else 0):
            level_y[level] = y
            y += level_h.get(level, 0) + _LEVEL_GAP
        step = _NODE_W + _SLOT_GAP
        for nid in order:
            boxes[nid] = (slots[nid] * step, level_y[depth[nid]], _NODE_W, heights[nid])
        content_w = slot_count * step - _SLOT_GAP if slot_count else 0
        content_h = y - _LEVEL_GAP if level_h else 0
    else:  # lr
        row_h = max(heights.values()) if heights else 0
        step = row_h + _SLOT_GAP
        step_x = _NODE_W + _LEVEL_GAP
        for nid in order:
            boxes[nid] = (depth[nid] * step_x, slots[nid] * step + (row_h - heights[nid]) / 2,
                          _NODE_W, heights[nid])
        content_w = (max(depth.values()) + 1) * step_x - _LEVEL_GAP if depth else 0
        content_h = slot_count * step - _SLOT_GAP if slot_count else 0

    pairs = sorted({(edge["from"], edge["to"]) for edge in edges
                    if edge["from"] != edge["to"]})
    return boxes, pairs, content_w, content_h


# ---------------------------------------------------------------------------
# Drawing.
# ---------------------------------------------------------------------------

def _edge(pair, boxes, layout):
    """One connector: a 4-point elbow from the source box to the target box.

    An elbow rather than a straight line, because straight lines through a
    layered tree cross each other and a crossing is read as a relationship that
    does not exist.
    """
    sx, sy, sw, sh = boxes[pair[0]]
    tx, ty, tw, th = boxes[pair[1]]
    if layout == "tb":
        start = (sx + sw / 2, sy + sh)
        end = (tx + tw / 2, ty)
        mid = (start[1] + end[1]) / 2
        points = [start, (start[0], mid), (end[0], mid), end]
    else:
        start = (sx + sw, sy + sh / 2)
        end = (tx, ty + th / 2)
        mid = (start[0] + end[0]) / 2
        points = [start, (mid, start[1]), (mid, end[1]), end]
    # A straight child (both boxes on the same centre line) collapses to a plain
    # line: the repeated elbow point is dropped rather than emitted.
    points = [point for i, point in enumerate(points) if i == 0 or point != points[i - 1]]
    return svg.polyline(points, stroke=_EDGE_STROKE, stroke_width=1)


def _node_elements(node, box):
    """One node: the box, the kind bar, the glyph, the label, dot and metrics."""
    x, y, w, h = box
    kind = node.get("kind")
    accent = kind_color(kind)
    label = node.get("label") or node["id"]
    parts = [
        svg.rect(x, y, w, h, fill=_NODE_FILL, stroke=_NODE_STROKE, stroke_width=1,
                 rx=_RX),
        # The kind bar: the accent colour, inside the rounded box.
        svg.rect(x + 1, y + 1, 4, h - 2, fill=accent, rx=2),
        svg.text(x + 14, y + 21, _glyph(kind), fill=accent, font_size=12,
                 font_family=_MONO),
        svg.text(x + 30, y + 21, label, fill=_TEXT, font_size=12,
                 font_family=_MONO),
    ]
    status = node.get("status")
    if status:
        # The dot is ALWAYS drawn: it is the channel that carries the status
        # without words. The word rides beside it only when it fits next to the
        # label, because overlapping text is not a badge, it is a smudge.
        colour = status_color(status)
        parts.append(svg.circle(x + w - 14, y + 16, 4, fill=colour))
        label_end = x + 30 + _LABEL_ADVANCE * len(str(label))
        status_start = x + w - 24 - _STATUS_ADVANCE * len(status)
        if label_end + 8 <= status_start:
            parts.append(svg.text(x + w - 24, y + 20, status, fill=colour,
                                  font_size=9, anchor="end", font_family=_MONO))
    for i, (key, value) in enumerate(_metric_lines(node)):
        parts.append(svg.text(x + 14, y + 34 + i * _METRIC_LINE_H,
                              "%s=%s" % (key, _fmt(value)), fill=_DIM,
                              font_size=10, font_family=_MONO))
    return parts


def _title(title, width):
    if not title:
        return []
    return [svg.text(width / 2, 22, title, fill=_TEXT, font_size=15, anchor="middle")]


def tree(spec):
    """Render a tree spec to an SVG document string.

    ``spec`` may be a dict or a JSON string. Raises ``SpecError`` on invalid
    input — an edge to a node that does not exist and a duplicate node id are
    both refused rather than approximated. Missing data (no label, no status, a
    metric with no value) renders as absent, never as a zero.
    """
    if isinstance(spec, str):
        spec = json.loads(spec)
    validate_tree(spec)

    nodes = spec["nodes"]
    edges = spec.get("edges", [])
    layout = spec.get("layout", "tb")
    size = spec.get("size") or {}
    title = spec.get("title")

    boxes, pairs, content_w, content_h = _geometry(nodes, edges, layout)

    # An explicit `size` is the canvas; without one the canvas fits the drawing.
    band = _TITLE_BAND if title else 0
    width = size.get("width") or max(_MIN_W, content_w + 2 * _MARGIN)
    height = size.get("height") or max(_MIN_H, band + content_h + 2 * _MARGIN)
    ox = (width - content_w) / 2
    oy = band + (height - band - content_h) / 2
    placed = {nid: (x + ox, y + oy, w, h) for nid, (x, y, w, h) in boxes.items()}

    body = []
    # Edges first: a box never has an unrelated line drawn across it.
    for pair in pairs:
        body.append(_edge(pair, placed, layout))
    # Nodes in id order, so the document is a function of the spec and not of
    # the order the nodes were written in.
    for node in sorted(nodes, key=lambda n: n["id"]):
        body.extend(_node_elements(node, placed[node["id"]]))
    body.extend(_title(title, width))
    return svg.svg_document(width, height, body, background="#ffffff")
