# CONTEXT.md — chopshop-studio

Working state for agents and humans: what is in flight, what is blocked, and
the caveats that are not obvious from the code. Update this as work lands.

**Repo visibility: private.** Host-specific deployment facts may live here but
must be tagged `HOST-SPECIFIC` (see `skills/README.md` and the
`sync-skills` convention) — subject to change, remove before reuse elsewhere.

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
gone), and `AGENT_USAGE_REPORT.md` moved to `docs/agent-usage-report.md`. The
`test/lib/runner_contract_test.rb` path was updated and the suite re-verified.
