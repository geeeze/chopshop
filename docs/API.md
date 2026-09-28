# chopshop-flux HTTP API

Six routes, JSON bodies, one GPU. This is the whole surface — nothing here is
optional and nothing here is a placeholder.

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
    "vram_free_gb": 15.88
  }
}
```

`device_name` is reported because torch presents a ROCm GPU as `cuda`, and an
integrated GPU can enumerate as a device too — never assume device 0 is the card
you meant, read what it says it is. `rocm` is non-null when `torch.version.hip`
is set.

## `GET /models`

The registry, with the licences. Read this before generating something you intend
to sell. Three arrays: `models` (eight entries across five families — FLUX.2
[klein], SDXL, SD 1.5, Sana Sprint and SSD-1B), `modifiers` (the LoRA adapters)
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
      "edit_pipeline": null
    },
    { "key": "sdxl-1.0", "pipeline": "StableDiffusionXLPipeline",
      "edit_pipeline": "StableDiffusionXLImg2ImgPipeline",
      "dim_multiple": 8, "min_dim": 128, "negative_prompt": true,
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
      "repo_bytes": 393854592,
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
      "repo_bytes": 9793292,
      "tiny": true,
      "aliases": ["taesd-xl", "tiny-sdxl"],
      "notes": "..."
    }
  ]
}
```

The family-specific fields — `pipeline`, `edit_pipeline`, `dim_multiple`,
`min_dim`, `max_pixels`, `negative_prompt`, `img2img_strength` — are the
per-model rules a client reads before calling, not optional hints.
`edit_pipeline` names the img2img class for a family that splits text-to-image
from image-to-image (SDXL, SSD-1B, SD 1.5); `null` means one class serves both
(klein). Sana Sprint names an edit class too, and its rules are its own:
multiples of 32, a 512 floor, a 1 MP cap.

Two flags exist because they contradict an assumption the earlier responses
encouraged:

| field | means |
|---|---|
| `guidance_embedded` | the model is distilled **but acts on `guidance_scale`** anyway, through a guidance embedding rather than a CFG pass. Sana Sprint is `true`. Where this is `true` the "guidance is ignored" warning does **not** fire, because it would be false. |
| `resolution_binning` | the pipeline silently re-bins a requested size to its own training buckets, so the returned image's `width`/`height` may not be the requested ones. Sana Sprint is `true`; the service warns when the model is used. |

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
| `modifiers` | array of string | unset | LoRA adapter keys, applied in the order given |
| `modifier_scales` | object | unset | adapter weight per modifier, `{"lcm-lora-sdxl": 0.8}` |
| `vae` | string | unset | a VAE key to swap in (see `vaes` in `/models`) |
| `seed` | int | random | always reported back, so a result is reproducible |
| `images` | int | 1 | batched in one call — the cheap kind of parallelism |

```json
{
  "model": "klein-4b",
  "license": "Apache-2.0",
  "commercial_ok": true,
  "prompt": "a phoenix emblem",
  "width": 512, "height": 512,
  "steps": 4, "guidance": 1.0, "seed": 1234567,
  "edited": false,
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
pipeline may re-bin, and a step/guidance pair that contradicts a loaded adapter's
own schedule.

### Concurrency

**One.** There is one GPU, so a second concurrent request waits on a lock rather
than over-subscribing VRAM, and `queue_wait_seconds` reports how long it waited.
Several images in one request are genuinely batched. Do not add GPU parallelism
here: a 17 GB card running a 13 GB pipeline has no room to be clever.

## `POST /edit`

Image and text to image. Same fields as `/generate`, plus:

| field | type | notes |
|---|---|---|
| `image` | string | **required**, a `data:image/png;base64,...` URL |

`modifiers`, `modifier_scales` and `vae` work here exactly as they do on
`/generate`, and are applied to the edit class the family names (`edit_pipeline`) —
so `StableDiffusionXLImg2ImgPipeline` gets the adapters, not the txt2img class.

```json
{ "prompt": "flatten to 6 flat colours and drop the background",
  "image": "data:image/png;base64,iVBORw0KGgo...",
  "width": 512, "height": 512 }
```

Response is the same shape, with `"edited": true`. The reference is passed to the
pipeline's `image=`. For FLUX.2 [klein], text-to-image and editing are one model
(`image=` is the only difference); SDXL and SD 1.5 take an SD-style `image=` plus
`strength=` instead.

A malformed data URL, a non-image payload or a missing `image` is a `400`.

## `GET /files/<name>`

The generated image, as bytes. Serves **only** the flat basename inside
`CHOPSHOP_FLUX_OUT`: the name arrives over the network, so containment is checked
rather than assumed, and `..`, absolute paths and anything that resolves outside
the output directory is a `404`.

## `POST /unload`

Free the model. `{"unloaded": true, "status": {...}}`.

Useful because the load is the expensive part (~16 GB read from disk), so a box
that alternates between models pays it each time — and because a 17 GB card is
worth having back when nothing is generating.

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
| 500 | `error` | generation failed, or something unexpected |

A `4xx` is a caller error and will not fix itself by retrying; a `5xx` is
generation failing. The client maps them to exit codes `2` and `5` respectively.
