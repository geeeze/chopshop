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
  One new answer type, `phrase`, for a field the source constrains by SHAPE.
  The design and the honest limits are in `docs/dataset-translation.md`.

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

## Blockers and known gaps

- The remediation loop cannot execute until steps 3–7 are implemented.
- **The `phrase` answer type is not rendered by the studio's JEV conf editor.**
  The template in this repo is complete; the studio's editor knows `choice`,
  `score` and `noul` only, so a `phrase` question is editable in the sidecar and
  not in that form.
- **The translation profile cannot see the image**, and says so: the artifact
  projector sets `evidence.image_visible: false`, the image-dependent questions
  declare `requires: ["image_visible"]`, and the fold reports them in
  `unevidenced`. Run as-is their answers are unevidenced by construction.
- **No cross-vocabulary drift test yet.** The criteria identifiers here and the
  display words in the studio's `meme_vocabulary.rb` are two renderings of
  MET-Meme's scheme, correct by inspection and not by construction.

## Caveats / known issues

- **The local backend answers `choice` / `score` / `noul`, and nothing else.**
  The `printability` template is inside that vocabulary; a template asking a
  `phrase` question (the `dataset-translation` one does) is refused by the live
  service — verified: `422 "question 'shaped': unknown type 'phrase'; use one of
  ['choice', 'noul', 'score']"`. It fails loudly rather than answering
  nonsense, but it means that template is TypeSafe-only until the local model
  gains a head for it. `tests/test_jev_annotate.py` pins the default set's types
  against the local vocabulary.
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
  change is not done, so nothing here is pending. chopshop-studio's docs must
  read the same way, and one of them does not: `app/models/jev_conf.rb` describes
  that wiring path ("a change in another repo and is not done"), which reads as a
  plan in flight, while the studio's own
  `skills/chopshop-studio/references/jev-integration.md` already agrees with this
  file ("No `--questions` CLI flag is planned"). The studio model comment is the
  outlier; this repo plans nothing.
- **Typed-answer certainty differs by type:** `choice` uses `confidence`;
  `score` reports `confidence: 0.0` (use `max(probabilities)`); `noul` certainty
  is `2·|noul − 0.5|`. `_answer_confidence` handles all three.
- **On the runner path, `.jev.json` never exists on disk** — `runner.py`
  redirects the annotator into a temp dir and lifts `answers` + `verdict` into
  an HTTP envelope. A zero count of `.jev.json` is not a missing producer.
- **`remediation_table.json` has a `_deviations_from_plan_doc` note** where the
  plan's premises were superseded by code (e.g. the plan's §7 predates
  `chopshop-svg` gaining `scripts/node_reduce.py`). Read it alongside the doc.
