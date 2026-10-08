# chopshop-flux — Interface Contract

Generation layer only. Calls the pipeline; the pipeline never calls it. Never judges art.

## HTTP routes (stdlib http.server, `chopshop_flux serve`)

| Method | Path | Purpose |
|---|---|---|
| GET  | /health  | liveness probe (token-covered) |
| GET  | /models  | list registry checkpoints |
| POST | /generate| text-to-image source |
| POST | /edit    | img2img / inpaint edit |
| POST | /unload  | free VRAM for a checkpoint |

Auth: bearer token checked FIRST, before route and body.

## Model registry (`chopshop_flux/models.py`)

Families: FLUX.2 [klein], SDXL, SD 1.5, Sana Sprint, Z-Image (9 checkpoints;
SSD-1B is an SDXL-architecture entry). Second registry: LoRA adapters + VAE swaps.

`REGISTRY: dict[str, ModelSpec]` in models.py is the source of truth.

## Boundaries

- SwarmUI/ComfyUI surface (`chopshop-sui`) is deliberately absent.
- This layer produces sources; a human picks. No ranking, no judging.
- Host facts tagged `HOST-SPECIFIC`.
