# Step lists — one job, several runner actions, in order

A job's request is normally ONE action: a trace, a generation, a drawing, a
render, a scene. A job whose `spec` carries a **step list** asks for several, in
order, in one record — one name, one owner, one state, one page.

**The studio drives the chain, never a runner.** Every runner here is stateless
and serves one operation per request; nothing about a chain is sent to it.
`RunJob#run_steps` posts step 1, waits for it to terminate, posts step 2 with
step 1's produced file handed in, and so on. That is why no runner needed a
change, a session, or a chain concept.

## The shape

```json
{"steps": [
  {"runner": "fluxbox",   "flux":    {"prompt": "a phoenix", "mode": "raster"}},
  {"runner": "pipeline",  "svg":     {"sweep": {"preset": "bw"}}},
  {"runner": "bp",        "input":   "previous",
                          "blender": {"doc": {"extrude": {"depth": 40}}}},
  {"runner": "pipeline",  "op":      "compose",
                          "svg":     {"width": 3000, "height": 2050,
                                      "layers": [{"name": "art", "kind": "vector",
                                                  "src": "step:2", "x": 0, "y": 0,
                                                  "w": 3000, "h": 2050}]}}
]}
```

- **`runner`** — a configured label (`CHOPSHOP_RUNNER_<LABEL>_URL`). Required.
- **the kind's block** — the SAME document a single-action job of that kind
  posts, under the kind's own name: `flux`, `svg`, `plot`, `blender`, `bp`. A
  `svg` step's block is the whole runner-contract document, because that
  contract takes one `spec` and that document is what the top level has always
  been. A block may arrive as a JSON STRING (a pasted contract); it is parsed
  once, where validation, the worker and the page all read it.
- **`input`** — where this step's source file comes from: `"previous"` or
  `"job"`. It goes BESIDE the label, never inside the kind's block: the block is
  posted to the service untouched, and a key the service does not know is a 400.
  Omitted, a kind that cannot run without a source takes the step before it when
  that step produced something it accepts, and the job's own artwork when it did
  not. A hand-off the studio cannot derive is refused by the MODEL, naming the
  step index, rather than posted blind.
- **`op`** — the step's OPERATION, when it is not its runner's own. Currently one
  exists: `compose` (see below). Same placement rule as `input`, same reason.

## File hand-off rules (`Job::STEP_FILE_RULES`)

| kind | needs a file | accepts | produces |
| --- | --- | --- | --- |
| `flux` | no | — | `.png` |
| `plot` | no | — | `.svg` |
| `svg` (trace) | **yes** | `.png` `.jpg` `.jpeg` | `.svg` |
| `blender` | no | `.svg` | `.png` |
| `bp` | no | `.svg` | op-dependent: `.svg`, or `.png` for `blender` |
| `svg` + `op: compose` | no | — | `.svg` |

`bp`'s and `compose`'s produced extension is read off the step itself
(`produced_extension`), because the kind alone cannot answer it — one bp action
can draw or render.

## The `compose` operation

A compose step is executed **studio-side**, not by a runner, and it is the one
step that can compose what the steps ABOVE IT produced:

- a layer's `src` may be `step:<n>` — the file step *n* of this same chain left
  behind. It is resolved from the ledger, so a step naming a LATER step, or one
  that produced nothing, fails naming the step index. Every other `src` form is
  what `ComposeSpec` already resolves: a `data:` URI, `/jobs/upload_preview/<n>`,
  a path under `storage/`, `/scrapbook/<id>/file`, an `http(s)://` runner file.
- the studio builds the wire spec with the SAME builder a flattened composite
  uses (`ComposeSpec`), and POSTs it to the pipeline runner's `/compose` — the
  route that merges vectors. Inlining is the point: the runner is on another box
  and cannot see this app's storage, so a source that is an SVG is composed as
  VECTORS, never rasterised and re-traced.
- the answer is stored in `storage/uploads` like any other step's output, so a
  later step (or the page) can read it.

## The ledger (`Job#steps_progress`, the `steps_state` column)

```json
{"current": 2, "total": 4, "state": "running",
 "steps": [
   {"index": 1, "runner": "fluxbox", "kind": "flux", "state": "done",
    "file": "flux_ab12cd.png", "content_type": "image/png",
    "runner_job_id": null, "started_at": "…", "finished_at": "…"},
   {"index": 2, "runner": "pipeline", "kind": "svg", "state": "running",
    "runner_job_id": "runner-7", "started_at": "…"}
 ]}
```

- Written by ONE writer (`RunJob#write_progress!`), so its shape cannot drift;
  `Job#steps_progress` / `#steps_recorded` / `#current_step_index` are the only
  readers that name its keys.
- **A step's output is recorded BESIDE its request**, under `rendered` inside the
  step's own block (`write_step_render!`), exactly where a single-action job
  records its own — one record carries the ask and the answer, per step.
- A step that is not `svg` (or `bp`) cannot take a file, and a step that needs one
  and can get it from nowhere is refused at validation time, by index.

## What a chain's own state means

- The job is `done` only after the LAST step, and its own verdict is written last
  (`complete_chain!`), so a runner's `done` for step 2 of 3 never reads as this
  job's done.
- A step that fails fails the JOB, naming the step: `step 3 (pipeline): …`.
- Cancelling between steps, or during one, stops the chain where it stands —
  the same rule every single-action path follows.
- A chain that included a pipeline step mirrors its candidates ONCE, at the end.
  `Job#execution_runner` / `#base_url` resolve to the runner the most recent
  pipeline step ran on, because that is where the candidates and the archive are.

## Back-compat

A spec with no `steps` key behaves exactly as it did before step lists existed,
and `Job#steps` answers one implicit step — so the single-action path and the
chain path share every reader and no existing row needed migrating.

## Where it is read

- `Job#steps` / `#sequenced?` / `#steps_progress` — the model.
- `RunJob#run_steps` — the execution.
- `app/views/jobs/_process.html.erb` — a chained job's page: the process as a
  TABLE (step, runner, operation, state, produced, runner job, seconds) and the
  end results as a GRID (one tile per produced file, in step order).
