# Issues — this repository

**GitHub issues on `geeeze/chopshop` are the only tracker.** Not this file, not a
`CONTEXT.md` status list, not a per-component scan.

```sh
gh issue list -R geeeze/chopshop
gh issue create -R geeeze/chopshop --title "svg: ..." --body "..." --label bug,ready-for-agent
```

## Filing

- Name the component in the title or the first line — `studio:`, `svg/`, `bp:`,
  `flux:`, `jev:` — and say which subdirectory the change lands in. There are no
  path labels; the prefix is the index.
- Five canonical triage labels, and the label string is the role name:
  `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`.
  Component labels (`studio`, `svg`, `bp`, `flux`, `jev`, `sui`) exist for
  filtering as well; use both.
- One issue per change. A finding that spans components is filed against the one
  that owns the code, with the others named in the body.

## Retired

Six `.github/ISSUES.md` / auto-review scan files lived in the component trees
(`studio`, `svg`, `bp`, `flux`, `jev`) before the consolidation. Each was a
one-off code scan; every item in them was resolved or filed elsewhere, and
keeping a second list in-tree only ever produced duplicate or stale verdicts.
They were deleted when the trackers merged. If you find one in old history, its
items are not open work.
