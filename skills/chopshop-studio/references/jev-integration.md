> HOST-SPECIFIC — `127.0.0.1:8787`, `~/.chopshop-studio.env`,
> `~/chopshop-jev`, the `start-chopshop-stack.sh` export list and the
> docker recreation steps are THIS deployment. The three-piece contract,
> status ladder and typed-answer rules are generic (the runner route is
> host-agnostic in chopshop-svg).

# Jev integration (TypeSafe System One) — studio ↔ runner ↔ chopshop-jev

Jev is an OPTIONAL, advisory add-on: four narrow typed questions about a candidate's
printability signature, folded into a verdict. It never ranks candidates and never picks a
winner. The deterministic gates stay the source of truth.

Three separate pieces, and conflating them is the main source of confusion:

| piece | where | what it owns |
|---|---|---|
| annotator | `~/chopshop-jev/scripts/jev_annotate.py` (its own repo, private) | the question set, `project_manifest()`, the response-typing rules, `compose_verdict()`, endpoint/model resolution |
| runner route | `~/chopshop-svg/runner.py` → `POST /validations/:id/jev` | shelling the annotator, the studio-facing envelope, the 503-when-unconfigured decision |
| studio | `RunnerClient.ask_jev` → `ValidationsController#ask_jev` → `validations/show` (served at `/proofs/:id`) | the call, persistence, card rendering |

## Studio-side traps (they present as runner failures)

- **A controller cannot call a view helper.** `jev_answer_view` / `jev_words` are
  `ApplicationHelper` methods, so calling one bare in `ValidationsController` raises
  `NoMethodError` — and because it happens while BUILDING the response, after the runner has
  already answered and the answers were persisted, the operator sees "Jev call failed" for a call
  that actually succeeded. That points at the runner, the key and the annotator, all of which are
  fine. Use `helpers.jev_answer_view` / `helpers.jev_words` from any controller.
- **A Jev call costs a model round-trip, so make it idempotent SERVER-SIDE.** A
  client guard (`data-has-answers`, `dialog.dataset.asked`) is a per-page-load
  courtesy: a reload, a second tab or a hand-typed POST each re-pay for a model
  call to produce an answer already held. `ask_jev` must return the STORED
  `jev_answers` when present and never touch the runner. Give the stored and
  fresh paths ONE payload helper so a replay is byte-identical and the client
  needs no second code path. Prove it by COUNTING runner calls across two
  requests, not by asserting the response — the response is the same either way,
  so a test that only checks the payload passes against the unfixed code.
- **Jev answers live on the VALIDATION, not the job.** Several proofs per job
  means several independent answers, so a job-level "Ask Jev" button has to pick
  one proof arbitrarily. Make the control PER PROOF. Corollary for aether.js: a
  hardcoded dialog id (`dialog.id === 'jev-popup'`) silently leaves every dialog
  past the first unwired — detect the dialog by its body slot
  (`dialog.querySelector('[data-jev-body]')`) so N dialogs all work.
- Test the `format.json` branch explicitly: the popup is a second render path
  (`POST /proofs/:id/ask_jev.json`, `Accept: application/json`, `X-CSRF-Token` from
  `meta[name=csrf-token]`) and a green page load says nothing about it.
- Confirm success on the RUNNER before touching the studio: `GET /health` must report
  `tools.jev: true`, and a direct `POST /validations/:id/jev` with `{job_id, candidate_file}` must
  return the envelope. A 503 there is configuration, not breakage.

## Never reimplement the annotator

The runner SHELLS the annotator; it does not copy the question set, the projection or the
verdict logic. A second copy drifts from the tested one — and the annotator's own suite
(`.venv/bin/python -m pytest tests/`) is the behavioural spec. The runner only:

1. checks readiness and reports the FIRST missing piece (annotator path → file exists → key),
2. runs it with `--output <tmp>/jev.json` (the job dir is not ours to write in — it is
   root-owned on a bind mount and belongs to the pipeline),
3. parses the sidecar and hands back `{model, endpoint, latency_ms, answers, verdict}`.

A non-`ok` sidecar status (e.g. `skipped` with a reason) must raise, not return an envelope —
otherwise a skipped call renders as a successful one.

## The route's status contract

| situation | answer | why |
|---|---|---|
| add-on not configured (no annotator or no key) | **503** with the reason | a 404 reads as "this runner has no such route" and sends you hunting for a wiring bug that is not there |
| validation known and still running | 409 | nothing to annotate yet |
| unknown validation AND no `job_id`/`candidate_file` fallback | 404 | genuinely unknown |
| manifest missing on disk | 404 naming the candidate | distinct from "no such validation" |

## Configuration (host-agnostic, and the key never goes in a tracked file)

`chopshop-svg` is PUBLIC, so `docker-compose.yml` takes these as env with empty defaults and a
host-local `docker-compose.override.yml` supplies this box's values. The override is GITIGNORED
(along with `.env`) — a machine-specific path or key committed there would be published.

| env (runner side) | meaning |
|---|---|
| `JEV_ANNOTATOR` | absolute path to the mounted `jev_annotate.py` |
| `JEV_API_KEY` | operator's key; `TYPESAFE_API_KEY` is the accepted historical alias |
| `JEV_ENDPOINT` / `JEV_MODEL` | overrides for `api.typesafe.ai/v1/systemone` / `jev-latest` |
| `JEV_TIMEOUT` | annotator subprocess timeout (default 180s) |

The annotator is MOUNTED, not baked into the runner image: the two repos stay separate
deliverables. On this box the key lives in `~/.chopshop-studio.env` as
`CHOPSHOP_JEV_API_KEY` (the `CHOPSHOP_` prefix is deliberate — it is the studio's env file), and
`start-chopshop-stack.sh` sources and exports it so `docker compose up -d runner` picks it up
through the override's `"${CHOPSHOP_JEV_API_KEY:-}"`. Add a new var by appending it to that file
AND to the launcher's `export` list, same as `CHOPSHOP_RUNNER_<LABEL>_URL`.

That `export` line is the mechanism, not bookkeeping: a var present in `~/.chopshop-studio.env` but
missing from the export list is invisible to `docker compose up -d runner`, so the container is
recreated with an EMPTY value and the add-on answers 503 from then on — while the env file looks
perfectly correct and the studio reports it as "Jev call failed". Check the CONTAINER, not the
file: `docker exec <container> sh -c 'echo ${#JEV_API_KEY}'` (a `0` is the tell) and
`curl -sS http://127.0.0.1:8787/health` for `tools.jev`. Recover with
`set -a && . ~/.chopshop-studio.env && set +a && docker compose up -d runner` — a RECREATE, since
a restart keeps the old env.

`/health` reports `tools.jev`, so an unset key is visible BEFORE the operator presses the button.

## Response shapes — the part that actually bites

Live answers are TYPED and each type keeps its certainty somewhere different (verified against
`api.typesafe.ai`, model `jev-1.13.0`):

| type | shape | certainty |
|---|---|---|
| `choice` | `{choice, confidence, probabilities}` | `confidence` is real |
| `score` | `{score, probabilities, legend}` | `confidence` is reported **0.0**; use `max(probabilities)` |
| `noul` | `{noul}` | the value IS P(true); certainty is `2·abs(noul − 0.5)` |

Two rendering traps, both live in `ApplicationHelper#jev_answer_view` (reachable from a controller
ONLY as `helpers.jev_answer_view` — see the studio-side traps):

- Reading `ans["choice"]` for all four answers renders the `score` and `noul` cards BLANK.
- The inverse trap bites in TESTS: a fixture written as `{"type"=>"choice",
  "value"=>"…"}` renders a card with the question and a BLANK value, which reads
  as a helper bug when the helper is correct. Match the fixture to the shape in
  the table above and assert the card carries its value, so a blank one fails.
- `0.0` is truthy in Ruby, so `if ans["confidence"]` prints "confidence 0%" on a `score` answer.
  Guard with `is_a?(Numeric) && positive?`.

A fractional `score` maps onto the NEAREST described legend level (`round()`), mirroring the
annotator's `_fraction_label` — an exact-key lookup shows no label at all for a legitimately
fractional score.

## Timing — do not use the shared timeout

A live call measures **~40s** (about 3000 input tokens on a real manifest). `RunnerClient::TIMEOUT`
is 15s, so `ask_jev` passes `read_timeout: JEV_READ_TIMEOUT` (150). Same reasoning as the
on-demand archive's `read_timeout:`. Any new call that proxies a third-party model or a render
needs its own timeout, not the shared constant.

## The mock is NOT a substitute for this

The mock runner returns canned answers and needs no key, so a green Ask Jev against the mock proves
nothing about the real runner — that is exactly how the missing route went unnoticed. The runner
image needs a REBUILD to gain the route (`docker compose build runner && docker compose up -d
runner`), not a restart; a restart also WIPES in-memory validations.

To check the route for real without the ~15-minute rebuild, boot `runner.py` on the HOST (pure
stdlib) against synthetic dirs. It exercises routing, statuses and the envelope; the container path
differs only in env. Harness pattern:

- `PIPELINE_ROOT` = a temp root, `RUNNER_ROOT` = the PARENT of the job dirs. `reindex_jobs()`
  iterates that directory, so pointing it at a single job dir is the easy mistake — it yields an
  empty `JOBS`, which reads as a 404 from the fallback and looks like a route bug.
- a job dir named `<job_id>` containing `<stem>.manifest.json`,
- `JEV_ANNOTATOR` = a tiny stand-in that writes a live-shaped sidecar to `--output`,
- plus a SECOND instance with `JEV_API_KEY=''` / `JEV_ANNOTATOR=''` to prove the 503 path.

**Kill any previous runner on that port first.** A failed bind is silent in the harness and the
requests then hit the STALE process from an earlier run — producing a reproducible-looking failure
against code that is already fixed. Confirm with `ss -ltnp | grep <port>` before believing a red
result. This cost a full debugging cycle once; same trap as the mock runner's `Address already
in use`.

## The standalone `/jev` page and its two file popups

The `/jev` page is a separate surface from the proof page's Ask Jev. Its head is
**Run Job**, then **TABLE | JSON** side by side — both open a file for reading
and editing, so they share ONE grid cell (`.head-action-pair`, which carries the
`--below` placement class) and flex inside it, rather than each taking a row.
DOM order decides which is on the left; no ordering CSS is needed. The grid
places the PAIR, so neither button carries a row class.

**Neither popup can write back, and the page says so.** This is a real limit,
not a missing feature:

- `chopshop-jev/scripts/jev_annotate.py` has **no conf input**. `QUESTIONS` is a
  module CONSTANT that `build_envelope()` deep-copies, and the CLI exposes no
  `--questions` flag. So the conf editor on `/jev` validates and previews
  faithfully but does **not** change what Jev is asked. Making it real means
  adding a `--questions` flag over there and passing the payload from here.
- `remediation_table.json` lives in the `chopshop-jev` repo and is read from
  there by `jev_remediate.py`. A Rails page cannot write into that checkout, so
  its popup is a viewer/editor with copy-out. Do not add a "Save" button that
  cannot save.

The help text is transcribed from the annotator's own note keys
(`project_manifest`, `_compact_finding`, `_compact_stats`, `compose_verdict`,
`_answer_confidence`), and a test asserts each field name it mentions actually
appears in `jev_annotate.py` — that is what stops the page describing a state
the pipeline never sends. It has already caught one false claim: the confidence
floor is NOT skipped for a score answer (`_answer_confidence` falls through to
`max(probabilities.values())`, and a `noul` uses `2*abs(noul - 0.5)`).

## State of play

- Runner level, unit-tested: readiness reasons, `/health` reporting, answers passed through
  verbatim, annotator failure surfaced as the reason, skipped-status rejected.
  `pytest tests/test_runner.py` (12 pass).
- Runner level, HTTP-verified on the host: unknown validation → 404, `job_id`+`candidate_file`
  fallback → 200, envelope carries answers/verdict/latency, missing manifest → 404 naming it,
  unconfigured → 503 with the reason, `/health` flips `tools.jev` false.
- Studio level, verified live: Ask Jev answered a real `jev-1.13.0` call end to end and rendered
  all four typed cards plus the verdict line.
- The disk-recovery fallback matters in practice: recreating the runner container drops every
  in-memory validation, so the studio's stored `runner_validation_id` then points at nothing. The
  fallback is what keeps Ask Jev working after a deploy.
- The studio DB column is `validations.file` (not `candidate_file`); `runner_validation_id` is the
  runner's id.
