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

### The `backend` field

Each `ModelSpec` carries a `backend` field:

| value | meaning |
|---|---|
| `"local"` | A diffusers checkpoint loaded on this box. The engine imports the pipeline class, loads weights, and runs inference locally. |
| `"novita"` | A hosted model reached over HTTP via `chopshop_flux/remote.py` (`NovitaClient`). No pipeline class, no weights, no VRAM. |

A remote model is another `model` key in the same registry; the routes are
unchanged. `POST /generate` and `POST /edit` dispatch on `backend` — `"local"`
goes through the diffusers engine, `"novita"` through the remote client. The
response shape is the same either way.

## Boundaries

- SwarmUI/ComfyUI surface (`chopshop-sui`) is deliberately absent.
- This layer produces sources; a human picks. No ranking, no judging.
- Host facts tagged `HOST-SPECIFIC`.
