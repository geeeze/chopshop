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

- **Login** — password gate over the Aether "draw as you move" canvas: spawned
  particles that drift, connect and dissolve behind the form, over a sun surface
  whose layers drift, flare and storm on their own clocks, with the blue→pink
  balance shifting between them
- **Jobs** — front-half runs: a lean table (preview, name, state, passed,
  queued) with a per-row action set, and a 2×2 preview grid (source + top-3
  candidates) docked in the header. A job's **results** page splits 67/33 into
  the candidates table (preview, preset, layer A/B, per-row download SVG /
  manifest / proof) and the proofs column (preview, proof, state, Jev). Hard,
  advisory and the fidelity verdict are NOT columns on either table: they are in
  the row's **Findings & detail** popup, together with **Raw data** (the
  spec+comparison JSON), **Log** (the runner log) and the proof's own detail.
  **Download** streams the runner's 7z of the whole job *directory* and
  **Delete** removes it there — which is why anything a job produces has to be
  written inside that directory, not into the pipeline's shared tree, or it
  misses the archive and survives the delete
- **Proof** (`/proofs/:id`) — the back half for one chosen candidate: its render,
  its findings, its manifest, and the Jev decision sidecar. Reached from the
  results page, the Jobs list, or the findings popup
- **Run Job** — upload a PNG/JPEG (≤ 50MB, magic-byte checked), pick a runner, edit the spec JSON
- **JSON** — the spec builder: form fields with per-key docs → live job-contract
  JSON, laid out as two columns of grouped cards. The **left** is what the job
  *is* — Job Spec, then **Print & tolerances** directly under it, then Colour
  Spec: the contract, the conditions it is measured under, and the palette it is
  checked against. The **right** is what the *tracer* does, in the order the
  pipeline runs it — Prep, **Prep — expanded**, Sweep. It was one flow grid
  across the page, which interleaved the two halves: Prep sat beside Print &
  tolerances while Prep — expanded landed under Job Spec, half a page away. The
  colour palette is a swatch button + hex field + add button, with a
  **Colours** button opening the full hue/lightness grid and the shop's palette
  library; there is no quick-pick row of preset swatches any more (it was a
  second, poorer route to the same colours and read as "these are the colours you
  get"). There is a `pitch_shift` toggle, and **Prep — expanded** carries the
  optional raster benches (`spec.print.prep_expand`): the ImageMagick filter bench
  and the tune sweep before the tracer, and `node_reduce` after the sweep, which
  writes reduced *copies* of the over-gate candidates and keeps the originals.
  Every control on it is off by default and none of it picks a candidate — it is
  measurement for a human to read
- **FLUX** — the generation service's settings and model registry, mirrored from
  `chopshop-flux`'s `config.py` and `models.py` so the page cannot drift from the
  service it documents: four setting cards (Service, Model, Resolution,
  Hand-off), each with a `?` that documents that card's own fields, a full-width
  **Checks** card that runs the service's size rules in the browser and shows
  what the current request comes to, and a **flux.conf.json** popup carrying the
  generated conf as the client would take it. The **MODELS** popup leads with
  the licence, which is the point of the page: klein-4B is Apache-2.0 and its
  output is yours to sell, while the 9B is FLUX Non-Commercial — stated in the
  registry, in the live licence pill beside the model select, and in the refusal
  the service gives until `CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1`. The quantised 9B
  builds are listed as unloadable *with the reason*. Read-only by design: it
  shows what the service would be started with, it does not start it
- **JEV** — the decision-sidecar contract: the four typed questions Jev answers, the verdict shape, confidence rules
- **???** (`/about`) — plain-words overview: what the pipeline does, the two validation
  layers, runners, the generation service, Jev, a step-by-step walkthrough of a
  run, how to read the comparison table, what it deliberately won't do, and how
  the thing stays private

## The runner contract

The studio maps a per-job runner name to a base URL (`Job::RUNNERS`) and talks
to it via `RunnerClient`:

```
POST   /jobs                → 202 {id, stem}     front half (async)
GET    /jobs/:id            → {state, log_tail, comparison, ...}
GET    /jobs/:id/candidates → {candidates: [{file, preset, layer_a, ...}]}
GET    /jobs/:id/archive    → the job directory as a 7z   (the Download button)
DELETE /jobs/:id            → drop the job and its directory (the Delete button)
POST   /jobs/:id/cancel     → abandon an in-flight run
GET    /files/:job_id/:name → file bytes (candidate SVGs, proofs, PDFs)
POST   /validations         → 202 {id}           back half on a picked candidate
GET    /validations/:id     → {state, manifest, error}
POST   /validations/:id/jev → Jev decision sidecar
GET    /health              → {ok, host, tools}
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

- Ruby 3.2.3 + Rails 8.1.3 (`bundle install` and go)
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

# development
bin/rails server -b 127.0.0.1 -p 3001

# production, behind the nginx config in nginx-chopshop.conf
RAILS_ENV=production SECRET_KEY_BASE=<secret> bin/rails server -b 127.0.0.1 -p 3001
```

`Dockerfile.dev` is a **verification** image, not a deploy image: the bundle is
baked in so a check container starts in seconds, and the repo is bind-mounted
over `/app` at run time, which is why an edit here is live on reload with no
build step. The deploy path is kamal/thruster (`Gemfile`) against
`nginx-chopshop.conf` on the host.

```bash
podman build -f Dockerfile.dev -t chopshop-app .
podman run -d --name chopshop-app -p 127.0.0.1:3001:3001 \
  -v "$PWD":/app:rw --env-file .env chopshop-app
```

How the stack is wired per host (which runner, which port, which jobs dir) is
operator configuration, deliberately not recorded here — see the guardrails.
`.env.example` is the shape of it: copy to `.env` and edit. It deliberately names
no host, so one file describes a **single-box** install (runner and studio on the
same machine, loopback addresses) and a **split** install (studio here, GPU
elsewhere — a tailnet address, a LAN address, a tunnel) equally well. The two
differ only in the URLs.

A runner is either the **pipeline** (kind `svg` — prep, trace, gate) or a
**generator** (kind `flux`, a `chopshop-flux` service, reached through that
service's own standard API). A pipeline runner needs nothing said about it; a
generator is declared by adding `CHOPSHOP_RUNNER_<LABEL>_KIND=flux`, and Run Job
then offers it and swaps its form for a prompt. Nothing in this repo knows which
box anything runs on.

Secrets (never committed; `.env*` is gitignored):

- `CHOPSHOP_PASSWORD` — GUI login
- `SECRET_KEY_BASE` — Rails production
- `RUNNER_TOKEN` — shared bearer token between studio and runner, if set
- `CHOPSHOP_FLUX_TOKEN` — the generator's own token, separate on purpose: that
  service keeps a clean standard API which other applications also call, so it
  does not share the pipeline's credential

Deployment configuration (not secret, but environment-specific — keep it out
of the repo):

- `CHOPSHOP_RUNNER_<LABEL>_URL` — one per live runner, as above
- `CHOPSHOP_RUNNER_<LABEL>_KIND` — `svg` (default) or `flux`
- `CHOPSHOP_FLUX_HANDOFF_RUNNER` — where a flux job's raster goes to be traced;
  defaults to the first non-mock pipeline runner
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
lib/              palette_library.rb — the shop's palettes; no Rails deps
mock-runner/      runner.py — contract reference implementation
doc/              runner-contract.md
Dockerfile.dev    local verification image (not the deploy path)
nginx-chopshop.conf
config/routes.rb  — the whole surface is 25 routes; read it top to bottom
```

## Tests

The app is a thin GUI over the runner; the pipeline's hermetic suites live in
their own repos (chopshop-svg, chopshop-jev, chopshop-sui). Studio-side,
`bin/rails test` runs a suite that is mostly rendering contracts: each page's
structure is asserted against the rendered HTML with Nokogiri (columns, classes,
cardinality, help-block coverage, alignment), so a layout change that breaks a
promise fails a test rather than a user's eye. The run count is deliberately not
written down here; it goes stale on every new contract.

Expect **1 failure and 9 errors** out of the box: `JevHelpTest` and
`JevRemediationTest` fail to parse the annotator's JSON against the current
checkout. That is pre-existing and unrelated to the rest of the suite — compare
against those two files, not against green.

```bash
bin/rails test                                   # everything
bin/rails test test/controllers/some_test.rb     # one contract
```

Where a test needs the runner, it is **swapped out**: the tests replace
`RunnerClient`'s singleton methods by hand and restore them in an `ensure`
(Minitest 6 dropped `minitest/mock`), so no live runner is needed.
`mock-runner/runner.py` is therefore *not* exercised by this suite — it is a
reference implementation to read and adapt. What is checked at that boundary is
in `test/lib/runner_client_test.rb`: a refused connection surfaces as
`RunnerClient::RunnerError`, not a bare socket error.
