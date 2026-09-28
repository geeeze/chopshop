# Review: two uncommitted feature streams in chopshop-studio

You are a NEUTRAL reviewer. You change and commit NOTHING. Your job is to read
two uncommitted diffs against the written briefs each implementer was given, and
return PASS/FAIL findings, not to fix anything.

The repo root is `~/chopshop-studio` (branch `main`, clean, HEAD `5f7d82e`).
The two implementations live in separate worktrees:

- `~/chopshop-studio-dnd` (branch `feature/drag-drop`) — brief
  `DND_BRIEF.md` at that worktree root.
- `~/chopshop-studio-preview` (branch `feature/preview-popups`) — brief
  `PREVIEW_BRIEF.md` at that worktree root.

## What to do

For EACH worktree, independently:

1. Read the brief file in that worktree root, then read the uncommitted diff
   (`git -C <worktree> diff` plus untracked files `git -C <worktree> status`).
2. Check every claim the brief makes is actually implemented, and every hard
   rule is honoured. Specifically watch for:
   - DND: does dragging a drawer/picker thumbnail onto `#compCanvas` call
     `addLayer`? Do job-show thumbnails drag onto the drawer/toggle and fire
     the SAME favourite POST the star uses (no second code path)? Is the
     `dragleave` child-guard correct? Any dropped payload accepted without
     validation?
   - PREVIEW: does `#reuse` only accept source.png/source.inverse.png? Does
     it clone the spec into `session[:spec_draft]` and NEVER auto-run? Does the
     toolbox decorate image popups only (non-image popups untouched)? Does the
     hue apply as a CSS filter (never a file mutation)? Does save canvas-export
     main + reference with hue baked, then POST `/scrapbook/import`?
   - Both: no hostnames/IPs/paths leaked; no new dependencies; inline SVG icons
     not text glyphs; popups use `&times;` close (`PopupCloseStandardTest`); no
     credential touched; changes UNCOMMITTED (no precompile/restart/deploy).
3. Run the suite yourself in each worktree and record the EXACT final line:
   `bin/rails test` and `node --check app/javascript/aether.js`.
4. Look for actual bugs the implementer's own tests would miss — e.g. an
   `[hidden]` attribute overridden by a display rule (the CSS claims to handle
   this; check it is complete), a CSRF token read as `.content` vs
   `.getAttribute('content')` inconsistency, an HTML-injection path through an
   interpolated attribute, or a drag payload that is parsed but not validated.

## Output format (one short message, no edits)

Two sections, one per worktree, each with:
- **Verdict:** SHIP or FIX-FIRST.
- **Suite:** the exact `bin/rails test` tail line + `node --check` result.
- **Findings:** numbered, each with `file:line` and a one-line reason. Mark
  each BLOCKING or NIT. If none, say "no findings".
- **Hard-rule violations:** any, or "none".

Be specific and cite line numbers. Do not re-implement, do not edit, do not
commit. Report only.
