# The decision service: hosted, or on your own box

The annotator asks a template's worth of typed questions — four, by default — and
folds the answers into a verdict.
*Which service answers them* is a deployment choice, not a code path: the whole
seam is `JEV_ENDPOINT`, and both backends speak the same wire protocol. Nothing
in `scripts/jev_annotate.py` knows which one replied.

| | hosted (TypeSafe System One) | local (`laya-serve`) |
|---|---|---|
| endpoint | `https://api.typesafe.ai/v1/systemone` | your box, `/v1/systemone` |
| needs | an API key, on a waitlisted service | a container image and a checkpoint |
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

A **container**, built from `jev/deploy/laya/` — laya is a published pip package
(`laya[serve]`), not a checkout, so the image is that install with a fixed
entrypoint. The CPU torch wheel goes in **first**: the default PyPI torch on
Linux is the CUDA build, ~2 GB for a card this service does not use.

```bash
podman build -t chopshop-laya:0.1.0 jev/deploy/laya     # from the repo root
```

Both versions are pinned (`torch==2.14.0+cpu`, `laya[serve]==0.3.21`) because the
wire behaviour the annotator is written against was measured on them; unpin
deliberately, not casually. The build gate is an `import laya.serve` check,
**not** `laya-serve --help`: laya-serve ignores `--help` and boots the server,
which pulls checkpoints and hangs the build.

It runs as a **quadlet** — podman's systemd generator, so the unit is a file in
`~/.config/containers/systemd/`, not one of systemd's own:

```bash
cp jev/deploy/laya/chopshop-laya.container ~/.config/containers/systemd/
cp jev/deploy/chopshop-laya.env.example ~/.config/chopshop-laya.env   # edit
systemctl --user daemon-reload
systemctl --user start chopshop-laya
```

The env file is read through `EnvironmentFile=`, so the token and the address
*callers* use live there, not in the unit. The unit's own `Environment=` lines
are in-container facts and **override** the file — podman gives `Environment=`
precedence — which is the point: the file says where the service is reachable
from outside, and a reachable address can never bind inside a container netns.

Two shape rules, both learned from a crash loop:

- **Bind `0.0.0.0` in-container; narrow exposure at the publish layer.** The
  literal-address bind is `OSError: [Errno 99] Cannot assign requested address`.
  `PublishPort=` is what decides who can reach the service, so a split install
  adds a publish line, not an `LAYA_HOST` value.
- **Order the unit after the address, not just after `network-online`.** When a
  `PublishPort` names a tailnet IP, pasta fails to bind it if `tailscale0` has
  not been assigned that address yet, and systemd's default start-rate limit then
  leaves the unit **dead** rather than retrying. The comment block at the top of
  the quadlet carries the `After=`, `StartLimitIntervalSec=0` and `ExecStartPre`
  lines that fix it; `StartLimitIntervalSec` is already set in the file.

The CALLER's half of that configuration is a template too:
`deploy/chopshop-jev.env.example` carries a block for the hosted backend and one
for this one — endpoint, key name, model, timeout and floor — plus a note of
which layer reads which variable (annotator, chopshop-svg runner, slop cannon).
Both backends are configured the same way because both speak the same wire
protocol; only the token's name differs, and every layer accepts both.

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
#    (either key name works: JEV_API_KEY, TYPESAFE_API_KEY or LAYA_API_KEY —
#     the local service's own name is accepted by the runner and the annotator)
JEV_ENDPOINT=http://127.0.0.1:8797/v1/systemone LAYA_API_KEY=<the shared secret> \
  .venv/bin/python scripts/jev_annotate.py path/to/manifest.json
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
answerable locally, and so are the other two templates that ship
(`dataset-translation`, 8 questions; `generation-slop`, 5 — the vocabulary
`scripts/slop_cannon.py` drives). A template that asks a `phrase` question is
**not** answerable on either backend, which is why none asks one: the
`dataset-translation` template dropped its two SHAPE-constrained `*_domain` fields
for exactly that reason, and the HOSTED service refuses a `phrase` set too. Both
boundaries are measured:

```
local  422 {"detail":"question 'shaped': unknown type 'phrase'; use one of ['choice', 'noul', 'score']"}
hosted 400 {"detail":{"error_type":"api_usage_error","message":"Invalid request."}}
```

Neither backend has a free-text answer type, so a phrase-using template is not
"hosted-only" — it is unusable on either, which is why the shipped translation
template asks eight questions rather than ten. A template declaring a refusable
type is stopped locally, with the measurement in the message
(`jev.UNSUPPORTED_QUESTION_TYPES`). Check a profile's types before pointing a
caller at either backend; `tests/test_jev_annotate.py` pins that the default set
stays inside the local vocabulary, and `tests/test_jev_profiles.py` pins that no
shipped profile declares a refusable type.

**The envelope is `{model, state, questions}` on both backends.** The hosted
service is STRICT about it — an extra key beside those three returns 400 for
every request — while being relaxed about extra fields *inside* a question
object (a `requires` field rides along harmlessly). So what this repo knows about
a request, such as which template answered, is written to the sidecar and never
sent. `jev.ENVELOPE_KEYS` is the constant; a test pins every profile against it.

## When it misbehaves

| symptom | most likely cause |
|---|---|
| `401` from the service | the caller's `JEV_API_KEY` does not match the service's `LAYA_API_KEY` |
| `413` | the projection outgrew a limit (state ≤ 50,000 chars, ≤ 64 questions, ≤ 100 options per `choice`, ≤ 32 levels per `score`) — measure the projection, do not guess |
| `422` naming an unknown question type | the profile asks a type the local backend has no head for: it answers `choice`/`score`/`noul`, not `phrase` |
| `400 api_usage_error: Invalid request` from the HOSTED service | the envelope carries a key beside `model`/`state`/`questions`. It is strict about the envelope and relaxed about fields inside a question — record local-only facts in the sidecar, never on the wire |
| `503` from the runner | the add-on is unconfigured on the *runner*: `JEV_ANNOTATOR` path, file exists, key non-empty |
| every `noul` flagged `low_confidence` | the certainty is being read as entropy rather than mass — see the trap above; `_answer_confidence` is where that lives |
| first call is slow, or fails as a timeout | checkpoint load. `LAYA_PRELOAD=1` moves it to start-up; a caller that names a checkpoint the service has not loaded needs `JEV_HTTP_TIMEOUT` wider than the 20s default |
| empty answers, HTTP 200 | the state was sent as a string of JSON rather than an object, or `null` — the service rejects only the latter |

## Where the deployment facts live

Paths, ports, tokens and this fleet's exact cutover belong in the studio's
`HOST-SPECIFIC` skill material, not here: this repo stays host-agnostic, and the
unit in `deploy/` names nothing.
