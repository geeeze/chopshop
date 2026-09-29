# Driving Chopshop Studio over HTTP — the agent contract

The studio is a web app a browser uses, but **an agent is a first-class caller**:
almost every action has a scriptable path, and this document is the canonical
description of it. Everything here was verified against the app in this repo —
not read off a slide — with the notes at the end saying how.

This file replaces the earlier `agent-usage-report.md`, which predated the users
table; its findings are folded in below with the parts that have since changed
called out.

- [The 60-second version](#the-60-second-version)
- [Login and identity](#login-and-identity)
- [CSRF: two tokens, only one of them is reusable](#csrf-two-tokens-only-one-of-them-is-reusable)
- [Filing a job](#filing-a-job)
- [JSON: which routes have it, which do not](#json-which-routes-have-it-which-do-not)
- [Polling and reading a run](#polling-and-reading-a-run)
- [Picking a candidate and making a proof](#picking-a-candidate-and-making-a-proof)
- [Collecting the result](#collecting-the-result)
- [Composing: the recipe is the contract](#composing-the-recipe-is-the-contract)
- [Cancelling and deleting](#cancelling-and-deleting)
- [The https-`Location`-over-http gotcha](#the-https-location-over-http-gotcha)
- [Health: runners and the system aggregate](#health-runners-and-the-system-aggregate)
- [Things that bite](#things-that-bite)
- [How these claims were verified](#how-these-claims-were-verified)

---

## The 60-second version

```bash
BASE="${CHOPSHOP_BASE:-http://localhost:3000}"   # wherever the studio listens
JAR="$(mktemp)"                                  # the cookie jar is not optional

# 1. the login page: take the SESSION token out of the meta tag, not the form
PAGE="$(curl -sS -c "$JAR" -b "$JAR" "$BASE/login")"
TOKEN="$(printf '%s' "$PAGE" | sed -n 's/.*name="csrf-token" content="\([^"]*\)".*/\1/p' | head -1)"

# 2. log in (the password IS the identity)
curl -sS -i -c "$JAR" -b "$JAR" -X POST "$BASE/login" \
  -H "X-CSRF-Token: $TOKEN" --data-urlencode "password=$CHOPSHOP_PASSWORD"

# 3. upload a raster -> JSON
UP="$(curl -sS -c "$JAR" -b "$JAR" -X POST "$BASE/jobs/upload" \
  -H "X-CSRF-Token: $TOKEN" -F "file=@artwork.png")"
PATH_ON_DISK="$(printf '%s' "$UP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["path"])')"

# 4. file the job -> 302 to the job page; follow the Location
curl -sS -i -c "$JAR" -b "$JAR" -X POST "$BASE/jobs" \
  -H "X-CSRF-Token: $TOKEN" \
  --data-urlencode "job[name]=agent-curl-probe" \
  --data-urlencode "job[source_kind]=raster" \
  --data-urlencode "job[input_path]=$PATH_ON_DISK" \
  --data-urlencode "job[runner]=mock" \
  --data-urlencode 'job[spec]={"print_method":"screen_print","max_colors":6}'

# 5. poll the JSON branch until done is true
curl -sS -c "$JAR" -b "$JAR" "$BASE/jobs/37.json"
# {"done":false,"log_html":"queued"}
```

Then read the candidate list off the job page, `POST /proofs` to make one, and
`GET /jobs/:id/download` for the bundle. Details for each step follow.

## Login and identity

- **There is no username.** The password identifies the user: `User.authenticate_by_password`
  compares the entered password against every user's digest until one matches
  (`app/models/user.rb`). The matched user's `handle` becomes the owner key on
  every row that user creates.
- **Every job, candidate, proof, scrapbook item, composite and event is
  owner-scoped** to that handle by a `default_scope` (`Owned`). A second operator
  cannot see the first's jobs — and neither can an agent that logs in as the
  wrong user. This is the biggest change since the old report, which assumed a
  single shared password gate over one global list.
- **`POST /login`** takes `password` (form-encoded or multipart) plus a valid CSRF
  token. Success is a `302` into the app (`GET /jobs` then answers `200`) and a
  session cookie; a wrong password is `401` with the login page again, and is
  written to `log/chopshop-auth.log` for fail2ban. Do not retry a wrong password
  in a loop — the failure is deliberate and logged.
- **Keep the cookie jar.** The session cookie is the whole session; there is no
  bearer token or API key. `curl -c jar -b jar` (or your HTTP client's cookie
  store) on every request.
- **`DELETE /logout`** ends the session (`reset_session`).
- Adding a user is a one-liner on the deployment:
  `bin/rails runner 'User.create!(handle: "…", password: "…")'`. The studio has
  no signup surface.

## CSRF: two tokens, only one of them is reusable

Rails protects every non-GET request. The studio uses `load_defaults 8.1`, which
turns on **per-form CSRF tokens**, and that produces the one gotcha that costs
agents the most time:

| token | where it is | what it is valid for |
|---|---|---|
| `<meta name="csrf-token" content="…">` | the `<head>` of **every** page, including `/login` | **any** non-GET request in this session — put it in `X-CSRF-Token` |
| `<input name="authenticity_token" value="…">` | inside a form | **only that form's action and method** — the login form's token is for `POST /login` and nothing else |

So: **scrape the meta tag, send it as `X-CSRF-Token`.** An
`authenticity_token` parameter is accepted too (Rails checks both), but a token
lifted from a form field is rejected (`422`) on any other action — verified, not
assumed.

Measured behaviour, with forgery protection on:

- the meta token is valid **across login**: a token taken from `GET /login` and
  sent after logging in was accepted (`200`), so the "pre-login token goes
  stale" note in the audit is not what happens. What is rejected is the *form's*
  token used elsewhere.
- the meta token **string differs between page loads** (tokens are masked per
  request, to blunt BREACH). Re-scrape it if you reload a page; a token you
  already hold stays valid for the session.
- no token at all is `422` (Rails' `InvalidAuthenticityToken`).
- **GET requests need no token.** Reads are never gated on CSRF.

## Filing a job

`POST /jobs` is the create endpoint. `job[name]` is required; the rest:

| field | shape | notes |
|---|---|---|
| `job[name]` | string | required; the slug for the run comes from it |
| `job[source_kind]` | `raster` \| `svg` | studio-side bookkeeping; the runner ignores it |
| `job[input_path]` | string | the **stored** path returned by `POST /jobs/upload`. For a plot or blender job there is no raster, so it may be omitted (the app stores an empty string) |
| `job[runner]` | one of `Job.runners` keys | which runner runs it. **Validated by inclusion** against the configured labels, and the labels are env-driven (`CHOPSHOP_RUNNER_<LABEL>_URL`) — ask the app (`/engine.json`) rather than guessing |
| `job[spec]` | a **JSON string** | the print contract. `{}` is legal; an unparseable string is a validation failure, not a crash |

**On `job[runner]` being "required"** — the old report said a create without it
failed validation and had to be fixed by adding `job[runner]=mock`. That is no
longer accurate: the column carries the schema default `"mock"`, so an omitted
`runner` saves as a `mock` job and the request is accepted. Send it anyway: it
costs one field and it is the only way to say *which* runner you meant, and a
deliberate `job[runner]=<unknown>` is still refused (`422`,
`"Runner is not included in the list"`).

For a **flux** job the spec carries the generation block
(`spec.flux.prompt`, `mode`, `model`, `width`, `height`, …) and the job is
queued for generation instead of tracing; a `spec.flux.image` reference must be a
**basename of a stored upload**, never a path. For a **plot**/**blender** job the
spec carries the operation (`spec.plot.op` ∈ `generate|digest|query` plus
`doc`) or the geometry document (`spec.blender.doc`); `doc`/`runs` may be pasted
as JSON strings and the app parses them.

## JSON: which routes have it, which do not

The studio is HTML-first: JSON exists on the routes that need it, and asking for
JSON on a route that has none is a hard `406`, not a silent HTML page.

| request | JSON? | shape |
|---|---|---|
| `POST /jobs/upload` | **always JSON** | `{path, preview_url, name, size}` |
| `POST /jobs` (success) | **no** — a `302` whose body is HTML | follow `Location` for `/jobs/:id` |
| `POST /jobs` (failure, `Accept: application/json`) | yes | `422 {error}` |
| `POST /jobs` (failure, no Accept) | no | `422` with the re-rendered form |
| `GET /jobs/:id` | yes, via **either** `Accept: application/json` or the `.json` extension | `{done, log_html}` |
| `GET /jobs/:id.json?log=1` | yes | `{log: […]}`, the runner's log tail |
| `GET /jobs/:id.json?candidate=<file>` | yes, when the job's comparison exists | `{file, job, spec, sweep, proof}` (the sweep entry plus that candidate's proof manifest); `404` when the comparison has no such candidate; the plain `{done, log_html}` when there is no comparison at all |
| `GET /jobs` and `GET /jobs.json` | **no JSON branch — `406`** | parse the HTML row (`a.cs-job-name`, `href="/jobs/:id"`) if you need the history |
| `GET /proofs/:id.json` | yes | `{done: bool}` |
| `POST /proofs/:id/ask_jev` | yes, or a `302` for a form post | the sidecar's answers as the popup's JSON |
| `GET /events` | **always JSON** (whatever the `Accept` header says) | `[{id, event, job_id, svg_sha, pos, ranker, payload, created_at}]` |
| `GET /scrapbook` | **always JSON** | `[{id, name, kind, url, job_id, sha256, vector, size, created_at}]` — `vector` says whether the stored bytes are an SVG |
| `GET /composite/layers` | **always JSON** | `[{id, name, kind, layer_kind, item_kind, vector, url}]` — `kind`/`layer_kind` are the LAYER kind (`vector` for an SVG item, else `raster`), `item_kind` the scrapbook artefact kind |
| `GET /composite/:id/recipe` | **always JSON** | the compose spec (below): `{width, height, background, palette, layers: [{type, src, x, y, w, h, opacity, hue}]}` |
| `GET /engine.json` | **always JSON** | the system aggregate (below) |
| `GET /up` | no | the Rails health check, `200`/`500` |

The rule of thumb: **use `Accept: application/json` for `POST /jobs/upload`,
`POST /proofs/:id/ask_jev` and the `.json` read routes; do not expect JSON from a
*succeeded* `POST /jobs`** — that is an HTML `302` whatever you send. Asking the
jobs index for JSON is a `406`.

## Polling and reading a run

- `POST /jobs` puts the job in `queued` immediately and a single worker
  dispatches it (`RunJob`), so the create response is **not** the run's result.
- Poll `GET /jobs/:id.json` for `{"done": bool}`; `done:false` covers
  `pending|queued|running`.
- Reading the state out of the HTML is possible but easy to get wrong: the first
  `status-pill status-*` on the page can be a *candidate* pill. The
  authoritative job state is `<span class="gradient-text job-state">· <state></span>`.
- The states are `pending`, `queued`, `running`, `done`, `error`, `cancelled`.
- The candidate list is the `comparison` the runner reported: each entry carries
  `file`, `sweep` (the VTracer parameters), `layer_a`, `layer_b`, `hard`,
  `advisory`, `fidelity`, `passed`, plus a derived `fidelity_verdict`. **The list
  is ordered; it is not a ranking that decided anything** — a human still picks.
  `GET /jobs/:id` renders it as a table.
- `GET /jobs/:id/refresh` forces a sync from the runner and redirects back.

## Picking a candidate and making a proof

There is no "choose" endpoint that records a winner: the pick *is* running the
back half (a proof) on one candidate, and the studio records that as a `pick`
event with the candidate's position on the list.

```bash
curl -sS -i -c "$JAR" -b "$JAR" -X POST "$BASE/proofs" \
  -H "X-CSRF-Token: $TOKEN" \
  --data-urlencode "job_id=37" \
  --data-urlencode "candidate_file=candidate_03.svg"
# 302 -> /proofs/<id>   (the proof page; it also appears on the job page)
```

- the parameters are **top level** (`job_id`, `candidate_file`), not nested under
  `validation[...]`; the candidate must belong to a `done` job.
- the proof is created `pending`, the runner is asked for a validation, and the
  page polls it. `GET /proofs/:id.json` → `{done: bool}`.
- `POST /proofs/:id/ask_jev` asks the decision sidecar about that proof's
  manifest. It is answered **once** and the stored answer is replayed, so a
  repeated call costs nothing: use it freely to poll for the answer. The runner
  distinguishes "the add-on is not configured here" (`503`, with the reason) from
  "the call failed" — a `503` will not fix itself by retrying.

## Collecting the result

| what | how |
|---|---|
| one artefact (candidate SVG, proof PNG, print PDF, manifest) | `GET /jobs/:id/file/<name>` — `<name>` is the runner's own basename; add `?download=1` for an attachment |
| the whole job | `GET /jobs/:id/download` — a `7z` attachment of the job directory (a flux job gets the studio's own provenance archive, with the runner's bundle inside it). The job must be `done` |
| a stored upload / a preview | `GET /jobs/upload_preview/<basename>` |
| the history | `GET /jobs` (HTML) |

## Composing: the recipe is the contract

A **composite** (the Compose builder) is layers placed on a canvas, and it is
flattened into a job's artwork on demand. Two flattens exist, and the composite's
layers decide which one runs:

- **raster** (the original): every layer is pixels, the browser rasterises the
  canvas, and `POST /composite/:id/flatten` stores the posted PNG twice — a
  scrapbook item and an upload. `mode: "raster"` comes back.
- **vector**: any layer whose `kind` is `"vector"` (an SVG scrapbook item) is
  composed by the **svg runner** instead, so a traced source stays a trace
  instead of being rasterised and re-traced. The studio POSTs the merged document
  to the runner's `/compose`, stores the SVG it answers with the same way, and
  answers `mode: "vector"`, `content_type: "image/svg+xml"`.

Both answer the same JSON shape, so the caller stores either:

```json
{ "scrapbook_id": 12, "path": "/app/storage/uploads/upload_…svg",
  "preview_url": "/jobs/upload_preview/upload_…svg",
  "content_type": "image/svg+xml", "mode": "vector" }
```

**The recipe is the one contract to read.** Do not rebuild the compose spec from
the composite's JSON — ask for it:

```bash
curl -sS -b "$JAR" "$BASE/composite/3/recipe"
```

```json
{ "width": 3000, "height": 3000, "background": "transparent",
  "palette": ["#101010", "#f2f2f2"],
  "layers": [
    { "type": "svg",
      "src": "<svg xmlns=\"http://www.w3.org/2000/svg\" …</svg>",
      "x": 120, "y": 80, "w": 900, "h": 600, "opacity": 0.8, "hue": 30 },
    { "type": "raster", "src": "data:image/png;base64,iVBORw0…",
      "x": 0, "y": 0, "w": 3000, "h": 3000 }
  ] }
```

What to know about it:

- **`src` is inline, never a path.** A vector layer carries the SVG's own TEXT; a
  raster layer a `data:` URI. The runner is on another box and cannot read this
  app's `storage/`, which is exactly why the studio resolves it for you.
- **This is the document the studio POSTs.** `POST /composite/:id/flatten` sends
  `{"op": "compose", "spec": <this document, with nil-valued keys omitted>}` to
  the svg runner's `/compose`, so composing it yourself and collecting the
  response reproduces the studio's own flatten. Which runner:
  `CHOPSHOP_COMPOSE_URL`, or the runner named by `CHOPSHOP_COMPOSE_RUNNER`, or
  the first svg-kind runner. The one difference: an absent palette is `null` here
  and OMITTED on the wire (the contract makes `palette` optional).
- **`palette` is optional and omitted when empty.** Set it on the composite (a
  comma-separated list of `#rrggbb`, `POST`/`PATCH /composite`), or override it
  for one request with a `palette` parameter on the recipe or the flatten.
- **A layer with no `kind` is raster**, and an invisible layer is not in the
  spec at all (the wire contract has no `visibility`). An SVG layer is sent as
  `type: "svg"` even if an old layer forgot to say `vector`, because the bytes
  decide — rasterising a trace is the failure this path exists to prevent.
- **The recipe is login- and owner-scoped** like the composite itself, and it is
  a `422 {error}` when a vector layer's source is missing or is not an SVG (never
  a half-composed document).
- The flatten also accepts `mode: "raster"` (or `raster=1`) to force the PNG path
  for a composite that holds vectors — a deliberate screenshot.

## Cancelling and deleting

- `POST /jobs/:id/cancel` → `302` to `/jobs`; JSON answers `{ok}`. A job still
  queued is discarded before it runs; a dispatched one is cancelled at its
  runner.
- `DELETE /jobs/:id` → `302` to `/jobs`. It logs a `delete` event first (the
  event outlives the job — it carries provenance only), tells the runner to drop
  its files, then removes the row.
- Both are non-GET, so both need the CSRF header.

## The https-`Location`-over-http gotcha

In production the app runs behind a TLS-terminating proxy and is configured with

```ruby
config.assume_ssl = true     # treat the proxied request as if it arrived over https
config.force_ssl = true      # and never serve it as plain http
```

so **redirects and generated URLs come back as `https://…` even when you are
talking plain HTTP to the app's listener** (verified historically on a loopback
deployment; it is a consequence of that configuration, not of the request).
What to do:

- **follow `Location` by path, not by absolute URL** — take the path (and query)
  and re-issue it against the base you are already using;
- never rewrite the scheme to `https` "to match", or attempt TLS against a plain
  listener: the session worked over plain http, which is the point.

If your client refuses redirects it cannot reach (some do, over a scheme
mismatch), just patch the path in yourself: `Location: https://…/jobs/37` means
`GET $BASE/jobs/37`.

## Health: runners and the system aggregate

- `GET /up` is the app's own liveness check (Rails' built-in), no session needed.
- **`GET /engine.json`** is the aggregate for an agent — the machine-readable
  twin of the footer's check-engine light. It needs a session, and it answers:

```json
{
  "ok": true,
  "generated_at": "2026-09-28T20:17:10Z",
  "owner": "<the signed-in handle>",
  "cold": true,
  "runners": [
    { "label": "mock", "kind": "svg", "url": "http://127.0.0.1:8790",
      "healthy": true, "health": { "ok": true, "mode": "mock", /* … */ },
      "error": null }
  ],
  "events": { "total": 0, "by_kind": { "star": 0, "unstar": 0, "pick": 0, "delete": 0 } },
  "counts": { "jobs": 0, "candidates": 0, "scrapbook": 0 },
  "ranker": {
    "state": "cold",
    "recorded_events": 0,
    "picks": 0,
    "jobs_with_picks": 0,
    "thresholds": { "min_picks": 30, "min_jobs": 2 },
    "learned_files": ["learned_ranker.json", "learned_buckets.json"],
    "learning_dir_env": "PIPELINE_LEARNING_DIR",
    "shipped": [ /* the ML/ranking constants, grouped as the STATUS page shows them */ ]
  }
}
```

- `GET /engine` is the same document (json is the route's default format).
- every count is **the signed-in owner's**; `runners` is deployment-wide and
  reports each configured label's `kind` and liveness. A dead runner is data —
  `healthy: false` plus the reason in `error` — never a failed request. That is
  what makes it safe to call first: it tells you which runner labels exist before
  you try to file a job against one.

## Things that bite

- **No `RUNNER_TOKEN` needed by *you*.** If the deployment sets `RUNNER_TOKEN`,
  the *studio* sends it to runners; your calls use only the session cookie. (The
  older report noted a deployment where no token was configured at all, and
  studio → runner calls went unauthenticated over loopback. Both are normal.)
- **The reference field is a basename.** `spec.flux.image` (an img2img
  reference) must be the basename of a **stored upload**; anything else is
  refused, and a path is never honoured.
- **Inspection runs use the deployment's environment.** A bare
  `bin/rails runner` reads the *development* database; to inspect the deployed
  data, set `RAILS_ENV=production` and source the deployment's env file. Read-only,
  and don't print the values.
- **`allow_browser versions: :modern`** does not block a plain client: `curl`,
  no `User-Agent`, and a modern Chrome UA all reached `/jobs` (`200`) in
  verification. No UA spoofing is required.
- **Unknown format is a `406`, not a fallback.** If you ask for JSON on an HTML
  route, you get a `406` page — see the table above.
- **`job[spec]` is a string.** Send JSON *text* (`--data-urlencode 'job[spec]={"…":…}'`),
  not a nested form field.

## How these claims were verified

- **Against the code**: `config/routes.rb`, `app/controllers/*`, `app/models/*`
  (`User`, `Job`, `Event`, `Telemetry`), `app/lib/runner_client.rb` — the shapes
  and status codes above are read from the actions that produce them.
- **Empirically**: an `ActionDispatch::IntegrationTest` probe with
  `allow_forgery_protection = true` (the test env disables it) drove the real
  login form, the real CSRF checks and the real create/upload paths. Results:
  meta token accepted pre- and post-login in `X-CSRF-Token` **and** as an
  `authenticity_token` parameter; the login **form's** token rejected with `422`
  elsewhere; no token `422`; `POST /jobs` `302` with and without a JSON `Accept`;
  a failing create `422` JSON with `Accept: application/json`; `GET /jobs/:id.json`
  JSON with or without the header; `GET /jobs` **`406`** for JSON; `GET /events`
  JSON regardless of `Accept`; `GET /proofs/:id.json` `{done:true}`; and the
  job-state span text.
- **Pinned by tests**: `test/controllers/agent_driven_job_test.rb` (the no-browser
  path end to end: login, upload JSON contract, create, history),
  `test/controllers/engine_json_test.rb` (the aggregate's shape, the login gate
  and the owner scoping), and `test/controllers/composite_recipe_test.rb` (the
  layer kind and its raster default, the recipe document, the vector flatten's
  compose POST and the raster flatten's PNG path). `test/controllers/auth_gate_test.rb`
  enumerates the router and asserts every operator route bounces an anonymous
  caller to `/login`.
- The 2026-09-27 deployment report the previous version of this file was based on
  is preserved in git history; its remaining true findings (the runner without a
  token, the https `Location`, `RAILS_ENV` for inspection) are restated above.
