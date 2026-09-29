# MODELS_BRIEF_B — better output from the models we already have

You are working in **`chopshop-flux`** (private): the generation layer for the
chopshop print pipeline — a small HTTP service and a registry of checkpoints. Read
`AGENTS.md`, `CONTEXT.md`, `docs/API.md` and `docs/MODELS.md` first. The spec you
are implementing is **`docs/MODELS-PLAN.md` §3 (W2)**; that section is the
authority, this brief is the operating instruction.

## The point

The biggest quality win available here is **not another checkpoint**. It is a
second pass, an enforced ink cap, an isolated background, a seed sweep, and
prompt/negative defaults that aim at the *tracer* rather than at the eye. The
pipeline traces flat art well and photographic gradients badly, so a generated
source is only good if it traces.

Implement, in this order (each is a spec field or an op, never a verdict):

1. **`hires`** — two-pass: generate at the model's native size → upscale
   (`lanczos` default, `scale` 1.5–2.0) → img2img at low `strength`
   (0.2–0.35 safe band; refuse or warn above 0.5, do not silently clamp).
   Refuse above the entry's `max_pixels`. Report each pass's seconds and the
   target size. This is the largest single quality win, so do it first.
2. **`ink_cap`** — after decode, reduce the frame to at most N flat colours
   (`quantize` or `posterize`), and record the cap AND the count actually present.
   When the reduction changes nothing, SAY so (a frame already at the cap is a
   skip, not work done). Never call it a colour separation; it is a reduction.
3. **`background`** — `white` | `key` | `keep`. `key` flood-keys a uniform border
   colour; if the border is not uniform, report "not uniform, left alone" and
   change nothing.
4. **`seeds`** — accept a list, file one frame per seed, return the seed→file
   mapping. Nothing is ranked.
5. **Per-family default negative prompts** for the entries that really have a
   `negative_prompt` (SDXL `sdxl-1.0`, `sdxl-turbo`, `ssd-1b`, `sd-1.5`), tuned
   for print (`gradients, soft shadows, photographic texture, hairlines, blur`).
   The request must ECHO what was sent, and the entries without a negative prompt
   keep the existing "ignored, with a warning" answer.
6. **Provenance for a later trace comparison** — record per frame the fields a
   comparison needs (`model`, `seed`, `prompt`, `ink_cap`, `hires`, dimensions) in
   the response and any sidecar. Do NOT add a scoring or ranking surface; the
   metrics/comparison side lives elsewhere.

## Measured facts you must not re-derive

- `offload=cpu` is the operating mode; `offload=none` does not fit (MEASURED:
  VAE decode dies with 174 MiB free at 512×512/4 steps).
- Tiled/large upscales are slow here and **stage paging dominates, not per-step
  compute** — do not claim a step-count speedup.
- Tiled upscaling can show seams at tile boundaries; if you implement it (only if
  `hires` cannot reach the print target), say so in the docs rather than selling it.
- A `taesd`/`taesdxl` tiny VAE decodes visibly softer — a trade, not a speed-up.
- VAE/LoRA build order is load-bearing (MEASURED): `from_pretrained` → scheduler →
  `load_lora_weights` → `set_adapters` → VAE → `enable_model_cpu_offload()` LAST.
- Print targets are large: a 12-inch full-front print at 300 dpi is ~3600 px. The
  pipeline's own spec uses `dpi: 300` and a `max_colors` cap — the numbers a
  generation needs to be useful come from there, not from a thumbnail.

## Evidence required

- A determinism test: a request using NONE of the new keys produces byte-identical
  output to the current build for the same seed.
- Per feature, a test that the key is validated (a bad value is a 400 naming the
  key, never a silent default).
- Any "improved" claim must be a comparison with the metric named — ink count, or
  a node count from an actual trace through `front_pipeline.sh`, or a mean absolute
  pixel difference. State which, with both numbers.
- `python -m pytest` green (no GPU, no torch, no network — that is the point of
  the suite). `scripts/smoke.py` on the GPU box is for real timings and must not
  become a test.
- `docs/API.md` updated for every new key in the same change; `GAPS.md`'s already
  recorded API gaps close in this pass if they are in your way.

## Hard rules

- stdlib service; torch only inside `engine.py` methods (a test pins that
  importing the server works without torch).
- No host, port or path hardcoded in code (environment variables only). The repo
  is private, so a HOST-SPECIFIC doc note is allowed — code is not.
- Never judge the art, never rank, never pick a winner.
- **Do NOT edit `AGENTS.md`** (write-guarded) — use `CONTEXT.md`.
- Never kill a process by `pkill -f <pattern>` when the pattern is in your own
  command line; kill by port (`ss -ltnp`) or PID.
- Do not commit; report the exact commands and their output.
