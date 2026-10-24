# Domain Docs

How the engineering skills should consume this repo's domain documentation
when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — this single-context repo's one source of
  context: the domain vocabulary, the UI standards (the page-header canon),
  what the Projects redesign settled and what is *still genuinely open*, and
  the measured state of the suite.
- **`docs/SURFACES.md`** — the registry of every route the app serves.
- **`docs/agents/standards.md`** — the binding engineering rules.

There is no `CONTEXT-MAP.md` and no `docs/adr/` in this repo; recorded decisions
live in `CONTEXT.md`. If a file above doesn't exist, **proceed silently** —
don't flag its absence, don't suggest creating it upfront. The
`/domain-modeling` skill creates such files lazily when terms or decisions
actually get resolved.

## The vocabulary this repo uses

Use these words exactly; don't drift to synonyms:

- **Project** — the workspace and the data silo: a stored table (`Project`), the
  app's root (`GET /`), owning sources, jobs, composites and outputs. A job is
  filed INTO a project (`job[project_id]`); one filed without appears in no
  workspace, reachable only by its direct URL.
- **Job** (a *run*) — one dispatch to a runner: a spec, the state machine
  `pending → queued → running → done → error → cancelled`, owned by a project.
- **Sequence** (a *step list*) — a job whose spec carries `steps`: an ordered
  list driven by the **studio** (a runner is stateless and never knows a chain
  exists), one queue slot, one record.
- **Candidate** — one traced SVG a sweep produced, with its gates and fidelity
  readings. Rows are *sorted* by the hand-order rules (fewest hard gates, then
  advisories, then artwork MAE); nothing advances on its own.
- **Proof** — the validated pick. The URL says `/proofs`, the model and
  controller say `Validation` — the URL is the operator-facing vocabulary, the
  code keeps its internal name. Built by Layer A + Layer B.
- **Runner** — a URL and a kind behind the HTTP contract in
  `docs/runner-contract.md`; labels are env-configured
  (`CHOPSHOP_RUNNER_<LABEL>_URL`). Only an `svg` runner traces.
- **Spec / contract** — the JSON document a job is filed with; the JSON page is
  its builder and the Run Job form carries it in a textarea.
- **Template** — a named `PipelineConf::TEMPLATES` preset applied by
  `POST /templates/use`, composing onto whatever the textarea already holds
  rather than replacing it.
- **Composite** and **Scrapbook** — layered artwork assembled in the builder and
  flattened into a job's source raster (vectors go through the svg runner's
  `POST /compose`, never a rasterise-retrace); the Scrapbook is the operator's
  copy-not-reference store feeding both.
- **Source / Output / Tag** — the other container tables. **Caveat (2026-10-06):**
  `Output` rows are never written by any code path and tags have no write path
  yet — read CONTEXT.md's "Still genuinely open" list before relying on either.
- **no-winner** — the load-bearing rule: the studio, the ranker and the bandit
  order and propose; a human picks. Every surface that ranks must stop there.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal,
a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift
to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either
you're inventing language the project doesn't use (reconsider) or there's a real
gap (note it for `/domain-modeling`).

## Flag conflicts with recorded decisions

There are no ADRs here; the settled decisions are in `CONTEXT.md`. If your
output contradicts one of them, surface it explicitly rather than silently
overriding:

> _Contradicts CONTEXT.md's `<settled decision>`, but worth reopening because…_
