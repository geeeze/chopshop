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

**`<test-handle>` IS THE OPERATOR'S OWN ACCOUNT — NEVER RESET ITS PASSWORD.
`<disposable-handle>` IS THE THROWAWAY ONE.** "Reset the demo user" means
`<disposable-handle>`, and only `<disposable-handle>`.

This is not a fixture. The second account is the operator's own, its password is
an operator-owned env file entry, and the operator set it there by hand. A
"rotate it to a fresh temp password before the run" step does not reset a test
fixture — it DESTROYS an operator credential, silently, every time an agent
follows documented procedure. Measured: three resets in one day from agents
following this page (the credential digest's `updated_at` moved each time), and
each one invisible to the person it burned. The account looked disposable and
nothing said otherwise; that is the entire failure.

So:

- **`<test-handle>`** (`CHOPSHOP_UNODOS2_SECRET` on the box; redacted here) — the
  operator's second account. **Never write a password to it.** Read the
  credential; if it does not authenticate, that is a FINDING to report, never a
  licence to overwrite somebody else's account.
- **`<disposable-handle>`** (`CHOPSHOP_UNODOS3_SECRET` on the box) — the
  disposable smoke account. If a genuinely fresh random password is wanted, it
  is generated for THIS account and no other.

`E2E_PW_FILE` is an explicit override for a throwaway account only. Nothing here
needs it.

Read the credential without printing it — it must stay out of `argv`, `ps` and
shell history:

```bash
set -a && . ~/.chopshop-studio.env && . ~/.hermes/.env && set +a
RAILS_ENV=production bin/rails runner 'puts User.authenticate_by_password(ENV["CHOPSHOP_UNODOS2_SECRET"])&.handle.inspect'
# => "<test-handle>"   (a nil means the stored password is NOT the one in the env file
#                       — REPORT it. Do NOT "fix" it by writing a new password:
#                       that IS the incident.)
```

`scripts/check_studio_login.py` is the same check end to end and needs no Rails
console: it logs in over loopback with the password from the env file and reports
what the SERVED response says (302 → `/jobs` 200, or 401). Pass `--against
<file>` with the other password in question: env ACCEPTED + that one REFUSED is
the confirmation; env REFUSED + that one ACCEPTED is the incident — restore the
env value, and NEVER re-reset the account to make the symptom go away. It prints
no password and never puts one on a command line.

`bin/rails runner` needs BOTH `RAILS_ENV=production` AND the env file sourced (it
holds `SECRET_KEY_BASE`). Without the env file: `Missing secret_key_base`. With
it but without `RAILS_ENV=production`: it silently opens the *development* DB and
fails with `Could not find table 'users'` — that error means the env, not the
schema.

**A sourced env file must PARSE, or the whole file is silently inert** — and the
symptom points somewhere else entirely. Every command that sources it keeps its
own failure: `bin/rails runner` reports `Missing secret_key_base`, and a helper
script reading a credential from the same file just comes up empty (which
presents as an auth problem, not a syntax one). One unquoted value ending in a
bare `>` is enough: the shell parses it as a REDIRECTION and dies with `newline
unexpected` before exporting anything. When several unrelated tools all suddenly
"lose" their configuration, check the file itself first:

```bash
sh -n ~/.chopshop-studio.env   # silent = it parses
sh -n ~/.hermes/.env
```

Log in AS `<test-handle>` to see the outputs — per-user isolation means the
`<operator-handle>` account cannot see `<test-handle>`'s jobs, so demonstrate and
verify as the user the data belongs to, and hand the operator the login in the
report. (Do not hand over a PASSWORD that was rotated to satisfy the demo: the
operator's credential is the one in their env file, and the report should say so
rather than shipping a throwaway value as if it were the account's.)

## The unattended check (HOST-SPECIFIC: `studio_smoke.py`)

> Not vendored in this repo's `skills/chopshop-studio/scripts/` (which holds only
> `verify-ui-clicks.js`); the runnable copy lives on the host at
> `~/.hermes/skills/software-development/chopshop-studio/scripts/studio_smoke.py`.
> The heading's old `scripts/…` path was repo-relative and did not exist here.

`studio_smoke.py` runs the same idea on a schedule, against the
DISPOSABLE account (`<disposable-handle>` / `CHOPSHOP_UNODOS3_SECRET`), as a
health check rather than a demonstration. Run it directly to prove the whole
surface end to end; the cron just calls it.

```bash
cd ~ && python3 ~/.hermes/skills/software-development/chopshop-studio/scripts/studio_smoke.py
--list      # print the plan and exit: no login, no jobs
--dry-run   # log in and report, but file nothing
--only bp   # substring filter over the steps
--skip flux # drop a step whose dependency is busy (repeatable)
--keep 3    # after the pass, prune this account's older smoke runs
```

**A PASS IS ONE JOB, AND THE RUN ID IS IN ITS NAME.** The operations ride as
`spec["steps"]` on ONE record, so a pass adds ONE row to the job list instead of
eight; the name is `smoke-<run-id>` with the run id stamped ONCE before the first
submit. Per-submit minute stamps were the old shape's defect: a pass crossing a
minute boundary filed `…-1712` and `…-1713` and the set stopped being greppable as
one thing. `--individual` still files one job per step, stamped with the SAME run
id, and is the mode that isolates a single failing step. `--keep N` deletes only
this account's own `smoke-*` jobs beyond the newest N runs — the app's per-user
scoping plus the name prefix, so no other user's row and no hand-filed job is
reachable.

**Step order is DEPENDENCY-FREE: the trace goes FIRST, taking the job's own
uploaded artwork.** A trace step can only take the job's artwork as STEP 1, so a
later trace step is validated against the step above it and `input: "job"` is
refused there. Trace first means `--skip`ping any other step — or losing one to a
busy GPU — cannot take a second step down with it.

**Why it submits one job at a time — do not "optimise" this.** The studio already
serialises every job through a single Solid Queue worker thread, so one job in
flight is one unit of work and the script can never add a second. The order is
cheapest-first (bp plot → blender → trace → flux) so an interrupted run leaves the
cheap work done and the GPU run undone; flux is last and once-per-pass because it
is the only operation that reaches for a GPU on another host. Parallelising it
would trade the load control for wall-clock.

## The per-account demo (HOST-SPECIFIC: `studio_users_demo.py`)

> Not vendored in this repo's `skills/chopshop-studio/scripts/` either; runnable
> copy: `~/.hermes/skills/software-development/chopshop-studio/scripts/studio_users_demo.py`.

The ask "run a demo test across all users" wants every account PROVEN, not just
the test one: one pass logs in as each handle in its own cookie jar, files ONE job
named `demo-<run id>-<handle>`, polls it to a terminal state, and fetches the
produced file **with that account's own session** (a non-owner's fetch is an HTML
error page at 200, so the check reads the bytes).

```bash
cd ~ && E2E_PW_FILE=/tmp/e2e_pw.txt \
  python3 ~/.hermes/skills/software-development/chopshop-studio/scripts/studio_users_demo.py
```

Every password comes from the env files (`CHOPSHOP_PASSWORD`,
`CHOPSHOP_UNODOS2_SECRET`, `CHOPSHOP_UNODOS3_SECRET`) via the script's
`load_passwords()`. **There is no reset step and none is needed** — the script
never writes a password to any account, which is the point: it demonstrates the
per-user isolation without needing to break a credential to get in.

It also asserts ISOLATION rather than assuming it: each session's own project
workspace's jobs list must link to none of the other accounts' job ids, and a cross-account job page
must answer 404. And it demonstrates as the operator's own account, which is only safe BECAUSE it authenticates with the stored password.

## A prune keyed off page ORDER deletes the wrong rows

When pruning by run id, parse the page ROW-SCOPED — the anchor is the row
partial's own `data-href="/jobs/<id>"` and the name is read out of THAT row. A
"if that matched nothing, pair the page's ids with the page's names" fallback is
not a pairing: every job is rendered TWICE (a table row and a grid card) and the
lists have different lengths, so it deleted a scatter of unrelated rows in the
account instead of the runs it had just named. A prune whose key is a guess must
refuse to delete rather than delete wrongly, and `--dry-run` on the prune path is
how you see the plan before it runs. The blast radius is bounded by the app's own
per-user scoping — only the signed-in account's rows are reachable, foreign ids
answer 404.

## A concurrent `bin/rails test` reads as catastrophic and is not

If a cron or background process is running the suite while you run it yourself,
both hold `storage/test.sqlite3`'s WAL and the whole suite fails with hundreds of
`ActiveRecord::StatementTimeout: SQLite3::BusyException` — which reads as total code
breakage and is pure contention. **Diagnose before touching any code:**

```bash
fuser -v storage/test.sqlite3                                          # names the holding PID
pgrep -af 'bin/rails test' | grep -vE 'bash|hermes-snap|pgrep'        # find the stray
```

The `grep -v` is load-bearing: a bare `pgrep -f 'bin/rails test'` matches the
polling command's own cmdline. Kill the stray, re-run, and if the re-run is green
it was never your change — a clean re-run is the disambiguator, and taking a
mass-failure result at face value sends you debugging a green codebase.
