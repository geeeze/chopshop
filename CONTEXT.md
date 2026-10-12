# CONTEXT.md — chopshop-studio

Working state for agents and humans: what is in flight, what is blocked, and
the caveats that are not obvious from the code. Update this as work lands.

**Repo visibility: private.** Host-specific deployment facts may live here but
must be tagged `HOST-SPECIFIC` (see `skills/README.md` and the
`sync-skills` convention) — subject to change, remove before reuse elsewhere.

**Language: English only.** Every file, comment, doc, string and commit message in
this repo is English — no CJK (Chinese/Japanese/Korean) characters. Where a parser
genuinely needs them, write `\uXXXX` escapes, never the literal
(`docs/agents/standards.md`, rule "English only").

## The public datasets the studio draws from (DATASETS page)

Two corpora are ingested, each for a different KIND of useful — and neither one's
images are copied into this repo.

- **DiffusionDB** (`poloclub`, CC0-1.0 metadata / MIT repo) supplies **prompts**:
  a slice of its 2M prompts with the hyperparameters their authors used, its own
  2-D projection of prompt space, its derived topic labels and its phrase tree.
  `prompt_sources` is the table; `PromptSource` is the model; `bin/rails
  datasets:ingest_diffusiondb` (see the task header for the source URLs) is the
  ingest, which JOINs four files on the prompt text. **No `owner` column** — it is
  shared reference data, the one table here without one. The page draws the map
  through the blend-plot service and hands a prompt to the Run Job form, so the
  library is a working prompt source rather than a gallery.
- **MET-Meme** (`liaolianfoka`, images on Kaggle under its own terms) supplies a
  **schema**: nine annotation fields (metaphor occurrence/category, source and
  target domain and modality, sentiment, intention, offensiveness).
  `app/lib/meme_vocabulary.rb` transcribes it; `bin/generate-meme-vocabulary-fixture`
  GENERATES `test/fixtures/meme_vocabulary.json` from the source's README and the
  pin test compares the two — a hand-typed copy of an external schema is free to
  lie about it, so it is pinned like `Telemetry`'s pipeline constants. The
  images and their per-image labels are NOT here; the paper's classifier belongs
  to the pipeline repo, not this app, which computes no ML.

`GET /datasets/library|draw|meme-labels` are the JSON twins; `POST /datasets/use`
is the hand-off. The full contract is in `docs/agent-api.md`.

**Live, measured:** 60,000 prompts ingested, all 60,000 mapped, 1,991 parts,
9,632 topics, 1,967 phrase roots, licence CC0-1.0 — and the loop PROVEN end to
end: a prompt drawn from the library was filed with its own settings and the box
returned a real raster (job 386, `flux_68bd74b78c9a.png`, 562KB).

**Two transcriptions are pinned, not trusted** — DiffusionDB's numeric
`sampler` codes (`bin/generate-sampler-fixture` → `test/fixtures/diffusiondb_samplers.json`)
and MET-Meme's vocabulary. Both fixtures are GENERATED from the source; when a
a source changes, re-run the generator and review the diff. The sampler mapping
matters because the dataset stores a CODE (`8`) and the generator takes a NAME
(`k_lms`) — passing the number through would file a request the service cannot
honour.

### The MET-Meme boundary is a DECISION, recorded (#49)

MET-Meme is a **schema source, not a data source**. The studio transcribes its
annotation vocabulary — nine fields: metaphor occurrence/category, source and
target domain and modality, sentiment, intention, offensiveness — and serves
those labels as JSON. It never ingests MET-Meme's images or per-image labels.

WHY, three reasons:
- **Provenance.** The labels are MET-Meme's intellectual contribution. Serving
  the vocabulary with a citation is honest; serving their images would imply a
  licence the studio does not hold.
- **Kaggle's terms.** The images live on Kaggle under the dataset's own
  licence. The studio neither hosts nor redistributes them and has no need —
  the annotation scheme is the part it transcribes.
- **No ML here.** The paper's multilingual BERT + VGG16/ResNet50 classifier is
  a pipeline-repo concern. The studio computes no ML, so ingesting images
  would be dead weight: a corpus the app cannot use and should not host.

The labels are usable as a structured descriptor axis — e.g. a mashup
descriptor like "offensive, humorous" — but that is **PENDING the mashup
feature (#46/#47/#50), which is not built**. `MemeVocabulary` already provides
`labels`, `valid?`, `word`, `check` and `to_contract`, so the seam exists; the
combinator does not. Recorded here as a future capability, not a live one.

Seams: `app/lib/meme_vocabulary.rb`, `GET /datasets/meme-labels`
(`DatasetsController#meme_labels`), `bin/generate-meme-vocabulary-fixture
--check`.

## UI standard: the page header (canonical: the project workspace head)

The project workspace's header (`app/views/projects/show.html.erb` — and the
Projects index mirrors it) is the reference format every page's head should
follow. It is the best-balanced title/subtitle/action layout to date — mirror
it, do not re-invent it. (It was the Jobs page's head before the Projects
redesign removed that page; the format survived the move.)

- **50/50 split.** Title + subtitle own the LEFT half; the action button(s) own
  the RIGHT half. `.page-head-row--stacked` is a `grid-template-columns: 1fr auto`
  grid: `.section-title` is pinned row 1 col 1, the blurb row 2 col 1, the
  primary action row 1 col 2, and secondary controls row 2 col 2 (right-aligned
  with `justify-self: end`).
- **Title.** `.section-title` + `.gradient-text` — `clamp(2rem, 4vw, 3.2rem)`,
  weight 800, gradient across the word. Subtitle is `.page-head-blurb`
  (`--text-secondary`, `max-width: 67%`; the projects pages use the `--long` variant).
- **Larger primary action.** "Run Job" is a `.btn.btn-primary.head-action` —
  the LARGEST button in the head (2.75rem tall / 98×44px measured, plus the
  conic glow ring at `inset: -3px` and the ambient `0 20px 60px` glow). The
  accent button is deliberately bigger and brighter than everything beside it.
- **Buttons underneath.** Secondary controls (e.g. the List/Grid view toggle)
  sit DIRECTLY BENEATH the primary, in row 2 col 2 — never beside it, never in
  the title cell. They are small `.btn-secondary` controls, NOT `.head-action`s.
- **Frosted glass.** Secondary controls are frosted: `.btn-secondary` carries
  `backdrop-filter: blur(10px)` over a translucent `--surface` fill, so the
  particle field reads through them.
- **No margin between grouped buttons.** A set of mode buttons is ONE segmented
  control: `.view-toggle { display: inline-flex; gap: 0 }` with square inner
  edges and rounded outer corners only, and `margin-left: -1px` on the second
  half so the two 1px borders collapse into one. They touch; they are one box
  with two stops, not two buttons with air between them. Pinned by
  `jobs_grid_test.rb` (`gap: 0` assertion), re-pointed at the project
  workspace when the suite was brought green (#33, 2026-10-06).

A visual change is a contract change: the header shape is pinned by
`page_head_uniformity_test.rb`, `responsive_head_test.rb`, `head_alignment_test.rb`
and `head_action_size_test.rb` — changing the title, blurb, button size or
arrangement means updating those lists and re-running the suite.

## THE REDESIGN — LANDED (designed 2026-10-01, built 2026-10-03/04)

**READ THIS BEFORE TOUCHING THE JOBS MODEL — as the record of what was BUILT,
not a plan.** Nothing below is a proposal any more. The container landed in
`cf675c1`, `94e95a6`, `76c80dd` and the follow-ups `05d4004`, `754fc50`,
`f4605dd`, `13e4066`; templates landed in `e5b2019`, `09e7c23`, `5b022fc`
(`PipelineConf::TEMPLATES`, `POST /templates/use`, the picker on the Run Job
form). The reasoning below is why it is shaped this way, and it stays because
the chat session it came from is gone.

### Still genuinely open (audited 2026-10-06)

- Whether an automated batch runs against ONE template or spans many.
- Who authors a template's bounds (product decision vs derived from the pipeline).
- **`Output` rows are never written.** The model and the container diagram
  exist, but no code path in `app/` creates one (zero `Output.create` /
  `outputs.create` hits, 2026-10-06) — an artefact "returning to the project"
  is visible only as its job row.
- **Tags are read, never written.** `Project.includes(:tags)` runs, but there is
  no `Tag.create`, `tags.build` or `tag_list` call anywhere in `app/`
  (2026-10-06) — the join table is scaffolding until a write path exists.
- **Sequences**: `Job` dispatches them (`sequenced?`, `steps`, `sequence`) and
  the step-list docs describe the chain, but the page a chain renders through
  was missing its `_process` partial until #32 (see the blocker note).

### The incoherence that motivates it

A job's output has **nowhere to go back to**. `Job` is the row, `runner_job_id`
is the runner's row, and `active_job_id` is a third thing entirely — three things
called "job" and no container for the work. Provenance is four unrelated
mechanisms with real holes:

- `candidates.job_id` and `validations.job_id` are genuine foreign keys.
- `scrapbook_items.job_id` and `events.job_id` are bare integers that outlive
  their job by design, and nothing ever reconciles them.
- **Both composite flatten paths create their `ScrapbookItem` with
  `job_id: nil`**, and the raster path writes **no `sha256` at all** — so a
  flattened composite is an artifact belonging to nothing (61 of 321 jobs).
- The runner derives its own `stem` from the name it is sent. The studio derives
  a *different* one and never stores the runner's, so the two can disagree with
  no record that they did.

And **there is no tagging anywhere** — no column, no table, no join. Four
unrelated closed vocabularies exist (`ScrapbookItem::KINDS`, `Event::KINDS`,
`Candidate#preset` free text, `PromptSource#topic` free text) and nothing joins
them. `Composite` has no FK to anything; it reaches a job only through
`spec["compose"]["composite_id"]`, a string in JSON.

### The container

```
Project ──┬── Source      loaded or generated INTO the project
          ├── Job         sequence N, dispatched from a source,
          │               and its output RETURNS to the project
          └── Output      one row per artefact the job produced
                ↑
      tags (system + operator) on all four
```

- **A Project is a stored table, not a view over tags.** This was the load-bearing
  fork and it is settled: a view cannot receive a source, cannot sequence jobs,
  and cannot be seen empty. The whole point is that an output lands back in the
  project that asked for it, which needs somewhere for it to land.
- **A Job keeps its meaning exactly as it is now** — what the runner does when
  the user asks it to act on a source. It gains `project_id`, `source_id`,
  `sequence` and `runner_stem`. Nothing about what a job *is* changes.
- Project name is the operator's word for it, free text, unique **per owner**.

### Settled defaults

- **Tags are two tiers, one table, a `kind` column.** *System* tags are derived
  from the spec at write time and are **never typable** — if an operator can type
  `max_colors_3` by hand, the search index carries a lie. *Operator* tags are free
  text, because a human needs to say `client-work` or `redo`.
- **`is_test` is a real column**, not `name LIKE 'smoke-%'`. A name prefix is a
  lie the moment anyone names a real project `smoke-test-hero`.
- **Sequencing is an integer per project, assigned on dispatch, gaps allowed.**
  No renumbering on delete. The counter lives on the project row (not
  `MAX(sequence)+1`, which is a read-then-write race), incremented under the row
  lock.

### Templates: a parameter space, not a view

The Run Job form must not require understanding the runner's spec to use.
**Default format, selectable templates, with configurable levers exposed for
modification** — and a person demonstrating or testing basic functionality never
has to know the settings exist.

- A template is a **parameter space with bounds** (`layers: 1..6`,
  `max_colors: 2..8`). That is directly sampleable for an automated batch, and the
  bounds are the guardrail: a batch cannot generate a request the runner would
  refuse.
- **Bounds belong to the pipeline, not the template.** The template carries only
  the *chosen subset* of levers. If it restates ranges it becomes a second source
  of truth for every default and limit — the same drift trap as `FluxConf` vs
  `config.py`, which already costs a cross-repo parity test.
- **The JSON page stays, as a power feature. It is not in the MVP.** It is the
  union of every lever, which is exactly why it cannot be the default: it only
  made sense while one narrow pipeline flow used most of it. Nobody needs 1:1
  mapping of every lever in the UI — the people who want the raw spec are the
  same people who will use the JSON page.
- **The configuration does not disappear, it stops cluttering the site.** Fewer
  surfaced levers means less documentation, and the documentation is already the
  bigger cost.
- **The picker is a GUIDED CHOICE** (`PipelineConf::GROUPS`), not a flat list of
  twelve. The first control picks the KIND of job — Print production, General,
  Multiphase, 3D & game assets, Demo / test — and the second control is that
  kind's deeper setting. Where every template under a group is a preset of ONE
  shape of job ("trace this raster" four ways, "render this geometry" three
  ways) the second control IS that job's tuning and is labelled as such
  (`GROUP_SUB_LABEL`: "Trace tuning", "Render preset"). Where a group is
  genuinely different shapes there is no single tuning, so the second control
  names them and is labelled "Job shape" rather than claiming a tuning it does
  not have. The grouping is stated in ONE place and a test pins it to the
  template list in both directions, so a template cannot be added without a
  home or appear twice. Each option carries its blurb as a `title`, so a choice
  explains itself on hover.
- **The guided choice is ADDITIVE.** The template select still holds every
  option and still posts `job_template`, so the Apply round trip
  (`POST /templates/use`, the server composing the spec) is untouched — the
  group control only sets `option.hidden`. Reverting it is one ERB block and
  one JS block.

**The twelve templates, by group.** The right-hand column is the honest
caveat: three bp templates compose a document that is deliberately INCOMPLETE
until you supply the geometry (the form refuses locally with a named reason).

| Group | Template | Kind | What it is | Caveat |
|---|---|---|---|---|
| Print production | Standard | svg | the ordinary trace | — |
| Print production | Screen print | svg | 4 inks, hard minimum stroke | — |
| Print production | Photographic | svg | photo preset, gradients on, ink limit raised | — |
| Print production | Deep sweep | svg | every preset at the candidate ceiling | slow |
| General | Generate only | flux | the raster IS the deliverable | — |
| General | Draw a document | bp | bp draws the geometry you paste | needs a `doc` |
| Multiphase | Generate, then trace | flux → svg | FLUX draws, the sweep traces | — |
| Multiphase | Generate → trace → render | flux → svg → bp | three steps, each handed the last file | — |
| 3D & game assets | Render in 3D | bp | extrude + shade that geometry | needs an `elements` list |
| 3D & game assets | Sprite (alpha) | bp | one front-on RGBA frame | needs an `elements` list |
| 3D & game assets | Prop turntable + GLB | bp | four ortho views + a GLB | needs an `elements` list |
| Demo / test | BP tournament (simulated) | bp (sim) | a bracket the studio runs itself | decides nothing; no runner |

The `Draw from dataset` template was REMOVED: a library draw is a property of
the generation (the Prompt source control on the flux panel), not a separate
kind of job — so it was a template that existed only to set one sibling
control. The draw itself is unchanged.



### Measured on the live box (2026-10-01)

321 jobs, 165 distinct inputs (~2:1 reuse). **242 of 303 `done` jobs have no
candidates** — most jobs produce exactly one artefact, so any "group outputs with
inputs" container has to work for the single-file case. **284 of 321 jobs landed
on 2026-09-29** and are `smoke-*` residue from the hourly cron, now disabled; the
real working set is ~37 rows. **Those 284 should be deleted** before a tagging
vocabulary is built on top of this corpus, or every tag is skewed by test data.

## What this repo is

Chopshop Studio, the Rails 8.1 operator front end for the chopshop pipeline
(private demo). The operator uploads a raster, the runner produces traced SVG
candidates, the operator picks one, and that pick is proved: proof PNG, print
PDF, manifest. The pipeline never picks a winner; the studio is the surface
where the human makes that call.

## Work in progress

- **The FLUX page carries the model knowledge now, and `FluxConf` follows `config.py`
  as well as `models.py` (landed, live).** The generation layer's quality write-up
  (`~/chopshop-flux/docs/MODELS.md`) reached the operator: every card in the MODELS
  popup gains ONE judgement sentence (`FluxConf::QUALITY`, keyed to
  `FluxConf::MODELS`), and the page gains a **Tips** card — distilled vs undistilled,
  which entries have a REAL negative prompt, generating at the model's native size,
  and the print formula. The quality sentences deliberately do NOT live inside
  `MODELS`: that hash stays a verbatim copy of the registry, so a reader can still
  tell the transcription from the studio's own prose.
  - **The counter-intuitive, MEASURED facts are on the page because they are the ones
    an operator gets wrong:** a distilled checkpoint ignores guidance and more steps
    do NOT help it (`klein-4b`, `sdxl-turbo`); Sana's guidance is embedded and
    honoured; `klein-4b-base` honours it (guidance 4.0 vs 1.0, mean absolute pixel
    difference 34.38); and no step-count speedup may be claimed on this box, because
    stage paging dominates. The print numbers stay in the pipeline's spec (dpi 300,
    max_colors) — the page points at them and carries no second set.
  - **#13's studio half is done: the GPU-contention guard is mirrored.** A fifth card
    (**GPU**, full width OUTSIDE the 2x2 setting grid, `data-flux-gpu`) carries the
    five knobs `config.py` reads — `CHOPSHOP_FLUX_GUARD` (`off`/`warn`/`wait`/`block`,
    default `warn`), `_GUARD_VRAM_GB` (`5.0`), `_GUARD_WAIT` (`120`), `_GUARD_POLL`
    (`5`), `_LMSTUDIO_URL` (unset) — and the refusal an operator meets: **`503
    gpu_busy`**, retry-don't-fix, returned only in `block` or after `wait`'s budget.
    Its "?" also names `/health`'s `engine.gpu_guard` block, where a busy card is
    legible WITHOUT a failed generation. The knobs' fields render from one new partial
    (`app/views/pages/_flux_fields.html.erb`) shared with the setting cards, so a
    field's markup cannot differ between the two, and the JSON popup's conf emits the
    five variables in the service's own names.
  - `docs/SURFACES.md` gained the same five knobs, the `503 gpu_busy` kind and
    `gpu_guard` in the `/health` shape. Its `GET /models` row was also incomplete and
    is corrected in the same pass: the service answers THREE arrays
    (`models`/`modifiers`/`vaes`), and the modifiers/VAEs carry `kind`, `aliases` and
    `notes` beside what was listed. (`CHOPSHOP_FLUX_IDLE_EXIT` was missing from the
    config list too — same line, same class of omission.)
  - **The parity test now compares `config.py`, which is why #13 could not fail
    before.** `test/lib/flux_repo_parity_test.rb` parses config.py with `ast` for its
    module constants AND its env inventory (name → default, read from
    `os.environ.get` and the `_int_env`/`_float_env` helpers; a fallback the parser
    cannot evaluate is UNPARSED, never "no default"), then compares: the seven
    constants both files state, `models.py`'s `DEFAULT_MODEL_KEY` (the select opens on
    it and nothing tied it to the registry until now), the guard family **name for
    name and default for default** (selected by NAME, so a sixth guard knob fails on
    arrival), and every variable the studio's inventory names against what the service
    reads. Each comparison has a can-fail test that corrupts it one character at a
    time.
  - Deployed and verified live: `https://chopshop.geenet.work/flux` (`200`, 83946
    bytes at deploy). The SERVED page carries 8 × "Where it fits"/"Weak spot", the
    four tip labels, `503 gpu_busy`, `gpu_guard`, all five guard env names and the
    five guard fields; the served inline script (12549 bytes) passes `node --check`
    and emits `CHOPSHOP_FLUX_GUARD*` into the conf JSON. Served
    `application-a3ee1b9c.css` == `public/assets/.manifest.json`'s
    `application.css.digested_path` (no asset file changed, so no precompile).
  - Suite at that change (2026-10-01): **1162 runs, 11555 assertions, 0 failures**.
    The 1148 baseline in `MODELS_BRIEF_C.md` predates that HEAD; that change added
    exactly nine (five parity, four served-page). **Do not quote this as the current
    state** — as of 2026-10-06 the suite is RED (see the bottom note, #33).
  - **#13 is NOT closed deliberately:** every item it enumerates now exists in the
    working tree and is serving live, but nothing is committed (this task's rule), so
    the issue carries a comment with the evidence and the close belongs with the
    commit that lands it.

- **STATUS is now a telemetry page: the hierarchy is gone, and the host is
  sampled (landed).** The operator's ask was for "actual relevant stats …
  pipeline use / files generated traced scrapbooked composited and server
  information / cpu ram swap usage over time, plotted by -bp and rendered".
  - **The source → job → candidate HIERARCHY was REMOVED**, not restyled. It
    restated the jobs table in a shape no number could be read out of. Its HTML
    fallback and CSS (`.status-tree`, `.status-node`, `.status-metrics`,
    `.status-tag`) went with it — the absence is pinned STRUCTURALLY by
    `test/controllers/status_page_test.rb` (no panel, no nested list, and the
    `tree` operation is never called; a grep for the word would match the page's
    own prose and prove nothing), which is also the regression the operator would
    otherwise ask for again.
  - **Two new panels, both drawn by chopshop-bp's `digest` operation** (a POST is
    a blend-plot task — that is the settled division, not a leak):
    **PIPELINE USE** as a BAR chart (jobs / generated / traced / proofs /
    scrapbooked / composited — six unrelated totals, so a line would imply a
    progression that does not exist), and **SERVER** as a LINE chart (CPU, memory
    and swap over six hours in five-minute buckets) with the newest reading as
    tiles. The event log keeps bp's `log`. With no blend-plot runner the same
    numbers render as the page's own HTML, and **nothing to draw is nothing to
    ASK for**: a bar chart of six zeros and an empty timeline are drawings of an
    absence, so those documents are simply not requested.
  - **`HostSample` is new: one row a minute of this host's CPU/memory/swap**,
    read from `/proc` (stdlib — `sysstat`/`psutil` answer "now" and keep no
    series, and the app already has a store). Written by a new `host_sample`
    recurring task in `config/recurring.yml` running `HostSample.capture!` every
    minute from the Solid Queue worker already alive inside Puma: no second
    daemon. Three rules the model exists to hold, each a bug it does not have:
    a CPU percentage is a DELTA against the sample before it (so the raw counters
    travel with the reading, and a gap wider than one bucket yields `nil` rather
    than a spike that never happened); a missing reading is `nil`, never `0` (no
    swap on the box means no swap series, not a line on the floor); and a stopped
    sampler is a STATE the page names — an hour-old percentage is a true reading
    of an hour ago and a lie about now.
  - **`/engine.json` gained `use` and `host`**, read through the SAME methods the
    page reads (`EngineMetrics.use`, `HostSample`), so the page and its
    machine-readable twin cannot drift about a number. `EngineMetrics.use` counts
    generated files from the JOB's own record (`Job#generated_variations`) rather
    than through the configured runner kinds: a tally that asked the deployment's
    environment would report zero files the moment a `CHOPSHOP_RUNNER_FLUX_*`
    line was removed, which is a page lying about its own database.
  - **A count appears ONCE on the page.** The strip at the top now carries the
    learning signal only (events, by kind); the produced counts live in the
    PIPELINE USE panel where they are both listed and drawn, and the bar order
    and wording live in `PagesController::USE_BARS` so the chart, the tiles and
    the JSON agree by construction.
  - **Deployed and verified live.** `https://chopshop.geenet.work/status`. Three
    panels drawn by bp (`use`, `server`, `log`) with the four status panels
    `use`/`server`/`log`/`ml` and zero hierarchy traces on the served page.
    Owner-scoped use tally read back live: 161 jobs, 33 generated, 456 traced,
    36 proofs, 66 scrapbooked, 39 composited.
  - **The merge that carried this to origin means the digests are a chain, not
    one value** — the CSS is hash-stamped, so re-read the manifest rather than
    trusting a number in prose. In order: `2f0f86ad` (before), `32eac3cf` (this
    work alone), and **`a3ee1b9c` (live — the merged tree, after the merge
    `de3820b` — rewritten from `f4c6c2f`, see the master.key caveat — brought the
    candidates-grid / popup-convention work in beside it).**
    The merge landed 15:20, ten minutes AFTER this work was deployed, so the box
    was briefly serving CSS that `main` no longer contained; recompiling and
    restarting on the merged tree is what closed that. **Tracked: #8** — deploy
    is manual, so the window can reopen.
  - **THE SAMPLER DID NOT RUN AT FIRST, AND THE REASON WAS A PRE-EXISTING BUG.**
    The `host_sample` recurring task was created and enqueued, and then sat in
    `ready` forever: this deployment's worker (config/queue.yml) is pinned to
    `queues: "runs"`, while Solid Queue's `RecurringJob` defaults to the
    `solid_queue_recurring` queue — which NOTHING works. So the whole dispatch
    path completed (task row created, execution recorded, job enqueued) and no
    recurring task had ever executed here: measured, 30 ready RecurringJobs and 0
    failed, with the hourly `clear_solid_queue_finished_jobs` having never once
    run. Fixed by declaring `queue: runs` on BOTH tasks in config/recurring.yml.
    A dedicated recurring worker was rejected on measurement: the DB pool is
    exactly sized (3 Puma threads + 2 queue processes = the pool of 5), so a
    third queue process over-subscribes it. The trade — a long run delays the
    sampler, so a busy window leaves a hole rather than a spike — is reported
    honestly by `MAX_GAP_SECONDS` and documented in that file. **Tracked: #3**
    (the mechanism — any FUTURE recurring task added without `queue:` fails the
    same silent way) and **#9** (the sampler losing ticks to a long run).

- **Sketch: snapping, COUPLING and templates on the composite canvas (landed).**
  Sutherland's Sketchpad (1963) is the source, and its own write-up draws the
  line the feature is built on: an early version let lines be drawn parallel or
  perpendicular to another "but carried no permanent trace of the relationship
  other than the accident of their position" — which he treated as a deficiency.
  So there are two halves, and they are different things:
  - **SNAPPING is the strong condition** (the T-square). `s.snap(...)` in
    `aether-sketch.js` proposes edges, centres, margins, equal gaps and mirrors
    within a tolerance, scored, and the drag applies the best of each axis.
    Nothing is stored; Alt suppresses it; the guides are drawn on the canvas.
  - **A CONSTRAINT is kept.** `s.couple(...)` records
    `{ how, to }` on the LAYER (Sketchpad put them on variables — and it needs
    no migration: the JSON a composite already posts carries them). A constraint
    is "a subroutine yielding a scalar that should be zero": `error` is the
    scalar, `resolve` the projection, and `solve` runs Sketchpad's **one-pass**
    method along the dependency direction, falling back to **relaxation** when
    the graph has a cycle. The DRIVER IS FIXED — the layer in hand is never
    resolved by its own links, or coupling would fight the drag.
  - **Only a snap that MOVED the layer is kept.** A zero-delta candidate means
    "already aligned" (or already the same size), and recording that is coupling
    the operator never asked for.
  - **Templates** (`grid`/`stack`/`row`/`hero`/`thirds`/`mirror`) are the "not
    manually" door: `CompositeLayout.place` arranges AND COUPLES, because a
    template that only wrote coordinates is a very large snap. Plans live in
    Ruby, so the page, an agent POSTing `/composite/template` and the metrics
    endpoint all arrange by one implementation.
  - **Metrics**: alignment, even-gap spacing, frame fit, balance, coverage,
    overlap (reported, never scored) and COUPLING, blended by one weight table.
    Served per composite at `/composite/:id/metrics`, aggregated into
    `EngineMetrics.metrics[:composites]` (so `/engine.json` carries it), and shown in
    the builder. They describe how the pieces SIT and rank nothing — the
    pipeline's no-winner rule does not stop applying because the pieces are
    rectangles.
  - Pinned by `composite_layout_test.rb` (the vocabulary, weights and tolerances
    are asserted against the JS source, and every template must satisfy its own
    constraints) and `composite_sketch_test.rb` (routes + page wiring). Verified
    in a browser: snap lands exactly and stores nothing, Alt suppresses it,
    coupling records and shows a badge, a coupled layer follows the one it is
    aligned to, a template re-arranges, and the page's score equals the API's.
  - **Not ported, on purpose:** perpendicular/parallel (a box is both already),
    point-on-line/circle (no points, lines or circles in this model; the box
    equivalent is `touch-x`/`touch-y`), and `upright` (no rotation to take).

- **The left column is a FRAME with two panels (landed).** The composites panel
  was in the layout from `53072b9` and could never be seen: nothing ever gave it
  an `.open` class (its only geometry was `.scrapbook-sidebar`'s
  `translateX(-100%)`), while the inline cycle script that shipped with it
  toggled the `hidden` attribute — and a `hidden` panel is STILL off-screen, so
  it looked identical to a working one. Dead feature, green suite, no test
  covering it. It is now ONE frame: `frameApply`/`frameCycle` in `aether.js` own
  the state (`scrap` / `both` / `comp` / `none`), drive the same `.open` class
  the CSS and `body.scrapbook-open` already read, and the close orb on whichever
  panel is showing advances it (double-click closes the frame). The order is
  star → scrap → both → comp → none: every state is reachable from a control
  that is on screen while you are in it, and the committed order (`both` → comp
  → scrap → close) could not reach `comp` at all. Both panels up
  (`body.frame-split`) SPLIT the column — scrapbook top band, composites bottom.
  The composites panel is the NAVIGATION frame over the composites table
  (`/composite/list`, each row opening `/composite?id=N`), not a second store.
  Pinned by `test/controllers/frame_cycle_test.rb`, which asserts the MECHANISM
  (which class, which states, which control) because that is what a green suite
  missed. Verified in a browser: the cycle, the two bands, the page share and
  the restore across navigation.

- **A flattened composite is a JOB (landed, live).** Compose work used to live
  only as a Composite row plus a scrapbook item, so agent-made composites and
  albums appeared NOWHERE in `/jobs` and clicking their image led to no results
  page. Both flatten paths now record a Job — created ALREADY DONE, because the
  merge has happened — filed against the label whose URL owns the `/compose`
  route, with `spec["compose"]` carrying the composite, its mode, its palette and
  the layers it was made of. `Job#compose?`, `#compose_output_file`,
  `#locally_produced?`; the results page renders the merged document with a link
  back to the composite. **`locally_produced?` is the guard every runner-backed
  action must ask first** — a compose job never dispatched anything, so building
  an archive URL for it puts a nil runner id in a path. Pinned by
  `test/controllers/compose_job_test.rb` (6 tests).
- **A test assertion must be scoped to the test, not to the BOX.** Two more
  assertions were pinning the uploads bug: they asserted global emptiness (or a
  global count) of a `flux_inverse_*.png` glob in the LIVE uploads directory,
  which only ever held while the cleanup was deleting the operator's own files.
  Assert on what the test ADDED (a before/after delta), never on the size of a
  shared directory.

- **The Composite builder composes (landed).** Four faults, all found by driving
  the feature as an agent and none visible to the suite: `composite_path(@composite)`
  redirected to `/composite.5` (id swallowed as a format suffix); migration
  `20260928000500_add_palette_to_composites` was **never applied to production**,
  so every create 500'd; `compose_base_url` picked `labels.first` and `mock` is an
  svg-KIND runner whose URL sorts first, so every vector composite was composed
  against the MOCK (no `/compose`, `404 unknown route`); and
  `ComposeClient#parse_svg` required the body to start with `<svg` while the
  operation answers with an XML declaration first, rejecting a 200 that carried
  the right bytes (`PlotClient` had the same guard and the same fault). Pinned by
  `test/controllers/composite_wiring_test.rb`.
- **A test cleanup must never glob the LIVE uploads directory (landed).** Five
  helpers deleted by prefix in `storage/uploads` — the real directory a live
  job's raster and a bp job's drawing live in — so every suite run silently
  emptied them and those rows' thumbnails 404'd until someone re-checked the live
  page. All now go through `UploadsSandboxHelper` (`test/test_helper.rb`): snapshot
  in setup, delete only what THIS test added and matches its prefix. **When you
  find one of these, grep for the whole class** — fixing the three you found is
  not the same as closing it, and the second sweep is what found `plot_*.svg`.
  Verify with a colliding sentinel file that must survive a full run.
- **A job's drawing is REPRODUCIBLE, so a lost artifact is repairable.** Every bp
  job records the document it drew and the filename it drew it to, so re-posting
  that document to the service and writing the answer back under the recorded name
  restores the row without duplicating it in the history. `repair_drawings.py`
  lives in the agent scratch dir. The wire shape, measured: `{op, spec, runs?}` —
  document under `spec`, a query's records as a top-level SIBLING `runs` (nested
  inside `spec` it is refused with "query needs a 'runs' field"), and the op picks
  the URL PATH.
- **`~/.hermes/.env` had a shell syntax error that broke every tool sourcing it.**
  A value ending in a bare `>` (`JEV_API_KEY=…b7>`) is parsed as a REDIRECTION, so
  `. ~/.hermes/.env` failed with "Syntax error: newline unexpected" — and
  `git-credential-hermesenv` sources that file, so it silently served no
  credential and every `git push` failed with `could not read Username`. The fix
  is to QUOTE the value; a helper that sources a config file inherits every syntax
  error in it.

- **The ambient effects are seeded by the pointer (landed).**
  `app/javascript/aether-entropy.js` is one polled source of randomness: a single
  passive `pointermove` listener (plus a `mousemove`+`touchmove` fallback only for
  an engine without `PointerEvent`) records where and when, and a consumer asks for
  a number when it wants one — `poll()`, `coin()`, `activity()`, `motion()`,
  `stats()`. No timer, no work per event, and no DOM writes of its own: the effects
  keep writing the same custom properties they always did.

  Two consumers. The background particle field draws every spawn value through it
  (a page load's single PRNG sequence was why two visits looked alike) and gains a
  bounded **breeze**: pointer motion bends the field, and the per-axis displacement
  is clamped to the same 0.4 px/frame the spawn already used, so a stirred field is
  never faster than the one that shipped — with the hand still, `activity()` is
  exactly 0 and the field is bit-for-bit the old one. The login orb's sunspot drift
  takes its ebb/flow coin from it and scales the walk step by 0.75x..1.25x
  depending on how busy the last minute was; the `[min, max]` clamp still owns the
  range, and the balance walk is untouched (its direction is state, not a coin).

  Measured on the rendered page: a busy tick walked 0.227s (1.25x, the top of the
  band) and a still tick 0.136s (0.75x, the bottom), both inside the clamp; each
  tick called the polled coin twice and `Math.random` **zero** times. Pinned by
  `pointer_entropy_test.rb`; the ranges themselves by `sunspot_weather_test.rb` and
  `background_budget_test.rb`.

- **The operator surfaces now mirror chopshop-svg's hardened Layer A (landed).**
  `geometry.allow_gradients` became a real Layer A gate on the svg side (a
  two-stop gradient used to pass the source-level gate with zero findings and only
  Layer B's rendered ink count caught it), raster-embed detection widened beyond
  `<image>`, the colour budget learned the implicit black fill and `currentColor`,
  `!important` is ranked, and `filter`/`mask`/`clip-path` references are now a
  NOTE. Four surfaces were brought in line in one pass: the JSON page's
  `allow_gradients`/`allow_raster_embed` hints and their `?` help blocks name the
  gate IDs (`GRADIENT_NOT_ALLOWED`, the broader `RASTER_EMBED`, advisory
  `EFFECT_REFERENCE`); the proof page's cleared-gates checklist carries the
  gradient gate and routes the three advisory tags into its "not cleared" list;
  the About page's Layer A paragraph matches the new counting; and the Run Job
  preset hint states the gradient consequence. No page head, blurb, button or
  column changed.
- **Both builders expose the `-svg` spec keys they used to omit (landed).** The
  `print.prep_expand` sub-keys the pipeline always honoured but the UI never
  offered are wired on the JSON page and the Run Job panel — `filters.keep_alpha`,
  `filters.spec`, `tune.filter_speckle`, `tune.hierarchical`,
  `tune.with_node_reduce`, `node_reduce.tolerance`, `node_reduce.tolerance_cap` —
  each written only when set, so an untouched form still composes the same
  contract. Also added: `print.ramp_min_members` (beside `ink_merge_tolerance`),
  `print.assume_opaque_bg` and `print.prep_colors` (Prep card + the popup's raster
  pass), and `print.substrate` / `print.substrate_index` on the Colour Spec card —
  the fabric colour the runner's `front_common.substrate_hex` implements and the
  proof page already DISPLAYED, with no way to author it until now (an explicit
  `substrate` hex wins over the index; the page keeps them mutually exclusive).
  `validation.variants` can now be a subset request (`{enabled: true,
  transforms: [...]}`) instead of only a bare `true`.
  - Two defaults were wrong and are fixed: the JSON page pre-selected
    `count_white_as_ink: true` against the documented default of false (and
    implied `dark_garment_underbase` with it), and the Run Job default contract
    carried `print.sweep_max_candidates` while the form's own sweep panel writes
    `print.sweep.max_candidates` — two caps in one contract. The default now
    writes the namespaced key only.
  - Three defects the new controls exposed, all fixed: the FLUX popup's raster
    pass read two non-existent elements (`pe_tune_sheet`, `pe_nr_verify`), so every
    tune block it composed silently wrote `contact_sheet: false` and every
    node_reduce block `verify: false`; and a CLEARED speckle box posted
    `filter_speckle: [0]` because `Number('')` is 0 — a sweep axis nobody asked for.
- **The studio's own contract docs now document what the app really calls
  (landed).** `docs/runner-contract.md` had no `/compose` heading and no dataset
  routes although `CompositesController#flatten` POSTs `/compose` through
  `ComposeClient` and the proof page consumes both dataset routes;
  `test/lib/runner_contract_test.rb` then silently omitted them. All three are
  documented (request, response, status codes) and covered in the test as LIVE
  entries, so 15 documented routes == 15 dispatched in `runner.py` == the
  `SURFACES.md` table. The stale "unbuilt" wording for the vector-preserving
  composition is corrected in `docs/agent-surface-gaps.md` (gap 6 and the
  priorities line, history kept) and `docs/game-asset-generation.md`, and the
  About card + README now say a composite holding a vector layer is flattened by
  the runner as vectors.

- Skill publication landed: `sync-skills` now generates a host-tagged copy of
  the working skill into `skills/chopshop-studio/`.
- **Jobs-list preview rule + job-named artifacts — LANDED and LIVE.** The
  thumbnail now shows the run's COLOUR SOURCE (`source.png`) by default and the
  PROOF PNG once a proof has finished (`Job#preview_file` /
  `#preview_from_upload?`, with `proof_preview_file`); the top candidate is no
  longer the default. A job's NAME is part of what it publishes
  (`<name>-candidate-01.svg`, `<name>-proof-01.png/.pdf/.manifest.json`), applied
  at publish time by `chopshop-svg/runner.py`; both spellings resolve, and
  `ApplicationHelper#proof_name` + `ScrapbooksController#kind_from_name` read
  either. Conventions: `docs/ui-conventions.md` ("A job's NAME reaches its
  published filenames"); contract: `docs/runner-contract.md`. Tests:
  `test/controllers/jobs_index_preview_test.rb` (rewritten),
  `test/controllers/proof_naming_test.rb` (new).
- **FLUX registry mirror + proof variants — LANDED and LIVE (`2bc58cd`).**
  `app/models/flux_conf.rb` mirrors
  `~/chopshop-flux`'s three new models (`sana-sprint-0.6b`, `sana-sprint-1.6b`,
  `ssd-1b`), its `MODIFIERS` registry (14 LoRAs) and its `VAES` registry (5
  decoder swaps), and carries `modifier` / `modifiers_for` / `vaes_for` plus
  `validate(modifiers:, vae:)`. `FluxClient.render` and `RunJob` pass
  `modifiers` / `modifier_scales` / `vae` through and the render facts keep
  them. The Run Job flux popup and the JSON builder gained a modifiers
  multi-select, a VAE select and a **Proof variants** opt-in that composes
  `validation.variants`; the proof page grows a **Training set** card when a
  proof's manifest carries a `dataset` key; `GET /jobs/:id/dataset?candidate=…`
  proxies the runner's on-demand `.dataset.7z`. Parity with the sibling repo is
  pinned by `test/lib/flux_repo_parity_test.rb`.

## Blockers

- None known.

## Caveats / known issues

- **A fresh database can be built EITHER way, and `test/lib/schema_drift_test.rb`
  now holds the two in step (#4).** `bin/rails db:migrate` on an empty database
  used to abort at `20260928000500_add_palette_to_composites` with "Could not find
  table 'composites'", because `jobs`, `candidates`, `validations`, `composites`
  and `scrapbook_items` had no create migration of their own — `schema.rb` was
  their only source. Three guarded create migrations
  (`20260927000000_create_studio_core_tables`, `…_create_composites`,
  `…_create_scrapbook_items`) fix that, so replaying migrations now builds a
  complete database; VERIFIED on an empty file: all 21 app tables, and every
  column matching `schema.rb` except the implicit `id`. `bin/rails
  db:test:prepare` (which loads `schema.rb`) remains the faster path for tests,
  and is what the suite itself uses.

  The three are GUARDED on `table_exists?`, so they are a no-op on every existing
  database and on any built from `schema.rb`. They deliberately do NOT create the
  columns that later migrations add (`owner`, `active_job_id`, `steps_state`,
  `sha256`, `palette`): the table is reconstructed as the dump first described
  it and the later migrations build it forward, which is what makes the replay
  produce the dump's schema.

  **`schema.rb` must describe every migration's table, and the reverse**:
  `session_drafts` was missing from it, so every
  hand-off test errored with "Could not find table 'session_drafts'" until it was
  added. `CreateSessionDrafts` is the one migration here that is NOT guarded with
  `table_exists?` — which is exactly why nothing caught the drift, since on a
  database that already has the table it is a silent no-op and on a schema-built
  one it never runs at all. The drift test checks BOTH directions, so the next
  table added in one file and not the other fails the suite rather than waiting to
  be found by hand.

- **The proof page's cleared-gates checklist used to OVER-CLAIM when a ban was
  never on — FIXED (2026-09-29).** It marked a gate CLEARED from the mere absence of
  its finding, so with `geometry.allow_gradients: true` in the job's spec the page
  read "no gradient declaration and no `url(#…)` paint server in the source — flat
  spot colour only" for a check that never ran, and the same over-claim applied to
  `geometry.allow_raster_embed` and the RASTER_EMBED gate.
  `ApplicationHelper#cleared_checks(manifest, spec:)` now gates those two clearances
  on the flag the RUN carried: the manifest first (`stats.static.allow_gradients` —
  the flag is nested under `static`, NOT a top-level `stats.allow_gradients`;
  preflight copies every validate_svg stats key into `stats.static`, including
  `allow_raster_embed` since `982e161`), then the run's own spec — the
  document the studio POSTs at create and the runner re-reads for the back
  half (for manifests written before the flag echo existed). A disarmed or
  unsettleable gate is reported as NOT cleared, never as a pass. Pinned
  by `jobs_list_proof_test.rb` (the rule) and `proof_clearances_test.rb`
  (the served pages: the proof page AND the job results popup).
  **#5 closed 2026-10-06**: both proof-page clearances settle from the
  manifest echo first, spec second, unknown third; the read rule is
  documented in svg's `docs/OVERVIEW.md` (`ba73ee7`) and gap 8 is closed.
- **The expanded-prep bench report is archive-only.** The runner returns
  `prep_expand` in `GET /jobs/:id` and the studio stores no column and renders no
  block for it (a migration plus a block inside the pinned `.results-split` would be
  needed), so the bench an operator paid for is read out of the job download. Both
  studio contract docs state this rather than promising a UI. **Tracked as #7**
  — the open question is block ORDER inside the pinned `.results-split`.
- **THE SUITE IS GREEN ON THIS BOX — measured, not asserted.** Re-measured
  2026-10-06 on HEAD `0613b73`:

  ```bash
  bin/rails test  ->  1327 runs, 13144 assertions, 0 failures, 0 errors, 0 skips
  ```

  The path there: #33 re-pointed the Projects redesign's orphaned index tests
  at the project workspace (they `get jobs_path`, deleted with `GET /jobs`),
  retired 7 pagination/scroll-signal tests with tombstones (the workspace
  lists `@project.jobs.recent` unpaginated), and fixed two real bugs the tests
  found — `jobs_controller#dataset` raising `NoMethodError` on every failure
  path, and composed runs being recorded project-less (and therefore listed
  nowhere). Earlier revisions of this bullet claimed `1148 … 0` (2026-09-29),
  `1162 … 0` (2026-10-01) and a measured red `1332 / 51F / 18E` (2026-10-06
  morning) — all superseded. Re-run before quoting any number.

  The app runs as the `chopshop-rails.service` systemd USER unit (`bin/rails
  server -b 127.0.0.1 -p 3001`), and the ONLY container on the box is
  `chopshop-svg-runner-1` (the pipeline runner, publishing `127.0.0.1:8787`).
  There is no `chopshop-app` container, so any instruction to
  `podman exec chopshop-app …` / `docker exec chopshop-app …` describes an
  environment this box has moved on from.

  Both causes of the old number are ABSENT here, so today's reds are real
  regressions/drift rather than that old noise — know the old causes anyway, so a
  red one is not misread as the container's:
  - **The JEV tests read a path RELATIVE to the repo's parent.**
    `test/controllers/jev_help_test.rb:11` and `JevConf::REMEDIATION_PATH` resolve
    the annotator as `Rails.root.parent.join("chopshop-jev/scripts/…")`. On the
    host the repo is `~/chopshop-studio`, so that is `~/chopshop-jev` — PRESENT
    (`jev_annotate.py`, `jev_remediate.py`). In the container the repo sat at the
    filesystem root, so the identical expression resolved to `/chopshop-jev`,
    which was never mounted. Same code, two paths, only one of them real.
  - **`JsonInjectionTest#test_the_reflected_script_block_is_still_JavaScript`**
    pipes the page's script block to `node --check`, and this box HAS node
    (`/usr/bin/node`, v24.21.0). The container image did not, hence
    `Errno::ENOENT: node` there and a pass here.

  So **anything red on this box is the change's fault** — do not carry the old
  container workaround (copying the two JEV files into a mount) across, and do not
  report the old failure count as the expected baseline.

- **`/jev` reports WHICH DECISION SERVICE answered, and it cannot be a setting.**
  The backend is selected in the RUNNER's environment (`JEV_ENDPOINT`,
  `JEV_API_KEY`, `JEV_MODEL`), which this app does not own, so
  `JevConf::BACKENDS` + `JevConf::SELECTION` document the two backends and
  `PagesController#jev` tallies the endpoint and model each stored answer came
  from (`jev_meta`, bounded to the last 200). A cutover therefore shows up as a
  new provenance line rather than as a config field someone typed — and a
  claim the app cannot verify is exactly what would have gone stale. The local
  backend is `chopshop-jev`'s `deploy/chopshop-laya.{service,env.example}`; the
  full install, cutover and measured numbers are in
  `chopshop-jev/docs/local-decision-service.md`.

- **The FLUX registry is now covered by a cross-repo parity test.**
  `test/lib/flux_repo_parity_test.rb` parses `~/chopshop-flux`'s `models.py` +
  `modifiers.py` with Python's `ast` (stdlib, no import, no torch) and compares
  keys, licences, schedules, commercial-ok flags and resolution rules against
  `FluxConf`. The checkout comes from `CHOPSHOP_FLUX_REPO` (default: the sibling
  at `~/chopshop-flux`); it SKIPS with a reason when there is no checkout or no
  `python3`, and FAILS when a registry the studio mirrors cannot be found. So an
  edit to the flux registry that the studio does not follow breaks this suite
  rather than drifting quietly.
- **The Sana rows' `distilled: true` is not the whole story — and the studio now
  mirrors the rest of it.** `models.py` carries `guidance_embedded: true` for the
  Sana family (guidance is an embedding there and IS honoured, unlike klein's) and
  `resolution_binning: true` (the pipeline re-bins a size it has no bucket for).
  Both are mirrored into every `FluxConf::MODELS` entry, `validate` guards the
  distilled-guidance warning with `!guidance_embedded` and emits the binning
  warning, the `/flux` page's client-side validation mirrors both, and the parity
  test compares both fields — so the two sides cannot drift apart on the two
  facts that decide what the operator is told. Do not key a new behaviour off bare
  `distilled` without asking whether an embedded guidance changes the answer; that
  was the original bug, and it had exactly two behaviour sites (both now fixed).
- **Password-only per-user accounts.** The password IS the identity (no username,
  no LDAP). `User` model + bcrypt; `session[:user_id]`; an `Owned` concern stamps
  `owner` at create and scopes every read, so each user sees only their own jobs,
  validations, scrapbook and composites. Add users with `bin/rails 'users:add[handle,password]'`.
- **THE LEAKED `config/master.key` HAS BEEN PURGED FROM PUBLISHED HISTORY
  (2026-09-29).** It was tracked from the first commit and only untracked later,
  so the key sat in every clone while `config/credentials.yml.enc` sat beside it
  in the same repo — both halves of the pair, publicly. History was rewritten
  (`git filter-branch --index-filter 'git rm --cached --ignore-unmatch
  config/master.key'`) and force-pushed, and the purge was verified from a FRESH
  CLONE OF GITHUB, not from the rewriting copy: the key's blob is absent, no ref
  reaches a `master.key`, and a brute-force scan of every blob in the pack finds
  no object containing the key text. The tip TREE is byte-identical, so no file
  content changed — only the SHA of every commit did.

  **What unpublish does NOT achieve, so do not treat this as closed:**
  - Every clone or fork taken BEFORE the rewrite still contains the key. Rewriting
    history cannot reach into someone else's `.git`.
  - GitHub serves unreachable objects by SHA for a while. The commits are
    unlinked from every ref, but a request to GitHub Support is what forces the
    old objects out of the cache; GC alone does not guarantee it.
  - **Rotation is still the only remedy** (`ready-for-human`, **#6**), and it is
    the one part an agent must not do alone.

  **Why the impact is narrower than the leak looks** — established by measuring,
  not assumed: `credentials.yml.enc` holds EXACTLY ONE key, `secret_key_base`,
  and NO application code reads `Rails.application.credentials` anywhere. This
  deployment signs with `SECRET_KEY_BASE` from the host env file, and the
  `secret_key_base` the leaked key decrypts is a DIFFERENT value from the live one
  (different digests, both 128 chars). So the leaked key unlocks a secret this
  app does not use — an attacker cannot forge the live session cookie with it.

  **The rewrite rewrote every SHA, so SHAs quoted in notes written before
  2026-09-29 are dangling.** The two this note itself used to cite are now
  `6205eee` (root commit, was `e512ae3`) and `3896328` (the untrack commit, was
  `16f8801`); the merge cited below is `de3820b` (was `f4c6c2f`). If a lint or a
  tool reports an unknown revision from an older note, that is why — prefer the
  written fact over the SHA.
- **The credentials pair is RETIRED (2026-10-12, #6).**
  `config/credentials.yml.enc` is deleted from the repo. The store was
  unused by the app — zero references to `Rails.application.credentials`
  in app/ or config/, the deployment signs with `SECRET_KEY_BASE` from
  the host env file, and the container carries no master.key and no
  RAILS_MASTER_KEY — and its key was once public in git history (purged
  2026-09-29, above), so the pair is retired rather than rotated: any
  secret ever stored in that file must be treated as PUBLIC and rotated
  at its provider. There is no deployment step: nothing consumed the
  store, so nothing breaks at boot.
- **No JS build step** (importmap + Propshaft); **Turbo is NOT pinned**, so
  mutating nav must use `button_to method: :delete`, not a `data-turbo-method`
  link.
- **Runner state is in-memory**; a runner restart drops validations, so the
  studio resolves proofs from disk (`job_id` + candidate file), not the stored
  `runner_validation_id`.
- **Jev add-on is optional and advisory**; an unconfigured add-on answers 503
  with a reason (never 404). The key is operator-supplied and lives only in a
  gitignored host-local override + env file.
- **Host-specific detail** (ports, env-file paths, systemd unit, timings) lives
  in `skills/` and is tagged `HOST-SPECIFIC`. The repo's own code stays
  host-agnostic via `CHOPSHOP_RUNNER_<LABEL>_URL`, `CHOPSHOP_EXTRA_HOSTS`, and
  the `@SERVER_NAME@` nginx template.

- **The AM5 runner handoff is superseded, and it opens by telling agents to READ
  IT.** `~/am5-chopshop-rails-handoff.md` (am5 agent, 2026-09-24) lives in the home
  directory, invisible from the repo, and is stale in five measured ways: it names
  a `Job::RUNNERS` hash that no longer exists (runners are env-driven,
  `CHOPSHOP_RUNNER_<LABEL>_URL`/`_KIND`), wires an `am5` runner this box does not
  carry, points at `doc/runner-contract.md` (moved to `docs/`), claims
  `JobsController` still hardcodes `runner = "mock"`, and reserves port **8787**
  for am5 — the port the LOCAL `chopshop-svg-runner-1` container already publishes.
  am5 is not answering on it (`curl 100.125.38.46:8787/health` refused).
  **Tracked as #11**: either rewrite it as a current task or retire the document.

- **`docs/agent-surface-gaps.md` items 4, 5 and 6 are still open** (gap 8 has its
  own caveat above). Each is cross-repo or needs a consent decision, which is why
  the audit left them as prose. **Tracked as #10.**

## Doc layout note (2026-09-28)

`doc/runner-contract.md` moved to `docs/runner-contract.md` (the `doc/` dir is
gone), and `AGENT_USAGE_REPORT.md` was folded into `docs/agent-api.md` (the
canonical studio HTTP driver contract) and then deleted. The cross-repo
orientation now lives in `docs/SYSTEM.md`, `docs/SURFACES.md` and
`docs/README.md`. The `test/lib/runner_contract_test.rb` path was updated and
the suite re-verified.

## Doc-vs-source sweep (2026-09-29)

Every human-facing doc was read against the source it describes. What had gone
stale was not the pointer list but the CLAIMS — all of them about the STATUS
page, which lost its hierarchy when it became a telemetry page:

- **The STATUS page's hierarchy was still being announced.** `README.md` (the
  status bullet), `config/routes.rb` (the `get "status"` comment),
  `docs/SYSTEM.md` (the repo table), `docs/agent-surface-gaps.md` and four
  paragraphs of `app/views/pages/about.html.erb` all described it as drawing
  `source → job → candidate` through the service's `tree` operation, and named
  `chopshop-plot`'s `tree` and `log`. The page asks for `digest` twice and `log`
  once and never for `tree` — pinned structurally by
  `test/controllers/status_page_test.rb`. All five now describe the three panels
  that exist. (The `tree` operation itself is untouched: the service still has
  it, nothing in this app asks for one, and the About page says so.)
- **`chopshop-plot` is `chopshop-bp`.** The service's own repo, remote and
  `SERVICE_NAME` were renamed (its README is titled `chopshop-bp`), and
  `BpConf::SERVICE` already said `chopshop-bp`, so the
  studio's docs naming `chopshop-plot` were the odd ones out. Fixed in README,
  `docs/SYSTEM.md` and `docs/SURFACES.md` (including the section heading and its
  anchor). `docs/game-asset-generation.md` still says `chopshop-plot` — it is a
  dated research report, deliberately left as written, and this line is the map
  to that decision.
- **The runner kinds were one revision behind.** `bp` is the offered blend-plot
  target and `plot`/`blender` are legacy-but-valid (`Job::LEGACY_JOB_KINDS`);
  `README.md` and `docs/SYSTEM.md` (the runner-contract bullets and the env table)
  now say so. `docs/agent-api.md` was already correct — it documents the `bp`
  action and the legacy labels' old shapes — so it was left alone.
- **`docs/SURFACES.md` claimed to be the whole registry and was missing twelve
  studio routes**: `/bp`, `/tournament` and `/tournament/surface`, the six
  `/datasets*` surfaces, `POST /composite/template`,
  `GET /composite/:id/metrics` and `POST /scrapbook/:id/artwork`. (Its page row
  named `/plot` and `/blender` as reference PAGES; they are redirects now.) A
  later pass then missed the Projects redesign's routes — added 2026-10-06
  (`/projects` ×4, `POST /templates/use`). Current count from `bin/rails
  routes` (2026-10-06): **71 rows, 3 of them turbo — 68 HTML/JSON routes, all
  in the file.**
- **Indexes drifted from the directory.** `docs/README.md` said "seven gaps" for
  an eight-gap audit and did not list `docs/step-lists.md`; README's `docs/` list
  omitted it too, and its repo-layout block was missing `datasets`/`engine`
  controllers, five models, three JS files, five `app/lib` clients and
  `mock-runner/runner_deployed.py` (byte-identical to `runner.py`, and referenced
  by `test/lib/runner_serialisation_test.rb` as the deployed copy).
- The one CODE gap in the audit (gap 8, the disarmed-gate over-claim) is fixed
  rather than documented — see the caveats above.

Method, because it generalises: for each doc, list the source files it describes
and check each claim against them (`bin/rails routes` for a route list, the
repo's own README/`SERVICE_NAME` for a name, the view for a page's shape). What
this sweep did NOT do: touch `REVIEW_BRIEF.md` (a finished review brief whose
worktrees are gone — history, not a claim about the app) or rewrite the research
report.
