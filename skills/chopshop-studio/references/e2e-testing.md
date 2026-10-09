# E2E testing / demonstration of the studio, as a specific user

The operator periodically asks to "run the e2e tests" and to SEE real outputs in a
second user (usually `<test-handle>`): a source image traced, a generated image, the same
image steered through the pipeline in different directions, and distillation by
prompt. This is a DEMONSTRATION, not a load test — a handful of jobs, low candidate
caps, one at a time. Drive the live production app at `http://127.0.0.1:3001`; never
POST straight at a runner, because the studio's own serial gate + per-user scoping is
half of what is being demonstrated.

## Driver skeleton (python stdlib only — no requests/pip)

The studio sets `assume_ssl` + a `secure` session cookie, so a loopback client must
(1) send the cookie over http and (2) NOT auto-follow the https redirect:

```python
import urllib.request, urllib.parse, http.cookiejar, re, json, time, os

BASE = "http://127.0.0.1:3001"
PASSWORD = open(os.environ["E2E_PW_FILE"]).read().strip()   # never inline the secret

policy = http.cookiejar.DefaultCookiePolicy()
policy.secure_protocols = ("https", "wss", "socks", "http")  # allow secure cookie over http
cj = http.cookiejar.CookieJar(policy)

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None

opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj), NoRedirect())
opener.addheaders = [("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) Chrome/149.0.0.0 Safari/537.36")]
```

Login: GET `/login`, pull `csrf-token" content="…"` (or `meta[name=csrf-token]`),
POST `authenticity_token` + `password` to `/login`. Success is a 302.

## Viewing the authenticated page in a real browser (no password typed)

When you must SEE the rendered page (a layout, a visual) rather than fetch its
HTML, and the browser backend cannot reach the loopback origin but CAN reach the
public URL, inject the session cookie you already hold instead of logging in
again. The Rails session cookie is signed with the same `secret_key_base` on
every host, so the loopback value works on the public domain:

1. Log in over loopback with the urllib harness above and read the cookie value
   from the jar (`cj`). It is URL-encoded and carries the `Secure` flag.
2. In the browser, `cdp('Network.setCookie', name='_chopshop_studio_session',
   value=<the URL-encoded value>, domain='<public-host>', path='/',
   secure=True)`.
3. `goto_url('https://<public-host>/...')` — the page is authenticated.

The cookie must be set with `secure=True` (the app's session cookie is Secure)
and the value must stay URL-encoded exactly as the jar holds it. The browser
session is not persistent — re-inject after any reset.

## Submitting a job

POST `/jobs` with a fresh CSRF from `/jobs/new`, fields:
`job[name]`, `job[runner]` (label: `svg` for the pipeline, `flux`, `plot` — NOT `<old-label>`, which was renamed), `job[source_kind]` (`raster`), `job[input_path]` (absolute path to a file under `storage/uploads` — only uploads are honoured), `job[spec]` = `json.dumps(spec)`. Success is a 302 whose `Location` carries `/jobs/<id>`.

## Spec shapes

- Trace (pipeline/`svg`): `{print_method, max_colors, palette, geometry{min_stroke_width_pt, max_nodes_per_path, allow_gradients, allow_open_paths}, print{dpi, sweep_max_candidates, invert}}`. `print.invert: true` adds the colour-inverted prep twin. `sweep_max_candidates` caps the candidate count — keep it low (≤6) for a gentle demo. Steering direction = the `palette` (warm/cool/mono hex sets) + `invert`.
- Flux text→image (raster-only): `{flux:{prompt, model, mode:"raster", width, height}}`. The model key is from `FluxConf::MODELS` (`klein-4b`, `klein-4b-base`, `sdxl-1.0`, `sdxl-turbo`, `sd-1.5`).
- Flux img2img (distill by prompt): same plus `image: "<uploaded basename>"` — a file already in `storage/uploads`, validated server-side to be a basename, never a path.

## Polling to done

GET `/jobs/<id>` and match the served state: `job-state">· <state>` and `job-error...>(<msg>)`. Candidate count is in the summary tile `<div class="value">N</div><div class="label">candidates</div>`. Poll every ~4s until `done`/`error`/`cancelled`. The studio serialises the queue itself, so submit one job at a time and just wait; each trace job is ~30–160s, each flux generation ~10–20s.

## Verify outputs are REAL, not just "submit returned 200"

- Candidate SVG: `GET /jobs/<id>/file?name=candidate_NN.svg` → 200 `image/svg+xml`.
- Flux raster: `GET /jobs/upload_preview/<name>` → 200 `image/png`; the raster lives in `storage/uploads` as `flux_<hex12>.png`. **The route is `/jobs/upload_preview/:name` — a `?name=` query string 404s.**

## Test user + password

**`<test-handle>` IS THE OPERATOR'S OWN ACCOUNT — NEVER RESET ITS PASSWORD.** The value is
`CHOPSHOP_UNODOS2_SECRET` in `~/.hermes/.env`, the operator set it, and the driver
scripts read it from there. A "reset the demo user to a fresh temp password first"
step does not rotate a test fixture — it DESTROYS the operator's credential and draws
"why is the <test-handle> password different than what i set it to and put into .env".
Measured: three silent resets in one day (the digest's `updated_at` moved each time),
every one of them from an agent following this page. `E2E_PW_FILE` is an explicit
override for a throwaway account only; nothing here needs it for `<test-handle>`.
**`<disposable-handle>` IS THE THROWAWAY ONE.** "Reset the demo user" means
`<disposable-handle>`, and only `<disposable-handle>` — the smoke account
(`CHOPSHOP_UNODOS3_SECRET`). If a fresh random password is genuinely wanted,
that is the account to use, and it is the only one.

Read the credential without printing it (it stays out of argv, `ps`, and history):

```bash
set -a && . ~/.chopshop-studio.env && . ~/.hermes/.env && set +a
RAILS_ENV=production bin/rails runner 'puts User.authenticate_by_password(ENV["CHOPSHOP_UNODOS2_SECRET"])&.handle.inspect'
# => "<test-handle>"   (a nil means the stored password is NOT the one in the env file
#                 — REPORT it. Do NOT "fix" it by writing a new password:
#                 that IS the incident.)
```

A nil here is a FINDING to report, not a licence to write a new password into somebody
else's account.

`scripts/check_studio_login.py` is the same check end to end and needs no Rails console —
it logs in over loopback with the password from the env file and reports what the SERVED
response says (302 → `/jobs` 200, or 401). Pass `--against <file>` with the other password
in question: env ACCEPTED + that one REFUSED is the confirmation, and env REFUSED + that one
ACCEPTED is the incident (restore the env value; never re-reset the account). It prints no
password and never puts one on a command line.

**There is a second copy of this file: the published one under `skills/` in the studio
repo.** `~/chopshop-studio/skills/chopshop-studio/references/e2e-testing.md` is generated
from THIS file by `./sync-skills` (generation restored 2026-10-08; until then the repo-side
copy was frozen and had drifted — issue #15, which is why it long said to reset the demo
user on demand after this copy was corrected). It is what an agent working inside the repo
reads, so after editing this file republish (`./sync-skills`) and commit — an uncommitted
publish leaves the repo copy stale. If you are fixing a credential incident, check BOTH
copies before calling it closed.

`bin/rails runner` needs BOTH `RAILS_ENV=production` AND the env file sourced (it
holds `SECRET_KEY_BASE`; the systemd unit `EnvironmentFile`s it). Without the env
file: `Missing secret_key_base`. With it but without `RAILS_ENV=production`: it
silently opens the *development* DB and fails with `Could not find table 'users'`
— that error means the env, not the schema.

**But when what you are reading is env-driven CONFIG rather than a DB row, an
unsourced env file produces no error at all — it returns the DEFAULTS, and that
reads as a real answer.** `Job.form_runners` with no env file answers `["mock"]`
(the only `RUNNER_DEFAULTS` entry), so a runner census printed from such a run
looks like a deployment with a single runner rather than a command that was never
given the configuration. Always
`set -a && . ~/.chopshop-studio.env && set +a` before believing ANY config-shaped
output of `bin/rails runner`; if a list of runners, models or kinds comes back
smaller than the deployment should have, suspect the missing env file before
suspecting the registry.

**A sourced env file must PARSE, or the whole file is silently inert** — and the
symptom points somewhere else entirely. Every command that sources it keeps its
own failure: `bin/rails runner` reports `Missing secret_key_base`, and a helper
script that reads a credential from the same file just comes up empty (which
presents as an auth problem, not a syntax one). One unquoted value ending in a
bare `>` is enough: the shell parses it as a REDIRECTION and dies with
`newline unexpected` before exporting anything. So when several unrelated tools
all suddenly "lose" their configuration, check the file itself first:

```bash
sh -n ~/.chopshop-studio.env   # silent = it parses
sh -n ~/.hermes/.env
```

Log in AS `<test-handle>` to see the outputs — per-user isolation means the `<operator-handle>` account
cannot see `<test-handle>`'s jobs, so demonstrate and verify as the user the data belongs to,
and hand the operator the login + password in the report.

## The unattended check (`scripts/studio_smoke.py`)

`scripts/studio_smoke.py` runs the same idea on a schedule, against a third account
(`<disposable-handle>`), as a health check rather than a demonstration. Run it directly to prove
the whole surface end to end; the cron just calls it.

```bash
cd ~ && python3 ~/.hermes/skills/software-development/chopshop-studio/scripts/studio_smoke.py
--list      # print the plan and exit: no login, no jobs
--dry-run   # log in and report, but file nothing
--only bp   # substring filter over the steps
--skip flux # drop a step whose dependency is busy (repeatable)
--keep 3    # after the pass, prune this account's older smoke runs
```

**A PASS IS ONE JOB, AND THE RUN ID IS IN ITS NAME (operator rule, 2026-09-29).**
The eight operations ride as `spec["steps"]` on ONE record, so an hourly pass adds
ONE row to the job list instead of eight; the name is `smoke-<run-id>` with the run
id stamped ONCE before the first submit. Per-submit minute stamps were the old
shape's defect: a pass that crossed a minute boundary filed `…-1712` and `…-1713`
and the set stopped being greppable as one thing (measured: jobs 432-439).
`--individual` still files one job per step, now stamped with the SAME run id, and
that is the mode that isolates a single failing step. `--keep N` deletes only this
account's own `smoke-*` jobs beyond the newest N runs — the app's per-user scoping
plus the name prefix, so no other user's row and no hand-filed job is reachable.

**Step order is DEPENDENCY-FREE: the trace goes FIRST, taking the job's own
uploaded artwork.** A trace step can only take the job's artwork as STEP 1 —
`step_takes_previous?` counts only `"previous"` or a blank input as a hand-off, so a
later trace step is validated against the step above it and `input: "job"` is
refused there with a message about that step's extension. Keeping it first means
`--skip` any other step, or losing one (a busy GPU), cannot take a second step down
with it.

The password comes from `CHOPSHOP_UNODOS3_SECRET` in `~/.hermes/.env` (or
`--password-file`, or stdin). It never appears on a command line, so it never lands in
`ps` or shell history.

**The `doc` blocks are copied from chopshop-bp's own `examples/*.json` — never
hand-write them.** A first attempt wrote all eight by hand and the service refused
four: `generate` needs a `canvas` block and coordinate-pair points (not an SVG points
string), `tree` needs `nodes` + `edges` with a `kind` on every node (not a `root`),
`query` needs a chart plus axes plus a NON-EMPTY `runs`, and `blender` refuses an
empty `elements` unless the document carries a `tiling`. A plausible-looking spec
tests nothing but its author's imagination; a fixture the service's own validator
accepts is worth something. When adding a step, copy from `~/chopshop-bp/examples/`
and confirm with the service's own validator before submitting it unattended.

**Why it submits one job at a time — do not "optimise" this.** The studio already
serialises every job through a single Solid Queue worker thread, so one job in flight
is one unit of work and the script can never add a second. The order is cheapest-first
(bp plot → blender → trace → flux) so an interrupted run leaves the cheap work done
and the GPU run undone; flux is last and once-per-pass because it is the only operation
that reaches for a GPU on another host. Parallelising it would trade the load control
for wall-clock.

The cron runs hourly with `deliver=local`, so its output is **saved, not delivered** —
read it with `cronjob list` / the run history rather than expecting a message. Confirm
the account is really accumulating:

```bash
sqlite3 ~/chopshop-studio/storage/production.sqlite3 \
  'select owner, count(*) from jobs group by owner;'
```

## A live smoke pass driven over HTTP (the bash shape)

When the ask is "run the demo tests once", a single sequential pass over the live
stack as its own user is the deliverable — not a load test, and not the Rails suite.
`script/demo_smoke.sh` in the studio repo is the shape. These cost real time to find:

- **Login needs a CSRF token from `/login`'s meta tag BEFORE the POST.** A bare
  `POST /login` is a 422; the meta token (not the form's `authenticity_token`) is
  valid for any non-GET in the session, and the cookie jar is the whole session.
  Re-scrape a token after any page reload — they are masked per request.
- **`--data-urlencode` on a joined `"a=1&b=2"` string encodes the WHOLE thing as
  ONE field named `a`** and silently drops every parameter after it. Pass each
  `key=value` as its own `--data-urlencode` argument.
- **Never wrap a `job[spec]` value in literal `{...}`.** Rails parses
  `job[spec]={...}` one nesting level deeper than intended and the spec lands
  nowhere, which surfaces as the model's own "needs an operation/document"
  refusal — not a parse error. Post the spec string bare.
- **A `bp` job create from an agent must post `job[input_path]=` explicitly.**
  `JobsController#blank_document_source!` covers `plot`/`blender` but not `bp`, so
  the `jobs.input_path` NOT NULL fires and is reported as a misleading
  "runner connection failed". (App bug, not a script workaround.)
- **Read the job id out of the `Location` header, reduced to a path.** The app
  answers with an absolute `https://…` URL; strip the scheme+host before matching
  `/jobs/<id>`. A composite create redirects to `/composite?id=N`, not `/composites/:id`.
- **Candidate files are named `<job-stem>-candidate-NN.svg`** (hyphen, job stem
  prefixed). Scrape the job page for the name rather than reconstructing it.
- **`/engine.json` is the runner census** — read the labels and health from the
  app rather than hardcoding them, so a deployment that adds a label is seen.
- **Build nested JSON specs with `jq -nc`, never shell string interpolation** —
  the shell cannot nest the quotes and the result is a malformed spec.

File every job of a run under one project so a re-run never touches another
project's history. Size poll deadlines against MEASURED timings (a 6-candidate
trace is ~40s, a klein-4b 512px raster ~10s), not guesses. Use a dedicated
disposable demo account (its own handle + owner scoping) rather than reusing the
operator's, so the run's jobs are cleanly attributable and removable.

## The per-account demo (`scripts/studio_users_demo.py`)

The ask "run a demo test across all users" wants every account PROVEN, not just
the test one: one pass logs in as each handle in its own cookie jar, files ONE job
named `demo-<run id>-<handle>`, polls it to a terminal state, and fetches the
produced file **with that account's own session** (a non-owner's fetch is an HTML
error page at 200, so the check reads the bytes).

```bash
cd ~ && E2E_PW_FILE=/tmp/e2e_pw.txt \
  python3 ~/.hermes/skills/software-development/chopshop-studio/scripts/studio_users_demo.py
```

It also asserts ISOLATION rather than assuming it: each session's own jobs index
must link to none of the other accounts' job ids, and a cross-account job page
must answer 404 (measured: `<operator-handle>` opening `<test-handle>`'s job → 404). Every password
comes from the env files (`CHOPSHOP_PASSWORD`, `CHOPSHOP_UNODOS2_SECRET`,
`CHOPSHOP_UNODOS3_SECRET`) — there is no reset step and none is needed.

## A prune keyed off page ORDER deletes the wrong rows

When pruning by run id, parse the page ROW-SCOPED — the anchor is the row
partial's own `data-href="/jobs/<id>"` and the name is read out of THAT row.
A "if that matched nothing, pair the page's ids with the page's names" fallback is
not a pairing: every job is rendered TWICE (a table row and a grid card) and the
lists have different lengths, so it deleted a scatter of unrelated rows in the
account (56 attempts, most already gone) instead of the runs it had just named.
A prune whose key is a guess must refuse to delete rather than delete wrongly, and
`--dry-run` on the prune path is how you see the plan before it runs. The blast
radius is bounded by the app's own per-user scoping — only the signed-in account's
rows are reachable, foreign ids answer 404 — which is why that check lives in the
app and not in the script.

The old one-job-per-step rows (`<step>-<stamp>`, no `smoke-` prefix) are invisible
to `--keep`; `--prune-legacy [--dry-run]` collects them by their own name shapes,
row-scoped again.

## A concurrent `bin/rails test` reads as catastrophic and is not

If a cron or background process is running the suite while you run it yourself, both
hold `storage/test.sqlite3`'s WAL and the whole suite fails with hundreds of
`ActiveRecord::StatementTimeout: SQLite3::BusyException` — which reads as total code
breakage and is pure contention. **Diagnose before touching any code:**

```bash
fuser -v storage/test.sqlite3                                          # names the holding PID
pgrep -af 'bin/rails test' | grep -vE 'bash|hermes-snap|pgrep'        # find the stray
```

The `grep -v` is load-bearing: a bare `pgrep -f 'bin/rails test'` matches the polling
command's own cmdline. Kill the stray, re-run, and if the re-run is green it was never
your change — a clean re-run is the disambiguator, and taking a mass-failure result at
face value sends you debugging a green codebase.
