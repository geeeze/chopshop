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
| `rect` | `x`, `y`, `width`, `height`, optional `rx`, `fill`, `stroke`, `stroke_width`, `stroke_dasharray` |
| `circle` | `cx`, `cy`, `r`, optional `fill`, `stroke`, `stroke_width`, `stroke_dasharray` |
| `ellipse` | `cx`, `cy`, `rx`, `ry`, optional `fill`, `stroke`, `stroke_width`, `stroke_dasharray` |
| `polygon` | `points` (array of `[x, y]`), optional `fill`, `stroke`, `stroke_width`, `stroke_dasharray` |
| `polyline` | `points`, optional `stroke`, `stroke_width`, `marker` |
| `line` | `x1`, `y1`, `x2`, `y2`, optional `stroke`, `stroke_width`, `stroke_dasharray`, `marker` |
| `path` | `d` (SVG path data), optional `fill`, `stroke`, `stroke_width` |
| `text` | `x`, `y`, `content` (a string), optional `fill`, `font_size`, `anchor`, `font_family` |

`marker` is accepted only on the two **edges** (`line`, `polyline`) and refused on
every other type (an area or contour is not an edge, so a direction there is
meaningless). It draws an **arrowhead** making the connector directed — "the
operator posts a job", "the runner answers with candidates". One shared
`<marker>` is emitted in `<defs>` (auto-orienting, `orient="auto"`), referenced
by `marker-start` / `marker-end`; its colour follows the edge's `stroke` and its
size follows its `stroke_width`. A document with no `marker` has no `<defs>` and
renders byte-identically to before. Values:

| value | meaning |
|---|---|
| `"none"` (default when absent) | a plain, undirected line |
| `"start"` | arrowhead at the first point |
| `"end"` | arrowhead at the last point |
| `"both"` | arrowheads at both ends |

`stroke_dasharray` is accepted on the five stroked shapes above (`rect`,
`circle`, `ellipse`, `polygon`, `line`) and refused on `path` (its `d` can
carry a dash) and `polyline`. It draws a **dashed boundary** — how a diagram
says "this group is logical, not physical" (a security group, a trust boundary,
a region). The value is **either** a string of comma- or space-separated numbers
(`"8,4"`, `"8 4"`) **or** a list of numbers (`[8, 4]`); both render identically.
Every number must be **non-negative** — a dash of `0` (or a negative) is a solid
line, i.e. a typo, and is refused by name. A shape with no `stroke_dasharray`
omits the attribute entirely (never `stroke-dasharray=""`).

`text` places a label at (`x`, `y`), `y` being the baseline as SVG defines it.
`content` is **required and required to be a string** — a number where a label
belongs is refused, not coerced. `font_size` defaults to `12`; `anchor` is one of
`start` / `middle` / `end` (SVG default `start` when unset); `fill` and
`font_family` style the glyphs.

Every element type also takes an optional **`luminance`** (a number in `0..1`),
used only with the document `relief` block described in the `blender` section —
where it is a height. Here it is a tone: `generate` emits
`fill-opacity="<luminance>"`, so one traced document can be drawn as a flat
tonal image and as a solid relief from the same measurements. It is accepted on
the closed shapes (`rect`, `circle`, `ellipse`, `polygon`, `path`) and refused on
`line` and `polyline`, which have no fill to make transparent.

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

**The scale rounds OUT to the tick step, never across the data.** The axis
maximum is the smallest multiple of the step that is **at or above** the tallest
data value, and the axis minimum the largest multiple **at or below** the
lowest. Two rules follow, and both are defects rather than style when broken:

- the top gridline is at or above every value, so a bar never overflows the plot
  area — and an axis maximum never implies headroom the plot area does not
  have (a 97 rendered against an axis that reads 100 is fine; a 100 that is
  really 97 is not);
- every tick the backend draws sits on a gridline **inside** the plot area,
  never in the title/legend band above it.

Rounding the maximum down below the tallest value is a bug. The scatter chart's
x axis follows the same rule, since a tick past the right margin is drawn where
nothing clips it.

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
| `elements` | required, the `generate` vocabulary with the same validation (`fill`/`stroke`/`stroke_width` as there, unknown fields refused), plus the 3D-only `z` and `depth` (below) and the 3D-only relief measurements `luminance` / `layer` |
| `title` | optional string |
| `tiling` | optional, the same block as `generate` |
| `extrude` | optional `{ "depth": 0.5, "bevel_depth": 0.02, "bevel_resolution": 2 }` |
| `relief` | optional `{ "rule": "luminance", "z_min": 0, "z_max": 20, "invert": false, "step": 4, "thickness": 1.5 }` — `rule` is required when the block is present (below) |
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

**The background.** `background` is a CSS hex colour (`#1a1a24` is the default)
**or** the literal `"transparent"`, and nothing else. `"transparent"` writes an
**alpha frame** — RGBA out with the world omitted from the result, so the subject
keeps its own alpha and the corners are 0 — which is the form a compositor or a
game engine wants for a sprite or a prop. Both engines honour it. A value that
is neither (a CSS name, a typo) is **refused by name**, because the colour parser
substitutes the default silently: `"transparnet"` would otherwise render the
default background and report success.

**Per-element height and depth.** Any element may carry `z` (a number, default
`0`, may be negative) and `depth` (a number >= 0). `z` is the element's *plane*
height and `depth` overrides `extrude.depth` for that one element. Together they
are what makes a 3D chart expressible — every bar is a `rect` differing only in
`depth` — and what lets a spec stack layers rather than putting everything on one
plane. Both are **3D-only**: `generate` draws SVG, which is flat, so it refuses
them instead of accepting and ignoring them. The 3D primitives below take them on
the same terms, so a `sphere` at `z: 40` with `depth: 5` sits its mid-plane at
40 and spans 35..45 like any other solid.

**Relief — turning a 2D image into depth.** A document-level `relief` block turns
per-element measurements into heights, which is the missing half of
raster → trace → extrude. **The division of labour is part of the contract, not
an implementation detail: this service DRAWS and does not MEASURE.** So the height
rule is *data in the spec* and the per-element measurement is the *caller's*,
handed over as a number — a backend does not read the raster, and a caller
implementing this rule in another language needs only the arithmetic below.

| field | default | |
|---|---|---|
| `rule` | **required** | `"luminance"` or `"layers"` |
| `z_min` | `0` | height of the measurement's low end; may be negative |
| `z_max` | `20` | height of the measurement's high end; must be `>= z_min` |
| `invert` | `false` | reflect the range (the intaglio reading) |
| `step` | `4` | `layers` only: height gained per layer |
| `thickness` | `1.5` | half-extent along z, on the same terms as `depth` |

`rule` is required and has **no default**: `luminance` is a tonal reading of an
image and `layers` an ordinal one, so defaulting would be choosing a reading of
the caller's image on their behalf.

- **`luminance`** — every element carries `luminance`, a number in `0..1` the
  caller measured from the raster it traced (not a `0..255` channel; that is
  refused by name). Height is `z_min + luminance * (z_max - z_min)`, **linear**,
  with `0` landing on `z_min` and `1` on `z_max`. Brighter stands higher;
  `invert: true` gives the intaglio reading, where the light parts are the recess
  (reflected about `z_min + z_max`, so both ends stay where the caller put them).
- **`layers`** — every element carries `layer`, an integer `>= 0` that is the
  trace's own stacking order. Height is `z_min + layer * step`. **Not capped by
  `z_max`**: a ceiling would flatten the top layers into one plane and destroy the
  stacking; a caller wanting a ceiling sets `z_max` and a `step` that fits under
  it. A fractional layer is refused — rounding is a decision the caller did not
  make.

`thickness` is a **half-extent**, exactly as `depth` is: a relief slab of
`thickness: 1.5` is 3 units thick. An element's own `z` or `depth` always wins
over the rule, which is the documented way to place a plate or a backdrop in a
relief document — and is why a missing measurement is refused per element rather
than per document. The rule is resolved in the driver into ordinary `z`/`depth`
before the spec reaches Blender, so the builder contains no relief code and the
rule is implemented once.

**Because the rule transforms the document, the frame name is a hash of the
transformed one.** The builder can only see the resolved spec, so the names
`render_blender` returns are derived from that — a caller reading a file back by
the returned name gets the frame. For a document with no `relief` block the
resolution is a no-op, so the name is unchanged and existing caches still hit.

**The SVG-side equivalent: opacity.** `generate` honours the **tonal** rule and
only the tonal rule. A relief's visual point is that nearer things are lighter
and further things darker under a raking light, and in a flat drawing that
gradient is `fill-opacity` — so the same `luminance` becomes a height in 3D and a
tone in 2D, and one traced document can be drawn both ways. `generate` therefore
**accepts `luminance`** (unlike `z`/`depth`, which it refuses) and emits
`fill-opacity="<luminance>"`, with `invert` applied. It refuses:

- the `layers` rule, which has no 2D reading — layer order is already expressed
  by the order the elements appear in;
- the 3D parameters (`z_min`, `z_max`, `step`, `thickness`), by name;
- a `luminance` on a `line` or `polyline`, which has no fill to make
  transparent.

Solid or stroke, from the element's own shape:

- **Closed elements** — `rect`, `circle`, `ellipse`, `polygon`, and a `path`
  whose data closes the contour (`Z`) and which carries a `fill` — become a
  filled Blender curve: extruded by the element's own `depth` when it has one and
  `extrude.depth` otherwise, and bevelled by `extrude.bevel_depth`. `fill` is the
  solid's colour.
- **Open elements** — `line`, `polyline`, and a path that is not a filled, closed
  contour — become a stroke tube whose radius is `stroke_width` (default
  `0.02`). `stroke` is the tube's colour.
- **3D primitives** — `box`, `sphere`, `cylinder`, `cone`, `torus` — are built
  as MESH solids rather than extruded curves. Same names, same `z`/`depth`
  rules, same material cache, and framed together with the contours, so one
  document can mix them. See the primitive table below.
- `tiling` repeats the element across the grid exactly as `generate` draws it,
  and the tiled copies are built first.

**The 3D primitives.** Five element types exist in this operation and nowhere
else: `box`, `sphere`, `cylinder`, `cone` and `torus`. Every other element is a
2D *contour* pushed along z, so its outline is the same no matter where the
camera stands — a sphere drawn that way is a bevelled disc from the side. A
primitive is a mesh solid, so its silhouette genuinely changes with the view.
That is the whole of the difference, and it is why these types are not in the
shared vocabulary: **`generate` refuses them by name**, because SVG is flat and a
solid whose outline depends on the camera has no SVG reading.

Each takes a transform and the same `fill` the rest of the vocabulary uses, plus
`z` and `depth` **on the same symmetric terms as a contour** — `depth` is the
half extent along z, so a primitive at `z` spans `z - depth .. z + depth`.
Consistent rather than a second convention, because the measurement that makes a
composed solid sit correctly has to be the same measurement everywhere.

| type | fields | anchored | notes |
|---|---|---|---|
| `box` | `x`, `y`, `width`, `height`, `depth`, `z`, `fill` | at its `(x, y)` **corner** | a `rect` that has stopped pretending: the third extent is real, not an extrusion of a silhouette |
| `sphere` | `cx`, `cy`, `r`, `depth`, `z`, `fill`, `segments` | centred on `(cx, cy)` | an explicit `depth` different from `r` squashes it into an ellipsoid, which is the honest reading of "this solid is `depth` tall" |
| `cylinder` | `cx`, `cy`, `r`, `depth`, `z`, `fill`, `segments` | centred | |
| `cone` | `cx`, `cy`, `r`, `depth`, `z`, `fill`, `segments` | centred | a true cone, not a frustum: `radius2` is 0 |
| `torus` | `cx`, `cy`, `r`, `tube`, `depth`, `z`, `fill`, `segments`, `tube_segments` | centred | two radii: `r` is to the middle of the tube, `tube` is the tube's own radius, and the outer radius is `r + tube` |

- **Resolution: `segments` (and `tube_segments`) is the resolution rule** — how
  many straight pieces approximate the curve. It is **per element**, so one
  document can carry a smooth hero sphere and cheap background geometry, and it
  is an **integer >= 3** (fewer than three straight pieces is not a curve). The
  defaults are `segments: 32` and `tube_segments: 16`, stated once in
  `chopshop_bp/blender.py` so the validation, the builder and this table
  cannot drift.
- **A radius or extent must be > 0.** A zero-radius sphere is not a smaller
  sphere, it is a degenerate mesh that renders as nothing — so it is refused by
  name rather than discovered as a blank frame.
- **`depth` may be 0** even though radii may not: a flat primitive is a
  legitimate coin or tile. Absent, it means `extrude.depth`, exactly as a
  contour's does.
- **No `stroke`.** A mesh has no outline to tint, so `fill` is the only colour a
  primitive takes and any other field is a **named error**, not a silent
  no-op — including `z`/`depth` typos. A primitive short-circuits the shared
  element check (these types do not exist in the flat vocabulary, so there is no
  shared rule to defer to), which makes the closed field set the *only* thing
  standing between a caller and a field that is accepted and ignored.
- The two kinds **compose in one document** — same names, same `z`/`depth`
  rules, same material cache, framed together — so a spec can mix a plate and the
  solids standing on it.

`extrude.depth` is the curve's own extrusion, which a renderer applies
symmetrically about the sketch plane, so the solid is `2 * depth` thick. That is
MEASURED (`depth: 1` spans z - 1 to z + 1 on Blender 4.3), and it is why `z`
places an element's mid-plane rather than its base: a solid of depth `d` at
height `z` occupies `z - d .. z + d`, so an element meant to stand ON something
is placed clear of it by its own depth. An element's own `depth` overrides
`extrude.depth` for that element. Spec x
stays x and spec y is mirrored (SVG's y grows downward, 3D's grows up), so a spec
seen from above reads like the SVG the same document draws; the extrusion runs
both ways along z about that plane. A colour that is not `#rgb`/`#rrggbb` — a CSS name, `none` — renders
neutral rather than failing the render.

**The half-thickness is measured, and enforced.** The z span above is not a
convention this repository chose; it is what Blender's curve `extrude` does, read
back from the generated mesh's z bounds. `tests/test_blender.py` asserts it
against real Blender (`RealGeometryMeasurementTest`, skipped when the binary is
absent), because a comment is a memory and this codebase's memory was once wrong
in exactly this way — the code claimed the extrusion ran along `+z`. The same
script takes an optional third argument, `probe`, which builds the geometry,
prints each object's `to_mesh()` bounds as JSON and renders nothing; that is the
measurement channel those tests read.

**Curve resolution.** `render.curve_resolution` is a block of four integers —
`circle` (straight segments around a circle or ellipse), `corner` (steps per
rounded corner), `bezier` (samples per C/Q/S/T curve segment) and `spline`
(Blender's own `resolution_u` on the curve data). Each is `>= 3` and `<= 4096`.

The **defaults are the values this operation has always used** — `circle: 64`,
`corner: 8`, `bezier: 16`, `spline: 12` — and a spec that says nothing renders
**byte for byte** as it did before the field existed. That is enforced, not
intended: `tests/test_blender_fidelity.py` renders a spec containing a circle, a
rounded rect and a bézier path twice, once with no `curve_resolution` and once
naming the defaults, and compares the frames as bytes. Every existing frame,
hash and diff stays valid.

Resolution is a `render` property rather than a per-element one because one
document has one camera and one frame size. The 3D primitives keep their own
per-element `segments`, where a smooth hero solid and cheap background geometry
genuinely coexist in a single frame.

**Material.** A `material` block on any element — contour or primitive — takes
`roughness`, `metallic`, `specular` (all `0..1`), `emission` (a `#rgb`/`#rrggbb`
**colour**, because "emits cyan" is a different statement from "emits") and
`alpha` (`0..1`). `render.shading` sets `roughness`, `metallic` and `specular`
for the whole document; an element's `material` overrides them **key by key**, so
a house style is declared once and one object overrides only what it must.

- A value outside `0..1` is **refused**, not clamped. Blender clamps outside the
  shader's range silently, so the render would stop matching the spec with
  nothing reporting it.
- A key inside the block that the operation does not know is **refused by name**.
  The block is read key by key, so `roughnes` is a roughness nobody applied and a
  ball that renders matte when the spec asked for glossy.
- `emission` has no default. A material with no emission does not emit, which is
  not the same claim as `emission: black` — the latter would make
  `"emission" in material` true of every material and turn the question into a
  constant.
- `material` is **3D-only**, like `z` and `depth`: `generate` draws SVG, which
  has no materials, so it refuses the field rather than accept a block it cannot
  act on.
- The default surface is **matte and non-metallic** (`roughness: 1.0`,
  `metallic: 0.0`), deliberately not Principled's own `0.5`. The flat poster work
  this repo draws has always rendered matte, and a shiny default would change
  every existing render the first time anybody set `engine: eevee`.

**The engine split, stated rather than discovered.**

| | Workbench (default) | EEVEE |
|---|---|---|
| base colour / `fill` | yes | yes |
| `roughness`, `metallic`, `specular` | **ignored** | honoured |
| `emission` | **ignored** | honoured |
| `alpha` | **ignored** — renders opaque | honoured |
| speed | fast, no lighting | lights the scene with a fixed sun |

Workbench reads `material.diffuse_color` and nothing else, so under it a `material`
block is inert. That is a documented limit, not a failure, and it is why the
default engine is Workbench for flat work and why a spec wanting highlights says
`engine: "eevee"`. Both halves of this claim are tested: that Workbench renders
two different roughness values identically, and that EEVEE does not — so the
first test cannot pass by the field being dead everywhere.

`alpha` needs a real transparency story rather than a material that is opaque to
Workbench: the material's blend mode is set, the scene's EEVEE surface render
method is set, and `diffuse_color`'s alpha carries the same number, so the two
engines cannot disagree about what was asked for.

Camera and frames:

- Framed to the geometry's bounds — the generated surface, so the bevel and the
  extrusion are inside the frame. The camera is orthographic by default with
  elevation 25° and the azimuth stepping `0..360` across `views`; `render`
  overrides all of it (`elevation`, `azimuth`, `projection`, `lens`). Same spec,
  same frames: rendering one document twice writes the same bytes (no timestamp
  metadata is stamped into the frame).
- Frames are `<stem>_000.png`, `<stem>_001.png`, … (`views` of them) and
  `<stem>.glb` when `export.glb` is true. The stem is a slug of `title` plus a
  short hash of the spec (`render-<hash>` when the spec has no title), so a rerun
  overwrites its own files and two different specs never collide in one output
  directory.

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
  missing or bad bearer token (only when `CHOPSHOP_BP_TOKEN` is set, and never
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
  `CHOPSHOP_BP_BIND`, `CHOPSHOP_BP_PORT`, `CHOPSHOP_BP_TOKEN` — defaulting
  to loopback and `8796`. `/health` is exempt from the token, because a health
  check that needs the secret cannot be used to decide whether to send it.
- The operations are injected, so the module imports with nothing
  installed and the service runs with no GPU and no network beyond its own
  socket: the reference implementation has no dependencies, and the service must
  not become the first one. `blender` is the one route that runs something
  installed, and it does so as a subprocess — nothing in the package imports
  `bpy` — which is why the module still imports and every other route still
  answers on a box with no Blender at all.
