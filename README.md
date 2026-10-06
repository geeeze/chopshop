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
| `generation-slop` | a generation artifact whose raster was measured (`slop_*` numbers, see "The slop cannon") | five: whether the frame has structure, whether one colour dominates it, how much structure there is, which slop signature the numbers show, and prompt adherence — the one question that needs pixels: a real answer when a captioner supplied the picture's description ("The captioner" below), `unevidenced` when none did |

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

1. the exported `JEV_API_KEY`,
2. the historical `TYPESAFE_API_KEY`,
3. `LAYA_API_KEY` — the local service's own name, accepted so the alternate
   backend needs no renaming. The runner and `slop_cannon.py` already take it;
   a check that accepts a key the annotator cannot read reports a wiring bug
   that does not exist,
4. `~/.hermes/.env` and the repo `.env`.

Only the Jev-relevant keys are ever read from those files — unrelated
secrets sitting alongside them are never touched. `JEV_ENDPOINT` /
`JEV_MODEL` (and their `TYPESAFE_*` aliases) override the endpoint and model,
`JEV_HTTP_TIMEOUT` overrides the 20s call budget, and `JEV_CONFIDENCE_FLOOR`
sets the advisory floor described under "The verdict".

### Hosted, or on your own box

`JEV_ENDPOINT` is the entire backend choice. A locally hosted service that
speaks the same wire protocol (`laya-serve` does) stands in for TypeSafe's with
no code change, no adapter and no second response shape; the hosted one stays
selectable, and switching back is unsetting the variable.

**Both backends are configured the same way, and both have a template:**

| | hosted (TypeSafe System One) | local `laya-serve` (the alternate) |
|---|---|---|
| endpoint | `https://api.typesafe.ai/v1/systemone` | your box's `/v1/systemone` |
| key | `JEV_API_KEY` or `TYPESAFE_API_KEY` | `LAYA_API_KEY` (or `JEV_API_KEY`) |
| model | leave unset (`jev-latest`) | `JEV_MODEL=typed-decisions`, **named** — English text routes to the `english` checkpoint on its own, and on a real manifest that answered the wrong finding |
| template in `deploy/` | `chopshop-jev.env.example` | `chopshop-laya.env.example` + `chopshop-laya.service` |
| cost / state | per call; state leaves the box | nothing; state stays home |

The key name is the only wiring difference, and every layer accepts all three:
the annotator resolves them in order, the chopshop-svg runner treats any of them
as proof Jev is configured (so a local deployment is no longer refused with
"set the hosted service's key"), and `slop_cannon.py` forwards whichever it
finds. A cutover is therefore one variable — `JEV_ENDPOINT` — plus the token
you already set.

```bash
systemctl --user is-active chopshop-laya                             # is the local one up?
.venv/bin/python scripts/jev_annotate.py manifest.json --dry-run     # envelope only: no call, no key needed
```

`deploy/chopshop-jev.env.example` is the caller-side template, with a block for
each backend and a note of who reads which variable. The service side is
`deploy/chopshop-laya.{env.example,service}`, and
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

A real `compose_verdict` result (values trimmed to what matters here):

```json
{
  "headline": "screen_explosion",
  "print_route": "process_halftone",
  "tonal_score": 3.8,
  "tonal_label": null,
  "evidence_actionable": false,
  "confidence": {
    "failure_mode": 0.94,
    "print_route": 0.88,
    "tonal_structure": 0.47,
    "evidence_is_actionable": 0.44
  },
  "low_confidence": ["tonal_structure", "evidence_is_actionable"],
  "confidence_floor": 0.6,
  "confidence_floor_is_advisory": true,
  "confidence_evidence": {
    "vocabulary": "printability",
    "by_backend": {"laya-serve": {"low": 0.23, "high": 0.61,
                                   "floor_covers_whole_range": false}},
    "all_observed_below_default_floor": false,
    "ranges_straddling_default_floor": ["laya-serve"],
    "note": "observed probability mass for this vocabulary, per backend; ..."
  },
  "confidence_range": {
    "n": 4, "low": 0.44, "high": 0.94,
    "all_below_floor": false, "floor": 0.6,
    "all_below_default_floor": false, "default_floor": 0.6,
    "recorded_evidence": {},
    "note": "masses span 0.44-0.94 against a 0.6 floor in use (default 0.6)"
  }
}
```

`low_confidence` lists any answer whose certainty fell below the floor — those
are surfaced, not reported as settled. Three keys exist so that list cannot be
mistaken for the measurement:

- **`confidence`** — the raw mass for every answer that has one, gated or not.
  A floor-gated verdict with the numbers kept private is a measurement turned
  into a constant: a caller who cannot see the mass cannot tell "the model was
  unsure" from "the floor was set for a different backend".
- **`confidence_floor_is_advisory`** — stated in the artifact rather than left
  to be inferred. The floor is a note about the numbers, never a claim about
  the artwork.
- **`confidence_evidence`** — the recorded masses per **backend** as well as per
  vocabulary (`OBSERVED_CONFIDENCE_RANGES`), because the floor is not a property
  of one question set:

  | vocabulary | backend | observed mass | does the 0.6 default cover it? |
  |---|---|---|---|
  | `printability` | `laya-serve` | 0.23 – 0.61 | no — the range **straddles** the floor |
  | `generation-slop` | `laya-serve` | 0.33 – 0.60 | yes — everything it saw was gated |

  A range is evidence; a constant is an assumption. Where nothing has been
  measured the field is `{}`, not a number invented for the occasion.

**`confidence_range`** is this run's own report: `n`, `low`, `high`, and both
floors side by side — `floor` (the one that gated this verdict) and
`default_floor` (the shipped 0.6) — with an `all_below_*` flag for each, so
"12 of 12 escalated" is readable as a statement about the floor rather than
about the rasters.

### Choosing your own floor

`--confidence-floor` (or `JEV_CONFIDENCE_FLOOR`) sets it; a value outside 0..1
is refused by name, because a typo that sent every answer to `low_confidence`
would be the same silent-constant failure this whole section is about. It moves
the note, never the masses: the `confidence` values above are identical at floor
0.4 and floor 0.9, only `low_confidence` changes.

There is no single right number — the floor depends on the **vocabulary** and
the **backend**, which is why the recorded ranges travel in the artifact. Read
the table above, or your own run's `confidence`, and set the floor from that.

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
- **It judges prompt adherence only when something saw the picture.**
  `prompt_adherence` declares `requires: ["image_visible"]`: with a caption in
  the artifact (from the captioner below) the evidence is satisfied and the
  answer is a number, and without one it comes back `unevidenced` and the
  harness records `None`, never a number. Either way the claim is bounded — a
  caption is a *description* of the pixels, so adherence measured through one is
  "the caption matches the prompt", which is stated rather than quietly upgraded
  to "the picture matches the prompt".
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

### The captioner — how a picture reaches a text model (#2)

`prompt_adherence` was the one question the vocabulary could not ask: a text
decision service never sees pixels, so the fold reported it `unevidenced` on
every run and "model X is more accurate" could only ever mean "more structured".
The seam this issue asked for now exists, and it deliberately does not put a
transformer in the annotator:

```bash
# the service (its own env template and unit are in deploy/)
CAPTION_MODEL=LiquidAI/LFM2.5-VL-450M CAPTION_PORT=8798 \
  python3 scripts/caption_serve.py

# the harness picks it up from one variable — or from --caption-endpoint
CAPTION_ENDPOINT=http://127.0.0.1:8798 python3 scripts/slop_cannon.py ...
```

- **Model: `LiquidAI/LFM2.5-VL-450M`** (450M params, SigLIP2 encoder), chosen
  because captioning is an explicitly supported task, it processes 512×512
  natively — the frame size this harness draws — and it runs on CPU next to a
  generator that owns the GPU. `LFM2.5-VL-1.6B` and `-3B` are the same seam with
  more capacity; set `CAPTION_MODEL` and restart.
- **Measured on this box:** 47–52 s to load the checkpoint on CPU, **4.7–5.8 s
  per 512×512 frame** (e.g. *"a tiger in mid-stride, surrounded by a dramatic
  explosion of fire and sparks…"* for `klein-4b`). Install `causal_conv1d` if
  you want the faster kernels; without it transformers falls back to a
  reference implementation and says so.
- **The caption travels INSIDE the artifact** (`image.caption` +
  `image.caption_model`), so the annotator stays stdlib-only and never learns a
  model exists. The projector turns it into `evidence.image_visible: true`,
  scrubs it to 600 chars, and names the model that wrote it — a caption is
  evidence about the picture, not the picture, and the sidecar says which.
- **An unconfigured or down captioner is recorded, never fatal.** No
  `CAPTION_ENDPOINT` → the run prints that prompt_adherence stays unevidenced
  and continues; a captioner that fails mid-run writes `image.caption_error`
  onto the artifact, so "we never asked" and "it was down" stay
  distinguishable. `deploy/chopshop-caption.{service,env.example}` install it
  the same way the decision service is installed.

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
