# CONTEXT.md — chopshop-jev

Working state for agents and humans: what is in flight, what is blocked, and
the caveats that are not obvious from the code. Update this as work lands.

**Repo visibility: private.**

## What this repo is

The Jev decision sidecar for chopshop preflight manifests. Optional and
advisory: it projects a manifest into a compact `state`, asks an external
service four narrow typed questions about the artwork's *printability
signature*, and folds the answers into a thresholded verdict written as a
`<stem>.jev.json` sidecar. It never modifies the manifest, never ranks
candidates, never picks a winner — the deterministic gates in `chopshop-svg`
stay the source of truth.

## Work in progress

- **Question-set TEMPLATES — landed.** The four printability questions are now the
  DEFAULT template (`printability`), unchanged: `PROFILES["printability"]["questions"]`
  IS the module's `QUESTIONS` object, so the studio's `JevConf`, the remediation
  table and the help page all keep reading exactly what they read before. A second
  template, `dataset-translation`, asks MET-Meme's meme-annotation vocabulary
  about a generation artifact; `--profile` selects one, `--list-profiles` prints
  them, and the sidecar records which one answered. A template is DATA (projector +
  questions + fold), so a third vocabulary is a dict and not a second annotator.
  The design and the honest limits are in `docs/dataset-translation.md`.

- **A third template, `generation-slop`, and the harness that drives it —
  landed.** `SLOP_QUESTIONS` (5 questions: `has_structure`, `dominant_field`,
  `structure_score`, `slop_signature`, `prompt_adherence`) asks what the
  MEASUREMENTS of a raster say about whether it is slop, over the same generation
  artifacts as `dataset-translation`. `scripts/slop_cannon.py` is its caller: draw
  prompts, generate a raster per (prompt, model) via flux, measure the PNG into
  `slop_*` scalars, shell the annotator for a verdict, bucket keep/escalate/drop.
  Two limits are structural, not tuning: `prompt_adherence` declares
  `requires: ["image_visible"]` and so comes back `unevidenced` (the harness
  records it as `None`), and `keep` means "not obviously slop", never "good".
  The bucketing lives in the harness because the annotator must never rank or
  pick. README's "The slop cannon" section is the usage record.

- **A local decision service is wired, and it is an endpoint, not a code path.**
  `JEV_ENDPOINT` selects the backend, so `laya-serve` (Apache-2.0, 421M, weights
  on HuggingFace) stands in for the hosted TypeSafe service with no adapter and
  no second response shape: `deploy/chopshop-laya.{service,env.example}` +
  `docs/local-decision-service.md`. The hosted one stays selectable and is still
  the default; switching back is unsetting the variable.
  - **Measured on the first deployment** (real 6 KB preflight manifest, CPU):
    2 s wall warm, 4 s for a first call that loads a checkpoint — against ~40 s
    for the hosted call. `typed-decisions` named the manifest's actual finding
    (`palette_mismatch`) where the auto-routed `english` said
    `render_or_tool_failure` on a manifest with no render failure. So the
    annotator has to name `JEV_MODEL=typed-decisions`; English text routes to
    `english` on its own.
  - **Open: the confidence floor is not calibrated for this backend.** The
    probability masses on a four-question call sat at 0.23–0.61, so most answers
    are surfaced in `low_confidence`. A 7-option `choice` rarely puts 0.6 of its
    mass on one option, and the hosted service's `confidence` is a different
    function on a different scale, so the floor's number does not transfer
    either way. Measure your own manifests before trusting 0.6 here.
- **The HTTP call budget is now env-resolved** (`JEV_HTTP_TIMEOUT`, 20s default)
  because the runner does not pass `--timeout`: its 180s is the SUBPROCESS
  budget, and the annotator's own HTTP budget was the binding one. Found by
  naming a checkpoint the service had not loaded — it failed as
  `error: timed out` (exit 2, no sidecar) at 20 s.
- **Remediation loop — partly built, dry-run only.** Steps 1–2 of the
  `docs/remediation-loop.md` plan are done: `scripts/remediation_table.json`
  holds the policy as data (with a drift test), and `scripts/jev_remediate.py`
  implements grounding + refusal behind `--dry-run`.
- **Steps 3–7 are open:** emitting the targeted sweep for real, executing the
  rungs, the provenance artifacts, honouring `auto_retry_limit`. `--remediate`
  refuses with an explicit error rather than silently no-opping.

- **The slop cannon's endpoints are environment variables, and there is no
  default.** `--endpoint` and `--jev-endpoint` fall back to
  `$CHOPSHOP_FLUX_ENDPOINT` and `$JEV_ENDPOINT`; with neither set the run exits
  2 with a message naming the variable it wanted. Both addresses used to be
  argparse defaults holding this box's tailnet IP, so a bare
  `./slop_cannon.py` anywhere else aimed at that machine and reported
  "unreachable" — which reads as a network fault, so the operator debugs the
  network instead of the missing variable. There is deliberately not even a
  loopback fallback: a port belongs to one deployment too.
  `tests/test_slop_cannon.py::EndpointConfigTest` pins the resolution order and
  scans every tracked and untracked file in the tree for an IPv4 literal, so the
  rule survives being reintroduced somewhere else.

## Blockers and known gaps

- The remediation loop cannot execute until steps 3–7 are implemented.
- **The service has no free-text answer type (measured).** `choice`, `score` and
  `noul` only: a set containing a `phrase` question returns
  `HTTP 400 api_usage_error`. So MET-Meme's two SHAPE-constrained domain fields
  (`source_domain`, `target_domain`) are NOT asked — the template asks eight
  questions, not ten. A template declaring an unsupported type is stopped locally
  with the measurement in the message (`UNSUPPORTED_QUESTION_TYPES`).
- **The wire envelope is `{model, state, questions}` EXACTLY (measured).** An
  extra key beside them returns 400 for every request; which profile answered is
  recorded in the sidecar, never sent. `ENVELOPE_KEYS` is the constant and a test
  pins every shipped profile against it.
- **The translation profile cannot see the image**, and says so: the artifact
  projector sets `evidence.image_visible: false`, the image-dependent questions
  declare `requires: ["image_visible"]`, and the fold reports them in
  `unevidenced`. Run as-is their answers are unevidenced by construction.
- **Verified live once.** Job 386's raster annotated end to end (`status: ok`,
  model `jev-1.13.0`, 1,320 input tokens): 8 answers, 3 `unevidenced`, 2 below the
  floor — and the service's own `evidence_is_actionable` said false (P(true)
  0.26), agreeing with the fold's mechanical list.
- **No cross-vocabulary drift test yet.** The criteria identifiers here and the
  display words in the studio's `app/lib/meme_vocabulary.rb` are two renderings of
  MET-Meme's scheme, correct by inspection and not by construction. (`SLOP_QUESTIONS`
  has no such counterpart to drift against — the vocabulary is this repo's own.)

## Caveats / known issues

- **The local backend answers `choice` / `score` / `noul`, and nothing else** —
  and the HOSTED one is no broader. A question set containing a `phrase` question
  is refused by the local service (`422 "question 'shaped': unknown type 'phrase';
  use one of ['choice', 'noul', 'score']"`) and by the hosted service (`400
  api_usage_error: Invalid request`), both measured, so a phrase-using template is
  not "TypeSafe-only" — it is unusable on either, which is why no shipped profile
  asks one. It fails loudly rather than answering nonsense, and
  `check_profile` stops such a template locally with the measurement in the
  message. `tests/test_jev_annotate.py` pins the default set's types against the
  local vocabulary; `tests/test_jev_profiles.py` pins that no shipped profile
  declares a refusable type.
- **A local backend echoes the criterion text as the `legend`.** `laya-serve`
  returns the level text it was given, so `verdict.tonal_label` reads as a full
  sentence ("Flat: tonal range reduced to a few hard steps with visible
  banding.") where the hosted service returns a short label. Anything rendering
  it must expect a sentence, not a word.
- **The studio reports the backend from the STORED answers, not from a setting.**
  The choice lives in the runner's environment, which the studio does not own, so
  `/jev`'s card lists the two backends and then shows the endpoint + model each
  stored answer came from (`jev_meta`). A cutover shows up there as a new line
  rather than as a config field someone typed.

- **The annotator has no `--questions` flag** (`QUESTIONS` is a module
  constant). The studio `/jev` conf editor validates and previews but does NOT
  change what Jev is asked — that is the intended state, not a gap. **This file
  is where that position is settled: the flag does not exist and is not
  currently planned.** Adding it would be a cross-repo change — a `--questions`
  flag in `scripts/jev_annotate.py` that accepts the studio's payload — and that
  change is not done, so nothing here is pending. chopshop-studio's docs now read
  the same way: `app/models/jev_conf.rb` says the flag "does not exist and is not
  currently planned (chopshop-jev/CONTEXT.md is where that position is settled)"
  and that adding one "would be a cross-repo change and is not in flight", and
  `skills/chopshop-studio/references/jev-integration.md` agrees ("No
  `--questions` CLI flag is planned"). The earlier outlier — a studio comment
  that read as a plan in flight — has been reconciled; this repo plans nothing.
  Note the vocabulary moved under that position without changing it: `QUESTIONS`
  is still a module constant, it is now simply `PROFILES["printability"]["questions"]`
  rather than the only question set, and no flag accepts a caller's question set.
- **Typed-answer certainty differs by type:** `choice` uses `confidence`;
  `score` reports `confidence: 0.0` (use `max(probabilities)`); `noul` certainty
  is `2·|noul − 0.5|`. `_answer_confidence` handles all three.
- **On the runner path, `.jev.json` never exists on disk** — `runner.py`
  redirects the annotator into a temp dir and lifts `answers` + `verdict` into
  an HTTP envelope. A zero count of `.jev.json` is not a missing producer.
- **`remediation_table.json` has a `_deviations_from_plan_doc` note** where the
  plan's premises were superseded by code (e.g. the plan's §7 predates
  `chopshop-svg` gaining `scripts/node_reduce.py`). Read it alongside the doc.

## Doc/code alignment pass (2026-09-29)

Every markdown file was read against the source it describes. What changed:

- **`generation-slop` and `slop_cannon.py` were undocumented in markdown.** The
  commit that added them (`912f122`) touched only the two scripts and a test
  file, so no `.md` in the repo mentioned either — not README's profile table, not
  this file, not `docs/local-decision-service.md`'s profile list. README gained a
  third template row, the `--list-profiles` example, and a "The slop cannon"
  section; this file gained the WIP bullet above.
- **`phrase` was still described as a live answer type in two places.** This file
  claimed a new `phrase` type "for a field the source constrains by SHAPE", and
  its caveat said the `dataset-translation` template asks one and is
  "TypeSafe-only". Both were superseded by the measurement recorded in
  `UNSUPPORTED_QUESTION_TYPES`: no backend has a free-text type and no shipped
  profile asks one. Corrected. `compose_annotation_verdict`'s docstring in
  `scripts/jev_annotate.py` and `tests/test_jev_profiles.py`'s module docstring
  carried the same stale claim (a `phrase` answer "carried verbatim", a phrase
  "SHAPE" in `check_profile`) and were corrected too.
- **`_env_file_values` said "the six JEV_*/TYPESAFE_* keys"; `_JEV_ENV_KEYS`
  holds eight.** Corrected to name the constant rather than a count that drifts.
- **`docs/dataset-translation.md`** said `--list-profiles` "prints both" (three
  ship), said the profile asks "ten questions" (it asks eight; the tenth is the
  historical record in its own probe table), and said "four of MET-Meme's fields"
  declare `requires: ["image_visible"]` — three do, and the code, the fold and the
  one live run all agree on three. Corrected.
- **`docs/agents/domain.md` is now repo-specific.** It was the generic upstream
  scaffold: it sent readers to a `CONTEXT-MAP.md` and a `docs/adr/` this repo has
  never had and showed `src/` trees it has never had, contradicting this repo's
  own rule (one root `CONTEXT.md` is the single context document).
- **A latent bug in the slop cannon, found by reading it against its own
  docstring:** `slop_cannon.py` accepts `JEV_API_KEY` *or* `LAYA_API_KEY`, but
  its `annotate()` never passed the resolved key through — the shelled annotator
  reads only `JEV_*`, so a caller who exported the service's own name would pass
  the harness's check and then fail one level down as "JEV_API_KEY is not set".
  The key is now forwarded as `--api-key`, with a test pinning the argv.
- **Tests strengthened where they under-claimed:** `--list-profiles` was asserted
  against two hand-written names while three templates ship (now asserted against
  `PROFILES` itself, count column included), and the unknown-profile refusal had
  the same hard-coded pair.
- Tests: `147 passed, 19 subtests passed` (`.venv/bin/python -m pytest tests/`,
  re-measured 2026-10-06; the pass recorded above shipped 124/15).
- Not touched: `AGENTS.md` (protected), and the studio's copy of the Jev position
  — see the `--questions` caveat above, which is now reconciled on both sides.
