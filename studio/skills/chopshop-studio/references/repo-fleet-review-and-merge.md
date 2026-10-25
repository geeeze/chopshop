# Landing agent branches across the repo fleet

How to take a batch of unmerged `agent/*` branches across the chopshop repos
(svg, studio, jev, sui, bp, flux, <dataset-pool>) from "code to review and merge" to
merged-on-`main`-and-verified. A vague ask like "there is chopshop code to
review and merge" means exactly this workflow: find them, review them, land them.

Scope: `geeeze/console` is off-limits unless the user names it in this session —
`ready-for-agent` labels there are not permission.

## 1. Find the pending work — never guess which branch

Survey every repo for branches ahead of `origin/main`:

```sh
for r in chopshop-svg chopshop-studio chopshop-jev chopshop-sui chopshop-bp chopshop-flux <dataset-pool>; do
  git -C "$r" fetch --all --prune -q
  git -C "$r" log --oneline origin/main..HEAD
  for b in $(git -C "$r" branch --format='%(refname:short)'); do
    n=$(git -C "$r" rev-list --count origin/main.."$b")
    [ "$n" != 0 ] && echo "$r $b ahead $n"
  done
  git -C "$r" worktree list
done
```

- `git merge-base --is-ancestor <branch> origin/main` → already merged, skip it.
- A branch whose tip subject matches an already-merged branch is often the same
  content under a second name. Settle it by patch-id, not by eye:
  `git show <commit> | git patch-id --stable` for both commits — identical ids
  mean the content is already on main, so a branch that "is not an ancestor"
  can still hold nothing new to land.
- The authoritative list of what was left unmerged is in the handoff of the
  session that pushed them. Recover it with `session_search` (e.g. query
  "chopshop review merge branch"); it returns the real messages, and the final
  summary names every branch and says nothing was merged.
- Dirty worktrees and untracked briefs next to a branch are residue from the same
  batch, not new work.

## 2. Review each branch on two axes, and run its suite

- **Standards**: the repo's own `AGENTS.md`, `docs/agents/standards.md`,
  `CONTEXT.md`, plus any `docs/*-conventions.md`. The repo's documented standard
  outranks any general opinion; skip what tooling already enforces.
- **Spec**: the originating issue. `gh issue view N -R geeeze/<repo>` works even
  where `gh pr list` does not — the token here can read issues but fails on PRs
  with "Resource not accessible by personal access token (repository.pullRequests)".
- Run the **full** suite on the branch, not just the tests it touches, and do it
  in a scratch worktree (`git worktree add <scratch> <branch>`) so the repo's own
  checkout and its other worktrees are untouched. Remove it afterwards and
  confirm `git status --porcelain` is empty.
- Read the **skip breakdown**, not just the pass count. A suite can be green with
  the whole acceptance evidence skipped: a branch whose four issues each required
  a real render reported 340 passed while all 38 render tests skipped for a
  missing `blender` binary — nothing the issues asked to be demonstrated had run.
  Report which evidence is unverified instead of quoting the green run.
- A scratch worktree cannot run a suite that needs gitignored install dirs
  (`vendor/bundle`, `node_modules`, `.venv`): bundler dies in `bundle/setup`.
  Point it at the main checkout's copies rather than installing into a throwaway
  tree — either the env form (`BUNDLE_PATH=<main-checkout>/vendor/bundle`) or a
  worktree-local `studio/.bundle/config` carrying the absolute path. A fresh
  worktree also has no test database: run `bin/rails db:prepare` inside its
  `studio/` once. Use the full load-bearing invocation,
  `RAILS_ENV=test env -u PYTHONPATH PARALLEL_WORKERS=1 bin/rails test` — `env -u`
  strips an ambient PYTHONPATH that breaks the suite, and `PARALLEL_WORKERS=1`
  keeps the single SQLite test DB from self-colliding.
- Subagent branches that live only in scratch worktrees are still
  cherry-pickable from the main checkout (one shared object database): amend
  review fixes into each branch tip (the branches are local-only, so amending
  loses nothing), cherry-pick the tips onto `main` in dependency order, and
  resolve a conflict by naming the source commit explicitly
  (`git checkout <commit> -- <file>`). On the `git rebase` inside a
  push-rejected loop, side-named resolution is INVERTED (`--ours` is upstream) —
  see the concurrent-git-writes skill; never resolve by side name.
- Batch review subagents ~3 per wave, one repo each, each doing both axes and the
  suite; keep the merges in the parent. Report test counts verbatim — a branch's
  commit message claims a count, so reproduce it.

## 3. Merge, then verify against the remote

- Dry-run the merge: `git merge-tree --write-tree origin/main <branch>` (git ≥
  2.38) prints the merged tree and names any conflicting paths without touching
  the checkout. The ref must resolve — passing `origin/<branch>` for a branch that
  exists only locally (or the bare name for one that is remote-only) fails, and
  that failure reads exactly like a CONFLICT that is not there. Check
  `git branch -a` before believing a conflict report.
- **Copy branch names from `git show-ref`, never retype them from memory.** A ref
  differing by one hyphen/underscore (`agent/svg-11-config` vs `agent/svg-11_config`)
  reports `fatal: ambiguous argument '…': unknown revision` — which reads as "the
  branch does not exist", so you conclude it is missing when it is right there
  under another spelling. Enumerate with `git show-ref | grep <prefix>` (or
  `git branch --format='%(refname:short)'`) and paste the exact name. And if the
  same command fails identically twice, stop and change approach — a third
  identical attempt cannot succeed.
- `git merge --ff-only` only when the branch contains `origin/main`. When main has
  moved since the branch was cut — another session, or the external Claude Code
  agent pushing concurrently — ff-only aborts with "Not possible to fast-forward".
  That is a real merge, not a broken branch: use `git merge --no-ff` with a
  message naming what the branch lands.
- **Never rebase a branch that is already pushed.** Merge it.
- Re-run the suite on the **merged tree** before pushing; the merge can combine
  two green branches into a red one. Do not judge it by the totals — capture the
  failing-test identifiers from both runs (`grep -E "^bin/rails test " out.txt |
  sort -u`) and `comm -23 merged.txt baseline.txt`. The baseline has to be run in
  the same tree shape and environment, or the comparison means nothing. An
  identical failure set is the proof of "no new failures"; the raw totals differ
  between branch and main for reasons that have nothing to do with quality.
- Push, then verify against the remote itself: compare
  `git ls-remote origin refs/heads/main` with `git rev-parse HEAD`. A push's own
  report is not evidence.
- Expect rejected pushes while the external agent works the same repos: fetch and
  merge, never force.
- Leave each repo's checkout back on the branch it was on when you started.
- **Merging is the deliverable; closing issues is not implied.** List the issues
  each merge satisfies and offer to close them — do not close unilaterally.
- **A review that lands after the merge is a defect already shipped.** Fix it
  forward on `main` in its own commit with a test, and say plainly that the merge
  preceded the finding rather than letting the merge commit stand as the fix.

## 4. Conflicts where main already landed the same change

Symptom: the same fix exists on both sides (a prior "doc/code alignment" pass
landed it on main). The conflict is textual; the semantics are duplicates.

- Keep the better-commented copy for source files, and **union** the test classes
  — dropping one side's tests is how a covered regression goes uncovered.
- Mechanical resolution: parse the `<<<<<<<` / `=======` / `>>>>>>>` blocks in
  Python and choose `ours` or `both` per file. Afterwards re-read the file's
  import block: both sides usually added imports in the same hunk and the
  auto-merge can leave one out.
- **Pitfall**: resolving the files in the working tree is not resolving the
  merge. `git add` them before committing — committing with unmerged index
  entries fails with "Committing is not possible because you have unmerged
  files", and the checkout is left mid-merge (the subsequent `git checkout main`
  then also refuses).

## Running one of these suites — the venv trap

- Symptom: `.venv/bin/python -m pytest` → `No module named pytest`, while
  `.venv/bin/pytest` exists; `.venv/bin/python -V` reports a newer minor than the
  venv was built for. Cause: the host `python3` moved (e.g. 3.12 → 3.14), so the
  venv's interpreter symlinks point at the new one while its site-packages still
  sit in `lib/python3.12`.
- Fix, per the repos' own instruction: `python3 -m venv --clear .venv &&
  .venv/bin/pip install -r requirements.txt`. The venv is untracked, so this is
  not a repo change; most of these repos are stdlib-only with pytest as the only
  test dependency, so the install is small.
- A segfault inside a C extension (vtracer) on a freshly upgraded host Python is
  an environment fault too: check whether the branch touches that code path
  before blaming the diff.
- Build a scratch venv with ONE pip command covering every dependency (`pip
  install pytest pygments packaging pillow lxml svgpathtools`): installing them
  in separate pip calls churned the resolver — a later call silently REPLACED
  packages an earlier one had brought in (`PIL`, then `pygments` vanished
  mid-sequence) — and the resulting collection error reads as a missing
  dependency, not as a resolver side-effect, so the reflex is to re-install the
  wrong package.
