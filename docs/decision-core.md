# The decision core: one stack, local or cloud

The Jev side of this repo used to be three deployment stories — hosted TypeSafe,
a local `laya-serve`, and (elsewhere) a router — each documented separately and
each with its own endpoint. This is the consolidation: **one stack, one wire
contract, and the backend behind it is a setting.**

```
   annotator   slop_cannon   the svg runner
         \         |          /
          POST /v1/systemone          <- the ONLY contract callers know
                  |
          jev-core / gateway          <- deploy/jev-core
          /        |        \
     local     openrouter     hf
   (laya)      (cloud)     (cloud)
```

`deploy/jev-core/docker-compose.yml` brings up `laya` (the 421M decision model)
and `gateway` (a stdlib front door) with one command:

```bash
cd deploy/jev-core && podman-compose up -d
curl 127.0.0.1:8799/health
```

Then every caller points at the gateway and nothing else:

```
JEV_ENDPOINT=http://127.0.0.1:8799/v1/systemone
```

## Why a gateway and not three configs

`docs/local-decision-service.md` is right that `JEV_ENDPOINT` is the whole seam
and that both *local* and *hosted TypeSafe* speak `/v1/systemone` — no adapter
needed. The gap was the rest of the world: OpenRouter and the HuggingFace
Inference Router speak `/v1/chat/completions`. Without a translator, "cloud as
well as local" means a second client inside the annotator, which is exactly what
the seam exists to prevent.

So the gateway holds the translation and nothing else:

| backend | what the gateway does |
|---|---|
| `local` (laya) | **pass-through** — forwards the envelope unchanged. laya already speaks the protocol; rewriting it here would be a second implementation that drifts. |
| `openrouter` | builds a chat request from `state` + `questions`, asks for one JSON object, validates every answer against the question's own criteria |
| `hf` | same, against the HF Inference Router |

## The footprints, measured on a T4 box

| piece | resident | disk |
|---|---|---|
| `gateway` | **17.87 MB** | `python:3.13-slim`, 122 MB |
| `laya` | 3.9 GB | image 1.28 GB of packages; **weights stay on the NFS cache** |

The gateway carries no model, so it is the cheap half. laya is the only thing
that holds one, and `LAYA_DEVICE=cpu` keeps it off the GPU the generator uses.

Nothing is downloaded at run time when `LAYA_CACHE_DIR` points at a populated
cache: set `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1` and a read-only mount
is enough (a read-only mount cannot accept lock-file writes).

## Choosing a backend

| variable | default | meaning |
|---|---|---|
| `SYSTEMONE_BACKEND` | `local` | which backend answers. Local is the default because "the projection never leaves the machine" is a property callers rely on. |
| `SYSTEMONE_FALLBACK` | empty | comma list tried, in order, after the default. **Empty means fail loudly** rather than quietly shipping a projection to a third party. |
| `SYSTEMONE_API_KEY` | unset | bearer the *callers* must present. Set it once the bind leaves loopback. |
| `OPENROUTER_API_KEY` / `OPENROUTER_MODEL` | unset / `google/gemini-2.5-flash` | cloud backend 1 |
| `HF_TOKEN` / `HF_MODEL` | unset / `Qwen/Qwen2.5-7B-Instruct` | cloud backend 2 |
| `LAYA_ENDPOINT` | `http://127.0.0.1:8797` | the local service |
| `SYSTEMONE_TIMEOUT` | `60` | seconds per backend call |

A single request can override the default with `X-SystemOne-Backend: openrouter`
or `?backend=hf`.

**Every response says which backend answered**, and what was tried before it:

```json
"routing": {
  "backend": "local",
  "attempts": [{"backend": "openrouter", "ok": false, "kind": "backend_unconfigured",
                "reason": "no API key configured for the openrouter backend (OPENROUTER_API_KEY)"}],
  "fallback_used": true
}
```

That distinction matters: *"laya said unevidenced"* and *"laya was down and the
cloud answered instead"* are different facts about an artifact, and a verdict
that cannot tell them apart is not auditable.

## What a cloud backend is not allowed to do

Two guards, both because a hosted model will happily invent what it cannot see:

1. **The evidence gate.** A question declaring `requires: ["image_visible"]` is
   skipped unless `state.evidence.image_visible` is true, and the skip is
   reported in `routing.skipped`. A text model gets no chance to describe a
   picture it was never shown.
2. **Membership validation.** An answer whose `choice` is not one of that
   question's own criteria is **dropped and reported**, never passed on. A
   made-up category folded into a print verdict is a wrong verdict wearing a
   confident number.

## The three answer shapes, and why the gateway reproduces them exactly

MEASURED from the live local service, and the reason a cloud answer and a local
one are interchangeable to this repo's fold:

| type | criteria | answer shape |
|---|---|---|
| `choice` | dict, id -> description | `{"choice": "<id>", "answer_confidence": 0.44}` |
| `score` | **list** of described levels | `{"score": <index>, "legend": {"0": …}}` |
| `noul` | dict, `true`/`false` | `{"noul": 0.51}` — a calibrated P(true) |

`phrase` is refused by the service itself (HTTP 400), so the gateway refuses it
before spending a call: the types are `choice`, `score`, `noul`.

## Verifying it, rather than assuming it

```bash
python3 scripts/verify_gateway.py            # annotator's own request -> gateway -> laya
```

That script builds its request with the repo's own `project_artifact` +
`build_request`, so it fails if the gateway stops accepting what the annotator
actually sends. Expected: four answers, `backend: local`, and each answer valid
for its own type.
