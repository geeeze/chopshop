# This file is not the tracker

**GitHub issues are this repo's tracker.** `AGENTS.md` says so, and
`docs/agents/issue-tracker.md` holds that policy. This file was a second,
hand-maintained list, written when the GitHub credential looked unusable; every
item in it has since landed or been filed, so keeping it current here only ever
produced duplicates and stale verdicts — it listed flux#8 as open after
`eeee3d1` closed it, and called the GPU-contention guard "pending commit" long
after `63df883` landed it.

**Do not read status from this file.** It is a mapping, kept because the history
of how those items were catalogued is worth having; status lives on GitHub,
where it cannot rot.

## Where the old entries went

| entry (as it was written here) | filed as |
|---|---|
| output-side passes never run on real weights | `geeeze/chopshop-flux#8` |
| hires cannot reach a print size (no tiled route) | `geeeze/chopshop-flux#9` |
| AGENTS.md stale behind the write guard | `geeeze/chopshop-flux#10` |
| the unread `requested_*` / produced dimension pair | `geeeze/chopshop-flux#11` |
| studio mirror missing `default_negative_prompt` | `geeeze/chopshop-studio#22` |
| bare `pytest` collects root-owned runner-data | `geeeze/chopshop-svg#3` |
| free-VRAM gate before the torch import (the guard itself) | landed in `63df883`; its follow-ups are `geeeze/chopshop-flux#4`, `#5`, `#14` |
| GAPS.md ledgers, "deleted per `scratch/issue-gaps-decision.md`" | `GAPS.md` was retired by `d3747b1`, which ported its four open items into this file — they are the four flux rows above |

## Two notes about the file this replaced

- The `scratch/` paths it named (`scratch/flux-commit-msg.txt`,
  `scratch/issue-gaps-decision.md`) do not exist in this checkout — they were
  working notes on the machine that wrote it, which is how a reader following
  them found nothing.
- It said "The five items below are filed" above a table with six rows, and
  kept open/closed verdicts in prose. Both problems came from duplicating a
  tracker; neither is repeated here.
