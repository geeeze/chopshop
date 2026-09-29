# AGENTS.md — orientation for an AI agent

You are working in **chopshop-flux**, the generation layer for the
[chopshop](https://github.com/geeeze/chopshop-svg) print pipeline. Read this
before touching code; it encodes hard rules and measured facts that cost real
time when rediscovered.

## What this is, in one paragraph

A small generation runner. `chopshop_flux serve` runs a small HTTP service
(next to the GPU); `chopshop_flux` as a client talks to it from anywhere. The
registry spans four diffusers families — FLUX.2 [klein], SDXL, SD 1.5 and Sana
Sprint — across eight checkpoints (SSD-1B is an SDXL-architecture entry), plus a
second registry of LoRA adapters and VAE swaps that can be applied on top of them.
The API is ours (six routes), and the SwarmUI/ComfyUI surface that `chopshop-sui`
built is deliberately absent. Two rules keep it opt-in: **this layer calls the
pipeline, the pipeline never calls it**, and **it never judges the art** — it
produces sources, a human picks.

## Hard rules

- **Never modify the GPU environment this runs against.** On the dev box that is
  ComfyUI's venv, which SwarmUI's own rules say must not be modified. Use its
  interpreter; do not `pip install` into it. This is why `requirements.txt` pins
  only pytest.
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
- **The licence gate is not advisory.** 4B and `sdxl-1.0`/`sd-1.5` allow
  commercial output; `sdxl-turbo` is a non-commercial research licence. Loading a non-commercial model requires
  `CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1`, checked in `models.check_usable` so it
  holds on every path that loads a model, not just in the view. Do not move it
  or make it implicit.
- **Do not weaken a caveat into a knob.** Guidance > 1.0 on a distilled model is
  ignored by the pipeline; a negative prompt on a model without a
  `negative_prompt` parameter is ignored too. The service says so in `warnings`
  rather than pretending to honour either.
- **Never `pkill -f <pattern>` when the pattern is in your own command line** —
  it matches your own shell and kills it (exit -15; happened twice on this
  project's sibling). Kill by port:
  `ss -ltnp | grep ':<port>' | grep -oP 'pid=\K[0-9]+' | head -1`.

- **Comments are section-level blocks that carry the WHY, not line-by-line
  narration.** Inside a system that spans files or repos, add a small
  `#label-name-function` breadcrumb at the key call sites so a reader can trace
  the thread across the codebase. The breadcrumb is a navigation tag, never a
  restatement of the code.

## Measured facts on this box (Radeon RX 9070 XT, gfx1201, RDNA4)

### LoRA adapters and VAE swaps (measured)

- **`peft` was the missing piece and it is VENDORED, not installed.** The GPU
  environment has no `peft`, so `load_lora_weights` cannot work there out of the
  box; `diffusers.utils.import_utils.is_peft_available()` reported False until
  `pip install --no-deps --target .vendor peft` (0.21.0) put it beside the
  checkout, picked up via `PYTHONPATH`. Verified after: that environment STILL
  cannot `import peft` on its own, so the hard rule about not modifying it holds.
- **THE ORDER IS LOAD-BEARING: assign the VAE (and swap the scheduler, and load
  the adapters) BEFORE `enable_model_cpu_offload()`, never after.** Measured:
  reassigning `pipe.vae` on an already-offloaded pipe leaves the new VAE outside
  accelerate's device map, and the next generation dies with
  `Expected all tensors to be on the same device, but found at least two devices,
  cuda:0 and cpu!` — raised inside the LCM SCHEDULER step, which names the wrong
  component entirely. `engine.load` therefore runs from_pretrained -> scheduler ->
  `load_lora_weights` per modifier -> `set_adapters(scales)` -> VAE -> offload
  LAST, and a test pins that order.
- Re-calling `enable_model_cpu_offload()` after a VAE assignment is a verified
  WORKAROUND for an already-offloaded pipe (identical output to assigning first),
  but the normal path never needs it because the VAE is part of the load. Swapping
  the SCHEDULER after the offload is fine and needs no constraint — only
  module-bearing components are in the device map.
- Measured on SDXL at 512x512: load + offload 8.3s; 30 steps 15.0s; LCM-LoRA at 4
  steps 11.2s; a repeat 4-step call 1.3s. **Do not claim a step-count speedup from
  these**: 4 steps is not 7.5x faster than 30, because under CPU offload the stage
  paging dominates, not the per-step compute.
- `set_adapters(adapter_weights=[...])` demonstrably changes the output, and two
  adapters can be active at once with independent weights.
- Measured timings for the newer entries, 1024x1024: klein-4b-base 28 steps 58.8s;
  SSD-1B at 25 / 7.5 6.1s first call and 4.4s after; Sana Sprint 0.6B at 2 / 4.5
  ~40s first call, 2.5s after, 2.1s at 512px, with 15.58 GB of 17.10 GB VRAM free
  between calls.
- **klein-4b-base's guidance is a real knob and klein-4b's is not.** Same prompt,
  same seed, same 4 steps, guidance 4.0 vs 1.0 differ by a mean absolute pixel
  difference of 34.38 on the base checkpoint. That is the measured form of
  `guidance_embedded` / the distilled distinction, and it is why the Sana rows
  carry `guidance_embedded=True`: their guidance is an embedding and IS honoured,
  so warning that it is "ignored" would be false.
- **Sana Sprint's `use_resolution_binning` defaults True**, so a size without a
  matching bucket is silently re-binned — hence the `resolution_binning` flag on
  the spec and the warning both the engine and the studio emit. Its
  `dim_multiple` of 32 (not a guess) comes from a 6-entry
  `encoder_block_out_channels`, i.e. `2**(6-1)`.
- **The licence gate must hold on EVERY path that loads an artefact.** It was
  measured missing on `engine.load(vae=...)`: a non-commercial VAE loaded with no
  acknowledgement while `generate(vae=...)` correctly refused it, because the gate
  lived only in `generate`. Deleting the load-path gate left the whole suite green
  — so if you add a load path, gate it and test it.


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
- **`Flux2KleinPipeline` is the klein family's t2i *and* edit pipeline**:
  `image=None` is text-to-image and `image=<PIL>` is an edit. There is no second
  model *within the klein family* — but the registry also spans SDXL and SD 1.5,
  which have their own pipeline/edit_pipeline classes, so this fact is
  klein-scoped, not repo-wide.
- Passing `torch_dtype` as a **string** (`"bfloat16"`) is silently ignored here and
  everything loads fp32; pass the torch dtype object. `torch_dtype` itself emits a
  FutureWarning pointing at `dtype` — left as-is because it is verified working.
- **`is_distilled` comes from the repo's `model_index.json`** (`true` for
  klein-4B), and it gates guidance: `do_classifier_free_guidance` is
  `guidance_scale > 1 and not is_distilled`, so no CFG ever runs for a distilled
  checkpoint and diffusers logs "Guidance scale X is ignored". That is the whole
  reason a negative prompt has no effect — there is nothing to wire.
- **`Flux2KleinPipeline` defaults to 50 steps / guidance 4.0**, which is the
  klein *base* model's schedule. The registry's per-model defaults (4 / 1.0 for
  the distilled checkpoints) override it; never let the class defaults through
  on a distilled checkpoint. SDXL and SD 1.5 carry their own defaults on their
  registry entries.
- On-disk weights: `HF_HOME` points at the model cache here. The klein-4B
  download needed `model_index.json` fetched **separately** — an `hf download
  --include "model_index.json"` with a bare filename pattern does not match, and
  `from_pretrained` then fails with a confusing error. Use `hf_hub_download` for a
  single file.
- **The card is SHARED with LM Studio (and ollama), and LM Studio cannot be
  asked whether it is busy.** Measured on LM Studio 0.4.24: `GET
  /api/v0/models` reports per-model `state` (`loaded` / `not-loaded`) and
  **nothing else** — sampled every 2 s across an active generation the loaded
  model stayed `state: "loaded"` and the endpoint kept answering in ~1 ms.
  `/api/v0/stats`, `/api/v0/queue` and `/metrics` are 404. The busy state exists
  only in the CLI: `lms ps` prints STATUS `IDLE` -> `GENERATING` for exactly the
  moment REST reports nothing. So a "is LM Studio queuing?" check is NOT
  implementable over HTTP here — gate on free VRAM instead (implementation
  agnostic, catches every holder) and use the loaded list for attribution only.
  See `guard.py` / #flux-gpu-guard.
- **`torch.cuda.mem_get_info` reports the CARD, not this process** — verified
  before the guard existed, when LM Studio's resident model showed up in
  `/health`'s `vram_free_gb`. That is what makes a free-VRAM gate able to see
  another process at all. `free_vram_gb()` returns None when torch/ROCm cannot
  answer, and None must never be read as "the card is free": the guard refuses
  nothing on an unreadable reading.
- **Free VRAM is measured with `rocm-smi --showpids`** to attribute it: the
  holder shows up as a KFD process name (`llama-server` for LM Studio,
  `python` for this service). `lms ps`'s SIZE column is the MODEL size
  (4.73 GB) and understates its footprint badly — the KV cache for a
  262144-token context × 4 parallel slots is what fills the card. Measured both
  ways: **16.21 GB held by `llama-server` while generating, and 16.23 GB held at
  IDLE** with the model merely resident (torch saw `free = 0.70 GB` of 17.10 GB).
  So the RESIDENCY is the contention, not the generation — the card does not come
  back when a generation ends, only when the model is released (`lms unload <id>`,
  or a TTL set in LM Studio). Do not size it from `lms ps`, and do not wait for a
  generation to finish expecting the card back.
- Report timings with `scripts/smoke.py`, which loads real weights and prints
  what the machine did. It is not a test and must not become one.
- **The output-side passes are measured on REAL generations, and two of them
  behave differently than the example rasters suggest.** MEASURED on this card
  (2026-09-29, #8), full tables in `docs/API.md`: `hires` is REFUSED on
  klein-4b and klein-4b-base (no `strength` on `Flux2KleinPipeline`), so the
  default model cannot use it — it needs `img2img_strength: true`, which is the
  other six entries. A `hires` second pass roughly DOUBLES generation time
  (SDXL 512→1024²: 4.21 s then 7.80 s), because it runs at 4× the pixels.
  And `background: "key"` keyed 0 of 3 real frames: the flood matches border
  colours EXACTLY and a model's "flat white" is off by one in a single channel.
  Do not "fix" the key by loosening the match without re-measuring — refusing is
  currently the correct behaviour, and the note says why.

## Layout

| path | what |
|---|---|
| `chopshop_flux/config.py` | every environment variable, read at call time |
| `chopshop_flux/guard.py` | the GPU-contention guard (#flux-gpu-guard): is another process holding the card. Stdlib only, like the HTTP layer; imported by `config.py` and `engine.py` |
| `chopshop_flux/models.py` | the registry: licences, VRAM, resolution rules, per-family behaviour |
| `chopshop_flux/styles.py` | named styles: prompt suffix + trace preset, stdlib only |
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

## Cross-repo docs

The cross-repo system map, the invocable-surface registry, and the studio's
HTTP driver contract live in `chopshop-studio/docs/` (SYSTEM.md, SURFACES.md,
agent-api.md). Read them for anything that spans repos.

## Not in scope, and why

Tracing/gating/ranking (that is `chopshop-svg`), the studio's runner contract
(generation is not trace-and-validate), and the studio's GUI. Style recipes —
`chopshop-sui`'s `swarm_styles.json` — are now bundled in
`chopshop_flux/styles.py` + `styles.json`, with a fallback built into the module
so a missing file never breaks generation.

## Agent skills

### Issue tracker

Issues for this repo live as GitHub issues; use the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` at the repo root. See `docs/agents/domain.md`.

### Standards

The shared conventions, and the rules for this tracker. Read
`docs/agents/standards.md` before filing an issue or landing a change.
