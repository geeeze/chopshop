# The decision service: hosted, or on your own box

The annotator asks four typed questions and folds the answers into a verdict.
*Which service answers them* is a deployment choice, not a code path: the whole
seam is `JEV_ENDPOINT`, and both backends speak the same wire protocol. Nothing
in `scripts/jev_annotate.py` knows which one replied.

| | hosted (TypeSafe System One) | local (`laya-serve`) |
|---|---|---|
| endpoint | `https://api.typesafe.ai/v1/systemone` | your box, `/v1/systemone` |
| needs | an API key, on a waitlisted service | a virtualenv and a checkpoint |
| state leaves the machine | yes, every call | no — it stays in the house |
| cost per call | per call | nothing |
| certainty field | `confidence` (`choice` only) | `answer_confidence` (`max(p)`) |

Both are legitimate. The hosted service is the default and stays selectable —
keeping it working is a requirement, not a legacy path — and the local one is
what you reach for when the projection should not leave the machine, or when a
per-call decision should not cost anything.

## Why a local backend is nearly free to adopt

`laya` is a 421M non-autoregressive decision engine (Apache-2.0, weights on
HuggingFace), and its `laya-serve` entry point **already implements the TypeSafe
Jev `/v1/systemone` wire protocol** — its own words:

> A client written against Jev -- `hs-jev`, `typesafe-sdk`, or your own -- can
> point its base URL at this server and keep working.

So there is no adapter in this repo, and there should never be one. The request
shape the annotator already sends is the shape the local service accepts:

```
POST /v1/systemone
{"model": "jev-latest", "state": {...projection...}, "questions": {...four...}}

200 {"model": "laya-rl-agent", "answers": {...}, "usage": {...}, "routing": {...}}
```

`model` is accepted and ignored: the annotator's `jev-latest` is not a
checkpoint name, so the service routes to the checkpoint its own heuristics pick
(English content lands on `english`). Set `LAYA_MODELS=english` on the service
and that is the only checkpoint resident.

`tests/test_jev_annotate.py` runs `main()` against a stub that enforces the
local service's documented request limits, so a change to the projection that
would earn a `413` from a real service fails here first.

## What actually differs, and the one trap

**Certainty is a different number on each backend, and the floor has to mean the
same thing on both.** `laya-serve` reports two: `answer_confidence` (the
probability mass on the reported answer, `max(p)`) and `confidence` (normalised
entropy `1 - H(p)/log k` on a `choice`, `max(p_yes, p_no)` on a `noul`). Its own
docs are blunt about it — *"Never compare the two against one threshold"* — and
TypeSafe's `(n·p_max − 1)/(n − 1)` is a third scale again. `_answer_confidence`
therefore takes `answer_confidence` when it is present, and otherwise keeps the
per-type rules the hosted service needs (a `score` answer's `confidence: 0.0`
still falls through to `max(probabilities)`, and a `noul` still falls back to
its distance from a coin flip). A Jev-shaped answer has no `answer_confidence`
field, so its gating is unchanged.

The number still means something different underneath — the calibration is the
backend's own — so treat the floor as a routing heuristic, not a probability
statement ported between vendors. Everything else already matches: a `score`
answer's `legend` maps level index to level text on both services, and
`_fraction_label`'s `round()` handles laya's fractional expected level the same
way it handles Jev's.

**The questions are already the right shape for this model, and that is luck
worth keeping.** The measured result behind `laya`'s scoring is that asking what
the state *is* agrees with a hand-written oracle (86%), while asking it what to
*do* agrees 0% — and the model grows *more* confident when it is wrong. Our four
questions ask for a failure signature, a route, a rubric level and whether the
evidence supports a decision: all descriptive, none asking for an action. A new
question-set template inherits that obligation — keep its questions descriptive,
keep them inside the vocabulary the backend answers (see Profiles below), and do
not put a word in the state you do not want answered.

## Install on the box that will answer

A virtualenv, because the checkpoint and its runtime are a multi-hundred-MB,
platform-specific install that has no business in this repo's requirements.

```bash
python3 -m venv ~/laya/.venv
~/laya/.venv/bin/pip install -U pip

# CPU: one wheel, a few hundred MB. Correct for four questions per proof.
~/laya/.venv/bin/pip install torch --index-url https://download.pytorch.org/whl/cpu
# GPU (ROCm/CUDA): install the torch build for the card FIRST, from its own
# index, then laya. Do not pip-install a GPU stack into somebody else's
# environment to save this step.

~/laya/.venv/bin/pip install "laya[serve]"
```

Then the unit, which is env-driven exactly like `chopshop-flux`'s:

```bash
cp deploy/chopshop-laya.service ~/.config/systemd/user/
cp deploy/chopshop-laya.env.example ~/.config/chopshop-laya.env   # edit it
systemctl --user daemon-reload
systemctl --user start chopshop-laya
```

A **split install** (pipeline on one box, decision service on another) is the
same act as flux's: set `LAYA_HOST` to the private address the caller can reach
*and* set `LAYA_API_KEY`. A bind that leaves loopback without a token is an
open decision endpoint on a shared network.

Read the env file, not the running process, when something looks wrong — and
believe the process when the two disagree: `systemctl --user show chopshop-laya
-p Environment` prints what the unit actually got.

## Verify, in this order

```bash
# 1. the service is up and says what it loaded
curl -s http://127.0.0.1:8797/health
#    {"status":"ok","loaded":["english"],"revisions":{...},"device":"cpu"}

# 2. it answers the protocol the annotator speaks (no key needed on loopback)
curl -s http://127.0.0.1:8797/v1/systemone -H 'content-type: application/json' \
  -d '{"state": {"paths": 5042, "hard_findings": 3},
       "questions": {"route": {"type": "choice", "instructions": "Which production route fits?",
                               "criteria": {"spot": "spot colour", "process": "four-colour process"}}}}'

# 3. the REAL annotator against it — the integration, not the punchline
JEV_ENDPOINT=http://127.0.0.1:8797/v1/systemone JEV_API_KEY=<LAYA_API_KEY> \
  .venv/bin/python scripts/jev_annotate.py path/to/candidate_03.manifest.json
#    Jev annotation: path/to/candidate_03.jev.json
#    ... and the sidecar's verdict is what the studio renders
```

From another box, substitute the address the service is bound to for
`127.0.0.1`. Then the studio path end to end: `/health` must report
`tools.jev: true`, Ask Jev must answer, and the four typed cards must render —
a green direct call says nothing about the render.

## Cut over, and cut back

The pipeline side reads two variables, so switching backends is an env change
and a restart — never an edit:

| env (runner side) | hosted | local |
|---|---|---|
| `JEV_ENDPOINT` | unset, or `https://api.typesafe.ai/v1/systemone` | `http://<host>:8797/v1/systemone` |
| `JEV_API_KEY` | the TypeSafe key | the service's `LAYA_API_KEY` |
| `JEV_MODEL` | unset (`jev-latest`) | `typed-decisions` — see the measurement below |
| `JEV_HTTP_TIMEOUT` | unset (20s) | `180` if a caller may name a checkpoint the service has not loaded |

All four are the *caller's* variables, so the fleet can run one box on each
backend at the same time, and a rollback is unsetting `JEV_ENDPOINT` again. Note
the runner's own rule: `JEV_API_KEY` empty or `JEV_ANNOTATOR` missing is the
unconfigured state and answers **503 with the reason**, which is configuration,
not breakage.

`JEV_MODEL` is worth its own line. The annotator's default `jev-latest` is not a
checkpoint name, so the service auto-routes it — and for English text that lands
on the general `english` checkpoint. Naming `typed-decisions` selects the one
fine-tuned for this workflow, and that is not a preference, it is a measurement:

| checkpoint | `failure_mode` on a manifest with one `PALETTE` finding and no render error |
|---|---|
| `english` (auto-routed) | `render_or_tool_failure` — wrong; nothing failed to render |
| `typed-decisions` | `palette_mismatch` — the finding the manifest actually carries |

## What the first deployment measured

Four questions over a real 6 KB preflight manifest, on CPU, against the service
described above:

- **2 s wall** on a warm service (vs ~40 s for the hosted call), **4 s** for the
  first call naming a checkpoint the service had not loaded. That load is what
  the 20 s default HTTP timeout cannot cover — hence `JEV_HTTP_TIMEOUT`.
- **`low_confidence` is noisy on this backend, and that is a calibration fact,
  not a bug.** The masses sat at 0.23–0.48 for the three-way-and-wider questions
  and 0.61 for the `noul`, so three of four answers were surfaced as uncertain.
  A seven-option `choice` rarely puts 0.6 of its mass on one option. The hosted
  service's `confidence` is a different function, on a different scale, so the
  floor's *number* does not transfer either way: measure your own manifests
  before treating 0.6 as the right threshold here. `low_confidence` is surfaced,
  never a veto, so a wrong floor costs signal rather than correctness.
- **`legend` comes back as the full criterion text**, not a short label (laya
  echoes what it was given), so `tonal_label` reads as a sentence. Anything
  rendering it should expect a sentence.
- The failure mode is clean: a timeout exits non-zero and writes **no sidecar**,
  so nothing downstream can mistake it for an answer.

## Profiles: which question set the local backend can answer

The annotator asks a question-set *template* (`--profile`, default
`printability`), and the local backend answers a **subset** of them: its
vocabulary is `choice`, `score`, `noul`, and nothing else. Verified against the
live service rather than inferred from its docs:

```
422 {"detail":"question 'shaped': unknown type 'phrase'; use one of ['choice', 'noul', 'score']"}
```

So `printability` — the default, and what every existing caller sends — is
answerable locally, and a template that asks a `phrase` question (the
`dataset-translation` one does) is **TypeSafe-only** until the local model gains
a head for it. It fails loudly, which is the right failure: do not read a 422 as
a wiring bug. Check a profile's types before pointing a caller at the local
backend; `tests/test_jev_annotate.py` pins that the default set stays inside the
local vocabulary.

## When it misbehaves

| symptom | most likely cause |
|---|---|
| `401` from the service | the caller's `JEV_API_KEY` does not match the service's `LAYA_API_KEY` |
| `413` | the projection outgrew a limit (state ≤ 50,000 chars, ≤ 64 questions, ≤ 100 options per `choice`, ≤ 32 levels per `score`) — measure the projection, do not guess |
| `422` naming an unknown question type | the profile asks a type the local backend has no head for: it answers `choice`/`score`/`noul`, not `phrase` |
| `503` from the runner | the add-on is unconfigured on the *runner*: `JEV_ANNOTATOR` path, file exists, key non-empty |
| every `noul` flagged `low_confidence` | the certainty is being read as entropy rather than mass — see the trap above; `_answer_confidence` is where that lives |
| first call is slow, or fails as a timeout | checkpoint load. `LAYA_PRELOAD=1` moves it to start-up; a caller that names a checkpoint the service has not loaded needs `JEV_HTTP_TIMEOUT` wider than the 20s default |
| empty answers, HTTP 200 | the state was sent as a string of JSON rather than an object, or `null` — the service rejects only the latter |

## Where the deployment facts live

Paths, ports, tokens and this fleet's exact cutover belong in the studio's
`HOST-SPECIFIC` skill material, not here: this repo stays host-agnostic, and the
unit in `deploy/` names nothing.
