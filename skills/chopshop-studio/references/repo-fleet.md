> HOST-SPECIFIC — the local clone paths (`~/chopshop-*`), the
> `geeeze/*` org, this box's git credential helper and the
> `GITHUB_TOKEN`-in-`~/.hermes/.env` setup are THIS machine. The
> rebase/collision and commit-author guidance is generic.

## Repo visibility & host-agnostic rule (read before any repo edit)

`chopshop-svg` is **PUBLIC** on GitHub; `chopshop-studio`, `chopshop-jev`, `chopshop-sui`, `chopshop-flux`, `chopshop-plot` are **private**. (More repos arrive as the fleet grows — re-list with `gh repo list geeeze` rather than trusting this count.) The CODE stays host-agnostic in all of them — it must not hardcode a machine: runner labels/URLs come from `CHOPSHOP_RUNNER_<LABEL>_URL` env vars (default mock-only), `config.hosts` extras from `CHOPSHOP_EXTRA_HOSTS`, `nginx-chopshop.conf` is a `@SERVER_NAME@` template (the live vhost lives in `/etc/nginx/`), and the runner `/health` reports `CHOPSHOP_RUNNER_LABEL` or `socket.gethostname()` — never a baked name.

**Docs/skills split by visibility: REDACT in public, TAG in private.** Never commit host-specific or private-stack detail to `chopshop-svg` (no hostnames, IPs, VPN names, no SwarmUI/ComfyUI references); its `sync-skills` redacts host detail out of its published skills. The private repos need NOT be purely host-agnostic — they may keep host-specific knowledge (paths, ports, timings, this box's deploy steps) — but every such fact MUST be tagged `HOST-SPECIFIC`, noted as subject to change and to be removed before reuse elsewhere. `chopshop-studio`'s `sync-skills` generates `skills/chopshop-studio/` from the on-disk Hermes skill with exactly that tagging. Both scripts are ONE-WAY (never import a repo copy back over a working skill) and treat a listed generated skill with no on-disk source as a hard error. Full mechanism + banner dicts: `references/repo-visibility-and-tagging.md`.

**`chopshop-studio/sync-skills --check` can report DRIFTED forever, and running the fix would UNDO a
deliberate cleanup.** The script only TAGS host-specific sections with a `HOST-SPECIFIC` banner — it
has no redaction pass — while the committed copy under `skills/` was scrubbed of host literals (banner
strings included) in a commit that replaced them with `<public-host>`-style placeholders. The two
halves now disagree by design, so the drift is a POLICY decision rather than staleness: either the
script grows a literal→placeholder redaction pass, or the placeholder treatment is reverted. Until
someone decides, `--check` exits non-zero and the disk-side content behind it (new reference files,
newer paragraphs) stays unpublished. **Never run a bare `./sync-skills` to "fix" a DRIFTED report
here without saying which side is authoritative** — it re-publishes the very literals the cleanup
removed. Report the drift with its cause instead of resolving it silently. When documenting, separate canonical repo facts from *this box's* deployment specifics; the paths/ports/labels below are this box, not the repo.

## Delegating work to subagents (brief file + reviewer)

When the user orders delegation ("delegate as much work as you can to subagents and a reviewer"), the
reason is that subagents share none of the session's rate limits — and the pattern that ships is one
`opencode run` implementer + one `opencode run` neutral reviewer, each against a written brief:

1. Write the brief as a FILE IN THE REPO the subagent will run in (`<TASK>_BRIEF.md`), NOT in the
   agent's scratch dir — the subagent's file access is scoped to its own working directory, so a
   brief in `~/.hermes/cache/scratch/` is invisible to it and the run dies having read nothing. The
   spawn prompt is one line: "Read <TASK>_BRIEF.md in this directory and do exactly what it says."
2. The brief carries: the user's asks verbatim, everything already MEASURED (so the subagent does
   not re-derive or re-guess), the hard rules (never commit; never touch files outside the named
   set; technique constraints from the verification skills), the test + deploy steps, and a Do NOT
   list.
2b. **State the baseline test numbers AND tell the subagent to re-measure them.** A hand-written
   baseline is wrong surprisingly often, and a wrong one is worse than none — the subagent reports
   "unchanged" against a figure that never existed. Give the number, label it a snapshot, and require
   the child to verify it before editing. Expect skips: a green run here reads "N passed, M skipped",
   never "N+M passed", because several tests guard optional third-party deps and `which inkscape` is
   empty on the host by design. A subagent reporting "590 passed" for a 590-collected suite has
   misread its own output. Name the repo's test ENTRY POINT explicitly (`.venv/bin/python -m pytest`;
   for Rails, source the env file first or `assets`/`db` tasks abort on a missing secret). A repo with
   no venv yet means the child's first job is to create one — say so in the brief, since `.venv/` is
   gitignored and a missing interpreter otherwise looks like a broken repo.
2c. **Expect the children's suite runs to collide with yours.** A `delegate_task` child runs the full
   suite in the repo it was given, and several children running Rails/pytest compete for the same
   database, ports, containers and caches as any run you start. Dispatching a batch and THEN starting
   your own "baseline" run means every one of them is slower and noisier for it. Dispatch first, take
   the baseline from a child's report or run your own only once they are done, and kill a redundant
   background run rather than waiting it out.
   **The signature to recognise is a WALL of `SQLite3::BusyException: database is locked`,** reported
   through `test/test_helper.rb` and spread across a dozen unrelated tests — it reads exactly like
   mass breakage and is purely contention. It applies to ANY two concurrent runs, including your own:
   starting a `bin/rails test` while a background suite is still going, or running a one-off
   `bin/rails test test/<file>` probe during a full-suite run, produces the same false red. Before
   believing that class of failure, look for the other run and re-test serially; a suite that was
   green seconds earlier either side of the "failure" was never failing.
2d. **Steer a running subagent with newly measured facts — do not let it rediscover a trap.**
   `delegate_task action='steer'` queues text onto the child's next tool result. When you measure
   something mid-flight that changes its implementation (a call-order requirement, a real timing, a
   class's actual defaults), steer it straight away with the measured numbers and the exact behaviour
   to adopt: the child is running against brief text you can supersede. Say explicitly whether it
   should WAIT for a follow-up or proceed now — an unqualified "I will confirm" leaves it blocking.
   One consolidated message carrying the decided answer beats a stream of hedged corrections that
   ends with the child still guessing.
3. Run the implementer with `background=true` writing to a log file in the repo, then wait on the
   session with process_manage; a bounded run routinely outlasts a single wait window — wait again
   or poll rather than assuming it died. Read the log's TAIL to check completion: a killed run ends
   mid-sentence.
4. The reviewer gets its OWN brief: NEUTRAL — read the uncommitted diff against the implementer's
   brief, PASS/FAIL per claim, run the suite itself and report exact counts, findings with
   file:line, and a ship / fix-first verdict. It changes and commits NOTHING.
5. Apply only the reviewer's findings you agree with — a wrong comment (a claim the code's own data
   does not support) is worth fixing before the commit; a design judgement belongs to the user.
   Re-run the FULL suite yourself before committing: the implementer's baseline counts can be stale.
6. Delete the brief and log files after the commit — they are untracked scratch in the user's repo.
   Delete them only once NO live child still reads them: a neutral reviewer started after the
   implementer finishes still opens the implementer's brief to check the diff against the requirement,
   so removing the briefs the moment the implementer commits can pull the ground out from under a
   running reviewer. Confirm every child that needs them has finished before cleaning up (the
   delegation's live transcript shows which files a child has read).

**opencode subagents cannot touch gems or run Rails.** Its sandbox auto-rejects any path outside the
working dir — including `/var/lib/gems` — so a subagent cannot `bin/rails test`, `assets:precompile`, or
`require` a gem. An implementer task that needs those will silently exit 0 having committed NOTHING (a
rejected tool call ends the run, and the "completed" self-report is false). Use subagents for READ-ONLY
review (git show + file reads under $HOME) and for pure-text edits that need no Rails; do the Rails
build/test/precompile work in the main agent. Always verify the worktree diff yourself after any
subagent reports done — an exit-0 with an empty diff is the signature.

**Hermes `delegate_task` subagents are NOT sandbox-gated the same way** — they run the full
`bin/rails test` suite in-repo, so prefer them when the subagent must edit code and run its own
tests (opencode can only do read-only review or pure-text edits). Parallel `delegate_task` subagents
that share ONE repo working tree collide — they `git checkout`/branch the same directory. Two ways to
parallelize on a single repo:
  (a) give each a separate repo (flux vs studio), or
  (b) — the general case — give each its own **git worktree** off the same repo. From the main
      checkout: `git worktree add ~/chopshop-studio-<task> -b feature/<task>` per subagent.
      Worktrees share one `.git` (branches/objects) but have independent working directories, so N
      subagents edit N branches in parallel while the main checkout stays on `main` for merge/deploy.
      This session ran three parallel implementers (index-preview fallback, show-page source stack,
      scrapbook dedupe) this way. Point each subagent's brief at ITS worktree path and make "do not
touch the main checkout or any other worktree" an explicit constraint in the brief.
After they finish: merge each branch onto `main` SEQUENTIALLY (fast-forward if clean), run the suite
at each merge step, deploy once at the end, then `git worktree remove <path>` to clean up. For
implementer-then-reviewer on the SAME branch, still run them sequentially — merge the implementer's
branch onto `main` before the reviewer starts.

## Repo sweep (all repos, every time)

"Chopshop" spans the `geeeze/*` repos: `chopshop-svg` (PUBLIC), `chopshop-studio`, `chopshop-jev`, `chopshop-sui`, `chopshop-flux`, `chopshop-plot` (private). Local clones:
`~/chopshop-studio`, `~/chopshop-svg`, `~/chopshop-jev`, `~/chopshop-sui`, `~/chopshop-flux`, `~/chopshop-plot`. For each:
`git -C <dir> fetch --all --prune && git -C <dir> rev-list --left-right --count HEAD...@{u}`
(0/0 = in sync) and `git -C <dir> status -sb`. Report ahead/behind and any uncommitted work per repo.
`~/chopshop-mock-runner` is NOT a git repo — it is the local-only mock runner service dir (runs on
`:8790`, `chopshop-mock-runner.service`). It has no remote and is never pushed; a repo sweep skips it.
`chopshop-jev`, `chopshop-sui`, `chopshop-flux` and `chopshop-plot` have no runtime services on this
box — they are cloned here so the sweep covers them; don't assume a deploy/verification step for them.

Repos differ in whether they carry a root `CONTEXT.md`. svg/studio/jev/sui carry one tracking **work in progress, blockers, and caveats** — keep it current as work lands; record a caveat there rather than letting suite-count/port/flag prose drift. **`chopshop-flux` also carries one** (the "flux and plot are newer, so they use `AGENTS.md` only" claim went stale — verify with `ls` per repo rather than trusting this list, and do not invent one where a repo genuinely has none and the user has not asked). Moving a doc file breaks whatever reads it by path — grep the TEST tree and app code for the literal path (`Rails.root.join("doc", ...)`), not just prose, and run the suite after. Full detail: `references/repo-visibility-and-tagging.md`.

**`AGENTS.md` is a PROTECTED file: an agent write to it is refused, and the refusal says not to route
around it.** When a required edit targets `AGENTS.md` (a stale suite count, a new hard rule to add),
the write guard blocks it — do NOT retry the same edit through terminal/execute_code, and do not let
the task look complete. Record the fact in the repo's `CONTEXT.md` instead, naming the exact line and
what it should say, and tell the user it needs a human edit or an approved one. A subagent hits the
same wall and reports it under "could not do" — treat that as an accurate limitation rather than a
child failure, and check for it, because a brief that asks for an `AGENTS.md` change will otherwise
look silently half-done.

### Investigating who authored a commit (delegated agents hide behind the author field)

An agent-delegated commit lands under the USER's own git identity with a `Co-Authored-By:` trailer in
the message body. So `%an`/`%ae` NEVER reveal that an agent wrote a commit, and GitHub's contributors
graph surfaces the trailer as a contributor — which is what makes a tool show up as a "contributor" on
a repo the user thought only they touched. Check bodies, not authors:
`git log --format='%b' | grep -i 'co-authored-by'`. Do not conclude "no agent touched this" from the
author field, and equally do not conclude that a separate credential pushed: the credential is the
user's own. Whether a PR gate existed is a server-side question — a direct push landing on `main`
proves no gate STOPPED it (or the owner bypassed it); reading protection needs admin scope and the
current PAT answers `403 Resource not accessible`, so say that rather than asserting no gate exists.
If a push is rejected non-fast-forward, the remote moved while you were working (someone else pushed).
`git fetch && git log --oneline HEAD..origin/main` to see what arrived, then `git pull --rebase origin main`
and push again — never `--force` over other people's commits. **Before rebasing, diff what arrived against
what you are about to push**: a concurrent worker may have already fixed the SAME drift (e.g. the same
contract-test pin), and pushing your duplicate leaves a redundant commit. Drop the duplicate
(`git checkout -B main origin/main` then `git cherry-pick` ONLY your unique commit) rather than rebasing
it on top.
A 0/0 reading is a SNAPSHOT, not a property: agents push to these repos while you work, so a sweep
that was clean earlier can be a commit behind by the time you report, and an expected push can be
rejected. Re-check before reporting status, and expect the collision. When a rebase lands conflicts
in files both sides rewrote, resolve by keeping THEIR measured facts and YOUR structure: the
incoming test counts and line references are usually the more current number — re-verify them by
running the suite rather than re-asserting your older figure — while the vocabulary and layout are
what you were changing. Never take one side wholesale, and never `--force`.
**A conflict in a DOCS file is usually not a choice — check whether either side DELETED anything
before picking.** When both sides add a different section at the same anchor (a reference file,
`CONTEXT.md`), the conflict is ADDITIVE: compare each side against the merge base (`git show
<base>:<file> | grep -c '<their heading>'`). If your version lacks their heading and theirs lacks
yours, both sections are new and BOTH belong — taking one side wholesale silently deletes a paragraph
nobody meant to remove. Keep both in the file's own section order, then re-read the merged region to
confirm it still reads as prose (a naive concatenation leaves a dangling clause). When both sides
rewrote the SAME paragraph instead, take the better POLICY and fold in the missing facts, rather than
alternating sentences from each.
**`git checkout <commit> -- <file>` RESTORES *AND STAGES* — and a later `git reset --hard` in a
rebase re-applies that file over a concurrent agent's edits.** Restoring your own copy of a file to
get a clean merge is safe only for files the OTHER side did not also change: if the agent has since
edited it, the restore silently reverts their work (a `reset --hard` re-materialises the staged old
copy — the mechanism is the index, not the checkout). Before restoring anything, list what the
incoming work touched (`git diff --name-only <base>..origin/main`) and restore ONLY files absent from
that list; for the shared ones, re-derive your change from the agent's new version. After any
restore, re-run the suite — a reverted fix surfaces as a failing test, not as an obvious diff.

**Drift is not always intentional.** When a count, flag, path, repo list, or README line has moved
since last time, treat it as a signal to VERIFY which way it went — an agent push is one cause, but
a stale suite count, a silently moved doc, or a repo that appeared/vanished is drift to catch and
re-check, not to assume or silently mirror. Check first; adjust the skill after.
Auditing the workspace for duplicated or divergent agent files, skills and docs — the scan
procedure, the scoring thresholds, and the interpretation rules that separate real duplication from
a templated artifact: `references/repo-hygiene-audit.md`.
When uncommitted work sits in files upstream also changed, `git pull` refuses (`Your local changes to
 the following files would be overwritten by merge`) and aborts. Do NOT stash reflexively: `git diff
 HEAD...origin/main -- <file>` first. If the incoming hunks are in different REGIONS than your edits,
commit your work and `git pull --rebase` — a clean rebase. When the dirty files are tracked PIPELINE
OUTPUTS that must never be committed (e.g. `04_validated/*.layer_a.txt`), committing them is not an
option: check the incoming commits do not touch them (`git diff HEAD..origin/main --name-only`),
then stash the NAMED files, rebase, and pop — `git stash push -m 'pipeline output' <files>`
(naming them, never a bare `git stash`, which sweeps in anything else dirty) →
`git pull --rebase origin main` → `git stash pop`, and confirm the files are dirty again after.
A dirty tracked file blocks rebase outright (it needs a clean worktree), and the pop restores the
output untouched. A pull that brings CSS/JS changes also
invalidates the deployed digest, so re-run `assets:precompile` and restart Puma, then assert the served
page references the NEW `application-<hash>.css` (a stale digest serves old CSS while the source looks
correct).
`git push` fails `could not read Username for 'https://github.com'` when the credential-helper chain resolves to nothing. The global helper that works is `git-credential-hermesenv`, which serves `GITHUB_TOKEN` from `~/.hermes/.env`. `gh auth setup-git` appends `[credential "https://github.com"]` scoped entries that SHADOW the global line, and the `gh-real auth git-credential` shim they point at reads `GH_TOKEN` — unset, since the PAT is `GITHUB_TOKEN` — so it returns empty and git has no username. Diagnose with `git config --get-all credential.helper` (look for the scoped `https://github.com` pair overriding the global one), then delete those scoped entries so only the single global helper remains. For a one-off push, bypass instead of repairing:
`git -c credential.helper= -c 'credential.https://github.com.helper=!~/.local/bin/git-credential-hermesenv' push`. Never re-run `gh auth setup-git` to "fix" auth — that is what breaks it. The token stays only in that one file.

### Scope boundary — "our repos" does not include the Hermes checkout

`~/.hermes/hermes-agent` is a clone of upstream `NousResearch/hermes-agent`, checked out to RUN
Hermes, not the user's code. When the user asks to check "our repos" / "code that still needs
commit", the answer covers the user's own project repos only (`geeeze/*` — the chopshop repos
[six and growing] plus `console`). If the Hermes checkout shows uncommitted files, report it in one line
and stop — never investigate its internals, config, logs, or runtime. Deep tangents into that repo
are the single fastest way to burn the user's patience when they asked about Chopshop.
