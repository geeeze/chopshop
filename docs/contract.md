# The chopshop-bp contract

This file is the **interface**, not an implementation note. A backend in any
language that reads these JSON documents and writes the SVG they describe is a
valid `chopshop-bp` backend. The Python package in this repo is the reference
implementation; richer backends (`matplotlib`+`shapely` in Python, `Makie` in
Julia, `ggplot2` in R) may implement the same contract with more chart types or
geometry operations, but the spec on the wire and the SVG on the wire do not
change.

Six operations, each one JSON document in. Five answer with an SVG document (the
`query` operation also takes the run records to draw from); `blender` answers
with a rendered PNG and, optionally, a GLB.

<!-- blend-plot: one service, two halves - `plot` draws documents, `blender` renders 3D. -->

## Common rules

- Every document either carries an `"op"` field — `"generate"`, `"digest"`,
  `"query"`, `"tree"`, `"log"` or `"blender"` — or is that operation's spec alone,
  sent to the operation named by the route or the subcommand. A document that
  carries the envelope is read as `spec` inside it; an explicit `"op"` must MATCH
  the operation it arrives at (a generate document handed to digest is a caller
  error, never a silent best-effort).
- Output is **one SVG document** (a single `<svg>` element). A parameter sweep
  that yields multiple candidates is a later extension and returns one SVG per
  member; it does not change these base shapes. `blender` is the one exception
  and says so in its own section: it answers with rendered files, not a
  document.
- Coordinates are in SVG user units (CSS pixels). Y grows downward.
- All fields listed are required unless marked optional. An unknown field is
  ignored — at the level of a document, a `canvas`/`size` block, a tree node or a
  log event it is never fatal — but it is **refused** on a `generate`/`blender`
  **element** and inside `extrude`, `render` and `export`, where a typo (`filll`,
  `depthd`) would otherwise draw a wrong document in silence.
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
on).

At the top level of the `generate` spec, `canvas` is **required** and must carry a
positive `width` and `height` (and optionally a `background`); `elements` is
optional and may be empty, and a spec with no elements and no `tiling` is a valid
document — an empty canvas is a drawing of a canvas, not an error. (The `blender`
operation is the opposite: a spec with nothing to render is refused, because a
render of nothing is not a render.) `tiling` (optional) repeats `element` across a
`grid` of cells of size `cell` starting at `origin`; the element's own coordinates
are offsets within each cell. `tiling` and `elements` compose — tiled elements are
drawn first.

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

## `tree` — a hierarchy spec

```json
{
  "op": "tree",
  "spec": {
    "title": "Trace pipeline",
    "layout": "tb",
    "nodes": [
      { "id": "source", "label": "source.svg", "kind": "root", "status": "ok" },
      { "id": "gate",   "label": "size gate",  "kind": "gate", "status": "passed",
        "metrics": { "nodes": 1234, "inks": 5 } },
      { "id": "trace",  "label": "VTracer",    "kind": "tool", "status": "running" },
      { "id": "report", "label": "report",     "kind": "tool" }
    ],
    "edges": [
      { "from": "source", "to": "gate" },
      { "from": "gate",   "to": "trace" },
      { "from": "gate",   "to": "report" }
    ]
  }
}
```

| field | |
|---|---|
| `nodes` | required, a list of node objects |
| `edges` | optional, `{ "from", "to" }` objects; both must name an existing node id |
| `layout` | optional `"tb"` (top-to-bottom, the **default**) or `"lr"` (left-to-right) |
| `title` | optional |
| `size` | optional `{ "width", "height" }`; the canvas auto-fits the drawing when absent |

A node carries `id` (required, unique, non-empty), and optionally `label` (its
own id is shown when absent), `kind` (a free string driving the node's accent
colour and glyph), `status` (a free string, drawn as a coloured dot and — when it
fits beside the label — the word) and `metrics` (a flat object of numeric values,
drawn as dim `key=value` lines under the label). A metric whose value is `null`
renders as **absent**, never as `0`. An edge to an unknown node id and a
duplicate node id are both rejected — never a line drawn out to nothing, never
one node silently replacing another.

Layout rules, so two backends can be compared:

- `roots` are the nodes no edge points at; if every node has an incoming edge
  (a cycle), the first node in the document is the root.
- `depth` is the distance from the root; `layout` decides which axis that maps
  to — `tb` grows downward, `lr` grows to the right. Y grows downward in both.
- Each leaf takes one slot; an internal node is centred over its children.
  Children are visited in **id order**, so the drawing is a function of the
  document rather than of the order it was written in.
- A node no root can reach is still drawn, as the root of its own subtree. A
  diagram that drops a node disagrees with the document it claims to show.

The rendering is deliberately semi-technical: 1px strokes throughout, a rounded
box with a kind-coloured left bar, a monospace label, and one flat
kind→colour table with a deterministic fallback for an unknown kind (the colour
is derived from the kind's own name, so the same kind is the same colour in
every drawing).

## `log` — an event spec

```json
{
  "op": "log",
  "spec": {
    "title": "Run events",
    "events": [
      { "t": "00:00:01", "kind": "start", "label": "pipeline started", "pos": 1 },
      { "t": "00:00:02", "kind": "gate",  "label": "size gate passed", "pos": 2 },
      { "t": "00:00:03", "kind": "warn",  "label": "colour drift, declared 5" },
      { "t": "00:00:04", "kind": "end",   "label": "run complete", "pos": 3 }
    ]
  }
}
```

| field | |
|---|---|
| `events` | required, a list of event objects |
| `title` | optional |
| `size` | optional `{ "width", "height" }`; the canvas auto-fits the rows when absent |

An event carries all-optional `t` (a display-only timestamp **string**), `kind`
(a free string driving the marker colour, same table and fallback as `tree`),
`label`, and `pos` (an integer rank, drawn as `#N`).

- **One row per event, in the order given. The spec order IS the time order.**
  A backend MUST NOT sort by `t`: `t` is display text, and sorting on it
  re-orders rows by something the document never promised was comparable.
- Missing fields render as **absent**: an event with no `t` has no timestamp
  (not midnight), one with no `pos` has no rank (not `#0`), and one with no
  `label` shows no label. None of these is an error.
- Each row is a kind-coloured marker on a vertical spine (drawn when the document
  has more than one row — it runs from the first marker to the last, because a
  spine out to nothing is not a spine), the dim timestamp, the label, then `#N`
  when there is one.

## `blender` — a geometry spec, rendered in 3D

The one operation that does not answer with a document: it builds a solid from
the geometry the `generate` vocabulary already describes and renders it with
headless Blender. Same elements, same `tiling`, one more dimension.

```json
{
  "op": "blender",
  "spec": {
    "title": "tray",
    "elements": [
      { "type": "rect",     "x": 0, "y": 0, "width": 300, "height": 200, "fill": "#e04030" },
      { "type": "circle",   "cx": 420, "cy": 100, "r": 90, "fill": "#3080e0" },
      { "type": "polyline", "points": [[0, 260], [200, 340], [400, 260]], "stroke": "#20c060", "stroke_width": 6 }
    ],
    "tiling": {
      "grid": [2, 2],
      "cell": [560, 400],
      "origin": [20, 20],
      "element": { "type": "polygon", "points": [[0, 0], [80, 0], [40, 60]], "fill": "#20c060" }
    },
    "extrude": { "depth": 40, "bevel_depth": 6, "bevel_resolution": 3 },
    "render": { "size": { "width": 1024, "height": 1024 }, "views": 4,
                "background": "#1a1a24", "engine": "workbench",
                "elevation": 25, "azimuth": 0, "projection": "ortho", "lens": 50 },
    "export": { "glb": true }
  }
}
```

An element may also carry its own height and depth, which is what a 3D chart is
made of — four bars are four `rect`s differing only in `depth`:

```json
"elements": [
  { "type": "rect", "x": 0, "y": 0, "width": 90, "height": 90,
    "fill": "#4f8bd6", "depth": 60 },
  { "type": "rect", "x": 110, "y": 0, "width": 90, "height": 90,
    "fill": "#6fc46f", "depth": 140, "z": 20 }
]
```

| field | |
|---|---|
| `elements` | required, the `generate` vocabulary with the same validation (`fill`/`stroke`/`stroke_width` as there, unknown fields refused), plus the 3D-only `z` and `depth` (below) |
| `title` | optional string |
| `tiling` | optional, the same block as `generate` |
| `extrude` | optional `{ "depth": 0.5, "bevel_depth": 0.02, "bevel_resolution": 2 }` |
| `render` | optional `{ "size": { "width": 1024, "height": 1024 }, "views": 1, "background": "#1a1a24", "engine": "workbench", "elevation": 25, "azimuth": 0, "projection": "ortho", "lens": 50, "curve_resolution": { "circle": 64, "corner": 8, "bezier": 16, "spline": 12 }, "shading": { "roughness": 1.0, "metallic": 0.0, "specular": 0.0 } }` |
| `export` | optional `{ "glb": false }` |

`engine` is `workbench` (the default) or `eevee`. A spec with nothing to draw is
refused, with the field named: no elements and no `tiling`, an element with fewer
than two points, or a path that is not a contour. Path data is read as
`M L H V Z C S Q T` (either case); an arc is refused rather than drawn as
something it is not. A typo inside `extrude`, `render` or `export` is an error,
never a silent default.

**The camera.** `elevation` is degrees above the horizon and `azimuth` is where
the view sweep *starts* — `views` still steps evenly around from it, so one view
is exactly one angle and N views walk around from that angle. `elevation: 90`
looks straight down, which is the plan view a chart, a floor plan or a blueprint
is actually read in; `elevation: 0` is the horizon. Both are free angles: a value
outside `0..360` is the same angle rather than a mistake worth refusing.
`projection` is `ortho` (the default — framing independent of the camera's
distance) or `perspective`, and `lens` is the focal length in millimetres for a
perspective camera (default `50`). `lens` is accepted on an ortho spec so a pair
can travel together and changes nothing there.

**Per-element height and depth.** Any element may carry `z` (a number, default
`0`, may be negative) and `depth` (a number >= 0). `z` is the element's *plane*
height and `depth` overrides `extrude.depth` for that one element. Together they
are what makes a 3D chart expressible — every bar is a `rect` differing only in
`depth` — and what lets a spec stack layers rather than putting everything on one
plane. Both are **3D-only**: `generate` draws SVG, which is flat, so it refuses
them instead of accepting and ignoring them. The 3D primitives below take them on
the same terms, so a `sphere` at `z: 40` with `depth: 5` sits its mid-plane at
40 and spans 35..45 like any other solid.


## The metrics schema — the shared data contract

Every chart drawn from pipeline output reads one flat, versioned schema, so no
chart hardcodes a field and a chart written against schema N keeps working
until N bumps. **This is a data contract, not a scoring engine**: it is the shape
of the run records chopshop-studio and the chopshop-svg pipeline hand to the
chart operations, and a backend only reads it — nothing here scores, ranks or
judges.

- **`metrics_version`** is the schema version (currently `1`). A reader refuses
  a version it does not know. Bump it when a field is renamed, added or removed.
- **Field names are flat and boring**: `node_count_max`, not
  `static.path_nodes_max`. The numeric fields are the selectable chart axes;
  the categorical fields are for colouring/filtering/grouping.
- **Missing data is a state, not a zero.** A gate that was skipped (e.g. the
  size gate with no dimensions block) renders as absent, never as `0`. A chart
  that plots `0` for a missing measurement is lying.
- **Runs are indexed by source hash + recipe hash.** The recipe is the sweep
  parameters (preset, filter_speckle, hierarchical, use_palette) hashed into a
  stable `recipe_hash`; the source is `source_sha256`. Together they make "recipe
  A vs recipe B on one source" and "one recipe across sources" directly
  comparable.

Numeric fields (chart axes): `hard`, `advisory`, `layer_a_hard`,
`layer_a_advisory`, `layer_b_hard`, `layer_b_advisory`, `declared_colors`,
`rendered_ink_colors`, `rendered_distinct_colors`, `node_count_total`,
`node_count_max`, `file_size`, `mae`, `mae_art`, `p95`, `within10`,
`tac_exact`, `rendered_continuous_tone`, `hard_findings`,
`advisory_findings`, `color_count`.

Categorical fields: `preset`, `variant`, `passed`, `fidelity_verdict`,
`label`, `selected`.

Identity fields: `candidate_id`, `run_stem`, `source_sha256`, `recipe_hash`.

## `query` — run records + chart spec -> SVG

The third operation is query-shaped: input is a set of run records (the archive
spine, `.run.json`) plus a chart spec; output is one SVG. The same operation
serves the studio, an agent and a CLI. Chart types:

| chart | spec fields | behaviour |
|---|---|---|
| `scatter` | `x`, `y` (numeric fields), optional `color` (categorical), optional `size`, `title` | every candidate across every run as a point; axes are the user's choice |
| `pareto` | `x`, `y` (numeric, minimise both), optional `color`, `size`, `title` | trade-off frontier: non-dominated candidates highlighted, never collapsed to a single number |
| `diff` | `left`, `right` (each `{candidate_id}` or `{recipe_hash, source_sha256}`), optional `size` (`width` only — the height follows the row count), `title` | two candidates/recipes side by side: which flags changed, which metrics moved, with a numeric delta |

A `diff` selector names one candidate directly, or a recipe+source pair (the
cleanest instance of that recipe on that source is diffed — never "the winner",
there is none). Invalid axes (a categorical field used as `x`/`y`) are rejected,
not approximated.

## Backend conformance

A backend conforms if, for a valid spec, it emits a well-formed SVG whose root
carries the canvas/size, and for an invalid spec it reports an error rather than
emitting a partial document. There is no hidden state — a backend is a function
from these JSON documents to SVG, so it slots into a shell pipeline
(`front_pipeline.sh`) or a service wrapper identically. For `blender` the same
rule reads one step out: it either produces the frames and the GLB it promised,
or it reports the failure that stopped it — never a success with no files behind
it.

## The service surface

The contract is a function, and `serve` is the thinnest possible wrapper around
it: `python3 cli.py serve` runs the same operations over HTTP, which is how
chopshop-studio drives this repo as a runner. The service adds no semantics
— it reads the same documents, calls the same functions and returns the SVG they
produced — so a backend that satisfies the contract satisfies the service too.

| route | body | answer |
|---|---|---|
| `POST /generate` | a generate spec, or `{"op": "generate", "spec": {…}}` | the SVG |
| `POST /digest` | a digest spec, or its envelope | the SVG |
| `POST /query` | `{"runs": <record or list of records>, "spec": <chart spec>}` | the SVG |
| `POST /tree` | a tree spec, or its envelope | the SVG |
| `POST /log` | a log spec, or its envelope | the SVG |
| `POST /blender` | a blender spec, or its envelope | one view with no GLB export: the frame as `image/png`; otherwise (several views, or an export): `{"frames": [names], "glb": name or null}` |
| `GET /files/<name>` | — | one rendered file from the output directory (`image/png`, else `application/octet-stream`) |
| `GET /health` | — | JSON: `ok`, `service`, `auth_required`, `engine` |

The route, the operation and the engine's method are one name, so `GET /health`
`engine.operations` is the list of routes the service answers on: a client reads
the status page to learn what this backend can draw.

- **Success is one SVG document** (`image/svg+xml`); **every refusal is JSON**
  (`{"error", "kind"}`), so a caller branches on the content type instead of
  guessing at the body. An invalid spec is `400 invalid_spec` carrying the same
  message the CLI prints on exit `3`; a malformed body is `400 bad_request`; a
  missing or bad bearer token (only when `CHOPSHOP_PLOT_TOKEN` is set, and never
  on `/health`) is `401 unauthorised`; an unknown route is `404 not_found`; an
  oversized body is `413 too_large`.
- `POST /blender` keeps the rule with its own success types: `image/png` for one
  view with no GLB export, and the manifest JSON otherwise (several views, or
  an export), both `200`, and every refusal JSON. An exported GLB is a second
  artifact, so the single-frame `image/png` shape cannot carry its name — the
  answer is the manifest whenever `export.glb` is true. Its frames are fetched
  by name from `GET /files/<name>` — a plain basename matching
  `[A-Za-z0-9][A-Za-z0-9._-]*` that resolves inside the output directory
  (`CHOPSHOP_BLENDER_OUT_DIR`, default `blender_out/` inside the repo). A name
  that is not a basename, or resolves outside, is `404 not_found`, exactly like a
  file that is not there, and nothing outside that directory is ever read.
- **A missing renderer is `503 blender_unavailable`, never `404` and never a
  `500`.** `POST /blender` needs a Blender binary (`CHOPSHOP_BLENDER_BINARY`,
  default `blender`) on the box that answers; when it is not there, or the
  process failed, the answer says so and names it. That is a machine problem, not
  a spec problem, and the CLI reports the same failure as exit `4`.
- For `query`, `runs` is transport rather than spec: it may be a single run
  record or a list, and whatever remains beside it is the chart spec. No
  filesystem path is ever read from a request body.
- Bind, port and an optional bearer token come from the environment —
  `CHOPSHOP_PLOT_BIND`, `CHOPSHOP_PLOT_PORT`, `CHOPSHOP_PLOT_TOKEN` — defaulting
  to loopback and `8796`. `/health` is exempt from the token, because a health
  check that needs the secret cannot be used to decide whether to send it.
- The operations are injected, so the module imports with nothing
  installed and the service runs with no GPU and no network beyond its own
  socket: the reference implementation has no dependencies, and the service must
  not become the first one. `blender` is the one route that runs something
  installed, and it does so as a subprocess — nothing in the package imports
  `bpy` — which is why the module still imports and every other route still
  answers on a box with no Blender at all.
