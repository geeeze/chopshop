# One job, many steps — filing a pipeline as a single record

Use this when the work is a multi-stage pipeline (generate → render → chart →
trace → compose pages out of what those produced) and the result should be read
on ONE page: the process as a table, the end results as a grid. That is the shape
the operator asks for by default; one job per stage is the wrong shape.

The studio's own contract for this is `docs/step-lists.md` in the repo. Keep it
in step with anything you extend here — it is what a future reader trusts.

## Where the mechanism lives

- `spec["steps"]` — the ordered step list, on the job.
- `Job#steps` (normalised), `#sequenced?`, `#steps_progress`, `#steps_recorded`,
  `#current_step_index`, `Job.file_rules_for(step)`, `Job.step_operation(step)`.
- `RunJob#run_steps` — the chain, driven entirely studio-side.
- The ledger: the `steps_state` column, written by ONE writer
  (`RunJob#write_progress!`) and read by the readers above. A step's output is
  recorded BESIDE its request, under `rendered` inside the step's own block.
- `app/views/jobs/_process.html.erb` — the page a sequenced job renders first.

## A step's shape

```json
{"runner": "<label>", "input": "previous", "op": "compose", "<kind>": {}}
```

- **`runner` is a LABEL, not a kind.** Labels come from
  `CHOPSHOP_RUNNER_<LABEL>_URL`. On this box the pipeline/trace runner's label is
  `svg` — there is no `pipeline` label, and a hand-written contract that guesses
  one is refused as `unknown runner`. Read `Job.runners.keys` before writing a
  label into anything.
- **`input` and `op` go BESIDE the label, never inside the kind's block.** The
  block is posted to the service untouched, so a studio key inside it is a 400
  waiting to happen; the model refuses the placement and names the step index.
- The kind's block is the SAME document a single-action job of that kind posts.
  A `svg` step's block is the whole runner-contract document.
- A block may arrive as a JSON STRING (a pasted contract); it is parsed once in
  `normalize_step_block`, which is why `%w[plot blender bp]` is a list that must
  grow when a new document kind needs parsing.

## File hand-off rules (`Job::STEP_FILE_RULES`)

| kind | needs a file | accepts | produces |
| --- | --- | --- | --- |
| `flux` | no | — | `.png` |
| `plot` | no | — | `.svg` |
| `svg` (trace) | **yes** | `.png` `.jpg` `.jpeg` | `.svg` |
| `blender` | no | `.svg` | `.png` |
| `bp` | no | `.svg` | op-dependent |
| `svg` + `op: compose` | no | — | `.svg` |

- **A trace step needs a RASTER and must therefore follow the step that produced
  one.** Ordering a generator after the trace step, or handing a drawing (`.svg`)
  to a trace, is refused by index with the remedy named — do not try to "fix" it
  by widening the accept list: prep opens the hand-off with PIL and cannot read an
  SVG at all.
- `bp`'s and `compose`'s produced extension is read off the STEP, not the kind,
  because one `bp` action can draw or render.
- A step that needs a file and can get one from nowhere is refused at validation,
  by index, rather than posted and discovered as an empty run.

## The `compose` operation (studio-side, the reason to put composing in a chain)

A `compose` step is executed **on the studio**, not posted to a runner: the studio
builds the wire spec with `ComposeSpec` (through the small `ComposeDocument`
adapter, which answers a step document with the five readers a composite has) and
POSTs it to the pipeline runner's `/compose`. Inlining is the point — the runner
is on another box and cannot see this app's storage.

- A layer may name **`step:<n>`**, the file an earlier step of the SAME chain
  produced. It is resolved from the ledger, so a step naming a later or same step
  fails naming the index. This is what lets one job compose ten sheets out of the
  forty rasters, charts and traces the steps above it produced.
- Every other `src` is what `ComposeSpec.read` already resolves: `data:`, a
  runner `http(s)://` URL, `/jobs/upload_preview/<name>`, `/scrapbook/<id>/file`,
  or a path under `storage/`.
- **A source that is an SVG is composed as VECTORS**, so a page stays a vector
  document holding rasters instead of a picture of one. A layer that claims
  `vector` but whose bytes are not an SVG is refused rather than re-traced.
- A layout's FRAME (titles, card boxes, gauges, captions) cannot be drawn by a
  runner — the blend vocabulary has no text element. Draw it studio-side and store
  it as the job's own ARTWORK, then reference it by upload path.

## What must NOT become a step

**A print PROOF.** A proof is the operator's action on a candidate they PICKED,
and the pipeline never picks a winner — that rule is the point of the system. A
chain can therefore generate, trace and compose the champion, and the page must
say the proof is absent rather than fake one.

## Two rules a chain must not break

**A runner-backed step must not be mid-chain, or `sync_from_runner!` will settle
the whole chain.** `runner_job_id` is NOT a chain's own: it names whichever step
last dispatched to a runner (`svg` and `flux` do; the in-process `bp`/`plot`/
`blender` steps record nil) and it stays set after that step finished. Both the
show action and the index's in-flight sweep call `sync_from_runner!`, so merely
LOADING a page was enough to mirror that one step's `done` onto the job: MEASURED
on a 7-step chain whose step 1 was the trace — the job read `done` with
`finished_at` nil, step 7 (`blender`) still `running`, and the chain's own verdict
never written, because `complete_chain!` is only reached after the loop ends. The
model now keeps the verdict for a sequenced job (`unless sequenced?` around the
state, prep_summary and error mirror in `sync_from_runner!`) while still mirroring
the candidate/comparison FACTS, which is what `complete_chain!` needs. Anything
that writes a job's state from a runner must carry the same guard.

**So order a chain with its runner-backed steps LAST.** Belt and braces with the
guard above: with `svg`/`flux` steps at the tail, even an unguarded mirror can
only fire when the chain is nearly done. A chain that needs BOTH a trace and a
generation therefore puts one of them first — the smoke test's answer is to make
the trace first and have it take the JOB's own artwork, so the GPU step is the only
one that can fail alone.

**A step's `input: "job"` is only legal as step 1.** `step_takes_previous?` counts
only `"previous"` or a blank input as a hand-off, so declaring `"job"` on a later
step leaves it validated against the step ABOVE it, and the refusal talks about
that step's extension rather than the artwork the step actually meant.

## Building a fixture that survives validation (tests)

A `Job.create!` for a sequenced job has to satisfy the real chain validator, not
a stub of it — the validator wants plausible pipeline content, and its refusals
name the STEP, so a fixture mismatch reads like an app bug:

- **`input_path` is NOT NULL** — pass a dummy string (`"/uploads/art.png"`);
  the validator checks presence, not existence.
- **`op` may only be `compose` or absent** (the Extending-it rule above, seen
  from the other side); a step with no op runs its runner's own operation, and
  the process table then shows the RUNNER'S KIND as the operation (`mock` →
  `svg`, `fluxbox` → `flux`, `pipeline` → `svg`).
- **The chain must be real**: flux-before-svg (the trace needs the raster the
  flux step produces), a flux step carrying a `flux` block with a prompt, and a
  `compose` step carrying a compose document (width, height, layers). The
  proven two-step shape is the smoke test's: fluxbox → pipeline.
- **Runners are env-driven and MEMOIZED.** The test env has only `mock`; a
  chain needs one runner per kind, so register them around the test:
  `CHOPSHOP_RUNNER_PIPELINE_URL`, `CHOPSHOP_RUNNER_FLUXBOX_URL`,
  `CHOPSHOP_RUNNER_FLUXBOX_KIND=flux`, then `Job.reset_runners_cache!` before
  AND after. Clear `CHOPSHOP_FLUX_HANDOFF_RUNNER` in the same sweep. Without
  the kind, `runner_kind("fluxbox")` falls back to `"svg"`, and both
  validation and the rendered page lie about the step.
- **Create + login + request all INSIDE the env block** — the show page reads
  runner kinds at render time, so restoring the env before the `get`
  re-derives everything from the default mock-only map.
- RED-proof page tests the way the process-card test does: run with the view
  file present (green), move the file away and confirm the failure is the SAME
  error production would raise (`MissingTemplate`), restore. A test that only
  ever ran green proves nothing about what it catches.

## Extending it

- Adding a step operation: declare it in `STEP_OPS`, route it in `RunJob#run_step`,
  give it its own file rules, and teach `produced_extension`. Validate the op from
  the step **as posted** (`validate_step(..., step["op"])`), because normalisation
  drops an unknown op and the step then validates as its kind's default — which
  reports "a SVG step needs an artwork source" for what is really a misspelled
  `compose`.
- Tests: model tests for the shape and every refusal (name the message), and a
  worker test that swaps the clients (`define_singleton_method` — there is no
  `minitest/mock` here) and asserts ORDER and the HAND-OFF, plus one case per new
  operation.
- The page needs no change for a new operation: the table reads
  `Job.step_operation`.
