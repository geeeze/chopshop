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

## Transfer map (2026-10-22)

The 23 issues that were open on the six component repositories now live here.
Numbers changed; old links still resolve to the archived repositories, so a doc
or commit message citing `chopshop-studio#110` is a pointer to the frozen copy,
not to the live ticket.

| was | now |
|---|---|
| `chopshop-studio#115` | [#2](https://github.com/geeeze/chopshop/issues/2) |
| `chopshop-studio#114` | [#3](https://github.com/geeeze/chopshop/issues/3) |
| `chopshop-studio#113` | [#4](https://github.com/geeeze/chopshop/issues/4) |
| `chopshop-studio#112` | [#5](https://github.com/geeeze/chopshop/issues/5) |
| `chopshop-studio#111` | [#6](https://github.com/geeeze/chopshop/issues/6) |
| `chopshop-studio#110` | [#7](https://github.com/geeeze/chopshop/issues/7) |
| `chopshop-studio#109` | [#8](https://github.com/geeeze/chopshop/issues/8) |
| `chopshop-studio#107` | [#9](https://github.com/geeeze/chopshop/issues/9) |
| `chopshop-studio#106` | [#10](https://github.com/geeeze/chopshop/issues/10) |
| `chopshop-studio#104` | [#11](https://github.com/geeeze/chopshop/issues/11) |
| `chopshop-studio#99` | [#12](https://github.com/geeeze/chopshop/issues/12) |
| `chopshop-studio#91` | [#13](https://github.com/geeeze/chopshop/issues/13) |
| `chopshop-studio#89` | [#14](https://github.com/geeeze/chopshop/issues/14) |
| `chopshop-studio#84` | [#15](https://github.com/geeeze/chopshop/issues/15) |
| `chopshop-studio#83` | [#16](https://github.com/geeeze/chopshop/issues/16) |
| `chopshop-studio#80` | [#17](https://github.com/geeeze/chopshop/issues/17) |
| `chopshop-studio#57` | [#18](https://github.com/geeeze/chopshop/issues/18) |
| `chopshop-studio#56` | [#19](https://github.com/geeeze/chopshop/issues/19) |
| `chopshop-studio#53` | [#20](https://github.com/geeeze/chopshop/issues/20) |
| `chopshop-studio#52` | [#21](https://github.com/geeeze/chopshop/issues/21) |
| `chopshop-flux#31` | [#22](https://github.com/geeeze/chopshop/issues/22) |
| `chopshop-flux#27` | [#23](https://github.com/geeeze/chopshop/issues/23) |
| `chopshop-jev#14` | [#24](https://github.com/geeeze/chopshop/issues/24) |
