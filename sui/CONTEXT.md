# CONTEXT.md — chopshop-sui

Working state for agents and humans: what is in flight, what is blocked, and
the caveats that are not obvious from the code. Update this as work lands.

**Superseded by [chopshop-flux](../flux/README.md):** the
generation layer moved there (one small HTTP service, its own model registry, no
SwarmUI/ComfyUI). Everything below is the historical SwarmUI stack, kept for the
facts it pinned down — read the model caveats as facts about those models, not as
a live path in this repo.

**Retirement decision (2026-10-12, issue #1): kept for research only, do not
extend.** Reasoning: the layer is fully superseded and no in-flight work
remains, but the repo still carries durable research value — the verified SwarmUI
API wire format, the model caveats, the binary-trace panic, the workflow survey
under `docs/` — so it stays readable rather than being archived. Archiving the
repo on GitHub remains the human's option and is deliberately not taken here (a
destructive, GitHub-side action); until then, the rules in `AGENTS.md` bind the
layer as it stands and nothing in this repo may be extended.

**Repo visibility: private.** This layer encodes a specific generation stack
and local install paths — keep it out of the public `chopshop-svg` repo.

**Language: English only.** Every file, comment, doc, string and commit message in
this repo is English — no CJK (Chinese/Japanese/Korean) characters. Where a parser
genuinely needs them, write `\uXXXX` escapes, never the literal
(`docs/agents/standards.md`, rule "English only").

## What this repo is

The SwarmUI / ComfyUI generation layer for the chopshop print pipeline. It
answers "where does a source raster come from, and where does artwork go
between generations". It **calls** the pipeline (never the reverse): the bridge
(`scripts/swarm_bridge.py`) and the in-graph `ChopShopTrace` node trace a
generated raster, and `front_pipeline.sh` / `pipeline.sh` in `chopshop-svg`
know nothing about SwarmUI. It never judges art.

## Work in progress

- No tracked in-flight feature at the time of writing. The bridge and the
  `ChopShopTrace` node are built and tested.

## Blockers

- None known.

## Caveats / known issues

- **FLUX.2 Klein 4B is guidance-distilled (CFG ~1.0): a negative prompt has no
  effect.** That is the model, not a wiring gap. Steering goes into the positive
  prompt plus the source image; switch to the non-distilled `klein-4b-base`
  (chopshop-flux's registry key for `black-forest-labs/FLUX.2-klein-base-4B`,
  shipped as `flux-2-klein-base-4b.safetensors` in the ComfyUI layout) only if
  guidance > 1.0 is genuinely required.
- **VTracer binary-mode colour clustering overflows on diffusion output**
  (Rust `CapacityOverflow` panic → a queue entry stuck "running"). Trace with
  `colormode=color`, never `binary`, on generated images.
- **The SwarmUI backend port drifts +1 on every restart** (starts at 7820).
  Discover it (`ss -ltnp | grep main.py`), never hard-code it; the UI is on 7801.
- **`scripts/SWARMUI_PLAN.md` is HOST-SPECIFIC** — it describes this install.
  It stays in this private repo and must not be published.
- **`StrictFilenameClean` strips every `.`** in example filenames — use `Flux2`,
  never `Flux.2`.
- **Model layout is ComfyUI-native split files** (diffusion_models / text_encoders
  / vae); SwarmUI needs a settings rescan (or restart) to see freshly placed
  models, not a re-download.
- **`scripts/front_common.py` is a 2-function vendored shim**, not a mirror of
  chopshop-svg's 12-function module. It exists so `swarm_bridge.py` imports (and
  the suite runs) with no chopshop-svg checkout present. Do not copy it over a
  chopshop-svg checkout — that strips helpers the pipeline scripts import.
- **Only `gen2pipe` reaches the pipeline, and it looks for `front_pipeline.sh`
  at this repo's root** (`PROJECT = dirname(scripts/)`), never the cwd or PATH.
  `generate` and `filter` never trace; `filter` is the one mode that needs
  Pillow at runtime (source dimensions + the `data:` URL).
- **Example filenames must not carry a period** beyond the extension — this is
  also why the regenerated workflow example is `... Flux2 Klein 4B.json`, and
  `comfy_to_swarmui.py`'s usage line says so.

## Doc/code alignment (2026-09-29)

Audited `README.md`, `CONTEXT.md`, `AGENTS.md`, `docs/*`, `skills/**`,
`swarm_workflows/README.md` and `scripts/*.md` against the source
(`swarm_bridge.py`, `front_common.py`, `comfy_to_swarmui.py`,
`comfyui_chopshop/__init__.py`, `trace_generate_trace_flux2_klein.json`).

- **`filter` was documented as handing off to `front_pipeline.sh`** in
  `README.md` and the skill — it does not; only `gen2pipe` does. Fixed in both,
  along with the "run from a directory with a chopshop-svg checkout alongside"
  advice, which misstated the resolution (the bridge uses its own repo root).
- **The `ChopShopTrace` output was documented as `svg` (STRING), "the traced
  SVG"** — the node's schema names it `svg_filename` and the value is the
  *filename* it wrote to the ComfyUI output dir (a list for a batch). Fixed in
  `swarm_workflows/README.md` and the skill.
- **Stale cross-repo test count** (`SWARMUI_PLAN.md`: chopshop-svg's suite
  "369 tests") — chopshop-svg's `CONTEXT.md` carries the live count; the number
  is gone rather than bumped a third time.
- **A documented regenerate command used `"~/..."`**, where the tilde cannot
  expand inside quotes; `"$HOME/..."` now. The same example in
  `comfy_to_swarmui.py`'s docstring used `Flux.2` in the filename, contradicting
  the `StrictFilenameClean` pitfall — fixed.
- **`front_common.py`'s docstring claimed byte-identity with a copy in
  chopshop-svg** — chopshop-svg has never tracked `swarm_bridge.py` and its
  `front_common.py` is a superset; docstring reworded.
- **`requirements.txt` said the bridge is stdlib-only** — `filter` imports
  Pillow. Comment and README corrected.
- **`docs/agents/domain.md` was the generic upstream scaffold**, pointing at a
  `CONTEXT-MAP.md`, a `docs/adr/` and an `src/` tree this repo has never had;
  rewritten repo-specific (single-context, root `CONTEXT.md`).
- **Workflow-count claim** ("20 workflows in five categories") — 18 workflows in
  five categories plus two SwarmUI surfaces; README now says so.
- **The superseded-by-chopshop-flux banner was missing** from
  `swarm_workflows/README.md`, the skill and `SWARMUI_PLAN.md`, which still read
  as a live plan. Added in all three.
- **Policy 6 (breadcrumbs) had no instances in this repo's code.** Added
  `#sui-bridge-run-front-pipeline` and `#sui-trace-node-vtracer` at the two
  cross-file call sites.

No `AGENTS.md` change was required — its claims (docs/agents contents, the
cross-repo docs path, the six hard rules) all match the repo, so nothing was
blocked by the protected-file guard this pass. `21 passed` after the edits.

## Doc/code alignment (2026-10-12)

- **Issue #1 — the superseded banner completed, and the retirement
  question answered.** `AGENTS.md` (the first file an agent reads) and
  `skills/README.md` (whose `cp -r` instruction still presented the
  skill as a live import) carried no supersession notice; both now do.
  `AGENTS.md`'s banner carries the decision — **kept for research
  only, do not extend** — and states that the hard policy binds the
  layer as it stands, not as an invitation to extend it; the decision
  and its reasoning are recorded above. Archiving the repo on GitHub
  remains the human's option and was deliberately not taken.
- **Issue #2 — the divergent `scripts/swarm_styles.json` retired.**
  The file forked the style vocabulary chopshop-flux owns: flux's
  `chopshop_flux/styles.py` `BUILTIN_STYLES` was ported from this
  repo's bridge and has since grown to 9 styles, while the file held
  3, and the two share no source. Consumer evidence (repo-wide grep):
  the only code consumer is `swarm_bridge.py`'s `DEFAULT_STYLES` —
  an *optional* overlay: `_load_styles` merges the file over the
  built-ins and falls back to the built-ins when it is absent, and
  the suite never reads the shipped file (tests pass a nonexistent
  path); everything else is doc references. The fork was replaced
  with a deprecation stub carrying no styles and pointing at flux's
  `styles.py`; the bridge serves `flat-poster` / `mono-line` /
  `photo-halftone` unchanged from its `BUILTIN_STYLES`. Wiring the
  bridge to flux's `BUILTIN_STYLES` was rejected — a cross-repo
  runtime dependency in a superseded, research-only repo is worse
  than a documented stub. Known cosmetic effect, accepted: the
  stub's two `_`-prefixed metadata keys appear in `apply_style`'s
  "available styles" error listing (the bridge was left untouched).

`21 passed` before and after both changes.
