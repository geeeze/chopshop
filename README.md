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
| `app/` | Rails 8.1 app — Jobs, Validations, Composite, Scrapbook, spec builder, Jev docs, Aether theme |
| `mock-runner/` | Reference implementations of the runner contract (Python + Pillow for demo rasters; simulates the full front/back half and the `pitch_shift` variant axis) — `runner.py`, plus `runner_serialised.py` for a single-worker deploy |
| `docs/runner-contract.md` | The wire protocol the studio speaks to any runner — source of truth |

## Pages

- **Login** — password gate over the Aether "draw as you move" canvas: spawned
  particles that drift, connect and dissolve behind the form, over a sun surface
  whose layers drift, flare and storm on their own clocks, with the blue→pink
  balance shifting between them
- **Jobs** — front-half runs: a lean table (preview, name, state, passed,
  queued) with a per-row action set, and a preview pair (source + its
  colour-inverted twin) in the job page's **source stack** — a vertical,
  bottom-aligned column below the candidates and the proofs, where a flux job's
  generated variations and a plot job's drawn SVG sit too. For a FLUX job that
  pair follows the GENERATION rather than a prep stage, because there is not
  always a runner behind it: an img2img job shows the reference it was piped in,
  the source tile is the generated raster (from `storage/uploads` for a
  raster-only job, from the runner for a traced one), and a raster-only job's
  twin is inverted locally at
  completion (`FluxInverseTwin`, pure Ruby) since no prep stage will draw one.
  Every flux tile's popup reveals the whole generation config — model, size,
  schedule, seed, images, mode, negative prompt, strength — not just the prompt.
  A job's **results** page splits 67/33 into
  the candidates table (preview, preset, layer A/B, per-row download SVG /
  manifest / proof) and the proofs column (preview, proof, state, Jev). Hard,
  advisory and the fidelity verdict are NOT columns on either table: they are in
  the row's **Findings & detail** popup, together with **Raw data** (the
  spec+comparison JSON), **Log** (the runner log) and the proof's own detail.
  **Download** streams the runner's 7z of the whole job *directory* — except for
  a FLUX job, whose generation the runner never saw: that one is packaged here
  (`FluxArchive`) as `flux.json` + the reference + every raster + the
  colour-inverted twin, with the runner's own archive riding inside it as
  `pipeline.7z` in trace mode, rather than the studio unpacking and re-writing
  the runner's artefact. **Delete** removes the job directory there — which is
  why anything a job produces has to be
  written inside that directory, not into the pipeline's shared tree, or it
  misses the archive and survives the delete
- **Proof** (`/proofs/:id`) — the back half for one chosen candidate: its render,
  its findings, its manifest, and the Jev decision sidecar. Reached from the
  results page, the Jobs list, or the findings popup
- **Run Job** — upload a PNG/JPEG (≤ 50MB, magic-byte checked), pick a runner, edit the spec JSON
- **Composite** — the composition builder: layer pieces (blank, upload, scrapbook item)
  into one image, then flatten it into a job's source raster. A composite holding any
  **vector** layer is flattened by the svg runner itself (`POST /compose`, via
  `ComposeClient`), so a traced source is merged as vectors instead of being
  rasterised and traced a second time
- **Scrapbook** — the left-sidebar store of favourited sources/inverts/candidates/proofs,
  kept in `storage/scrapbook` so it survives deleting the job it came from
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
  measurement for a human to read, and it is **archive-only**: the runner returns
  the bench summary in `GET /jobs/:id` as `prep_expand`, but the studio stores no
  column and renders no block for it, so the report is read out of the job's
  download (`prep-expand.md` and the bench reports beside it)
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
- **BP** — **Blend-Plot** (`chopshop-bp`, renamed from `chopshop-plot` because it hosts
  both halves): the geometry source, the metrics digest and cross-run query engine, and
  the headless-Blender 3D operation, all on **one** serve surface and therefore on one
  page, mirrored from that repo's `config.py`, `spec.py` and `metrics.py`. `generate`
  draws geometry, `digest`/`query` draw charts, `tree`/`log` draw a hierarchy and a
  timeline, and `blender` renders a frame or a GLB. Sections, `FIELDS` (the element
  types, the document's blocks, the metric field registry, the chart shapes) and `JSON`
  popups; the runner pills report the bp runners this deployment actually files and
  which half each serves. Read-only by design, the same rule FLUX holds: it shows what
  the service would be started with, it does not start it. `/plot` and `/blender` still
  resolve — they redirect here, so an old link lands somewhere real
- **DATASETS** — the public corpora the studio draws from: DiffusionDB's prompt
  slice (with its authors' hyperparameters, its own 2-D projection of prompt
  space, derived topic labels and a phrase tree) and MET-Meme's annotation
  vocabulary. Not a gallery: a prompt drawn here goes onto the Run Job form.
  Read-only, and the only page whose subjects are shared reference data rather
  than one operator's rows
- **TOURNAMENT** — a SIMULATED single-elimination bracket over a candidate set, drawn
  in the mirrored (two-sided) layout — the tree folded at its root with the final in
  the centre column. It decides nothing: it reads no Job, no Candidate and no Event,
  writes nothing, and exists as the reference drawing for that layout. The BP page
  opens the same bracket as a popup
- **STATUS** — the telemetry surface, and the reason the event log exists: three panels
  drawn by the blend-plot service. **PIPELINE USE** — what this studio has produced
  (jobs, generated, traced, proofs, scrapbooked, composited) as a bar chart with the
  same six numbers as tiles beside it. **SERVER** — this host's CPU, memory and swap
  over six hours in five-minute buckets, from `HostSample`'s minute samples, with the
  newest reading as tiles. **EVENT LOG** — one row per recorded action (every star,
  pick and delete), the learning signal a later learned-ranker phase reads. Both charts
  are bp `digest` documents and the log is a `log` one. The source → job → candidate
  **hierarchy that used to lead this page was REMOVED** — it restated the jobs table in
  a shape no number could be read out of — and its absence is pinned structurally. With
  no blend-plot runner configured the page renders the same numbers as its own HTML,
  and **nothing to draw is nothing to ask for**: a bar chart of six zeros is a drawing
  of an absence, so those documents are simply not requested. Its `EVENTS` button
  leaves for the raw JSON behind it — `GET /events`, login-gated and owner-scoped, with
  `?event=`, `?job_id=` and `?limit=` (max 1000). Read-only: it reports what the log
  already holds
- **About** (`/about`) — plain-words overview: what the pipeline does, the two validation
  layers, runners, the generation service, Jev, a step-by-step walkthrough of a
  run, how to read the comparison table, what it deliberately won't do, and how
  the thing stays private

## Sequences — an ordered step list in one job

A job is one runner action by default. Ticking **Sequence** on the Run Job page makes it an
ordered list instead, carried in the same contract under a top-level `steps` key:

```json
{
  "steps": [
    { "runner": "flux", "flux": { "prompt": "a woodcut phoenix", "mode": "raster" } },
    { "runner": "svg",  "svg":  { "sweep": { "preset": "bw" } } },
    { "runner": "bp",   "input": "previous",
      "bp": { "op": "blender", "doc": { "render": { "views": 1 } } } }
  ]
}
```

Each step names the runner it runs on by **label** and carries that runner's own block, which
is the same document the corresponding panel composes. The hand-off declaration (`input`) sits
beside the runner label rather than inside the block, because the block is posted to the service
untouched and a foreign key in it would be a contract violation.

**The studio drives the chain; the runner does not.** A runner is stateless and serves one
operation per request, so `RunJob` posts step one, waits for it to finish, then posts step two
with step one's output handed in. Pipeline steps are polled to a terminal state before the chain
continues, because the next step's input is the previous step's output. No runner change is
needed or wanted.

Back-compat is the default and is load-bearing: a spec with **no** `steps` key behaves exactly as
it did before step lists existed, so every existing job keeps running and no row needs migrating.
A spec carrying one answers a single implicit step, which is why the single-action path and the
chain path share every reader.

Validation reuses the existing per-kind validators once per step rather than copying them, and
names the step in the message (`step 2: a BLENDER document needs an elements list`). A step whose
file can come from nowhere is refused by index rather than posted with no input.

Progress is recorded per step in `jobs.steps_state`, so a job that is interrupted reports where it
actually got to. A step failure stops the chain and names the step; a cancel stops it between
steps.

## The runner contract

The studio maps a per-job runner name to a base URL (`Job.runner_urls`, backed
by `Job::RUNNER_DEFAULTS`) and talks to it via `RunnerClient`:

```
POST   /jobs                → 202 {id, stem}     front half (async)
GET    /jobs/:id            → {state, log_tail, comparison, ...}
GET    /jobs/:id/archive    → the job directory as a 7z   (the Download button)
GET    /jobs/:id/dataset    → ONE proof dataset as a 7z   (the proof's download)
DELETE /jobs/:id            → drop the job and its directory (the Delete button)
POST   /jobs/:id/cancel     → abandon an in-flight run
GET    /files/:job_id/:name → file bytes (candidate SVGs, proofs, PDFs)
GET    /files/:job_id/<stem>.dataset/<name>
                            → one file inside a proof dataset (the four-segment form)
POST   /validations         → 202 {id}           back half on a picked candidate
GET    /validations/:id     → {id, state, manifest, log, error}
POST   /validations/:id/jev → Jev decision sidecar
POST   /recolour            → recolour a candidate SVG in place (paint only)
POST   /recolour/colours    → list a candidate's declared colours
GET    /health              → {ok, host, mode, tools{inkscape, gs, jev}}
```

`POST /compose` is the one route the app reaches through a second client:
`ComposeClient` (not `RunnerClient`) posts a composite's layers to it and stores
the merged SVG it returns, so a composite holding a vector layer is never
rasterised and re-traced.

Full detail in `docs/runner-contract.md`; `mock-runner/` is a working
reference — adapt it, don't reinvent the surface. Auth is a shared bearer
token (`RUNNER_TOKEN` in both envs) when set.

Only **mock** ships in the map (`127.0.0.1:8790`, simulates the whole pipeline
for demos). Live runners are added by **environment variable**, not by editing
the repo — a hardcoded host URL would tie the code to one machine's topology
and go stale the moment that host moves:

```bash
CHOPSHOP_RUNNER_SVG_URL=http://127.0.0.1:8787   # label "svg"
```

The label is the variable name with the prefix/suffix stripped and lower-cased,
so underscores stay underscores (`CHOPSHOP_RUNNER_STUDIO_A_URL` → `studio_a`).
The map is memoised and recomputed when that slice of the environment changes.

Two non-pipeline runner kinds are also wired: `CHOPSHOP_RUNNER_*_KIND=flux`
(chopshop-flux, raster generation) and `CHOPSHOP_RUNNER_*_KIND=bp`
(chopshop-bp — the blend-plot service, whose op selector covers all six of its
operations: `generate`, `digest`, `query`, `tree`, `log` draw a document and
`blender` renders 3D). The **offered** target is `bp`; the older `plot` and
`blender` kinds a job may already be filed against stay VALID and are no longer
offered (`Job::LEGACY_JOB_KINDS`), because removing a kind makes an existing
job unaddressable rather than migrating it. See the BP page for the full
contract; every half reaches the same service, so the studio authenticates to
it with `CHOPSHOP_PLOT_TOKEN`.

The header's runners dropdown shows live health for each (`up`/`down`).

## Requirements

- Ruby 3.2.3 + Rails 8.1.3.1 (`bundle install` and go)
- SQLite (db lives in `storage/`)
- No JS build step — importmap + Propshaft. The Aether theme
  (particles, orbs, custom cursor, modal viewer, login draw canvas,
  brand-button conic glow) is plain JS/CSS in `app/javascript/` — `aether.js`
  (site), `aether-core.js` (the shared core, and the whole login bundle),
  `aether-entropy.js` (the polled mouse/touch entropy that seeds the background
  particle field and the login orb's drift) — and `app/assets/stylesheets/`
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
build step. The kamal/thruster gems are bundled (`Gemfile`) but the deploy
config (`config/deploy.yml`, `.kamal/`) lives outside the repo, against
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

- (per-user) — GUI login is per-user: a bcrypt `users` table where the password IS the identity. The operator's original password was migrated into the table unchanged; add more with `bin/rails 'users:add[handle,password]'`. The old `CHOPSHOP_PASSWORD` env var is no longer read by the app (its value now lives in the table).
- `SECRET_KEY_BASE` — Rails production
- `RUNNER_TOKEN` — shared bearer token between studio and runner, if set
- `CHOPSHOP_FLUX_TOKEN` — the generator's own token, separate on purpose: that
  service keeps a clean standard API which other applications also call, so it
  does not share the pipeline's credential

Deployment configuration (not secret, but environment-specific — keep it out
of the repo):

- `CHOPSHOP_RUNNER_<LABEL>_URL` — one per live runner, as above
- `CHOPSHOP_RUNNER_<LABEL>_KIND` — `svg` (default), `flux`, `bp`, or the legacy
  `plot` / `blender` (`Job::RUNNER_KINDS`; a new job is only offered `bp` for
  the blend-plot service)
- `CHOPSHOP_FLUX_HANDOFF_RUNNER` — where a flux job's raster goes to be traced;
  defaults to the first non-mock pipeline runner
- `CHOPSHOP_RUNNER_LABEL` — what `chopshop-svg`'s runner reports at `/health`
- `RUNNER_BIND` / `RUNNER_PORT` / `RUNNER_ROOT` — the runner's bind address,
  port and jobs directory

Login is password-only; the reference deployment runs fail2ban against the
login log. Users are real: a `User` model (`app/models/user.rb` —
`has_secure_password` + bcrypt) backed by the `users` table, where the password
IS the identity. Each user's own rows are scoped to them by the `owner` column
(`Owned`), so one operator never sees another's jobs, proofs, composites or
scrapbook.

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

### Reporting a problem

The footer's maintenance button (the worker icon beside the check-engine light)
opens a popup where any signed-in operator explains **what happened**, **what
they expected** and **anything else** — three boxes on purpose, because a single
textarea gets a description of what they did and stops. The submission becomes a
GitHub issue labelled `needs-triage` plus a kind label (`bug` / `expectation` /
`suggestion`), and the studio attaches the page, the account handle, the studio
version and the browser, so a reporter is never chased for facts only the server
can see.

It is a popup, not a page, on purpose: an operator reports from wherever they hit
the problem, and that page is itself part of the report. It posts with `fetch`
and renders the outcome in place, so a failed filing never costs the reporter
their words.

**Where the token goes.** The app reads the systemd unit's `EnvironmentFile`,
which on the live box is `/home/unodos/.chopshop-studio.env` — *not* the agent's
own `/home/unodos/.hermes/.env`. Edit the studio env file (or edit the Hermes
one and copy the value across), then restart and precompile:

```bash
RAILS_ENV=production bin/rails assets:precompile
systemctl --user restart chopshop-rails
```

**`assets:precompile` is not optional when you add an asset.** A deployment
that serves `/assets` from a precompiled `public/assets` keeps a
`.manifest.json`, and Propshaft resolves `image_tag` through it — so a new PNG
is missing from the manifest until you precompile, and then **every page 500s**
with `Propshaft::MissingAssetError`. A restart alone does not help: the source
file is on disk and a fresh process resolves it fine, which is exactly what makes
this confusing. Precompile on every deploy that adds or removes an asset.

Needs a fine-grained PAT with `issues: write`; see `.env.example`.

Leaving it unset is safe and visible: the popup still opens, says filing is not
configured, and keeps the typed report on screen rather than pretending to send
it.

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
  repo to one deployment. `docs/runner-contract.md` states the same rule for
  anyone extending the contract.
- **Never use an LLM to generate or edit SVG paths.** Tracing is VTracer, in
  the pipeline, behind the runner. Jev is advisory and typed; it never
  overrides gates.
- **No secrets in git** — secret-scan before every push.

## Repo layout

```
app/
  controllers/    application, jobs, validations, pages, composites, scrapbooks, datasets,
                  events, engine (+ upload proxy, per-candidate manifests)
  models/         job, candidate, validation, composite, composite_layout, scrapbook_item,
                  user, event, telemetry, host_sample, prompt_source, session_draft,
                  flux_conf, flux_archive, flux_inverse_twin, plot_conf, blender_conf,
                  bp_examples, jev_conf
                  (the runner map lives in job.rb)
  views/          Aether-styled pages; spec builder; Jev contract docs; composites + scrapbook
  javascript/     aether.js (site) / aether-core.js (shared, the login bundle) /
                  aether-entropy.js (the pointer entropy) / aether-sketch.js (the
                  composite canvas' snapping + coupling) / login.js / application.js
  lib/            runner_client.rb (the runner HTTP surface), flux_client.rb (the FLUX service
                  client), plot_client.rb + blender_client.rb (chopshop-bp's two halves),
                  bp_client.rb (the dispatcher over those two), compose_client.rb,
                  compose_spec.rb / compose_document.rb (the compose contract),
                  meme_vocabulary.rb, tournament_sim.rb
lib/              palette_library.rb — the shop's palettes; comment_redactor.rb; tasks/users.rake
mock-runner/      runner.py — the contract reference implementation; runner_serialised.py, the
                  single-worker variant the operator deploys over it; runner_deployed.py, the
                  copy currently deployed (kept for reference — it is byte-identical to
                  runner.py today); test_runner_serialised.py, its real-HTTP behaviour test
docs/             runner-contract.md (source of truth), ui-conventions.md, step-lists.md,
                  game-asset-generation.md, architecture-review-scrapbook-composite.md,
                  agent-surface-gaps.md, SYSTEM.md, SURFACES.md, agent-api.md, README.md,
                  agents/ (domain.md, issue-tracker.md, triage-labels.md)
Dockerfile.dev    local verification image (not the deploy path)
nginx-chopshop.conf
config/routes.rb  — the whole route surface; read it top to bottom
```

## Tests

The app is a thin GUI over the runner; the pipeline's hermetic suites live in
their own repos (chopshop-svg, chopshop-jev, chopshop-sui). Studio-side,
`bin/rails test` runs a suite that is mostly rendering contracts: each page's
structure is asserted against the rendered HTML with Nokogiri (columns, classes,
cardinality, help-block coverage, alignment), so a layout change that breaks a
promise fails a test rather than a user's eye. The run count is deliberately not
written down here; it goes stale on every new contract.

```bash
bin/rails test                                   # everything
bin/rails test test/controllers/some_test.rb     # one contract
```

Where a test needs the runner, it is **swapped out**: the tests replace
`RunnerClient`'s singleton methods by hand and restore them in an `ensure`
(Minitest 6 dropped `minitest/mock`), so no live runner is needed.
`mock-runner/runner.py` is therefore *not* exercised by this suite — it is a
reference implementation to read and adapt (though `test/lib/runner_serialisation_test.rb`
does pin `mock-runner/runner_serialised.py`'s single-worker queue). What is checked at that boundary is
in `test/lib/runner_client_test.rb`: a refused connection surfaces as
`RunnerClient::RunnerError`, not a bare socket error.
