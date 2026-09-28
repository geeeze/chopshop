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
to sell. Five entries across three families — FLUX.2 [klein], SDXL and SD 1.5 —
each with its own licence, resolution rules and calling convention.

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
      "edit_pipeline": null
    },
    { "key": "sdxl-1.0", "pipeline": "StableDiffusionXLPipeline",
      "edit_pipeline": "StableDiffusionXLImg2ImgPipeline",
      "dim_multiple": 8, "min_dim": 128, "negative_prompt": true,
      "img2img_strength": true, "...": "..." }
  ]
}
```

The family-specific fields — `pipeline`, `edit_pipeline`, `dim_multiple`,
`min_dim`, `max_pixels`, `negative_prompt`, `img2img_strength` — are the
per-model rules a client reads before calling, not optional hints.
`edit_pipeline` names the img2img class for a family that splits text-to-image
from image-to-image (SDXL, SD 1.5); `null` means one class serves both (klein).

## `POST /generate`

Text to image.

| field | type | default | notes |
|---|---|---|---|
| `prompt` | string | — | **required**, non-empty |
| `model` | string | `klein-4b` | key or alias (`4b`, `sdxl`, `sd-1.5`, …) |
| `width` / `height` | int | 1024 | within the model's own resolution rules (see `/models`) |
| `steps` | int | the model's | 4 for distilled klein, 2 for sdxl-turbo, 30 for SDXL |
| `guidance` | float | the model's | 1.0 for distilled klein, 0.0 for sdxl-turbo |
| `negative_prompt` | string | unset | works only where the model has one (`negative_prompt: true`) |
| `strength` | float | unset | img2img strength, SD-style models only |
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
same way — as a warning, not a silent drop.

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
