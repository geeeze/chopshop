"""The query-shaped drawing operation: run records + a chart spec -> SVG.

This is the archive view of the blend-plot service, not a metrics engine: the
input is a set of run records (the archive spine, ``.run.json``) and one chart
spec; the output is one SVG. The same operation serves chopshop-studio, an agent
and the CLI with no extra work — it draws the records it is handed, and applies
no score of its own.

Chart types:

- ``scatter`` -- any numeric field vs any other, across every run. Colour by a
  categorical field. The axes are the user's choice; nothing is hardcoded.
- ``pareto``  -- a 2-D trade-off frontier: minimise ``x`` and ``y``, highlight
  the non-dominated candidates. Ranks and visualises without choosing.
- ``diff``    -- two candidates (or two recipes on one source) side by side:
  which flags changed, which metrics moved.

Missing data renders as absent, never as zero.
"""

from __future__ import annotations

from . import svg
from . import metrics
from .digest import _SERIES_COLORS, _plot_area, _ticks, _fmt

_MARGIN_TOP = 40
_MARGIN_BOTTOM = 52
_MARGIN_LEFT = 64
_MARGIN_RIGHT = 16
_AXIS_COLOR = "#333333"
_GRID_COLOR = "#e8e8e8"
_TEXT_COLOR = "#444444"
_FRONTIER_COLOR = "#111111"


class QueryError(ValueError):
    """The chart spec does not satisfy the query contract."""


# ---------------------------------------------------------------------------
# Spec validation.
# ---------------------------------------------------------------------------

def _require(spec, key, where):
    if key not in spec or spec[key] is None:
        raise QueryError(f"{where}: missing required field '{key}'")


def validate_query(spec):
    if not isinstance(spec, dict):
        raise QueryError("spec must be an object")
    chart = spec.get("chart")
    if chart not in ("scatter", "pareto", "diff"):
        raise QueryError("'chart' must be one of scatter, pareto, diff")

    if chart in ("scatter", "pareto"):
        for axis in ("x", "y"):
            _require(spec, axis, chart)
            field = spec[axis]
            if not metrics.is_numeric_field(field):
                raise QueryError(f"{chart}: axis '{field}' is not a numeric metric field")
        if "color" in spec and spec["color"] is not None:
            if not metrics.is_categorical_field(spec["color"]):
                raise QueryError(f"{chart}: 'color' must be a categorical field")
    else:  # diff
        for side in ("left", "right"):
            _require(spec, side, "diff")
            sel = spec[side]
            if not isinstance(sel, dict):
                raise QueryError(f"diff.{side}: must be an object")
            has_id = "candidate_id" in sel and sel["candidate_id"]
            has_recipe = ("recipe_hash" in sel and sel["recipe_hash"]
                          and "source_sha256" in sel and sel["source_sha256"])
            if not (has_id or has_recipe):
                raise QueryError(
                    f"diff.{side}: need 'candidate_id' or 'recipe_hash'+'source_sha256'")
    return spec


# ---------------------------------------------------------------------------
# Row resolution.
# ---------------------------------------------------------------------------

def flatten_runs(runs):
    """Flatten a list of run-record dicts into (rows, metas)."""
    rows, metas = [], []
    for run in runs:
        r, m = metrics.flatten_run(run)
        rows.extend(r)
        metas.append(m)
    return rows, metas


def _select_row(selector, rows):
    """Resolve a diff side selector to a single flat row."""
    if selector.get("candidate_id"):
        for row in rows:
            if row.get("candidate_id") == selector["candidate_id"]:
                return row
        raise QueryError(f"diff: no candidate '{selector['candidate_id']}' in the run set")
    recipe = selector["recipe_hash"]
    source = selector["source_sha256"]
    matches = [r for r in rows if r.get("recipe_hash") == recipe
               and r.get("source_sha256") == source]
    if not matches:
        raise QueryError(f"diff: no candidates for recipe {recipe} on source {source[:8]}...")
    # "best" = fewest hard gates, then lowest artwork MAE. Never a winner, a
    # representative: we pick the cleanest instance of the recipe to diff.
    matches.sort(key=lambda r: (
        r.get("hard") if r.get("hard") is not None else 10**9,
        r.get("mae_art") if r.get("mae_art") is not None else 10**9,
    ))
    return matches[0]


# ---------------------------------------------------------------------------
# Scatter / pareto (shared geometry).
# ---------------------------------------------------------------------------

def _numeric_values(rows, field):
    return [(r.get(field), r) for r in rows if r.get(field) is not None]


def _extrema(values):
    vals = [v for v in values if v is not None]
    if not vals:
        return 0.0, 1.0
    return min(vals), max(vals)


def _pad(lo, hi):
    if lo == hi:
        lo -= 1
        hi += 1
    span = hi - lo
    return lo - span * 0.05, hi + span * 0.05


def _scale(value, lo, hi, top, height):
    if hi == lo:
        return top
    return top + (hi - value) / (hi - lo) * height


def _color_for(rows, field):
    """Map a categorical field to a colour per distinct value."""
    values = []
    for r in rows:
        v = r.get(field)
        if v is not None and v not in values:
            values.append(v)
    return {v: _SERIES_COLORS[i % len(_SERIES_COLORS)] for i, v in enumerate(values)}


def _scatter_geometry(spec, rows):
    """Shared x/y geometry for scatter and pareto. Returns a dict of computed
    positions so the renderers stay dumb."""
    xfield, yfield = spec["x"], spec["y"]
    color_field = spec.get("color")

    width = (spec.get("size") or {}).get("width", 800)
    height = (spec.get("size") or {}).get("height", 400)
    left, right, top, bottom, plot_w, plot_h = _plot_area(width, height)

    plotted = [r for r in rows if r.get(xfield) is not None and r.get(yfield) is not None]
    xs = [r[xfield] for r in plotted]
    ys = [r[yfield] for r in plotted]
    xmin, xmax = _pad(*_extrema(xs))
    ymin, ymax = _pad(*_extrema(ys))

    points = [
        (left + (r[xfield] - xmin) / (xmax - xmin) * plot_w,
         _scale(r[yfield], ymin, ymax, top, plot_h))
        for r in plotted
    ]

    colors = _color_for(plotted, color_field) if color_field else None
    return {
        "width": width, "height": height,
        "left": left, "right": right, "top": top, "bottom": bottom,
        "plot_w": plot_w, "plot_h": plot_h,
        "xmin": xmin, "xmax": xmax, "ymin": ymin, "ymax": ymax,
        "plotted": plotted, "points": points, "colors": colors,
        "xfield": xfield, "yfield": yfield, "color_field": color_field,
    }


def _axis_and_grid(g):
    parts = []
    for tick in _ticks(g["xmin"], g["xmax"]):
        x = g["left"] + (tick - g["xmin"]) / (g["xmax"] - g["xmin"]) * g["plot_w"]
        parts.append(svg.line(x, g["top"], x, g["top"] + g["plot_h"],
                              stroke=_GRID_COLOR, stroke_width=1))
        parts.append(svg.text(x, g["bottom"] + 16, _fmt(tick),
                              fill=_TEXT_COLOR, font_size=11, anchor="middle"))
    for tick in _ticks(g["ymin"], g["ymax"]):
        y = _scale(tick, g["ymin"], g["ymax"], g["top"], g["plot_h"])
        parts.append(svg.line(g["left"], y, g["left"] + g["plot_w"], y,
                              stroke=_GRID_COLOR, stroke_width=1))
        parts.append(svg.text(g["left"] - 6, y + 4, _fmt(tick),
                              fill=_TEXT_COLOR, font_size=11, anchor="end"))
    # axis box
    parts.append(svg.line(g["left"], g["top"], g["left"], g["top"] + g["plot_h"],
                          stroke=_AXIS_COLOR, stroke_width=1))
    parts.append(svg.line(g["left"], g["top"] + g["plot_h"],
                          g["left"] + g["plot_w"], g["top"] + g["plot_h"],
                          stroke=_AXIS_COLOR, stroke_width=1))
    # axis labels
    parts.append(svg.text(g["left"] + g["plot_w"] / 2, g["height"] - 12,
                          g["xfield"], fill="#111111", font_size=12, anchor="middle"))
    ylabel_y = g["top"] + g["plot_h"] / 2
    parts.append(svg.text(14, ylabel_y, g["yfield"],
                          fill="#111111", font_size=12, anchor="middle",
                          transform=f"rotate(-90 14 {ylabel_y})"))
    return parts


def _title(text, width):
    return [svg.text(width / 2, 22, text, fill="#111111", font_size=15, anchor="middle")] \
        if text else []


def _legend(g, width):
    if not g["colors"]:
        return []
    parts = []
    x = width - _MARGIN_RIGHT
    for label, color in g["colors"].items():
        parts.append(svg.rect(x - 8, 12, 8, 8, fill=color))
        parts.append(svg.text(x - 12, 20, str(label), fill=_TEXT_COLOR,
                              font_size=10, anchor="end"))
        x -= 16 + 6 * len(str(label))
    return parts


def _render_scatter(spec, rows):
    g = _scatter_geometry(spec, rows)
    parts = _axis_and_grid(g)
    parts += _title(spec.get("title"), g["width"])
    parts += _legend(g, g["width"])
    for i, (px, py) in enumerate(g["points"]):
        row = g["plotted"][i]
        color = g["colors"].get(row.get(g["color_field"]), "#4c78a8") if g["colors"] else "#4c78a8"
        parts.append(svg.circle(px, py, 4, fill=color))
    return svg.svg_document(g["width"], g["height"], parts, background="#ffffff")


def _nondominated(points):
    """Indices of the non-dominated points (minimise both axes)."""
    result = []
    for i, (xi, yi) in enumerate(points):
        dominated = False
        for j, (xj, yj) in enumerate(points):
            if xj <= xi and yj <= yi and (xj < xi or yj < yi):
                dominated = True
                break
        if not dominated:
            result.append(i)
    return result


def _render_pareto(spec, rows):
    g = _scatter_geometry(spec, rows)
    parts = _axis_and_grid(g)
    parts += _title(spec.get("title") or "Pareto frontier (lower is better on both axes)",
                    g["width"])
    parts += _legend(g, g["width"])

    # Non-domination is a property of the DATA values (minimise both axes), not
    # the screen pixels -- screen y is inverted, so running it on g["points"]
    # would maximise the y value.  Compute on raw values, then draw the frontier
    # line through the matching screen positions.
    values = [(r[g["xfield"]], r[g["yfield"]]) for r in g["plotted"]]
    frontier = _nondominated(values)
    fpts = sorted((g["points"][i] for i in frontier), key=lambda p: p[0])
    if len(fpts) >= 2:
        parts.append(svg.polyline(fpts, stroke=_FRONTIER_COLOR, stroke_width=2))

    frontier_set = set(frontier)
    for i, (px, py) in enumerate(g["points"]):
        on_frontier = i in frontier_set
        fill = "#111111" if on_frontier else "#9aa5b1"
        parts.append(svg.circle(px, py, 5 if on_frontier else 3, fill=fill))
    return svg.svg_document(g["width"], g["height"], parts, background="#ffffff")


# ---------------------------------------------------------------------------
# Diff view.
# ---------------------------------------------------------------------------

_DIFF_ROWS = [
    ("preset", "categorical"), ("variant", "categorical"),
    ("passed", "categorical"), ("fidelity_verdict", "categorical"),
    ("hard", "numeric"), ("advisory", "numeric"),
    ("layer_a_hard", "numeric"), ("layer_a_advisory", "numeric"),
    ("layer_b_hard", "numeric"), ("layer_b_advisory", "numeric"),
    ("declared_colors", "numeric"), ("rendered_ink_colors", "numeric"),
    ("node_count_total", "numeric"), ("node_count_max", "numeric"),
    ("file_size", "numeric"),
    ("mae", "numeric"), ("mae_art", "numeric"), ("p95", "numeric"),
    ("within10", "numeric"),
    ("tac_exact", "categorical"), ("rendered_continuous_tone", "categorical"),
    ("hard_findings", "numeric"), ("advisory_findings", "numeric"),
    ("color_count", "numeric"),
    ("label", "categorical"), ("selected", "categorical"),
]


def _cell(value, kind):
    if value is None:
        return "—"
    if isinstance(value, float):
        return _fmt(value)
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def _render_diff(spec, rows):
    left = _select_row(spec["left"], rows)
    right = _select_row(spec["right"], rows)

    width = (spec.get("size") or {}).get("width", 720)
    title = spec.get("title") or f"{left.get('candidate_id')} vs {right.get('candidate_id')}"

    parts = _title(title, width)

    col_label = 16
    col_a = 320
    col_b = 470
    col_delta = 620
    y = 52
    row_h = 20

    parts.append(svg.text(col_label, y, "metric", fill=_TEXT_COLOR, font_size=11))
    parts.append(svg.text(col_a, y, _diff_head(spec["left"], left),
                          fill=_TEXT_COLOR, font_size=11, anchor="middle"))
    parts.append(svg.text(col_b, y, _diff_head(spec["right"], right),
                          fill=_TEXT_COLOR, font_size=11, anchor="middle"))
    parts.append(svg.text(col_delta, y, "Δ", fill=_TEXT_COLOR, font_size=11, anchor="middle"))
    y += 10
    parts.append(svg.line(16, y, width - 16, y, stroke=_AXIS_COLOR, stroke_width=1))
    y += row_h

    for field, kind in _DIFF_ROWS:
        lv, rv = left.get(field), right.get(field)
        changed = lv != rv
        row_fill = "#f6f8fa" if changed else None
        if row_fill:
            parts.append(svg.rect(16, y - 12, width - 32, row_h, fill=row_fill))
        parts.append(svg.text(col_label, y, field, fill=_TEXT_COLOR, font_size=11))
        parts.append(svg.text(col_a, y, _cell(lv, kind), fill="#111111",
                              font_size=11, anchor="middle"))
        parts.append(svg.text(col_b, y, _cell(rv, kind), fill="#111111",
                              font_size=11, anchor="middle"))
        if kind == "numeric" and isinstance(lv, (int, float)) and isinstance(rv, (int, float)):
            delta = _fmt(rv - lv)
        elif lv != rv:
            delta = "changed"
        else:
            delta = ""
        parts.append(svg.text(col_delta, y, delta,
                              fill="#111111" if changed else _TEXT_COLOR,
                              font_size=11, anchor="middle"))
        y += row_h

    return svg.svg_document(width, y + 16, parts, background="#ffffff")


def _diff_head(selector, row):
    if selector.get("candidate_id"):
        return selector["candidate_id"]
    return (row.get("preset") or "?") + " · " + (row.get("recipe_hash") or "")[:6]


# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------

_RENDERERS = {
    "scatter": _render_scatter,
    "pareto": _render_pareto,
    "diff": _render_diff,
}


def query(runs, spec):
    """Render a query spec to SVG over a set of run records.

    ``runs`` is a list of parsed run-record dicts (``.run.json``). ``spec`` may
    be a dict or a JSON string. Raises ``QueryError`` on an invalid spec or an
    unresolvable selector.  Missing metric values render as absent, never zero.
    """
    if isinstance(spec, str):
        import json
        spec = json.loads(spec)
    if isinstance(spec, dict) and "spec" in spec and "chart" not in spec:
        spec = spec["spec"]
    validate_query(spec)

    rows, _ = flatten_runs(runs)
    return _RENDERERS[spec["chart"]](spec, rows)
