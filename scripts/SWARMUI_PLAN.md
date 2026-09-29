# SwarmUI integration — implementation plan

> **HOST-SPECIFIC, and superseded.** This describes one SwarmUI install and is
> kept unpublished (see `AGENTS.md` policy 5). The generation layer moved to
> [chopshop-flux](https://github.com/geeeze/chopshop-flux) (one small HTTP
> service over its own model registry); the "remaining work" below is the
> historical SwarmUI path, not an active plan. Reuse the verified API facts and
> the three bugs it surfaced, not the work list.

Status: **models present, bridge verified live.** SDXL base (0.9 VAE) and the
taesdxl decoder are downloaded; `generate`, `filter`, and `gen2pipe` all run
end-to-end against the live SwarmUI. A separate ComfyUI workflow layer now
exists too (`swarm_workflows/` — FLUX.2 Klein `trace → generate → trace`, with
the `ChopShopTrace` node); see `swarm_workflows/README.md`. Remaining work here
is style tuning, the filter loop, and (deferred) container integration.

## What is already done (do not redo)

- `scripts/swarm_bridge.py` — three modes, built against the live API:
  - `generate` — text → image(s) to disk.
  - `filter` — source raster → img2img (`initimage` + `initimagecreativity`).
  - `gen2pipe` — text → image → `front_pipeline.sh` (prep → sweep → compare).
- `scripts/swarm_styles.json` — style recipes (prompt suffix + trace preset):
  `flat-poster`, `mono-line`, `photo-halftone`.
- `tests/test_swarm_bridge.py` — 21 tests, stubbed HTTP layer; run without a
  server or models.
- Concurrency in `trace_sweep.py` + `compare_candidates.py` (`--workers`,
  `FRONT_PIPELINE_WORKERS`), including the Inkscape D-Bus fix.
- chopshop-svg's own suite passes; its `CONTEXT.md` is the canonical count (a
  number repeated here would only go stale again — it already has, twice).
  Live reachability/no-models paths verified (exit 4 with a clear message when
  model folders are empty).

## Live verification (done — 2026-09-24)

`gen2pipe "a stylized dragon emblem" --style flat-poster` ran the whole front
half against a real SDXL generation: 8 traced candidates, both layers, fidelity
metrics, comparison written. Three bugs surfaced and were fixed in this pass:

- **Image download paths must be percent-encoded.** SwarmUI names generated
  files after the prompt (spaces/commas); `_get_bytes` now runs
  `urllib.parse.quote(..., safe="/")` or urllib raises `InvalidURL`.
- **Model auto-selection.** A fresh SwarmUI selects no default model, so the API
  answers `No model input given` when `model` is omitted. `_resolve_model` now
  falls back to the first `Stable-Diffusion` entry when `--model` is absent.
- **`--sweep` seam.** `front_pipeline.sh` parses only `--sweep=FILE` (equals
  form); `_run_front_pipeline` was passing the two-token form, which hit the
  `unknown option` path. Fixed to `--sweep=<file>`.

## What blocks it

Resolved: SDXL base (0.9 VAE, ~6.9 GB) + taesdxl decoder (~4.9 MB) are in
`Models/Stable-Diffusion/` and `Models/VAE/`; SwarmUI sees both after a
`ChangeServerSettings` refresh. The network model shares remain offline;
downloading directly was the unblock.

## Verified API facts (SwarmUI 0.9.8.3 — reuse these, don't re-derive)

- `POST /API/GetNewSession` needs `Content-Type: application/json` and a `{}`
  body (bare POST → `basic_api` / "Wrong content type").
- `POST /API/GenerateText2Image` takes a **flat** JSON body (not nested under
  `rawInput`): `{session_id, images, prompt, model, width, height, ...}`.
- img2img: `initimage` (a `data:image/...;base64,` URL) + `initimagecreativity`
  (decimal, default 0.6). Note lowercase, no underscores.
- `POST /API/ListT2IParams` → `models` map keyed by category (list per category;
  empty = no models). Field names came from a live dump, not the docs table.
- Generated image path `View/.../x.png`; download by GETting it.
- GPU: torch ROCm build (`torch.version.hip` set, `cuda:0 AMD Radeon Graphics`
  17.1 GB). The CPU can enumerate as a HIP device — always check
  `torch.cuda.get_device_name(0)`.

## Remaining implementation work (in order)

### 1. ~~End-to-end smoke once a model is present~~ — DONE
```bash
.venv/bin/python scripts/swarm_bridge.py gen2pipe "a phoenix emblem" --style flat-poster
```
Ran live 2026-09-24: generation → PNG → sweep (8 candidates) → comparison all
worked. See "Live verification" above for the three bugs it surfaced.

### 2. `filter` loop — close the source→trace→regenerate→retrace circle
Currently `filter` is one-shot (source → N img2img variants → disk). Extend so
a source raster can be traced, then re-fed through img2img with a style, then
re-traced — an iterative "trace → restyle → trace" loop. Decision to make: is
this one `filter --iterate` pass with a fixed creativity schedule, or does it
hand back to the human between rounds? Lean human-in-the-loop (the pipeline's
core rule is: the agent never judges the art).

> Note: a `trace → generate → trace` loop already exists as a **ComfyUI
> workflow** (`swarm_workflows/`, FLUX.2 Klein), distinct from this bridge flag.
> That workflow inlines both VTracer trace steps in the generation graph; this
> item is about doing the same loop through the bridge's HTTP-only path.

### 3. Style templates — the real "categorise and template" work
The seed exists. To make it useful:
- Add a handful of real styles tuned against actual generated output (the
  current prompt suffixes are untested against a real checkpoint — they will
  need adjustment once generations work). Each style should record: prompt
  suffix, negative prompt, default `initimagecreativity`, trace preset, and a
  `spec` override (e.g. `max_colors`, `allow_gradients`) so a style carries its
  print budget too.
- Consider a `scripts/swarm_styles.json` → validate on load so a bad style fails
  loudly, not silently.

### 4. Batch generation + concurrency
`generate`/`filter` with `--images N` queue N images, but each `GenerateText2Image`
call is one job on one GPU. The GPU (16 GB) is the bottleneck, not CPU, so:
- Verify whether a single `images:N` call or N parallel calls is the right shape
  (single call = SwarmUI batches on the GPU; N calls = more HTTP round-trips).
- Do NOT parallelise the GPU calls blindly — one 16 GB card runs one job at a
  time; over-subscribing VRAM OOMs. The "ample cores" concurrency belongs to the
  CPU tracing stage (already done), not the generation stage.

### 5. ControlNet (optional, later)
`controlnetimageinput` / `controlnetmodel` exist in `ListT2IParams`. A
line-art/canny ControlNet could hold the source's *composition* fixed while the
text changes style — a stronger "filter" than img2img creativity. Needs a
ControlNet model (also absent). Mark as a later option, not part of the first
resume.

## Testing plan when models return
- Mock tests (done) stay green — they never need a server/model.
- Add ONE live integration test, gated on `SWARMUI_LIVE=1` and a model being
  present, so `pytest` still passes on a model-less box but the smoke can run
  in CI/CI-like conditions. Keep it out of the default suite.
- Record real output: a generated image, its trace candidates, and the
  comparison — to see whether the style prompt suffixes actually steer toward
  traceable art. Adjust `swarm_styles.json` from that evidence.

## Not in scope
- Modifying SwarmUI core (`~/SwarmUI/src/**`) — the bridge is external and stays
  that way. Only `scripts/swarm_bridge.py` + `scripts/swarm_styles.json` touch
  SwarmUI, and only via HTTP.
- Judging art quality. The bridge produces candidates + metrics; a human picks.
