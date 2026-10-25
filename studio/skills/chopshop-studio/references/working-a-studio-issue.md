# Working a studio issue end to end

The loop the operator asks for when he hands over the studio backlog — "keep
working through them", "use subagents for coding tests and review one issue at a
time". Do ONE issue fully, then the next; do not batch or ask between issues.

## 1. Claim it (collision avoidance)
Concurrent agents work the same repos. Mark the issue YOURS before touching code:

    gh issue edit <n> -R geeeze/chopshop-studio --add-label ready-for-agent \
      --remove-label needs-triage --add-assignee geeeze
    gh issue comment <n> -R geeeze/chopshop-studio \
      --body "Claimed by Hermes agent (this session) — implementing now. Other agents: hands off #<n>."

The assignee + the comment ARE the hands-off signal the other agent reads.

## 2. Branch
`git checkout main && git pull --ff-only && git checkout -b agent/issue-<n>-<slug>`.

## 3. Coder subagent
Hermes `delegate_task` (NOT opencode — the child must run `bin/rails test`).
Brief it with: repo + branch + the issue, the EXACT fix, the test entry point,
and the hard rules — add a test that FAILS when the fix is reverted, do not
commit/push/deploy, leave it STAGED and uncommitted (`git add` its files, so the
parent's `git diff --cached` is the whole change). It reports the diff + full-suite
tail, and it names the riskiest decision IT made for the reviewer to attack.

## 4. Neutral reviewer subagent
A SEPARATE `delegate_task`: read the diff against the issue, prove the test is
NON-VACUOUS (revert the fix, watch it fail, restore), re-run the full suite
itself, return PASS/FAIL + ship/fix-first with file:line. It changes nothing.
Steer it at the actual risk — a fake green (a test that passes with the fix
reverted), or a change that newly refuses input the app accepted before. Name
the change's RISKIEST decision explicitly and make the reviewer rule on it
("attack here hardest"), plus any claim in the coder's self-report you doubt.
- **Prove the bite's mutation LANDED before trusting any verdict that rests on
  it.** Print the mutated line (or assert the old text is gone) right after
  editing and BEFORE running — a sed/regex that silently no-ops leaves the
  suite green and manufactures "the test cannot fail" confidence in reverse
  (the "mutation that never landed" trap in `probe-verification-failures.md`).
  Mutation → failing test → restore → green is evidence only when the mutation
  is proven present.
- Name any KNOWN infrastructure failure in the brief (e.g. the sync-skills
  publish reminder above) and require the verdict to separate it from real
  failures — one red line otherwise buries the review. A reviewer that mutates
  anything restores it and confirms `git diff --cached --stat` matches the
  original before returning.

## 5. Parent: land it
- Inspect the diff yourself before trusting any child's "done".
- Commit BARE on the branch — the repo config already carries the right identity
  (`geeeze <156519592+geeeze@users.noreply.github.com>`); NEVER pass
  `-c user.name=...`, which overrides it and mis-attributes the commit.
- `git checkout main && git merge --ff-only <branch> && git push origin main`.
- `docker compose build` (foreground) then `docker compose up -d` — the terminal
  guard treats `up -d` as a long-lived server, so run it with background=true.
- Browser-verify the live page (below), then close: a `fixes #<n>` in the commit
  message auto-closes the issue on push, so post the summary as a COMMENT (the
  `gh issue close --comment` will say "already closed"). Delete the branch.
  - **A CHANGES-REQUIRED verdict with surgical, fully-specified findings (one
    selector, one test case, one doc line) can be applied by the PARENT directly**
    instead of re-dispatching the coder — same rigor: re-run the full suite and
    re-prove any bite the findings changed, and name in the closing comment which
    findings were applied and which reviewer ruled on them.
  - **When the fix turns an existing test red, read what that test ASSERTS before
    touching it.** A test asserting the defect's own literal (a placeholder
    label, a wrong message, an unstyled state) is a false specification: re-point
    it onto the fixed behaviour in the same commit and say so in the closing
    note. Grep the test tree for the defect's literal as a standing step of any
    visual/copy fix — the pin is usually hidden in an assertion that looks
    unrelated.

## The full suite is green — the old "1 expected failure" baseline is GONE
The suite used to carry ONE permanent failure,
`E2eTestingSkillTest#test_the_redaction_keeps_the_operator/disposable_distinction`,
because the in-repo skill was frozen and had drifted from the disk copy
(chopshop-studio #15). Generation was restored and the drift published away, so
`./sync-skills --check` reports `in sync` and that test now passes.

Do NOT resurrect the stale baseline. "One failure is expected, do not chase it" is
the worst kind of note: it hides a real failure inside the expectation (the same
hazard `studio-backend-traps.md` records). If that test fails again, the in-repo
skill has drifted from `~/.hermes/skills/.../chopshop-studio` — run
`./sync-skills --diff`, read it, and publish; do not wave it through. Expect it
MID-SESSION in any multi-subagent run: a round's skill lesson write lands on the
disk copy between two otherwise green suite runs, so the ship pass carries the
publish as its OWN `skills:` commit (separate from the feature commit) and re-runs
the suite after publishing.

A wall of `SQLite3::BusyException: database is locked` is a concurrent run, not
breakage: re-run serially before believing it. And a test that compares against
`User.first` (e.g. the bug-report body) fails if a stray user row was left in the
TEST db by a `rails runner` probe — those run OUTSIDE the test transaction, so
they persist. Check `User.order(:id).first&.handle` before blaming the code.

## Live verification in a real browser
The check Rails cannot do (its suite executes no JavaScript). On this box there
is NO `~/.cache/ms-playwright`, so the driver's auto-discovery finds nothing —
set CHROME_BIN:

    CHROME_BIN=~/.hermes/tools/chromium-1208/chrome-linux64/chrome \
    node ~/.hermes/skills/software-development/chopshop-studio/scripts/verify-ui-clicks.js \
      --base https://127.0.0.1 --ignore-cert --path <path> --eval "$(cat eval.js)"

Collect `window.onerror` + `unhandledrejection` in the eval and assert the app's
OWN side effect (a DOM turn, a computed style, a field value), never "the handler
ran". Write the eval to a scratch file and pass it with `--eval "$(cat f.js)"`;
there is no ms-playwright on this box so an unset CHROME_BIN exits with "no
chromium found; set CHROME_BIN".
