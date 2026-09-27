# AGENTS.md — orientation for an AI agent

You are working in **chopshop-flux**, the generation layer for the
[chopshop](https://github.com/geeeze/chopshop-svg) print pipeline. Read this
before touching code; it encodes hard rules and measured facts that cost real
time when rediscovered.

## What this is, in one paragraph

A narrow FLUX.2 [klein] runner. `chopshop_flux serve` runs a small HTTP service
(next to the GPU); `chopshop_flux` as a client talks to it from anywhere. The
model family is klein only, the API is ours (six routes), and the SwarmUI/ComfyUI
surface that `chopshop-sui` built is deliberately absent. Two rules keep it
opt-in: **this layer calls the pipeline, the pipeline never calls it**, and **it
never judges the art** — it produces sources, a human picks.

## Hard rules

- **Never modify the GPU environment this runs against.** On the dev box that is
  ComfyUI's venv under `~/SwarmUI/dlbackend/`, which SwarmUI's own rules say must
  not be modified. Use its interpreter; do not `pip install` into it. This is why
  `requirements.txt` pins only pytest.
- **`engine.py` imports torch inside methods, never at module scope.** The whole
  test suite depends on it: `import chopshop_flux.server` has to work on a
  machine with no GPU and no torch. `test_importing_the_server_does_not_import_torch`
  pins it. A module-level `import torch` anywhere in `chopshop_flux/` breaks this.
- **The tests must run with no GPU, no torch, no models and no network.** The
  engine is injected into the server; the client's network is two methods.
- **Nothing in the repo names a host, a port or a path belonging to one machine.**
  Bind address, port, output dir, model and pipeline root are all environment
  variables read at call time. A repo that hardcodes a machine goes stale the
  moment that machine moves.
- **The licence gate is not advisory.** 4B is Apache-2.0; the 9B is FLUX
  Non-Commercial. Loading a non-commercial model requires
  `CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1`, checked in `models.check_usable` so it
  holds on every path that loads a model, not just in the view. Do not move it
  or make it implicit.
- **Do not weaken a caveat into a knob.** Guidance > 1.0 on a distilled model is
  ignored by the pipeline; the service says so in `warnings` rather than
  pretending to honour it.
- **Never `pkill -f <pattern>` when the pattern is in your own command line** —
  it matches your own shell and kills it (exit -15; happened twice on this
  project's sibling). Kill by port:
  `ss -ltnp | grep ':<port>' | grep -oP 'pid=\K[0-9]+' | head -1`.

## Measured facts on this box (Radeon RX 9070 XT, gfx1201, RDNA4)

- torch reports the card as `15.92 GiB` = `17.10 GB`. **Watch the units** — the
  weights are 15.97 *decimal* GB = 14.87 GiB, so "16 GB of weights in a 17 GB
  card" is not the comparison it looks like. `torch.cuda.get_device_name(0)`
  returns `AMD Radeon Graphics`; an iGPU also enumerates, so read the name.
- **`accelerate` is NOT installed in any environment on this box.** That means
  `enable_model_cpu_offload()` raises `ImportError` (diffusers words it as a
  version requirement, which is misleading — the package is simply absent).
  `engine.offload_unavailable_message` names the interpreter and the alternative
  because diffusers' own message names neither.
- **Do not set `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` on this box.**
  It was added while chasing the resident-mode OOM, and it caused *intermittent
  NaN in the VAE decode* — a uniform black PNG written as a success, announced
  only as `RuntimeWarning: invalid value encountered in cast`. Removed, and
  24 consecutive frames then came back with 0 blank frames and 0 NaN warnings. It
  is an experimental allocator setting on ROCm; a mitigation you cannot verify is
  just a second variable.
- **Resident (`offload=none`) at 512×512, 4 steps does not fit:** all four denoise
  steps complete with 15.01 GiB allocated, then VAE decode dies with 174 MiB free.
  `offload=cpu` is the operating mode; the numbers are in the README.
- **`Flux2KleinPipeline` has no `enable_vae_tiling()`** — the switch is on the VAE
  (`pipe.vae.enable_tiling()`). The obvious call raises AttributeError and tiling
  silently never happens, which is what `engine.status()["load_notes"]` exists to
  catch. Tiling is off by default until something measured asks for it.
- **The VAE's config declares `force_upcast: True`** (fp32 decode) and the pipeline
  never applies it, but a naive `pipe.vae.to(torch.float32)` **breaks**: the
  latents leave the denoise loop as bf16 and nothing casts them, so decode fails
  with `Input type (c10::BFloat16) and bias type (float) should be the same`.
  Doing it properly means taking over the decode (`output_type="latent"`, cast,
  decode). Not done, because bf16 decode measured clean over 24 frames — do it
  only if NaN is actually observed.
- **`Flux2KleinPipeline` is the t2i *and* edit pipeline**: `image=None` is
  text-to-image and `image=<PIL>` is an edit. There is no second model.
- Passing `torch_dtype` as a **string** (`"bfloat16"`) is silently ignored here and
  everything loads fp32; pass the torch dtype object. `torch_dtype` itself emits a
  FutureWarning pointing at `dtype` — left as-is because it is verified working.
- **`is_distilled` comes from the repo's `model_index.json`** (`true` for
  klein-4B), and it gates guidance: `do_classifier_free_guidance` is
  `guidance_scale > 1 and not is_distilled`, so no CFG ever runs for a distilled
  checkpoint and diffusers logs "Guidance scale X is ignored". That is the whole
  reason a negative prompt has no effect — there is nothing to wire.
- **The pipeline class defaults to 50 steps / guidance 4.0**, which is the *base*
  model's schedule. Registry defaults (4 / 1.0) override it; never let the class
  defaults through on a distilled checkpoint.
- On-disk weights: `HF_HOME` is `/home/monop/models/hf` here. The klein-4B
  download needed `model_index.json` fetched **separately** — an `hf download
  --include "model_index.json"` with a bare filename pattern does not match, and
  `from_pretrained` then fails with a confusing error. Use `hf_hub_download` for a
  single file.
- Report timings with `scripts/smoke.py`, which loads real weights and prints
  what the machine did. It is not a test and must not become one.

## Layout

| path | what |
|---|---|
| `chopshop_flux/config.py` | every environment variable, read at call time |
| `chopshop_flux/models.py` | the registry: licences, VRAM, resolution rules |
| `chopshop_flux/engine.py` | the diffusers seam; the only module that touches torch |
| `chopshop_flux/server.py` | the HTTP service; stdlib only, engine injected |
| `chopshop_flux/client.py` | stdlib client; the network is two methods |
| `chopshop_flux/cli.py` | `serve`, `health`, `models`, `generate`, `edit`, `gen2pipe` |
| `docs/API.md` | the wire format |
| `scripts/smoke.py` | real weights, real timings |

## Running

```bash
.venv/bin/python -m pytest                       # no GPU, torch, models or network
HF_HOME=... /path/to/gpu-venv/bin/python scripts/smoke.py   # needs the GPU
```

Exit codes, shared with `chopshop-sui`'s bridge so one script handles both:
`0` ok, `2` usage, `3` unreachable, `4` model missing, `5` generation failed.

## Not in scope, and why

Tracing/gating/ranking (that is `chopshop-svg`), the studio's runner contract
(generation is not trace-and-validate), and the studio's GUI. Style recipes
(`chopshop-sui`'s `swarm_styles.json`) are the obvious next reuse and are
deliberately deferred until the generation path is proven on real output.
