# chopshop-flux HTTP API

Six routes, JSON bodies, one GPU. This is the whole surface — nothing here is
optional and nothing here is a placeholder.

| route | verb | what it does | costs GPU time |
|---|---|---|---|
| `/health` | GET | is it up, and what is loaded. Public (no token) | no |
| `/models` | GET | the three registries: models, LoRA modifiers, VAE swaps | no |
| `/generate` | POST | text → image(s) | yes |
| `/edit` | POST | image(s) + text → image(s) | yes |
| `/files/<name>` | GET | one generated PNG, by basename | no |
| `/unload` | POST | free the loaded model, taking the engine lock | no |

Six is the count `server.py` actually serves (five exact matches plus the
`/files/` prefix). There is **no `/load` route**: a model is loaded implicitly by
the first `/generate` or `/edit` that asks for it, and switching models is the
same request with a different `model`. `GET` and `POST` each end in a `404 no
route <path>` for anything else.

All responses are JSON except `GET /files/<name>`, which returns image bytes.

## Auth

If `CHOPSHOP_FLUX_TOKEN` is set, every route except `/health` requires:

```
Authorization: Bearer <token>
```

A bad or missing token is `401` with `{"error": ..., "kind": "unauthorised"}`.
When no token is configured, everything is open — which is why the default bind
is loopback, not `0.0.0.0`.

`/health` is deliberately exempt. A health check that requires the secret cannot
be used to decide whether to send the secret.

## `GET /health`

Is it up, and what is loaded. Cheap; does not touch the model.

```json
{
  "ok": true,
  "service": "chopshop-flux",
  "version": "0.1.0",
  "auth_required": false,
  "engine": {
    "loaded_model": "klein-4b",
    "loaded_repo": "black-forest-labs/FLUX.2-klein-4B",
    "load_seconds": 41.2,
    "offload": "cpu",
    "busy": false,
    "out_dir": "/srv/chopshop-flux/out",
    "torch": "2.14.0.dev20260804+rocm7.1",
    "rocm": "7.1.52802",
    "device": "cuda",
    "device_name": "AMD Radeon Graphics",
    "vram_total_gb": 17.06,
    "vram_free_gb": 15.88,
    "vae_tiling": false,
    "load_notes": [],
    "trimmed_on_unload": true,
    "gpu_guard": {
      "mode": "warn",
      "required_free_gb": 5.0,
      "free_gb": 15.88,
      "measured": true,
      "waiting": false,
      "contended": false,
      "lmstudio": null,
      "notes": [],
      "last": null
    }
  }
}
```

`device_name` is reported because torch presents a ROCm GPU as `cuda`, and an
integrated GPU can enumerate as a device too — never assume device 0 is the card
you meant, read what it says it is. `rocm` is non-null when `torch.version.hip`
is set. `load_notes` carries non-fatal things the last load hit (e.g. "VAE tiling
was requested but this VAE offers no `enable_tiling()`"), and
`trimmed_on_unload` says whether the last `POST /unload` got pages back from the
allocator — see "Memory, lifetime and the environment".

### Reading `gpu_guard` — the two things a poller gets wrong

`gpu_guard` answers *is something else on the card RIGHT NOW*, and it answers
from the moment the process is up: `serve()` takes one free-VRAM reading before
the socket is even bound (`FluxEngine.probe_guard`), so a start — or the restart
after an idle exit — no longer reports `measured: false` while another tenant
holds the card. That was #14: a generation submitted into that window OOM'd at
load instead of being refused `503 gpu_busy`. `guard=off` skips the startup read
(`contended` is null there by definition), and while nothing is loaded the
reading is re-taken on each `/health` call, so `free_gb` is the card's state now
rather than the number the process started with.

- **`measured: false` means "no reading has been taken yet" — never "the card is
  clear."** The device block deliberately does not import torch to answer, and
  before this fix only the load path did. `contended: null` says the same, or
  that the guard is off; neither is agreement that there is room.
- **`waiting: true` means a request is currently being HELD by
  `CHOPSHOP_FLUX_GUARD=wait`.** `busy: true` alone cannot say which situation a
  poller has landed in — `generate` sets `busy` before the load path runs the
  gate, so both cases report it — and the two want opposite responses: `busy`
  without `waiting` is a generation that finishes on its own, `busy` with
  `waiting` is waiting on *another* process, which a resident model (measured:
  16.23 GB held at IDLE) never releases without an explicit unload.

## `GET /models`

The registry, with the licences. Read this before generating something you intend
to sell. Three arrays: `models` (nine entries across five diffusers families —
FLUX.2 [klein], SDXL, SD 1.5, Sana Sprint and Z-Image; `ssd-1b` is an
SDXL-architecture entry, not a family of its own), `modifiers` (the LoRA adapters)
and `vaes` (the VAE swaps). `modifiers` and `vaes` are separate keys beside the
existing `models` array, not a restructure of it — a client that only reads
`models` keeps working unchanged.

```json
{
  "models": [
    {
      "key": "klein-4b",
      "repo_id": "black-forest-labs/FLUX.2-klein-4B",
      "params_b": 4,
      "license": "Apache-2.0",
      "commercial_ok": true,
      "vram_gb": 13.0,
      "default_steps": 4,
      "default_guidance": 1.0,
      "distilled": true,
      "gated": false,
      "default": true,
      "notes": "Apache 2.0, so generated output is yours to sell. The default.",
      "pipeline": "Flux2KleinPipeline",
      "dim_multiple": 16,
      "min_dim": 64,
      "max_pixels": 4194304,
      "negative_prompt": false,
      "img2img_strength": false,
      "guidance_embedded": false,
      "resolution_binning": false,
      "multi_reference": true,
      "edit_pipeline": null
    },
    { "key": "sdxl-1.0", "pipeline": "StableDiffusionXLPipeline",
      "edit_pipeline": "StableDiffusionXLImg2ImgPipeline",
      "dim_multiple": 8, "min_dim": 128, "negative_prompt": true,
      "default_negative_prompt": "gradients, soft shadows, photographic texture, hairlines, blur",
      "img2img_strength": true, "...": "..." },
    { "key": "sana-sprint-0.6b", "pipeline": "SanaSprintPipeline",
      "edit_pipeline": "SanaSprintImg2ImgPipeline",
      "dim_multiple": 32, "min_dim": 512, "max_pixels": 1048576,
      "negative_prompt": false, "guidance_embedded": true,
      "resolution_binning": true, "...": "..." }
  ],
  "modifiers": [
    {
      "key": "sdxl-lightning-4step",
      "kind": "modifier",
      "repo_id": "ByteDance/SDXL-Lightning",
      "weight_name": "sdxl_lightning_4step_lora.safetensors",
      "targets": ["sdxl-1.0", "ssd-1b"],
      "license": "CreativeML Open RAIL++-M License",
      "commercial_ok": true,
      "repo_bytes": 393900000.0,
      "steps": 4,
      "guidance": 0.0,
      "scheduler": "trailing-euler",
      "scale": 1.0,
      "aliases": ["lightning-4", "sdxl-lightning-4"],
      "notes": "..."
    }
  ],
  "vaes": [
    {
      "key": "taesdxl",
      "kind": "vae",
      "repo_id": "madebyollin/taesdxl",
      "targets": ["sdxl-1.0", "ssd-1b"],
      "license": "MIT",
      "commercial_ok": true,
      "repo_bytes": 9800000.0,
      "tiny": true,
      "aliases": ["taesd-xl", "tiny-sdxl"],
      "notes": "..."
    }
  ]
}
```

The family-specific fields — `pipeline`, `edit_pipeline`, `dim_multiple`,
`min_dim`, `max_pixels`, `negative_prompt`, `default_negative_prompt`,
`img2img_strength`, `multi_reference` — are the per-model rules a client reads
before calling, not optional hints.
`default_negative_prompt` is the print-tuned value the entry sends when a request
gives no `negative_prompt` (see "The negative prompt: per-family defaults"); it is
`null` on every entry whose pipeline has no such parameter.
`edit_pipeline` names the img2img class for a family that splits text-to-image
from image-to-image (SDXL, SSD-1B, SD 1.5); `null` means one class serves both
(klein). Sana Sprint names an edit class too, and its rules are its own:
multiples of 32, a 512 floor, a 1 MP cap.

The keys in `modifiers` and `vaes` are exactly what `POST /generate` and
`POST /edit` accept: pass a `modifier` key (`sdxl-lightning-4step`, `lcm-lora-sdxl`,
`taesdxl` …) in the request's `modifiers` array, and a `vae` key in the request's
`vae` field. Both resolve by key or alias, case-insensitively, the same way a
`model` does.

Two flags exist because they contradict an assumption the earlier responses
encouraged:

| field | means |
|---|---|
| `guidance_embedded` | the model is distilled **but acts on `guidance_scale`** anyway, through a guidance embedding rather than a CFG pass. Sana Sprint is `true`. Where this is `true` the "guidance is ignored" warning does **not** fire, because it would be false. |
| `resolution_binning` | the pipeline silently re-bins a requested size to its own training buckets, so the returned image's `width`/`height` may not be the requested ones. Sana Sprint is `true`; the service warns when the model is used. |
| `multi_reference` | the pipeline's `image=` accepts a **list**, so `/edit` may be conditioned on several references at once (the prompt says how they relate). `true` for the FLUX.2 [klein] rows only; every img2img family takes exactly one, and a second reference there is a `400`, not a silently dropped image. |

### Measured vs estimated

Not every number in a registry entry has the same provenance, and the entry's
`notes` says which is which — **MEASURED** means it was run on the box (with the
timings that are the evidence), **ESTIMATES** means the figure is a derived
heuristic nobody measured. There is no separate boolean for this; read the note.
The ledger as it stands:

| entry | run on the box | figures marked |
|---|---|---|
| `klein-4b` | yes — the default; timings in the README | run measured; `vram_gb` is a download-derived figure |
| `klein-4b-base` | yes — 28 steps 58.8 s, guidance 4.0 vs 1.0 differ by 34.38 mean abs | **MEASURED** |
| `sdxl-1.0` | no | `vram_gb`/`repo_bytes` **ESTIMATES** |
| `sdxl-turbo` | no | `vram_gb`/`repo_bytes` **ESTIMATES** |
| `sd-1.5` | no | `vram_gb`/`repo_bytes` **ESTIMATES** |
| `ssd-1b` | yes — 1024 px at 25 / 7.5: 6.1 s first call, 4.4 s after | steps/guidance **MEASURED**; `vram_gb`/`repo_bytes` **ESTIMATES** |
| `sana-sprint-0.6b` | yes — 2 / 4.5: ~40 s first call, ~2.5 s after; 15.58 of 17.10 GB VRAM free | run and download **MEASURED** |
| `sana-sprint-1.6b` | no | download **MEASURED**; `vram_gb` **ESTIMATE**; note says "NOT run on this card" |
| `z-image-turbo` | yes — 1024 px at 9 / 0.0: **55.8 s load, 41.3 s first call, 17.0 s after**; peak 15.52 GB (14.45 GiB) of the 15.92 GiB card; guidance 0.0 vs 4.0 differ by 25.11 mean abs | run, download and the guidance difference **MEASURED**; `min_dim`/`max_pixels` and `vram_gb` **ESTIMATES** (the note says which) |


`modifiers` and `vaes` are both licence-bearing in their own right:
`commercial_ok` on a `modifier` entry is the adapter's licence, not the target
model's, and it is enforced identically (see `POST /generate`). `weight_name` is
the exact file inside the repo — necessary because `ByteDance/SDXL-Lightning`
holds three different adapters, so the repo alone does not identify one.
`scheduler` is the scheduler the adapter requires (`lcm` or `trailing-euler`);
the engine installs it when the adapter is requested.

## `POST /generate`

Text to image.

| field | type | default | notes |
|---|---|---|---|
| `prompt` | string | — | **required**, non-empty |
| `model` | string | `klein-4b` | key or alias (`4b`, `sdxl`, `sd-1.5`, `sana`, `ssd`, …) |
| `width` / `height` | int | 1024 | within the model's own resolution rules (see `/models`) |
| `steps` | int | the model's | 4 for distilled klein, 2 for sdxl-turbo, 2 for Sana Sprint, 30 for SDXL |
| `guidance` | float | the model's | 1.0 for distilled klein, 0.0 for sdxl-turbo, 4.5 for Sana Sprint |
| `negative_prompt` | string | unset | works only where the model has one (`negative_prompt: true`) |
| `strength` | float | unset | img2img strength, SD-style models only |
| `modifiers` | array of string | unset | LoRA adapter keys from the `modifiers` array in `/models`, applied in the order given |
| `modifier_scales` | object | unset | adapter weight per modifier, `{"lcm-lora-sdxl": 0.8}` |
| `vae` | string | unset | a VAE key to swap in (see `vaes` in `/models`) |
| `seed` | int | random | always reported back, so a result is reproducible |
| `images` | int | 1 | batched in one call — the cheap kind of parallelism |
| `ink_cap` | int | unset (off) | reduce the decoded frame to at most N flat colours (2–256) — a reduction, not a separation. See "Output-side passes" |
| `ink_cap_mode` | string | `quantize` | `quantize` \| `posterize`; posterize's floor is 8 colours |
| `background` | string | `keep` | `white` \| `key` \| `keep` — flatten transparency, or flood-key a uniform border colour |
| `hires` | object | unset (one pass) | two-pass generate → upscale → img2img: `{"scale", "strength", "steps", "upscaler"}` |
| `seeds` | array of int | unset | a sweep: one frame per seed, returned with the seed→file mapping |
| `provenance` | bool | false | record each frame's provenance in the response and in a `.json` sidecar |

```json
{
  "model": "klein-4b",
  "license": "Apache-2.0",
  "commercial_ok": true,
  "prompt": "a phoenix emblem",
  "width": 512, "height": 512,
  "steps": 4, "guidance": 1.0, "seed": 1234567,
  "edited": false,
  "references": 0,
  "modifiers": [],
  "vae": null,
  "scheduler": null,
  "queue_wait_seconds": 0.0,
  "load_seconds": 41.2,
  "total_seconds": 3.4,
  "images": [
    { "name": "20260927T183001Z-klein-4b-s1234567-01.png",
      "path": "/srv/chopshop-flux/out/2026...-01.png",
      "width": 512, "height": 512, "bytes": 402133,
      "sha256": "…", "seed": 1234567, "model": "klein-4b", "seconds": 3.4 }
  ],
  "warnings": []
}
```

The response above is a request that used NONE of the output-side keys: those
fields (`ink_cap`, `background`, `hires`, `seeds`, `seed_files`, `provenance`,
`negative_prompt_source`, and the per-frame reports) are **omitted entirely**
unless the request used them — the same rule the adapter knobs already follow — so
an existing client keeps reading exactly the body it always read. A request that
uses them gets them back; see "Output-side passes" below.

With adapters applied, `modifiers` reports what actually ran — the resolved key
and **the scale it really used**, which is not always the one that was typed:

```json
{ "modifiers": [
    { "key": "lcm-lora-sdxl", "scale": 0.8,
      "repo_id": "latent-consistency/lcm-lora-sdxl",
      "weight_name": "pytorch_lora_weights.safetensors" },
    { "key": "pixel-art-xl", "scale": 1.0,
      "repo_id": "nerijs/pixel-art-xl",
      "weight_name": "pixel-art-xl.safetensors" } ],
  "vae": "sdxl-vae-fp16-fix",
  "scheduler": "lcm" }
```

`vae` is `null` unless a swap was requested, and `scheduler` is the scheduler an
adapter asked for (`lcm`, `trailing-euler`) — both are echoed so a caller never
has to guess which pipeline it actually got.

### Modifiers

- A LoRA key is licence-gated the same way a model is. A non-commercial adapter
  requires `CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1`; an unknown key is a `400` with the
  keys that exist.
- An adapter's own schedule is honoured, and contradicting it is **reported**:
  asking for `sdxl-lightning-4step` with `steps: 30` runs, and the `warnings` array
  says the adapter is a 4-step distilled one. `lcm-lora-sdxl` installs
  `LCMScheduler` and the Lightning adapters install `EulerDiscreteScheduler` with
  `timestep_spacing="trailing"`.
- An adapter aimed at another model still loads, and `warnings` says it was not
  trained for this one.
- A `modifier_scales` entry that names an adapter not in `modifiers` is ignored and
  reported. A scale of `0` disables the adapter and is reported as doing so.
- Two adapters asking for different schedulers cannot both be honoured; the first
  requested wins and the conflict is reported.
- A VAE swap that cannot load is a failed generation, never a silent fallback to
  the model's own VAE.
- **The swap order matters on the device map.** The VAE is assigned *before*
  `enable_model_cpu_offload()`, because accelerate builds the offload map over the
  original VAE — assigning afterwards leaves the new one on CPU and the next
  pipeline call fails inside the scheduler step with a device mismatch that names
  the scheduler rather than the VAE. Measured, and pinned by a test.

The service names its own files (`<utc>-<model>-s<seed>-<NN>.png`), so no
download URL ever needs percent-encoding. Prompt-derived filenames — what
SwarmUI does — do need it, which is a bug `chopshop-sui` hit.

`warnings` is where honest caveats go, e.g. asking for `guidance: 3.0` on a
distilled model — where the pipeline will ignore it, because for a distilled
checkpoint classifier-free guidance never runs:

```json
"warnings": ["guidance_scale 3 is ignored: klein-4b is step-wise distilled, so the pipeline never runs classifier-free guidance. That is also why a negative prompt has no effect on it — put the steering in the prompt and the reference image."]
```

A `negative_prompt` on a model with `negative_prompt: false` is reported the
same way — as a warning, not a silent drop. So is a size a resolution-binning
pipeline may re-bin, a step/guidance pair that contradicts a loaded adapter's
own schedule, and a `hires.strength` inside the allowed range but outside the
0.2–0.35 safe band (allowed, run as asked, and warned about).

## Output-side passes

Optional, and each is named after what it changes rather than after an opinion
about the frame. **A request that uses none of them is byte-for-byte the request
this service has always made** — the same pipeline call, the same PNG bytes, the
same response body — which is pinned by `tests/test_output_features.py` and by
`scripts/probe_output_path.py` (the same probe run against the committed build and
against the change). The new keys are echoed in the response only when they were
used.

They run in a FIXED order on the frame that is written: **`hires` → `ink_cap` →
`background`.** The cap has to see the frame that will be judged, and the key has
to see the final palette; a key before the cap would put a colour into the
reduction's histogram that is not part of the artwork.

### `ink_cap` and `ink_cap_mode`

| field | type | default | notes |
|---|---|---|---|
| `ink_cap` | int | unset (off) | reduce the decoded frame to at most N **flat colours**, N = 2–256 |
| `ink_cap_mode` | string | `quantize` | `quantize` (median cut over the frame's own colours) or `posterize` (per-channel bit reduction) |

A colour **reduction**, never a colour **separation**: it produces no per-ink
plates, and the note in the response says so in those words. `quantize` cuts the
frame's colour histogram down to N, and every palette colour is a colour the frame
actually contained. `posterize` rounds each channel to `2**bits` levels, so its
reachable counts are 8, 64, … — an `ink_cap` below 8 with `ink_cap_mode:
posterize` is a **400**, never a silent 8.

The result is MEASURED, not assumed: the response reports the cap, the count
actually present, and the count before it.

```json
"ink_cap": {"max_colors": 3, "mode": "quantize", "colors_before": 4096,
            "colors_present": 3, "changed": true,
            "note": "reduced the frame from 4096 colours to 3, at or below the 3 cap; this is a colour reduction, not a colour separation"}
```

A frame already at or below the cap is a **skip and says so** — `changed: false`,
a note, and not one byte of the file rewritten — rather than implying work:

```json
"ink_cap": {"max_colors": 6, "mode": "quantize", "colors_before": 3,
            "colors_present": 3, "changed": false,
            "note": "the frame was already at 3 colour(s), at or below the 6 cap: nothing was reduced"}
```

The PNG stays RGB (RGBA after a key): a pixel-value reduction, not a palette-mode
file.

Measured with `scripts/measure_output_passes.py`, on the pipeline's own example
rasters; the metric named is the **mean absolute pixel difference** over every
channel value, and the ink counts are the real ones:

| frame | distinct colours | cap | result | MAD |
|---|---|---|---|---|
| `00-example-tonal-reference.png` 1024×1024 | 245 608 | quantize 16 | 16 colours | 4.69 |
| " | | quantize 6 | 6 colours | 8.50 |
| " | | quantize 3 | 3 colours | 12.50 |
| " | | posterize 8 | 8 colours | 74.68 |
| `00-example.png` 1200×1200 | 5 | quantize 16 / 6 | **skipped** ("nothing was reduced") | 0 |
| " | | quantize 3 | 3 colours | 3.06 |

Two things that table says that prose would not: **posterize is far more
destructive than quantize at the same count** (MAD 74.68 vs 12.50 for 8 vs 3
colours on the same frame), and the skip path is real — a frame the pipeline
already produced flat was left byte-identical by a cap of 16. On those same two
frames, `background: "key"` moved **1 325 719** pixels on the flat one (uniform
`#ffffff` border) and was **refused, "not uniform, left alone"**, on the
photographic one (2 716 distinct border colours).

**What it is NOT: a node-count lever.** This is the same operation the trace side
has already measured, and its answer is in `chopshop-svg`'s own record
(`skills/chopshop-svg-pipeline/SKILL.md`, `README.md`, `scripts/im_filters.py`):
quantising the SOURCE raster does **not** reduce node count — over
pngquant/PIL-median/max-coverage/octree sources at 6–48 colours, max nodes went
**967 → 912 (median 16) → 1415 (median 6)**. "It is a colour tool, not a node
tool." The levers the tracer responds to are noise and soft gradients, which is
what the per-family negative prompt default (below) names — whether that lands in
the traced nodes has NOT been measured here, and no such claim is made.

### MEASURED on real generations, not on example rasters (#8)

The table above is measured, but it is measured on the pipeline's **example
rasters** — files that already exist, with no model involved. These runs are the
complement: real klein-4B and SDXL generations on this card, with the passes
applied by the engine to the frames it had just decoded. Run with
`scripts/smoke.py --ink-cap N --hires --background key --seeds ... --provenance`.

| pass | model | result |
|---|---|---|
| `ink_cap` 3 | klein-4b, seeds 1 / 2 | **19 122 → 3** and **16 044 → 3** colours |
| `ink_cap` 3 | klein-4b, seed 7 | **11 954 → 3** colours |
| `ink_cap` 4 | sdxl-1.0 | **32 643 → 4** colours |
| `seeds` 1,2 | klein-4b | 2 frames, 7.06 s first call then 3.26 s warm; 0 blank, 0 NaN |
| `hires` 2.0× | sdxl-1.0, 512 → 1024² | pass 1 **4.21 s**, pass 2 **7.80 s** |
| `background: key` | klein-4b, 3 frames | **0 of 3 keyed** — "not uniform, left alone" |

Four things that only a real run shows, and that the example-raster table cannot:

- **`hires` is UNAVAILABLE on the default model.** `klein-4b` and
  `klein-4b-base` are refused with a `400`: `Flux2KleinPipeline` has no
  `strength` parameter, so a second pass has no way to say how far from the first
  frame it may move. `hires` needs `img2img_strength: true`, which is the six
  other entries (sdxl-1.0, sdxl-turbo, sd-1.5, ssd-1b, both Sanas, z-image-turbo)
  and **not** the two kleins. The default model cannot use the flagship pass.
- **A `hires` second pass roughly DOUBLES the cost, not "one more pass".** On
  SDXL at 512² → 1024², strength 0.35: the first pass took 4.21 s and the second
  7.80 s. The second pass is dearer than the first, because it runs at 4× the
  pixels. Budget ~1.9× the generation time, not ~1.3×.
- **`background: "key"` matched nothing on ANY real frame — 0 of 3.** The key is
  a flood from the border that matches colours **exactly**, and the model's
  "flat white" is not flat: on a frame generated from a prompt that explicitly
  asked for "a plain flat white background, no texture", the 2 048 border pixels
  were `#fcfdfd` (1177), `#fdfdfd` (869) and `#fdfdfe` (2) — three colours
  differing by one unit in a single channel, and the flood stops on the second.
  It is correct to refuse rather than guess, but the practical reading is that
  `key` works on synthetic flat art and is inert on model output. `white` mode is
  the one that does something to a real frame.
- **A quantize cap that is met can still be a degenerate palette.** Every 3- and
  4-colour result above clustered at the extremes: klein's 3 were `#000000`,
  `#fdfdfe`, `#fdfffe`, and SDXL's 4 were `#2f2422`, `#cbc7c1`, `#e1ddd7`,
  `#e9e7e1` — one dark and three near-greys within 30 units of each other. The
  cap is satisfied and the picture is flattened; the `palette` list in the
  response is where a caller sees it, which is why it is there.

**`hires.steps` inherits the request's step count** unless the block sets its
own: pass 2 runs `hires.steps` when given, and otherwise the same number pass 1
ran. It used to fall back to the model's default instead, so `--steps 20`
produced a cheaper first pass and a full-price second one at 30 — while pass 2 is
the DEARER of the two (MEASURED 4.21 s then 7.80 s, SDXL 512 → 1024²), which
made it a cost bug rather than a preference (#13). The report carries both
numbers either way: `steps` is what pass 2 ran, `requested_steps` is the
request's own, so an explicit `hires.steps` reads as the deviation it is.

### `background`

| value | what it does |
|---|---|
| `keep` (default) | the frame is written exactly as decoded |
| `white` | compositing pass: transparency is flattened onto opaque white and the frame becomes RGB. On an already-opaque frame there is nothing to composite and the response says so |
| `key` | flood-key the frame's border colour to transparent (RGBA output) |

`key` reads the four edges. If they are **not one uniform colour** the frame is
left completely alone: `"not uniform, left alone"`, with the number of distinct
border colours. Keying a near-uniform edge would take pixels that are not
background with it. If the border IS uniform, the key is a 4-connected **flood**
from the border — so a region of that colour which touches no border pixel (a
white eye inside a black shape) stays part of the artwork.

```json
"background": {"mode": "key", "uniform": true, "key_color": "#ffffff",
               "pixels_moved": 320, "changed": true,
               "note": "flood-keyed the uniform border colour #ffffff to transparent: 320 pixel(s) moved, and pixels of that colour not connected to the border were left alone"}
```

`background: "white"` is a PIXEL operation and does not touch the prompt. A white
ground is still something to ask for in the prompt (`docs/MODELS.md` §5); this
service does not edit a prompt behind the caller's back.

### `hires` — the two-pass route

```json
{"prompt": "a woodcut fox in two inks", "model": "sd-1.5",
 "width": 512, "height": 512,
 "hires": {"scale": 2.0, "strength": 0.35, "steps": 20, "upscaler": "lanczos"}}
```

| field | default | accepted |
|---|---|---|
| `scale` | `2.0` | 1.5–2.0. Below 1.5 a second pass is not worth a generation; above 2.0 the img2img re-render invents detail at a size the checkpoint was not trained at |
| `strength` | `0.35` | 0–0.5. **0.2–0.35 is the safe band** (composition survives). Above 0.35 the response warns; **above 0.5 the request is refused, never clamped** — a silently lowered strength would render a different request than the one sent and report it as done |
| `steps` | the request's own step count (what pass 1 ran) | the second pass's `num_inference_steps`; set it to run pass 2 at a different number |
| `upscaler` | `lanczos` | `lanczos`, `nearest`, `bilinear`, `bicubic` |

Pass 1 is the request as given — a `/edit`'s reference included, at that request's
own `strength` — at the model's native size. Its frame is upscaled, and pass 2 is
an img2img call on **the upscaled frame** at the same prompt and seed with the
block's `strength`. Both passes go through one code path, so the second pass is
the same request at a larger size rather than a second, subtly different call.

The target is checked against the model's OWN rules **before anything is loaded**,
and refused rather than clamped (a `400` naming `hires.scale` and quoting the rule
that refused it): it must be within the entry's `max_pixels`, and it must satisfy
the entry's `min_dim`/`dim_multiple` because pass 2 really runs at that size. The
target is computed from **the frame that actually came back**, so a
resolution-binning pipeline (Sana Sprint) is reported at the size it used.

Both passes are reported — seconds and size — because a slow route has to be
visible:

```json
"hires": {"scale": 2.0, "strength": 0.35, "steps": 30, "requested_steps": 30,
          "upscaler": "lanczos", "target": [1024, 1024],
          "pass_seconds": [1.32, 2.11]}
```

`requested_steps` is the request's own step count; it equals `steps` when the
second pass inherited it, and differs only when `hires.steps` was set on
purpose.

`pass_seconds` is `[pass 1, pass 2]` summed over the frames the request wrote. Each
frame's own numbers ride on the frame (`images[i].hires.pass_seconds`), and the
frame's `seconds` covers both of its passes.

**Where it cannot be used, and why** (a `400` naming `hires`, never a silent
no-op):

- an entry with `img2img_strength: false` — the FLUX.2 [klein] rows. Their
  pipeline has no `strength` parameter, so a second pass could not say how far
  from the first frame it may move. Klein edits through `image=` instead.
- a target over the entry's `max_pixels`. This bites earlier than it sounds:
  `sdxl-1.0` and `ssd-1b` cap at 2 MP, so **at 1024 px they have no room at all
  for a 1.5× second pass** (2048×2048 is 4.19 MP). Hires on those entries starts
  from 512–768 px.
- **A ~3600 px print target is not reachable this way.** A 12-inch full-front
  print at 300 dpi is ~3600 px, and the pipeline's own spec uses `dpi: 300` with a
  `max_colors` cap; the caps above are an order of magnitude short. The tiled
  upscale that could reach it (W2.4 in `docs/MODELS-PLAN.md`) is **not
  implemented**: tiles of ~512 px can show seams at their boundaries, and nothing
  here has measured them. Do not read `hires` as "print resolution" — it is "one
  more pass at 1.5–2×".

### `seeds` — a sweep

`"seeds": [1, 2, 3]` runs the request once per seed, in the order given, one frame
per seed (times `images`), on ONE load of the model, and returns the seed→file
mapping:

```json
"seeds": [1, 2, 3], "seed": null,
"seed_files": {"1": ["2026...-klein-4b-s1-01.png"],
               "2": ["2026...-klein-4b-s2-01.png"],
               "3": ["2026...-klein-4b-s3-01.png"]}
```

`seed` is `null` when a sweep ran: the sweep is described by `seeds`, and reporting
the first seed as "the seed" would be a half-truth. A request carrying BOTH `seed`
and `seeds` is a `400` — the two do not say which one is meant. **Nothing is
ranked:** no score, no ordering beyond the caller's own, and no endpoint that
compares frames. One frame is a sample; the operator picks.

### `provenance` — the record a later comparison reads

`"provenance": true` records, per frame, the fields a "which generation traced
best" comparison needs — model, seed, prompt, negative prompt, `ink_cap`, `hires`,
the requested AND the produced dimensions, the modifier set, the VAE, the sha256 —
in the response (`images[i].provenance`) and in a sidecar beside the PNG
(`<name>.json`, served by `GET /files/<name>.json`, so a frame's record travels
with the frame).

It is **implied** by any request that measured or changed the frame (`hires`,
`ink_cap`, `seeds`, or a `background` other than `keep`), because such a
comparison needs those numbers written down. A plain request writes neither the
field nor the file. Recording changes no pixel: a frame generated with
`provenance: true` is byte-identical to the same frame generated without it.

There is deliberately **no scoring surface**. The provenance holds inputs and
measurements — never a judgement, a rank, a score or a winner. The comparison
belongs to the pipeline (`chopshop-svg`'s tournament), which reads this.

**Who reads the requested/produced pair** (#11): two places, and neither is
silent now. The response's `warnings` names an ACTUAL mismatch — `1 of 1
frame(s) came back at a different size than asked: requested 512x512, produced
480x480 — sana-sprint-0.6b re-binned it (resolution binning)` — emitted only
for a `resolution_binning` entry and only when the size really differed, where
the request path's prospective "may not be honoured" warning fires for every
such entry whether or not anything was re-binned. The sidecar is the offline
half: what a later comparison, or a job view, reads after the fact. `hires`
never triggers it — changing the size is that pass's job, and its own report
carries `target`.

### The negative prompt: per-family defaults

The entries whose pipeline really has a `negative_prompt` parameter (`sdxl-1.0`,
`sdxl-turbo`, `sd-1.5`, `ssd-1b`) carry a **print-tuned default** in the registry,
sent when the request gives none: `gradients, soft shadows, photographic texture,
hairlines, blur`. It is a default, not a silent insertion:

- the response echoes the value that was actually SENT, and
  `negative_prompt_source: "default"` marks a substitution. A caller's own value
  is echoed without that field, exactly as before;
- `"negative_prompt": ""` is a deliberate **"send none"** — that is how a caller
  reproduces the pre-default request exactly;
- the entries with no such parameter (the klein rows, Sana Sprint) keep the
  existing answer: the value is **ignored, with a warning**, never honoured;
- `sdxl-turbo`'s default is sent like any SDXL's, but at its own guidance 0.0 no
  CFG pass runs, so it only acts if guidance is raised above 1.0.

This is the one change here that alters output for a request using none of the new
keys: on those four entries, a request carrying no negative prompt now sends one.
It is the point of the feature (`docs/MODELS-PLAN.md` §W2.6) and it is stated here
rather than left to be discovered; the determinism test uses the default entry
(`klein-4b`), which has no negative prompt at all. `/models` reports the default
per entry as `default_negative_prompt`.

### Concurrency

**One.** There is one GPU, so a second concurrent request waits on a lock rather
than over-subscribing VRAM, and `queue_wait_seconds` reports how long it waited.
Several images in one request are genuinely batched. `POST /unload` joins the
same queue — it takes the lock through `release()`, so it waits for an in-flight
generate rather than pulling the pipeline out from under it — and `/health`
reports `busy` while a generate holds it. Do not add GPU parallelism here: a
17 GB card running a 13 GB pipeline has no room to be clever.

## `POST /edit`

Image and text to image. Same fields as `/generate`, plus:

| field | type | notes |
|---|---|---|
| `image` | string **or list of string** | **required**, a `data:image/png;base64,...` URL — or a list of them, conditioned on as one set |

`modifiers`, `modifier_scales` and `vae` work here exactly as they do on
`/generate`, and are applied to the edit class the family names (`edit_pipeline`) —
so `StableDiffusionXLImg2ImgPipeline` gets the adapters, not the txt2img class.

```json
{ "prompt": "flatten to 6 flat colours and drop the background",
  "image": "data:image/png;base64,iVBORw0KGgo...",
  "width": 512, "height": 512 }
```

**Several references are one conditioning set, not a batch.** `image` accepts a
bare data URL (the shape every existing caller sends) or a list of them, and the
list keeps the caller's order — "the first is the pose and the second is the
palette" is a distinction only the caller can make, and the order is the whole of
it. Whether a model may be conditioned on several is a property of its checkpoint,
read from the `multi_reference` flag in `/models`: the FLUX.2 [klein] rows declare
a list in their `image=` and take any number; every img2img family (SDXL, SSD-1B,
SD 1.5, Sana Sprint) takes exactly one, so a second reference there is a `400`
naming the model — refused before the GPU is touched, never dropped quietly.

**How that is proven rather than asserted.** The plumbing is correct by
construction, so a unit test of it proves nothing about the checkpoint;
`scripts/smoke.py --multi-reference` is the measurement. It generates two
reference frames, then runs the same prompt, seed and steps conditioned on the
first alone and on both, and compares the two results:

- **different sha256 digests** — the second reference conditioned the
  generation. The mean per-channel pixel difference is printed beside the verdict
  so the *size* of the change is visible, not just its existence.
- **identical digests** — the pipeline read only `image[0]`. `multi_reference` is
  declared and not implemented on that checkpoint, and the run exits `5`.
- asked of a model whose row does not declare `multi_reference`, it declines
  before generating anything and reports `passed: null`. Not applicable is not
  the same claim as failed, and a caller that read `null` as a failure would turn
  every img2img row red.

`examples/prompts.json` carries the same capability as a runnable example
(`klein-dual-reference-edit`): its `reference` is a LIST, which is how a set
expresses "condition on both of these" without shipping rasters.

```json
{ "prompt": "use the pose from the first and the palette from the second",
  "image": ["data:image/png;base64,iVBORw0K...", "data:image/png;base64,iVBORw1..."] }
```

Response is the same shape, with `"edited": true` and `"references": <n>` — the
number of images that really conditioned the render, so a caller that sent a list
reads back that all of it was used. The reference is passed to the pipeline's
`image=`. For FLUX.2 [klein], text-to-image and editing are one model (`image=` is
the only difference); SDXL, SSD-1B, SD 1.5 and Sana Sprint take an SD-style
`image=` plus `strength=` instead.

A malformed data URL, a non-image payload, an empty list, or a missing `image` is
a `400`.

## `GET /files/<name>`

The generated image, as bytes. Serves **only** the flat basename inside
`CHOPSHOP_FLUX_OUT`: the name arrives over the network, so containment is checked
rather than assumed, and `..`, absolute paths and anything that resolves outside
the output directory is a `404`.

A frame's provenance sidecar (`<name>.json`, written only when provenance was
recorded) is served the same way, as `application/octet-stream` — so a frame's
record travels next to the frame. See "Output-side passes".

## `POST /unload`

Free the model. `{"unloaded": true, "status": {...}}`.

Useful because the load is the expensive part (~16 GB read from disk), so a box
that alternates between models pays it each time — and because a 17 GB card is
worth having back when nothing is generating.

**The unload takes the engine lock.** Generation is serialised on one lock (see
Concurrency), and the route calls `engine.release()` — `unload()` under that same
lock — rather than `unload()` bare. An unload arriving while a generate is
mid-flight therefore *waits its turn* instead of dropping the pipeline out from
under the running call, which was a real race before `release()` existed.
`unload()` remains the lock-free primitive because `load()` calls it while
already holding the lock (a lock inside it would deadlock — `threading.Lock` is
not reentrant), so a caller that already holds the lock keeps using `unload()`.
An engine that predates `release()` still unloads: the route falls back to
`unload()` when the method is absent.

**The release actually returns the memory**, which took three fixes to get right
and is the difference between a service that runs for weeks and one the kernel
kills:

- `gc.collect()` after dropping the pipeline. A diffusers pipeline sits in
  reference cycles (accelerate's offload hooks link modules back into each
  other), so `del` alone only decrements a count — the weights wait for the
  cyclic collector. Measured: an unload left 16.20 GiB ANONYMOUS, and the collect
  took it to 3.97 GiB.
- `malloc_trim` after that. Freeing is not returning: the tensors are gone but
  glibc keeps the arena, so RSS sat at 16.23 GiB until the pages were handed
  back. Best effort and a silent no-op off glibc.
- The idle seam and the host knobs below, which keep the arena from ever getting
  that large.

`status` reports `trimmed_on_unload` (`true` when the last release got pages back)
and `load_notes`, so "did the release actually take effect" is answerable from
the response rather than by watching RSS.

## Memory, lifetime and the environment

The service is configured entirely from the environment (nothing in the repo
names a host, port or path). The knobs that matter to a caller reasoning about
*when the model is resident* and *how much memory the process holds*:

| variable | default | meaning |
|---|---|---|
| `CHOPSHOP_FLUX_IDLE_UNLOAD` | `0` | seconds of no generation after which the loaded model is unloaded. `0` never unloads on idle — the weights stay in host RAM so the next generation skips the load. Set it positive on a box that shares its RAM, but know what was MEASURED: the unload does **not** return the memory. A successful unload still held 16.2 GB of ANONYMOUS memory (`RssAnon`), so the box stayed short by the weights' worth while the next request paid one load's latency. A daemon thread reads it at first load, so the default keeps the engine thread-free. |
| `CHOPSHOP_FLUX_IDLE_EXIT` | off | the half that returns the RAM: after an idle unload, MEASURE `RssAnon` and — only if it is still held above 1 GiB — drain and end the process so the unit's `Restart=on-failure` brings it back with the memory returned (MEASURED end to end: 16.22 GB → 0.01 GB, available RAM 28 → 43 GB). Off by default because it changes the service's lifecycle. |
| `CHOPSHOP_FLUX_DRAIN_SECONDS` | `5` | how long that decided exit keeps answering `503` with `kind: "restarting"` and `retry_after` before the process goes; `0` disables the drain. Sized against the measured ~5 s systemd restart delay, so the drain covers requests arriving just after the decision and the client's retry covers the gap after the process is really gone. |
| `MALLOC_MMAP_THRESHOLD_` | glibc's | set it to `131072` (128 KB) so every allocation over 128 KB goes back to `mmap`. Under thread-per-request, each generate otherwise allocates from a fresh glibc arena; forcing the large allocations to mmap is what makes a free an `munmap`. |
| `MALLOC_ARENA_MAX` | glibc's (up to 8× cores) | set it to `2` to cap the per-thread arenas. Without it the thread-per-request model grows one arena per request thread and none of them shrink. |
| `MemoryMax` | unset | a systemd `[Service]` cap (`MemoryMax=56G` on the 91 GiB box) — a **regression tripwire**, not a working limit. The service should never approach it; if it does, the unload path has regressed and the alternative is the OOM killer. |
| `PYTHONPATH` | unset | point it at a vendored dependency tree (`.vendor`) when the one missing package could not be installed into the GPU environment. |

`MALLOC_MMAP_THRESHOLD_` and `MALLOC_ARENA_MAX` are read by glibc **at process
start**, so they belong in the unit's environment (see `deploy/`) and cannot be
set through the API. Measured on the live service over four model switches after
these landed, the resident set is flat — floor 16.85 GiB, peak 31.79 GiB, cycle
after cycle — where before both climbed without limit. The remaining one-model
reservoir is an arena the allocator keeps and reuses, not a leak.

The other environment variables (bind, port, output dir, token, offload mode, VAE
tiling, the global pixel ceiling, the acknowledgement flag and `HF_HOME`) are
tabulated in the README's "Running the service" section; they are read at call
time too.

## Errors

```json
{ "error": "width must be a multiple of 16, got 1000", "kind": "bad_request" }
```

| status | `kind` | means |
|---|---|---|
| 400 | `bad_request` | bad model, bad size, bad prompt, unusable reference |
| 401 | `unauthorised` | missing or wrong bearer token |
| 404 | `not_found` | no such route, or no such file |
| 413 | `too_large` | body over `MAX_UPLOAD_BYTES` (32 MB) |
| 503 | `gpu_busy` | the GPU is held by another process; retry, do not fix the request |
| 503 | `restarting` | the service is draining before an idle-exit restart; `retry_after` says how many seconds to wait. No generation was started |
| 500 | `error` | generation failed, or something unexpected |

A `4xx` is a caller error and will not fix itself by retrying; a `5xx` is
generation failing. The client maps them to exit codes `2` and `5` respectively —
**except** a `restarting` 503, which the client waits out on the service's own
schedule (sleeping `retry_after`, capped at its own backoff step) and, if the
budget runs out, reports as exit
`3` (unreachable), not `5`: a step that lands in a restart window was not a
generation failure. A REFUSED connect is retried the same way
(`CHOPSHOP_FLUX_RECONNECT_ATTEMPTS`, default 4, linear
`CHOPSHOP_FLUX_RECONNECT_BACKOFF`, default 2 s × attempt — ~12 s against the
measured ~5 s window).

There are two `503` kinds and they mean different things. `restarting` is the
drain above; the client waits it out. `gpu_busy` is the guard's: the request was
well-formed and the *card* was not free. It only appears when the guard is set
to refuse (`CHOPSHOP_FLUX_GUARD=block`, or `wait` after its budget expired) — the
default `warn` never returns it. The message names the numbers and, when
`CHOPSHOP_FLUX_LMSTUDIO_URL` is set, the process holding the card. Retrying is
the right response; a queued caller should back off rather than spin. The client
deliberately does **not** auto-retry `gpu_busy` — waiting for a busy card is the
guard's decision, made against free VRAM, not the service's clock.
