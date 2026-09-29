# MODELS_BRIEF_A — register or refuse the candidate checkpoints

You are working in **`chopshop-flux`** (private): the generation layer for the
chopshop print pipeline. One small HTTP service (`python -m chopshop_flux serve`)
plus `chopshop_flux`, a stdlib client. Read `AGENTS.md`, `CONTEXT.md` and
`docs/MODELS.md` before touching anything.

## The task

`docs/MODELS-PLAN.md` §2 lists five candidate checkpoints. Take **each one to a
decision**: a registry entry in `chopshop_flux/models.py`, or a documented refusal
in `docs/MODELS.md` §5. Silence is a failed task.

| candidate | what the HF API says | action |
|---|---|---|
| `Tongyi-MAI/Z-Image-Turbo` (6B, pipeline class `ZImagePipeline`) | `license: apache-2.0`, `gated: false`, core files ~33 GB (transformer stored fp32) | **register if it runs on the card** |
| `lodestones/Chroma1-HD` and `Chroma1-Flash` (8.9B, `ChromaPipeline`) | `license: apache-2.0`, `gated: false`, single-file transformer 17.80 GB bf16 | **prove or refuse** — 17.8 GB module vs a 17.10 GB card |
| `Qwen/Qwen-Image-2.1` (7B DiT + Qwen3-VL 8B encoder, RGBA VAE) | `license: other` = **Qwen Research License**, `gated: false`, ~33 GB | **read the licence first**; if commercial output is excluded it may only be an ACK-gated non-commercial entry, and the refusal/registration must say why |
| `black-forest-labs/FLUX.2-klein-9B` | FLUX Non-Commercial, **`gated: auto`** | **refuse** (gated + non-commercial), record why |
| `stabilityai/stable-diffusion-3.5-medium` | community licence, **`gated: auto`** | **refuse** (gated), record why |

## Measured facts you must not re-derive (they cost real time)

- The operating mode is `CHOPSHOP_FLUX_OFFLOAD=cpu`. **The footprint that matters
  is the largest SINGLE module**, not the vendor's headline VRAM: accelerate moves
  whole modules (transformer, then text encoder, then VAE), so a 24 GB model can
  fit while a 17.8 GB *module* cannot.
- `offload=none` does NOT fit even for the default model (MEASURED: 15.01 GiB
  allocated, VAE decode died with 174 MiB free).
- A step-count speedup MUST NOT be claimed: 4 steps vs 30 measured 11.2 s vs
  15.0 s under CPU offload (SDXL + LCM-LoRA, 512 px) — stage paging dominates.
- Guidance is a no-op on `klein-4b` and `sdxl-turbo` (distilled, CFG never runs);
  it IS honoured on the Sana entries (embedded) and on `klein-4b-base` (MEASURED:
  mean absolute pixel difference **34.38** between guidance 4.0 and 1.0).
- Several repos store fp32 weights, so `from_pretrained(..., torch_dtype=bfloat16)`
  halves the resident module while the DOWNLOAD stays the fp32 figure. Size the
  disk from the download, the VRAM from the bf16 module.
- The pipeline class's own defaults are the BASE model's schedule (e.g.
  `Flux2KleinPipeline` 50 / 4.0). Never let them through on a distilled checkpoint.
- Licence/gating/size facts come from the HF API, never from a model card's prose:
  `curl -s "https://huggingface.co/api/models/<repo_id>?blobs=true"`.

## How to measure (the GPU is on the other box)

The card is not on this host. The service's GPU environment is on `am5`, reached
over the tailnet, and `chopshop-flux` is cloned there at
`~/Documents/GitHub/chopshop-flux`:

```bash
# the GPU interpreter and HF_HOME the running service uses (read, never guess):
ssh monop@100.125.38.46 'systemctl --user show chopshop-flux.service -p Environment --value'
# the repo's own smoke runner — real weights, real timings, not a test:
ssh monop@100.125.38.46 'cd ~/Documents/GitHub/chopshop-flux && HF_HOME=<from above> \
  /home/monop/SwarmUI/dlbackend/ComfyUI/venv/bin/python scripts/smoke.py --json /tmp/smoke.json'
```

- **Do not install anything into that GPU environment** — it belongs to another
  project. `peft` and `accelerate` are already vendored beside the checkout
  (`.vendor`, put on `PYTHONPATH` by the service); reuse that.
- **Check free disk before any large download** (`df -h /` on am5). Measure the
  module sizes from the HF API FIRST and download only a candidate whose biggest
  module can fit — a 45 GB download for a model that cannot load is waste.
- **A blank frame is a failure, not a success**: check for CONTENT (a uniform PNG
  written with exit 0 is the failure mode a zero exit code hides).
- The card is shared with an LM Studio model. There is a guard
  (`CHOPSHOP_FLUX_GUARD*`) that refuses a load when another process holds the GPU;
  a refusal is a STATE, not a bug — do not unload anyone else's model, and re-run
  later instead.

## Deliverables

1. `chopshop_flux/models.py`: any new entry, in the existing shape — `pipeline`
   class, `edit_pipeline` if the family has one, resolution rules READ from that
   class's own signature (not copied from a sibling), and the
   `negative_prompt` / `img2img_strength` / `guidance_embedded` /
   `resolution_binning` flags as the class actually behaves. `notes` marks
   MEASURED vs ESTIMATE explicitly, with cold AND warm timings quoted together.
2. `docs/MODELS.md` §5: the outcome for EVERY candidate — including the refusals
   and the one-line reason. Add new entries to the §2 quality table honestly
   (ESTIMATE where they were not measured).
3. Tests: follow `tests/test_models_new.py`'s existing pattern for a new entry;
   every entry must validate and `/models` must keep its current JSON shape
   (three arrays) so an existing client does not break.

## Hard rules

- `python -m pytest` (or `.venv/bin/python -m pytest`) must be green; the suite
  needs no GPU, no torch, no network, and must stay that way.
- `engine.py` imports torch INSIDE methods, never at module scope — a test pins
  that importing the server works without torch.
- Never judge the art, never rank frames, never pick a winner.
- Never print or store a token.
- **Do NOT edit `AGENTS.md`** (write-guarded). If something belongs there, put it
  in `CONTEXT.md` and say so in your report.
- Do not commit anything; leave the working tree for review, and report the exact
  commands you ran and their output.
