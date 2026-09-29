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
