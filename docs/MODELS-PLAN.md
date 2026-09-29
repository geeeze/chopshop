# MODELS-PLAN — implementation spec: new checkpoints and better output

Status: **spec, not started.** Written 2026-09-29 after a research pass
(`docs/MODELS.md` carries the findings the user-facing docs need).

Two goals, one shape:

1. **Widen the registry** with the models that actually fit this box and whose
   licence is decidable — and record the refusals (§2).
2. **Get better output out of the models we already have**, without adding a model
   (§3). Most of the quality available here is not a new checkpoint; it is a second
   pass, a palette cap, a seed sweep, and prompting that aims at the *tracer*
   rather than at the eye.

Everything below inherits the repo's standing rules: **this layer calls the
pipeline, the pipeline never calls it**; **it never judges the art**; **stdlib
service, torch only inside `engine.py` methods**; **MEASURED or marked ESTIMATE**;
**no host, port or path hardcoded** (private repo, but the discipline holds).

## 1. What was measured while writing this

- The operative loading mode is `offload=cpu`, and the footprint rule is **the
  largest single module**, not the vendor's headline VRAM. `offload=none` does not
  fit even for the default (MEASURED: 15.01 GiB allocated, VAE decode died with
  174 MiB free).
- A step-count speedup **must not be claimed** under CPU offload: 4 steps vs 30
  measured 11.2 s vs 15.0 s (SDXL + LCM-LoRA, 512 px) — paging dominates.
- Guidance on a distilled checkpoint is a no-op except where it is embedded
  (`klein-4b`: ignored; Sana: honoured). Undistilled `klein-4b-base` differs by a
  mean absolute pixel difference of **34.38** between guidance 4.0 and 1.0.
- The HF API is the source of truth for licence/gating/sizes, and the candidate
  set already has a first reading (see §2). Repo sizes are the **download**;
  several store fp32, so the resident module is roughly half that after
  `torch_dtype=torch.bfloat16`.

## 2. W1 — registry candidates

Rule for every candidate, in this order: HF API enumeration → licence decidable?
→ **module-size measurement** → run one frame on the card and check for *content*
→ only then an entry, with each sentence in `notes` traceable to a measurement.

| candidate | licence (HF API) | gated | core download | action |
|---|---|---|---|---|
| `Tongyi-MAI/Z-Image-Turbo` (6B, `ZImagePipeline`) | apache-2.0 | no | ~33 GB | **register if it runs**: Apache-2.0, 8 NFEs, vendor claims <16 GB. Measure the transformer module and the per-frame time cold and warm. DiffSynth's own note: FP8 degrades it noticeably and CPU offload is the recommended low-VRAM route — so do NOT ship a quantised variant by default |
| `lodestones/Chroma1-HD`, `Chroma1-Flash` (8.9B, `ChromaPipeline`) | apache-2.0 | no | ~45 GB | **prove or refuse**: the bf16 transformer is ~17.8 GB against a 17.10 GB card. One honest attempt under `offload=cpu`; if it OOMs, record the refusal in `docs/MODELS.md` — do not quietly leave it out |
| `Qwen/Qwen-Image-2.1` (7B DiT + Qwen3-VL 8B encoder) | **Qwen Research License** | no | ~33 GB | **licence first.** Read the licence file; if commercial output is excluded, it may only be registered behind the existing non-commercial ACK, and `docs/MODELS.md` must say why. Also the only candidate advertising a native RGBA VAE — worth a look for background isolation |
| `black-forest-labs/FLUX.2-klein-9B` | FLUX Non-Commercial | **auto** | ~53 GB | **refuse** (gated + non-commercial): a different deployment story, and the same reason `sd-turbo` was refused |
| `stabilityai/stable-diffusion-3.5-medium` | other (community) | **auto** | ~28 GB | **refuse** (gated), and it fills no gap SDXL + klein leave |

**Acceptance criteria (W1)**

- Each candidate ends in exactly one of: a registry entry, or a documented refusal
  with its reason in `docs/MODELS.md` — never silence.
- An entry's `vram_gb` / `repo_bytes` are ESTIMATE only where the entry says so;
  anything run on the card is marked MEASURED with cold AND warm timings quoted
  together.
- A new entry ships with: its `pipeline` class, `edit_pipeline` if it has one, the
  resolution rules read from the pipeline's own signature (not copied from a
  sibling), `negative_prompt` / `img2img_strength` / `guidance_embedded` /
  `resolution_binning` flags as the class actually behaves, and a test that the
  entry validates.
- The registry's `/models` output stays the same SHAPE (three arrays), so a client
  reading `models` keeps working.

## 3. W2 — better output from the models we have

Ordered by value per unit of work. Each is a **spec field or an op**, never a
verdict on the art.

### W2.1 Ink/palette cap on the produced raster (`ink_cap`)

Ask for it in the prompt, *enforce* it on the pixels: after the frame is decoded,
reduce it to at most N flat colours and record `ink_cap` and the **count actually
present** in the response and the file's sidecar. Rationale: the trace stage and
any screen printer want few flat inks; the prompt steers, the pass guarantees.

- Default off. `ink_cap: 3` with `ink_cap_mode: quantize|posterize`.
- MUST report when the reduction did nothing (a frame already at 3 colours) rather
  than implying work — the same "missing/skipped is a state" rule the whole
  pipeline follows.
- MUST NOT be presented as a colour *separation*; it is a reduction, and the
  response says so.

### W2.2 Background isolation (`background`)

`background: "white" | "key" | "keep"`.

- `white` — ask the model for a plain white ground (already promptable).
- `key` — flood-key the border colour to transparent (or to white) and record what
  was keyed and how many pixels moved. This is the step every print workflow does
  by hand, and prep's own checks want it done.
- Never key when the border colour is not uniform; report "not uniform, left
  alone" instead.

### W2.3 Two-pass hires (`hires`) — the biggest quality win available

One spec block: generate at the model's native size, upscale, then **img2img at low
strength** with the same prompt and seed. The technique is standard; the work here
is doing it inside our contract.

```
"hires": {"scale": 2.0, "strength": 0.35, "steps": 20, "upscaler": "lanczos"}
```

- Only for entries with an `edit_pipeline`/`img2img_strength` (all but the klein
  family's distilled form, which edits with `image=` — treat it as supported via
  `/edit` and prove it).
- `strength` 0.2–0.35 is the safe band; above 0.5 composition drifts. Record the
  band in the doc, and refuse above the model's `max_pixels` rather than silently
  clamping.
- Report both passes (per-pass seconds, target size) so a slow route is visible.

### W2.4 Tiled upscale for large targets (only if W2.3 is not enough)

Tiles of ~512 px with overlap, feathered blend, one model per tile. This is the
route for a 3600 px print target on a 17 GB card. **Cost and seams are real**:
raise this only if W2.3 cannot reach the print size, and say in the docs that tile
boundaries can show. No new dependency — this is arrays and PIL.

### W2.5 Seed sweeps (`seeds`)

`"seeds": [1,2,3,4]` files four frames in one call and returns the mapping
seed→file. One frame is a sample; the operator picks. Nothing is ranked.

### W2.6 Per-family negative-prompt defaults, and an honest warning where there is none

Supply a default negative for the entries that have a real `negative_prompt`
(SDXL/SSD/SD 1.5), tuned for print (`gradients, soft shadows, photographic
texture, hairlines, blur`), and keep the existing "ignored, with a warning" answer
for the ones that do not. This is a default, not a silent insertion: the request
echoes what was sent.

### W2.7 Record the *trace* outcome next to the generation (the chopshop-specific win)

When a generation is handed to the pipeline, the studio already stores candidates
and their metrics. The generation side should record, per frame, the fields a
later comparison needs (`seed`, `model`, `prompt`, `ink_cap`, `hires`) so a
"which generation traced best" question is answerable from data — **without** this
service ranking anything. This is a data-contract change (the metrics schema
already exists in `chopshop-bp`), not a scoring engine.

**Acceptance criteria (W2)**

- Every feature above is optional and defaults to today's behaviour; a request with
  no new keys produces byte-identical output to the current build for the same seed
  (a determinism test, not a promise).
- Each new key is documented in `docs/API.md` and validated (a bad value is a 400
  naming the key, never a silent default).
- Nothing is reported as "improved" without a comparison: same prompt and seed,
  before/after, with the metric named (ink count, node count from a trace, or mean
  absolute pixel difference).
- The service still never picks a winner, and no new endpoint ranks frames.

## 4. W3 — docs and parity

- `docs/MODELS.md` is the new quality/fit/tips reference; link it from `README.md`
  (one line) and from the studio's `/flux` page.
- The studio carries a **hand-mirrored** model registry in `FluxConf`, pinned by
  `test/lib/flux_repo_parity_test.rb` (or the equivalent for this repo — check the
  studio side). Every new entry must be mirrored there in the same change, or the
  parity test fails; the page's model cards get the quality sentence from
  `docs/MODELS.md` (what it is good for), not a second copy of the numbers.
- `docs/API.md` gaps already recorded in `GAPS.md` (release/unload-lock, the new
  env vars, modifier/vae keys) close in the same pass.

## 5. Division of work, and what each subagent must NOT do

Three independent workstreams; briefs are files in the repo (`MODELS_BRIEF_*.md`)
so a child can read them in its own working directory.

| brief | repo | scope |
|---|---|---|
| `MODELS_BRIEF_A.md` | `chopshop-flux` | W1 — candidates: measure, register or refuse |
| `MODELS_BRIEF_B.md` | `chopshop-flux` | W2 — `ink_cap`, `background`, `hires`, `seeds`, negatives, provenance |
| `MODELS_BRIEF_C.md` | `chopshop-studio` | W3 — parity + the `/flux` page carrying the quality guidance |

**Do NOT, in any of them:**

- modify the GPU environment (no `pip install` into it; `peft`/`accelerate` stay
  vendored into `.vendor` and put on `PYTHONPATH`);
- claim a quality improvement, a speedup, or a VRAM figure without the
  measurement that backs it (blank-frame check included: a uniform PNG written as
  a success is the failure mode);
- register a model whose licence is not decidable, or a gated one;
- rank frames, pick a winner, or add an endpoint that does;
- touch `AGENTS.md` (protected) — record anything it needs in `CONTEXT.md`;
- run a `pkill -f`/`pgrep -f` whose pattern appears in the child's own command
  line; kill by port or PID.
