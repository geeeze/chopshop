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

**ONE credential under TWO names will drift, and the direct CLI is the side that breaks.** The
studio's file holds `CHOPSHOP_JEV_API_KEY` while the annotator itself resolves `JEV_API_KEY` from
the Hermes env file, so the same key lives in two places — renew one and not the other and the studio
works while every direct `jev_annotate.py` call answers `401` (or the reverse). When a Jev call 401s
while the add-on looks configured, COMPARE the two without printing either: read both values
in-process and report only length, first 11 and last 4. Two traps in the value: a key pasted out of a
dashboard can carry a stray `>` (the giveaway is a length that differs from the clean copy — check
the character class before writing it anywhere), and **an already-exported `JEV_API_KEY` overrides
the dotenv file for the whole life of the process**, so editing the file does not fix a session that
already exported the old value — unset the variable or start a fresh process. Both backends answer
`401` for a bad key and `400 api_usage_error` for a bad envelope, so read the CODE before touching
the credential.

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
  `--questions` flag. The conf editor on `/jev` validates and previews but does
  **not** change what Jev is asked — and that is the intended state of play, not
  a gap to close. No `--questions` CLI flag is planned.
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

## Question-set TEMPLATES — a second vocabulary, and what the service really accepts

**Built.** Jev's three-stage shape — project a document into a compact `state`, ask narrow typed
questions whose `criteria` ARE the target vocabulary, fold through a confidence floor — is a
translation layer; the second vocabulary now exists as a TEMPLATE.

- **A profile is DATA**: `{projector, questions, fold}` in `PROFILES` in `jev_annotate.py`, with
  `check_profile()` asserting each is internally sound. `printability` is the DEFAULT and is not a
  copy — its `questions` IS the module's `QUESTIONS` object, so `JevConf`, the remediation table and
  the help page keep reading exactly what they read before. `dataset-translation` reads a generation
  ARTIFACT (a prompt plus what was measured of the raster it produced) and asks the meme-annotation
  vocabulary. `--profile` selects, `--list-profiles` prints, the SIDECAR records which one answered,
  and the wrong profile for an input is refused rather than answered about the wrong document. A
  third vocabulary is a dict, not a second annotator — which is what that repo's `AGENTS.md` requires.
- **The fold is type-driven** (`compose_annotation_verdict`), so a new template needs no new folding
  code. `compose_verdict` (the studio's domain contract: `headline`, `print_route`, `tonal_score`,
  `evidence_actionable`) is deliberately untouched — it is read BY NAME and must stay a contract.
- **The verdict keeps three different admissions apart**: `values`, `low_confidence` (answered but
  under the floor), and `unevidenced` (answered, but the state says the evidence that question needs
  is not present). Collapsing the third into the second is how a guess starts reading as a fact.
- **The seam is an artifact PAIR, not a document** — exactly as predicted here before it was built. A
  generation run holds a prompt (the DATASETS library) plus the raster it produced, the same unit a
  meme dataset annotates as a text-image pair. `project_artifact()` reads that pair and declares
  `evidence.image_visible: false` by construction, because the annotator is handed text and numbers
  and never pixels; image-dependent questions declare `requires: ["image_visible"]` and the fold
  reports them. The service's OWN `evidence_is_actionable` answer agreed with that mechanical list on
  the first live run — a useful cross-check that the gate is not merely strict but correctly strict.
- **There is no ground truth available** (a dataset's images stay with the dataset), so the answers are
  UNVALIDATED annotations. Any surface showing them must say so as plainly as the tournament page says
  SIMULATED, and they stay advisory — an annotation may never filter, rank or gate a candidate. The
  honest first measurement is RELIABILITY, not accuracy: run the same profile twice over a small fixed
  set and report the agreement.
- **Cost bounds the scope.** A live call is a model round-trip, so a 60k-row library cannot be
  annotated row by row; run the profile over generated artifacts or a sample.

- **The seam is an artifact PAIR, not a document.** A generation run holds a prompt (the DATASETS
  library) plus the raster it produced — the same unit a meme dataset annotates as a text-image pair.
  One dataset supplies the material, our own generation the image, a labelling scheme the questions.
- **`QUESTIONS` is a module CONSTANT and the CLI has no `--questions` flag** — so a second vocabulary
  is a change IN `chopshop-jev` with its own pin, not something the studio can add. That is still
  true; what changed is that the change was made there (see the templates section above). `JevConf`
  remains a deliberate faithful copy pinned by a drift test, so it grows only when the annotator does.
- **The types are `choice` / `score` / `noul` ONLY, and there is no free-text type on EITHER backend
  — measured, not assumed.** A field the source vocabulary constrains by SHAPE (e.g. two domains
  specified as "adj + n" or "verb + n") therefore **cannot be asked at all**: adding a type and
  pointing it at the service returned `400 api_usage_error` on the hosted service and `422` on the
  local one, while the same set without it answered. Do not plan around "add the type later" — ask
  the fields the service can answer and record the gap. (An earlier revision of this file said the
  type could be added in the annotator. It cannot.) A template declaring a refusable type is now
  stopped locally, naming the measurement, so nobody pays a round trip to rediscover it.
- **An image-dependent question must be GATED, and the gate is its own list.** "image dominant" /
  "complementary" cannot be answered from prompt text, so the projection declares whether an image is
  present and the fold reports those answers in `unevidenced` — NOT in `low_confidence`, because
  "confident but unevidenced" and "unsure" are different admissions and a reader acts on them
  differently. That is the confidence floor's discipline, not a special case to route around.
- **There is no ground truth available** (a dataset's images stay with the dataset), so the answers are
  UNVALIDATED annotations. Any surface showing them must say so as plainly as the tournament page says
  SIMULATED, and they stay advisory — an annotation may never filter, rank or gate a candidate. The
  honest first measurement is RELIABILITY, not accuracy: run the same profile twice over a small fixed
  set and report the agreement.
- **Cost bounds the scope.** A live call is ~40s, so a 60k-row library cannot be annotated row by row;
  run the profile over generated artifacts or a sample.

## The wire contract, MEASURED — an opaque refusal costs a session if you guess

One live request per row against `api.typesafe.ai/v1/systemone`, model `jev-latest`, varying exactly
one thing at a time. Two rows describe faults that were in shipped code before anyone measured them.

| request | result |
|---|---|
| `{model, state, questions}` (the printability default) | **200** |
| the same plus ANY extra envelope key | **400** `api_usage_error: Invalid request` |
| a question set containing a free-text type | **400** hosted / **422** local |
| the same set with that question removed | **200** |
| 4, 5, 6 and 8 questions | **200** each — no count cap |
| a QUESTION carrying an extra field of its own (`requires`) | **200** — tolerated |

**The envelope is strict; a question object is relaxed.** An extra key beside
`model`/`state`/`questions` breaks EVERY request, including ones that had worked for a year — which is
how a harmless-looking bookkeeping field (`profile`) took the whole integration down. Record
local-only facts in the SIDECAR. `ENVELOPE_KEYS` is the constant and a test pins every shipped
profile against it.

**To find which part a service is refusing, BISECT — one field per call, read the status.** And keep
the FULL response body for parsing, truncating only for display: a probe that sliced the body to 400
chars before `json.loads` raised `JSONDecodeError` on a request that had actually SUCCEEDED, i.e. a
probe lying in the opposite direction from the usual false-green. A probe that reports a confident
FAILURE costs just as much as one that reports a confident pass.

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
- **A 404 "manifest not found for <candidate>" after a runner restart is usually the `name_slug`
  bug, not a genuinely missing manifest.** `reindex_jobs()` rebuilds the in-memory `JOBS` from disk
  but, if it does not set `NAME_SLUG_KEY`, `job_name_slug()` returns `""` and `published_proof_stem`
  falls back to the candidate stem — so the lookup asks for `<candidate>.manifest.json` while the
  real file is `<slug>-proof-NN.manifest.json`. The manifest exists; the lookup is looking for the
  wrong name. Before concluding a manifest is absent, list the job dir for `*-proof-*.manifest.json`
  and confirm the slug is being derived. The fix is to derive `name_slug` in `reindex_jobs` from the
  proof manifests on disk (regex `^(.*)-proof-\d+\.manifest\.json$`), then rebuild the image — a
  restart alone keeps the old code.
- The studio DB column is `validations.file` (not `candidate_file`); `runner_validation_id` is the
  runner's id.
