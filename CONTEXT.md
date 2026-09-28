# CONTEXT.md — chopshop-sui

Working state for agents and humans: what is in flight, what is blocked, and
the caveats that are not obvious from the code. Update this as work lands.

**Superseded by [chopshop-flux](https://github.com/geeeze/chopshop-flux):** the
generation layer moved there (one small HTTP service, its own model registry, no
SwarmUI/ComfyUI). Everything below is the historical SwarmUI stack, kept for the
facts it pinned down — read the model caveats as facts about those models, not as
a live path in this repo.

**Repo visibility: private.** This layer encodes a specific generation stack
and local install paths — keep it out of the public `chopshop-svg` repo.

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
