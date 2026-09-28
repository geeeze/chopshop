> HOST-SPECIFIC — the local clone paths (`~/chopshop-*`), the
> `geeeze/*` org, this box's git credential helper and the
> `GITHUB_TOKEN`-in-`~/.hermes/.env` setup are THIS machine. The
> rebase/collision and commit-author guidance is generic.

## Repo visibility & host-agnostic rule (read before any repo edit)

`chopshop-svg` is **PUBLIC** on GitHub; `chopshop-studio`, `chopshop-jev`, `chopshop-sui`, `chopshop-flux`, `chopshop-plot` are **private**. (More repos arrive as the fleet grows — re-list with `gh repo list geeeze` rather than trusting this count.) The CODE stays host-agnostic in all of them — it must not hardcode a machine: runner labels/URLs come from `CHOPSHOP_RUNNER_<LABEL>_URL` env vars (default mock-only), `config.hosts` extras from `CHOPSHOP_EXTRA_HOSTS`, `nginx-chopshop.conf` is a `@SERVER_NAME@` template (the live vhost lives in `/etc/nginx/`), and the runner `/health` reports `CHOPSHOP_RUNNER_LABEL` or `socket.gethostname()` — never a baked name.

**Docs/skills split by visibility: REDACT in public, TAG in private.** Never commit host-specific or private-stack detail to `chopshop-svg` (no hostnames, IPs, VPN names, no SwarmUI/ComfyUI references); its `sync-skills` redacts host detail out of its published skills. The private repos need NOT be purely host-agnostic — they may keep host-specific knowledge (paths, ports, timings, this box's deploy steps) — but every such fact MUST be tagged `HOST-SPECIFIC`, noted as subject to change and to be removed before reuse elsewhere. `chopshop-studio`'s `sync-skills` generates `skills/chopshop-studio/` from the on-disk Hermes skill with exactly that tagging. Both scripts are ONE-WAY (never import a repo copy back over a working skill) and treat a listed generated skill with no on-disk source as a hard error. Full mechanism + banner dicts: `references/repo-visibility-and-tagging.md`. When documenting, separate canonical repo facts from *this box's* deployment specifics; the paths/ports/labels below are this box, not the repo.

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

**opencode subagents cannot touch gems or run Rails.** Its sandbox auto-rejects any path outside the
working dir — including `/var/lib/gems` — so a subagent cannot `bin/rails test`, `assets:precompile`, or
`require` a gem. An implementer task that needs those will silently exit 0 having committed NOTHING (a
rejected tool call ends the run, and the "completed" self-report is false). Use subagents for READ-ONLY
review (git show + file reads under $HOME) and for pure-text edits that need no Rails; do the Rails
build/test/precompile work in the main agent. Always verify the worktree diff yourself after any
subagent reports done — an exit-0 with an empty diff is the signature.

## Repo sweep (all repos, every time)

"Chopshop" spans the `geeeze/*` repos: `chopshop-svg` (PUBLIC), `chopshop-studio`, `chopshop-jev`, `chopshop-sui`, `chopshop-flux`, `chopshop-plot` (private). Local clones:
`~/chopshop-studio`, `~/chopshop-svg`, `~/chopshop-jev`, `~/chopshop-sui`, `~/chopshop-flux`, `~/chopshop-plot`. For each:
`git -C <dir> fetch --all --prune && git -C <dir> rev-list --left-right --count HEAD...@{u}`
(0/0 = in sync) and `git -C <dir> status -sb`. Report ahead/behind and any uncommitted work per repo.
`~/chopshop-mock-runner` is NOT a git repo — it is the local-only mock runner service dir (runs on
`:8790`, `chopshop-mock-runner.service`). It has no remote and is never pushed; a repo sweep skips it.
`chopshop-jev`, `chopshop-sui`, `chopshop-flux` and `chopshop-plot` have no runtime services on this
box — they are cloned here so the sweep covers them; don't assume a deploy/verification step for them.

Repos differ in whether they carry a root `CONTEXT.md`. svg/studio/jev/sui carry one tracking **work in progress, blockers, and caveats** — keep it current as work lands; record a caveat there rather than letting suite-count/port/flag prose drift. flux and plot use `AGENTS.md` only (they are newer and smaller) — do not invent a CONTEXT.md for them unless the user asks. Moving a doc file breaks whatever reads it by path — grep the TEST tree and app code for the literal path (`Rails.root.join("doc", ...)`), not just prose, and run the suite after. Full detail: `references/repo-visibility-and-tagging.md`.

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
