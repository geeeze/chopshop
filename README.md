# chopshop-studio

Rails GUI for [chopshop-svg](https://github.com/geeeze/chopshop-svg) — the
screen-print vector pipeline. The studio drives the pipeline **only through a
runner over HTTP**; it never traces, validates, or renders anything itself.

The pipeline's one law holds here too: **the front half never picks a winner.**
The studio surfaces candidates + metrics, a human chooses, and only then does
the back half validate the pick.

## What's in the box

| Piece | What it is |
|---|---|
| `app/` | Rails 8.1 app — Jobs, Validations, spec builder, Jev docs, Aether theme |
| `mock-runner/runner.py` | Reference implementation of the runner contract (Python stdlib, no deps) |
| `doc/runner-contract.md` | The wire protocol the studio speaks to any runner — source of truth |

## Pages

- **Jobs** — front-half runs: candidates, both gate layers, fidelity metrics
- **Run Job** — upload a PNG/JPEG (≤ 50MB, magic-byte checked), pick a runner, edit the spec JSON
- **JSON** — the spec builder: form fields with per-key docs → live job-contract JSON
- **JEV** — the decision-sidecar contract: the four typed questions Jev answers, the verdict shape, confidence rules
- **???** — plain-words overview of the pipeline, layers, runners, and Jev

## The runner contract

The studio maps a per-job runner name to a base URL (`Job::RUNNERS`) and talks
to it via `RunnerClient`:

```
POST /jobs                → 202 {id, stem}          front half (async)
GET  /jobs/:id            → {state, log_tail, comparison, ...}
GET  /files/:job_id/:name → file bytes (candidate SVGs, proofs, PDFs)
POST /validations         → 202 {id}                 back half on a picked candidate
GET  /validations/:id     → {state, manifest, error}
POST /validations/:id/jev→ Jev decision sidecar
GET  /health              → {ok, host, tools}
```

Full detail in `doc/runner-contract.md`; `mock-runner/runner.py` is a working
reference — adapt it, don't reinvent the surface. Auth is a shared bearer
token (`RUNNER_TOKEN` in both envs) when set.

Two runners ship in the map:

- **mock** — `127.0.0.1:8790`, simulates the whole pipeline for demos
- **am5** — `100.125.38.46:8787` (Tailscale only), the real chopshop-svg
  pipeline; not yet live

The header's runners dropdown shows live health for each (`up`/`down`).

## Requirements

- Ruby 3.2.3 + Rails 8.1 (`bundle install` and go)
- SQLite (db lives in `storage/`)
- No JS build step — importmap + Propshaft. The Aether theme
  (particles, orbs, custom cursor, modal viewer) is plain JS in
  `app/javascript/aether.js`
- Fonts are self-hosted (`public/fonts/*.woff2`, latin + latin-ext) — no CDN calls

## Running it

```bash
bundle install
bin/rails db:prepare

# production, behind the nginx config in nginx-chopshop.conf
RAILS_ENV=production SECRET_KEY_BASE=<secret> bin/rails server -b 127.0.0.1 -p 3001

# the demo stack (GUI + mock runner) via the operator script
~/start-chopshop-stack.sh
```

Secrets (never committed; `.env*` is gitignored):

- `CHOPSHOP_PASSWORD` — GUI login
- `SECRET_KEY_BASE` — Rails production
- `RUNNER_TOKEN` — shared bearer token between studio and runner, if set

Login is password-only; the reference deployment runs fail2ban against the
login log. There is no user model.

## Guardrails

- **The pipeline never picks a winner** — the GUI may sort and annotate
  candidates, but must never auto-advance to the back half. The only exception
  is an explicit operator instruction naming a candidate.
- **Runners are tailnet-only.** am5 binds to its Tailscale IP, never
  `0.0.0.0`. The mock binds loopback.
- **Never use an LLM to generate or edit SVG paths.** Tracing is VTracer, in
  the pipeline, behind the runner. Jev is advisory and typed; it never
  overrides gates.
- **No secrets in git** — secret-scan before every push.

## Repo layout

```
app/
  controllers/    jobs, validations, pages (+ upload proxy, per-candidate manifests)
  models/         job, candidate, validation (runner map lives in job.rb)
  views/          Aether-styled pages; spec builder; Jev contract docs
  javascript/     aether.js — particles, orbs, cursor, modal viewer, polling
  lib/            runner_client.rb — the HTTP surface
mock-runner/      runner.py — contract reference implementation
doc/              runner-contract.md
nginx-chopshop.conf
config/routes.rb  — the whole surface is ~10 routes; read it top to bottom
```

## Tests

The app is a thin GUI over the runner; the pipeline's hermetic suites live in
their own repos (chopshop-svg, chopshop-jev, chopshop-sui). Studio-side, the
runner contract and the mock are exercised end-to-end against the live mock
runner.
