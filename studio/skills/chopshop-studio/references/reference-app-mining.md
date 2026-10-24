---
name: reference-app-mining
---
# Reference-app mining (e.g. <reference-app>) — read-only backport procedure

Use when the user names a reference app (like `~/<reference-app>/`, a live site, or a remote source over ssh) whose refinements should be incorporated.

## Procedure

1. Load the source — `~/<reference-app>/` (directory, not git), remote over ssh, or live site. Note whether it needs remote services (`podman`, DB, gem install) and whether they are available locally.
2. Read the skill's design vocabulary (`token set`, `.chip`/badge, popup, guided choice, epistemic flags) — most refinements will already be landed; only the remaining ones are real work.
3. Compare against the studio's current state (load the relevant `references/*.md` files from `chopshop-studio`).
4. Return a **ranked backport list** — each item must name:
   - The **target surface** (e.g. `datasets/_surface.html.erb`, the sticky header, the Jev card, the audit gap count).
   - The **kb refinement observed** (the concrete CSS/JS/data change).
   - The **smallest-reversible-change first step** (revert = delete one block or restore the old path; never delete the vocabulary or the data source).
5. Note what of the source is buildable locally (`bundle install`, `podman` availability, gem version match) and whether remote services are needed.

## Pitfalls

- The source is not necessarily a git repo (`~/<reference-app>/` is a plain directory with `VATICAN-KB-REVIEW-*.md` and a `mimoclaw_workspace(2)/` subdir).
- Many refinements are already landed (token set, chips, guided choice, audit endpoint, graph view) — do not propose them again.
- When the kb's counts depend on its own tool (`needs_factcheck`, `disputed`), take the mechanism (badge + audit gap entry) but not its counts — reproduce from studio data.
- A stale branch reference (`agent/laya-container`) may survive in other lines of the same file; fix all occurrences.
- **Concrete session evidence (vatican kb `~/<reference-app>/`):** the kb-app (`kb-app/`) is a plain Rails 8 directory (not a git repo), buildable with `bundle install` (ruby 3.3.8 matches the Dockerfile), needs no DB or node build, and requires only rubygems.org (no remote service). The parent directory `mimoclaw_workspace(2)/<reference-app>/<reference-app>-rebuilt/` is a 100% byte-identical duplicate (delete candidate). The data layer (`<reference-app>/json/`) has a count discrepancy: served `index.json` = 1000 records; entity docs = 1004; audit endpoint data = same. Always cross-check counts against the studio source before adopting them.
- **Hidden-control filter trap (focus trap):** when adding a focus ring (`csFocusables`), exclude hidden controls (`display:none` / `visibility:hidden`) — otherwise `.focus()` is a no-op and focus leaks to BODY. Filter the ring, verify live (`document.activeElement` inside modal).
