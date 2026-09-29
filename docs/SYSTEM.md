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
| 7 | **the handoff** | the studio | `GET /jobs/:id/download` streams the job's bundle |

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
2. **Upload a raster** — `POST /jobs/upload` (multipart) returns JSON: the stored
   path, a preview URL, the original name and the size.
3. **File the job** — `POST /jobs` with `job[name]`, `job[source_kind]`,
   `job[input_path]`, `job[runner]` and `job[spec]` (a JSON string). The answer
   is a `302` to `/jobs/:id`; follow it.
4. **Poll** — `GET /jobs/:id.json` until `done` is true, or read the job state
   span on the show page.
5. **Read the candidates** — the comparison in `GET /jobs/:id` (HTML) or the
   per-candidate JSON branch; each entry carries its sweep parameters, its hard
   and advisory gate counts, its fidelity numbers and whether it passed.
6. **Pick one** — a proof is created with the runner's `POST /validations`; the
   studio's UI does this as `POST /proofs`.
7. **Collect** — `GET /jobs/:id/download` for the bundle,
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
| `CHOPSHOP_PASSWORD` / the users table | who may sign in (password-only identity) |
| `PIPELINE_LEARNING_DIR` | where the pipeline keeps its learned ranker and bucket files |
| `CHOPSHOP_FLUX_*`, `CHOPSHOP_PLOT_*`, `CHOPSHOP_BLENDER_*` | each service's own bind/port/token/out-dir |

If you find yourself wanting to write a hostname into a file in any of these
repos, the answer is an environment variable and a label.

---

## Where to go next

| you want | read |
|---|---|
| the full list of things you can call, with input/output shapes | [`SURFACES.md`](SURFACES.md) |
| how to drive the studio over HTTP as an agent | [`agent-api.md`](agent-api.md) |
| the runner contract in full | [`runner-contract.md`](runner-contract.md) |
| how the studio looks and reads | [`ui-conventions.md`](ui-conventions.md) |
| the audit this documentation set answers | [`agent-surface-gaps.md`](agent-surface-gaps.md) |
| the index | [`README.md`](README.md) |
