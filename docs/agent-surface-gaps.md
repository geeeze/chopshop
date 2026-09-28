# Agent-use audit: gaps in guidance, control surfaces, legibility, adaptability

Date: 2026-09-28 · Scope: the whole chopshop system (svg, flux, plot, jev, sui,
studio) driven from an agent's perspective — "poke at the system and find where
it's lacking". This file is the record of that pass, not a fix list. Each gap
names a concrete recommendation; nothing here is fixed by this document.

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
- **The studio's curl-driven path is already documented** — see
  `docs/agent-usage-report.md` (login/upload/create/list/download/cancel/delete
  with the real gotchas: `job[runner]` required, no `RUNNER_TOKEN` on this
  deployment, https `Location` over http loopback, `RAILS_ENV` for inspection).
- **`docs/agents/{issue-tracker,triage-labels,domain}.md` exist in all six
  repos** — those AGENTS.md references are not stale.

## Gaps

### 1. No cross-repo system map (guidance)

Each AGENTS.md scopes to its repo. A fresh agent has no single document that
says "here is the whole chopshop system and how to drive it end to end: raster
→ trace → human picks → proof, with generation (flux), decision sidecar (jev),
metrics/ranking (plot + the triage ranker) and collection (scrapbook) where they
fit". The studio's Hermes skill (`references/repo-fleet.md`,
`references/front-pipeline-dev.md`) sketches this, but it lives in a
Hermes-only skill, not in a repo an arbitrary agent reads.

**Fix:** a root-level `docs/SYSTEM.md` in the studio (the umbrella) — one page,
the six repos, who calls whom, the one-way seams (flux/sui call the pipeline,
never the reverse; jev is advisory), and the end-to-end recipe.

### 2. No "what can I invoke" registry (control surfaces)

The invocable surfaces are real and complete, but scattered:

- svg: `front_pipeline.sh`, `pipeline.sh`, `pick_finish.py`, the individual
  scripts (prep/trace/compare/validate/preflight/snap_colors/node_reduce/
  tune_sweep/im_filters/palette_variants/triage/triage_ranker/run_record).
- flux: `chopshop_flux serve` + client CLI (health/models/generate/edit/
  gen2pipe), 6 HTTP routes (`/health /models /generate /edit /unload`).
- plot: `cli.py` (generate/digest/query/tree/log) + HTTP `/health /generate
  /digest /query /tree /log`.
- jev: `scripts/jev_annotate.py` (shelled by the runner).
- sui: the SwarmUI bridge (stdlib).
- studio: Rails HTTP (jobs, proofs, scrapbook, events, composite, pages) + the
  runner contract (`RunnerClient`).

There is no ONE table of "surface → what it does → input JSON → output". Flux's
`docs/API.md`, plot's `docs/contract.md`, and the studio's
`docs/runner-contract.md` each exist but in three repos. An agent must already
know all six repos exist and grep each.

**Fix:** one `docs/SURFACES.md` (studio, or a top-level index) with the table,
and a pointer from every AGENTS.md.

### 3. The studio's agent-driving contract is not documented in-repo (control surfaces)

The studio is driven over HTTP and has real gotchas — the meta `csrf-token` in
an `X-CSRF-Token` header (a pre-login token goes stale), `Accept:
application/json` only to upload/ask_jev (never `POST /jobs` create, which
returns an HTML 302), `job[runner]` is required, the reference field is the
stored basename. These are captured in the Hermes skill and in
`docs/agent-usage-report.md`, but there is no canonical `docs/agent-api.md` in
the studio, and the studio's own AGENTS.md says nothing about how an agent
drives it.

**Fix:** fold `docs/agent-usage-report.md`'s findings into a canonical
`docs/agent-api.md` (endpoints, the login/CSRF dance, the JSON contract, the
polling note) and link it from AGENTS.md.

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

### 6. Adaptability: composition + collection are not one addressable surface

Creation (flux), tracing (svg), collection (scrapbook), and composition
(`composites_controller`) all exist, but there is no single "recipe" surface
that chains them, and the vector-preserving composite (keep a traced SVG as
vectors, flatten = SVG merge) is direction-confirmed but unbuilt. An agent that
wants "compose sources → trace → collect" hand-orchestrates four surfaces with
no shared contract for the composition step.

**Fix:** a composition/collection recipe endpoint (vector-preserving merge as
the missing "composition" operation), so an agent can drive the whole loop on
one contract.

### 7. No discovery/health aggregate for an agent (legibility + control)

An agent probes each service separately (`/health` on flux and plot, `/up` on
the studio, runner `/health`). There is no single JSON aggregate that says
"flux up, plot up, runner X down, ranker cold-start, N events recorded".

**Fix:** a `GET /engine.json` (the machine-readable twin of the check-engine-
light popup): event counts by kind, job/candidate/scrapbook counts, runner
health map, ranker/bandit state. The footer popup is the human view; this is
the agent view.

## Priorities

- P0: `docs/agent-api.md` in the studio (fix #3, folding in the existing report).
- P0: `docs/SYSTEM.md` + `docs/SURFACES.md` (fix #1, #2).
- P1: `GET /engine.json` aggregate (fix #7).
- P1: de-duplicate the AGENTS.md "Agent skills" block (fix #4).
- P2: document the pipeline schemas in chopshop-svg's own docs (fix #5).
- P2: the composition/collection recipe surface (fix #6).
