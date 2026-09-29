# Models — what to expect, what fits, and how to get the best out of them

`README.md` carries the registry itself: keys, licences, resolution rules, steps
and guidance. **This file carries the judgement the registry cannot** — what
quality to expect from each entry, which one to reach for, how to drive it well,
and what a model has to be able to do before we register it at all.

Two rules that keep this honest:

- **MEASURED means run on this box, on the real card.** Everything else is marked
  ESTIMATE. A vendor's headline VRAM is an ESTIMATE by definition — it is quoted
  for *someone else's* loading mode.
- **A claim about behaviour is measured, never quoted from a model card.** If a
  sentence says a knob does something, it was tested by generating twice and
  comparing the frames.

## 1. The footprint rule on this box

The number that decides whether a model can run here is **not** the vendor's
"fits in 16 GB". It is:

> **the largest SINGLE module, resident, under `offload=cpu`.**

Our operating mode is `CHOPSHOP_FLUX_OFFLOAD=cpu` (`offload=none` does not fit —
MEASURED: klein-4b at 512×512/4 steps completes all four denoise steps with
15.01 GiB allocated and then dies in the VAE decode with 174 MiB free). Under
model offload, accelerate moves **whole modules** — the transformer, then the text
encoder, then the VAE — so what has to fit in 17.10 GB is the biggest of those,
plus activations, not the sum. A 24 GB model can therefore run here while a
17.8 GB *module* cannot.

Three consequences worth internalising:

1. **Read the module sizes, not the repo size.** `from_pretrained` pulls every
   precision a repo published, and our `repo_bytes` figure is the download.
2. **`torch_dtype` decides the module's footprint.** Several repos store fp32
   weights (a 6B transformer at ~25 GB of files); loading with
   `torch_dtype=torch.bfloat16` halves the resident module. The download is still
   the fp32 figure — size the disk, not the VRAM, from it.
3. **System RAM is part of the footprint.** Offload keeps the rest of the model in
   host memory, and this box has killed the service before (see `CONTEXT.md`:
   a 77.3 GiB peak on a 91 GiB box with no swap). A model whose offloaded modules
   plus the client's own buffers approach host RAM is not "fits", it is a future
   OOM kill.

**Measure it before registering anything** — the module list, not the total:

```python
# on the box with the GPU, in the service's interpreter
from diffusers import DiffusionPipeline
import torch, json
cfg = json.load(open("<snapshot>/model_index.json"))   # what classes exist
# then, per component, the file sizes from the HF API (see the recipe below)
```

The HF-API enumeration is the registry's own step 1 and it answers the licensing
and gating questions at the same time:

```bash
curl -s "https://huggingface.co/api/models/<repo_id>?blobs=true" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); \
      print(d["cardData"].get("license"), d["gated"]); \
      [print(s["rfilename"], round((s.get("size") or 0)/1e9, 2), "GB") \
       for s in sorted(d["siblings"], key=lambda s: -(s.get("size") or 0))[:12]]'
```

## 2. Expected quality — per entry

The axis that matters *here* is not "is it beautiful". It is **"does it produce
something the trace stage can turn into a good screen print"**: flat colour,
legible shapes, edges that survive vectorisation, few inks. Photorealism is
mostly a liability for this pipeline.

| key | prompt adherence | flat-art / printability | style range (LoRA) | text in image | speed under offload |
|---|---|---|---|---|---|
| `klein-4b` (default) | **strong**, including multi-subject and spatial relations | **good** — flat graphic styles come out clean when asked for | thin (new family) | fair — short words only | **best** (4 steps) |
| `klein-4b-base` | strongest of the klein pair | good | thin | fair | slow — 28 steps, every step paid for (MEASURED 58.8 s/frame at 1024) |
| `sdxl-1.0` | fair; needs a negative prompt and care | good, and the most predictable | **deepest** — style LoRAs, ControlNets, community checkpoints | poor — garbles past a word | moderate (30 steps) |
| `sdxl-turbo` | fair | good | inherits SDXL's LoRAs only partly | poor | fast (2 steps), non-commercial |
| `sd-1.5` | weak — short prompts only | good for graphic/line work | large but dated | very poor | fast (small model) |
| `ssd-1b` | fair-to-good; MEASURED as the fastest 1024 px entry (6.1 s first call, 4.4 s after) | good | limited | poor | **best at 1024 px** |
| `sana-sprint-0.6b` | fair; unpredictable on complex scenes | fair | very thin | poor | **fastest warm** (MEASURED 2.5 s warm, 39.7 s first call) |
| `sana-sprint-1.6b` | fair; ESTIMATE — not run on this card | fair | very thin | poor | ESTIMATE, between the 0.6B and SDXL |
| `z-image-turbo` | **not assessed in this pass** — ESTIMATE; the vendor claims strong instruction adherence and **no frame was judged here** (never judge the art) | ESTIMATE — a 6B general-purpose model, not tested against the print criteria | thin — no adapters registered for this family | vendor claims accurate bilingual (EN/CN) rendering; **NOT measured here** | **MEASURED** — 1024 px at 9 steps: 41.3 s on the first call after a load, 17.0 s after (load itself 55.8 s) |

### What each family is actually good at

- **FLUX.2 [klein]** — the default for a reason. Prompt adherence is the best
  here, multi-reference editing is built in, and the distilled 4B is the only
  entry that answers in a couple of seconds warm. Reach for it for a *described*
  graphic ("a woodcut fox in two inks, thick outlines"). `klein-4b-base` buys
  real CFG and a working negative prompt at ~15× the per-frame cost (MEASURED
  58.8 s at 1024/28 steps).
- **SDXL family (incl. `ssd-1b`, `sdxl-turbo`)** — the *style* family. If the
  design depends on a specific look (riso, linocut, halftone, a studio's house
  style), SDXL plus a style LoRA beats anything newer with no LoRA. `ssd-1b` is
  the value pick: same class, same rules, 1024 px in seconds.
- **SD 1.5** — kept for breadth and for the LoRA/ControlNet ecosystem, not for
  quality. Use it when a specific old checkpoint or embedding is the point.
- **Sana Sprint** — the cheapest iteration loop. 2 steps, guidance embedded
  (honoured), no negative prompt at all, and its own 32×/512 resolution rules.
  Its frames are the least predictable on complex scenes, so treat it as a
  sketchpad: many ideas, fast, then re-run the winner on `klein-4b`.
- **Z-Image-Turbo** — the second 6B family, and the only one here that arrived
  with its own step-distilled schedule *and* a real CFG pass available at
  guidance > 0 (§3). 9 steps at guidance 0.0, multiples of 16 from the class's own
  check, a 1 MP policy cap, and no `image=` on its text-to-image class — `/edit`
  is the separate `ZImageImg2ImgPipeline`. Its quality is **not judged here**:
  it runs, its frames are non-blank, and the timings are in the registry.

## 3. Tips for best use

### Distilled vs undistilled — the one distinction that changes everything

| | distilled (`klein-4b`, `sdxl-turbo`, both Sana, `z-image-turbo`) | undistilled (`klein-4b-base`, `sdxl-1.0`, `sd-1.5`, `ssd-1b`) |
|---|---|---|
| steps | 2–9 (`z-image-turbo` runs 9 = 8 transformer forwards). More steps do NOT help | 25–30. Fewer degrades |
| guidance | **ignored** on `klein-4b` and `sdxl-turbo` (no CFG at their own schedule); **honoured** on Sana (an embedding) and on `z-image-turbo` — its class gates CFG on `guidance_scale > 0`, so above 0 a REAL CFG pass runs (MEASURED) | honoured — and MEASURED to matter: `klein-4b-base` frames at guidance 4.0 vs 1.0 differ by a mean absolute pixel difference of **34.38** |
| negative prompt | `klein`: none. Sana: none. `sdxl-turbo` and `z-image-turbo`: the parameter exists, but no CFG runs at their own schedule (guidance 0.0), so it only acts if guidance is raised above 0 | real, and worth writing |
| speed claim | **do not quote a step-count speedup**: 4 steps vs 30 was 11.2 s vs 15.0 s under CPU offload, because stage paging dominates, not per-step compute | — |

### Practical, per knob

- **Always let the registry's defaults apply** unless you have a reason. The
  pipeline *class* defaults are the **base** model's schedule (50/4.0 for
  `Flux2KleinPipeline`), so running a distilled checkpoint at class defaults runs
  the wrong schedule entirely.
- **Resolution**: generate at the model's trained size — 1024 px for SDXL/SSD-1B/
  klein, 512 px for SD 1.5/Sana. Above that, the model invents anatomy; below it,
  it loses composition. Every dimension is a multiple of the entry's
  `dim_multiple`; violating a model's own rules is a **400**, not a bad frame.
- **The seed is a knob, not a constant.** A generated source is one sample; run 4–8
  seeds and pick by *traceability* (see §4), not by eye at thumbnail size.
- **img2img is the cheap way to iterate.** `sdxl-1.0`, `ssd-1b`, `sd-1.5` and the
  Sana entries take `strength` (0.3–0.5 keeps composition; 0.7+ reinterprets).
  This is how you push a design toward flat inks without regenerating it: take the
  frame you like and re-run it at strength 0.35 with "flat two-colour screen
  print, no gradients" in the prompt.
- **LoRA**: stack 1–2 style adapters, not five. Weights 0.6–0.8 usually reads as
  the style; 1.0 often over-fires. Re-calling `set_adapters` changes output
  (MEASURED) — it is a live knob, not a load-time choice.
- **VAE swaps**: only for a reason (an fp16-fix decoder, a better decoder). A
  `taesd`/`taesdxl` tiny VAE decodes **visibly softer** — a trade, never a free
  speed-up. **Build order matters** (MEASURED): `from_pretrained` → scheduler →
  LoRAs → `set_adapters` → VAE → `enable_model_cpu_offload()` LAST.
- **Text in the image**: keep it out of the generation and add it afterwards. Every
  entry here garbles anything longer than a word, and a garbled word is worse than
  no word on a garment.
- **Batch > single**: because one frame is a sample, ask for several and compare.
  The service's `/generate` takes `images`; a seed sweep is four calls with the
  seeds recorded, not one call hoping.

## 4. Prompting for the chopshop pipeline

The trace stage wants **flat, high-contrast, few-colour** art; a beautiful
gradient-heavy frame is the worst possible input. The industry's screen-print
prompt formula applies directly, and it is worth putting on the wall:

> **subject + garment/shirt colour + number of inks + art style + simplification
> + composition**

Concretely, for a source we intend to trace:

```
bold screen-print graphic of <subject>, exactly three flat ink colours
(<c1>, <c2>, <c3>), thick uniform outlines, simplified shapes,
no gradients, no soft shadows, no photographic texture, no hairlines,
centred composition, plain white background, print-ready vector-style illustration
```

- **Cap the inks in the prompt.** "three spot colours" measurably steers models
  away from subtle shading, and it is what makes the frame separable for print —
  the same reason the pipeline's own `max_colors` exists.
- **Name the background you can key out.** Models rarely give true transparency;
  `plain white background, no shadow, no ground` is the practical ask, and it is
  what the prep stage wants. (`Qwen-Image-2.1` is the exception that advertises a
  native RGBA VAE — a reason to look at it, not yet a measured fact here.)
- **Ask for flat, not photographic.** "flat colour", "vector style", "screen
  print", "woodcut", "halftone with limited palette" all move the output toward
  something that traces.
- **Keep fine detail out.** AI adds speckle and hairlines that become thousands of
  nodes; the tracer then fails or produces a print nobody wants. "thick uniform
  stroke weight, minimal fine detail" is a print constraint *and* a tracing one.
- **Do not describe the garment.** You are designing the print file, not the
  product photo; a described shirt steals composition and resolution.
- **Generate at the size you need for the print, not the size that looks fine on
  screen.** A full-front print is ~12 in wide; at 300 dpi that is ~3600 px. The
  source can be traced at less, but the frame you *judge* should not be a
  thumbnail.
- **Judge a source by its trace, not by itself.** The pipeline has `front_pipeline.sh`
  for exactly this: a candidate that looks good and traces into 400 nodes is worse
  than a plainer frame that traces into 60. The tournament/compare stage already
  measures this — use it as the selection criterion for generations too.

## 5. What fits, what does not, and why

Checked against the HF API (the registry's own rule: enumerate the repo, never the
card's prose). Sizes are the *download* of the core files; gating and licence
decide deployability before VRAM does. This table is the **outcome of the W1
candidate pass**: every candidate ends in a registry entry or a refusal with the
reason recorded here once, so the next person does not have to re-derive it.

| candidate | licence (HF API) | gated | core download | outcome |
|---|---|---|---|---|
| `Tongyi-MAI/Z-Image-Turbo` (6B, `ZImagePipeline`) | apache-2.0 | no | 32.8 GB (transformer 24.61 GB **fp32** + Qwen3 text encoder 8.05 GB fp32 + VAE 0.17 GB) | **REGISTERED — `z-image-turbo`.** Runs on this card under `offload=cpu`; the fp32→bf16 module is what makes it fit (see below) |
| `lodestones/Chroma1-HD` and `lodestones/Chroma1-Flash` (8.9B, `ChromaPipeline`) | apache-2.0 | no | 27.5 GB core; the transformer shards alone are **17.80 GB** (9.95 + 7.85), plus a 9.52 GB T5-XXL encoder. Both repos also ship a duplicate 17.8 GB single-file transformer | **REFUSED — the deciding module cannot be resident.** 17.80 GB = **16.58 GiB** against a **15.92 GiB** card, and under `offload=cpu` accelerate moves the whole transformer (see below for the on-card attempt) |
| `Qwen/Qwen-Image-2.1` (7B DiT + Qwen3-VL 8B encoder, RGBA VAE) | other → **Qwen Research License** | no | 33.1 GB (transformer 14.23 GB + text encoder **17.54 GB** + VAE 1.35 GB) | **REFUSED — non-commercial *and* unloadable here.** The licence is research-only, its pipeline class is absent from the installed diffusers, and its biggest module is over the card (three independent reasons, below) |
| `black-forest-labs/FLUX.2-klein-9B` | other → **flux-non-commercial-license** | **auto** | 52.9 GB (transformer 18.16 GB, text encoder 16.38 GB, plus a duplicate 18.16 GB single file) | **REFUSED — gated AUTO *and* non-commercial.** Fetching it needs terms accepted with a token, and its output may not be sold; the transformer is also 16.91 GiB against a 15.92 GiB card |
| `stabilityai/stable-diffusion-3.5-medium` | other → community (`stabilityai-ai-community`), behind a gated terms form | **auto** | 48.9 GB (T5-XXL fp16 9.79 GB, transformer 4.94 GB, CLIP-L/G 1.64 GB, plus fp8 and fp16 duplicates) | **REFUSED — gated AUTO.** The gate is a licence-acceptance form (name, email, country, organisation) plus a token, and SD 3.5 fills no gap that SDXL + klein leave |

### Why Z-Image-Turbo is registered

- **Apache-2.0**, so output is commercially usable — the second Apache-2.0 family
  here after FLUX.2 [klein] and Sana Sprint. Not gated; no ACK needed.
- **It fits because of `torch_dtype`.** The repo stores the transformer (24.61 GB)
  and the text encoder (8.05 GB) as **fp32**; loading with
  `torch_dtype=torch.bfloat16` halves the *resident* module to ~12.3 GB, which is
  the number the 15.92 GiB card has to hold under `offload=cpu`. The **disk** is
  sized from the 32.8 GB download. This is the §1 rule in action, not a special
  case.
- **Resolution rule 16, read off the class.** `ZImagePipeline.__call__` raises
  unless each side is divisible by `vae_scale_factor * 2`, and `vae_scale_factor`
  is diffusers' own `2 ** (len(vae.config.block_out_channels) - 1)` = 8 for this
  repo's four-entry `AutoencoderKL` — so 16, and it is an error rather than a
  silent re-bin. `min_dim` 128 and the 1 MP cap are **our policy, ESTIMATE**: the
  class imposes neither, and 1024×1024 is the size that was actually run.
- **The schedule is the Turbo one, not the class's.** `ZImagePipeline` defaults to
  **50 steps / guidance 5.0** (its base model). The card's own example is
  `num_inference_steps=9` (8 transformer forwards) at `guidance_scale=0.0`, and
  that is what the registry entry carries.
- **Guidance is NOT a no-op here**, unlike `klein-4b` and `sdxl-turbo`:
  `do_classifier_free_guidance` is `guidance_scale > 0`, so above 0 a real CFG
  pass runs. That is the measured distinction the registry's `guidance_embedded`
  flag exists to express (see §3).
- **No img2img on the t2i class.** `ZImagePipeline` has no `image=`/`strength=`;
  the family's separate `ZImageImg2ImgPipeline` carries them, and that class is
  what an `/edit` request loads.

### Why the four refusals are refusals

- **Chroma1-HD / Chroma1-Flash (17.8 GB module vs a 17.10 GB card — MEASURED).**
  This is the footprint rule with no room to argue, and it was proved on the card
  rather than inferred. The transformer is the deciding module because
  `enable_model_cpu_offload` moves whole modules: its two shards on disk are
  **9,946,193,392 + 7,853,894,360 bytes = 17.80 GB (16.58 GiB)**, and the module
  loaded from the repo is **8.900 B parameters → 17.800 GB = 16.578 GiB in
  `bfloat16`**. The `torch_dtype=torch.bfloat16` trick that rescues Z-Image does
  **not** apply here: the repo already stores the transformer in bf16, so the
  loaded module is the same size as the download. Attempted placement of that real
  module on the card: PyTorch allocated **15.70 GiB** of it, then died —
  `CUDA out of memory. Tried to allocate 18.00 MiB. GPU 0 has a total capacity of
  15.92 GiB of which 16.00 MiB is free`. A bare allocation of the same footprint
  fails on its own (`Tried to allocate 16.58 GiB` against 15.857 GiB free), while
  a 12.30 GB bf16 allocation — Z-Image's transformer module — succeeds on the same
  card in the same session. Chroma is FLUX.1-schnell derived and ships three parts
  per repo (a `transformer/` directory, a duplicate single-file `.safetensors`, and
  a Flash *delta* weight), so the download is 27.5 GB at best and 45–63 GB if you
  fetch what the repo also offers. Nothing was registered, and no quality claim is
  made either way.
- **Qwen-Image-2.1 (three independent reasons).** (1) The licence is the **Qwen
  RESEARCH LICENSE AGREEMENT** — "Non-Commercial" is defined as "for research or
  evaluation purposes only", and commercial use needs a separate licence from the
  licensor — so it is not a licence this repo can treat as commercial. (2) The
  repo declares `QwenImage21Pipeline`, and the diffusers installed in the GPU
  environment (0.40.0) has **no such class** (`hasattr(diffusers,
  "QwenImage21Pipeline")` is `False`, as are `QwenImage21Transformer2DModel` and
  `AutoencoderKLQwenImage21`); the environment must not be modified, so the model
  cannot be loaded at all. (3) Even with the class, the largest single module — the
  Qwen3-VL-8B text encoder at **17.54 GB = 16.34 GiB** — is over the 15.92 GiB
  card, so under `offload=cpu` it would refuse for the same reason Chroma does. It
  was **not** downloaded: 33 GB for a model that cannot load is the waste this
  file's own rule forbids. Its advertised native RGBA VAE stays a *note for the
  future* (background isolation, §4) — not a measured fact here.
- **FLUX.2-klein-9B (gated AUTO + FLUX Non-Commercial).** `gated: "auto"` means
  the download needs the terms accepted under an account token, and the licence is
  the FLUX **Non-Commercial** License — the same two-part reason `sd-turbo` was
  refused, one of them (the gate) not negotiable by an environment variable. Its
  transformer is also 18.16 GB / 16.91 GiB, over this card, so even a
  commercial licence would not have made it a registry entry.
- **stable-diffusion-3.5-medium (gated AUTO).** `gated: "auto"` with a licence
  form (name, email, country, organisation, intended use) behind it, under a
  community licence this repo cannot accept on anyone's behalf. It was refused on
  the gate alone, and the second reason is that it fills no gap here: SDXL + SSD-1B
  own the LoRA-ecosystem slot and klein owns the prompt-adherence one.

Rejections are as much a part of this file as acceptances — a candidate refused
once should not have to be re-derived by the next person.

## 6. Quick picks

| you want | use | how |
|---|---|---|
| a graphic from a description, fast | `klein-4b` | 4 steps, guidance 1.0, 1024 px, name the ink count in the prompt |
| the same, at maximum klein quality | `klein-4b-base` | 28 steps, guidance 4.0, and write a negative prompt — it works |
| a specific style / a LoRA | `sdxl-1.0` or `ssd-1b` | 1024 px, 25–30 steps, guidance 5.0–7.5, negative prompt is real |
| fastest good 1024 px frame | `ssd-1b` | 25 / 7.5 — MEASURED 4.4 s warm |
| a 6B frame | `z-image-turbo` | 9 steps, guidance 0.0, 1024 px, multiples of 16 — MEASURED 41.3 s first call, 17.0 s after |
| many ideas, cheap | `sana-sprint-0.6b` | 2 steps; 512 px multiples of 32; no negative prompt |
| a frame to steer toward inks | any img2img-capable entry | re-run the chosen frame at `strength` 0.35 with a flat-colour prompt |
| something to trace into few nodes | — | prompt for flat colour + thick outlines, then judge it with `front_pipeline.sh`, not by eye |
