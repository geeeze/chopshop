# Composites, and the test cleanups that eat the live uploads

Two subjects that each cost a session's worth of wrong turns.

## A test cleanup must never glob the LIVE uploads directory

`storage/uploads` is REAL and shared: a live job's raster, a flux raster, and a
bp job's drawing (the blend-plot service publishes `plot_<hex>.svg` there) all
live in it. A test that cleans up by PREFIX deletes the OPERATOR's files, and the
only symptom is a thumbnail that 404s on a live page later — nothing red, nothing
logged, no artifact to inspect. It happened FIVE times in one session, in two
sweeps.

- The rule: snapshot at setup and delete only what THIS test added AND what
  matches the prefix it owns — `UploadsSandboxHelper` in `test/test_helper.rb`
  (`snapshot_uploads`, `cleanup_test_uploads(/\Aflux_/)`). `run_bp_test` and
  `run_steps_test` are the in-repo model.
- **When you find one, grep the WHOLE class before moving on.** Fixing the three
  found by looking for `Dir[...].each { File.delete }` was not the same as closing
  it — a second sweep caught `plot_*.svg`, which had been wiping every bp drawing
  on every suite run.
- Verify with a COLLIDING sentinel: plant `plot_sentinel_<hex>.svg` (the prefix the
  cleanup targets, a name it does not own) and require it to survive a full run of
  the affected files. A sentinel on an unrelated prefix proves nothing.
- The damage is REPAIRABLE, and RE-RUNNING THE JOB IS THE WRONG FIX — it duplicates
  the history. A bp job records its document under `spec.bp.doc` and the filename
  it drew to under `spec.bp.rendered.file`, so re-post the document and write the
  answer back under the recorded name. Wire shape, measured against the live
  service: `{op, spec, runs?}` — the op picks the URL PATH, the document goes under
  `spec`, and a query's records are a top-level SIBLING `runs` (nested inside
  `spec` the service refuses it with "query needs a 'runs' field").
- The detector that works is behavioural, not a grep: re-check the LIVE thumbnails
  after a suite run and before reporting. Two of the five were found that way, only
  because the row's preview was read a second time.

## Driving the Composite path as an agent

A composite is CREATED then FLATTENED. Four things about that pair are not
readable from the views, and each cost a debugging round:

- The show route has **no `:id` segment** (`get "composite"`), so the id rides in
  the QUERY STRING. `composite_path(@composite)` renders `/composite.5` — the id
  swallowed as a format suffix, which is not the composite page. Use
  `composite_path(id: c.id)`, and compare redirects with `request_uri` rather than
  `path` (`path` drops the query string, so a correct redirect reads as wrong).
- **A composite opened from a project's Compose button must be filed against that
  project — thread the FK onto the UNSAVED record, or the form drops it.** The
  builder's hidden `project_id` field reads `composite.project_id`, so the `show`
  action must set `project_id: params[:project_id].presence` on the `Composite.new`
  it builds for the new page. The `create` action already accepts `project_id`;
  the gap is the new-page path — without it the hidden field posts nil and the
  composite is orphaned from the project it was composed in. General rule: any
  builder/new page that pre-scopes a record (project, owner, parent) must set the
  scoping FK on the unsaved record, or the form's hidden field silently drops it.
- A layer's `src` is a URL or a storage path, NEVER raw SVG text:
  `ComposeSpec.read` accepts a data URI, `/scrapbook/<id>/file`,
  `/jobs/upload_preview/<name>`, a path under `storage/`, or an http(s) URL. Raw
  text is what the RECIPE carries on the wire, not what a stored layer holds — to
  compose a generated frame, write it to `storage/uploads` and reference it.
- A file lives on the runner that PRODUCED the job, so every layer URL must come
  from the job's OWN runner: a mock job's candidates are on the mock runner
  (`Job::RUNNER_DEFAULTS` — there is no `CHOPSHOP_RUNNER_MOCK_URL` line in the env
  file) and a real trace's on the pipeline runner. Building every URL against one
  base 404s with "the runner could not serve the layer's source".
- `compose_base_url` must SKIP the mock: `mock` is an svg-KIND runner whose URL
  sorts first, so `labels.first` composes against the runner whose whole job is to
  fake the pipeline — which has no `/compose`. This is the same rule
  `Job.handoff_runner` applies; a new `_base_url` reader is a place to re-make the
  mistake.
- A runner client's SVG check must match the ROOT ELEMENT, not the first four
  bytes: `body.start_with?("<svg")` rejects `<?xml version='1.0' ...?>` followed by
  the root, which is what the compose operation emits — so a 200 carrying the right
  bytes read as "expected an SVG document". Allow an optional BOM, whitespace, and
  an XML declaration first. There were TWO copies of this guard (`ComposeClient`
  and `PlotClient`); grep for the message, not the method.
- **The blend-plot element set has no text element**, so a sheet that needs titles
  cannot be one bp document. bp draws the graphs, hierarchies and blender renders;
  the chrome (frames, labels, connectors) is SVG generated beside them and composed
  in as a vector layer. Prove the vectors survived by counting elements in the
  COMPOSED file: a trace that stayed a trace shows a real `<path>` count, not an
  `<image>` wrapper around it.

## Drops on the pages that accept one

The composite canvas could not accept a layer by ANY route until the null-hostile
`keyOf(null)` was fixed — drag, the file picker and the "add blank" button all
threw the same silent `TypeError`. Before touching an add-a-layer path, check the
page's own state field (`#compLayers`) moves; see
`references/browser-interaction-verification.md` for the probe.

Two pages accept a scrapbook drop, and the binding rules differ by what a drag
MEANS there:

- **Composite page** — a dragged item has exactly one meaning, so the drop is
  bound to `document.body` (not the canvas, not `document`).
- **Run Job** — the drop is page-level too, but the flux REFERENCE tile carries a
  second meaning, so both its handlers call `stopPropagation()`. An item accepted
  as the edit reference must not also become the job's source.

A dropped source goes through `POST /scrapbook/:id/artwork`, which copies any
readable item into `storage/uploads` and answers JSON with `source_kind`:
deliberately not `#reference` (raster only, because a flux reference travels as a
data URI) and not `#use` (which REDIRECTS to the new-job form and would discard a
form the operator has already filled in). An SVG dropped in switches the source
kind to `svg`, so the kind follows the FILE.

## A flattened composite is a JOB

Compose work lived only as a `Composite` row plus a scrapbook item, so an
agent-made composite or album appeared NOWHERE in `/jobs` and clicking its image
led to no results page. Both flatten paths now record a Job.

- The job is created **already `done`** — the merge has happened by the time the
  row is written — and filed against the label whose URL owns the `/compose`
  route, so the Runner column stays true. What marks it is `spec["compose"]`,
  the same ask-and-answer-block shape a plot or bp job uses.
- **A locally-produced job needs `locally_produced?` guarding every runner-backed
  action.** It has no runner job id, so `download`/`archive_url`/`dataset` would
  build a path with a nil id — a 404 rendered as a generic failure. Ask the
  guard FIRST, then serve the artefact.
- **Take provenance from the model's own record, never by re-resolving it.**
  Building the compose spec to count layers RESOLVES every layer's source
  (fetching an SVG off a runner, decoding a data URI) and can raise — so
  recording a job could fail the flatten that already succeeded. Read the
  composite's own layer list, and make the record's `save` non-bang: log and
  carry on.
- Backfilling existing rows does NOT need a re-compose. The composite and its
  artefact are both on disk; write the Job row that points at what was produced.
  (The driver's own state file is where a demo's output path lives, because a
  Composite row does not store its last flatten.)
- `Job#preview_file` order is: proof -> compose output -> bp -> plot -> blender ->
  a raster-only flux generation -> `source.png`. Each kind line `return`s, so a
  queued job with nothing to show answers nil instead of requesting a file its
  runner will never have.

## An assertion about a shared directory is an assertion about the BOX

Cleaning up scoped to the test is only half the fix: two more assertions then
failed because they asserted a GLOBAL property of the live uploads directory —
`assert_empty Dir[uploads/"flux_inverse_*.png"]`, and a bare `twins.size == 2`.
Both only ever held while the cleanup was deleting the operator's own files, so
they were pinning the bug.

**Assert on what the test ADDED** (a before/after delta), never on the size of a
directory shared with production. Expect to find these immediately after scoping
a cleanup — a green suite going red there is the old assertion coming clean, not
a regression.

## Vector-preserving enhancement, stated honestly

"Enhance a traced source without losing the data" has exactly one answer here:
`POST /compose` places a candidate's own SVG text as VECTORS beside a generated
raster, so the trace is never rasterised and re-traced. Flux img2img CANNOT retain
an SVG's path geometry or declared colours at any strength — it re-renders the
picture — so it is the wrong tool for that ask, and saying so is part of the job.
