# CONTEXT.md — chopshop-studio

Working state for agents and humans: what is in flight, what is blocked, and
the caveats that are not obvious from the code. Update this as work lands.

**Repo visibility: private.** Host-specific deployment facts may live here but
must be tagged `HOST-SPECIFIC` (see `skills/README.md` and the
`sync-skills` convention) — subject to change, remove before reuse elsewhere.

## UI standard: the page header (canonical: the Jobs page)

The Jobs page's header is the reference format every page's head should follow.
It is the best-balanced title/subtitle/action layout to date — mirror it, do not
re-invent it.

- **50/50 split.** Title + subtitle own the LEFT half; the action button(s) own
  the RIGHT half. `.page-head-row--stacked` is a `grid-template-columns: 1fr auto`
  grid: `.section-title` is pinned row 1 col 1, the blurb row 2 col 1, the
  primary action row 1 col 2, and secondary controls row 2 col 2 (right-aligned
  with `justify-self: end`).
- **Title.** `.section-title` + `.gradient-text` — `clamp(2rem, 4vw, 3.2rem)`,
  weight 800, gradient across the word. Subtitle is `.page-head-blurb`
  (`--text-secondary`, `max-width: 67%`; the Jobs page uses the `--long` variant).
- **Larger primary action.** "Run Job" is a `.btn.btn-primary.head-action` —
  the LARGEST button in the head (2.75rem tall / 98×44px measured, plus the
  conic glow ring at `inset: -3px` and the ambient `0 20px 60px` glow). The
  accent button is deliberately bigger and brighter than everything beside it.
- **Buttons underneath.** Secondary controls (e.g. the List/Grid view toggle)
  sit DIRECTLY BENEATH the primary, in row 2 col 2 — never beside it, never in
  the title cell. They are small `.btn-secondary` controls, NOT `.head-action`s.
- **Frosted glass.** Secondary controls are frosted: `.btn-secondary` carries
  `backdrop-filter: blur(10px)` over a translucent `--surface` fill, so the
  particle field reads through them.
- **No margin between grouped buttons.** A set of mode buttons is ONE segmented
  control: `.view-toggle { display: inline-flex; gap: 0 }` with square inner
  edges and rounded outer corners only, and `margin-left: -1px` on the second
  half so the two 1px borders collapse into one. They touch; they are one box
  with two stops, not two buttons with air between them. Pinned by
  `jobs_grid_test.rb` (`gap: 0` assertion).

A visual change is a contract change: the header shape is pinned by
`page_head_uniformity_test.rb`, `responsive_head_test.rb`, `head_alignment_test.rb`
and `head_action_size_test.rb` — changing the title, blurb, button size or
arrangement means updating those lists and re-running the suite.

## What this repo is

Chopshop Studio, the Rails 8.1 operator front end for the chopshop pipeline
(private demo). The operator uploads a raster, the runner produces traced SVG
candidates, the operator picks one, and that pick is proved: proof PNG, print
PDF, manifest. The pipeline never picks a winner; the studio is the surface
where the human makes that call.

## Work in progress

- Skill publication landed: `sync-skills` now generates a host-tagged copy of
  the working skill into `skills/chopshop-studio/`.
- No tracked in-flight feature at the time of writing. If you start one, list it
  here with an owner and a note.

## Blockers

- None known.

## Caveats / known issues

- **Password-only per-user accounts.** The password IS the identity (no username,
  no LDAP). `User` model + bcrypt; `session[:user_id]`; an `Owned` concern stamps
  `owner` at create and scopes every read, so each user sees only their own jobs,
  validations, scrapbook and composites. Add users with `bin/rails 'users:add[handle,password]'`.
- **`config/master.key` was tracked from the first commit** — the key is in git
  history and must be treated as compromised; rotate it. Untracking does not
  unpublish.
- **No JS build step** (importmap + Propshaft); **Turbo is NOT pinned**, so
  mutating nav must use `button_to method: :delete`, not a `data-turbo-method`
  link.
- **Runner state is in-memory**; a runner restart drops validations, so the
  studio resolves proofs from disk (`job_id` + candidate file), not the stored
  `runner_validation_id`.
- **Jev add-on is optional and advisory**; an unconfigured add-on answers 503
  with a reason (never 404). The key is operator-supplied and lives only in a
  gitignored host-local override + env file.
- **Host-specific detail** (ports, env-file paths, systemd unit, timings) lives
  in `skills/` and is tagged `HOST-SPECIFIC`. The repo's own code stays
  host-agnostic via `CHOPSHOP_RUNNER_<LABEL>_URL`, `CHOPSHOP_EXTRA_HOSTS`, and
  the `@SERVER_NAME@` nginx template.

## Doc layout note (2026-09-28)

`doc/runner-contract.md` moved to `docs/runner-contract.md` (the `doc/` dir is
gone), and `AGENT_USAGE_REPORT.md` was folded into `docs/agent-api.md` (the
canonical studio HTTP driver contract) and then deleted. The cross-repo
orientation now lives in `docs/SYSTEM.md`, `docs/SURFACES.md` and
`docs/README.md`. The `test/lib/runner_contract_test.rb` path was updated and
the suite re-verified.
