# Compose → trace: the raster-only invariant

Read before touching the composite flatten, the compose operation, or any
"chain compose into a trace" endpoint. The trace stage reads a RASTER. A
composed SVG is the *compose deliverable*, never a trace source. Violating
this ships an endpoint that fails at the job-create door.

## The invariant

The trace pipeline (`prep_raster.py`) opens the job's `input_path` with
**PIL**, which cannot read an SVG. So a TRACE job's `input_path` must be a
`.png`/`.jpg`.

- `Job::RASTER_INPUT_EXTENSIONS = %w[.png .jpg .jpeg]` (`job.rb`).
- `JobsController#create` gates every real job at `trace_source_refused?`
  — refuses a trace job whose `input_path` is not a raster, with the
  message *"The trace stage preps a raster and cannot open an SVG"*
  (`Job.trace_source_refusal`). The FILE extension is the truth;
  `source_kind` is decorative metadata and is ignored by the gate.
- The vector flatten (`flatten_vector`) stores an **SVG**
  (`store_svg` writes `composite_*.svg`, scrapbook item kind `"svg"`). That
  SVG is the compose deliverable — it must NOT be filed as a trace job's
  `input_path`.

## Why the sequenced-job escape does NOT rescue it

`trace_source_refused?` returns false for `job.sequenced?` (a step list).
Do not conclude "a sequenced job can trace an SVG":

- The studio's **per-step** validation refuses a trace step whose
  predecessor produced an SVG: *"step N: a SVG step traces a RASTER, and
  step N-1 produces .svg. Add a step that renders the drawing to PNG first
  (bp's blender operation does)."*
- `RunJob#run_pipeline_step` posts the `input_path` to the runner's
  `/jobs`, where `prep_raster.py` (PIL) fails on an SVG anyway.

`STEP_FILE_RULES["svg"]` (the trace step) `accepts: %w[.png .jpg .jpeg]`
only. A compose step *produces* an SVG, so a trace step after it is refused
at both the studio and the runner. The sequenced concept is for chains where
a **raster-producing** step (e.g. flux) precedes the trace step.

## The two correct designs

**A — vector-preserving (no new deps):** compose + store the SVG + record
the compose job (`record_compose_job`), return the stored artefact
(`201 {composite_id, scrapbook_id, path, mode: "vector",
content_type: "image/svg+xml"}`). Do NOT file a trace job against the SVG.
Reuse `ComposeSpec.build → ComposeClient.compose → store_svg` and
`flatten_vector`'s private logic. This is the one-call collapse that
respects the invariant.

**B — true compose→trace:** requires a **server-side SVG→PNG rasteriser**
(inkscape / a headless rasteriser) — the studio has none today (no
inkscape/rmagick/mini_magick anywhere; the only pixel path is the
browser-posted raster in `flatten`). Rasterise once, then file the trace
job with `input_path` = the PNG, `source_kind` = raster. Cost: the
composed vectors are rasterised before the trace — the fidelity loss the
vector path exists to avoid.

## Failure semantics (when building a chain endpoint)

- Step 1 (compose) failure → `422 {error}`, no job. The SVG is only
  written inside `store_svg` *after* a successful compose, so a compose
  failure cannot leave a half-written artefact.
- `ComposeSpec::Error` → `422`; `ComposeClient::ComposeError` → `502`.
- Gate on `composite.vector?` (any vector layer present) — `all_vector?`
  is false for an EMPTY composite, so use `vector?`, not `all_vector?`.
- Owner scoping is automatic via the `Owned` concern, but the action must
  sit under `before_action :require_login` or `Current.user_handle` is
  blank and no scoping applies.
- `project_id` must come from `composite.project_id` — a project-less job
  is listed NOWHERE under the Projects workspace.

## Pitfall: docs that teach the broken sequence

The chained-recipe doc once told agents to file `POST /jobs` with
`job[input_path]` = the vector flatten's stored SVG, with a bash example
walking through it. That is the exact sequence the create door refuses.
When documenting compose→trace, the trace step's source is a **raster**:
flatten the composite as *pixels* (`mode: "raster"`, a PNG) or render to
PNG (a bp `blender` step) first. Verify any doc that says an SVG "becomes
the job's `input_path`" against `trace_source_refused?` before trusting it.
