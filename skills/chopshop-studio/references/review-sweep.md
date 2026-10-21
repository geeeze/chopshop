# Review sweeps — "review the whole suite and enhance it"

The ask arrives as one line ("comprehensive review of the suite and supporting
apps… test and evaluate… update the tracker… enhance the workflow and UX"),
often with a named reference app whose refinements should be incorporated.
The deliverable is NOT a report: it is the tracker made current AND fixes
shipped and live-verified. Filing alone is not delivering.

## Step 1 — Orient (one batch, before any subagent)

- Fleet state: `git fetch` + `rev-list --left-right --count HEAD...origin/<branch>`
  per repo (see `references/repo-fleet.md` for the sweep), noting dirty worktrees
  and which checkouts another agent is mid-work in.
- Live stack: which services answer (`/up`, health endpoints), and the tracker's
  open issues — the fix phase dedupes against them.
- Decide the fan-out from what the ask names; do not invent scope.

## Step 2 — Fan out (~3 subagents), then pull the drops yourself

Three roles cover almost every sweep; assign only what the ask needs:

1. **Live-stack dogfood QA** (read-only): walks the running app like an operator,
   collects console errors, broken flows, UX friction (the `dogfood` skill).
   Hard constraint: no repo, container, DB, or storage writes.
2. **Dropped-changes evaluator** (the only child allowed to write the tree):
   `git fetch` → read `git log HEAD..origin/main -p` FIRST → `merge --ff-only`
   (STOP and report if it refuses — never force) → review the diffs against the
   repo's standards → run the FULL suite and report counts VERBATIM with the
   skip breakdown. A green run whose evidence is skipped is not verified.
3. **Reference-app miner** (read-only), when the ask names one: crawl the live
   app AND its source (it usually lives on another host — read-only over ssh),
   and return a ranked backport list where every item names the target SURFACE
   and a smallest-reversible-change first step.

**Under concurrent merges, subagents go on the local/live stack FIRST and the
parent pulls drops as they land** (re-fetch near the end and pull again). Do not
wait for an in-flight merge to finish before starting the review.

## Step 3 — Consolidate into tracker updates

- **Verify every external-state claim before filing.** A QA report is a
  self-report: reproduce each finding at the layer where the effect must appear
  (a flash renders on the FOLLOWED page, not in a 302 body; a visual defect
  requires the element to actually paint) or against code. Findings whose
  premise does not survive are closed as already-done or not-reproducible with
  the evidence named — never filed open.
- **Dedupe against OPEN issues**: when a finding belongs to one, COMMENT the
  evidence there instead of filing a sibling.
- Batch-file the rest from a staged file via `scripts/file-issues.py`
  (`--dry-run` first; mechanics in `references/studio-backend-traps.md`), then
  file the FOLLOW-UPS reviews surface as their own issues — never fold them
  into the change in front of you.

## Step 4 — Fix in the one-issue-at-a-time loop

Claim → coder → neutral reviewer (named risky half, a reproduced bite) → the
PARENT ships: `references/working-a-studio-issue.md`. Blocking defects get
FIXED in the same sweep; the tracker records, it does not substitute. Keep the
main checkout single-writer: one coder at a time, the parent not committing
while a child holds the tree.

## Step 5 — Ship, verify, leave the record

Commit per issue (`fixes #N` auto-closes — the closing evidence goes up as a
`gh issue comment` after the push), rebuild + live-verify app-code changes
(`references/change-and-live-verification.md`), cross-link the sweep's issues
into `CONTEXT.md` in one pointer block, and park the full reports at a DURABLE
path (the scratch dir prunes) before summarising.

## Pitfalls

- **A skill edit mid-sweep reds the suite**: the app's test tree carries a
  sync-skills self-check that fails while the on-disk skill and the published
  copy differ. Publish (`./sync-skills`) and commit the published tree in the
  same pass; a suite failure naming that self-check is a publish reminder, not a
  code regression. (Measured pattern: `E2eTestingSkillTest#test_the_redaction_keeps_the_operator...
  (sync-skills_self-check)` — 1 failure, 0 errors, 0 skips, 4-file drift; publish clears it.)
- A docs-only drop can still break the suite for the same reason — read the
  failure, not the commit's subject. (Measured: `3cb766c` docs-only drop → same
  single failure; merge `--ff-only` refused is a stop, not a force.)
- **Stale branch references survive the fix that targets them**: when a doc
  references `agent/laya-container` in multiple lines, fixing one (line 18) leaves
  the same defect on another line (line 72) — scan the file again after the fix.
- **Reference-app miner deliverable shape**: ranked backport list, each item
  names the target SURFACE (e.g. `datasets/_surface.html.erb`), the observed kb
  refinement, and the smallest-reversible-change first step (revert = delete one
  block or restore the old path). Read-only over ssh when the app is remote; when
  the source is local (`~/vatkb/`), verify buildability (`bundle install`, `podman`
  availability) and whether remote services are needed (kb-app needs none; only
  rubygems.org for the gem install).
- A reviewer's CHANGES-REQUIRED verdict is two lists: what the change must fix
  (apply before shipping) and what it merely surfaced (file, do not fix here).
- The suite's runs/assertions totals drift between environments; quote
  runs/failures/skips VERBATIM and treat a changed total as a question, not a
  failure.
