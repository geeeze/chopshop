# CONTEXT.md — chopshop-flux

Working state for agents and humans: what is in flight, what is blocked, and the
caveats that are not obvious from the code. Update this as work lands.

**Repo visibility: private.** The registry encodes licence facts and measured
machine behaviour — keep it out of the public `chopshop-svg` repo.

## What this repo is

The generation layer for the chopshop print pipeline: one small HTTP service with
our own API (six routes) and a registry spanning three diffusers families —
FLUX.2 [klein], SDXL, SD 1.5 — deliberately replacing `chopshop-sui`'s
SwarmUI/ComfyUI surface (no C# server, no generated workflow wrapper, no queue).
`python -m chopshop_flux serve` runs on the box with the GPU; the same module as
a client talks to it from anywhere. Two rules keep it opt-in: **this layer calls
the pipeline, the pipeline never calls it**, and **it never judges the art** — it
produces sources, a human picks.

## Work in progress

- No tracked in-flight feature. The registry, the styles bundled from
  `chopshop-sui`'s `swarm_styles.json`, and the systemd user-unit toggle have landed.
- In-flight but uncommitted, in this repo's own tree: a new AGENTS.md hard rule —
  comments are section-level WHY blocks with a `#label-name-function` breadcrumb at
  cross-file call sites, never line-by-line narration.
- Deliberate holds, not backlog: VAE tiling and an fp32 decode are unverified /
  not done (see Caveats); the SDXL and SD 1.5 VRAM figures are estimates.

## Blockers

- None known.

## Caveats / known issues

- **The default model is guidance-distilled (CFG ~1.0), so a negative prompt has
  little effect.** `is_distilled` comes from the repo's `model_index.json` (`true`
  for klein-4B) and gates `do_classifier_free_guidance` (`guidance_scale > 1 and
  not is_distilled`), so CFG never runs and diffusers logs "Guidance scale X is
  ignored" — there is nothing to wire. Steering goes into the positive prompt plus
  the source image; the service says so in `warnings` rather than accepting a knob
  it silently drops.
- **Multi-model registry, per-family rules — never global.** Six entries:
  `klein-4b` (default), `klein-4b-base`, `klein-9b`, `sdxl-1.0`, `sdxl-turbo`,
  `sd-1.5`. FLUX.2 [klein] does 64×64–4 MP on multiples of 16; SDXL and SD 1.5
  floor at 128, multiples of 8, 1–2 MP cap. Violating a model's own rules is a
  `400` (a caller error), not a failed generation.
- **Distilled checkpoints need their own schedule:** `klein` is 4 steps /
  guidance 1.0 and `sdxl-turbo` 2 steps / 0.0 — the registry's defaults.
  `Flux2KleinPipeline.__call__` defaults to 50 / 4.0 because that is what a *base*
  model wants; letting the class defaults through is the wrong schedule.
- **The licence gate is not advisory.** 4B (Apache-2.0), SDXL (Open RAIL++-M) and
  SD 1.5 (Open RAIL-M) allow commercial output; the 9B is FLUX Non-Commercial
  v2.1 and `sdxl-turbo` is Stability NC Research. Loading a non-commercial model
  requires `CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1`, checked in `models.check_usable`
  so it holds on every path that loads a model. Do not make it implicit.
- **The 9B is HF-gated and needs CPU offload** (~24 GB at bf16). Its quantised
  single-file builds (`-fp8`, `-nvfp4`) have **no `model_index.json`**, so
  `from_pretrained` cannot load them at all; `GET /models` reports them under
  `unloadable` *with the reason*, because the question comes up.
- **Binds `127.0.0.1:8795` by default — loopback on purpose** (`8791` is
  `chopshop-svg`'s runner, `8790` the studio's mock). Reaching it from another
  machine is an explicit act: set `CHOPSHOP_FLUX_BIND` to the private address
  **and** set `CHOPSHOP_FLUX_TOKEN`; `CHOPSHOP_FLUX_OUT` is the only tree
  `/files/` serves.
- **`/health` is unauthenticated on purpose.** With a bind and token set,
  `/generate`, `/edit` and `/models` answer `401` without the header, `/health`
  does not — it reports `auth_required`, so a monitor can ask whether the box is
  up without holding a credential. The routes that cost GPU time are guarded.
- **`accelerate` is absent from the environments here**, so diffusers refuses
  `enable_model_cpu_offload()` (worded as a version requirement — misleading; the
  package is simply missing). Hard rule: **never modify the GPU environment**.
  Vendor it (`pip install --no-deps --target .vendor`, put it on `PYTHONPATH`);
  verified afterwards that the other environment still cannot import it alone.
- **Resident (`offload=none`) does not fit:** the weights are 15.97 decimal GB
  against a 15.92 GiB card — all four denoise steps complete, then VAE decode has
  ~174 MiB left. `offload=cpu` is the operating mode, not a preference.
- **Do not set `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` here.** Added
  while chasing the resident OOM, it caused *intermittent NaN in the VAE decode* —
  a uniform black PNG announced only as a `RuntimeWarning`. A mitigation you cannot
  verify is just a second variable.
- **`Flux2KleinPipeline` has no `enable_vae_tiling()`** — the switch is on the VAE
  (`pipe.vae.enable_tiling()`); the obvious call raises `AttributeError` and
  tiling silently never happens. `CHOPSHOP_FLUX_VAE_TILING` is off by default and
  **unverified at these sizes**. A naive fp32 decode is likewise **not done**: the
  config declares `force_upcast: True` but the latents leave denoise as bf16, so
  `pipe.vae.to(torch.float32)` fails on an input/bias dtype mismatch — bf16 decode
  measured clean over 24 frames, so do it only if NaN is actually observed.
- **`torch_dtype` as the dtype object, not the string** — `"bfloat16"` is silently
  ignored and everything loads fp32. `Flux2KleinPipeline` is the t2i *and* edit
  pipeline (`image=None` vs `image=<PIL>`); `/edit` is not a second model.
- **Tests run with no torch, GPU, models or network.** `engine.py` imports torch
  inside methods, never at module scope, and the server takes an injected engine;
  `test_importing_the_server_does_not_import_torch` pins that. A module-level
  `import torch` in `chopshop_flux/` breaks the suite everywhere but the GPU box.
  `scripts/smoke.py` is not a test — it loads real weights and must not become one.
- **Nothing in the repo names a host, port or path belonging to one machine** —
  bind, port, output dir, model, offload mode and pipeline root are all environment
  variables read at call time. klein VRAM figures are measured; the SDXL / SD 1.5
  ones are estimates, noted per entry.
- **Never `pkill -f <pattern>` when the pattern is in your own command line** — it
  matches your own shell and kills it. Kill by port:
  `ss -ltnp | grep ':<port>' | grep -oP 'pid=\K[0-9]+' | head -1`.
