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

### 8. A cleared gate is claimed from the ABSENCE of a finding (legibility) — REPORTED, not fixed here

The proof page states its gates positively (the "cleared" checklist), and the
checklist decides "cleared" by a rule NOT appearing in the manifest's findings
(`cleared_checks`, `app/helpers/application_helper.rb:97`; `fired` at `:100`).
That reads correctly only when the rule actually ran — and a rule that the job's
spec DISARMED also produces no finding. Two live cases:

- `app/helpers/application_helper.rb:142` asserts "no gradient declaration and no
  url(#…) paint server in the source — flat spot colour only" whenever
  `GRADIENT_NOT_ALLOWED` is absent. With `geometry.allow_gradients: true` in the
  spec, `check_gradients` returns before checking anything
  (`validate_svg.py:1617`), so the page claims a check that never happened.
- `app/helpers/application_helper.rb:135` asserts "vectors only — no `<image>`,
  no `<feImage>`, no `<foreignObject>` …" whenever `RASTER_EMBED` is absent.
  With `geometry.allow_raster_embed: true`, `check_raster_embeds` is skipped
  entirely (`validate_svg.py:2214`), so the same over-claim applies.

**Fix (not taken here — the checklist lives in a file this pass did not own):**
gate each clearance on the flag the RUN carried, not on the absence of a finding.
For gradients the data is already in the manifest the page renders:
`stats.allow_gradients` and the counts `stats.gradient_definitions` /
`stats.gradient_paint_references` are written either way
(`validate_svg.py:2286`, `:1615`), so the studio can suppress a clearance it did
not earn without a pipeline change. For raster embeds the manifest does NOT echo
the flag (no `stats["allow_raster_embed"]`), so THAT half needs the pipeline to
record it — the same shape of fix, in the other repo.

## Priorities

- ~~P0: `docs/agent-api.md` in the studio (fix #3)~~ — landed, replacing `docs/agent-usage-report.md`.
- ~~P0: `docs/SYSTEM.md` + `docs/SURFACES.md` (fix #1, #2)~~ — landed.
- ~~P1: `GET /engine.json` aggregate (fix #7)~~ — landed, with `test/controllers/engine_json_test.rb`.
- P1: de-duplicate the AGENTS.md "Agent skills" block (fix #4) — partial: the
  `docs/adr/` claim was dropped and cross-repo pointers added where consented;
  jev/sui AGENTS.md edits are still pending consent.
- P1: stop claiming a DISARMED gate as cleared (fix #8) — the gradient half is
  fixable in the studio from the manifest's own `stats.allow_gradients`; the
  raster-embed half waits on the pipeline echoing `allow_raster_embed`.
- P2: document the pipeline schemas in chopshop-svg's own docs (fix #5) — the
  triage/ML stack, `runner-http-contract.md` and the studio JSON branches are
  now documented; verify the `comparison.json`/run-record schema coverage.
- P2: the composition/collection recipe surface (fix #6) — partial: the
  vector-preserving merge landed (svg's `POST /compose`, wired through
  `composite#flatten`); the single chained endpoint is still unbuilt.
