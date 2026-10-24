# Backend bracket — 2026-10-10

Three real manifests from `chopshop-svg/05_final/` (candidate_04, candidate_11,
upload_10e21bcefbca/candidate_01), `printability` vocabulary, run live against
two decision backends. Ground truth for candidate_04: **899 declared colors
exceeding max 6, `passed: false`, screen_print** — i.e. a color-count/palette
failure, NOT a render or tonal failure.

## Result

| backend | mean mass | min | max | below 0.6 floor | candidate_04 headline |
|---|---|---|---|---|---|
| **MS-Decision-1** (OpenRouter, `microsoft/microsoft-decision-1`) | **0.719** | 0.206 | 0.970 | **3/12** | `continuous_tone` / `process_halftone` |
| **laya (GPU box)** (`typed-decisions`) | **0.410** | 0.211 | 0.612 | **10/12** | `render_or_tool_failure` |

Two findings, both structural:

1. **MS-Decision-1 is far better calibrated on this vocabulary.** Its masses
   cluster high (0.70–0.97); laya's sit at 0.2–0.6 with 10 of 12 under the
   default floor. On candidate_04, MS-Decision-1 read `continuous_tone` /
   `process_halftone` — defensible for 899 colors — while laya read
   `render_or_tool_failure`, which the manifest contradicts (it is a valid
   artifact; the failure is a color-count gate, not a render). n=3 is too small
   to call accuracy, but the calibration gap is large and consistent.

2. **A config-shadowing bug, found while wiring this up.** `resolve_env`
   resolves `JEV_API_KEY → TYPESAFE_API_KEY → LAYA_API_KEY →
   CHOPSHOP_OPENROUTER_KEY`, checking `os.environ` before the dotfile. This box
   has `LAYA_API_KEY` set in the ambient environment (the GPU box's laya token, 48
   chars), so it **shadows** `CHOPSHOP_OPENROUTER_KEY` (73 chars) and the
   annotator sends the laya token to OpenRouter → `HTTP 401 Missing
   Authentication header`. Workaround: pass `--api-key` explicitly, or unset
   `LAYA_API_KEY`. **Not fixed here** — the resolution order is a deliberate
   compatibility choice (a local deployment passes its own key), so changing it
   needs a decision about whether endpoint-scoped key resolution is wanted.

## Solar Decide Flash — not reachable

`upstage/solar-decide-flash` on OpenRouter routes through **Upstage's own API**
for auth; it returned `401 invalid_api_key ... console.upstage.ai`. It needs an
Upstage key, not the OpenRouter key. Not a bug — a provider routing detail.

## Caveat

n=3, one vocabulary, one backend pair. The calibration difference is real and
large; the accuracy claim is not established. A proper comparison needs more
manifests and a ground-truth label per manifest.
