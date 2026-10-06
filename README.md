# chopshop-bp — the blend-plot service: one service, two halves

**chopshop-bp (BP) is the blend-plot service.** The `plot` half **draws
documents** — `generate`, `digest`, `query`, `tree` and `log` each answer with an
SVG — and the `blender` half **renders geometry in 3D**. One JSON contract, one
service, two kinds of output; **chopshop-studio** drives it over HTTP as a
runner of kind `bp`, and the run records its chart operations draw are the ones
the **chopshop-svg** pipeline's archive writes.

An **optional sidecar** for the chopshop pipeline. The pipeline emits
measurements and computes the ML; this service turns what it is handed into
something you can *look at* — a chart, a tree, a timeline, a 3D render — without
ever choosing, in keeping with the never-picks-a-winner rule.

The name **chopshop-bp** shortens **blend-plot**, because BP hosts both halves of
one service: the `plot` half draws documents and the `blender` half renders 3D
from the same geometry spec. The short form **BP** is used from here on.

Six operations, one language-agnostic JSON contract (`docs/contract.md`):

<!-- blend-plot: one service, two halves - `plot` draws documents, `blender` renders 3D. -->

1. **generate** — a JSON geometry spec → SVG (shapes, tiling, patterns). A
   programmatic *source* for the front half, the same way a raster or a prompt is.
2. **digest** — a metrics spec → chart SVG (bar / scatter / line). A post-hoc
   *reporter* on a single run's numbers.
3. **query** — a set of run records + a chart spec → SVG. The *archive view*:
   cross-run scatter, a Pareto trade-off frontier, and a two-way diff. Built on a
   flat, versioned metrics schema so axes are the user's choice and no chart
   hardcodes a field.
4. **tree** — a hierarchy spec (nodes + edges) → a layered tree SVG. A
   *diagram*: kind-coloured boxes, status dots, metrics as `key=value` lines,
   laid out `tb` (default) or `lr`. No node is ever dropped for being
   unreachable.
5. **log** — an event spec → a vertical event-timeline SVG. One row per event in
   the order given (the spec order **is** the time order), each with a
   kind-coloured marker on the spine, its timestamp, label and `#rank`.
6. **blender** — the same geometry spec → **rendered 3D**: PNG frames from a
   headless Blender render, plus an optional GLB. Closed elements become filled,
   extruded, bevelled solids and open ones stroke tubes; the camera is
   orthographic and framed to the bounds. The one operation that is not a
   document, and the one that needs something installed.

The Python package is the reference implementation and is **stdlib-only** — it
writes SVG directly, because SVG is the pipeline's native vector format. A Julia
(Makie) or R (ggplot2) backend would read the same JSON spec and emit the same
SVG; see the contract for how backends slot in.

## What BP is not

BP draws what it is handed. It applies no scoring, keeps no telemetry and never
picks a winner; the work it does *not* own is named here, with its owner:

- **Not the metrics engine.** The metrics engine's configuration and the
  presentation of server statistics — the footer's check-engine light, the STATUS
  page, `GET /engine.json` — are **chopshop-studio**'s. The studio owns what the
  numbers mean and how they are shown; BP is the service the studio calls for the
  blend-plot work.
- **Not where the ML is computed.** Ranking, scoring and the learned models — the
  learned ranker and the bucket bandit — are computed by the **chopshop-svg**
  pipeline (`scripts/triage_ranker.py`). BP runs no model and holds no state.
- **Not a telemetry surface.** BP keeps no run history, no counters and no
  scores. It reads the run records (the archive spine, `.run.json`) that the
  pipeline's archive hands it and draws them.
- **Not a judge.** A Pareto frontier marks which candidates the data values leave
  non-dominated; that is a property of the records, not a verdict from BP. `diff`
  shows what moved, never which side won.

Drawing a document **is** a blend-plot task, so BP drawing the studio's STATUS
hierarchy and event timeline is BP's job exactly like any other `tree` or `log`
call: the page is the studio's, the drawing is BP's.

## The metrics schema

Charts are drawn from a shared flat, versioned **data contract**
(`metrics_version: 1`) with boring field names — `node_count_max`, not
`static.path_nodes_max`. It is the shape of the run records **chopshop-studio**
and the **chopshop-svg** pipeline hand to the chart operations, and **not a
scoring engine**: BP only reads it — nothing in this repo derives or judges a
value. Runs are indexed by **source hash + recipe hash** so "recipe A vs recipe B
on one source" and "one recipe across sources" are directly comparable. **Missing
data renders as absent, never as zero** — a skipped gate is not a `0`. See
`docs/contract.md` for the field list.

## Why stdlib-only

SVG is text. Shapes map one-to-one onto `<rect>`, `<circle>`, `<polygon>`,
`<path>` and a chart is a handful of rectangles, lines and text. Round-tripping
through a plotting library adds a dependency (and its own SVG wrapper) for no
gain at this stage. `matplotlib`+`shapely` (Python), `Makie` (Julia) and
`ggplot2` (R) are richer backends that can implement the same contract later —
they are named in the contract, not required to run this package.

## Usage

```
python3 cli.py generate spec.json out.svg          # geometry -> SVG
python3 cli.py digest   metrics.json out.svg       # metrics  -> chart SVG
python3 cli.py query    runs/ chart.json out.svg   # run records + spec -> SVG
python3 cli.py tree     hierarchy.json out.svg     # nodes + edges -> tree SVG
python3 cli.py log      events.json out.svg        # events   -> timeline SVG
python3 cli.py blender  spec.json blender_out/     # geometry -> rendered 3D
python3 cli.py generate - < spec.json > out.svg    # stdio
```

`query` takes a directory of `.run.json` records (the archive spine) and a chart
spec. See `examples/` for run records and specs.

Exit codes: `0` success, `2` usage error, `3` invalid spec, `4` blender
unavailable.

### The blender operation

`python3 cli.py blender spec.json blender_out/` renders a geometry spec with a
headless Blender and prints the file names it wrote, one per line. Its `out` is a
**directory**, not a file — the operation produces `views` PNG frames named
`<stem>_000.png`, … and a `<stem>.glb` when `export.glb` is true (the stem is a
slug of `title` plus a short hash of the spec — `render-<hash>` when there is no
title — so a rerun overwrites its own files and two specs never collide). The
elements are the same vocabulary `generate` reads, so a spec that draws as an SVG
extrudes as a solid; `extrude` sets the depth and bevel, and `render` the size,
the number of azimuth steps, the background and the engine (`workbench`, the
default, or `eevee`). `background` takes a hex colour **or** `"transparent"`,
which writes an RGBA frame with the world omitted — the sprite/prop form a game
engine composites over its own art, honoured by both engines (measured in
`tests/test_blender_transparent.py`, which decodes the PNG and reads the corner
alpha rather than trusting the setup). A value that is neither hex nor that
sentinel is refused by name: the colour parser falls back to the default
*silently*, so a typo would otherwise render the default background and report
success.

The spec also **aims the camera** and can lift an element off the sketch plane:
`render.elevation` (degrees above the horizon — `90` is the plan view a chart, a
floor plan or a blueprint is actually read in) and `render.azimuth` (where the
sweep *starts*; `views` still steps evenly round from there), `render.projection`
(`ortho`, the default, or `perspective`) with `render.lens` in millimetres, plus
`z` (an element's plane height, may be negative) and `depth` (an element's own
extrusion, overriding `extrude.depth`) on any element — which is what makes a 3D
chart expressible, since every bar is then a `rect` differing only in `depth`.
Both `z` and `depth` are **3D-only**: `generate` draws flat SVG and refuses them
rather than accepting a field it would silently ignore. `docs/contract.md` has the
field list and the defaults.

**Five element types exist in `blender` and nowhere else: `box`, `sphere`,
`cylinder`, `cone`, `torus`.** Every other element is a 2D *contour* pushed
along z, so its outline is fixed wherever the camera stands — a sphere drawn
that way is a bevelled disc from the side. A primitive is a mesh solid, so its
silhouette changes with the view, which is what "a 3D model" means and was
previously inexpressible. They take the same `z`/`depth` on the same symmetric
terms a contour does (depth is the half extent along z), the same `fill`, and a
per-element `segments` as the resolution rule. `generate` refuses them by name —
SVG is flat. The two kinds mix in one document, so a spec can put solids on a
plate. See `examples/primitives-gallery.json` and the primitive table in
`docs/contract.md`.

Blender is **not** a dependency of the package — nothing imports `bpy`, and a box
without Blender still runs every other operation. It is a binary this one
operation shells out to: `CHOPSHOP_BLENDER_BINARY` (default `blender`) and
`CHOPSHOP_BLENDER_OUT_DIR` (default `blender_out/` inside this repo, gitignored)
name it and where the frames land. With no binary the CLI exits `4` and the
service answers `503`. See `examples/blender_shapes.json` and `docs/contract.md`.

**Two knobs for how good a render looks.** `render.curve_resolution`
(`circle`, `corner`, `bezier`, `spline`) sets the geometry sampling — the
defaults are the values this operation has always used, so a spec that says
nothing renders **byte for byte** as before and every existing frame and hash
stays valid. A per-element `material` block takes `roughness`, `metallic`,
`specular` (all `0..1`), `emission` (a colour, not a number) and `alpha`, with
`render.shading` setting the three numbers document-wide and the element
overriding key by key.

**Workbench ignores all of the material block** — it reads `diffuse_color` and
nothing else — and **EEVEE honours it**. That is a documented table in
`docs/contract.md`, not something to discover by comparing two renders. The
default surface is matte and non-metallic, so flat work looks the same on both
engines; a spec that wants highlights says `engine: "eevee"`.

**Relief: a 2D image turned into depth.** A document-level `relief` block gives
each traced contour its own height, which is the missing half of
raster → trace → extrude:

```json
"relief": { "rule": "luminance", "z_min": 0, "z_max": 24, "thickness": 0.8 },
"elements": [
  { "type": "ellipse", "cx": 100, "cy": 108, "rx": 52, "ry": 66,
    "fill": "#d8b090", "luminance": 0.62 },
  { "type": "polygon", "points": [[100,104],[108,128],[92,128]],
    "fill": "#fff0dc", "luminance": 0.97 }
]
```

**The rule is data and the measurement is the caller's, and that split is the
design.** This service draws documents; it does not measure them. So the spec
names the rule and its parameters, and the caller — the pipeline that traced the
image — hands over one `luminance` per contour, measured from the raster. Two
rules ship, because they disagree about what height means: `luminance` (brighter
stands higher, linear across `z_min`..`z_max`, `invert` for the intaglio reading)
and `layers` (a layered cut-paper look, from the trace's own `layer` ordering).
`generate` honours the tonal one too, reading the same `luminance` as
`fill-opacity`, so one traced document can be drawn flat or solid.
See `examples/relief-portrait.json` and the relief section of
`docs/contract.md`.

## The service (`serve`)

The same operations over HTTP, so chopshop-studio can drive this as a runner:

```
python3 cli.py serve                            # loopback, port 8796
python3 cli.py serve --bind 0.0.0.0 --port 9000 # explicit, for a split deployment
```

`POST /generate`, `POST /digest`, `POST /query`, `POST /tree`, `POST /log` and
`POST /blender` take the contract's JSON and answer with the SVG
(`image/svg+xml`); `GET /health` answers with JSON, and its `engine.operations`
is the list of routes this backend answers on. Every refusal is JSON — an invalid
spec is a `400` carrying the CLI's own message, an unknown route a `404` — so a
caller branches on the content type. `query` takes `{"runs": <record or list of
records>, "spec": <chart spec>}`. Bind, port and an optional bearer token are
environment variables (`CHOPSHOP_BP_BIND`, `CHOPSHOP_BP_PORT`,
`CHOPSHOP_BP_TOKEN`); `/health` is exempt from the token. See `docs/contract.md`
for the surface in full.

`POST /blender` is the one route whose answer is not a document: one view is the
frame itself (`image/png`), several views are a manifest
`{"frames": [...], "glb": "…" | null}`, and the files are fetched from
`GET /files/<name>` — a plain basename inside `CHOPSHOP_BLENDER_OUT_DIR`, never
anything outside it. A box with no Blender answers `503 blender_unavailable` on
that route and keeps serving every other one.

## Demo gallery + fractals

`demo/make_geometry.py` renders a set of pure-SVG geometric pieces (phyllotaxis,
mandala, recursive tree, Koch snowflake, Lissajous, string-art circle envelope).
`demo/make_fractals.py` renders fractals: Mandelbrot (overview + seahorse-valley
zoom), Julia, and Barnsley fern as PNG, plus a Sierpinski triangle as SVG.
`demo/make_animation.py` renders an animated time-series (a cumulative line
chart that grows frame by frame) and stitches it with Inkscape + ffmpeg into
`demo/animation.mp4` and `demo/animation.gif`.

Fractals are the **one optional dependency**: the raster ones (Mandelbrot, Julia,
fern) use `numpy`; `chopshop_bp.png` writes PNG with stdlib `zlib`/`struct`
(no Pillow). Sierpinski and everything else in the package stay stdlib-only. The
tests skip the numpy-backed cases when numpy is absent.

## Tests

```
python3 -m unittest discover -s tests -v
```

Stdlib only — no torch, no GPU, no absolute paths, no host identity. The serve
suite (`tests/test_server.py`) runs a real server on an ephemeral loopback port
with an injected engine, so it needs no models and no network.
