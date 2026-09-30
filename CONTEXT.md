# CONTEXT.md — chopshop-bp

Working state for agents and humans: what is in flight, what is blocked, and the
caveats that are not obvious from the code. Update this as work lands.

**Repo visibility: private.**

## What this repo is

The **blend-plot service** for the chopshop pipeline — an optional sidecar. The
`plot` half **draws documents** and the `blender` half **renders geometry in
3D**, behind one language-agnostic JSON contract (`docs/contract.md`). It draws
what it is handed: no scoring, no ranking, no telemetry, never a winner. Six
operations:

<!-- blend-plot: one service, two halves - `plot` draws documents, `blender` renders 3D. -->

1. **generate** — a JSON geometry spec → SVG. A programmatic *source* for the front
   half, alongside a raster or a prompt.
2. **digest** — a metrics spec → chart SVG. A post-hoc *reporter* on one run.
3. **query** — `.run.json` records + a chart spec → SVG. The *archive view*: cross-run
   scatter, a Pareto trade-off frontier, and a two-way diff.
4. **tree** — a hierarchy spec (nodes + edges) → a layered tree SVG. A *diagram*:
   kind-coloured boxes with a status dot and `key=value` metrics, `tb` (default) or
   `lr`. A node no root reaches is still drawn rather than dropped.
5. **log** — an event spec → a vertical event-timeline SVG. One row per event in the
   order given — the spec order IS the time order, nothing sorts by `t`.
6. **blender** — the same geometry spec → **rendered 3D**: PNG frames from a
   headless Blender render, plus an optional GLB. The one operation that is not a
   document, and the one that needs something installed (the `CHOPSHOP_BLENDER_*`
   binary/out-dir env vars); with no binary it exits `4` and the service answers
   `503`, while every other operation still runs.

The Python package is the reference implementation and is **stdlib-only** — it
writes SVG directly, because SVG is the pipeline's native vector format. A Julia
(Makie) or R (ggplot2) backend would read the same JSON spec and emit the same SVG;
they are named in the contract as richer backends, not required to run this package.

### What this repo is NOT

- **Not the metrics engine.** The metrics engine's configuration and the
  presentation of server statistics (the footer's check-engine light, the STATUS
  page, `GET /engine.json`) belong to **chopshop-studio**. The studio calls this
  service for the blend-plot work; it owns what the numbers mean and how they
  are shown.
- **Not where the ML is computed.** The learned ranker and the bucket bandit are
  computed by the **chopshop-svg** pipeline (`scripts/triage_ranker.py`). BP runs
  no model.
- **Not a telemetry surface.** It keeps no run history, no counters and no
  scores; it reads the `.run.json` records the archive hands it and draws them.
- **Not a judge.** `query`'s Pareto frontier marks what the data values leave
  non-dominated — a property of the records, not a verdict. `diff` shows what
  moved, never which side won.

Drawing a document **is** a blend-plot task, so drawing the studio's STATUS
hierarchy and event timeline is this service's job like any other `tree` or `log`
call: the page is the studio's, the drawing is BP's.

## Work in progress

- **The `blender` vocabulary has 3D primitives (chopshop-bp#1): `box`,
  `sphere`, `cylinder`, `cone`, `torus`.** Every other element is a 2D contour
  pushed along z, so its outline is fixed no matter where the camera stands — a
  sphere drawn that way is a bevelled disc from the side. A primitive is a MESH
  solid, so its silhouette changes with the view, which is what "a 3D model"
  means and was previously inexpressible. They take the same `z`/`depth` on the
  same symmetric terms a contour does (depth is the HALF z extent), the same
  `fill`, and a per-element `segments` (default 32; a torus also gets
  `tube_segments`, default 16) as the resolution rule. They are deliberately
  ABSENT from `spec._ELEMENT_FIELDS`, so `generate` refuses them by name — SVG is
  flat and a field it accepted and ignored would be a lie. The two kinds compose
  in one document and are framed together. Validated, refused on the SVG side,
  and measured against real Blender's `to_mesh()` bounds
  (`tests/test_blender_primitives.py`).
  **One implementation note worth keeping:** a primitive short-circuits the
  shared element check, which made it the only element in the vocabulary that
  silently accepted *any* field — `stroke` on a sphere was accepted, ignored,
  and drew no outline. `_check_primitive` now states its allowance as a closed
  set and names anything outside it. That check is the only thing standing
  between a caller and a field this operation reads but does not act on.
- No tracked in-flight feature. The six operations, the geometry demo gallery,
  the fractals, and the animated time-series demo (`demo/make_animation.py` →
  mp4/gif) have all landed.
- **The service (`cli.py serve`) landed alongside the studio's BP page.** The
  same operations over HTTP (`chopshop_plot/server.py`: `POST /generate`,
  `POST /digest`, `POST /query`, `POST /tree`, `POST /log`, `POST /blender`,
  `GET /files/<name>`, `GET /health`), which
  is how chopshop-studio drives this repo as a runner of kind **`bp`** — the one
  blend-plot runner, whose op selector covers all six operations. The studio's
  older `plot` and `blender` kinds still resolve to this same service
  (`Job::LEGACY_JOB_KINDS`: legacy-but-valid, no longer offered to a new job),
  and its `/plot` and `/blender` pages now redirect to `/bp`.
  `POST /blender` is the one route that does not answer with a document — one
  view is the frame (`image/png`), otherwise a manifest whose files come from
  `GET /files/<name>`, a plain basename inside `CHOPSHOP_BLENDER_OUT_DIR` — and a
  box with no Blender is `503 blender_unavailable` on that route alone.
  Documentation of the surface lives in `docs/contract.md`; the runner wiring and
  the page live in chopshop-studio.
- Named but not built: the Julia / R backends. They exist in the contract as
  intended implementers, not as pending work here.

## Blockers

- None known.

## Caveats / known issues

- **stdlib-only, with exactly ONE exception: `chopshop_plot/fractals.py` may import
  numpy** (Mandelbrot/Julia/fern rasterise on a complex grid; pure Python is far too
  slow). `chopshop_plot/png.py` writes PNG with stdlib `zlib`/`struct` — no Pillow —
  and Sierpinski stays stdlib SVG. The numpy-backed cases are guarded with
  `skipUnless(HAVE_NUMPY)` so the suite runs without it. Import no other third-party
  package anywhere.
- **The metrics schema is a flat, versioned DATA CONTRACT (`metrics_version: 1`),
  not a scoring engine.** It is the shape of the run records the studio and the
  pipeline hand to the chart operations; `chopshop_plot/metrics.py` only flattens
  and keys them — nothing here scores, ranks or judges. Field names stay boring
  (`node_count_max`, never `static.path_nodes_max`). Bump `METRICS_VERSION` when a
  field is renamed/added/removed — a reader refuses an unknown version. Never
  hardcode a chart's axis; the user picks the field.
- **Runs are keyed by `source_sha256` + `recipe_hash`**, so "recipe A vs recipe B on
  one source" and "one recipe across sources" are directly comparable. `recipe_hash()`
  hashes the sweep params (preset, filter_speckle, hierarchical, use_palette).
- **Missing data is a state, not a zero.** A skipped gate renders as absent (`None`),
  never `0`. `flatten_candidate` must emit `None` for absent fields; renderers must
  skip `None` rather than plot a lie.
- **Non-domination is computed on DATA values, not screen pixels.** Screen y is
  inverted, so running the Pareto test on pixels maximises y. The test that pins this
  checks *which* candidates are on the frontier (fill colour + position), not just
  counts.
- **The contract is the interface.** Any change to a chart type, a metric field or the
  schema MUST update `docs/contract.md` and the tests in the same commit.
- **Invalid specs raise `SpecError` / `QueryError`** (CLI exit `3`), never a partial
  document. Validation lives in `chopshop_plot/spec.py` and `chopshop_plot/query.py`.
  Exit codes: `0` success, `2` usage error, `3` invalid spec, `4` blender binary
  unavailable (the service answers `503` for that instead — a missing renderer is
  a machine problem, not a spec problem).
- **`chopshop_plot/config.py` is the service's only configuration, and it is all
  environment:** `CHOPSHOP_PLOT_BIND` (default loopback), `CHOPSHOP_PLOT_PORT`
  (default `8796`, clear of the studio's mock runner at 8790, chopshop-svg's
  runner at 8787 — its own `RUNNER_PORT` default in `chopshop-svg/runner.py`,
  pinned as `8787` in that repo's `docker-compose.yml`; this file used to say
  8791, which nothing sets — and chopshop-flux's service at 8795) and an
  optional `CHOPSHOP_PLOT_TOKEN`. Read at CALL time, never at import time, so a
  test can change the environment without reloading the module. The service
  binds loopback by default; reaching it from another machine is an explicit
  act. The blender half reads its own two (`CHOPSHOP_BLENDER_BINARY`,
  `CHOPSHOP_BLENDER_OUT_DIR`), and the one constant here that is not an
  environment knob is the request-body cap (`MAX_BODY_BYTES`, 8 MiB, answered as
  `413 too_large` before the body is read).
- **212 tests, stdlib only** (`python3 -m unittest discover -s tests`): no torch,
  no GPU, no network beyond a loopback socket. `tests/test_server.py` starts a
  real server on an ephemeral port with an injected engine (a stub for the
  plumbing, the reference implementation for the wiring) and asserts the CLI's
  `serve` command answers on the port it printed. Every emitted SVG must be
  well-formed XML and carry `width`/`height`/`viewBox` on the root. The diagram
  ops are pinned by measurement, not by counting elements: `tests/test_tree.py`
  asserts a child box is strictly below/right of its parent, `tests/test_log.py`
  asserts the rows are drawn in the order given (a log sorted by `t` would fail).
  The count is **measured, not remembered**: `python3 -m unittest discover -s
  tests` reports `Ran 212 tests … OK` (2026-09-29, Python 3.13.5). Re-measure
  rather than editing the number by arithmetic.
- **`demo/*.png` is gitignored** (regenerable via `demo/make_fractals.py`); the SVG
  demos are tracked. The animation demo needs Inkscape + ffmpeg — external tools for
  the demo script, not dependencies of the package.
- **Host-agnostic.** No absolute paths, no hostnames, no secrets in code or docs.

## Doc/code alignment pass (2026-09-29)

Every human-facing doc (`README.md`, `CONTEXT.md`, `docs/contract.md`,
`docs/agents/*.md`, `AGENTS.md`) was read against the source it describes
(`cli.py`, `chopshop_plot/*`, `blender/bpy_geometry.py`, `tests/*`, `examples/*`,
`demo/*`). Each claim was re-derived from the code, not from another doc.

Fixed:

- **The suite count was stale** (`202` → **212**, measured). The old number
  predated the blender-camera commit; the bullet now carries the command and the
  date.
- **`CONTEXT.md`'s config bullet named only three of the five knobs.** It now
  names the blender pair (`CHOPSHOP_BLENDER_BINARY`, `CHOPSHOP_BLENDER_OUT_DIR`)
  and the one non-environment constant, `MAX_BODY_BYTES` (8 MiB → `413`).
- **The port map was wrong: "chopshop-svg's runner at 8791".** That runner
  serves its own `RUNNER_PORT`, default **8787** (`chopshop-svg/runner.py`, and
  `RUNNER_PORT: "8787"` in that repo's `docker-compose.yml`); the studio's own
  runner doc and its deployed runner map agree on 8787, and nothing anywhere sets
  8791. Corrected here and in `chopshop_plot/config.py`'s comment — **the same
  stale 8791 survives in three sibling files this repo does not own**
  (`chopshop-flux/README.md`, `chopshop-flux/CONTEXT.md` and its env example
  header, `chopshop-studio/app/models/{plot,blender,flux}_conf.rb` hints). Those
  are cross-repo: name them to their owners rather than editing trees another
  session holds.
- **The studio's runner kind had moved on.** The service bullet said "a runner of
  kind `plot`"; the offered kind is now **`bp`** (one blend-plot target whose op
  selector covers all six operations). `plot` and `blender` remain valid for
  jobs already filed against them (`Job::LEGACY_JOB_KINDS`) but are no longer
  offered, and the studio's `/plot` and `/blender` pages redirect to `/bp`. The
  bullet now says so.
- **`README.md` named the wrong callers.** It said "chopshop-svg and
  chopshop-studio call it"; `chopshop-svg` holds no reference to `chopshop-bp`
  at all — the studio is the caller (it drives the service as a `bp` runner), and
  the pipeline's archive is what *writes* the `.run.json` records the chart
  operations read. Rewritten to say that.
- **`README.md`'s blender section predated the camera** (`render.elevation`,
  `azimuth`, `projection`, `lens`) and per-element `z`/`depth`, and did not state
  the output stem rule. All three documented now, including that `z`/`depth` are
  3D-only and that `generate` refuses them.
- **`README.md` called the string-art demo a "cardioid".** `demo/make_geometry.py`'s
  `string_art` draws chords between points at a multiplicative step
  (`i → 19i mod n`) — a circle-envelope star figure, not a cardioid. Renamed.
- **`docs/contract.md` "Common rules" was wrong in two places.** It implied every
  document carries `"op"` (the code accepts a bare spec too, and an explicit `op`
  must MATCH the operation it arrives at), and it said unknown fields are
  "ignored, never fatal" — true at document/`canvas`/`size`/node/event level,
  false on an element and inside `extrude`/`render`/`export`, where `spec.py` and
  `blender.py` refuse them. Both qualified to match the code.
- **`generate`'s required `canvas` was never stated.** `validate_generate`
  requires a positive `width`/`height` on `canvas` and accepts an empty
  `elements` (an empty canvas is a valid document), while `blender` refuses a
  spec with nothing to render. Stated, with the contrast.
- **Three smaller contract gaps:** the log's spine is drawn only when a document
  has more than one row; a title-less blender spec's stem is `render-<hash>`; and
  `diff` also reads `size.width` (its height follows the row count).
- **The service's `401 unauthorised` was undocumented.** `server.py` answers it
  when `CHOPSHOP_PLOT_TOKEN` is set (`tests/test_server.py` pins it), but the
  refusal list named only `400`/`401`-less `404`/`413`. Added, with `/health`'s
  exemption.
- **`docs/agents/domain.md` was the generic upstream scaffold** — it sent readers
  to a `CONTEXT-MAP.md`, a `docs/adr/` and `src/` trees this repo has never had.
  Rewritten repo-specific while keeping the generic guidance.
  `issue-tracker.md` and `triage-labels.md` were checked and are accurate as they
  stand.

Checked and left alone:

- **`AGENTS.md` is a protected agent-instruction file** and was read line by line
  anyway: it carries no test count and no port, and every claim in it (stdlib
  rule with the single numpy exception, the contract-as-interface rule, the
  missing-data-is-not-zero rule, the cross-repo doc pointers) matches the code,
  so nothing needs a human edit. A future session that finds a stale line there
  cannot fix it in place — the write guard refuses `AGENTS.md` (approval is one
  operation, every time) — so record the correction here instead.
- **`docs/agents/issue-tracker.md` cannot be exercised on this box:** it is
  written around the `gh` CLI, and `gh` is not installed here (`gh: command not
  found`). The doc's own claim (GitHub issues, `gh` as the tool) is consistent
  with the repo's remote, so it stands; the gap is the missing binary, not the
  doc.
- **`docs/agents/triage-labels.md` labels are unverifiable locally** for the same
  reason (no `gh`), and its five role names are the upstream defaults it says
  they are.

Cross-repo, not edited (name them to their owners):

- The stale 8791 port (above) in `chopshop-flux` and `chopshop-studio`.
- `dmpool` still calls this service `chopshop-plot` in `dmpool/README.md`
  (and points at `http://127.0.0.1:8796`, which is correct) — the name, not the
  port, is stale there.
- `docs/agents/*.md` in this repo are plain docs, not protected: only a
  basename of `AGENTS.md`/`CLAUDE.md`/`SOUL.md`/`.cursorrules` (or a
  project-local `.hermes/`) trips the guard.
