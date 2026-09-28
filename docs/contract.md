# The chopshop-plot contract

This file is the **interface**, not an implementation note. A backend in any
language that reads these JSON documents and writes the SVG they describe is a
valid `chopshop-plot` backend. The Python package in this repo is the reference
implementation; richer backends (`matplotlib`+`shapely` in Python, `Makie` in
Julia, `ggplot2` in R) may implement the same contract with more chart types or
geometry operations, but the spec on the wire and the SVG on the wire do not
change.

Two operations, each one JSON document in, SVG out.

## Common rules

- Every document has an `"op"` field: `"generate"` or `"digest"`.
- Output is **one SVG document** (a single `<svg>` element). A parameter sweep
  that yields multiple candidates is a later extension and returns one SVG per
  member; it does not change these base shapes.
- Coordinates are in SVG user units (CSS pixels). Y grows downward.
- All fields listed are required unless marked optional. Unknown fields are
  ignored, never fatal.
- A backend MUST reject an invalid spec with a clear error, not silently emit
  a wrong SVG. The reference implementation exits `3` on an invalid spec.

## `generate` — a geometry spec

```json
{
  "op": "generate",
  "spec": {
    "canvas": { "width": 1000, "height": 1000, "background": "#ffffff" },
    "elements": [
      { "type": "rect",    "x": 10, "y": 10, "width": 100, "height": 100, "fill": "#000000" },
      { "type": "circle",  "cx": 500, "cy": 500, "r": 200, "fill": "#ff0000" },
      { "type": "ellipse", "cx": 250, "cy": 250, "rx": 120, "ry": 60, "fill": "#00ff00" },
      { "type": "polygon", "points": [[0, 0], [200, 0], [100, 200]], "fill": "#0000ff" },
      { "type": "polyline", "points": [[0, 0], [100, 100], [200, 0]], "stroke": "#111111", "stroke_width": 4 },
      { "type": "line",    "x1": 0, "y1": 0, "x2": 200, "y2": 200, "stroke": "#111111", "stroke_width": 2 },
      { "type": "path",    "d": "M 0 0 L 100 0 L 50 100 Z", "fill": "#ffff00" }
    ],
    "tiling": {
      "grid": [3, 3],
      "cell": [220, 220],
      "origin": [40, 40],
      "element": { "type": "circle", "cx": 110, "cy": 110, "r": 80, "fill": "#333333" }
    }
  }
}
```

Element types and their fields:

| type | fields |
|---|---|
| `rect` | `x`, `y`, `width`, `height`, optional `rx`, `fill`, `stroke`, `stroke_width` |
| `circle` | `cx`, `cy`, `r`, optional `fill`, `stroke`, `stroke_width` |
| `ellipse` | `cx`, `cy`, `rx`, `ry`, optional `fill`, `stroke`, `stroke_width` |
| `polygon` | `points` (array of `[x, y]`), optional `fill`, `stroke`, `stroke_width` |
| `polyline` | `points`, optional `stroke`, `stroke_width` |
| `line` | `x1`, `y1`, `x2`, `y2`, optional `stroke`, `stroke_width` |
| `path` | `d` (SVG path data), optional `fill`, `stroke`, `stroke_width` |

`fill`, `stroke`, `background` are CSS colours. `stroke_width` is a number.
The positional/defining fields in the table are **required** (a `circle` must
carry `cx`, `cy`, `r`; a `rect` must carry `x`, `y`, `width`, `height`; and so
on). `tiling` (optional) repeats `element` across a `grid` of cells of size
`cell` starting at `origin`; the element's own coordinates are offsets within
each cell. `tiling` and `elements` compose — tiled elements are drawn first.

The SVG a backend emits MUST carry `width`, `height` and `viewBox` on the root,
matching `canvas`, so the pipeline can consume it as a normal candidate raster
source.

## `digest` — a metrics spec

```json
{
  "op": "digest",
  "spec": {
    "chart": "bar",
    "title": "Candidate scores",
    "size": { "width": 800, "height": 400 },
    "data": {
      "labels": ["cand-1", "cand-2", "cand-3"],
      "series": [ { "name": "score", "values": [0.8, 0.4, 0.9] } ]
    }
  }
}
```

Chart types:

| chart | data shape |
|---|---|
| `bar` | `labels` (array) + `series` (array of `{name, values}`), or a bare `values` array with `labels` |
| `line` | same as `bar` — each series is a polyline |
| `scatter` | `points` (array of `{x, y}`), or `series` as `{name, points: [{x, y}, ...]}` |

`size` (optional, default `800x400`) sets the SVG dimensions. `title` is
optional. The backend MUST auto-scale the value axis to fit the data (min and
max of all series) so a chart is never clipped, and MUST render a value axis and
an axis line so the chart is readable without any metadata beyond the spec.

## Backend conformance

A backend conforms if, for a valid spec, it emits a well-formed SVG whose root
carries the canvas/size, and for an invalid spec it reports an error rather than
emitting a partial document. There is no hidden state and no network protocol —
a backend is a function from these JSON documents to SVG, so it slots into a
shell pipeline (`front_pipeline.sh`) or a service wrapper identically.
