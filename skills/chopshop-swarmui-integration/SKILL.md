---
name: chopshop-swarmui-integration
description: Use when extending the chopshop SwarmUI/ComfyUI layer. Covers the bridge API, the in-graph trace node, and the pipeline seam.
---

# chopshop-sui — the SwarmUI / ComfyUI layer

> **Superseded by [chopshop-flux](https://github.com/geeeze/chopshop-flux):** the
> generation layer moved there (one small HTTP service over its own model
> registry — no SwarmUI, no ComfyUI graph). Read this skill for the pinned-down
> API facts, the model caveats and the trace-node pitfall, not as the live
> generation path.

This repo is the generation layer for the chopshop print pipeline. It answers
"where does a source raster come from, and where does the artwork go between
generations" — it does not trace candidates for print or gate them.

**The seam contract, and it is the thing most easily broken:** this layer
*calls* the pipeline; the pipeline never calls it. `front_pipeline.sh` and
`pipeline.sh` live in `chopshop-svg` and know nothing about SwarmUI. Keep it
that way — a workflow that the standard flow depends on is no longer opt-in.

It also never judges art. It produces sources and candidates; a human picks.

## Two pieces

1. **The bridge** — `scripts/swarm_bridge.py`, a CLI over SwarmUI's HTTP API
   (stdlib only, except `filter`, which needs Pillow for the source dimensions
   and the `data:` URL). Modes: `generate` (text→image), `filter` (source
   img2img → variants on disk; it never traces), `gen2pipe` (text→image→
   `front_pipeline.sh`). It imports `scripts/front_common.py`, a vendored
   2-function shim (`load_json` / `write_json`) — enough to import the bridge
   with no chopshop-svg checkout present. **Only `gen2pipe`** reaches the
   pipeline, and it resolves `front_pipeline.sh` from this repo's own root
   (`PROJECT = dirname(scripts/)`), not from the cwd: run it where this
   checkout carries the pipeline, or copy `scripts/` into such a checkout
   without overwriting chopshop-svg's full 12-function `front_common.py`.
2. **The workflow** — `swarm_workflows/`, a ComfyUI `trace → generate → trace`
   graph plus the `ChopShopTrace` node.

## SwarmUI API facts (verified against 0.9.8.3 — these are not guessable)

- `POST /API/GetNewSession` **requires** `Content-Type: application/json` and a
  `{}` body. A bare POST returns `error_id: basic_api` / "Wrong content type",
  which reads like an auth failure and is not.
- `POST /API/GenerateText2Image` takes a **flat** JSON body, NOT nested under
  `rawInput` (the published docs table says otherwise):
  `{session_id, images, prompt, model, width, height, ...}`.
  img2img is `initimage` (a `data:image/...;base64,` URL) plus
  `initimagecreativity` (decimal, default 0.6) — lowercase, no underscores.
- `POST /API/ListT2IParams` returns a `models` map keyed by category
  (`Stable-Diffusion`, `VAE`, `LoRA`, …), each a list. An empty list means no
  models — so "the API works" and "generation can run" are different claims.
- Generated images are addressed as `View/.../x.png`; download by GETting that
  path.

The HTTP layer is stubbed in `tests/test_swarm_bridge.py`, so the suite runs
with no server, no GPU and no models — keep it that way when adding calls.

## The `ChopShopTrace` node

`swarm_workflows/comfyui_chopshop/__init__.py` exposes one node that calls the
pipeline's exact VTracer (`vtracer.convert_image_to_svg_py`). The graph wires it
to the `poster` preset's values — `colormode=color`, `mode=spline`,
`color_precision=6`, with `layer_difference` left at VTracer's default of 16,
which is the preset's value — plus `hierarchical=stacked` and
`filter_speckle=4`. (`bw`'s `colormode=binary` stays selectable in the node, and
is exactly what the pitfall below is about.) No LLM ever generates or edits SVG
paths — that is a hard rule of the project, and an in-graph node is not an
exception to it.

- **in** `image`, `colormode`, `hierarchical`, `mode`, `filter_speckle`,
  `color_precision`, `filename_prefix`
- **out** `svg_filename` (STRING) — the **filename** of the SVG the node wrote
  into the ComfyUI output dir as `<filename_prefix>_NNNNN.svg`, not the SVG
  text. The node takes a batch (one file per input image), so a batch of more
  than one image returns a list of filenames.

### The pitfall that costs a hung queue

**Trace a generated image with `colormode=color`, never `binary`.** VTracer's
binary-mode colour clustering overflows (Rust `CapacityOverflow` panic in
`clusters.rs`) on noisy diffusion output — hundreds of thousands of unique
colours is normal for a generated raster. That panic is a `BaseException`, which
ComfyUI's worker does not catch, so the queue entry sits "running" forever with
no error surfaced. The node is hardened to catch it and fail cleanly, but the
hardening is a safety net, not the fix: `color` mode on the final trace.

## Workflow files and how they are regenerated

- `swarm_workflows/trace_generate_trace_flux2_klein.json` — the API-format
  graph posted to ComfyUI `/prompt`. **This is the source of truth.**
- `ChopShop Trace Generate Trace Flux2 Klein 4B.json` — the SwarmUI wrapper (UI
  graph + API graph + metadata), generated from the API graph against the live
  backend's `object_info`. Regenerate with `scripts/comfy_to_swarmui.py` rather
  than hand-editing; the wrapper is derived output.

**SwarmUI's `StrictFilenameClean` strips every `.`**, so an example filename
containing a period (`Flux.2`) breaks the read API. Use `Flux2`, never
`Flux.2`, in example filenames.

## FLUX.2 Klein 4B — the honest caveat

The distilled `flux-2-klein-4b` is **guidance-distilled**: it runs at CFG ~1.0,
so a **negative prompt has no effect at all**. That is the model, not a wiring
gap — do not "fix" it by wiring the negative input differently. If guidance
> 1.0 is genuinely required, switch to the non-distilled
`flux-2-klein-base-4b.safetensors` (same repo, same 7.75 GB), accepting that it
is slower and worse at image editing. Default: keep the distilled model and put
all steering into the positive prompt plus the source image.

## Model layout

Native ComfyUI split files (`Comfy-Org/vae-text-encorder-for-flux-klein-4b`):
`flux-2-klein-4b.safetensors` → `diffusion_models/` (7.75 GB),
`qwen_3_4b_fp4_flux2.safetensors` → `text_encoders/` (3.85 GB),
`flux2-vae.safetensors` → `vae/` (0.34 GB). SwarmUI rescans on a
`ChangeServerSettings` with a `paths.*` key, or on restart — if it does not see
freshly placed models, that is the fix, not a re-download.

The backend port **drifts +1 on every restart** (starts at 7820). Discover the
live port (`ss -ltnp | grep main.py`) rather than hard-coding it; the UI is on
7801.

## Research input

`docs/workflow-candidates.md` surveys 20 public ComfyUI/SwarmUI workflows by
integration cost. Two findings are load-bearing and already reflected above:
`ComfyUI-ToSVG` puts VTracer in-graph (same shape as this repo's node), and
VTracer's `--palette` / `--max-colors` are **standalone-CLI only** — the PyPI
wheel is API-only and exposes neither, so colour reduction stays with the
pipeline's snap step rather than a trace flag.
