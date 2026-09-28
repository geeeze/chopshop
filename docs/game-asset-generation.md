# Chopshop → indie game assets: a research report on semi-automated composite generation

Date: 2026-09-28 · Status: research / proposal (nothing built)

Scope: how to integrate chopshop-studio and its sibling repos into a
semi-automated process that composites 2D and simple 3D assets (Blender-class)
for indie game development — vectors, sprites, animation frames, pre-rendering,
procedural modification, and runtime generation — from multiple source materials
and influences.

Constraint that shapes everything: the target game is a **2D point-and-click
adventure, dialogue/UI-heavy, static art**, built in **C + SDL3 at the
`SDL_Renderer` tier, no shaders**. So the asset surface is: 2D sprites and
sprite sheets, pre-rendered animation frames, simple extruded/relief 3D that is
pre-rendered to 2D (or baked to sprite), and procedural modification at build
time and at runtime. Not AAA rigs, not real-time PBR scenes.

---

## 1. The answer in one paragraph

Chopshop is already, in miniature, a *code-first procedural asset system*: a
raster in, candidate vectors out, with a geometry-spec renderer, a generation
layer, a decision sidecar, a composition surface, a collection store, and a
learned-ranker that orders candidates from recorded human picks. The missing
piece for game assets is a **Blender-class backend** and a **raster-output
path for animation**, plus the framing to run the whole thing as an
agent-driven loop. CraftBot (the closest prior art) proves the loop: constrain
an LLM to write *executable geometry code*, run it headless, screenshot, and
let a human (or a vision model) reject and revise. Chopshop already has the
"never picks a winner, human chooses" discipline that loop needs; it is missing
the 3D lift and the animation/pre-render stage. Both are small, well-understood
additions.

---

## 2. What chopshop already does, mapped to game-asset needs

Grounded in the current code (verified this session), repo by repo:

| Repo | Capability today | Game-asset role |
|---|---|---|
| **chopshop-svg** | raster → VTracer candidate SVGs → print gates (Layer A source + Layer B render) → proof manifest. Never picks a winner. | **Vectorisation**: photo/sketch/AI image → clean layered vector; the "keep vectors as vectors" rule maps directly to resolution-independent sprite geometry. |
| **chopshop-flux** | text2image + img2img (FLUX.2 klein / SDXL / SD 1.5), 6 HTTP routes, batch (`images: N`) → multiple rasters. | **Source synthesis**: concept art, background plates, tiled texture sources, a "variation set" per prompt (already batch-native). |
| **chopshop-plot** | stdlib SVG engine: `generate` (shapes/tiling geometry spec), `digest`/`query` (charts), `tree`/`log` (hierarchy/timeline), fractals; an **animation demo** that renders fixed-axis SVG frames → Inkscape rasterise → ffmpeg. | **Procedural geometry + animation**: the `generate` op IS a code-first geometry spec; the animation demo IS a pre-render frame pipeline. |
| **chopshop-jev** | advisory 4-question typed sidecar (TypeSafe System One), never decisive. | **QC on a generated asset** (does this sprite read? is it off-model?) without trusting a prose LLM. |
| **chopshop-sui** | SwarmUI/ComfyUI bridge (generation). | Alternate generation front-end (ComfyUI node graphs = more controllable procedural gen). |
| **chopshop-studio** | Rails GUI, runner contract, **scrapbook** (collection), **composites** (composition), **event log** + **learned ranker/bandit** (human-pick-driven ordering). | The **semi-automated driver**: scrapbook = asset library, composites = layering, the event log + ranker = the "show 12 candidates, learn which the human keeps" loop that makes batch generation sortable. |

The one rule that threads every repo — **the pipeline never picks a winner; a
human chooses** — is precisely the right discipline for asset generation. An
LLM that "picks the best sprite" will do it confidently and wrong; the
chopshop pattern is "produce a labelled, measurable candidate set and let the
human (or a vision model with a rubric) choose, then record the choice so the
next batch ranks better."

---

## 3. Prior art and tools (each claim sourced)

### 3.1 CraftBot — the code-first Blender agent (the template to copy)

CraftBot (github.com/lukapiskorec/craftbot) is an architect agent that, instead
of producing meshes or images, **writes Python that constructs geometry in
Blender**, then loops code-generation → execution → visual feedback → revision.
Key mechanics that transfer directly:

- **Code is the medium.** All reasoning manifests as an executable script; a
  headless runner frames the geometry with an orthographic camera and renders
  four orbit views with the Workbench engine
  (`blender --background --python tools/run_experiment_headless.py`).
- **Knowledge lives in skills, not in the prompt.** Distilled per-domain
  skills (`procedural-geometry`, `structural-logic`, `verifying-models`, …)
  so there is one copy of every rule.
- **A small agent team with hand-off files on disk** (Designer/Builder/
  Inspector/Runner), so any agent can be restarted from disk.
- **Verification is structural.** `check_overlaps.py` (SAT interpenetration),
  `check_contacts.py` (members touching nothing), and the Inspector agent
  (looks at renders against requirements) — because *"CraftBot remains largely
  incapable of autonomously detecting its own geometric errors, requiring
  human guidance."* (aalto.fi project page).

The direct mapping: **chopshop-plot's `generate` operation is already a
code-first geometry spec**; a Blender backend for it (JSON spec → Blender
`bpy` mesh) would be CraftBot minus the LLM-in-the-loop — and the LLM loop can
be added by letting an agent write `generate` specs the way CraftBot writes
`.py` scripts.

### 3.2 SVG → 3D: extrusion is a solved, scriptable path

Blender imports SVG as curves (path geometry only — gradients/fills/strokes/
text are ignored), then the standard lift is: set curve `Extrude`/`Bevel` in
the Geometry panel, optionally convert to mesh, remesh for clean topology
(docs.blender.org SVG import; alpha3d.io / vagon.io workflows). Practical
notes that matter for automation:

- SVG imports **tiny** and in the XY plane — scale up and set origin to
  geometry in the same script.
- **Curve cleanliness is the failure point**: loose segments, overlapping
  paths, near-duplicate vertices, and sharp angles break bevel/extrude. This is
  exactly the class of defect chopshop's print gates and `svg-geometry-
  invariants` already detect (Z/M preservation, closure detection) — so
  chopshop-svg's validation can gate a vector *before* it becomes a broken 3D
  extrude.
- Extrude + bevel while still a **curve** is fine for simple shapes; convert to
  mesh + remesh (Sharp, Octree) for animation-friendly quads.

This means the whole "2D sprite → simple 3D token/logo/prop" path is: VTracer
(or chopshop-plot generate) → clean vector → headless `bpy` extrude → render
orthographic frames back to sprite. No new model needed.

### 3.3 Image → 3D: for props and set pieces, feed-forward models are usable now

Single-image-to-3D has real open-weight options (sources: TripoSR arXiv
2403.02151; TRELLIS/TRELLIS.2 Microsoft; MoGe arXiv 2410.19115; UniK3D CVPR
2025; Depth Anything family):

- **TripoSR** — feed-forward triplane-NeRF → mesh, ~6 GB VRAM, <0.5 s on an
  A100, **plain MIT**, vertex colours (no PBR). The "runs anywhere, fast,
  unencumbered" baseline.
- **TRELLIS (original)** — SLAT latent → mesh **or** 3D Gaussians **or**
  radiance field, text + image input, MIT, ~16 GB.
- **TRELLIS.2-4B** — O-Voxel, native PBR (base colour/roughness/metallic/
  opacity) GLB out, MIT, **24 GB** minimum; 3 s @ 512³, 60 s @ 1536³ on H100.
- **MoGe / UniK3D / Depth Anything** — monocular **depth/point-map** estimation
  rather than full mesh; depth is the cheap "2.5D relief" route (a depth map →
  displacement → relief token) that needs far less GPU than a generative mesh.

Critical caveats for indie use (from the 2026 comparisons): **none of these
emit shippable topology** — all produce dense extraction-driven triangle soup
that needs retopology before a rig or subdivision; **single-view models produce
thin relief shells with blank/hallucinated backs** (TripoSR judged "unusable as
the ship" in one benchmark for that exact reason). Licences vary sharply
(Hunyuan3D 2 has a community licence with carve-outs; Stable Fast 3D is
Stability Community <$1M revenue; TripoSR/TRELLIS are MIT). For a
point-and-click with static art, the sane use is: image-to-3D for a *reference
prop*, re-traced/re-extruded through the clean vector path for the shipped
asset.

### 3.4 SDL3 — the runtime target is already well-served

SDL3's `SDL_Renderer` gives `SDL_CreateTexture` (static) and streaming textures
for runtime pixel updates; sprites are "a texture drawn many times"
(examples.libsdl.org/renderer/06-textures). For a no-shaders `SDL_Renderer`
game:

- **Pre-render everything to PNG sprite sheets** and load once; the runtime
  does `SDL_RenderTexture` with a source rect per cell. This is the standard
  atlas approach (any packer: Cram, TexturePacker, or a small in-house one).
- **Runtime procedural modification** at the `SDL_Renderer` tier means either
  a streaming texture (lock → draw → unlock per frame, per
  examples.libsdl.org/renderer/07-streaming-textures) or CPU-side pixel work on
  an `SDL_Surface` before upload. Simple palette swaps, tinting, and procedural
  patterns are CPU-cheap; nothing here needs shaders.
- (Batching/instancing via SDL3's GPU API exists — moonside.games,
  glusoft.com — but that is the shader tier, out of scope for "no shaders
  needed".)

The chopshop-relevant insight: **chopshop-plot already knows how to emit SVG
and rasterise it deterministically** (the animation demo). The same
SVG→PNG-at-fixed-frames path is the pre-render stage for sprite sheets and
frame animation, and chopshop-plot's `digest`/`query` can visualise the asset
run itself.

---

## 4. Proposed architecture

A single loop, agent-driven, with the human (or a rubric-carrying vision
model) as the only chooser. Stages are additive to what exists; none changes
the "never picks a winner" rule.

```
influences / source materials
   (photos, sketches, flux prompts, palette refs, a style sheet)
        │
   ┌────▼──────────────────────────────────────────────┐
   │ 1. SOURCE (flux / sui)          text2image, img2img,│
   │    batch N variations per prompt                    │
   └────────────────────┬────────────────────────────────┘
                        │
   ┌────────────────────▼──────────────────────────────┐
   │ 2. VECTORISE (svg)   VTracer sweep → candidate SVGs,│
   │    gated + fidelity-measured (already built)        │
   └────────────────────┬────────────────────────────────┘
                        │
   ┌────────────────────▼──────────────────────────────┐
   │ 3. PROCEDURAL (plot `generate`)  geometry spec →    │
   │    SVG (shapes, tiling, fractals) — the code-first  │
   │    geometry source, no raster input needed          │
   └────────────────────┬────────────────────────────────┘
                        │
   ┌────────────────────▼──────────────────────────────┐
   │ 4. COMPOSE (studio composites, VECTOR-preserving)  │
   │    layered merge: vector layers stay vectors, only  │
   │    fresh raster (flux output/upload) is re-traced   │
   └────────────────────┬────────────────────────────────┘
                        │
   ┌────────────────────▼──────────────────────────────┐
   │ 5. LIFT (new: Blender bpy backend for plot)        │
   │    spec → bpy: extrude/bevel curves, orthographic   │
   │    camera, Workbench render → PNG frames            │
   └────────────────────┬────────────────────────────────┘
                        │
   ┌────────────────────▼──────────────────────────────┐
   │ 6. PRE-RENDER / ANIMATE (plot animation path)      │
   │    fixed-axis SVG frames → Inkscape → ffmpeg →      │
   │    sprite sheet + GIF/WebM preview (already demoed) │
   └────────────────────┬────────────────────────────────┘
                        │
   ┌────────────────────▼──────────────────────────────┐
   │ 7. COLLECT + RANK (scrapbook + event log + ranker) │
   │    candidate set → human picks → record → next batch│
   │    ranks better (P1-P5 already shipped)            │
   └────────────────────┬────────────────────────────────┘
                        │
   ┌────────────────────▼──────────────────────────────┐
   │ 8. RUNTIME (SDL3)   packed PNG atlas; procedural   │
   │    mods = CPU surface work or streaming texture    │
   └────────────────────────────────────────────────────┘
```

The semi-automation is the **loop**, not any single step: stages 1→6 produce a
labelled candidate set, stage 7 is the human gate that also *feeds the ranker*,
and stage 8 consumes the survivors. An agent drives 1→6 by writing specs
(flux prompts, VTracer sweep files, `generate` geometry specs, `bpy` scripts)
and reading results; it never advances a candidate to "final" on its own.

### Where the "multiple influences" land

- **Vectors** → stage 2 (trace) and stage 3 (procedural).
- **Sprites** → stage 6 output (atlas + per-frame PNGs).
- **Animation frames** → stage 6 (the existing SVG-frames → ffmpeg path,
  extended to emit a packed atlas + a frame manifest JSON).
- **Pre-rendering** → stages 5–6 (orthographic Blender / Inkscape render).
- **Procedural modification** → stage 3 (a new `generate` spec) and stage 8
  (runtime palette swap / tint on the CPU).
- **Gen at runtime** → stage 8 (streaming texture; procedural pattern drawing),
  constrained to what `SDL_Renderer` + CPU pixels can do.

---

## 5. What to build, prioritised

1. **P0 — a Blender `bpy` backend for chopshop-plot.** The contract already
   names richer backends ("Makie/ggplot2"); a `generate` spec that emits Blender
   geometry (curves → extrude/bevel → orthographic Workbench render to PNG) is
   the same pattern. stdlib-free in the plot package itself (bpy only runs
   inside Blender, so the backend is invoked as
   `blender --background --python …` with the spec on stdin/file), keeping the
   "no third-party import" rule intact. This is the entire "simple 3D" ask.
2. **P0 — an asset-run surface in the studio.** A "composite generation" page/
   recipe: name the influences (flux prompt + palette + trace preset + geometry
   spec), run stages 1→6, land the results in the scrapbook as an asset set,
   and record the run so the ranker can order the next batch. This is the
   "semi-automated" part made concrete; it reuses the existing runner contract,
   scrapbook, composites, and event log.
3. **P1 — sprite-sheet + frame-manifest output** in chopshop-plot: extend the
   animation demo into a real `sheet` operation (packed atlas PNG + JSON of
   cell rects, plus a per-frame manifest), so stage 6 emits game-ready
   artifacts, not just a demo GIF.
4. **P1 — vector-preserving composite** (already direction-confirmed, unbuilt):
   traced SVG stays vectors through compositing; flatten = SVG merge for
   vectors, trace only fresh raster. This is the correctness precondition for
   resolution-independent sprites out of stage 4.
5. **P2 — optional image-to-3D reference path** (TripoSR for a prop reference,
   MIT, low VRAM), re-traced/extruded through the clean vector path for the
   shipped asset — explicitly a *reference*, never the final topology.
6. **P2 — runtime-asset format** documented: a tiny JSON manifest (atlas + cells
   + palettes + animation clip table) the SDL3 loader reads, so the game and the
   generator share one contract.

---

## 6. Risks and constraints (do not ignore)

- **Never-picks-a-winner stays.** The ranker/bandit order candidates; a human
  (or a rubric-carrying vision model) picks. Nothing auto-advances.
- **Topology is never shippable out of a generative 3D model.** Single-view
  image-to-3D gives relief shells with blank backs; dense extraction soup needs
  retopology. Keep the vector-extrude path as the shipped route and treat
  image-to-3D as a reference only.
- **Licences differ per model** and per *your* revenue. TripoSR/TRELLIS are MIT;
  Hunyuan3D 2 has carve-outs; Stable Fast 3D is <$1M revenue; sdxl-turbo is
  non-commercial (chopshop-flux already gates it). A "commercial indie" tag on
  every asset run must record the source model's licence, the same way
  chopshop-flux already records `commercial_ok`.
- **`SDL_Renderer`, no shaders** means runtime generation is CPU-pixel work and
  palette/tint swaps — not shader-driven effects. Pre-render anything fancy.
- **Blender automation is headless-brittle** (add-on enable, tiny import scale,
  curve cleanup, dbus/X in containers) — CraftBot's `run_experiment_headless.py`
  and chopshop-svg's `DBUS_SESSION_BUS_ADDRESS=disabled:` lesson are the
  template to copy.
- **Determinism + provenance.** Every stage already stamps version + sha256;
  the asset run must record the full spec → hash chain so a sprite is
  reconstructable (chopshop's existing checksum-sidecar convention).

---

## 7. Sources

- CraftBot — github.com/lukapiskorec/craftbot (README: code-first Blender
  geometry, six-agent team, headless runner, check_overlaps/check_contacts);
  aalto.fi project page ("largely incapable of autonomously detecting its own
  geometric errors").
- SVG→3D — docs.blender.org/manual/latest/files/import_export/svg_curve.html
  (path-only import, XY plane); vagon.io / alpha3d.io SVG-extrude/bevel/remesh
  workflows; blender.stackexchange.com/questions/47217 (curve-cleanup failure
  modes).
- Image→3D — TripoSR (arXiv 2403.02151, MIT, ~6 GB); TRELLIS / TRELLIS.2
  (Microsoft, O-Voxel, PBR GLB, MIT, 24 GB); MoGe (arXiv 2410.19115);
  UniK3D (CVPR 2025); Depth Anything family (monocular depth); 2026 comparisons
  (builderai.tools, triposr.org, dreamers-laboratory/image-to-3d-pipeline).
- SDL3 — wiki.libsdl.org/SDL3/SDL_CreateTexture; examples.libsdl.org renderer
  06-textures / 07-streaming-textures; moonside.games + glusoft.com (atlas +
  batching; the GPU tier is noted as out of scope for no-shaders).
- chopshop — capability map grounded in the current repos (this session):
  svg trace/gate, flux batch generation, plot generate/animation, studio
  scrapbook/composites/event-log/ranker/bandit.
