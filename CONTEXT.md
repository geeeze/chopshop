# CONTEXT.md — chopshop-flux

Working state for agents and humans: what is in flight, what is blocked, and the
caveats that are not obvious from the code. Update this as work lands.

**Repo visibility: private.** The registry encodes licence facts and measured
machine behaviour — keep it out of the public `chopshop-svg` repo.

## What this repo is

The generation layer for the chopshop print pipeline: one small HTTP service with
our own API (six routes) and a registry spanning four diffusers families — FLUX.2
[klein], SDXL, SD 1.5 and Sana Sprint — across eight checkpoints (SSD-1B is an
SDXL-architecture entry, not a family of its own) — plus a second registry of LoRA
adapters and VAE swaps that can be applied on top of them, deliberately replacing
`chopshop-sui`'s SwarmUI/ComfyUI surface (no C# server, no generated workflow
wrapper, no queue). `python -m chopshop_flux serve` runs on the box with the GPU;
the same module as a client talks to it from anywhere. Two rules keep it opt-in:
**this layer calls the pipeline, the pipeline never calls it**, and **it never
judges the art** — it produces sources, a human picks.

## Work in progress

- **FIXED: the OOM kill (2026-09-29).** The service was killed by the kernel at a
  77.3 GiB peak on a 91 GiB box with no swap; earlier peaks were 63.8 and 35.3 GiB.
  `unload()` dropped the pipe with `del self._pipe` and released NOTHING: measured
  on the live service, one generate + unload left RSS at 16.81 GiB of which 16.23
  was ANONYMOUS (not cache), and it never came back. Each model switch — or any
  change to the (model, edit, modifiers, vae) key — therefore added ~16 GiB
  permanently, which is exactly what the recorded peaks are: 2 / 4 / 5 cycles.
  Three faults, three fixes:
  - **`gc.collect()` in `unload()`** (`#flux-unload-collect`). A diffusers pipeline
    sits in reference cycles, so `del` only decrements a count and the weights wait
    for the cyclic collector. Measured: 16.20 GiB anon -> 3.97 after the collect,
    and a second collect frees 0 objects, i.e. the cycles are broken.
  - **`malloc_trim` after it** (`#flux-unload-trim`). Freeing is not returning: the
    tensors were gone (11 live modules, `gc.collect` freeing 0) with RSS still at
    16.23 GiB, because the allocator keeps the arena. Best effort, no-op off glibc.
  - **`/unload` now takes the engine lock** (`#flux-unload-locked`). The route
    called `unload()` outside the lock that serialises generation, so an unload
    could drop the pipeline out from under a running `_run`. `release()` is the
    locked form; `load()` still uses the lock-free `unload()` internally (a lock
    inside it would deadlock, `threading.Lock` being non-reentrant).
  - The host side got the rest: `CHOPSHOP_FLUX_IDLE_UNLOAD=900` (the weights were
    resident forever), `MALLOC_MMAP_THRESHOLD_=131072` and `MALLOC_ARENA_MAX=2`
    (thread-per-request means each generate allocates from a fresh glibc arena;
    forcing every allocation over 128 KB back to mmap is what makes a free an
    munmap), and `MemoryMax=56G` on the unit as a regression tripwire.
  Measured on the live service over four model switches, after: the resident set
  is FLAT — floor 16.85 GiB and peak 31.79 GiB, cycle after cycle, where before
  both climbed without limit. What remains is a one-model reservoir the arena
  keeps and REUSES (identical cycles 3 and 4 prove the reuse); it is not a leak
  and it does not grow. If the idle floor ever wants to be smaller,
  `MALLOC_TRIM_THRESHOLD_` is the next knob, not more collecting.
  Pinned by `tests/test_engine.py` (the collect, its order, the trim, the
  lock-free-vs-locked pair) and `tests/test_server.py` (the route uses `release`,
  and an engine without it still unloads).

- LANDED: the registry grew from five entries to eight (`sana-sprint-0.6b`,
  `sana-sprint-1.6b`, `ssd-1b`); `chopshop_flux/modifiers.py` registers 14 LoRA
  adapters and 5 VAE swaps with their own licence gate; `engine.generate`/`load`
  apply modifiers, install the scheduler an adapter needs and swap the VAE; the
  CLI gained `modifiers`, `vaes` and `examples`; six print-oriented styles landed;
  and `examples/prompts.json` + `chopshop_flux/examples.py` +
  `scripts/smoke_examples.py` are the machine-readable example/test prompt set,
  its validator and its GPU smoke run. Tests 135 -> 334.
- FIXED after review: the VAE licence gate fired only in `generate()`, so
  `engine.load(vae=<non-commercial>)` loaded one with no acknowledgement while
  `generate` refused the same request — the gate is now on the load path and a
  test fails if it is removed. `smoke_examples.py` never applied a `style`, so
  eight rows claiming the style did the work were run bare and still reported
  PASS; the suffix is now composed exactly as the CLI composes it, and the report
  prints the style and the composed prompt so the claim is auditable.
- LANDED: the AGENTS.md hard rule — comments are section-level WHY blocks with a
  `#label-name-function` breadcrumb at cross-file call sites, never line-by-line
  narration (commit f671597, with the Agent-skills block and the `docs/agents/`
  seeds).
- LANDED: the `models.py` header note that chopshop-studio's
  `app/models/flux_conf.rb` hand-mirrors this registry, with nothing to sync it.
  That note is the only warning a reader gets before editing the registry and
  silently letting the studio drift.
- **Doc pass (2026-09-29, this repo's tree): `docs/API.md` and
  `docs/agents/domain.md` were brought back level with the code.** API.md now
  lists the six routes explicitly (verified against `server.py`: `/health`,
  `/models`, `/generate`, `/edit`, `/files/<name>`, `/unload` — there is no
  `/load`), documents `release()` and the lock `/unload` takes, documents the
  multi-reference `image` form and the `references` echo, adds the
  measured-vs-estimated ledger the registry `notes` carry, and has a
  "Memory, lifetime and the environment" section for `CHOPSHOP_FLUX_IDLE_UNLOAD`,
  `MALLOC_MMAP_THRESHOLD_`, `MALLOC_ARENA_MAX`, `MemoryMax` and `PYTHONPATH`.
  `domain.md` gained the repo-specific "This repo" section (single-context, the
  private-registry rule, the studio mirror). The four host memory knobs were also
  written into `deploy/chopshop-flux.service` and the `EnvironmentFile` example:
  they were set on the live host but absent from the committed unit, so a fresh
  deploy regressed the OOM fix. **Still outstanding: `AGENTS.md` itself** — its
  Layout table (`modifiers.py`, `examples.py`, `scripts/smoke_examples.py` and the
  `modifiers`/`vaes`/`examples` CLI commands are missing), its licence hard rule
  (SSD-1B and the Sana rows are Apache-2.0 too) and its missing unload/memory
  hard rule are stale, and an automated edit was blocked (it is a protected
  agent-instruction file). A human or a consented session should land those three.
- **The example set and the modifier registries are NOT yet proven on hardware as
  a set.** The 0.6B Sana row and the SDXL + LCM/Lightning paths were measured; the
  rest is registered from probed facts. `scripts/smoke_examples.py` is the script
  that closes that gap, and it will produce `examples-report.json` / `.md`.
- Deliberate holds, not backlog: VAE tiling and an fp32 decode are unverified /
  not done (see Caveats); SSD-1B's VRAM figure and the Sana 1.6B VRAM figure are
  estimates; the Sana VAE scale factor is inferred from the encoder block count
  rather than measured. SSD-1B's step/guidance figures are NOT estimates any more
  — they were measured on the box (25 / 7.5 at 1024px: 6.1s first call, 4.4s
  after) and `models.py` says so; this line lagged that correction.

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
- **Multi-model registry, per-family rules — never global.** Eight entries:
  `klein-4b` (default), `klein-4b-base`, `sdxl-1.0`, `sdxl-turbo`, `sd-1.5`,
  `ssd-1b`, `sana-sprint-0.6b`, `sana-sprint-1.6b`.
  FLUX.2 [klein] does 64×64–4 MP on multiples of 16; SDXL, SSD-1B and SD 1.5
  floor at 128, multiples of 8, 1–2 MP cap; **Sana Sprint floors at 512, multiples
  of 32, 1 MP cap** — its VAE is a 32×-downsampling `AutoencoderDC`, not an 8×
  `AutoencoderKL`, which is where that rule comes from rather than from taste.
  Violating a model's own rules is a `400` (a caller error), not a failed
  generation.
- **LoRA adapters and VAE swaps are a second registry, gated the same way.**
  `modifiers.py` holds 14 adapters and 5 VAEs, each with its own `repo_id`,
  exact weight filename and **its own licence**. An adapter does not inherit the
  checkpoint's licence, so `commercial_ok` is per entry and
  `modifiers.check_modifier_usable` is the same gate as `models.check_usable` —
  one gate, one env var, no weaker copy. Modifiers are the *only* part of this
  registry that cannot be verified without downloading something: a wrong
  `weight_name` fails at load time, not at import.
- **The order of operations in `engine.load()` is a measured fact, not style.**
  scheduler → `load_lora_weights` per modifier → `set_adapters(scales)` → VAE →
  **`enable_model_cpu_offload()` last**. Assigning `pipe.vae` after the offload
  leaves the new VAE outside accelerate's device map and the *next* pipeline call
  dies inside the scheduler step with "Expected all tensors to be on the same
  device, but found at least two devices, cuda:0 and cpu!" — a message that names
  everything except the VAE. Re-applying `enable_model_cpu_offload()` after the
  assignment is the verified fix for that case; the scheduler is NOT in the device
  map, so swapping it after the offload is fine and needs no such treatment.
- **An LCM or Lightning adapter is its scheduler.** `lcm-lora-*` needs
  `LCMScheduler` and `sdxl-lightning-*` needs `EulerDiscreteScheduler` with
  `timestep_spacing="trailing"`; the requirement rides on the registry entry so it
  cannot be forgotten. Loading one without its scheduler produces noise, not a
  cheap image. Measured on SDXL at 512×512: 30-step base 15.0s, 4-step LCM-LoRA
  11.2s, a repeated 4-step call 1.3s — **4 steps is not 4× faster than 30 here**,
  because under CPU offload per-step compute is not the bottleneck. Do not quote a
  speed-up the numbers do not show.
- **Sana Sprint is distilled but its guidance is NOT ignored.** It takes
  `guidance_scale` as a guidance *embedding* (`guidance_embeds_scale`) with no CFG
  pass, so the registry's `guidance_embedded` flag suppresses the "guidance is
  ignored" warning for it and the warning still fires for klein and sdxl-turbo.
  Measured on the 0.6B: `from_pretrained` 3.7s, offload ~0s, 1024×1024 at 2 steps
  / guidance 4.5 takes **~40s on the first call after a load and ~2.5s after**
  (512×512 ~2.1s), 15.58 GB of 17.10 GB VRAM free between calls, every frame
  non-blank. It has **no `negative_prompt` parameter** — confirmed from `__call__`'s
  signature — and `use_resolution_binning` defaults to True, so a requested size
  can be silently re-binned to a bucket. Both are recorded as caveats and the
  binning one is warned about at request time.
- **A tiny VAE is a different class, not a smaller file.** `taesd*` loads through
  `AutoencoderTiny`; the rest through `AutoencoderKL`. It decodes visibly softer,
  which lands exactly on the edges a tracer needs — a trade, not a free speed-up.
- **VAE `repo_bytes` is the download, not the repo total.** `sdxl-vae-fp16-fix` is
  a 1.34 GB repo whose real cost is one 334.7 MB file; the larger number would make
  every swap look unaffordable.
- **Distilled checkpoints need their own schedule:** `klein` is 4 steps /
  guidance 1.0 and `sdxl-turbo` 2 steps / 0.0 — the registry's defaults.
  `Flux2KleinPipeline.__call__` defaults to 50 / 4.0 because that is what a *base*
  model wants; letting the class defaults through is the wrong schedule.
- **The licence gate is not advisory.** 4B, SSD-1B and Sana Sprint (Apache-2.0),
  SDXL (Open RAIL++-M) and SD 1.5 (Open RAIL-M) allow commercial output;
  `sdxl-turbo` — the fastest entry here — is Stability NC Research. Loading a
  non-commercial model **or a non-commercial LoRA or VAE** requires
  `CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1`, checked in `models.check_usable` and
  `modifiers.check_modifier_usable` so it holds on every path that loads
  something, not just in the view. Do not make it implicit. Two licence facts that
  look like they should be reclassified and must not be:
  `stabilityai/sdxl-turbo`'s card (`other` / `sai-nc-community`) disagrees with the
  licence file it currently serves (Stability AI Community License, commercial
  below $1M revenue) — the repo stays conservative and records the disagreement;
  and `stabilityai/sd-turbo` is **not registered at all** because its licence is
  undecidable from the repo (no card field, README and LICENSE.md disagree).
- **Sana Sprint's Apache-2.0 covers the weights, not the text encoder.** That is
  Gemma-2 under Google's Gemma Terms of Use, a pass-through condition riding along
  with the model. It is in the entries' `notes` rather than left to be discovered.
- **Deliberately not registered, with the reason recorded:** `stabilityai/sd-turbo`
  (undecidable licence), `ostris/ikea-instructions-lora-sdxl` (`other`, so
  undecidable), `ByteDance/Hyper-SD` (no licence field at all), `PixArt-alpha/*`
  (a T5-XXL encoder dominating disk and VRAM for a superseded architecture),
  `Alpha-VLLM/Lumina-Image-2.0` (31.7 GB), `sta/stable-diffusion-3.5-medium`
  (gated), `black-forest-labs/FLUX.1-schnell` (gated + 57.8 GB), `tianweiy/DMD2`
  (CC-BY-NC), `black-forest-labs/FLUX.2-klein-9B` (~24 GB against a 17 GB card).
  There is no 1-step SDXL-Lightning LoRA either — the 1-step artifact is a ~5.1 GB
  full UNet, which is a replacement model rather than a modifier.
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
  variables read at call time. The download sizes in the table are not resident
  footprints; what is measured is that the klein family, the Sana 0.6B, SSD-1B and
  klein-4b-base all RUN on the 16 GB card, with the timings recorded in the
  registry notes. The remaining figures are estimates, noted per entry.
- **Never `pkill -f <pattern>` when the pattern is in your own command line** — it
  matches your own shell and kills it. Kill by port:
  `ss -ltnp | grep ':<port>' | grep -oP 'pid=\K[0-9]+' | head -1`.
