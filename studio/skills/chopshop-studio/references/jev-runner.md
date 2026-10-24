# JEV on the chopshop-svg runner — answered by the local LAYA service

JEV (the four advisory questions on a proof's manifest) is served by the
chopshop-svg Docker runner at `127.0.0.1:8787`. The chain is:

    POST /proofs/:id/ask_jev (studio) → RunnerClient.ask_jev
      → POST /validations/<id>/jev (runner)
      → JEV_ANNOTATOR = /app/jev/jev_annotate.py (chopshop-jev, read-only mount)
      → the service at JEV_ENDPOINT

## The backend: local laya-serve, NOT TypeSafe

As of 2026-10-08 this box answers Jev from the **local `laya-serve` on <gpu-box>**, not
TypeSafe. The switch was the operator's call and it is DONE — do not describe
LAYAA as "an option to keep alongside TypeSafe".

| thing | value |
|---|---|
| `JEV_ENDPOINT` | `http://<tailnet-ip>:8797/v1/systemone` (<gpu-box>, over the tailnet) |
| `JEV_MODEL` | **`typed-decisions`** — required |
| service | podman quadlet `chopshop-laya.container` on <gpu-box> (unit name `chopshop-laya`); code is the image, built from `jev/deploy/laya` |
| health | `GET /health` lists the LOADED models + device; `GET /` and `/v1/models` 404 by design |
| auth | `Authorization: Bearer <token>` — 401 without it, 422 on a malformed envelope |
| `JEV_API_KEY` | from `~/.chopshop-studio.env` `CHOPSHOP_JEV_API_KEY` (same 48-char token as `LAYA_API_KEY` in the Hermes env file) |

The annotator's own `DEFAULT_MODEL` is `jev-latest` — TypeSafe's name — and it
resolves the key from `JEV_API_KEY`, then `TYPESAFE_API_KEY`, then
`LAYA_API_KEY`. Set the model to `typed-decisions` or the local service answers
nothing. A live LAYA call takes ~4s on CPU; TypeSafe measured ~40s, which is why
`JEV_READ_TIMEOUT` is not the shared 15s read timeout.

**Two separate timeout budgets.** The annotator's HTTP budget is
`JEV_HTTP_TIMEOUT` (then `TYPESAFE_HTTP_TIMEOUT`) in `jev_annotate.py`, and it is
independent of the RUNNER's 180 s subprocess budget (`JEV_TIMEOUT`), which the
runner does NOT pass as `--timeout`. So a caller that names an unloaded
checkpoint can hit the HTTP budget first and fail as `error: timed out` with NO
sidecar — widen `JEV_HTTP_TIMEOUT`, not `JEV_TIMEOUT`, when that happens.

Config lives in `~/chopshop-svg/docker-compose.override.yml` (gitignored,
host-local) and is read from `~/.chopshop-studio.env`. The tracked
`docker-compose.yml` is already env-driven (`JEV_ENDPOINT: "${JEV_ENDPOINT:-}"`),
so a LITERAL in the override SHADOWS it and editing the env file then does
nothing — that had already happened here, leaving two dead lines in the env file.
Keep the override on `${VAR:-default}` form.

## Pitfall: a bare recreate empties the key

If the container was started without the env sourced, `JEV_API_KEY` is empty
(silent — the container comes up green) and `POST /validations/:id/jev` answers
**503 "JEV_API_KEY is not set on the runner"**. One backgrounded command (a
foreground `docker compose up -d` also trips the long-lived-command guard):

```bash
cd ~/chopshop-svg && set -a && . ~/.chopshop-studio.env && set +a \
  && docker compose up -d --force-recreate runner
```

Verify the container first — expect `48 typed-decisions
http://<tailnet-ip>:8797/v1/systemone`:

```bash
sudo docker exec chopshop-svg-runner-1 sh -c \
  'echo ${#JEV_API_KEY} $JEV_MODEL $JEV_ENDPOINT'
```

Then the real check, the annotator in-container against a real manifest:

```bash
sudo docker cp <a real *.manifest.json> chopshop-svg-runner-1:/tmp/m.json
sudo docker exec chopshop-svg-runner-1 \
  python3 /app/jev/jev_annotate.py /tmp/m.json --output /tmp/o.json
```

Expect `status: ok | model: laya-rl-agent` and the four printability answers
(`evidence_is_actionable`, `failure_mode`, `print_route`, `tonal_structure`).
`laya-rl-agent` is LAYA reporting itself; `jev-1.13.0` means TypeSafe answered.

Same chain through the studio, without the login wall (`RunnerClient` is the
object the controller calls, so this is the real HTTP path minus auth):

```bash
cd ~/chopshop-studio && set -a && . ~/.chopshop-studio.env && set +a
RAILS_ENV=production bin/rails runner \
  'v = Validation.find(<id>); p RunnerClient.ask_jev(v)'
```

## Reading it back from the studio

Answers are stored per proof (`Validation#jev_answers` / `#jev_meta`) and the
studio serves the stored answer forever — `ONE REQUEST, EVER` — so a proof
answered before the cutover keeps `jev-1.13.0` in its provenance and cannot be
re-asked. `GET /jev` tallies endpoint+model across the last 200 stored answers,
which is how you see the real distribution instead of a claim.

## Pitfall: name_slug lost on restart

`runner.py`'s `reindex_jobs` must derive `name_slug` from the job dir's
`*-proof-*.manifest.json` files. Without it, after a container restart
`published_proof_stem` falls back to the candidate stem and the JEV manifest
lookup **404s** — it looks for `<candidate>.manifest.json` instead of the real
`<slug>-proof-NN.manifest.json`. The manifest for a proof is named after the
JOB slug, not the candidate. Validations and jobs are in memory only, but the
reindex runs at start, so the `job_id`/`candidate_file` fallback in the
`/validations/<id>/jev` route still resolves an old proof's manifest after a
restart.
