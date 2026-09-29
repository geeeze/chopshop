# chopshop-sui

> **Superseded by [chopshop-flux](https://github.com/geeeze/chopshop-flux).**
> chopshop-flux replaces the broad SwarmUI/ComfyUI integration described here
> with one small HTTP service over its own model registry — no SwarmUI, no
> ComfyUI graph, no workflow wrapper. Generation work belongs there; this repo is
> kept for its history, the workflow research under `docs/`, and the model and
> trace pitfalls it pinned down (the style recipes were carried over).

SwarmUI / ComfyUI integration for [chopshop-svg](https://github.com/geeeze/chopshop-svg).

**chopshop-sui** is the layer that connects the chopshop print pipeline to a
running [SwarmUI](https://github.com/mcmonkeyprojects/SwarmUI) instance. It is a
separate, opt-in layer: it *uses* the chopshop-svg pipeline scripts and never
interferes with the standard `front_pipeline.sh` / `pipeline.sh` flow. It never
judges the art — it produces sources and candidates; a human picks.

Two pieces live here:

1. **The bridge** (`scripts/swarm_bridge.py`) — a CLI that talks to SwarmUI's
   HTTP API to generate raster sources and (via chopshop-svg) trace them. It
   imports `scripts/front_common.py`, a vendored two-helper shim
   (`load_json` / `write_json`) that is enough to import and run the bridge
   with no chopshop-svg checkout present.
2. **The workflow** (`swarm_workflows/`) — a ComfyUI `trace → generate → trace`
   graph (FLUX.2 Klein 4B) with a custom `ChopShopTrace` node that inlines the
   pipeline's VTracer inside the generation graph.

## The bridge

Three modes:

```bash
# text -> image(s), raw generation (eyeball before committing to a trace)
.venv/bin/python scripts/swarm_bridge.py generate "a dragon logo" \
    --width 1024 --height 1024 --out-dir 00_source

# source image + text -> img2img variant(s) (a filter on existing sources)
.venv/bin/python scripts/swarm_bridge.py filter 00_source/remon.png \
    "flatten to 8-color screen-print poster" --creativity 0.5

# text -> image -> prep -> sweep -> compare (hands off to chopshop-svg)
.venv/bin/python scripts/swarm_bridge.py gen2pipe "a phoenix emblem" \
    --style flat-poster
```

Style templates come from `scripts/swarm_styles.json` (`flat-poster`,
`mono-line`, `photo-halftone`). `--style NAME` pairs a prompt suffix with a
trace preset.

### Relationship to chopshop-svg

`generate` and `filter` are self-contained (SwarmUI + disk only): `filter`
writes its img2img variants and stops, it never traces. **Only `gen2pipe`**
hands the raster to chopshop-svg's `front_pipeline.sh` (prep → sweep →
compare), which is **not** in this repo — it lives in a chopshop-svg checkout.

The bridge resolves the pipeline from its **own repo root**
(`PROJECT = dirname(scripts/)`), not from the current directory, so `gen2pipe`
only runs when this checkout itself carries the pipeline: copy
`front_pipeline.sh` and the pipeline scripts it calls in alongside, or copy
`scripts/` into a chopshop-svg checkout. When copying, **do not overwrite
chopshop-svg's `scripts/front_common.py`** — the copy here is a 2-function
subset (`load_json` / `write_json`) of that 12-function module, and the
pipeline scripts need the full set.

### API facts (verified against SwarmUI 0.9.8.3)

See `scripts/SWARMUI_PLAN.md` for the full plan, the verified API facts, and the
remaining work. The bridge's HTTP layer is stubbed in the tests, so the suite
runs with no server and no models.

## The workflow (`swarm_workflows/`)

`trace_generate_trace_flux2_klein.json` is the ComfyUI API-format graph:
**trace the source → generate (FLUX.2 Klein 4B img2img) → trace the output**,
with a TAESD fast preview. `scripts/comfy_to_swarmui.py` converts it to a
loadable SwarmUI example (the `.json` with the full title is the generated
SwarmUI wrapper). `comfyui_chopshop/__init__.py` is the `ChopShopTrace` custom
node — the pipeline's exact VTracer, hardened to catch the Rust panic that
`colormode=binary` hits on noisy diffusion output (trace generated images in
`color` mode).

Full details, model files, and the binary-vs-color pitfall:
`swarm_workflows/README.md`.

## Public workflow research (`docs/workflow-candidates.md`)

A curated survey of **20 entries — 18 publicly available** ComfyUI / SwarmUI
workflows that could plug into chopshop, in five categories: image-to-image /
style transfer, colour quantisation and segmentation, raster-to-vector tracing,
T-shirt and graphic design generation, and ControlNet structure locking — plus
a closing section with two SwarmUI resources that are integration surfaces
rather than workflows. Each entry records what it does, where it lives, and
what integrating it would take — plus a quick-pick table for the ones worth
trying first.

Two findings from it are already load-bearing:

- **Tracing stays in the graph.** `ComfyUI-ToSVG` (Yanick112) wraps VTracer as a
  node, and the Flux.2 Klein raster-to-vector workflow pairs img2img with it and
  a prompt saver — the same shape as `swarm_workflows/` here.
- **VTracer's `--palette` / `--max-colors` are standalone-CLI only.** The PyPI
  wheel this project installs is API-only and exposes neither, so colour
  reduction belongs to the pipeline's own snap step, not a trace flag.

## Install / tests

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest tests/
```

21 tests pass; they stub the SwarmUI HTTP layer and the pipeline seam, so they
run anywhere with no GPU, no server, and no models. `pytest` is test-only;
`Pillow` is also the bridge's one runtime dependency, used by `filter` (source
dimensions + the `data:` URL) — `generate` and `gen2pipe` are stdlib-only.

## Agent skill

`skills/chopshop-swarmui-integration/` is the agent-facing reference for this
layer — the verified API facts, the trace-node pitfall, the workflow files and
the model caveats. It is deliberately private-stack (see `skills/README.md`),
unlike the two pipeline skills published in `chopshop-svg`.
