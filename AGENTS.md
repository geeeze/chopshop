# AGENTS.md

> **Superseded by [chopshop-flux](https://github.com/geeeze/chopshop-flux).**
> The generation layer moved there (one small HTTP service over its own
> model registry — no SwarmUI, no ComfyUI graph). **Retirement decision
> (2026-10-12, issue #1): this repo is kept for research only — do not
> extend it.** Its remaining value is the facts it pinned down (the
> verified SwarmUI API wire format, the model caveats, the
> binary-trace panic, the workflow research under `docs/`), not a live
> path. The hard policy below is binding on the layer *as it stands*:
> it governs how this repo is read and preserved, and it is not an
> invitation to build on the SwarmUI stack. Archiving the repo remains
> an open option for the human; until they take it, "do not extend"
> is the rule.

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
6. **Comments are section-level blocks that carry the WHY, not line-by-line
   narration.** Inside a system that spans files or repos, add a small
   `#label-name-function` breadcrumb at the key call sites so a reader can trace
   the thread across the codebase. The breadcrumb is a navigation tag, never a
   restatement of the code.

7. **English only.** Every file, comment, doc, string and commit message in this
   repo is English — no CJK (Chinese/Japanese/Korean) characters. Where a parser
   genuinely needs them, write `\uXXXX` escapes, never the literal.

Work in progress, blockers, and caveats live in `CONTEXT.md` at the root — keep
it current as work lands.

## Agent skills

Repo-specific how-tos live in `docs/agents/` (`standards.md`,
`issue-tracker.md`, `triage-labels.md`, `domain.md`). One `CONTEXT.md` at
the repo root is the single source of context.

### Cross-repo docs

The cross-repo system map, the invocable-surface registry, and the studio's
HTTP driver contract live in `chopshop-studio/docs/` (SYSTEM.md, SURFACES.md,
agent-api.md). Read them for anything that spans repos.
