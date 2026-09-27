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
| `mock-runner/runner.py` | Reference implementation of the runner contract (Python + Pillow for demo rasters; simulates the full front/back half and the `pitch_shift` variant axis) |
| `doc/runner-contract.md` | The wire protocol the studio speaks to any runner — source of truth |

## Pages

- **Login** — password gate over the Aether "draw as you move" canvas (spawned
  particles that drift, connect and dissolve, behind the form)
- **Jobs** — front-half runs: a lean table (preview, name, state, passed,
  queued) with a per-row action set, and a 2×2 preview grid (source + top-3
  candidates) docked in the header. A job's **results** page splits 67/33 into
  the candidates table (preview, preset, layer A/B, palette, per-row download
  SVG / manifest / proof) and the proofs column (preview, proof, state, Jev).
  Hard, advisory and the fidelity verdict are NOT columns on either table: they
  are in the row's **Findings & detail** popup, together with **Raw data** (the
  spec+comparison JSON), **Log** (the runner log) and the proof's own detail
- **Run Job** — upload a PNG/JPEG (≤ 50MB, magic-byte checked), pick a runner, edit the spec JSON
- **JSON** — the spec builder: form fields with per-key docs → live job-contract
  JSON. The colour palette is a swatch button + hex field + add button, with a
  **Colours** button opening the full hue/lightness grid and the shop's palette
  library; there is no quick-pick row of preset swatches any more (it was a
  second, poorer route to the same colours and read as "these are the colours you
  get"). A `pitch_shift` toggle. **Prep — expanded** carries
  the optional raster benches (`spec.print.prep_expand`): the ImageMagick filter
  bench and the tune sweep before the tracer, and `node_reduce` after the sweep,
  which writes reduced *copies* of the over-gate candidates and keeps the
  originals. Every control on it is off by default and none of it picks a
  candidate — it is measurement for a human to read
- **JEV** — the decision-sidecar contract: the four typed questions Jev answers, the verdict shape, confidence rules
- **???** — plain-words overview: what the pipeline does, the two validation
  layers, runners, Jev, a step-by-step walkthrough of a run, how to read the
  comparison table, what it deliberately won't do, and how the thing stays
  private

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

Only **mock** ships in the map (`127.0.0.1:8790`, simulates the whole pipeline
for demos). Live runners are added by **environment variable**, not by editing
the repo — a hardcoded host URL would tie the code to one machine's topology
and go stale the moment that host moves:

```bash
CHOPSHOP_RUNNER_GEENET_URL=http://127.0.0.1:8787   # label "geenet"
```

The label is the variable name with the prefix/suffix stripped and lower-cased,
so underscores stay underscores (`CHOPSHOP_RUNNER_STUDIO_A_URL` → `studio_a`).
The map is memoised and recomputed when that slice of the environment changes.

The header's runners dropdown shows live health for each (`up`/`down`).

## Requirements

- Ruby 3.2.3 + Rails 8.1 (`bundle install` and go)
- SQLite (db lives in `storage/`)
- No JS build step — importmap + Propshaft. The Aether theme
  (particles, orbs, custom cursor, modal viewer, login draw canvas,
  brand-button conic glow) is plain JS/CSS in `app/javascript/aether.js`
  and `app/assets/stylesheets/`
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

Deployment configuration (not secret, but environment-specific — keep it out
of the repo):

- `CHOPSHOP_RUNNER_<LABEL>_URL` — one per live runner, as above
- `CHOPSHOP_RUNNER_LABEL` — what `chopshop-svg`'s runner reports at `/health`
- `RUNNER_BIND` / `RUNNER_PORT` / `RUNNER_ROOT` — the runner's bind address,
  port and jobs directory

Login is password-only; the reference deployment runs fail2ban against the
login log. There is no user model.

Every controller runs `before_action :require_login`, including
`PagesController` — `/about`, `/json` and `/jev` were reachable without a
password until that was fixed, since the gate had been declared only in
`JobsController` and `ValidationsController`. New public pages must be added to
`PagesController`'s `except:` list deliberately, with a reason.

### Keeping it out of search indexes

Two layers, both advisory — the password gate is the real protection:

- `public/robots.txt` — `Disallow: /` for every agent, with the common search
  and AI-dataset crawlers named explicitly.
- `X-Robots-Tag: noindex, nofollow, noarchive, nosnippet` on **every** response
  (`ApplicationController#forbid_indexing`), plus a `<meta name="robots">` tag
  in the layout and the static error pages.

The header is the stronger of the two: robots.txt is only read by crawls that
start at the site root, whereas the header travels with each response and so
also covers direct links, already-indexed URLs, and the non-HTML endpoints (job
JSON, candidate SVGs, proofs, PDFs).

## Guardrails

- **The pipeline never picks a winner** — the GUI may sort and annotate
  candidates, but must never auto-advance to the back half. The only exception
  is an explicit operator instruction naming a candidate.
- **Runners are private-network only.** A live runner must bind a private
  address (`RUNNER_BIND`), never a public interface. Note the default in
  `runner.py` is `0.0.0.0`, which listens on *every* interface — set `RUNNER_BIND`
  explicitly in any real deployment. The mock binds loopback.
- **No host-specific literals in code or docs.** Runner identities come from
  configuration; a commit that names a machine, a VPN, or a fixed IP couples the
  repo to one deployment. `doc/runner-contract.md` states the same rule for
  anyone extending the contract.
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
