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

The demo user is `<test-handle>`; its password is NOT in context, so reset it on demand —
never inline it in a shell command line (it lands in history / `ps`):

```
umask 077 && openssl rand -hex 8 > /tmp/e2e_pw.txt
RAILS_ENV=production bin/rails runner 'User.find_by(handle: "<test-handle>").update!(password: File.read("/tmp/e2e_pw.txt").strip)'
```

Log in AS `<test-handle>` to see the outputs — per-user isolation means the `<operator-handle>` account
cannot see `<test-handle>`'s jobs, so demonstrate and verify as the user the data belongs to,
and hand the operator the login + password in the report.
