# chopshop-jev

A Jev decision sidecar for [chopshop-svg](https://github.com/geeeze/chopshop-svg)
preflight manifests.

**chopshop-jev** is an **optional add-on** — it is not part of the deterministic
pipeline and is never run by default. It takes the JSON manifest that
`chopshop-svg`'s `preflight.py` produces and asks an external decision service
a template's worth of narrow, advisory questions about the artwork. The DEFAULT
template is four questions about its *printability signature* — what this
annotator has always asked. Two more vocabularies ship beside it:
`--profile dataset-translation` asks MET-Meme's meme-annotation vocabulary about
a generation artifact, and `--profile generation-slop` asks whether a *measured*
raster is worth keeping (the vocabulary `scripts/slop_cannon.py` drives). See
"Question-set templates" below, `docs/dataset-translation.md`, and "The slop
cannon" below that.
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
2. **Ask a template's questions** against the live service (see "The questions"
   and "Question-set templates").
3. **Fold** the typed answers into a `verdict`, gating any answer whose
   confidence falls below a floor into `low_confidence` instead of reporting it
   as settled fact.

## Question-set templates

A template is a question set plus the two things it needs to be usable: which
projector reads the input, and how the answers fold. They are DATA, so a new
vocabulary is a dict rather than a second annotator — `AGENTS.md` forbids
reimplementing this module elsewhere precisely so there is one place holding the
projection, the questions and the fold.

| profile | input | questions |
| --- | --- | --- |
| `printability` (default) | a preflight manifest | four: the failure signature, the production route, tonal structure, and whether the evidence is actionable |
| `dataset-translation` | a generation artifact (a prompt plus the measurements of what it produced) | eight: MET-Meme's meme-annotation scheme (minus its two shape-constrained domain fields, which need a free-text answer this service does not have), plus the evidence question |
| `generation-slop` | a generation artifact whose raster was measured (`slop_*` numbers, see "The slop cannon") | five: whether the frame has structure, whether one colour dominates it, how much structure there is, which slop signature the numbers show, and prompt adherence — the one question that needs pixels, so it comes back `unevidenced` |

```bash
python3 scripts/jev_annotate.py --list-profiles
python3 scripts/jev_annotate.py 05_final/artwork.manifest.json --dry-run
python3 scripts/jev_annotate.py artifact.json --profile dataset-translation --dry-run
python3 scripts/jev_annotate.py artifact.json --profile generation-slop --dry-run
```

The sidecar records which profile answered, so it is never ambiguous which
vocabulary its verdict is in. A profile that does not match its input is
REFUSED, naming the reason, rather than answered about the wrong document.

**The wire envelope is `{model, state, questions}` and nothing else.** That was
measured: an extra key beside them returns `400 api_usage_error` for EVERY
request, so anything this repo wants to record about a request is written to the
sidecar instead. The answer types the service implements are `choice`, `score`
and `noul` — a free-text type is refused, which is why the translation template
asks eight questions and not ten. `docs/dataset-translation.md` has the probe
table.

## Install

Runtime needs only the Python standard library (3.11+). Tests need `pytest`.
`scripts/slop_cannon.py` is stdlib too — it decodes PNGs itself rather than
depending on Pillow or numpy, so the harness stays installable anywhere the
annotator is.

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

# plan the remediation for a verdict — prints the decision, executes nothing
.venv/bin/python scripts/jev_remediate.py 05_final/candidate_03.jev.json --dry-run

# a runner envelope carries no findings, so pair it with the manifest it describes
.venv/bin/python scripts/jev_remediate.py envelope.json \
    --manifest 05_final/candidate_03.manifest.json --dry-run
```

By default the sidecar is written next to the manifest as
`<stem>.jev.json` (a `candidate_03.manifest.json` becomes
`candidate_03.jev.json`). Override with `--output PATH`.

**On the runner path that file never exists, by design.** `runner.py` redirects
the annotator into a temp directory (the job directory is root-owned on a bind
mount, so it is not the runner's to write in), then discards it and lifts
`answers` + `verdict` into an HTTP envelope at `POST /validations/:id/jev`.
So a zero count of `.jev.json` on disk is not a missing producer — and a
remediation input taken from the runner is an envelope, which carries no
findings: pass `--manifest` alongside it or grounding has nothing to read.

### API key resolution

The key is read, in order, from:

1. the exported `JEV_API_KEY` (falling back to the historical `TYPESAFE_API_KEY`),
2. `~/.hermes/.env` and the repo `.env`.

Only the Jev-relevant keys are ever read from those files — unrelated
secrets sitting alongside them are never touched. `JEV_ENDPOINT` /
`JEV_MODEL` (and their `TYPESAFE_*` aliases) override the endpoint and model,
and `JEV_HTTP_TIMEOUT` overrides the 20s call budget.

### Hosted, or on your own box

`JEV_ENDPOINT` is the entire backend choice. A locally hosted service that
speaks the same wire protocol (`laya-serve` does) stands in for TypeSafe's with
no code change, no adapter and no second response shape; the hosted one stays
selectable, and switching back is unsetting the variable. `deploy/` carries the
systemd unit and env template for the local one, and
[`docs/local-decision-service.md`](docs/local-decision-service.md) has the
install, the cutover, the measured numbers and the one real difference (which
field carries a usable certainty).

## The questions

The DEFAULT template's four intentionally narrow, atomic judgments. None asks
Jev to rank or select a candidate; the other two vocabularies are the same kind
of question set and `--list-profiles` prints all three. (Their question sets live
as data in `scripts/jev_annotate.py` — `MEME_QUESTIONS`, `SLOP_QUESTIONS`.)

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

## The slop cannon — a keep/escalate loop over a measured raster

`scripts/slop_cannon.py` is the caller the `generation-slop` template exists for.
It draws prompts from a JSON list, has the flux service generate one raster per
(prompt, model), measures that PNG into `slop_*` numbers itself, shells
`jev_annotate.py` for a `generation-slop` verdict, and buckets each result
**keep / escalate / drop**.

```bash
python3 scripts/slop_cannon.py --prompts prompts.json \
    --models klein-4b,sd-1.5,sdxl-turbo --out runs/bracket-1
```

- **The bucketing is the harness's job, never the annotator's** — Jev never ranks
  and never picks, so `keep`/`drop` is decided here, by the caller. Three
  outcomes, and `escalate` is the design: an answer below the confidence floor,
  or a signature and a structure score that disagree, is handed on rather than
  resolved by ordering two rules.
- **It never judges prompt adherence.** That needs pixels, this system has no
  captioner, so `prompt_adherence` declares `requires: ["image_visible"]` and
  comes back `unevidenced`; the harness records it as `None`, never as a number.
- **`keep` means "not obviously slop"** — never "good", never "as asked for".
- **The measurements are its own.** They are named `slop_*` precisely so they
  cannot be confused with `chopshop-svg`'s `rendered_*` print-preflight metrics,
  which are a different pipeline's definitions on a different box. They are crude
  slop detectors, not a quality metric, and the definitions are stated in
  `measure_raster`.
- **Both endpoints are flags with no default address** (`--endpoint` for flux,
  `--jev-endpoint` for the decision service); each falls back to its environment
  variable (`$CHOPSHOP_FLUX_ENDPOINT`, `$JEV_ENDPOINT`) and the run exits 2
  naming the one that is missing. Auth comes from the
  environment: `CHOPSHOP_FLUX_TOKEN` for flux, and `JEV_API_KEY` or
  `LAYA_API_KEY` for the decision service (the harness forwards whichever it
  finds to the annotator, which reads only the `JEV_*` name).
- **Expect most rasters to escalate on the local backend**, and read the printed
  `P(struct)` / `P(field)` / `score` columns instead of the bucket: the local
  backend's probability masses sit around 0.23–0.60 against the 0.6 floor, which
  `CONTEXT.md` records as the floor not being calibrated for it. Escalation says
  something about the floor and nothing about the models.

## Remediation loop (partly built — dry-run only)

`docs/remediation-loop.md` designs the next layer: turning `failure_mode`
into a *deterministic* remediation — a table lookup that decides whether to
retrace with an adjusted parameter, re-filter the existing SVG, or refuse and
stop. Jev stays observational; only the processing layer acts.

**Step 1 and step 2 of its §10 implementation order are done.**
`scripts/remediation_table.json` holds the policy as data, with a test that
fails the build if its `failure_mode` keys ever drift from
`jev_annotate.QUESTIONS`, and `scripts/jev_remediate.py` implements the
grounding and refusal logic behind `--dry-run`. A dry run prints the table
lookup, the chosen remedy and the resulting sweep JSON for every branch and
executes nothing.

Read the table's `_deviations_from_plan_doc` alongside the doc — it records
where the plan's premises were superseded by code (most notably: the doc's §7
says there is no node simplifier in the repo, which stopped being true when
`chopshop-svg` gained `scripts/node_reduce.py`).

Steps 3–7 are open: emitting the targeted sweep for real, executing the rungs,
the provenance artifacts, and honouring `auto_retry_limit`. **Nothing executes
yet** — `--remediate` refuses with an explicit error rather than silently
no-opping. Read the doc before starting them.

## Tests

```bash
.venv/bin/python -m pytest tests/
```

The suite is fully hermetic: it exercises the projection, scrubbing,
response-validation, and verdict logic against a real-shaped manifest fixture,
and never touches the network or the real `.env`.
