# AGENTS.md

## Hard policy (read before editing — these are binding)

1. **Jev is optional and advisory.** It never modifies the manifest, never ranks
   candidates, never picks a winner. The deterministic gates in `chopshop-svg`
   stay the source of truth. If a change would make Jev decisive, it is wrong.
2. **The remediation loop is dry-run only.** Steps 1–2 of
   `docs/remediation-loop.md` are done; steps 3–7 are open. `--remediate` must
   refuse (explicit error), never silently no-op, until execution is built.
3. **Never reimplement the annotator.** The runner shells
   `scripts/jev_annotate.py`; do not copy its question set, projection or
   verdict logic into another repo — this suite is the behavioural spec.
4. **An unconfigured add-on answers 503 with a reason, never 404.** 404 means
   "no such route" and sends the operator hunting a wiring bug that does not
   exist.
5. **This repo is private, but host-specific facts are tagged `HOST-SPECIFIC`**
   (paths, this box's env layout) and marked subject to change / removal before
   reuse elsewhere.
6. **Comments are section-level blocks that carry the WHY, not line-by-line
   narration.** Inside a system that spans files or repos, add a small
   `#label-name-function` breadcrumb at the key call sites so a reader can trace
   the thread across the codebase. The breadcrumb is a navigation tag, never a
   restatement of the code.

Work in progress, blockers, and caveats live in `CONTEXT.md` at the root — keep
it current as work lands.

## Agent skills

Repo-specific how-tos live in `docs/agents/` (`standards.md`,
`issue-tracker.md`, `triage-labels.md`, `domain.md`). One `CONTEXT.md` at
the repo root is the single source of context. One `CONTEXT.md` at the repo root is the
single source of context.

### Cross-repo docs

The cross-repo system map, the invocable-surface registry, and the studio's
HTTP driver contract live in `chopshop-studio/docs/` (SYSTEM.md, SURFACES.md,
agent-api.md). Read them for anything that spans repos.
