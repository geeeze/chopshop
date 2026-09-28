> HOST-SPECIFIC — the venv paths (`~/chopshop-studio-runner-venv`,
> `~/chopshop-svg/.venv`) and the mock-runner reference are this box's.
> The sweep-axis anatomy is generic.

# chopshop-svg front pipeline — development reference

The real raster→vector pipeline lives in `~/chopshop-svg`. Front half:

```
prep_raster.py  (stage 1: check/normalise raster -> 01_prepped/<stem>.prepped.png + .prep.json)
trace_sweep.py  (stage 2: VTracer sweep -> 02_traced/<stem>/candidate_NN.svg + sweep.json)
compare_candidates.py (stage 3: Layer A+B + fidelity -> 04_validated/<stem>.comparison.md/.json)
front_pipeline.sh (orchestrator: prep -> sweep -> compare, never calls the back half)
```

Shared helpers live in `scripts/front_common.py`: `print_options()` (merges
`print.*` defaults), `resolve_workers()` / `run_parallel()` (process pool,
results in task order), `hex_to_rgb()`, `sha256_file()`, `load_json`/`write_json`.
The back half (`validate_svg.py`, `preflight.py`, `pipeline.sh`) takes an SVG and is a
separate deliverable — never mix the two halves' concerns.

## Dev environment (the venv, and which one NOT to use)

- `chopshop-svg/.venv` is gitignored. Fresh checkout: `cd ~/chopshop-svg &&
  python3 -m venv .venv && .venv/bin/pip install -r requirements.txt` (pins
  lxml, svgpathtools, Pillow, numpy, vtracer; dev extras pytest, pyflakes).
- System `python3` is externally-managed (PEP 668): `python3 -m pip install --user`
  fails with a `--break-system-packages` hint. Always use the repo venv for pipeline work.
- `~/chopshop-studio-runner-venv` is NOT the pipeline venv. It carries only Pillow because
  the mock runner is pure-PIL by design. It lacks numpy/vtracer/lxml, so pipeline tests or
  scripts run from it will fail on import. Do not confuse the two venvs.
- Run tests: `.venv/bin/python -m pytest tests/ -q -p no:cacheprovider`. The
  `-p no:cacheprovider` is cosmetic but avoids a permission warning when
  `.pytest_cache/` is root-owned.

## Sweep anatomy

`trace_sweep.py` builds candidates from a nested product of axes, each in a documented
interleaved order: speckle → hierarchical → preset → palette (`use_palette`). Axis values resolve
in this precedence — `DEFAULT_SWEEP` < **`spec.print.sweep`** < `--sweep <file>` — each layer
merged partial-over-partial, so an object naming one axis leaves the others at their default (and
`--sweep` may still add `preset_params`).

**The axes are part of the job CONTRACT**, not an internal default:

    "print": {"sweep": {"presets": ["bw", "poster"],
                        "filter_speckle": [2, 8],
                        "hierarchical": ["cutout"],
                        "use_palette": [false],
                        "max_candidates": 8}}

Without that key a job cannot express which presets it traces at all — the operator picks them in
the JSON builder's Sweep card, and the mock runner reads the same keys so the demo previews the
real thing. The cap is `print.sweep.max_candidates`, with the older `print.sweep_max_candidates`
honoured only when the namespaced key is absent, resolved in ONE place (where the sweep config is
merged) so the two spellings cannot disagree — it was once read twice, the second read won, and a
cap of 3 produced 12 candidates. A non-object `print.sweep` is refused with exit 2, never silently
ignored. Cover each path in tests: narrowing by spec, an omitted axis keeping its default, both cap
spellings, `--sweep` beating the spec, and the refusal. The round-robin truncation still samples
every value of every axis at a small cap.

`print.*` keys are owned by the front half. A new key must be added in BOTH places or a
minimal spec silently falls back wrong: `front_common.PRINT_DEFAULTS` and `spec.example.json`.

## Trace settings: which levers are ALREADY pulled

When someone proposes "use spline not polygon, raise filter_speckle, lower color_precision", check the
table first — most of that list is already the default, and the genuine gaps are elsewhere.

| lever | state in `trace_sweep.py` |
|---|---|
| `mode: spline` | ALREADY the default for `poster` and `photo` (`bw` is `colormode: binary`, no mode key) |
| `filter_speckle` | ALREADY a swept axis — `[2, 8, 16]` |
| `color_precision` | ALREADY set — 6 (poster), 8 (photo) |
| `corner_threshold` | **unset anywhere** — sits at the vtracer default |
| `length_threshold` | **unset anywhere** — sits at the vtracer default |
| `splice_threshold` | **unset anywhere** — sits at the vtracer default |

The three thresholds are the real untapped levers: in no preset and on no axis. Wire them like any
other axis (checklist below) rather than adding them ad hoc to one preset.

**There is NO denoise/blur step in prep at all** — `prep_raster.py` and `front_common.py` hold no
Gaussian, bilateral or median pass. Prep is check-first by design (it copies the input through
unchanged unless `--fix`), so noise reduction is a genuine hole rather than a hidden setting: anything
proposed there is new code and a new optional step, not a flag flip. If it is added it must default
OFF and be spec-enabled, like every other transform, or output starts depending on how a host was
provisioned.

`node_reduce.py` already does targeted Douglas-Peucker-style reduction (only paths over the node
gate, transactional, `--verify` renders before/after) — but it is a by-hand side tool wired into no
stage. Same for svgo's `convertPathData`: `scripts/svgo_print.yml` exists and nothing runs it.

## The inverted-average trap (do not build this)

Written down because it reads plausible and has been proposed more than once:

> average the source with an inverted/offset copy to cancel noise

Averaging an image with its colour-inverse yields FLAT MID-GREY — per channel, an average of `x` and
`1-x` is 0.5 everywhere. It destroys the artwork instead of denoising it. The astrophotography
analogy invoked for it is misapplied in both halves: dark-frame subtraction subtracts a measured
*noise* frame (bias / dark current), and frame stacking averages N *aligned* captures of the same
scene. Neither inverts the signal.

The offset half of the idea is sound but is not a new mechanism: offsetting copies by sub-pixel
amounts and averaging IS a convolution with the kernel those offsets describe. So producing N raster
passes buys nothing over applying the equivalent kernel once in prep, unless the passes genuinely
differ in content (real different exposures or sources). If directional smoothing is wanted — soften
vertical edges more than horizontal, for hair and fur — implement the kernel: cheaper, deterministic,
and it leaves no intermediate rasters behind.

## JEV inside the pipeline: two rules it must respect

Jev is an ON-DEMAND studio call today. Any proposal to invoke it at every pipeline step has to honour
two standing decisions or it breaks something already settled:

- **Auto-invocation needs a not-configured path.** An unconfigured add-on answers 503 with its reason,
  and every optional step defaults OFF unless the spec enables it. A stage that calls Jev
  unconditionally means a box without the key cannot run the pipeline at all. Gate it on the spec the
  same way `print.tools.<step>` is gated, and skip-with-reason when absent.
- **Letting Jev choose trace settings is a DIFFERENT posture from letting it rank candidates.** The
  sweep's stated law is that it never recommends a cell (`tune_sweep.py` never recommends a cell,
  never ranks). A model picking the preset/params that generate the candidates does not pick a winner,
  but the sweep stops being neutral. Decide that deliberately; don't let it arrive as a side effect.

The annotator is MOUNTED from its own private repo and the key is host-local, so calling it from
inside a stage adds an external-model dependency to a PUBLIC tool — which is the other reason to keep
it spec-gated and skippable.

## Adding a sweep axis / variant (checklist)

A new axis (e.g. a source transform like pitch-shift's source/inverse/pitch) touches every
one of these, in order — miss one and the axis is silently ignored or wrong:

1. `trace_sweep.py` `build_candidates`: add the axis to the nested loop and to the
   per-candidate dict. Decide whether the new axis RETIRES an existing one (pitch-shift
   retires `use_palette`, because the transformed candidate *is* the palette candidate).
2. `trace_sweep.py` truncation round-robin: **update the group key to include the new axis.**
   The interleave groups by `(speckle, variant)` etc. so a small cap round-robins across
   every value. If you add an axis but leave the group key unchanged, a cap ≤ the group count
   aliases every selected candidate onto the first value of the new axis — the higher values
   are never traced. This is the single most common way a new sweep axis is silently broken.
3. `trace_sweep.py` `_trace_one`: thread the axis into the per-task input selection. For a
   derived-raster axis, pre-generate each variant raster ONCE in the parent (under a hidden
   dir like `.variants/`), hand the worker a `{variant -> path}` map, and record
   `variant_input` + its sha256 in the candidate record — never re-derive per worker.
4. `trace_sweep.py` `_sweep`: add the axis to the record dict and to the per-candidate
   status print line.
5. `compare_candidates.py`: add the axis label to `_sweep_summary`, and — if the axis
   changes the raster — make fidelity diff each candidate against ITS OWN source raster
   (see below), not the original.
6. `scripts/TRACE_STAGE.md` (renamed from `FRONT_HALF.md`) + `tests/test_trace_sweep.py`:
   document and test the axis, including
   the off/legacy path (the axis absent must reproduce the old behaviour byte-for-byte).

## Fidelity diff against the candidate's own source

`compare_candidates.py` renders each candidate back to raster and diffs against the source
for MAE. A candidate traced from a *transformed* raster (inverse, palette-quantised) diffed
against the ORIGINAL source reports a misleadingly huge error — it is different on purpose.
When a sweep record carries a `variant_input` (the derived raster), diff against that instead
of the prepped source. `_candidate_source(sweep_entry, default)` does this; extend it when
adding a transform axis.

## Mock/docker parity

The mock runner (pure-PIL, `/tmp/chopshop-mock/<job_id>/`) and the docker runner must stay in
behavioural parity for the operator contract — and the mock runner exists as TWO files that drift,
so diff before choosing which copy wins (SKILL.md). A spec key one side honours and the other
ignores reads as a demo that lies about the real pipeline. When a spec flag changes what the front half
produces (e.g. a new sweep axis), the mock runner must simulate the same shape — same
candidate `sweep` fields, same derived artifacts — or the demo UI silently diverges from the
real pipeline it is meant to preview.

## Tracked example outputs go dirty after any local back-half run

`04_validated/*.layer_a.txt` and the other example reports under `01_prepped/`, `02_traced/`,
`04_validated/`, `05_final/` are TRACKED even though `.gitignore` lists those directories — ignore
rules never apply to already-tracked files. So running the back half on this box (any Proof run)
rewrites `04_validated/candidate_NN.layer_a.txt` with THIS machine's details: an
`/app/02_traced/upload_<hash>/...` path and a different node count. The repo is PUBLIC, so that
never gets committed. It shows up as a mystery dirty file during a clean sweep: restore it with
`git checkout -- 04_validated/candidate_NN.layer_a.txt` (upstream's version is the canonical
example) and treat any future diff there as generated noise unless the numbers were deliberately
regenerated.
