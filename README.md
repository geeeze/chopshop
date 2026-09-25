# chopshop-sui

SwarmUI / ComfyUI integration for [chopshop-svg](https://github.com/geeeze/chopshop-svg).

**chopshop-sui** is the layer that connects the chopshop print pipeline to a
running [SwarmUI](https://github.com/mcmonkeyprojects/SwarmUI) instance. It is a
separate, opt-in layer: it *uses* the chopshop-svg pipeline scripts and never
interferes with the standard `front_pipeline.sh` / `pipeline.sh` flow. It never
judges the art — it produces sources and candidates; a human picks.

Two pieces live here:

1. **The bridge** (`scripts/swarm_bridge.py`) — a CLI that talks to SwarmUI's
   HTTP API to generate raster sources and (via chopshop-svg) trace them.
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

`generate` is self-contained (SwarmUI + disk only). `filter` and `gen2pipe` end
by handing the raster(s) to chopshop-svg's `front_pipeline.sh`, which is **not**
in this repo — it lives in a chopshop-svg checkout. The bridge resolves the
pipeline location from its own repo root, so run these modes from a directory
that has a chopshop-svg checkout alongside, or copy the bridge into a
chopshop-svg checkout.

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

A curated survey of **20 publicly available** ComfyUI / SwarmUI workflows that
could plug into chopshop, in five categories: image-to-image / style transfer,
colour quantisation and segmentation, raster-to-vector tracing, T-shirt and
graphic design generation, and ControlNet structure locking. Each entry records
what it does, where it lives, and what integrating it would take — plus a
quick-pick table for the ones worth trying first.

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
.venv/bin/pip install pytest Pillow      # tests only (the bridge itself is stdlib)
.venv/bin/python -m pytest tests/
```

21 tests pass; they stub the SwarmUI HTTP layer and the pipeline seam, so they
run anywhere with no GPU, no server, and no models.
