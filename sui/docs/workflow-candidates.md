# ComfyUI / SwarmUI Workflow Candidates for chopshop-svg

Research date: 2026-09-24
Superseded context: the SwarmUI/ComfyUI integration layer these candidates were
scored against now lives in [chopshop-flux](../flux/README.md)
(a single HTTP service, no SwarmUI/ComfyUI). The survey is retained as research —
the upstream workflows and the VTracer findings below did not move.
Pipeline context: raster → VTracer → SVG → Inkscape proof/print → validate.
Existing integration points:
- `scripts/swarm_bridge.py` — SwarmUI REST: `generate` (txt2img), `filter` (img2img), `gen2pipe`.
- `swarm_workflows/` — ComfyUI `trace → generate → trace` (FLUX.2 Klein 4B) with a
  custom `ChopShopTrace` node (VTracer, same `convert_image_to_svg_py` as the pipeline).
- Style recipes (`flat-poster`, `mono-line`, `photo-halftone`) — served
  by `swarm_bridge.py`'s built-in `BUILTIN_STYLES`; the
  `scripts/swarm_styles.json` fork was retired 2026-10-12 (issue #2)
  and is now a deprecation stub pointing at chopshop-flux's
  `styles.py`, which owns the vocabulary.
- GPU: ROCm AMD 16 GB; FLUX.2 Klein 4B distilled (CFG ~1.0, no negative prompt effect).
- `scripts/SWARMUI_PLAN.md` item 5 already flags ControlNet as a future option.

The hard rule to respect in any integration: **the agent never judges the art, and
tracing is VTracer only (no LLM-generated SVG paths).** Workflows below feed the
tracer or steer generation upstream — they do not replace VTracer.

---

## Category 1 — Image-to-image / style transfer (feed traces)

### 1. FLUX_Img2Img Change Style
- URL: https://openart.ai/workflows/owl_glaring_95/flux_img2img-change-style/eJNNoeqyuTyIhtlVEMOM
- What it does: Load image → Florence2 auto-caption → Flux img2img restyle. One-click
  style swap on an existing raster, prompt-driven.
- Integration: Drop-in replacement for the `filter` mode's single img2img pass when a
  full style swap (not a creativity nudge) is wanted. Caption auto-fill removes manual
  prompt authoring. Output raster → `prep_raster.py` → trace sweep. Caveat: uses Flux
  Dev (not Klein); needs the Dev checkpoint + its VAE.

### 2. 100% Flux Native ControlNet + IPAdapter Style Transfer
- URL: https://openart.ai/workflows/odam_ai/100-flux-native-controlnet-ipadapter-style-transfer/u55OSJqYClitcKGAqQ8B
- What it does: Three-stage Flux-native pipeline — Canny/Depth/HED ControlNet for
  composition, IPAdapter for style, plus a low-weight img2img redraw for tone/lighting.
- Integration: This is the strongest "restyle but keep the silhouette" option — exactly
  what `filter` wants when the source's *shape* must survive a style change so the trace
  still reads. ControlNet strength ≥0.7 preserves edges the tracer depends on; keep
  IPA <0.5 to avoid noise. Composition-lock makes retrace fidelity predictable.

### 3. Flux to SDXL Style with IP Adapter
- URL: https://civitai.com/models/1291440/flux-to-sdxl-style-with-ip-adapter
- What it does: Generate with Flux (good prompt adherence) → pass to SDXL + IPAdapter +
  tile ControlNet to apply a reference style.
- Integration: Two-model cascade — Flux for clean concept, SDXL/IPA for the "print look."
  The tile ControlNet (`xinsir/controlnet-tile-sdxl-1.0`) preserves coarse color blocks,
  which helps VTracer's `poster` preset land on fewer, cleaner regions. v1.1 adds an
  IPAdapter Noise node for sharper style detail.

### 4. FLUX-Advanced-Img2Img (RF Inversion / Ref2Img)
- URL: https://openart.ai/workflows/nxssar/flux-advanced-img2img-workflow-for-reference-inversion-ref2img-rectified-flow-rf-inversion/PZKxqyjUj9ALsBKmaDzy
- What it does: Rectified-flow inversion gives controlled noise from the input image —
  prompt-driven style transfer, inpainting, even face swap, **without** ControlNet or
  manual masking.
- Integration: A no-extra-model route to "restyle the source, keep structure" using only
  Flux. Good when ControlNet models aren't downloaded yet (matches the plan's
  "models absent" reality). Use Hyper/Turbo LoRAs to cut 28×2 steps to 12×2. Higher
  control over *which* regions change than plain creativity — useful for localized
  cleanup before trace.

---

## Category 2 — Color quantization / segmentation / palette

### 5. ComfyUI-KJNodes (Kijai) — ColorMatch, ColorToMask, ImageQuantize
- URL: https://github.com/kijai/ComfyUI-KJNodes
- What it does: 200+ utility nodes; the relevant ones: `ColorMatch` / `ColorMatchV2`
  (match one image's color distribution to another), `ColorToMask` (RGB value → mask),
  and an `ImageQuantize` node for posterization. Widely depended-on (LTX, AnimateDiff).
- Integration: Pre-trace color conditioning. `ImageQuantize` can enforce the spec's
  `max_colors` budget *before* VTracer, so the tracer operates on already-banded pixels
  (cleaner region boundaries → fewer path artifacts). `ColorMatch` can snap a generated
  image to a customer's Pantone-style fixed palette — pair with VTracer's
  `--palette` / `--palette-file` (now in vtracer 0.6) for a fully palette-locked output.
  `ColorToMask` enables per-color-layer extraction for the print layer (.layer_a/.layer_b)
  workflow already in `05_final/`.

### 6. VTracer native palette / max-colors flags (standalone CLI only — NOT the pip wheel)
- URL: https://github.com/visioncortex/vtracer
- What it does: the **standalone Rust CLI** added `--palette`/`--palette-file` (snap to fixed hex palette,
  nearest in OKLab), `--max-colors` (auto-quantize to ≤N colors), and `--hierarchical
  cutout` (seam-free mosaic with shared boundaries).
- **Accuracy caveat (verified 2026-09-24):** these flags are **CLI-only**. This box runs the
  VTracer **pip wheel (0.6.15)**, which is API-only and exposes exactly:
  `colormode, hierarchical, mode, filter_speckle, color_precision, layer_difference,
  corner_threshold, length_threshold, max_iterations, splice_threshold, path_precision`.
  There is **no `palette` / `palette_file` / `max_colors` parameter in the API**, and no
  `vtracer` binary on PATH. So this is **not** a zero-friction "expose the flag" change —
  it requires installing the standalone CLI first (a deliberate environment decision).
- Integration (corrected): the *effect* of `--palette`/`--max-colors` is already available
  in-repo via **`scripts/snap_colors.py`** (pure-Python, snaps every fill/stroke to the spec
  palette). That is what actually produced the sub-20-colour candidates in this session —
  e.g. a `poster` trace of 677 colours snapped to 4 with `--force`. The `hierarchical
  cutout` mode *is* exposed by the API and already swept by `trace_sweep.py`. If the
  standalone CLI is adopted later, its palette/max-colors flags would supersede
  `snap_colors.py`; until then, use `snap_colors.py`.


---

## Category 3 — Raster-to-vector / tracing (ComfyUI-native)

### 7. Yanick112/ComfyUI-ToSVG (VTracer in-graph)
- URL: https://github.com/Yanick112/ComfyUI-ToSVG
- What it does: ComfyUI custom node exposing VTracer: `ConvertRasterToVector` (full
  VTracer params: filter_speckle, color_precision, layer_difference, corner_threshold,
  splice_threshold, path_precision), `SaveSVG`, plus `ImageQuantize`,
  `VectorToRaster` (SVG→image preview), BW Potracer & VTracer variants.
- Integration: **Already in the repo's dependency tree** — the `ChopShopTrace` node in
  `swarm_workflows/comfyui_chopshop/` calls the same `vtracer.convert_image_to_svg_py`.
  Adopting Yanick112's node directly would give `VectorToRaster` (in-graph SVG→PNG
  fidelity preview) and `ImageQuantize` for free, replacing the bespoke trace node with
  a maintained upstream one. Parameter names match the pipeline's sweep, so a spec→node
  mapping is mechanical.

### 8. ImagineerNL/ComfyUI-ToSVG-Potracer (Potrace for 2-color work)
- URL: https://github.com/ImagineerNL/ComfyUI-ToSVG-Potracer
- What it does: Potrace-based node for 2-color (B/W) vectorization — fewer vector points,
  near-zero cleanup, ideal for logos/text/silhouettes/vinyl-cut. Requires Yanick112's
  `SaveSVG`/`VectorToRaster`. Params: threshold, turnpolicy, turdsize, corner_threshold,
  zero_sharp_corners, opttolerance, foreground/background/stroke color, output_scale.
- Integration: A complementary tracer for the `mono-line` / 1-color spec. VTracer (current)
  wins on multicolor; Potrace wins on single-color stencil/logo where point count and
  smoothness matter for print. Could add a `tracer: potrace` option to the spec and a
  second trace path in `trace_sweep.py`. The `zero_sharp_corners` flag is notably useful
  for vinyl/screen-print where sharp internal corners tear.

### 9. Flux.2 Klein Raster-to-Vector (sarcastictofu) — img2img + VTracer + prompt saver
- URL: https://civitai.com/models/2489329/comfyui-all-in-one-fast-flux2-klein-raster-to-vector-image-to-image-with-prompt-saver-workflow
- Alt: https://civarchive.com/models/2489329 (mirror)
- What it does: Same model family as the repo (Flux.2 Klein 4B/9B) + a LoRA trained on
  250 illustration/vector artworks to push Klein toward flat digital art (not its
  photographic bias), then VTracer to SVG on the fly. Includes a Prompt Saver subgraph
  writing human-readable metadata .txt alongside each .jpeg/.svg.
- Integration: The LoRA is the valuable piece — it steers Klein toward traceable flat art,
  which is the core problem with feeding photoreal gens into VTracer. The prompt-saver
  pattern maps onto the pipeline's run-record/manifest needs (`scripts/run_record.py`,
  `05_final/*.manifest.json`). Since the repo already runs Klein 4B, the LoRA is a
  drop-in model addition; the in-graph VTracer step duplicates the existing ChopShopTrace
  node but the LoRA + style guidance is net-new value.

### 10. Txt2Img→SVG Potracer example workflow (ImagineerNL, on OpenArt)
- URL: https://openart.ai/workflows/awkward_monster00/txt2img-to-svg-potracer-vector-conversion-example-workflow/bnoXqmR1qQFtBAOCYqod
- What it does: Evolved from Stonelax's "Flux Text to Vector" workflow; uses Flux Dev +
  vector-style LoRAs (`v3ct0r`, `Simple_Vectors_Flux`, `v3ctora`) + contrast node →
  Potrace SVG. Documents the exact settings (Euler-Simple, 25–30 steps, distilled CFG 3.5,
  contrast 1.5–2) and which LoRAs/triggers to use.
- Integration: A reference recipe for the *prompt + LoRA + contrast* layer that makes a
  generated image trace cleanly. The contrast 1.5–2 pre-trace trick is directly portable
  into `prep_raster.py`. The LoRA trigger words (`v3ct0r`, `v3ctora style`) become
  `swarm_styles.json` prompt-suffix entries for a new `vector-flat` style.

---

## Category 4 — Design generation (T-shirt / graphic / logo)

### 11. MAGIFACTORY t-shirt diffusion (checkpoint)
- URL: https://comfy.icu/models/4694/-MAGIFACTORY-t-shirt-diffusion
- File: https://comfy.icu/files/MAGIFACTORYTShirt_magifactoryTShirtModel.safetensors
- What it does: SD1.5 checkpoint trained on 512×512 t-shirt logos; prompt format
  `"<subject> (on a black background:1.4) as a t-shirt logo in the style of <MAGIFACTORY> art"`.
  Suggests hires-fix to 896² + 4× SwinIR upscale, Euler-a.
- Integration: A purpose-built T-shirt-logo generator — directly on-theme for
  `gen2pipe` ideation. 512² native is small, so chain its output through the pipeline's
  upscale/prep before trace. SD1.5 era, so quality ceiling is lower than FLUX.2 Klein, but
  it's a fast, cheap "first draft" generator and the prompt grammar (black background,
  logo framing) is a ready-made `swarm_styles.json` template.

### 12. AI Tattoo Generator workflow pack (comfy.org) — line art + stencil
- URL: https://comfy.org/workflows/use-cases/ai-tattoo-generator
- What it does: 8-workflow pack: txt2img (Flux.2 Dev / Z-Image-Turbo) for concepts →
  line-art workflow to convert photo/sketch to crisp black outlines → Qwen-Image Union
  Control workflow to restyle while locking composition. Explicitly built around
  "generate base → redraw → clean line art for stencil."
- Integration: The closest public match to chopshop-svg's own philosophy (generate →
  clean → trace). The line-art extraction step is a candidate pre-trace conditioner:
  feeding VTracer a clean B/W line image (instead of a full-color raster) yields far
  fewer, cleaner paths. The Qwen-Image Union Control restyle maps onto the `filter`
  loop's "keep composition, change style" goal. Worth mining for reusable subgraphs.

### 13. Logo Design "Pro" workflow (HiDream + Qwen-Image-Edit)
- URL: https://youtube.com/watch?v=ObWhRfDCr9g (workflow embedded in video description)
- What it does: Two-stage — HiDream txt2img → image-chooser → Qwen-Image-Edit for
  refinement + background removal, in one graph with an intermediate human pick step.
- Integration: The **image-chooser / intermediate pick** pattern is the human-in-the-loop
  gate the plan (`SWARMUI_PLAN.md` item 2) wants for the `filter --iterate` loop. The
  background-removal step aligns with print readiness (transparent bg, no box around
  art). Qwen-Image-Edit is a different model family than Klein but shows the "edit mode"
  pattern Klein 4B also supports (the README notes Klein packs classical + edit modes).

---

## Category 5 — ControlNet (line art / canny / structure)

### 14. ComfyUI official FLUX ControlNet examples (canny, depth, union)
- URL: https://github.com/comfyanonymous/ComfyUI_examples/tree/master/flux
- Guide: https://docs.comfy.org/tutorials/flux/flux-1-controlnet
- What it does: Canonical, maintained example graphs for FLUX.1-Canny-dev,
  FLUX.1-Depth-dev (LoRA), and community Union ControlNets (InstantX, Shakker, XLab).
  Drag-and-drop PNGs carry the workflow.
- Integration: The baseline ControlNet integration the plan item 5 references. Canny
  ControlNet fed the *source raster's edges* would hold composition fixed during a
  style transfer — a stronger "filter" than `initimagecreativity`. Needs a ControlNet
  model download (currently absent per plan). The depth LoRA is lighter-weight (LoRA,
  not a separate model). Start here for the "optional, later" ControlNet milestone.

### 15. xinsir/controlnet-union-sdxl-1.0 (12-control "ProMax")
- URL: https://huggingface.co/xinsir/controlnet-union-sdxl-1.0
- What it does: One SDXL ControlNet covering 12 conditions — openpose, depth, canny,
  lineart, anime lineart, mlsd, scribble, hed, pidi, teed, segment, normal — plus 5
  editing modes (tile deblur/variation/super-res, inpaint, outpaint).
- Integration: A single model that covers *all* the line-art/edge/segment conditions the
  pipeline cares about. `lineart`/`anime lineart`/`canny` conditions can pre-condition
  generation toward traceable art; the `segment` condition pairs with Category 2 color
  segmentation. Since it's SDXL (the bridge's current default via SDXL base), no new
  base checkpoint needed — just the 1B ControlNet. Tile mode preserves color blocks
  during restyle.

### 16. xinsir/controlnet-scribble-sdxl-1.0 (anyline)
- URL: https://huggingface.co/xinsir/controlnet-scribble-sdxl-1.0
- What it does: A single ControlNet that accepts *any* line type and width (scribble,
  canny, HED, PIDI, lineart) and still produces strong, midjourney-comparable structure
  control.
- Integration: The most forgiving edge-condition model — feed it the source's canny
  edges *or* the VTracer output re-rasterized as line art, and it locks the silhouette
  through a restyle. Useful for the "trace → generate → trace" loop's generate step:
  use the first trace (as line art) as the ControlNet input so the regeneration stays
  faithful to the already-traced shapes.

### 17. Z-Image-Turbo-Fun-Controlnet-Union-2.1
- URL: https://modelscope.cn/models/PAI/Z-Image-Turbo-Fun-Controlnet-Union-2.1
- What it does: ControlNet for Z-Image-Turbo (the fast model SwarmUI presets feature),
  8-step distilled, supports canny/depth/pose/mlsd/hed/scribble/gray + inpainting.
- Integration: If the pipeline adopts Z-Image-Turbo for speed (SwarmUI presets ship it),
  this is the matching ControlNet — 8 steps keeps the generation stage cheap enough to
  run many style candidates. The `gray` control (v2602) is interesting: a grayscale
  luminance map can hold tonal structure through a recolor, useful for the
  `photo-halftone` style.

### 18. Image-to-Line-Art workflow (ControlAltAI) — full line-art extraction pipeline
- URL: https://youtube.com/watch?v=XodTkkpdSyo (workflow JSON in description)
- What it does: Converts any image to line art using ControlNet LoRA + IPAdapter + BLIP
  captioning, with batch processing, background removal, upscaling, and post-processing
  (color removal, grayscale removal, line thickness, edge enhancement).
- Integration: A complete "raster → clean B/W line art" subgraph that could sit between
  generation and VTracer. Feeding VTracer clean line art (vs. full-color photo) is the
  single biggest lever for path-count reduction and trace fidelity. The batch +
  line-thickness controls map onto a `mono-line` style spec. The color/grayscale removal
  post-processing is a pre-trace conditioner that complements Category 2 quantization.

---

## SwarmUI-specific resources (not workflows, but integration surfaces)

### 19. SwarmUI repo + Comfy Workflows wiki
- URL: https://github.com/mcmonkeyprojects/SwarmUI
- Wiki: https://github.com/mcmonkeyprojects/SwarmUI/wiki/Features.Comfy-Workflows
- What it does: SwarmUI hosts Comfy workflows as examples, exposes `SwarmInput` nodes for
  custom parameters, and supports Grid generation across workflow variants.
- Integration: The repo already ships a SwarmUI example
  (`ChopShop Trace Generate Trace Flux2 Klein 4B`). The `SwarmInput` custom-parameter
  pattern lets the VPS Rails GUI drive trace params (filter_speckle, color_precision)
  directly from the SwarmUI Generate tab. Grid generation could sweep trace presets
  across generated variants in one run — a natural fit for the candidate-sweep model.

### 20. FurkanGozukara: SwarmUI presets → ComfyUI migration (Z-Image-Turbo + ControlNet Union, Wan 2.2)
- URL: https://github.com/FurkanGozukara/Stable-Diffusion/discussions/354
- What it does: Tutorial + exportable JSON presets for SwarmUI's 40+ presets (SDXL,
  FLUX, Z-Image-Turbo, FLUX 2, Qwen Image/Edit, FLUX Kontext), with `extra_model_paths.yaml`
  to unify SwarmUI/ComfyUI model folders.
- Integration: The `extra_model_paths.yaml` unification is directly useful — the repo
  already keeps its SwarmUI models in a single tree; sharing that tree with a
  standalone ComfyUI avoids duplicating the 7.75 GB Klein weights. The Z-Image-Turbo +
  ControlNet Union preset pairs with candidate #17 for a fast, structure-locked generation
  path.

---

## Quick-pick recommendations (highest leverage, lowest friction)

| # | Candidate | Why it's first | Friction |
|---|-----------|----------------|----------|
| 7 | Yanick112 ComfyUI-ToSVG | Already the tracer the repo uses; adds VectorToRaster preview + ImageQuantize | Near-zero — swap bespoke node for upstream |
| 6 | `snap_colors.py` palette snapping | Already in-repo, pure Python; produced 4-colour output from a 677-colour trace | Zero — already works (the `--palette` CLI flags are NOT in the pip wheel) |
| 14 | ComfyUI FLUX ControlNet examples | Canonical, matches the plan's "optional ControlNet" milestone | One model download |
| 9 | sarcastictofu Klein R→V LoRA | Same model (Klein 4B); LoRA fixes the "photoreal bias" that hurts tracing | One LoRA download |
| 15 | xinsir controlnet-union-sdxl-1.0 | One model, 12 conditions incl. lineart/canny/segment; SDXL already present | One model download |
