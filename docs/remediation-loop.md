# Jev-driven remediation loop — plan

**Status: a plan, of which steps 1–2 of §10 are now implemented.** Every fact
below was read from the code *as it stood when this was written*; the
primitives that exist are marked as such. Where code has since overtaken a
premise here, the correction is recorded as data in
`scripts/remediation_table.json` under `_deviations_from_plan_doc` — read that
alongside this doc. The table is the current policy; where the two disagree,
the table wins and this doc is the historical record.

As of commit `4c0c0eb`, the table-as-data, the vocabulary pins, and the
grounding/refusal logic behind `scripts/jev_remediate.py --dry-run` exist.
**Nothing executes:** `--remediate` refuses with an explicit error rather than
silently no-opping. Steps 3–7 below remain the plan.

One premise in §7 is already obsolete and the table records it: this doc says
there is no node simplifier in the repo, which stopped being true the day after
it was written, when `chopshop-svg` gained `scripts/node_reduce.py`. That makes
`geometry_overload` the tracer-free rung §7 says it cannot be — see the
deviation note, not the paragraph below, for the current answer.

The goal: let a Jev `failure_mode` verdict trigger a *deterministic* re-trace or
re-filter, so a run can converge on a printable candidate without a human
guessing which knob to turn — while Jev itself stays observational.

---

## 0. Where this lives (boundary decision)

**This belongs in `chopshop-jev`, not `chopshop-svg`.**

`chopshop-svg` is public and must never carry Jev vocabulary. The failure-mode
names, the remediation table, and the loop driver are all Jev-coupled, so they
live here. The loop then *calls* the public pipeline exactly the way
`chopshop-sui`'s `swarm_bridge.py` does:

```
jev_remediate.py  --calls-->  front_pipeline.sh / snap_colors.py / palette_variants.py
                  --reads-->  <candidate>.jev.json (verdict), or a runner envelope
                              plus its --manifest (an envelope carries no findings)
                  --writes--> 06_run/<stem>.remediation.json + child sweeps
```

Nothing in `chopshop-svg` learns about Jev. No new flag, no new key, no import.
That keeps the existing rule intact — *the public pipeline is Jev-free* — and the
loop remains an optional external layer, never something the pipeline does to
itself.

The one exception is the **budget key**, which already exists in the public
spec (see §6) and needs no new Jev-aware code to be read.

---

## 1. Primitives that already exist (verified)

| primitive | where | state |
|---|---|---|
| `failure_mode` verdict, 7 choice values | `scripts/jev_annotate.py:114` | **live** |
| `verdict.headline` = the failure_mode | `compose_verdict()` | **live** |
| `low_confidence[]` + `confidence_floor` | `compose_verdict()` | **live** |
| `evidence_actionable` (noul) | `QUESTIONS` | **live** |
| per-preset param override (`preset_params`) | `../chopshop-svg/scripts/trace_sweep.py:259` | **live** — merges over built-in `PRESETS` |
| sweep axes: `filter_speckle`, `hierarchical`, `use_palette`, `max_candidates` | `trace_sweep.py` | **live** |
| colour snap with tolerance | `../chopshop-svg/scripts/snap_colors.py --tolerance` (default 32.0) | **live** |
| palette transfer with explicit map | `../chopshop-svg/scripts/palette_variants.py` | **live** |
| sweep JSON records every param + hashes | `02_traced/<stem>/sweep.json` | **live** |
| run chain: source → prep → sweep → svg hash → A/B → decision | `../chopshop-svg/scripts/run_record.py` | **live** |
| requirement board + exit gate | `../chopshop-svg/scripts/closeout.py` | **live** |
| table-as-data idiom (`requirements.json`) | `../chopshop-svg/requirements.json` | **live** — the pattern to copy |

**The decisive finding: no new tracing machinery is needed.** `preset_params`
already overrides one named preset, and the axes are already lists that can be
narrowed to a single value. A targeted retrace is therefore *a different sweep
JSON*, not a code change. The only genuinely new files are the table and the
driver.

### Two hazards in the existing code

**`validation.auto_retry_limit` is dead config.** It is in `spec.json` and
`spec.example.json` (value `3`), and `README.md:210` documents it as *"Retry
budget (used by the back-half runner)"*. **Nothing reads it.** `validate_svg.py`
passes the whole `validation` dict through into its `resolved` block and never
consults the key. Today the README statement is false. This plan proposes
honouring it (see §6) — or the doc should be corrected to say it is reserved.

**It is not the same knob as `--loop`.** Verified separately:

- `front_pipeline.sh --loop` → `scripts/pick_finish.py`, `MAX_PICKS = 3`. That is
  a **human menu limit** — "pick up to 3 candidates" per prompt, in an
  interactive pick → validate → pick loop.
- `pick_finish.py`'s own docstring is explicit: *"Re-tracing with new parameters
  means re-running the front half"* — i.e. the existing loop deliberately does
  **not** retrace.

So the automated retrace budget is a genuinely separate knob. Do not overload
`MAX_PICKS`; use `auto_retry_limit`.

### The determinism contract the loop must respect

`sweep.json` carries `"deterministic": true` and a `determinism_note`. The
contract is *same sweep JSON → same candidates*. **Therefore every remediation
iteration must emit its own sweep JSON**, or the retrace becomes unreplayable and
that field turns into a lie. This is a hard requirement, not a nicety.

---

## 2. The remediation table

Copy the `requirements.json` idiom: **data, not code**, in
`scripts/remediation_table.json`, so the policy is editable without touching
Python.

```json
{
  "_comment": "failure_mode -> deterministic remedy. Keys must match the choice values in scripts/jev_annotate.py QUESTIONS.failure_mode exactly. loopable=false means: do NOT retrace; report and stop.",
  "remedies": [
    {
      "failure_mode": "geometry_overload",
      "loopable": true,
      "needs_tracer": true,
      "grounds_in": ["NODE_COUNT"],
      "remedy": {"kind": "retrace", "axis": "filter_speckle", "step": +8, "range": [2, 48]}
    },
    {
      "failure_mode": "geometry_overload",
      "loopable": true,
      "needs_tracer": true,
      "variant": "coarser_layer",
      "remedy": {"kind": "preset_param", "preset": "poster", "param": "layer_difference", "step": +8, "range": [8, 64]}
    },
    {
      "failure_mode": "screen_explosion",
      "loopable": true,
      "needs_tracer": true,
      "grounds_in": ["COLOR_COUNT", "COLOR_COUNT_RENDERED"],
      "remedy": {"kind": "snap", "op": "force", "note": "cheapest: no retrace. Prefer this before dropping color_precision."}
    },
    {
      "failure_mode": "screen_explosion",
      "loopable": true,
      "needs_tracer": true,
      "variant": "lower_precision",
      "remedy": {"kind": "preset_param", "preset": "poster", "param": "color_precision", "step": -2, "range": [4, 8], "floor_note": "color_precision=2 collapses to 1 colour (measured) — the range floor is 4, not 0."}
    },
    {
      "failure_mode": "palette_mismatch",
      "loopable": true,
      "needs_tracer": false,
      "grounds_in": ["PALETTE"],
      "remedy": {"kind": "snap", "op": "tolerance", "from": 32.0, "to": 12.0, "range": [8.0, 32.0]}
    },
    {
      "failure_mode": "continuous_tone",
      "loopable": false,
      "needs_tracer": false,
      "grounds_in": ["CONTINUOUS_TONE"],
      "reason": "Tone cannot be reproduced by flat spot inks at any trace setting. This is a print-route decision (process halftone / DTG), not a trace-parameter one. Looping burns candidates for no outcome.",
      "next_step": "surface print_route from the same verdict to the operator"
    },
    {
      "failure_mode": "render_or_tool_failure",
      "loopable": false,
      "needs_tracer": false,
      "grounds_in": ["RENDER_ERROR", "PDF_ERROR", "MISSING_TOOL"],
      "reason": "A missing or failing tool (inkscape/gs/qpdf/poppler) is an environment fault. Retracing cannot fix it and will fail identically.",
      "next_step": "fail the iteration loudly and report the missing tool"
    },
    {
      "failure_mode": "no_hard_failure",
      "loopable": false,
      "needs_tracer": false,
      "reason": "Nothing to remediate. Stop — a retrace has no target and any change is a random walk.",
      "next_step": "hand the run back to the human pick"
    },
    {
      "failure_mode": "unclear",
      "loopable": false,
      "needs_tracer": false,
      "reason": "The measurements did not identify one signature, so no remedy can be justified.",
      "next_step": "ask for a human review, or improve measurement fidelity first"
    }
  ]
}
```

### Why each loopable remedy is legitimate

Every looping remedy must trace its trigger back to a **deterministic rule ID**,
not to Jev's opinion. That is what keeps the judgment observational and the
action reproducible:

| failure_mode | Layer A rule | Layer B rule | knob |
|---|---|---|---|
| `geometry_overload` | `NODE_COUNT` | — | `filter_speckle` ↑, `layer_difference` ↑ |
| `screen_explosion` | `COLOR_COUNT` | `COLOR_COUNT_RENDERED` | `snap_colors --force`, then `color_precision` ↓ |
| `palette_mismatch` | `PALETTE` | — | `snap_colors --tolerance` ↓ |

If the cited rule is not actually present in the candidate's findings, the remedy
is **not applied** — the table entry is ignored. This stops Jev from triggering a
param change on a file that has no such defect. (Call it the *grounding check*.)

---

## 3. Termination

### 3.1 Loopability is branch zero

Order of evaluation, before any candidate is traced:

```
1. verdict present and schema-valid?          no -> stop (refused_no_verdict)
2. failure_mode in low_confidence?            yes -> stop (refused_low_confidence)
3. evidence_actionable == false?              yes -> stop (refused_evidence)
4. table entry for failure_mode exists?       no  -> stop (not_loopable)
5. entry.loopable == false?                   yes -> stop (not_loopable) + next_step
6. grounding rule present in findings?        no  -> stop (not_grounded)
7. iteration < auto_retry_limit?              no  -> stop (budget_reached)
8. remedy param still inside range?           no  -> stop (range_exhausted)
9. same (failure_mode, remedy) already tried with no metric improvement?
                                              yes -> stop (no_progress)
10. this failure_mode equals the one two iterations back, and metrics are not
    improving?                                yes -> stop (oscillating)
                                              -else-> TRACE
```

Branches 2 and 3 are free wins: the loop should **refuse to act on an uncertain
verdict**. `low_confidence` already tells us when certainty fell below the floor,
and `evidence_actionable: false` already says the measurements do not support a
production decision. Acting on either would mean turning a guess into a retrace
that *looks* principled because a table was consulted. Both fields exist today;
no new Jev API surface is needed.

### 3.2 Termination statuses

Every iteration ends with exactly one status, written into the remediation log:

| status | meaning |
|---|---|
| `converged` | the grounded rule cleared (`hard_findings` for that rule == 0) |
| `budget_reached` | hit `auto_retry_limit` |
| `no_progress` | same remedy repeated, metric did not improve |
| `oscillating` | two modes alternating without metric movement |
| `range_exhausted` | the knob is at the end of its permitted range |
| `not_loopable` | mode is structurally unfixable by retracing (§2) |
| `not_grounded` | the cited rule is absent from the findings |
| `refused_low_confidence` | `failure_mode` was below the confidence floor |
| `refused_evidence` | `evidence_actionable` was false |
| `refused_no_verdict` | no verdict / malformed |

`converged` is the only *success*; every other status is a normal, expected end
and must be reported as such, not as an error.

### 3.3 The metric that defines "progress"

Progress must be measured on a **deterministic** number, never on Jev's score
(because Jev's judgement is advisory and its confidence can move on identical
input as the model is versioned). Use, in order:

1. count of hard findings for the grounded rule (want 0)
2. total hard findings
3. total advisory findings
4. for `geometry_overload`: `path_nodes_max` (monotone ↓)
5. for colour modes: `rendered_distinct_colors` (monotone ↓)

An iteration improves if **any** cited metric improves and none regresses. This
is the anti-random-walk rule: without it the loop is free to wander while
reporting activity.

---

## 4. Cost model

The cost concern is real and the arithmetic is lopsided. Current sweep width:

```
3 presets x 3 filter_speckle x 2 hierarchical x 2 use_palette = 36
capped by spec.print.sweep.max_candidates (the older flat print.sweep_max_candidates
still resolves as a fallback; spec.json leaves both unset -> 12)
```

So a full re-sweep per Jev cycle is **up to 36 traces and 3x-9x the current
candidate count**, and the expensive part is not the trace — it is Layer B
(Inkscape render + Ghostscript separation) run per candidate. Jev itself is
effectively free by comparison.

**Recommendation: targeted retrace, never a full re-sweep.**

An iteration narrows every axis to a single value and overrides one preset:

```json
{
  "version": 1,
  "presets": ["poster"],
  "preset_params": {"poster": {"colormode": "color", "mode": "spline",
                               "color_precision": 6, "layer_difference": 24}},
  "filter_speckle": [16],
  "hierarchical": ["cutout"],
  "use_palette": [true],
  "max_candidates": 2
}
```

That is **1–2 new candidates per iteration instead of 12–36**. At
`auto_retry_limit = 3` the worst case adds 3–6 candidates on top of the original
12 — bounded and predictable.

### Split remedies by whether they need the tracer

This is the biggest single saving, so it drives the table's ordering:

| class | modes | cost |
|---|---|---|
| **tracer-free** (post-process an SVG that already exists) | `palette_mismatch`; `screen_explosion` colour stage | ~0.1 s per file (measured: 6 palette variants in 0.96 s) |
| **tracer-required** | `geometry_overload`; `screen_explosion` once the `color_precision` floor is hit | 1 trace + Layer B per candidate |
| **not loopable** | `continuous_tone`, `render_or_tool_failure`, `no_hard_failure`, `unclear` | 0 |

**Most colour failures never need a retrace.** `snap_colors.py --force` is a pure
post-process on an existing SVG; `palette_variants.py` likewise. So the table
must try the tracer-free remedy first and only escalate to `color_precision` if
the snap cannot reach the budget. That ordering alone removes most of the cost
the concern is about.

---

## 5. Provenance — landing in the existing chain

The requirement: *"explain why candidate 3 has different settings than candidate
1"*. Today `run_record.py` builds one chain per stem:

```
source -> prep -> sweep entry -> SVG hash -> Layer A/B -> proof/PDF -> human decision
```

Iterations are new stems, because `pipeline.sh` takes
`02_traced/<stem>/<candidate>` and the stem comes from the directory name. So a
child iteration is `02_traced/<stem>__r2/`, and everything downstream
(`compare_candidates`, `pick_finish`, `run_record`) works on it unchanged.

Two additions, both additive:

**5.1 A `remediation` block in each child `sweep.json`.** Top level, next to
`deterministic`:

```json
"remediation": {
  "iteration": 2,
  "iteration_of": "00-example__r1",
  "root_stem": "00-example",
  "parent_candidate": "candidate_03.svg",
  "parent_svg_sha256": "…",
  "trigger": {
    "source": "05_final/candidate_03.jev.json",
    "headline": "geometry_overload",
    "confidence": 0.91,
    "low_confidence": [],
    "verdict_sha256": "…"
  },
  "remedy": {
    "id": "geometry_overload/filter_speckle",
    "kind": "retrace",
    "axis": "filter_speckle",
    "from": 2, "to": 16, "clamped": false
  },
  "status": "converged",
  "metrics_before": {"node_max": 4310, "hard": 2},
  "metrics_after":  {"node_max": 480,  "hard": 0}
}
```

This is what makes the settings explicable: the child sweep carries the verdict
that caused it, the exact delta, and the outcome. Because it lives in `sweep.json`,
it travels with the candidates and survives a copy of the output tree.

**5.2 An iteration log: `06_run/<root-stem>.remediation.json`.** One file per
remediation *chain*, listing every iteration in order with its trigger, delta,
status, and child stem. `run_record.py` gains one optional read
(`load_remediation()`), and `closeout.py` gains one check type
(`remediation_resolved`) so the board can show whether a chain converged.
Unchanged behaviour when the file is absent — the loop stays optional.

Deliberately **not** done: no change to `04_validated/<stem>.decision.json`. That
is the *human* decision record and its meaning must not be diluted by machine
iterations. The machine's reasoning goes in its own artifact.

---

## 6. Config surface — optional and tunable

Two levels, so policy and budget stay separable:

**Job level (`spec.json`, public repo, already present):**

```json
"validation": {
  "auto_retry_limit": 3,
  "remediation": {
    "enabled": false,
    "max_total_candidates": 24,
    "prefer_tracer_free": true
  }
}
```

- `auto_retry_limit` — the iteration budget. **Reuse this existing key** rather
  than inventing one; it is already in `spec.json`, already documented, and
  currently unread. Honouring it turns dead config into the budget, and the
  README line finally becomes true.
- `remediation.enabled` — **default `false`**. Opt-in, matching the conventions
  already used elsewhere: `--preflight` on `palette_variants.py` is off by
  default, `jev_annotate.py --optional` degrades gracefully. Nothing in the
  pipeline changes behaviour for anyone who does not ask for this.
- `max_total_candidates` — a hard ceiling across all iterations, independent of
  the per-iteration budget. Guards the case where each iteration is cheap but
  the chain is long.

**Policy level (`scripts/remediation_table.json`, this repo):** which remedy
each mode maps to. Editable without code.

**CLI:**

```
python scripts/jev_remediate.py 06_run/00-example.run.json --dry-run
      # print the plan per iteration, run nothing
python scripts/jev_remediate.py ... --remediate
      # actually retrace / re-filter
python scripts/jev_remediate.py ... --optional
      # exit 0 with a skip note when no JEV_API_KEY
```

`--dry-run` prints the table lookup, the chosen remedy and the resulting sweep
JSON for each branch without executing. This is the review affordance that makes
the whole thing trustworthy: the deterministic decision is inspectable before it
costs anything.

---

## 7. Colour reduction + the palette system

The colour remedies are the part that joins up with existing tooling, so they
should be described as **one ladder**, cheapest rung first:

| rung | tool | changes | reaches budget by | cost |
|---|---|---|---|---|
| 1. snap to palette | `snap_colors.py --force` | `fill`/`stroke`/`stop-color` | collapsing near-misses onto palette entries | post-process, ~0.1 s |
| 2. tighten snap tolerance | `snap_colors.py --tolerance` ↓ | same | refusing to leave off-palette colours unmatched | post-process |
| 3. palette transfer | `palette_variants.py` + explicit `map` | `fill`/`stroke`/`stop-color` only | deliberate re-colouring onto a target palette | post-process, + optional `--preflight` |
| 4. lower trace precision | `trace_sweep.py` `preset_params.color_precision` ↓ | the trace itself | fewer colour clusters at source | **retrace** |
| 5. coarser layering | `preset_params.layer_difference` ↑ | the trace itself | fewer gradient layers | **retrace** |

Measured behaviour to respect:

- `poster` alone produces **362–3748 colours** on photographic input — it does
  not by itself meet a 6-colour budget.
- `snap_colors --force` took a **677-colour** trace to **4 colours**. Rungs 1–2
  are therefore far more effective than intuition suggests, and should always be
  tried before rung 4.
- `color_precision = 2` collapses to **1 colour** — too aggressive. Hence the
  table's `range: [4, 8]` floor. A remediation loop that is allowed to walk
  `color_precision` downward without a floor will destroy the artwork.

**Rungs 1–3 preserve geometry byte-identically** — only colour attributes
change, every `d=`, `viewBox`, `width`/`height` is untouched, and
`palette_variants.py` already writes a per-variant `mapping.json` recording
source→target for every colour. That matters twice:

1. It means a colour remedy can **never** worsen `geometry_overload` — the node
   count is provably unchanged. The two failure modes cannot interfere.
2. The `mapping.json` is exactly the provenance the loop must cite for a colour
   iteration, and it already exists.

**Node reduction is the gap.** There is no node simplifier in the repo. The
`NODE_COUNT` rule *gates* `geometry.max_nodes_per_path` (500 in `spec.json`) but
nothing reduces nodes; `filter_speckle`, `layer_difference` and `mode` are the
only levers, all tracer-side. So `geometry_overload` is the one mode that always
needs a retrace. If a tracer-free path is wanted later, the honest option is a
new `simplify_paths.py` (svgpathtools line/curve fitting) — a genuinely new tool,
not a rewiring of an existing one. Kept out of scope here.

**Where the palette library fits:** `scripts/palettes.json` holds six named
palettes. A remediation iteration may target `spec.palette` (the contract) or a
named library palette — but only the former resolves `palette_mismatch`, since
that rule compares against the contract. A library palette is a *design* choice
and stays human.

---

## 8. Guards the loop must keep

1. **It never picks a winner.** Every iteration produces candidates that go back
   to the human pick. The loop changes *settings*, never *selection*. This is the
   `AGENTS.md` rule and the loop must not become a back door around it.
2. **Deterministic decisions only.** The remedy is a table lookup on a choice
   value plus a bounded arithmetic step. No model output ever becomes a
   parameter value directly — that is precisely the failure the table exists to
   prevent.
3. **Every iteration writes its own sweep JSON** (§1, determinism contract).
4. **Ranges are enforced, not suggested.** A remedy that would leave its range
   terminates as `range_exhausted` rather than clamping and continuing.
5. **Idempotent.** Re-running with the same inputs reproduces the same
   iterations; an existing `__rN/` directory is reused, not re-traced.
6. **Optional and offline-safe.** Absent `JEV_API_KEY` → skip, exit 0, note it.
   No network in the trace path. Matches `jev_annotate.py --optional`.
7. **Bounded.** Per-iteration budget *and* a total candidate ceiling.
8. **Fails loudly on tool problems.** `render_or_tool_failure` is never
   loopable — the iteration ends `not_loopable` with the missing tool named.

---

## 9. Non-goals

- Not an autotuner. No search over the parameter space; each step is a
  deterministic response to a named failure.
- Not a ranker. No candidate is promoted or discarded by the loop.
- Not a replacement for the human pick.
- Not wired into `front_pipeline.sh` or `pipeline.sh`. Called by hand or by the
  runner, like every other optional layer.
- No Jev awareness in `chopshop-svg`.

---

## 10. Implementation order

1. **DONE** (`4c0c0eb`) — `scripts/remediation_table.json`, the table as data,
   plus a test that every `failure_mode` in `jev_annotate.QUESTIONS` has either a
   remedy or an explicit `loopable: false` entry. (Cheap, and it pins the
   vocabulary to the code.)
2. **DONE** (`4c0c0eb`) — grounding + refusal logic behind `--dry-run`. No
   execution. The ten termination statuses are pinned, with `converged` listed
   for completeness even though this pass cannot reach it.
3. `preset_params`-driven targeted sweep emission + the determinism test
   (same inputs → identical child sweep JSON twice).
4. Wire the tracer-free rungs (`snap_colors`, `palette_variants`) and the ladder
   ordering.
5. Provenance: the `remediation` block in child sweeps, then
   `06_run/<stem>.remediation.json`.
6. `run_record.py` + `closeout.py` optional read and the `remediation_resolved`
   check type — additive, with existing tests proving unchanged behaviour when
   the artifact is absent.
7. `auto_retry_limit` honoured; README line corrected either way.

Step 3 is the remaining risk — it is the one that writes files. 4–7 are
mechanical.

---

## 11. Open questions

1. **Does `converged` mean "printable" or "the grounded rule cleared"?** This
   plan assumes the latter — the narrow, defensible claim. A candidate can clear
   `NODE_COUNT` and still be rejected by the human. Worth confirming.
2. **Should `continuous_tone` escalate `print_route` automatically?** The verdict
   already carries `print_route` (`process_halftone`, `dtg_or_dtf`). Surfacing it
   is free; *acting* on it is a route change, which is a commercial decision.
   Recommend: surface only.
3. **One metric per mode, or a vector?** §3.3 ranks five. A vector with
   dominance checking is stricter but harder to explain in a log.
4. **When several candidates in one comparison fail differently, which one seeds
   the iteration?** Options: the Jev `headline` of the fewest-hard-findings
   candidate; or one chain per distinct mode. The latter multiplies cost, so the
   former is the default — but it does encode a preference, which brushes against
   "never rank". Recommend: iterate per distinct mode, cap by
   `max_total_candidates`, so no candidate is privileged.
5. **Should the human decision record the iteration it came from?** It would help
   auditability but risks implying the machine proposed the pick. Recommend: the
   link lives in `remediation.json` (machine side), and the decision record stays
   clean.
