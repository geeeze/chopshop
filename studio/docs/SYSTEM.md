# The chopshop system — a cross-repo map

One page for an agent or operator who has just discovered **one** of these repos
and needs to know what the whole thing is, how a raster becomes a proof, and
which direction each seam runs.

The system turns a source image into **print-ready vector artwork a human has
chosen**. That sentence is the whole design, and everything below is machinery
for it:

- **A human always picks.** No part of this system ranks by "looks best", scores
  a winner, or takes a decision away from a person. Machines *order* and
  *measure*; the operator chooses. A surface that picks has broken the system,
  not improved it.
- **Tracing is deterministic.** Vectorisation is VTracer's, through a parameter
  sweep. No LLM ever generates or edits SVG path data.
- **Sidecars are advisory.** The decision sidecar (jev) and the generators
  (flux, sui) inform the pipeline and never decide for it.

This document is host-agnostic on purpose: it names no host, no address, no
absolute path. A deployment is a set of labels and environment variables, and
everything here is written so that adding a machine is configuration rather than
an edit (see *Configuration* below).

---

## The six repos

| repo | what it is | what it does | speaks | visibility |
|---|---|---|---|---|
| **chopshop-svg** | the pipeline | raster → prep → VTracer sweep → candidates → two print gates → proof. Also the **runner service** (`runner.py`) that runs those stages on demand. | runner contract over HTTP; `front_pipeline.sh` / `pipeline.sh` on the box | public (reference project) |
| **chopshop-studio** | the control surface | the Rails GUI and the **only orchestrator**: files jobs, drives runners, records the human's actions, shows the results. | runner contract (as a client); browser HTTP + JSON | private |
| **chopshop-bp** | the blend-plot service (renamed from `chopshop-plot`) | JSON documents in, SVG (or a rendered 3D frame) out: geometry, metric charts, cross-run queries, the STATUS page's digest and log drawings, and a headless-Blender 3D operation. One service, two halves — `plot` draws, `blend` renders. | its own contract over HTTP (`serve`), plus a CLI | private |
| **chopshop-flux** | the generator | text (and image + text) → raster, on one GPU, with licences attached to every model. | its own standard HTTP API (`/generate`, `/edit`, …) | private |
| **chopshop-jev** | the decision sidecar | reads a rendered preflight manifest and answers four narrow, advisory questions about *what kind* of print problem a file has. Writes a `<stem>.jev.json` sidecar. | a script the runner shells out to; an outbound decision-service call | private |
| **chopshop-sui** | superseded generator bridge | the earlier SwarmUI integration (generate / img2img / gen2pipe). Kept for the record; **superseded by chopshop-flux**. | SwarmUI's own HTTP API | private |

Only **chopshop-studio** orchestrates. Everything else is a capability the studio
calls, or a capability a human runs by hand.

### Where each piece sits in the flow

```
  ┌───────────────┐
  │  an operator  │  drags a raster in (or asks for one)
  └───────┬───────┘
          │  POST /jobs  (runner = an svg runner label)
          ▼
  ┌──────────────────────── chopshop-studio ────────────────────────┐
  │  files the job, queues it (one worker, one job at a time),      │
  │  polls the runner, records every human action as an Event       │
  └───────┬─────────────────────────────────────────────────────────┘
          │  runner contract: POST /jobs {name, input_path, spec}
          ▼
  ┌────────────────────── chopshop-svg runner ──────────────────────┐
  │  front_pipeline.sh                                              │
  │    prep  →  trace sweep  →  compare (Layer A + Layer B)         │
  │      ▲            ▲              ▲                              │
  │      │            │              └── chopshop-bp's metrics      │
  │      │            └── VTracer (colormode=color)                 │
  │      └── raster prep (filters, upscale)                         │
  │                                                                 │
  │  → a RANKED comparison of candidate SVGs (never a winner)       │
  └───────┬─────────────────────────────────────────────────────────┘
          │  GET /jobs/:id  → comparison.json
          ▼
  ┌──────────────────────── chopshop-studio ────────────────────────┐
  │  the candidate table: the human studies, stars, recolours,      │
  │  deletes, and PICKS ONE                                          │
  └───────┬─────────────────────────────────────────────────────────┘
          │  runner contract: POST /validations {job_id, candidate_file}
          ▼
  ┌────────────────────── chopshop-svg runner ──────────────────────┐
  │  pipeline.sh on the chosen candidate                            │
  │    Layer A  validate_svg.py   (source-level, fast)              │
  │    Layer B  preflight.py      (rendered, measured)              │
  │  → 05_final/ manifest.json + the proof (PNG + print PDF)        │
  │                          │                                      │
  │                          └─→ chopshop-jev may annotate it        │
  │                              (advisory only, never a verdict    │
  │                               over the gates)                   │
  └───────┬─────────────────────────────────────────────────────────┘
          │  GET /jobs/:id/archive   (the job directory as a 7z)
          ▼
     the operator has a proof and a bundle to hand over
```

Generators feed the **top** of that flow and are never called back:

```
  chopshop-flux  ──raster──▶  the pipeline's input
  (prompt, or an edited reference)
```

## The data flow, stage by stage

| # | step | produced by | artefact |
|---|---|---|---|
| 1 | **source** | the operator, or a generator (flux) | a PNG/JPEG uploaded into the studio's uploads, or a runner-local path |
| 2 | **prep** | `front_pipeline.sh` → `prep_raster.py` | a normalised PNG, plus its colour-inverted twin (`source.inverse.png`) |
| 3 | **trace** | `front_pipeline.sh` → `trace_sweep.py` (VTracer) | N *candidate* SVGs from N parameter combinations |
| 4 | **compare** | `front_pipeline.sh` → `compare_candidates.py` | `comparison.json`: every candidate with its sweep parameters, its Layer A findings, its Layer B readings, its fidelity numbers and a pass/fail |
| 5 | **the pick** | **a human**, in the studio | one candidate chosen, recorded as an `Event` (`pick`) |
| 6 | **the proof** | `pipeline.sh` on that candidate | `05_final/<stem>.manifest.json`, a rendered proof PNG, a print PDF, and a per-candidate 7z — plus the same artefacts written attributable to their source under `05_final/<artwork-stem>/` (stem-carrying run-unique copies as well as the canonical flat names the runner's routes read) |
| 7 | **the handoff** | the studio | `GET /jobs/:id/download` streams the job's bundle (a bp/plot/blender draw with no runner job gets the studio's own `StudioArchive`; a job holding nothing gets no Download button at all) |

**The pick is the product.** Steps 2–4 and 6–7 exist to give a human something
worth choosing between and to prove that what they chose prints.

## The runner contract

The studio drives chopshop-svg over HTTP through one small contract: create a
job, poll it, cancel it, delete it, read a candidate's file, ask for a proof,
ask the decision sidecar, and merge a composite's layers into one SVG with the
vectors intact (`POST /compose`). It is written down in full — routes, payloads,
status codes — in **[`runner-contract.md`](runner-contract.md)**, which is the
authoritative version. The shape, in brief:

- **A runner is a label, not a machine.** `Job.runners` is built from the
  environment (`CHOPSHOP_RUNNER_<LABEL>_URL`), each label carrying a **kind**
  (`svg` | `flux` | `bp` | the legacy `plot` / `blender`) from
  `CHOPSHOP_RUNNER_<LABEL>_KIND`. The studio's dropdown is keyed off that, so
  nothing in any repo has to name a host.
- **Only an `svg` runner is a pipeline runner.** It is the one that traces, holds
  job state and produces candidates. `flux` and `bp` are Run Job *targets* (they
  generate a raster, draw a document, render a frame) but they speak their own
  service APIs and are never offered as a hand-off target. `plot` and `blender`
  are the same blend-plot service under its older labels: still valid on a job
  that was already filed against one, no longer offered for a new job.
- **The job directory is the unit of delivery.** Everything a job produces is
  written inside it, because the download archives that directory and the delete
  removes it.
- **Auth is optional and one-way.** If `RUNNER_TOKEN` is set, the studio sends it
  as a bearer token; a runner without it configured accepts unauthenticated
  calls. A deployment may run either way.

## The one-way seams

These are the rules that keep the system comprehensible. They are load-bearing,
not stylistic.

1. **flux → pipeline, never back.** The generator produces a raster and hands it
   to the pipeline (the studio stores it as an ordinary upload and files a
   pipeline job). The pipeline never calls flux. The generator holds no job
   state, no candidates and no archive — which is exactly why the studio builds
   its own bundle for a flux job.
2. **sui → pipeline, the same way, and sui is retired.** The SwarmUI bridge was
   the original version of that seam. chopshop-flux replaced it; sui stays
   unpublished-in-spirit and unmaintained.
3. **jev is advisory, full stop.** It annotates a manifest the operator already
   chose. It never overrides a gate, never ranks candidates and never picks a
   winner. A runner with no decision service configured refuses the request
   honestly (`503`, "the add-on is not configured here") rather than pretending
   the route does not exist.
4. **bp is a function, not an orchestrator.** JSON document in, SVG (or a
   rendered frame) out. The studio calls it for the STATUS page's drawings and
   as a `bp` job target (the legacy `plot`/`blender` labels address the same
   service); it calls nothing back.
5. **The studio orchestrates; the pipeline works.** Only the studio knows about
   jobs, owners, queues and the event log. The pipeline is a set of commands a
   runner executes.
6. **No repo reaches into another's store.** Each repo owns its own files; the
   seams are HTTP payloads and files inside a job directory.

## The end-to-end recipe (what an agent does)

The full, verified version with every gotcha is in
**[`agent-api.md`](agent-api.md)**. In outline:

1. **Log in** — `POST /login` with the operator's password (the password *is*
   the identity) and a cookie jar; keep the jar for every later request.
2. **Pick (or create) a project** — `GET /` is the Projects index (each card
   links its workspace); `POST /projects` with `project[name]` makes a new one.
   Projects are the workspace/data silo: a job, composite or output belongs to
   one, and each workspace lists only its own jobs.
3. **Upload a raster** — `POST /jobs/upload` (multipart) returns JSON: the stored
   path, a preview URL, the original name and the size.
4. **File the job** — `POST /jobs` with `job[name]`, `job[source_kind]`,
   `job[input_path]`, `job[runner]`, `job[spec]` (a JSON string) and
   `job[project_id]` (from step 2 — a job filed without one appears in no
   workspace, only at its direct URL). The answer
   is a `302` to `/jobs/:id`; follow it.
5. **Poll** — `GET /jobs/:id.json` until `done` is true, or read the job state
   span on the show page.
6. **Read the candidates** — the comparison in `GET /jobs/:id` (HTML) or the
   per-candidate JSON branch; each entry carries its sweep parameters, its hard
   and advisory gate counts, its fidelity numbers and whether it passed.
7. **Pick one** — a proof is created with the runner's `POST /validations`; the
   studio's UI does this as `POST /proofs`.
8. **Collect** — `GET /jobs/:id/download` for the bundle (the studio builds it
   as `StudioArchive` when there is no runner job to proxy),
   `GET /jobs/:id/file/:name` for a single artefact.

To see the state of everything at once, an agent asks the studio for
**`GET /engine.json`**: runner health per label, the owner's event counts by
kind, what the pipeline has produced (`use`), the host's newest CPU/memory/swap
sample and whether the sampler is still running (`host`), and the ranker's
cold/live state. That endpoint is the machine-readable twin of the footer's
check-engine light.

## Configuration, not facts

Every join in the system is an environment variable, so a deployment is described
by values rather than by names baked into code:

| variable | meaning |
|---|---|
| `CHOPSHOP_RUNNER_<LABEL>_URL` | adds a runner; the label is the env name lower-cased |
| `CHOPSHOP_RUNNER_<LABEL>_KIND` | `svg` (default) / `flux` / `bp` / the legacy `plot` / `blender` |
| `RUNNER_TOKEN` | the bearer token the studio sends to runners (optional) |
| `CHOPSHOP_FLUX_HANDOFF_RUNNER` | which pipeline runner a flux job's raster goes to |
| the `users` table (`bin/rails 'users:add[handle,password]'`) | who may sign in (password-only identity; the old `CHOPSHOP_PASSWORD` env var is no longer read) |
| `PIPELINE_LEARNING_DIR` | where the pipeline keeps its learned ranker and bucket files |
| `CHOPSHOP_FLUX_*`, `CHOPSHOP_BP_*`, `CHOPSHOP_BLENDER_*` | each service's own bind/port/token/out-dir |
| `CHOPSHOP_GITHUB_TOKEN` | a PAT with `issues: write`, so the footer's report popup can file. Unset ⇒ the popup still opens and still says it is unconfigured, and keeps the typed report on screen rather than pretending to file it |
| `CHOPSHOP_GITHUB_REPO` | which repository those issues are filed against (`owner/name`; defaults to `geeeze/chopshop-studio`) |

If you find yourself wanting to write a hostname into a file in any of these
repos, the answer is an environment variable and a label.

**Where a deployment keeps them matters.** The studio reads the systemd unit's
`EnvironmentFile` (on the live box `/home/unodos/.chopshop-studio.env`), which is
a DIFFERENT file from the agent's own `~/.hermes/.env`. A token added only to the
agent's file is invisible to the app, and the app's own guard reports exactly
that — the report popup says filing is not configured rather than failing
quietly — so the two can be told apart by what the operator sees. Copy the value
across; do not symlink one to the other, because the two files are edited for
different reasons.

---

## The queue and its recurring work

One worker, pinned to `queues: "runs"` (`config/queue.yml`) — the serial
gatekeeper that guarantees no two runs hit a runner at once, and the reason the
DB pool is exactly sized (3 Puma threads + 2 queue processes = 5). The
recurring tasks (`config/recurring.yml`) — finished-job pruning, the host
sampler, the stranded-run reaper — **must each name `queue: runs`**: Solid
Queue's default `solid_queue_recurring` queue is worked by nobody here, so a
task without the line dispatches, looks healthy, then sits `ready` forever
(measured before the fix: 30 such jobs, 0 failed, hourly pruning never once
executed). That is enforced at boot by
`config/initializers/recurring_queue_guard.rb`, which checks every environment
section against the worker's own `queues:` list and refuses to boot on a
mismatch — proven by `test/lib/recurring_queue_guard_test.rb`, because an
initializer is the one place the app cannot otherwise be tested. The one
recurring failure the guard cannot catch — a task that ran but stopped writing —
is monitored instead: the engine JSON reports `stale` from `HostSample.stale?`
(pinned by `test/controllers/engine_json_test.rb`).

**Purging a stale ready backlog.** Solid Queue runs every `ready` recurring job
it finds on restart and timestamps each execution `now` — so a backlog
accumulated while the worker was stopped fires its command in a burst at boot,
each row stamped as if it had just run (31 were deleted by hand before the
restart on 2026-09-29). A ready backlog is a `solid_queue_ready_executions`
row joined to its `solid_queue_jobs` row; on the production sqlite database:

```bash
# count the backlog first (expect 0 on a quiet box)
sqlite3 storage/production.sqlite3 \
  "select count(*) from solid_queue_ready_executions e join solid_queue_jobs j on j.id = e.job_id where j.class_name = 'SolidQueue::RecurringJob';"
# then clear it — executions first, then their jobs
sqlite3 storage/production.sqlite3 \
  "delete from solid_queue_ready_executions where job_id in (select j.id from solid_queue_jobs j where j.class_name = 'SolidQueue::RecurringJob' and j.finished_at is null);
   delete from solid_queue_jobs where class_name = 'SolidQueue::RecurringJob' and finished_at is null;"
```

Delete only the backlog, never `solid_queue_recurring_tasks` — those rows are
the task DEFINITIONS, and losing them stops the sampler and the pruning with
the same silence the queue guard exists to prevent.

## Retired plans

**The AM5 pipeline handoff (superseded 2026-10-10).** `~/am5-chopshop-rails-handoff.md`
(written by the am5 agent, 2026-09-24) told an agent to add an `am5` entry to a
`Job::RUNNERS` hash and build the chopshop-svg pipeline on am5 at
`100.125.38.46:8787`. Every premise is now false, so it is retired, not deployed:

- `Job::RUNNERS` does not exist — runners are env-driven
  (`CHOPSHOP_RUNNER_<LABEL>_URL`, hard policy in `AGENTS.md`; see *Configuration,
  not facts* above).
- No am5 runner is wired; am5 is used only for **flux** (`CHOPSHOP_RUNNER_FLUX_URL`
  → `100.125.38.46:8795`), not the pipeline.
- The pipeline runs **locally in a container** — `chopshop-svg-runner-1`
  (`chopshop-svg:0.1.0`) publishes `127.0.0.1:8787`, the very port the handoff
  reserved for am5. am5 is not answering on 8787.
- The paths it names moved: the contract is `docs/runner-contract.md` (there is no
  `doc/` directory), and `JobsController` no longer hardcodes `runner = "mock"`.

The local container superseded the am5 plan. The home-directory file is invisible
to anyone reading the repo, which is why the outcome is recorded here. If running
the pipeline on am5 is ever intended again, write it as a task against the current
env-driven topology — do not resurrect that document.

## Where to go next

| you want | read |
|---|---|
| the full list of things you can call, with input/output shapes | [`SURFACES.md`](SURFACES.md) |
| how to drive the studio over HTTP as an agent | [`agent-api.md`](agent-api.md) |
| the runner contract in full | [`runner-contract.md`](runner-contract.md) |
| how the studio looks and reads | [`ui-conventions.md`](ui-conventions.md) |
| the audit this documentation set answers | [`agent-surface-gaps.md`](agent-surface-gaps.md) |
| the index | [`README.md`](README.md) |
