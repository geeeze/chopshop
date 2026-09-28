# AGENTS.md

## Hard policy (read before editing — these are binding)

1. **The seam is one-way.** This layer *calls* the pipeline
   (`chopshop-svg`'s `front_pipeline.sh`/`pipeline.sh`); the pipeline never
   calls it. A workflow the standard flow depends on is no longer opt-in — keep
   generation opt-in and upstream.
2. **It never judges art.** It produces sources and candidates; a human picks.
   Never rank by "looks best."
3. **No LLM ever generates or edits SVG paths** — tracing is VTracer only, and
   an in-graph node (`ChopShopTrace`) is not an exception.
4. **Trace generated images with `colormode=color`, never `binary`** — binary
   mode panics (Rust `CapacityOverflow`) on diffusion output and hangs the queue.
5. **This repo is private and host-specific.** `scripts/SWARMUI_PLAN.md` and the
   model/install paths describe this install; tag host facts `HOST-SPECIFIC` and
   never publish them to the public `chopshop-svg`.

Work in progress, blockers, and caveats live in `CONTEXT.md` at the root — keep
it current as work lands.

## Agent skills

### Issue tracker

Issues for this repo live as GitHub issues; use the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
