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
7. **`storage/production.sqlite3` is live data, and the only copy is this disk.**
   It is the studio's real database — users, jobs, ~60k `prompt_sources` — open by
   the running Puma. **Never delete, reset, truncate, or `db:`-drop it**, and never
   treat it as scratch. If it goes, the ONLY recovery is a `.bak-*` sibling or a
   copy you made yourself; there is no upstream to pull from. Before any operation
   that could touch it, copy it *together with its `-wal` and `-shm` siblings* to a
   timestamped path outside `storage/`. After any restore, do not trust the file's
   existence or its size — compare `md5sum` against the source, run
   `pragma integrity_check`, and count rows. A file recreated to the same byte
   count is not a restore until its contents prove it.
8. **Pin every Python dependency; a bare host venv is not a pin.** The mock runner
   ran from a venv whose `bin/python` symlinks to `/usr/bin/python3`, so a system
   Python upgrade moved it off its own `site-packages` and cost it Pillow with no
   error at all — 799 restart-loop failures that systemd reported only as
   `status=1/FAILURE`. It is now the `chopshop-mock-runner` container with a
   pinned `requirements.txt` and a build-time import check, so a broken dep is a
   failed build rather than a silent crash loop. For anything new: container, or at
   minimum a `requirements.txt` with versions in it. Never a venv you built and
   forgot.
9. **A purged secret rewrites every SHA, so every pre-purge clone diverges.** The
   `config/master.key` purge rewrote history, and the local clones still held the
   pre-purge commits — so `git status` reported ~280 commits "only on local" and
   the same number "only on origin" for work that was byte-identical. **Before
   your first commit in any chopshop repo, `git fetch` and run
   `git rev-list --count origin/main..main`.** If that is non-zero on a repo you
   have not touched, stop and `git reset --hard origin/main`. Committing onto a
   pre-purge branch republishes the very secret that was purged.
10. **Confirm a fault against the running system before you report it.** A
    post-incident report claimed the user table was empty, a Ruby version
    mismatch, and an invalidated secret; all three were false — 3 users intact,
    `.ruby-version` matching the system, an env var untouched — while the actual
    fault was a venv that had lost Pillow. Check the thing you are reporting on
    (`select count(*) from users`, `ruby -v` against `.ruby-version`, `md5sum`),
    and quote the command's output. A confident wrong diagnosis costs the operator
    more time than an unfinished one.

Work in progress, blockers, and caveats live in `CONTEXT.md` at the root — keep
it current as work lands.

## Agent skills

### Issue tracker

Issues for this repo live as GitHub issues; use the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` at the repo root. See `docs/agents/domain.md`.

### Cross-repo docs

Anything that spans repos — the six-repo system map, the invocable-surface
registry, and the studio's HTTP driver contract — lives in
`docs/SYSTEM.md`, `docs/SURFACES.md` and `docs/agent-api.md` here, indexed by
`docs/README.md`. Read those before assuming one repo's facts apply to another.

### Standards

The shared conventions, and the rules for this tracker. Read
`docs/agents/standards.md` before filing an issue or landing a change.
