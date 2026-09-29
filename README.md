# chopshop-bp — the blend-plot service: one service, two halves

**chopshop-bp (BP) is the blend-plot service.** The `plot` half **draws
documents** — `generate`, `digest`, `query`, `tree` and `log` each answer with an
SVG — and the `blender` half **renders geometry in 3D**. One JSON contract, one
service, two kinds of output; chopshop-svg and chopshop-studio call it for the
blend-plot work.

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
`<stem>_000.png`, … and a `<stem>.glb` when `export.glb` is true. The elements are
the same vocabulary `generate` reads, so a spec that draws as an SVG extrudes as a
solid; `extrude` sets the depth and bevel, and `render` the size, the number of
azimuth steps, the background and the engine (`workbench`, the default, or
`eevee`).

Blender is **not** a dependency of the package — nothing imports `bpy`, and a box
without Blender still runs every other operation. It is a binary this one
operation shells out to: `CHOPSHOP_BLENDER_BINARY` (default `blender`) and
`CHOPSHOP_BLENDER_OUT_DIR` (default `blender_out/` inside this repo, gitignored)
name it and where the frames land. With no binary the CLI exits `4` and the
service answers `503`. See `examples/blender_shapes.json` and `docs/contract.md`.

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
environment variables (`CHOPSHOP_PLOT_BIND`, `CHOPSHOP_PLOT_PORT`,
`CHOPSHOP_PLOT_TOKEN`); `/health` is exempt from the token. See `docs/contract.md`
for the surface in full.

`POST /blender` is the one route whose answer is not a document: one view is the
frame itself (`image/png`), several views are a manifest
`{"frames": [...], "glb": "…" | null}`, and the files are fetched from
`GET /files/<name>` — a plain basename inside `CHOPSHOP_BLENDER_OUT_DIR`, never
anything outside it. A box with no Blender answers `503 blender_unavailable` on
that route and keeps serving every other one.

## Demo gallery + fractals

`demo/make_geometry.py` renders a set of pure-SVG geometric pieces (phyllotaxis,
mandala, recursive tree, Koch snowflake, Lissajous, string-art cardioid).
`demo/make_fractals.py` renders fractals: Mandelbrot (overview + seahorse-valley
zoom), Julia, and Barnsley fern as PNG, plus a Sierpinski triangle as SVG.
`demo/make_animation.py` renders an animated time-series (a cumulative line
chart that grows frame by frame) and stitches it with Inkscape + ffmpeg into
`demo/animation.mp4` and `demo/animation.gif`.

Fractals are the **one optional dependency**: the raster ones (Mandelbrot, Julia,
fern) use `numpy`; `chopshop_plot.png` writes PNG with stdlib `zlib`/`struct`
(no Pillow). Sierpinski and everything else in the package stay stdlib-only. The
tests skip the numpy-backed cases when numpy is absent.

## Tests

```
python3 -m unittest discover -s tests -v
```

Stdlib only — no torch, no GPU, no absolute paths, no host identity. The serve
suite (`tests/test_server.py`) runs a real server on an ephemeral loopback port
with an injected engine, so it needs no models and no network.
