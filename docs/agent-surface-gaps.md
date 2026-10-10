# Agent-use audit: gaps in guidance, control surfaces, legibility, adaptability

Date: 2026-09-28 · Scope: the whole chopshop system (svg, flux, bp, jev, sui,
studio) driven from an agent's perspective — "poke at the system and find where
it's lacking". This file is the record of that pass. Each gap names a concrete
recommendation, and each carries its own STATUS, which is updated as the work
lands: a gap marked CLOSED names what fixed it and the test that pins it, so the
list can be read as a live ledger rather than a snapshot of the day it was
written.

## What's already good

- **Per-repo AGENTS.md files exist and the svg one is exemplary** — the
  "never picks a winner" rule, the human decision point, hard rules, measured
  environment facts, and the container story are all there.
- **Machine-readable outputs are rich** — run_record `.run.json`, the
  `comparison.json` candidate dict, the proof `manifest.json`, flux render
  facts, and the studio's `GET /events` JSON.
- **Runners are env-driven** — `CHOPSHOP_RUNNER_<LABEL>_URL` adds a runner with
  no code change; model/chart registries (`models.py`, `docs/contract.md`) are
  the same pattern.
- **The studio's curl-driven path is now documented** — see
  `docs/agent-api.md` (login/upload/create/list/download/cancel/delete with the
  real gotchas: `job[runner]`, the CSRF dance, `Accept: application/json` only
  where JSON is served, https `Location` over http loopback).
- **`docs/agents/{issue-tracker,triage-labels,domain}.md` exist in all six
  repos** — those AGENTS.md references are not stale.

## Gaps

### 1. No cross-repo system map (guidance) — CLOSED

Each AGENTS.md scopes to its repo. A fresh agent has no single document that
says "here is the whole chopshop system and how to drive it end to end: raster
→ trace → human picks → proof, with generation (flux), decision sidecar (jev),
metrics/ranking (plot + the triage ranker) and collection (scrapbook) where they
fit".

**Fixed:** `docs/SYSTEM.md` (studio) is the cross-repo map — six repos, who
calls whom, the one-way seams, the end-to-end recipe — and the studio's
`AGENTS.md` links it.

### 2. No "what can I invoke" registry (control surfaces) — CLOSED

The invocable surfaces are real and complete, but were scattered across the
six repos. **Fixed:** `docs/SURFACES.md` (studio) is the one table of
"surface → what it does → input JSON → output" across svg/flux/plot/jev/sui/
studio, and the studio's `AGENTS.md` links it.

### 3. The studio's agent-driving contract is not documented in-repo (control surfaces) — CLOSED

The studio is driven over HTTP and has real gotchas — the meta `csrf-token` in
an `X-CSRF-Token` header, `Accept: application/json` only to upload/ask_jev
(never `POST /jobs` create, which returns an HTML 302), `job[runner]`
semantics, the reference field as the stored basename. **Fixed:** these are now
in the canonical `docs/agent-api.md` (which folded in and replaced
`docs/agent-usage-report.md`, deleted), and `AGENTS.md` links it.

### 4. AGENTS.md boilerplate drift (guidance)

jev and sui AGENTS.md are thin and near-identical; the "Agent skills → issue
tracker / triage labels / domain docs" block is copied verbatim across four
repos. jev's AGENTS.md never tells an agent the annotator contract (the 503-vs-
404 rule, the dry-run remediation) in agent terms; sui's is barely
repo-specific.

**Fix:** keep repo-specific orientation; reference the shared block instead of
copying it (a shared `docs/agents/` pointer), so a change in one place stops
four copies drifting.

### 5. Legibility: the studio is HTML-first, JSON is per-route and undocumented

An agent wants JSON. The pipeline writes it well (`run_record.py`,
`comparison.json`, `manifest.json`), and the studio has `format: :json`
branches — `GET /jobs/:id.json` exposes a `done` boolean and per-candidate
detail (sweep entry + proof manifest). But the JSON shape is not in any
contract doc, and the pipeline's `comparison.json` shape is documented in the
studio's Hermes skill (`references/candidate-triage.md`), not in chopshop-svg's
own `docs/`.

**Fix:** document the studio's JSON branches and the pipeline's run-record /
comparison schema in the repos themselves, so a non-Hermes agent can find them.
**STATUS 2026-10-10:** the studio's `GET /jobs/:id.json` branches are now
documented in `docs/jobs-json.md`; the pipeline's `comparison.json` and
run-record schemas are documented in `chopshop-svg/docs/pipeline-schemas.md`.

### 6. Adaptability: composition + collection are not one addressable surface

Creation (flux), tracing (svg), collection (scrapbook), and composition
(`composites_controller`) all exist, but there is no single "recipe" surface
that chains them, and the vector-preserving composite (keep a traced SVG as
vectors, flatten = SVG merge) — **LANDED 2026-09-29**: the svg runner's
`POST /compose` merges layers as vectors, the composite's `GET
/composite/:id/recipe` is the one document an agent reads to drive it, and
`POST /composite/:id/flatten` uses it so a trace is never rasterised and
re-traced (pinned by `test/controllers/composite_recipe_test.rb`). The recipe
surface itself is still not one addressable chained endpoint. An agent that
wants "compose sources → trace → collect" now has a shared contract for the
composition step, but still hand-orchestrates the other three.

**Fix:** a composition/collection recipe endpoint — the vector-preserving merge
it asked for LANDED as `POST /compose`; what is still missing is the single
chained endpoint, so an agent can drive the whole loop on one contract.

### 7. No discovery/health aggregate for an agent (legibility + control) — CLOSED

An agent probed each service separately (`/health` on flux and plot, `/up` on
the studio, runner `/health`). **Fixed:** `GET /engine.json` is the
machine-readable aggregate (runner health map, owner-scoped event counts,
ranker state) — the twin of the check-engine-light popup, login-gated and
pinned by `test/controllers/engine_json_test.rb`.

### 8. A cleared gate is claimed from the ABSENCE of a finding (legibility) — CLOSED 2026-10-06

The proof page states its gates positively (the "cleared" checklist), and the
checklist decided "cleared" by a rule NOT appearing in the manifest's findings
(`cleared_checks`, `app/helpers/application_helper.rb`; `fired` there). That
reads correctly only when the rule actually ran — and a rule that the job's spec
DISARMED also produces no finding. Two live cases:

- `geometry.allow_gradients` true in the spec makes `check_gradients` return
  before checking anything (`validate_svg.py:1617`), so the page claimed "no
  gradient declaration and no url(#…) paint server in the source — flat spot
  colour only" for a check that never happened.
- `allow_raster_embed` true skips `check_raster_embeds` entirely
  (`validate_svg.py:2214`), so the same over-claim applied to "vectors only".

**FIXED 2026-09-29, both halves, with no pipeline change.**
`cleared_checks(manifest, spec:)` now gates each of those two clearances on the
flag the RUN actually carried, and reports a DISARMED or unsettleable one in the
"not cleared" list instead of as a pass:

- **the manifest first**, because it is the run's own record. NOTE the nesting:
  the flag is `stats.static.allow_gradients`, not a top-level `stats.allow_gradients`
  — `preflight.py` nests the whole `validate_svg.validate()` stats dict under
  `stats.static`, so this pass's original cite of `validate_svg.py:2286` was right
  about the file and wrong about the path an agent would read it at. The gradient
  COUNTS written alongside it (`gradient_definitions`, `gradient_paint_references`)
  are written whether or not the gate is armed, so they say nothing about arming —
  only the flag does.
- **the run's own spec second**, for what the manifest does not settle: older
  manifests that predate the flag echo. (The 2026-09-29 note here said the
  pipeline did not echo `allow_raster_embed` — "confirmed against
  `validate_svg.py`". That was true when written and false since 2026-09-30,
  when svg's `982e161` added it: `stats["allow_raster_embed"]` is now written
  alongside `allow_gradients`, and `preflight.py` copies both into
  `stats.static`.) The spec read is the run's, not an inference: the studio
  POSTs `job.spec` at create and the runner re-reads that same document for the
  back half, so it is the document the run was made with. It is read with the
  pipeline's own defaults (absent means false, i.e. the gate is ON), and a step
  list's own `svg` block is read too, because a chained job keeps its tracing spec
  inside the step.
- a flag neither source settles leaves the gate UNKNOWN, which is reported as not
  cleared — never as a pass.

Pinned by `test/controllers/jobs_list_proof_test.rb` (the resolution rule, both
flags, the step-list case) and `test/controllers/proof_clearances_test.rb` (the
SERVED pages: a disarmed gate reads as not cleared on the proof page and in the
job results popup, and an armed one still reads as cleared).

**2026-10-06 follow-up (chopshop-studio#5 closure):** both gates now settle
from the manifest echo FIRST — `run_gate_flags` reads `stats.static`'s
`allow_gradients` and `allow_raster_embed` alike — the run's spec second, and
unknown third. The "owed in the other repo" line is paid: svg's
`982e161` (2026-09-30) already echoes `allow_raster_embed` into the manifest
stats, and the svg side now documents the echo and the read rule in
`docs/OVERVIEW.md` (`ba73ee7`). New cases in `jobs_list_proof_test` pin the
manifest-only armed and disarmed raster gates and the pre-echo-manifest
unknown.

## Priorities

- ~~P0: `docs/agent-api.md` in the studio (fix #3)~~ — landed, replacing `docs/agent-usage-report.md`.
- ~~P0: `docs/SYSTEM.md` + `docs/SURFACES.md` (fix #1, #2)~~ — landed.
- ~~P1: `GET /engine.json` aggregate (fix #7)~~ — landed, with `test/controllers/engine_json_test.rb`.
- P1: de-duplicate the AGENTS.md "Agent skills" block (fix #4) — partial: the
  `docs/adr/` claim was dropped and cross-repo pointers added where consented;
  jev/sui AGENTS.md edits are still pending consent.
- ~~P1: stop claiming a DISARMED gate as cleared (fix #8)~~ — LANDED 2026-09-29,
  both halves, with no pipeline change: `cleared_checks` gates the gradient and
  raster-embed clearances on the flag the run carried, resolved from the manifest
  (`stats.static.allow_gradients`) and then from the run's own spec. Pinned by
  `test/controllers/jobs_list_proof_test.rb` and `proof_clearances_test.rb`. The
  one thing still worth doing is in the OTHER repo: echo `allow_raster_embed` in
  the manifest, so the raster half stops depending on the studio's copy of the spec.
- P2: document the pipeline schemas in chopshop-svg's own docs (fix #5) — the
  triage/ML stack, `runner-http-contract.md` and the studio JSON branches are
  now documented; verify the `comparison.json`/run-record schema coverage.
- P2: the composition/collection recipe surface (fix #6) — partial: the
  vector-preserving merge landed (svg's `POST /compose`, wired through
  `composite#flatten`); the single chained endpoint is still unbuilt.
