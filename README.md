# chopshop-jev

A Jev decision sidecar for [chopshop-svg](https://github.com/geeeze/chopshop-svg)
preflight manifests.

**chopshop-jev** is an **optional add-on** — it is not part of the deterministic
pipeline and is never run by default. It takes the JSON manifest that
`chopshop-svg`'s `preflight.py` produces and asks an external decision service
four narrow, advisory questions about the artwork's *printability signature*.
The answers are folded into a thresholded verdict and written as a separate
`<stem>.jev.json` sidecar, alongside the manifest it was derived from.

It never modifies the manifest, never ranks candidates, and never picks a
winner. The deterministic gates in `chopshop-svg` remain the source of truth;
Jev is a second, independent opinion on *what kind* of print problem a file has.

## What it does

1. **Project** the manifest into a compact `state` object — the scalars a
   decision needs (colour counts, ink coverage, node counts, gate findings),
   with long colour lists collapsed to a gist and machine-specific paths
   shortened. It never sends the full manifest.
2. **Ask four questions** against the live service (see "The questions").
3. **Fold** the typed answers into a `verdict`, gating any answer whose
   confidence falls below a floor into `low_confidence` instead of reporting it
   as settled fact.

## Install

Runtime needs only the Python standard library (3.11+). Tests need `pytest`.

```bash
python3 -m venv .venv
.venv/bin/pip install pytest        # tests only
```

## Usage

```bash
# write the request envelope without calling the service
.venv/bin/python scripts/jev_annotate.py manifest.json --dry-run

# skip cleanly when no key is available (exit 0)
.venv/bin/python scripts/jev_annotate.py manifest.json --optional

# live call
JEV_API_KEY=... .venv/bin/python scripts/jev_annotate.py manifest.json
```

By default the sidecar is written next to the manifest as
`<stem>.jev.json` (a `candidate_03.manifest.json` becomes
`candidate_03.jev.json`). Override with `--output PATH`.

### API key resolution

The key is read, in order, from:

1. the exported `JEV_API_KEY` (falling back to the historical `TYPESAFE_API_KEY`),
2. `~/.hermes/.env` and the repo `.env`.

Only the six Jev-relevant keys are ever read from those files — unrelated
secrets sitting alongside them are never touched. `JEV_ENDPOINT` /
`JEV_MODEL` (and their `TYPESAFE_*` aliases) override the endpoint and model.

## The questions

Four intentionally narrow, atomic judgments. None asks Jev to rank or select a
candidate:

| id | type | asks |
|---|---|---|
| `failure_mode` | choice | which failure signature best describes this candidate (screen explosion, continuous tone, geometry overload, palette mismatch, render/tool failure, no hard failure, unclear) |
| `print_route` | choice | which production route fits (spot low/multi, process halftone, DTG/DTF, unsuitable, unclear) |
| `tonal_structure` | score | how faithfully the trace preserved tonal structure (broken → engraving-grade) |
| `evidence_is_actionable` | noul | whether the supplied measurements support a production decision given their stated limitations |

## Request / response contract (verified live)

The service is TypeSafe's "System One" model, called over HTTP:

- **Endpoint** `POST https://api.typesafe.ai/v1/systemone`
- **Auth** `Authorization: Bearer <key>`
- **Request** `{"model": "jev-latest", "state": {...}, "questions": {...}}`
- **Response** `{"model": "jev-1.13.0", "answers": {<id>: {...}}, "usage": {...}}`

Each answer carries a type-specific certainty — and this is the one trap worth
knowing up front:

| answer type | confidence lives in | note |
|---|---|---|
| `choice` | `confidence` (0..1) | real field |
| `score` | `probabilities` distribution | `confidence` is reported as **0.0** — use `max(probabilities)` |
| `noul` | the value itself | P(true); certainty is `2·|noul − 0.5|` |

The annotator handles all three (`_answer_confidence`), so a score answer is
never wrongly flagged as low-confidence because of the bogus `confidence: 0.0`.

## The verdict

```json
{
  "headline": "screen_explosion",
  "print_route": "process_halftone",
  "tonal_score": 0.95,
  "tonal_label": "Flat",
  "evidence_actionable": false,
  "low_confidence": ["tonal_structure"],
  "confidence_floor": 0.6
}
```

`low_confidence` lists any answer whose certainty fell below the floor — those
are surfaced, not reported as settled. `confidence_floor` is configurable.

## Tests

```bash
.venv/bin/python -m pytest tests/
```

The suite is fully hermetic: it exercises the projection, scrubbing,
response-validation, and verdict logic against a real-shaped manifest fixture,
and never touches the network or the real `.env`.
