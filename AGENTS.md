# AGENTS.md

## Hard policy (read before editing — these are binding)

1. **Production Rails does not hot-reload.** The live app runs Puma under the
   `chopshop-rails.service` systemd USER unit. After ANY change that touches
   `app/` or `config/`, or any `git pull` that brings such changes, restart the
   service (`systemctl --user restart chopshop-rails.service`) and verify the
   served page BEFORE reporting the change as done. A process started between
   two of a feature's file writes serves the old checkout and 500s on routes and
   constants that are already in the tree and green in tests — that is a stale
   process, not a code bug. Do not chase the code first.
2. **The unit of done is the live page, not the edited file and not a green
   suite.** Deploy (precompile + restart) and assert on the served response as
   part of the same edit. "Done" means the operator is looking at the new page.
3. **Design minutiae live at their root of origin.** Title/subtitle structure,
   button sizes, fonts, and the rest of the UI conventions are owned by
   `docs/ui-conventions.md` in this repo — edit them THERE, not ad hoc in a
   view. A one-off inline change to a font size or button shape is a bug against
   the convention, not a new rule.
4. **This repo is private, but its code stays host-agnostic.** Runner
   labels/URLs come from `CHOPSHOP_RUNNER_<LABEL>_URL`, `config.hosts` extras
   from `CHOPSHOP_EXTRA_HOSTS`, and the nginx template is `@SERVER_NAME@` — no
   machine is hardcoded. Host-specific deployment facts (paths, ports, timings,
   this box's deploy steps) belong in the `HOST-SPECIFIC`-tagged skill material
   (`skills/`), not in `app/`.
5. **`chopshop-svg` is PUBLIC.** Never push hostnames, IPs, VPN names, or
   SwarmUI/ComfyUI references there. See `sync-skills` and the README.
6. **Comments are section-level blocks that carry the WHY, not line-by-line
   narration.** Inside a system that spans files or repos, add a small
   `#label-name-function` breadcrumb at the key call sites so a reader can trace
   the thread across the codebase. The breadcrumb is a navigation tag, never a
   restatement of the code.

Work in progress, blockers, and caveats live in `CONTEXT.md` at the root — keep
it current as work lands.

## Agent skills

### Issue tracker

Issues for this repo live as GitHub issues; use the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
