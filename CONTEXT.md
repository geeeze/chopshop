# CONTEXT.md — chopshop-flux

Working state for agents and humans: what is in flight, what is blocked, and the
caveats that are not obvious from the code. Update this as work lands.

**Repo visibility: private.** The registry encodes licence facts and measured
machine behaviour — keep it out of the public `chopshop-svg` repo.

**Language: English only.** Every file, comment, doc, string and commit message in
this repo is English — no CJK (Chinese/Japanese/Korean) characters. Where a parser
genuinely needs them, write `\uXXXX` escapes, never the literal
(`docs/agents/standards.md`, rule "English only").

## What this repo is

The generation layer for the chopshop print pipeline: one small HTTP service with
our own API (six routes) and a registry spanning five diffusers families — FLUX.2
[klein], SDXL, SD 1.5, Z-Image and Sana Sprint — across nine checkpoints (SSD-1B is
an SDXL-architecture entry, not a family of its own) — plus a second registry of
LoRA
adapters and VAE swaps that can be applied on top of them, deliberately replacing
`chopshop-sui`'s SwarmUI/ComfyUI surface (no C# server, no generated workflow
wrapper, no queue). `python -m chopshop_flux serve` runs on the box with the GPU;
the same module as a client talks to it from anywhere. Two rules keep it opt-in:
**this layer calls the pipeline, the pipeline never calls it**, and **it never
judges the art** — it produces sources, a human picks.

## Work in progress

- **LANDED: `CHOPSHOP_FLUX_LMSTUDIO_TOKEN` — the guard can name a KEYED LM
  Studio.** `probe_lmstudio` fetched `/api/v0/models` with no auth header, and a
  local LM Studio with an API key set answers `401`. MEASURED on a Tesla T4 box:
  `/health` reported `lmstudio.reachable: false`, `HTTPError: HTTP Error 401:
  Unauthorized`, while `llama-server` held 9.10 GiB of a 15.36 GB card. The gate
  itself is free VRAM, so the refusal was still correct — but it could not say
  *what* to release, which is the only reason the URL is configurable at all.
  `config.guard_lmstudio_token()` reads the new variable, `_get_json` turns a
  non-empty value into an `Authorization: Bearer …` header on a
  `urllib.request.Request`, and both probe call sites pass it. With no token the
  argument to `urlopen` and to every test seam is still a plain `str`, so
  unkeyed servers see byte-identical traffic. 4 tests: the header and the URL on
  a real `Request`, the no-key/empty-key compatibility case, the config read,
  and the gate passing the token through (wired, not merely defined).
  Documented in `README.md`, `docs/API.md` (the `gpu_busy` paragraph) and
  `deploy/chopshop-flux.env.example`.

- **LANDED: `CHOPSHOP_FLUX_DTYPE` — the compute dtype is a knob, and on a card
  without native bf16 it is a CORRECTNESS switch.** `engine.py` loaded both the
  pipeline and the VAE with a hardcoded `torch.bfloat16`. That is right on the
  card this was written for (gfx1201, native bf16) and wrong on Turing (sm_75),
  where bf16 GEMMs are executed by upcasting — MEASURED on a Tesla T4,
  4096x4096 GEMM, torch 2.14.1+cu130: **float16 5.55 ms, bfloat16 54.94 ms,
  float32 32.42 ms** (bf16 is 9.90x slower than fp16 and slower than fp32). The
  cost was real: a `klein-4b` 512 px / 4-step frame took **1050 s** in bf16 and
  **28.5 s** in fp16. It also fails outright in bf16 on that card:
  `sana-sprint-0.6b` raises `RuntimeError: GET was unable to find an engine to
  execute this computation` from a `conv2d` inside Sana's DC-AE
  (`autoencoder_dc.py` → attention → `proj_in`) — cuDNN has no engine for that
  conv shape in bf16 on sm_75, and the same model generates in fp16. The
  lesson worth keeping: plain bf16 matmul, conv2d and SDPA all RUN on sm_75,
  which is what made this invisible; "runs" is not "runs fast", and a per-op
  probe does not cover every conv shape a real model uses.
  `config.compute_dtype()` reads `CHOPSHOP_FLUX_DTYPE` (`bfloat16` default |
  `float16` | `float32`) at call time and refuses an unrecognised value;
  `engine.compute_dtype(torch)` resolves it with `getattr` rather than a dict
  literal, so a test stub carrying one dtype still works. Both
  `from_pretrained` sites use it, and a test asserts no `torch.bfloat16`
  literal survives. Unset behaviour is byte-identical, so the ROCm box is
  unaffected. MEASURED here after the change: `sd-1.5` 512 px 23.1 s,
  `ssd-1b` 768 px 56.0 s, `sana-sprint-0.6b` 512 px 9.0 s, `klein-4b` 512 px
  28.5 s. Documented in `README.md`, `docs/API.md` and
  `deploy/chopshop-flux.env.example`.

- **IN PROGRESS: the novita remote backend.** Two hosted models
  (`ming-image-0.1-design` t2i, `ming-image-0.1-design-layer` layer-decouple
  edit) are registered with `backend: "novita"` and reached through
  `chopshop_flux/remote.py` (`NovitaClient`). The client is stdlib-only
  (urllib, json, base64) with two network seams (`_post_json` for generations,
  `_post_multipart` for edits). The engine dispatches on `backend` — `"local"`
  goes through diffusers, `"novita"` through the remote client — and the
  response shape is the same either way. The registry entries carry
  `min_dim: 1024` (the API documents 1k-and-above), `vram_gb: 0`,
  `repo_bytes: 0`, and inert `default_steps: 1` / `default_guidance: 1.0`
  placeholders (the API has no step/guidance control). `commercial_ok: false`
  (Novita Terms of Service). The User-Agent is mandatory — Cloudflare 403s
  urllib's default UA. An opt-in smoke pass (`scripts/smoke_examples.py
  --include-remote`) measures the real API behaviour. Tests: 620 passed,
  3 skipped. Docs: `docs/API.md` § "Remote (API) models", `docs/MODELS.md` §6,
  `docs/contract.md` § "The `backend` field".

- **MEASURED: the output-side passes against REAL generations (#8, 2026-09-29).**
  The passes themselves landed in `4bfa241` with numbers measured over the
  pipeline's own EXAMPLE rasters — real code, real pixels, but no model
  involved. These runs close that half: real klein-4B and SDXL generations on
  this card, passes applied by the engine to frames it had just decoded, via
  `scripts/smoke.py --ink-cap N --hires --background key --seeds ... --provenance`.
  Full tables in `docs/API.md` under "MEASURED on real generations".
  Four findings, none of which the example rasters could have shown:
  - **`hires` is UNAVAILABLE on the default model.** klein-4b and klein-4b-base
    are refused (`Flux2KleinPipeline` has no `strength`, so a second pass cannot
    say how far it may move). It needs `img2img_strength: true` — the other six
    entries. The default model cannot use the flagship pass.
  - **A `hires` second pass roughly DOUBLES the cost.** SDXL 512→1024² at
    strength 0.35: pass 1 4.21 s, pass 2 7.80 s. The second pass is dearer than
    the first because it runs at 4× the pixels. Budget ~1.9×, not ~1.3×.
  - **`background: "key"` keyed 0 of 3 real frames.** The flood matches border
    colours EXACTLY and a model's "flat white" is `#fcfdfd`/`#fdfdfd`/`#fdfdfe` —
    off by one in a single channel. Correct to refuse rather than guess, but the
    practical reading is that `key` is inert on model output; `white` is the
    mode that does something.
  - **A met cap can still be a degenerate palette.** Every real 3- and 4-colour
    result clustered at the extremes (klein: `#000000` + two near-whites; SDXL:
    one dark + three near-greys within 30 units). The cap is satisfied and the
    picture is flattened — which is what the `palette` list in the response is for.
  - Minor, real, and **since fixed (#13)**: `hires.steps` did NOT inherit the
    request's steps — `hires.steps or spec.default_steps` meant `--steps 20`
    ran pass 2 at the model's default 30 while pass 2 is the dearer pass
    (measured 4.21 s then 7.80 s). Pass 2 now inherits the request's count
    unless `hires.steps` is set explicitly, and the report carries both
    (`steps`, `requested_steps`) so the deviation is visible.
  - `ink_cap` and `seeds` are sound on real frames: 19 122 / 16 044 / 11 954 → 3
    colours, and a 2-seed sweep returned 2 frames (7.06 s cold, 3.26 s warm),
    0 blank, 0 NaN.

- **LANDED: the W2 output-side passes** — `docs/MODELS-PLAN.md` §3, which
  absorbed its own brief (`MODELS_BRIEF_B.md` was retired into it by
  `5cae8a0`). `hires` (generate → upscale → img2img at low strength),
  `ink_cap` (+`ink_cap_mode`), `background`, `seeds`, per-family negative-prompt
  defaults, and per-frame provenance. New module `chopshop_flux/postprocess.py`
  holds the pixel passes and is **stdlib only** — no PIL and no torch — so the
  suite drives the real reduction, the real flood key and the real colour counts
  on real bytes instead of asserting that a key exists. New keys on `/generate`
  and `/edit` (`ink_cap`, `ink_cap_mode`, `background`, `hires`, `seeds`,
  `provenance`), CLI flags for all six, `ModelSpec.default_negative_prompt` +
  `PRINT_NEGATIVE_PROMPT` in the registry, a `<name>.json` provenance sidecar
  beside each frame, and `scripts/probe_output_path.py` (the no-GPU before/after
  capture — **not** a test). Tests 379 → 488; `docs/API.md` documents every key.
  The facts from doing it that are worth not rediscovering:
  - **The passes run in a FIXED order: `hires` → `ink_cap` → `background`.** The
    cap has to see the frame that will be judged, and the key has to see the final
    palette; a key first would put a colour into the reduction's histogram that is
    not part of the artwork.
  - **`ink_cap` is a colour tool, NOT a node tool — and that is measured, in the
    pipeline's own repo.** `chopshop-svg`'s `skills/chopshop-svg-pipeline/SKILL.md`,
    `README.md` and `scripts/im_filters.py` all carry the same measurement:
    quantising the SOURCE raster (pngquant / PIL median / max-coverage / octree,
    6–48 colours) leaves max nodes where it was — 967 → 912 (median 16) → 1415
    (median 6). So no traceability claim is made for `ink_cap`: it exists because a
    screen printer wants few flat inks (`max_colors`, `prep_colors`). The trace
    levers are noise and soft gradients, which is what the default negative prompt
    names. Do not sell the cap as producing fewer nodes.
  - **A cap is MEASURED, never promised.** `colors_present` is counted from the
    buffer that is written. A frame already at the cap is a skip: `changed: false`
    and "nothing was reduced", with the file byte-identical. Posterize is a
    per-channel bit reduction, so its reachable counts are `2**(3*bits)` — an
    `ink_cap` below 8 with `ink_cap_mode: posterize` is a `400` rather than a
    silent 8. It is a colour REDUCTION, never a separation, and the note says so.
  - **`hires` cannot reach a print target, and the docs say so.** `sdxl-1.0` and
    `ssd-1b` cap at 2 MP, so at 1024 px there is no room for even a 1.5× second
    pass (2048² = 4.19 MP); the klein rows have no `strength` parameter and refuse
    `hires` outright. `~/chopshop-svg/spec.example.json` wants `dpi: 300` — ~3600 px
    for a 12-inch front — which is an order of magnitude past every entry's cap.
    The tiled upscale that could reach it (W2.4) is **not implemented** and the
    API doc says tiles can show seams rather than selling them.
  - **The determinism evidence is an executable probe.** `git archive HEAD` into a
    scratch dir, run `scripts/probe_output_path.py` against it and against this
    tree: the two outputs diff clean — identical pipeline kwargs, identical PNG
    sha256, identical response body. Those values are pinned in
    `tests/test_output_features.py` so a future edit cannot move them quietly.
    (The GPU's own bit-identity for a seed is not measurable here and is not
    claimed.)
  - **Disclosed behaviour change, and the only one on the default path:** the four
    entries with a real `negative_prompt` (`sdxl-1.0`, `sdxl-turbo`, `sd-1.5`,
    `ssd-1b`) now send the print default when a request gives none, marked
    `negative_prompt_source: "default"`; `"negative_prompt": ""` opts out. The
    entries with no such parameter keep the "ignored, with a warning" answer.
  - **Mechanical detail that surprised nobody but cost a lookup:** a `hires`
    target is computed from the frame that ACTUALLY came back, not from the
    requested size — a resolution-binning pipeline (Sana Sprint) re-bins, and the
    report has to be about the frame that exists.
  - **The studio's mirror is now behind the registry.** chopshop-studio's
    `app/models/flux_conf.rb` hand-transcribes this registry and does not carry
    `default_negative_prompt`; that is a chopshop-studio (W3) change, recorded
    here so the drift is not silent.

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

- LANDED: **the W1 candidate pass (2026-09-29) — `docs/MODELS-PLAN.md` §2 taken to
  a decision per candidate, recorded in `docs/MODELS.md` §5.** One registration
  and four refusals, each with the measurement behind it:
  - **`z-image-turbo` registered** (`Tongyi-MAI/Z-Image-Turbo`, 6B
    `ZImagePipeline`, Apache-2.0). MEASURED on the card under `offload=cpu`:
    load 55.8 s, 1024×1024 at 9 steps / guidance 0.0 in 41.3 s first call and
    17.0 s after, both frames non-blank, peak 15.52 GB (14.45 GiB) of the 15.92 GiB
    card. The repo stores the transformer (24.61 GB) and text encoder (8.05 GB) in
    **fp32**, so `torch_dtype=torch.bfloat16` halves the resident module to ~12.3 GB
    while the download stays 32.8 GB — the §1 rule, not an exception. `dim_multiple`
    16 comes from `ZImagePipeline.__call__`'s own divisibility check
    (`vae_scale_factor * 2`); `min_dim` 128 and the 1 MP cap are policy, marked
    ESTIMATE. Guidance is **not** a no-op: `do_classifier_free_guidance` is
    `guidance_scale > 0`, so 0.0 vs 4.0 differ by 25.11 mean absolute pixel
    difference (MEASURED) and the entry sets `guidance_embedded=True` to suppress a
    warning that would be false. `/edit` is the separate `ZImageImg2ImgPipeline`
    (verified, 49.3 s, non-blank).
  - **Refused: `lodestones/Chroma1-HD` / `Chroma1-Flash`** — the deciding module is
    a 17.80 GB (16.58 GiB) bf16 transformer; the real module fills 15.70 GiB of the
    15.92 GiB card and dies, and a bare allocation of the same size fails while
    12.30 GB (Z-Image's module) succeeds on the same card. Stored bf16, so the
    dtype trick gives nothing back.
  - **Refused: `Qwen/Qwen-Image-2.1`** — Qwen **Research** License (non-commercial
    only), *and* `QwenImage21Pipeline` does not exist in the installed diffusers
    0.40.0 (the GPU environment must not be modified), *and* its 17.54 GB text
    encoder is over the card. Not downloaded: 33 GB for a model that cannot load.
  - **Refused: `black-forest-labs/FLUX.2-klein-9B`** (gated `auto` + FLUX
    Non-Commercial; transformer also 16.91 GiB) and
    **`stabilityai/stable-diffusion-3.5-medium`** (gated `auto` behind a terms
    form; fills no gap SDXL/SSD-1B/klein leave).
  - Tests 379 → 392 (`tests/test_models_new.py` carries the z-image section and
    pins the refusal list against `docs/MODELS.md` §5); `examples/prompts.json`
    gained two `z-image-turbo` rows (t2i + the family's img2img edit) because the
    example set's coverage check requires every registered model.
  - **The studio mirror is now stale by one entry.** `chopshop-studio`'s
    `app/models/flux_conf.rb` hand-transcribes this registry (`MODELS`,
    `DEFAULT_MODEL_KEY`, the per-family dimension rules, every default). It has to
    gain `z-image-turbo` (Apache-2.0, `ZImagePipeline` /
    `ZImageImg2ImgPipeline`, dim multiple 16, min 128, 1 MP cap, 9 / 0.0,
    `distilled` true, `guidance_embedded` true, `negative_prompt` true,
    `img2img_strength` true) in the same change, or its parity test fails. That is
    W3's work (`docs/MODELS-PLAN.md` §4, in `chopshop-studio`), not this pass's.
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
  (SSD-1B and the Sana rows are Apache-2.0 too), its registry counts ("eight
  checkpoints", "four diffusers families" — now nine and five, with
  `z-image-turbo`/`Z-Image` missing from both the count and the measured-facts
  list) and its missing unload/memory
  hard rule are stale, and an automated edit was blocked (it is a protected
  agent-instruction file). A human or a consented session should land those three.
- **LANDED: the idle-exit restart, and a client that rides it out (#3).** An idle
  unload does NOT return the memory (MEASURED: 16.2 GB of `RssAnon` still held
  after a successful unload), so `CHOPSHOP_FLUX_IDLE_EXIT` drains — every route,
  `/health` included, answers `503 {"kind": "restarting", "retry_after": …}` for
  `CHOPSHOP_FLUX_DRAIN_SECONDS` — and then exits non-zero so the unit's ordinary
  `Restart=on-failure` brings the service back (MEASURED end to end: 16.22 GB →
  0.01 GB, available RAM 28 → 43 GB). The client waits out both halves
  (`CHOPSHOP_FLUX_RECONNECT_ATTEMPTS` / `_BACKOFF`): a refused connect and that
  drain 503 are retried, and exhausting the budget reports exit `3` ("looks like
  it is restarting"), never `5` — so a chain's step landing in the window is not
  reported as a generation failure. Written down in README ("The idle-exit
  restart, and how a client rides it out"), `docs/API.md`'s env and error tables,
  and `deploy/chopshop-flux.env.example`.
- **LANDED: `/health` now says WHICH busy it is, and it reads the card at
  startup (#5, #14).** `gpu_guard.waiting: true` covers exactly the window
  `CHOPSHOP_FLUX_GUARD=wait` is holding a request — `busy` alone is true for
  that whole window too (`generate` sets it before `load` runs the gate), so a
  poller could not tell "generating, be patient" from "held by another process,
  which a resident model never releases", and those want opposite answers.
  `serve()` now takes a free-VRAM reading before the socket is bound
  (`FluxEngine.probe_guard`, skipped for `guard=off` and for a misconfigured
  value, both so `/health` — not the startup — reports them), so a start or an
  idle-exit restart no longer says `measured: false` while another tenant holds
  the card: the window a generation once OOM'd into instead of being refused
  `503 gpu_busy`. While nothing is loaded the reading is re-taken on each
  `/health` call, so it can never be the startup number wearing `measured:
  true`. Documented in `docs/API.md`'s new "Reading `gpu_guard`" section; 8
  tests, 7 of which fail without the code (verified by reverting
  `engine.py`/`server.py` and re-running them).
- **Multi-reference is now EXERCISED, not just declared** (issue #1). The
  example set's `reference` field is a string for an ordinary edit and a LIST for
  a multi-reference one — `reference_ids()` is the single place the two shapes are
  read, and `_validate_references` refuses a list on a model whose registry row
  does not declare `multi_reference`, a repeated id, an empty list, and a chain
  (a reference that is itself an edit). `examples/prompts.json` carries
  `klein-dual-reference-edit`, and `scripts/smoke_examples.py --only` now pulls in
  EVERY reference an entry names, because a partial conditioning set is a
  different request rather than a smaller one.
  `scripts/smoke.py --multi-reference` is the real demonstration: four
  generations, and the verdict is that the one-reference frame and the
  two-reference frame have DIFFERENT sha256 digests at the same prompt, seed and
  steps. That is the comparison the issue asked for, and it can fail — a pipeline
  reading only `image[0]` produces byte-identical frames and the run exits 5. It
  is a smoke case, not a test (real weights, GPU): what the test suite pins is
  the part that interprets the render. On a single-reference family it declines
  before generating and reports `passed: null` — not applicable is not failed.
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

- **The card is shared, and nothing arbitrates it.** This box also runs LM
  Studio (and ollama). Measured: LM Studio's `llama-server` held **16.21 GB of
  the 17.10 GB** card with a 262144-context model resident, while one klein-4b
  `offload=cpu` stage wants ~5 GB. Both cannot be true at once, and on ROCm the
  loser is not necessarily the process that asked second. `guard.py`
  (#flux-gpu-guard) checks free VRAM before a load and, depending on
  `CHOPSHOP_FLUX_GUARD`, notes / waits / refuses. An occupied card is a `503
  gpu_busy`, never a `400`.
- **LM Studio cannot be asked whether it is queuing.** Its REST API
  (`GET /api/v0/models`) reports per-model `state`: `loaded` / `not-loaded` —
  and that is all. Sampled every 2 s across an active generation, the state
  stayed `loaded` and the endpoint kept answering in ~1 ms; `/api/v0/stats`,
  `/api/v0/queue` and `/metrics` are 404 on 0.4.24. The busy state exists only in
  the CLI (`lms ps` prints `IDLE` -> `GENERATING`), which this repo will not
  shell out to. So the guard gates on **free VRAM**, which catches every holder,
  and uses LM Studio's loaded list only to name one.
- **The default model is guidance-distilled (CFG ~1.0), so a negative prompt has
  little effect.** `is_distilled` comes from the repo's `model_index.json` (`true`
  for klein-4B) and gates `do_classifier_free_guidance` (`guidance_scale > 1 and
  not is_distilled`), so CFG never runs and diffusers logs "Guidance scale X is
  ignored" — there is nothing to wire. Steering goes into the positive prompt plus
  the source image; the service says so in `warnings` rather than accepting a knob
  it silently drops.
- **Multi-model registry, per-family rules — never global.** Nine entries:
  `klein-4b` (default), `klein-4b-base`, `sdxl-1.0`, `sdxl-turbo`, `sd-1.5`,
  `ssd-1b`, `sana-sprint-0.6b`, `sana-sprint-1.6b`, `z-image-turbo`.
  FLUX.2 [klein] does 64×64–4 MP on multiples of 16; SDXL, SSD-1B and SD 1.5
  floor at 128, multiples of 8, 1–2 MP cap; **Sana Sprint floors at 512, multiples
  of 32, 1 MP cap** — its VAE is a 32×-downsampling `AutoencoderDC`, not an 8×
  `AutoencoderKL`, which is where that rule comes from rather than from taste.
  **Z-Image is multiples of 16 and nothing else** — that is its own
  `ZImagePipeline.__call__` raising unless each side is divisible by
  `vae_scale_factor * 2`, which is 8 × 2 for its four-block `AutoencoderKL` — and
  its 128 floor and 1 MP cap are the registry's policy rather than the class's, so
  its `notes` say ESTIMATE for those two. Its text-to-image class takes no `image=`
  at all: `/edit` for that family is the separate `ZImageImg2ImgPipeline`.
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
- **Binds `127.0.0.1:8795` by default — loopback on purpose** (`8787` is
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
