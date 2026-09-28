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

- **Remediation loop — partly built, dry-run only.** Steps 1–2 of the
  `docs/remediation-loop.md` plan are done: `scripts/remediation_table.json`
  holds the policy as data (with a drift test), and `scripts/jev_remediate.py`
  implements grounding + refusal behind `--dry-run`.
- **Steps 3–7 are open:** emitting the targeted sweep for real, executing the
  rungs, the provenance artifacts, honouring `auto_retry_limit`. `--remediate`
  refuses with an explicit error rather than silently no-opping.

## Blockers

- The remediation loop cannot execute until steps 3–7 are implemented.

## Caveats / known issues

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
