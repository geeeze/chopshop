# Hanging threads / tracked issues (post-cycle, 2026-09-29)
- Flux GPU-contention guard (scratch/flux-commit-msg.txt -> refs #6 / #2 / #4 / #5)
  Description: Implement free-VRAM gate (CHOPSHOP_FLUX_GUARD) before torch import;
  reference AGENTS.md measured facts (LM Studio shared card, rocm-smi attribution).
  Status: pending commit; subagent completed doc/code pass. Blocked for live tracking: gh not auth.
- GAPS.md ledgers (all repos): deleted per scratch/issue-gaps-decision.md.
  Status: cleared; audit contents moved to docs (API.md, CONTEXT.md, agent docs).
- Cross-repo notes (not edited externally):
  - chopshop-studio / SURFACES.md + docs/agent-surface-gaps.md reference 8791 (svg runner port corrected in bp/docs/contract.md).
  - dmpool references chopshop-plot (not edited; noted in scratch).
- AGENTS.md protected-file blocks: chopshop-flux and chopshop-svg AGENTS.md require consented session.
  svg edit applied (line 163: 853 tests); flux requires no numeric fix but may need guard doc addition.
  Status: partially resolved (svg done, flux pending consent).
Note: `gh auth` missing; cannot open GitHub issues live. Tracker file serves as durable reference.

## Ported from GAPS.md when it was retired (2026-09-29)

The output-side work (hires / ink_cap / background / seeds / negatives /
provenance) landed with four items that had no home once GAPS.md was folded into
this file. They are OPEN, and each names what would close it.

- **The output-side passes have never run against a real generation.** They are
  verified against real bytes and the real code (45+51+15+8 tests, and a
  measurement over the pipeline's own example rasters), but no GPU has produced a
  frame through `hires`/`ink_cap`/`background`. `scripts/smoke.py` gained
  `--ink-cap/--hires/--background/--seeds/--provenance` so the box can produce the
  numbers; run it there and record real per-pass seconds, then this closes.
- **`hires` cannot reach a print-sized frame, and the tiled route is unbuilt.**
  Every entry's `max_pixels` is an order of magnitude short of the ~3600 px a
  12-inch 300-dpi front wants, and tiling can show seams — so it was not
  implemented rather than sold. Closing it means either a tiled MultiDiffusion
  pass with a seam measurement, or a documented decision that the print size is
  reached by the pipeline rather than by generation.
- **The studio's hand-mirrored registry lacks `default_negative_prompt`.** The
  service reports the per-entry print default; `chopshop-studio`'s `FluxConf` does
  not carry it yet, so the page cannot say a negative prompt was supplied for the
  operator. Mirror it in the studio and extend the parity test.
- **`AGENTS.md` is stale and is write-guarded** (its Layout table has no
  `postprocess.py`, its registry counts predate the ninth entry, its licence list
  is short). Needs a consented human edit; recorded here because the guard refuses
  an agent write.
- **`requested_*` vs produced dimensions have no consumer yet.** The provenance
  records both (a re-binning model can answer at a different size); nothing reads
  the pair. Worth a UI note when something does.
