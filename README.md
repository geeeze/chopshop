# chopshop-flux

A small generation service for the
[chopshop](https://github.com/geeeze/chopshop-svg) print pipeline.

It replaces the broad SwarmUI/ComfyUI integration in
[chopshop-sui](https://github.com/geeeze/chopshop-sui) with one small thing:
**one HTTP service, our own API, a registry of models.** No SwarmUI, no ComfyUI
graph, no workflow wrapper. The registry spans three diffusers families — FLUX.2
[klein], Stable Diffusion XL and Stable Diffusion 1.5 — and the style recipes
from `chopshop-sui` are bundled (see [Styles](#styles)).

Two rules carried over from `chopshop-sui`, because they are what keep a
generation layer opt-in:

1. **This layer calls the pipeline; the pipeline never calls it.**
   `front_pipeline.sh` and `pipeline.sh` live in `chopshop-svg` and know nothing
   about any of this.
2. **It never judges the art.** It produces sources; a human picks.

## Why the scope is this narrow

`chopshop-sui` proved the integration works and then showed what the surface
costs: a SwarmUI API that drifts, a C# server to keep alive, a 1560-line workflow
wrapper regenerated from `object_info`, and a queue whose failure mode was a hung
entry rather than an error. None of that is needed to answer "give me a raster to
trace". A service with six routes and one GPU does it, and the parts that were
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

## Models

The registry is five entries across three families. Each carries its own licence,
resolution rules and calling convention, so no family's rules leak into another:

| key | family | params | licence | commercial | VRAM* | steps / guidance |
|---|---|---|---|---|---|---|
| `klein-4b` **(default)** | FLUX.2 [klein] | 4B | Apache-2.0 | **yes** | ~13 GB | 4 / 1.0 |
| `klein-4b-base` | FLUX.2 [klein] | 4B | Apache-2.0 | **yes** | ~13 GB | 28 / 4.0 |
| `sdxl-1.0` | SDXL | 3.5B | Open RAIL++-M | **yes** | ~8 GB* | 30 / 5.0 |
| `sdxl-turbo` | SDXL | 3.5B | Stability NC Research | **no** | ~8 GB* | 2 / 0.0 |
| `sd-1.5` | SD 1.5 | 0.86B | Open RAIL-M | **yes** | ~4 GB* | 30 / 7.5 |

\* VRAM figures for the klein family are measured; the SDXL and SD 1.5 figures
are estimates (noted per-entry in the registry), because the same box has not
run them yet.

One of these facts is load-bearing and easy to get wrong:

- **Speed says nothing about what you may sell.** 4B is Apache 2.0, SDXL is
  Open RAIL++-M, SD 1.5 is Open RAIL-M — all allow commercial output, and
  `sdxl-turbo`, the *fastest* entry here, is a non-commercial research licence:
  local, non-commercial use only; commercial use of its output requires a licence
  from its licensor. Because that is a business decision rather than a technical
  one, loading a non-commercial model requires an explicit
  `CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1` — a commercial deployment cannot happen by
  accident.

### Limits, per family

- **Resolution rules are per-model, not global.** FLUX.2 [klein] generates
  64×64 to 4 MP with every dimension a multiple of 16; SDXL and SD 1.5 floor at
  128 with multiples of 8 and a 1–2 MP cap. Violating a model's own rules is a
  400 (a caller error), not a failed generation.
- `klein` and `sdxl-turbo` are step-distilled: **4 steps at guidance 1.0** and
  **2 steps at guidance 0.0**. Those are the registry's defaults, not the
  pipeline class's — `Flux2KleinPipeline.__call__` defaults to 50 steps /
  guidance 4.0 because that is what a *base* model wants, and running a
  distilled checkpoint at those values is running the wrong schedule.
- **A negative prompt works only where the model has one.** `klein` and
  `sdxl-turbo` are distilled, so classifier-free guidance never runs and a
  negative prompt has nothing to act through; SDXL and SD 1.5 take a real one.
  The registry's `negative_prompt` flag decides, and the service reports the
  situation in the response's `warnings` rather than accepting a knob it
  silently drops.

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
| `CHOPSHOP_FLUX_PORT` | `8795` | `8791` is `chopshop-svg`'s runner, `8790` the studio's mock |
| `CHOPSHOP_FLUX_OUT` | `./out` | where PNGs go, and the only tree `/files/` will serve |
| `CHOPSHOP_FLUX_MODEL` | `klein-4b` | default model |
| `CHOPSHOP_FLUX_OFFLOAD` | `cpu` | `cpu` or `none`. `none` does not fit here |
| `CHOPSHOP_FLUX_VAE_TILING` | off | decode the VAE in tiles. For large decodes; unverified at these sizes |
| `CHOPSHOP_FLUX_TOKEN` | unset | bearer token. Enforced only when set |
| `CHOPSHOP_FLUX_ACK_NONCOMMERCIAL` | unset | required to load a non-commercial model |
| `CHOPSHOP_FLUX_MAX_PIXELS` | unset | optional global ceiling: lowers every model's own cap, never raises it |
| `CHOPSHOP_FLUX_URL` | the loopback above | where the *client* looks for the service |
| `CHOPSHOP_FLUX_PIPELINE` | unset | a `chopshop-svg` checkout, for `gen2pipe` only |
| `HF_HOME` | huggingface_hub's | where the weights live |

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
works on every box and the checkout can live anywhere.

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
python -m chopshop_flux generate "a phoenix emblem" --width 512 --height 512 --out 00_source
python -m chopshop_flux generate "a phoenix emblem" --style flat-poster --out 00_source
python -m chopshop_flux gen2pipe "an owl crest" --width 512 --height 512 --out 00_source
```

`gen2pipe` generates, fetches the raster, and hands it to `front_pipeline.sh`
(needs `CHOPSHOP_FLUX_PIPELINE`). Exit codes match `chopshop-sui`'s bridge, so a
script that handles one handles the other: `0` ok, `2` usage, `3` unreachable,
`4` model missing, `5` generation failed. `gen2pipe` passes the pipeline's own
`1` ("candidates produced, none passed") straight through — that is a result, not
an error.

## Styles

A style is a prompt suffix plus the trace preset the traced sweep should use —
nothing more, so this layer still produces sources and the pipeline still traces
them. Three are bundled (ported from `chopshop-sui`'s `swarm_styles.json`):

| style | prompt steering | trace preset |
|---|---|---|
| `flat-poster` | flat vector poster, flat palette, bold shapes, no gradients | `poster` |
| `mono-line` | black-and-white line art, single ink, solid silhouette | `bw` |
| `photo-halftone` | photographic, soft gradients, continuous tone | `photo` |

`--style <name>` on `generate`/`edit` appends the suffix to the prompt. On
`gen2pipe` it also writes a single-preset sweep from the style's trace preset
(unless you pass your own `--sweep`, which wins), so one flag steers both the
generation and the trace. `--styles path.json` loads a caller styles file merged
over the built-ins — add styles or retune the bundled ones without editing code.
An unknown style is a usage error (`exit 2`), naming the styles that exist.

## Tests

```bash
python -m pytest          # no GPU, no torch, no models, no network
```

The HTTP layer is importable and testable without torch: `engine.py` imports it
inside methods, never at module scope, and the server takes an injected engine.
`test_importing_the_server_does_not_import_torch` pins that property, because the
moment it breaks, this suite stops running anywhere except the GPU box.

The suite covers the registry's licence and resolution rules, the whole HTTP
contract against a stub engine over a real socket (including path-traversal
containment on `/files/`, the body-size cap, and token auth), the client's two
network seams, and the pipeline hand-off — including a regression test for the
`--sweep=FILE` equals form, which `chopshop-sui` shipped broken once.

## Not in scope

- Tracing, gating, ranking or picking. That is `chopshop-svg`, and the picking is
  a human's.
- Implementing the studio's runner contract. Generation is not trace-and-validate,
  and bending `POST /jobs` to mean both would make one contract mean two things.
- The studio's GUI. This is a service, a client and a seam.
