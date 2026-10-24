# chopshop-flux

A small generation service for the
[chopshop](../README.md) suite.

It replaces the broad SwarmUI/ComfyUI integration in
[chopshop-sui](../sui/README.md) with one small thing:
**one HTTP service, our own API, a registry of models.** No SwarmUI, no ComfyUI
graph, no workflow wrapper. The registry spans five diffusers families — FLUX.2
[klein], Stable Diffusion XL, Stable Diffusion 1.5, Z-Image and Sana Sprint —
across nine checkpoints (`ssd-1b` is an SDXL-architecture entry, not a family of its
own), with
a second registry of LoRA adapters and VAE swaps that can be applied on top of
them, and the style recipes from `chopshop-sui` are bundled (see
[Styles](#styles)).

Two rules carried over from `chopshop-sui`, because they are what keep a
generation layer opt-in:

1. **This layer calls the pipeline; the pipeline never calls it.**
   `front_pipeline.sh` and `pipeline.sh` live in `chopshop-svg` and know nothing
   about any of this.
2. **It never judges the art.** It produces sources; a human picks.

(The pipeline never picks a winner; the choice is the operator's.)

## Why the scope is this narrow

`chopshop-sui` proved the integration works and then showed what the surface
costs: a SwarmUI API that drifts, a C# server to keep alive, a 1560-line workflow
wrapper regenerated from `object_info`, and a queue whose failure mode was a hung
entry rather than an error. None of that is needed to answer "give me a raster to
trace". A service with six routes and one GPU does it — `/health`, `/models`,
`/generate`, `/edit`, `/files/<name>`, `/unload`, exactly what `server.py` serves
(there is no `/load`; a model loads on the first request that asks for it) — and
the parts that were
genuinely hard-won — the model facts, the licence facts, the resolution rules —
are kept here as data rather than as tribal knowledge.

## What it does

```
text ──────────────► POST /generate ──► PNG(s)
image + text ──────► POST /edit ──────► PNG(s)
generated raster ──► front_pipeline.sh (prep → sweep → compare)   [client, opt-in]
```

The default model, FLUX.2 [klein], unifies text-to-image and editing in one
pipeline — `image=` is the only difference — so `/edit` is not a second model.
SDXL and SD 1.5 take an SD-style `image=` + `strength=` for editing instead.

A generation can then be pushed toward what the print pipeline can actually use,
with four **output-side passes** that are all optional and none of which ranks
anything: `hires` (generate → upscale → img2img at low strength), `ink_cap`
(reduce the frame to at most N flat colours, and report the count present),
`background` (`white` | `key` | `keep`), and `seeds` (a sweep, returned with the
seed→file mapping). `provenance: true` records per frame what a later trace
comparison needs, in the response and in a `.json` sidecar — inputs and
measurements only, never a score. The contract, the ranges and what each pass
does and does not buy are in `docs/API.md` ("Output-side passes"); the judgement
about when to reach for them is `docs/MODELS.md` §4.

## Models

The registry is nine entries across five diffusers families (`ssd-1b` is an
SDXL-architecture entry, not a family of its own). Each carries its own licence,
resolution rules and calling convention, so no family's rules leak into another:

> **`docs/MODELS.md` is the companion to this section**: what quality to expect
> from each entry, what actually fits this card (the largest single MODULE under
> `offload=cpu`, not a vendor's headline VRAM), how to drive each family well, and
> how to prompt for something the trace stage can use. `docs/MODELS-PLAN.md` is
> the spec for the checks not yet registered.

| key | family | params | licence | commercial | VRAM* | steps / guidance |
|---|---|---|---|---|---|---|
| `klein-4b` **(default)** | FLUX.2 [klein] | 4B | Apache-2.0 | **yes** | ~13 GB | 4 / 1.0 |
| `klein-4b-base` | FLUX.2 [klein] | 4B | Apache-2.0 | **yes** | ~13 GB | 28 / 4.0 |
| `sdxl-1.0` | SDXL | 3.5B | Open RAIL++-M | **yes** | ~8 GB* | 30 / 5.0 |
| `sdxl-turbo` | SDXL | 3.5B | Stability NC Research | **no** | ~8 GB* | 2 / 0.0 |
| `sd-1.5` | SD 1.5 | 0.86B | Open RAIL-M | **yes** | ~4 GB* | 30 / 7.5 |
| `ssd-1b` | SDXL | 1.3B | Apache-2.0 | **yes** | ~8 GB* | 25 / 7.5* |
| `sana-sprint-0.6b` | Sana Sprint | 0.6B | Apache-2.0† | **yes** | ~7.7 GB* | 2 / 4.5 |
| `sana-sprint-1.6b` | Sana Sprint | 1.6B | Apache-2.0† | **yes** | ~9.7 GB* | 2 / 4.5 |
| `z-image-turbo` | Z-Image | 6B | Apache-2.0 | **yes** | ~12.3 GB | 9 / 0.0 |
| `ming-image-0.1-design` | Novita AI (remote) | — | Novita ToS | **no** | 0 (hosted) | — |
| `ming-image-0.1-design-layer` | Novita AI (remote) | — | Novita ToS | **no** | 0 (hosted) | — |

\* The column is the DOWNLOAD size, not a resident footprint — the two differ, and
the registry's own note says so per entry. What is measured rather than inferred is
that the klein family and the Sana 0.6B RUN here; for Sana that measurement is a
download of 7.66 GB with **15.58 GB of 17.10 GB VRAM free between calls**. The
other figures are estimates, noted per-entry, because the same box has not run them.
SSD-1B's **steps and guidance are MEASURED**, not estimated: 1024×1024 at
25 / 7.5 returns well-formed frames — 6.1 s on the first call after a load and
4.4 s after — which makes it the fastest 1024 px checkpoint here. It is **not**
distilled: the Segmind name describes how the checkpoint was pruned from SDXL,
not a few-step inference schedule, which is why guidance 7.5 does something on it.

† The **Sana Sprint weights are Apache-2.0, but the text encoder is Gemma-2**
under Google's Gemma Terms of Use. That is a licence that rides along with the
Apache-2.0 weights: the model being Apache-2.0 is not the whole answer for output
you intend to ship. Recorded in each entry's `notes` rather than left to be
discovered.

`z-image-turbo` is the fifth family and the second one MEASURED running here:
**load 55.8 s, then 1024×1024 at 9 steps / guidance 0.0 takes 41.3 s on the first
call after a load and 17.0 s after**, both frames non-blank with 0 NaN warnings,
and a peak of **15.52 GB (14.45 GiB) of the 15.92 GiB card** sampled during the
run. It fits because the repo stores the transformer and text encoder in fp32 —
`torch_dtype=torch.bfloat16` halves the resident module to ~12.3 GB, while the
**download stays the 32.8 GB fp32 figure**, so size the disk from the download and
the card from the bf16 module. Its resolution multiple is **16**, read from
`ZImagePipeline.__call__`'s own check (`vae_scale_factor * 2`, and the VAE's
four blocks give 8), and its `guidance_scale` is **not** ignored: the class gates
CFG on `guidance_scale > 0`, so guidance 0.0 vs 4.0 at the same seed differ by a
mean absolute pixel difference of **25.11**. 9 / 0.0 is the Turbo schedule; the
class's own 50 / 5.0 belongs to the base model and is never used. `/edit` is the
separate `ZImageImg2ImgPipeline` (verified: 49.3 s, non-blank). The `min_dim` of
128 and the 1 MP cap are this repo's policy, not measurements — 1024×1024 is what
was run.

One of these facts is load-bearing and easy to get wrong:

- **Speed says nothing about what you may sell.** 4B, SSD-1B and Sana Sprint are
  Apache 2.0, SDXL is Open RAIL++-M, SD 1.5 is Open RAIL-M — all allow commercial
  output, and `sdxl-turbo`, the *fastest* entry here, is a non-commercial research
  licence: local, non-commercial use only; commercial use of its output requires a
  licence from its licensor. Because that is a business decision rather than a
  technical one, loading a non-commercial model requires an explicit
  `CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1` — a commercial deployment cannot happen by
  accident.
- **`stabilityai/sdxl-turbo`'s card and its `LICENSE.md` disagree.** The card says
  `license: other` / `sai-nc-community` while the licence file currently serves the
  Stability AI Community License, which allows commercial use below $1M revenue.
  This repo stays conservative and keeps it non-commercial — the disagreement is
  recorded, never silently resolved in the direction that looks convenient.
- **`stabilityai/sd-turbo` is deliberately not registered.** Its card has no
  licence field at all and its README and `LICENSE.md` disagree, so the licence is
  undecidable from the repo; it also adds nothing over `klein-4b`. A model whose
  terms cannot be read is not a model this registry can carry.

### Limits, per family

- **Resolution rules are per-model, not global.** FLUX.2 [klein] generates
  64×64 to 4 MP with every dimension a multiple of 16; SDXL, SSD-1B and SD 1.5
  floor at 128 with multiples of 8 and a 1–2 MP cap; **Sana Sprint floors at 512
  with multiples of 32 and caps at 1 MP**, because its VAE is a 32×-downsampling
  `AutoencoderDC` rather than an 8× `AutoencoderKL`. Violating a model's own rules
  is a 400 (a caller error), not a failed generation.
- `klein` and `sdxl-turbo` are step-distilled: **4 steps at guidance 1.0** and
  **2 steps at guidance 0.0**. `ssd-1b` is NOT — it is a full CFG model at
  **25 steps / 7.5**, measured on the box. Those are the
  registry's defaults, not the pipeline class's — `Flux2KleinPipeline.__call__`
  defaults to 50 steps / guidance 4.0 because that is what a *base* model wants,
  and running a distilled checkpoint at those values is running the wrong
  schedule.
- **A negative prompt works only where the model has one.** `klein` and both Sana
  rows have no `negative_prompt` parameter at all; `sdxl-turbo` and
  `z-image-turbo` HAVE the parameter but run at guidance 0.0, where
  classifier-free guidance never runs and there is nothing for it to act through
  (raise guidance above 1.0 for `sdxl-turbo`, above 0 for `z-image-turbo` — its
  class gates CFG on `guidance_scale > 0` — and it does act). The four SD
  entries — `sdxl-1.0`, `sdxl-turbo`, `sd-1.5`, `ssd-1b` — now **send a
  print-tuned default** (`gradients, soft shadows, photographic texture,
  hairlines, blur`) when a request gives none, echoing it and marking it
  `negative_prompt_source: "default"`; `"negative_prompt": ""` sends none.
  `z-image-turbo` takes a caller's negative prompt and has **no default**, so an
  absent one sends nothing. The registry's `negative_prompt` flag decides which
  case a model is in, and the service reports the situation in the response's
  `warnings` rather than accepting a knob it silently drops.
- **Guidance is not always ignorable just because a model is distilled.** Sana
  Sprint is distilled but takes `guidance_scale` as a *guidance embedding*, so its
  number is honoured with no CFG pass anywhere. The registry's
  `guidance_embedded` flag separates the two cases, and the "guidance is ignored"
  warning fires only where it is actually true.
- **A Sana size you ask for may not be the size you get.** `SanaSprintPipeline`
  enables `use_resolution_binning` by default, so a request that is not one of its
  buckets is silently re-binned. The service says so in `warnings` and
  `resolution_binning` reports the flag, because a caller who asked for a size
  should not have to read it off the PNG.

## Modifiers — LoRA adapters and VAE swaps

`chopshop_flux/modifiers.py` is a second registry: **fourteen LoRA adapters and
five VAE swaps** that can be applied on top of any model they target. They are
first-class and selectable, not folklore:

```bash
python -m chopshop_flux modifiers            # the LoRA registry
python -m chopshop_flux vaes                 # the VAE registry

python -m chopshop_flux generate "a flat wolf badge" --model sdxl-1.0 \
    --lora sdxl-lightning-4step --lora-scale sdxl-lightning-4step=0.8
python -m chopshop_flux generate "a hero sprite" --model sdxl-1.0 --lora pixel-art-xl
python -m chopshop_flux generate "an emblem" --model sdxl-1.0 --vae taesdxl
```

| group | adapters | licence | what they are for |
|---|---|---|---|
| klein edit | `klein-background-remove`, `klein-object-remove`, `klein-outpaint`, `klein-spritesheet` | Apache-2.0 | background/object removal, outpaint, sprite sheets — for FLUX.2 [klein] |
| speed | `sdxl-lightning-2step`, `-4step`, `-8step`, `lcm-lora-sdxl`, `lcm-lora-sd15` | Open RAIL++-M / Open RAIL-M | 2–8 step SDXL and SD 1.5 generation |
| style | `pixel-art-xl`, `logo-redmond`, `colouring-book`, `stickers`, `papercut-sdxl` | Open RAIL-M | flat, few-colour idioms that trace well |

| VAE swap | licence | note |
|---|---|---|
| `sdxl-vae-fp16-fix`, `sdxl-vae` | MIT | SDXL's decoder, standalone (334.7 MB download) |
| `sd-vae-ft-mse` | MIT | SD 1.5's fine-tuned MSE decoder |
| `taesdxl`, `taesd` | MIT | tiny autoencoders, ~30× smaller, **visibly softer** — a trade, not a free speed-up |

Three rules hold every one of them:

- **A modifier's licence is its own.** An adapter does not inherit the licence of
  the checkpoint it is bolted onto — putting a CreativeML Open RAIL-M adapter on an
  Apache-2.0 checkpoint means the terms you are working under are no longer only
  the checkpoint's. So every modifier and every VAE carries its own
  `commercial_ok` and goes through the same gate as a model — the same
  `CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1`, checked in
  `modifiers.check_modifier_usable`.
- **A distilled adapter is its scheduler.** LCM adapters need `LCMScheduler` and
  the Lightning ones need `EulerDiscreteScheduler` with trailing timestep spacing.
  That requirement travels with the adapter (`scheduler` on the entry) and the
  engine installs it; loading either without its scheduler produces noise rather
  than a cheap image.
- **The order of operations is contractual.** `from_pretrained` → scheduler →
  `load_lora_weights` per modifier → `set_adapters(scales)` → VAE → **offload
  last**. Measured on this card: assign `pipe.vae` *after*
  `enable_model_cpu_offload()` and the next pipeline call dies with "Expected all
  tensors to be on the same device, but found at least two devices, cuda:0 and
  cpu!" — inside the scheduler step, naming everything except the VAE, because
  accelerate built the device map over the original one. A sequence test pins the
  order so it cannot regress.

The response echoes what was actually applied (`modifiers` with the scale each one
really ran at, `vae`, `scheduler`), and the service warns — rather than silently
proceeding — when an adapter targets another model, when the step/guidance in
effect contradicts an adapter's own schedule, or when a scale of 0 disables the
adapter it was given for.

### Measured (RX 9070 XT, 512×512, `offload=cpu`, SDXL + LCM-LoRA)

| | |
|---|---|
| `sdxl-1.0` load + offload | **8.3 s** |
| base generation, 30 steps | **15.0 s** |
| 4-step LCM-LoRA generation | **11.2 s** |
| a repeated 4-step call | **1.3 s** |

**Four steps is not four times faster than thirty here.** Under CPU offload the
per-step compute is no longer the bottleneck, so the honest comparison is the two
numbers above, not the ratio of the step counts.

## Running the service

The runtime needs torch + diffusers + Pillow, plus **`accelerate`** — without it
diffusers refuses `enable_model_cpu_offload()`, and without offload this model
does not fit (see below). This repo pins none of them: a working GPU stack is a
multi-GB, platform-specific install. Point the service at the environment that
already has it:

```bash
# on the box with the GPU
/path/to/gpu-venv/bin/python -m chopshop_flux serve
```

If the GPU environment is not yours to modify — the dev box's is another
project's ComfyUI venv, and its own rules forbid touching it — put the one
missing package somewhere you own and put it on the path:

```bash
pip install --no-deps --target .vendor accelerate     # writes only into .vendor
PYTHONPATH=.vendor /path/to/gpu-venv/bin/python -m chopshop_flux serve
```

`--target` is the point: it leaves the other environment untouched. Verified
after installing — that venv still cannot import `accelerate` on its own.

Configuration is entirely environment-driven — **nothing here names a host**, so
the same code runs on the GPU box and is reachable from anywhere else:

| variable | default | meaning |
|---|---|---|
| `CHOPSHOP_FLUX_BIND` | `127.0.0.1` | listen address. Loopback on purpose |
| `CHOPSHOP_FLUX_PORT` | `8795` | `8787` is `chopshop-svg`'s runner, `8790` the studio's mock |
| `CHOPSHOP_FLUX_OUT` | `./out` | where PNGs go, and the only tree `/files/` will serve |
| `CHOPSHOP_FLUX_MODEL` | `klein-4b` | default model |
| `CHOPSHOP_FLUX_OFFLOAD` | `cpu` | `cpu` or `none`. `none` does not fit here |
| `CHOPSHOP_FLUX_DTYPE` | `bfloat16` | `bfloat16` / `float16` / `float32` for every `from_pretrained`. **Set `float16` on a card without native bf16** (Turing, sm_75): MEASURED on a T4, bf16 is 9.9x slower than fp16 (54.94 ms vs 5.55 ms per 4096^2 GEMM) *and* Sana's DC-AE raises `GET was unable to find an engine` from a conv2d in bf16. Unset keeps the previous behaviour exactly |
| `CHOPSHOP_FLUX_VAE_TILING` | off | decode the VAE in tiles. For large decodes; unverified at these sizes |
| `CHOPSHOP_FLUX_GUARD` | `warn` | what to do when another process holds the GPU: `off` / `warn` / `wait` / `block` |
| `CHOPSHOP_FLUX_GUARD_VRAM_GB` | `5.0` | free VRAM required before a load is attempted (one `offload=cpu` stage, not the whole model) |
| `CHOPSHOP_FLUX_GUARD_WAIT` | `120` | seconds `wait` holds a request before refusing — **long enough only for a transient holder**, see the note below |
| `CHOPSHOP_FLUX_GUARD_POLL` | `5` | seconds between VRAM readings while waiting |
| `CHOPSHOP_FLUX_LMSTUDIO_URL` | unset | LM Studio's local server, to NAME the holder in a refusal |
| `CHOPSHOP_FLUX_LMSTUDIO_TOKEN` | unset | the API key an LM Studio's local server may demand. Without it a keyed LM Studio answers `401` to the guard's probe, so the guard still refuses on free VRAM but cannot say *what* to release. Attribution only — never sent anywhere else |
| `CHOPSHOP_FLUX_IDLE_UNLOAD` | `0` | seconds quiet before the loaded model is unloaded (0 = never). **The unload does NOT return the ~16 GB** — MEASURED, a successful unload still held 16.2 GB of anonymous memory (`RssAnon`). Pair it with `CHOPSHOP_FLUX_IDLE_EXIT` on a box that shares its RAM; the next request pays one load |
| `CHOPSHOP_FLUX_IDLE_EXIT` | off | with `IDLE_UNLOAD`: measure `RssAnon` after the unload and, if the memory is still held (> 1 GiB), drain and end the process so the unit's `Restart=on-failure` returns it. MEASURED end to end: 16.22 GB held → 0.01 GB after the restart, box free RAM 28 → 43 GB. Off by default — it changes the service's lifecycle |
| `CHOPSHOP_FLUX_DRAIN_SECONDS` | `5` | how long a decided exit keeps answering `503 {"kind": "restarting", "retry_after": …}` before the process goes (`0` = no drain). Sized against the measured ~5 s restart |
| `CHOPSHOP_FLUX_RECONNECT_ATTEMPTS` | `4` | *client side*: tries when a connect is REFUSED, first try included (`1` = no retry). Spans ~12 s against the ~5 s window |
| `CHOPSHOP_FLUX_RECONNECT_BACKOFF` | `2` | *client side*: seconds before the Nth retry, multiplied by N (linear — the window is bounded and known) |
| `CHOPSHOP_FLUX_TOKEN` | unset | bearer token. Enforced only when set |
| `CHOPSHOP_FLUX_ACK_NONCOMMERCIAL` | unset | required to load a non-commercial model |
| `CHOPSHOP_FLUX_MAX_PIXELS` | unset | optional global ceiling: lowers every model's own cap, never raises it |
| `CHOPSHOP_FLUX_URL` | the loopback above | where the *client* looks for the service |
| `CHOPSHOP_FLUX_PIPELINE` | unset | a `chopshop-svg` checkout, for `gen2pipe` only |
| `HF_HOME` | huggingface_hub's | where the weights live |

**`wait` is for a transient holder, and only that.** The budget
(`CHOPSHOP_FLUX_GUARD_WAIT`, 120 s) is shorter than a holder's own generation
MEASURED on this card — 180.6 s and 399.0 s for two LM Studio runs — so a request
that arrives mid-generation stalls for the full two minutes and is then refused:
the one outcome worse than failing fast. A resident model never releases the
card at all (measured: ~16 GB held while IDLE), so no budget helps there either.
On a shared box, **use `block`** — refuse at once and let the caller decide — or
raise the budget and the caller's read timeout *together*: the studio's
`FluxClient::GENERATE_READ_TIMEOUT` is 300 s, so a budget past ~250 s trades a
clean `503 gpu_busy` for a client-side timeout whose message says nothing. The
live service on this box runs `wait`/120 s; that is a deliberate choice for a
box where the holder is usually transient, not a general recommendation.

**The bind default is loopback deliberately.** `chopshop-svg`'s `runner.py`
defaults to `0.0.0.0` and its own contract calls that a footgun. Reaching this
service from another machine is an explicit act — set `CHOPSHOP_FLUX_BIND` to the
private address (a tailnet address, say) and set `CHOPSHOP_FLUX_TOKEN`.

**What the token covers, measured rather than assumed.** With a bind and a token
set, `/generate`, `/edit` and `/models` all answer `401` without the header and
work with it. `/health` does not: it is a public probe on purpose, so that a
monitoring script or a studio showing runner status can ask whether the box is up
without holding a credential. It reports `auth_required` so a caller can tell the
difference between "up and open" and "up and locked". The generation routes are
the ones that cost GPU time, and they are the ones that are guarded.

Binding elsewhere really does move it: with `CHOPSHOP_FLUX_BIND` set to the
tailnet address, loopback stops answering entirely. There is no second listener.

### The idle-exit restart, and how a client rides it out

`CHOPSHOP_FLUX_IDLE_UNLOAD` alone does not hand the memory back (MEASURED: a
successful unload still held 16.2 GB of `RssAnon`, because the allocator keeps
the arena), so `CHOPSHOP_FLUX_IDLE_EXIT` ends the **process** instead — and a
process that ends under an open port is a window in which a chained job can fail
for no reason. The lifecycle has both halves:

1. The idle reaper sees the service quiet past `IDLE_UNLOAD`, unloads, and
   MEASURES `RssAnon`. Memory came back → the service keeps running. Still held
   above 1 GiB → it decides to exit.
2. **Drain** (`CHOPSHOP_FLUX_DRAIN_SECONDS`, default 5 s): every route —
   `/health` included — answers
   `503 {"kind": "restarting", "retry_after": <seconds>}` for that window. The
   socket stays open on purpose: a 503 that names the wait beats a refused
   connect.
3. The process exits with a FAILURE code, so the unit's ordinary
   `Restart=on-failure` brings it back ~5 s later. MEASURED end to end on the
   box: `RssAnon` 16.22 GB → 0.01 GB, available RAM 28 → 43 GB.
4. **The client** retries a REFUSED connect `CHOPSHOP_FLUX_RECONNECT_ATTEMPTS`
   times (default 4, ~12 s of linear `CHOPSHOP_FLUX_RECONNECT_BACKOFF` against
   the ~5 s window) and waits out `retry_after` on a `restarting` 503 rather
   than raising — never longer than one of its own backoff steps, so a drain
   cannot eat the caller's timeout budget. It deliberately does **not** do that
   for `gpu_busy` — that 503 is the guard's business and the guard decides when
   to wait.

The distinction a chain needs is the exit code: a step that lands between
restarts comes back as exit `3` (unreachable) with a message saying the service
looks like it is restarting and that no generation was started — never as `5`
(generation failed), which is what the old behaviour reported for a socket
closed under it.

### Keeping it running — a service you can toggle

`deploy/` holds a systemd **user** unit, so starting and stopping the service is
the same one-command affair as switching a local model server on and off:

```bash
cp deploy/chopshop-flux.service ~/.config/systemd/user/
cp deploy/chopshop-flux.env.example ~/.config/chopshop-flux.env   # then edit
systemctl --user daemon-reload
systemctl --user start chopshop-flux      # GPU is mine for the next hour
systemctl --user stop  chopshop-flux      # hand it back
systemctl --user status chopshop-flux
```

Nothing host-specific is in the unit — the interpreter, the model cache, the bind
address and the token all come from the unit's `EnvironmentFile`, so the same file
works on every box and the checkout can live anywhere. The only values baked into
the unit are the two glibc allocator variables and the `MemoryMax` tripwire, which
are properties of this workload rather than of one machine (size `MemoryMax` to
the box; the comment says how).

`start`/`stop` are the toggle; `enable` is what makes it survive a reboot:

```bash
systemctl --user enable chopshop-flux
loginctl enable-linger "$USER"            # one root command, once: start at boot
                                          # without waiting for a login
```

Skip the `enable` line if you would rather it never came up on its own — the
service costs nothing idle, but it does hold a GPU context once loaded, and a box
that quietly starts using the GPU at boot is a box that surprises you later.

### Measured on the Radeon RX 9070 XT (klein-4b, 512×512, 4 steps, offload=cpu)

| | |
|---|---|
| weights load | **1.3 s** |
| first frame after load | **7.7 s** (unavoidable one-off warm-up) |
| every frame after that | **~3.5 s**, stable across 24 consecutive frames |
| VRAM held between calls | **0.64 GB** of 15.92 GiB |

Reproduce with `scripts/smoke.py`, which loads real weights, checks each frame for
actual content rather than trusting the exit code, and prints these numbers.

Under `systemd`, two glibc variables are set on the process —
`MALLOC_MMAP_THRESHOLD_=131072` and `MALLOC_ARENA_MAX=2` — because thread-per-request
generation otherwise leaves each request's allocations in an arena that never
shrinks, and `MemoryMax` acts as a regression tripwire. They are in
`deploy/chopshop-flux.service`, and the memory release they belong to (an unload
that used to free nothing, and the `gc.collect()` + `malloc_trim` that fixed it)
is documented in `docs/API.md` under "Memory, lifetime and the environment".

Resident (`offload=none`) does **not** work on this card, and the numbers say why:
the weights are 15.97 GB (7.75 transformer + 8.05 text encoder + 0.17 VAE) against
15.92 GiB = 17.10 GB, so all four denoise steps complete with 15.01 GiB allocated
and the VAE decode then has 174 MiB left. Offload is not a preference here, it is
the difference between running and not.

### Deployment shape

The service runs on the machine with the GPU. A runner elsewhere — a VPS, a
laptop — talks to it over a private network and never needs a GPU of its own:

```
[ GPU box: python -m chopshop_flux serve ] ──tailnet──► [ runner: client + front_pipeline.sh ]
```

Generation is the only thing that needs the Radeon. Tracing, gating and comparing
happen wherever the pipeline runs.

## Client

```bash
export CHOPSHOP_FLUX_URL=http://<gpu-box>:8795
python -m chopshop_flux health
python -m chopshop_flux models
python -m chopshop_flux modifiers
python -m chopshop_flux vaes
python -m chopshop_flux examples
python -m chopshop_flux generate "a phoenix emblem" --width 512 --height 512 --out 00_source
python -m chopshop_flux generate "a phoenix emblem" --style flat-poster --out 00_source
python -m chopshop_flux generate "a flat wolf badge" --model sdxl-1.0 --lora sdxl-lightning-4step --out 00_source
python -m chopshop_flux gen2pipe "an owl crest" --width 512 --height 512 --out 00_source
```

`models` reads the registry from the service; `modifiers`, `vaes` and `examples`
read it locally, so they work with nothing running — the registries are the same
compiled-in facts on both sides.

`gen2pipe` generates, fetches the raster, and hands it to `front_pipeline.sh`
(needs `CHOPSHOP_FLUX_PIPELINE`). Exit codes match `chopshop-sui`'s bridge, so a
script that handles one handles the other: `0` ok, `2` usage, `3` unreachable,
`4` model missing, `5` generation failed. `gen2pipe` passes the pipeline's own
`1` ("candidates produced, none passed") straight through — that is a result, not
an error.

## Styles

A style is a prompt suffix plus the trace preset the traced sweep should use —
nothing more, so this layer still produces sources and the pipeline still traces
them. Nine are bundled: the original three ported from `chopshop-sui`'s
`swarm_styles.json`, plus six **print styles** whose suffix exists to remove what
a tracer cannot follow (gradients, antialiased edges, large colour counts):

| style | prompt steering | trace preset | suggests |
|---|---|---|---|
| `flat-poster` | flat vector poster, flat palette, bold shapes, no gradients | `poster` | — |
| `mono-line` | black-and-white line art, single ink, solid silhouette | `bw` | — |
| `photo-halftone` | photographic, soft gradients, continuous tone | `photo` | — |
| `logo-mark` | minimal logo mark, single flat fill, hard edges, white ground | `bw` | `sdxl-1.0` + `logo-redmond` |
| `line-art` | black line art on white, closed shapes, no fills, no shading | `bw` | `sdxl-1.0` |
| `flat-vector` | 4–6 solid colours, hard edges, no gradients, no texture | `poster` | — |
| `sticker` | die-cut sticker, one subject, thick outline, flat ground | `poster` | `sdxl-1.0` + `stickers` |
| `colouring-book` | outline page, unfilled white, no shading, no hatching | `bw` | `sdxl-1.0` + `colouring-book` |
| `pixel-art` | 8-bit sprite, axis-aligned pixels, indexed palette, no antialiasing | `poster` | `sdxl-1.0` + `pixel-art-xl` |

`--style <name>` on `generate`/`edit` appends the suffix to the prompt. On
`gen2pipe` it also writes a single-preset sweep from the style's trace preset
(unless you pass your own `--sweep`, which wins), so one flag steers both the
generation and the trace. `--styles path.json` loads a caller styles file merged
over the built-ins — add styles or retune the bundled ones without editing code.
An unknown style is a usage error (`exit 2`), naming the styles that exist.

The `suggests` column is the two **optional** fields a print style may carry:
a `model` and a `modifiers` list. They are advisory — `apply_style` still returns
exactly the `(suffix, preset)` pair it always did, so nothing that consumed a
style before this is affected — and they exist so `logo-mark` can say "this
subject wants the logo adapter on SDXL" instead of leaving it as folklore. A
style with no opinion says nothing rather than naming the default model.

## Examples — the test-prompt set

`examples/prompts.json` is a machine-readable set of **30 example generations**
that exercises every registered model, every modifier and every VAE at least once,
plus the print subjects (a logo mark, a line-art crest, a flat poster, a sticker, a
pixel sprite, a background-removal edit and an img2img edit):

```bash
python -m chopshop_flux examples               # list them, with coverage checked
python -m chopshop_flux examples --json
```

Each entry carries `id`, `model`, `modifiers`, `vae`, `prompt`, `negative_prompt`,
`width`, `height`, `steps`, `guidance`, `seed`, `style`, `what_it_proves` — and an
optional `reference`, which names another example whose generated frame becomes
this one's input image. That is how an edit example ships without a raster beside
it, and how an img2img edit stays reproducible.

`chopshop_flux/examples.py` loads and validates the set: every model, modifier,
VAE and style key must resolve, every size must pass the same `validate_size` the
service uses, and steps/guidance may not contradict a distilled model's — or a
distilled *adapter's* — own schedule. It raises `ModelError` with a precise
message, so a set that has drifted from the registries fails on a CI box rather
than twenty minutes into a GPU run.

**Proving it against real weights** is what `scripts/smoke_examples.py` is for. It
drives a live service over HTTP, decodes every frame it gets back, and writes
`examples-report.json` + `examples-report.md` — one row per example with
PASS/FAIL, seconds, seed, sha256 and the frame's distinct-colour count:

```bash
python -m chopshop_flux serve &                 # on the box with the GPU
python scripts/smoke_examples.py --only sdxl-lightning-4step
python scripts/smoke_examples.py --report examples-report
```

`--only ID` runs one example (pulling in **every** reference it edits — a
multi-reference entry needs all of them generated first, and a partial
conditioning set is a different request, not a smaller one). An example's
`reference` is a string for the ordinary edit and a **list** for a
multi-reference one, and `examples.py` refuses a list on a model whose
registry row does not declare `multi_reference` — so a broken set fails on the
CI box rather than as a `400` on the GPU box. The set carries
`klein-dual-reference-edit`, which conditions on two frames at once.

It is **not a test and must not become one** — the test suite runs with no
GPU, no torch, no models and no network. Three things it refuses to do: trust a
zero exit code (a uniform black frame from NaN latents is decoded and counted, not
assumed fine), report an example it never ran, and need Pillow — the blank-frame
check is a small PNG decoder in the script, and its own test pins that decoder
against all five PNG filters.

**Proving multi-reference is real** is a separate case, `--multi-reference` on
`scripts/smoke.py`. The plumbing is correct by construction and a unit test
cannot show the checkpoint conditions on *all* its references; only a render can:

```bash
scripts/smoke.py --model klein-4b --multi-reference --multi-reference-seed 4321
```

Four generations — two reference frames, then the same prompt, seed and steps
conditioned on one reference and on two. The verdict is that the two frames'
**sha256 digests differ**, and the mean per-channel pixel difference is printed
beside it so the size of the change is visible. Identical digests mean the
pipeline read only `image[0]` and `multi_reference` is declared but not
implemented on that checkpoint; the run then exits `5`. Run against a
single-reference family it declines before generating anything and reports
`passed: null` — not applicable is not failed, and a caller reading it as a
failure would turn every img2img row red.

## Tests

```bash
python -m pytest          # no GPU, no torch, no models, no network
```

The HTTP layer is importable and testable without torch: `engine.py` imports it
inside methods, never at module scope, and the server takes an injected engine.
`test_importing_the_server_does_not_import_torch` pins that property, because the
moment it breaks, this suite stops running anywhere except the GPU box.

The suite covers the registry's licence and resolution rules, the modifier and VAE
registries (every repo, weight filename, target and licence; the shared licence
gate), the engine's must-have ordering with a fake pipeline that records the
sequence of calls — offload last — plus the idempotency rule that a different
modifier set must re-load, the whole HTTP contract against a stub engine over a
real socket (including path-traversal containment on `/files/`, the body-size cap,
and token auth), the example set's validity and coverage, and the client's two
network seams, including a regression test for the `--sweep=FILE` equals form,
which `chopshop-sui` shipped broken once.

The output-side passes are covered the same way: the ink cap, the flood key and
the colour counts run in `postprocess.py` — **stdlib only, no Pillow** — so the
suite exercises them on real bytes (`tests/test_postprocess.py`), and the request
path is driven end to end through `FluxEngine` with a fake pipeline and fake PIL
whose frames carry real pixels (`tests/test_output_features.py`). That file also
pins the thing that matters most here: **a request using none of the new keys is
byte-for-byte the request the service made before them** — same pipeline kwargs,
same PNG sha256, same response body, captured from the committed tree by
`scripts/probe_output_path.py`. Every new key is asserted to be a 400 naming its
key on a bad value (`tests/test_server_output.py` over a real socket).

## Not in scope

- Tracing, gating, ranking or picking. That is `chopshop-svg`, and the picking is
  a human's.
- Implementing the studio's runner contract. Generation is not trace-and-validate,
  and bending `POST /jobs` to mean both would make one contract mean two things.
- The studio's GUI. This is a service, a client and a seam.

## Interface contract

See [`docs/contract.md`](docs/contract.md) for the JSON spec, metrics schema, routes, and boundaries.
