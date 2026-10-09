> HOST-SPECIFIC — the local clone paths (`~/chopshop-*`), the
> `geeeze/*` org, this box's git credential helper and the
> `GITHUB_TOKEN`-in-`~/.hermes/.env` setup are THIS machine. The
> rebase/collision and commit-author guidance is generic.

## Repo visibility & host-agnostic rule (read before any repo edit)

`chopshop-svg` is **PUBLIC** on GitHub; `chopshop-studio`, `chopshop-jev`, `chopshop-sui`, `chopshop-flux`, `chopshop-bp` and `dmpool` are **private** (confirmed with `gh repo view <owner>/<repo> --json visibility`). (More repos arrive as the fleet grows — re-list with `gh repo list geeeze` rather than trusting this count.) The CODE stays host-agnostic in all of them — it must not hardcode a machine: runner labels/URLs come from `CHOPSHOP_RUNNER_<LABEL>_URL` env vars (default mock-only), `config.hosts` extras from `CHOPSHOP_EXTRA_HOSTS`, `nginx-chopshop.conf` is a `@SERVER_NAME@` template (the live vhost lives in `/etc/nginx/`), and the runner `/health` reports `CHOPSHOP_RUNNER_LABEL` or `socket.gethostname()` — never a baked name.

**Docs/skills split by visibility: REDACT in public, TAG in private.** Never commit host-specific or private-stack detail to `chopshop-svg` (no hostnames, IPs, VPN names, no SwarmUI/ComfyUI references); its `sync-skills` redacts host detail out of its published skills. The private repos need NOT be purely host-agnostic — they may keep host-specific knowledge (paths, ports, timings, this box's deploy steps) — but every such fact MUST be tagged `HOST-SPECIFIC`, noted as subject to change and to be removed before reuse elsewhere. `chopshop-studio`'s `sync-skills` generates `skills/chopshop-studio/` from the on-disk Hermes skill with exactly that tagging. Both scripts are ONE-WAY (never import a repo copy back over a working skill) and treat a listed generated skill with no on-disk source as a hard error. Full mechanism + banner dicts: `references/repo-visibility-and-tagging.md`.

**`chopshop-studio/sync-skills --check` is GREEN when the published copy is current — but run
`--diff` BEFORE publishing, because a publish overwrites repo-side hand edits.** The script has TWO
generation passes: it TAGS host-specific sections (`HOST-SPECIFIC` banners) and then REDACTS a
literal→placeholder map over the result, so the committed copy under `skills/` carries placeholders
(`<public-host>`, `<operator-handle>`, `<gpu-box>`) rather than the literals. A `LEAK_GUARDS` scan
runs before anything is written and REFUSES the whole publish (non-zero exit) if a host-shaped fact
survives, which is what makes a green `--check` mean "current AND clean" rather than merely "the two
copies match".

What still bites is the opposite direction: the committed copy is sometimes HAND-EDITED in place, and
generating from a stale on-disk source silently reverts that work. A reference file had its subsystem
progress updated in-repo across three commits that each touched that ONE file, while the disk copy
still said the phases were unstarted. So: `--diff` → read it → fold anything the repo copy knows and
the disk copy does not back INTO the on-disk skill → publish → re-run `--check`. A commit touching a
single file under `skills/` is the signature of a hand edit (a publish rewrites many files at once),
and most of a long diff is usually REWORDING, not lost facts — grep the disk copy for a rule's own
words before calling it deleted. After editing the on-disk skill, republish and commit: an
uncommitted publish leaves `--check` green against a copy nobody else can see. Full mechanism (the
ordered-map requirement, the guard's stated limits, the independent-grep verification):
`references/repo-visibility-and-tagging.md`.

When documenting, separate canonical repo facts from *this box's* deployment specifics; the
paths/ports/labels below are this box, not the repo.

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

**Cap the wave at ~3 subagents and group by repo.** The user objects to large fan-outs ("dont spawn
10 lol") — a wide batch also floods the box (every child runs a full suite) and makes the completed
unit's report unreadable. Give each child a tight, complete context block: its repo path, the
existing `agent/<repo>-fix` branch, the rules (English only, host-agnostic, commit only its own
files, no push, no GitHub edits — report instead), the test entry point, and the instruction to
report per-issue status + commit hash + evidence.

**An interrupted owner turn kills running children mid-task — their results are 'unknown', not
'failed'.** After any interruption, do NOT re-dispatch from scratch: survey the actual state on disk
first (`git branch --format=... | grep agent`, `git worktree list`, `git status --porcelain` per
repo, `git log main..<branch>`) and re-dispatch CONTINUATION agents whose context names what is
already committed and what is mid-flight (uncommitted edits, a half-written test file, a worktree
path). Children hitting their iteration cap hand you their background processes as terminated —
re-launch anything you still need.

**A host `python3` upgrade silently breaks EVERY repo `.venv` at once.** The venv's
`bin/python3` symlinks to `/usr/bin/python3`; when the host moves that to a new minor (old one
removed), the venv reports the NEW version while its site-packages sit in `lib/python<old>/` —
imports fail and the failure looks like a broken repo, not a broken venv. Diagnose with `cat
.venv/pyvenv.cfg` (names the old interpreter) + `readlink -f .venv/bin/python3`. Fix per repo:
`sudo apt-get install -y python3.<new>-venv` first (a bare `python3 -m venv` fails on
`ensurepip`), then `rm -rf .venv && python3 -m venv .venv && .venv/bin/pip install -r
requirements.txt`, then verify imports AND a `--collect-only` before believing it. Check every
`~/*/.venv` in the fleet, not just the repo you are in.

## Repo sweep (all repos, every time)

"Chopshop" spans the `geeeze/*` repos: `chopshop-svg` (PUBLIC), `chopshop-studio`, `chopshop-jev`, `chopshop-sui`, `chopshop-flux`, `chopshop-bp` (private, RENAMED from `chopshop-plot` — GitHub redirects the old URL, so a stale remote still works and silently rots), `console`, and `dmpool` (private). Local clones (confirm by listing `~/*/`, never by trusting this line):
`~/chopshop-studio`, `~/chopshop-svg`, `~/chopshop-jev`, `~/chopshop-sui`, `~/chopshop-flux`, `~/chopshop-bp`, `~/console`, `~/dmpool`. For each:
`git -C <dir> fetch --all --prune && git -C <dir> rev-list --left-right --count HEAD...@{u}`
(0/0 = in sync) and `git -C <dir> status -sb`. Report ahead/behind and any uncommitted work per repo.

**An ahead/behind reading on a NON-DEFAULT branch is only as good as the fetch
refspec — check it before believing a phantom "ahead".** A single-branch clone
(`git config remote.origin.fetch` → `+refs/heads/main:refs/remotes/origin/main`)
never updates `origin/<other-branch>`, so a successful push still reads as "1
ahead" forever: `git push` exits 0 while the local tracking ref lies. When a
reading contradicts a push that reported success, get ground truth from
`git ls-remote --heads origin <branch>`; if the refspec is single-branch,
widen it once (`git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'`
+ `git fetch`) so every later sweep of that clone is trustworthy. The same
clone should have its branches fetched after any push made from elsewhere.
`~/chopshop-mock-runner` is NOT a git repo — it is the local-only mock runner service dir (runs on
`:8790`, `chopshop-mock-runner.service`). It has no remote and is never pushed; a repo sweep skips it.
`chopshop-jev`, `chopshop-sui`, `chopshop-flux` and `chopshop-bp` have no runtime services on this
box — they are cloned here so the sweep covers them; don't assume a deploy/verification step for them.
(`chopshop-bp` is the renamed `chopshop-plot`, whose module also serves this box's `127.0.0.1:8796`
plot endpoint for the studio; the repo has no service OF ITS OWN to sweep.) `dmpool` is cloned here
for vetting only — no service, no deploy step.

**The fleet has NO global git identity; every repo sets it locally — and the CORRECT identity is `geeeze <156519592+geeeze@users.noreply.github.com>`.** Check any repo's own config (`git -C <dir> config user.name` / `user.email`) and an existing commit's author before you rely on your memory of it: the login is **`geeeze`** (three e's — `gh api user -q .login` says so), the GitHub noreply address carries the numeric id, and `geeze` / `geeze@users.noreply.github.com` (two e's, bare) is WRONG and will not attribute the commit to the account. **Never pass `-c user.name=... -c user.email=...` on a commit: it OVERRIDES the repo's correct config**, which is how six commits on `chopshop-flux` landed as `geeze` in one session. Commit bare and let the repo config apply. If a wrong-identity commit is still local and unpushed, rewrite it (`FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --env-filter '…' <base>..HEAD`), verify with `git log --format='%an <%ae> | %cn <%ce>'`, and re-run the suite; if it is already PUSHED, say so and offer the rewrite rather than force-pushing a branch other agents push to.

**When the ask is "sync the repos", VET THE DIRTY LIST BEFORE `git add -A`.** A concurrent agent
(Claude Code, another Hermes session) edits the same working tree, so `git status --porcelain` can
hold untracked files and partial edits that are not yours — and a blanket `git add -A` commits their
half-finished work under your message. Enumerate the list, account for every path, and stage in
logical GROUPS BY PATH (`git add <files…>` per change), so each commit's diff is only what its
message claims. Finish by proving the push landed: `git fetch` then compare
`git rev-parse HEAD` against `origin/main` and report the two SHAs; "pushed" with a tree that still
has uncommitted work is a half-sync. A repo whose working tree is clean and level (`0/0`) needs no
commit at all — say so rather than manufacturing one.

Repos differ in whether they carry a root `CONTEXT.md`. svg/studio/jev/sui carry one tracking **work in progress, blockers, and caveats** — keep it current as work lands; record a caveat there rather than letting suite-count/port/flag prose drift. **`chopshop-flux` also carries one** (the "flux and plot are newer, so they use `AGENTS.md` only" claim went stale — verify with `ls` per repo rather than trusting this list, and do not invent one where a repo genuinely has none and the user has not asked). Moving a doc file breaks whatever reads it by path — grep the TEST tree and app code for the literal path (`Rails.root.join("doc", ...)`), not just prose, and run the suite after. Full detail: `references/repo-visibility-and-tagging.md`.

**`AGENTS.md` is a PROTECTED file: a write to it is APPROVAL-GATED.** The guard raises a prompt owned
by the UI — a chat message saying "approve it" does not answer it, and an unanswered prompt expires
with "Silence is not consent", which reads exactly like a refusal but is not one. Trigger the write,
then ask for the one action that works: accept the prompt when it appears. Two mechanics worth
knowing: a blocked attempt CLEARS this task's read-state of that file, so an immediate retry comes
back `stale_write_blocked` — `read_file` the target again and re-issue the SAME write — and a SUBAGENT
cannot answer a UI prompt at all, so a brief that asks for an `AGENTS.md` change reports it under
"could not do"; treat that as an accurate limitation and check for it rather than reading it as a child
failure. Fall back to the repo's `CONTEXT.md` (naming the exact line and what it should say) plus the
replacement text in a fenced block ONLY when no prompt can be answered. Never route around the guard
via terminal/execute_code.

### Vetting a NEWLY CLONED repo for further development

The ask arrives as one line — "`<owner>/<repo>` another repo to clone and consider for further
development" — and the deliverable is a verdict backed by OUTPUT, not a tour of the code: what runs
today, what is broken, and where the next work pays. Change nothing and push nothing.

1. **Metadata before the clone** — `gh repo view <owner>/<repo> --json name,description,visibility,defaultBranchRef,createdAt,pushedAt,diskUsage,primaryLanguage,licenseInfo,isFork,url`. Size, language, licence and last-push date say what kind of repo it is before you spend a clone on it, and `visibility` decides whether the tagging rule above applies.
2. **Clone and inventory** — `gh repo clone <owner>/<repo>` into `~/<repo>` (the fleet convention), then `git log --oneline -20`, `git ls-files | wc -l`, `wc -l` over its sources, and `ls -a` for `.github/`. A history where every commit lands on one day is a published prototype, not a matured repo — say so. A fast suite with no CI workflow is a cheap, concrete finding.
3. **Read the repo's own contract first** — `AGENTS.md`, `CONTEXT.md`, `README.md`, `docs/`. It names the hard rules you must not violate and the command its author treats as verification; run THAT command rather than inventing one.
4. **Run the declared verification verbatim and keep the exact result line** ("Ran 55 tests ... OK"). A repo that passes its own suite is the baseline every later claim leans on.
5. **Exercise the real CLI end to end, on a store OUTSIDE the checkout** (see the store-root pitfall below): run the documented happy path (fetch → route → build → render), then a command that should REFUSE, and confirm it refuses for the right reason.
6. **Probe the source claims** with the repo's own `doctor --probe`-style command, and separate "deliberately UNVERIFIED" from "broken" — an unverified registry entry is a designed state, and reporting it as a defect is noise.
7. **Read every produced artifact as data, not as a filename** — parse it with the stdlib (`xml.etree`, `json`, `csv`) and assert it against the input it came from. "The file exists and parses" is not a check; a look at what is IN it found a gridline tick label at `y=-9.45` on a 520-high canvas.
8. **Report, then leave the tree clean** — `git status --porcelain` empty, nothing committed, nothing pushed.

### Scope gates when working the tracker fleet (read before taking a labelled issue)

**A `ready-for-agent` label is authorization to do THAT issue, not to start a project.** Before
working any issue, check what repo it lives in against what the engagement actually is. The fleet
has a reference-only member: **`console` — do not work it except as a reference, and never without
the user naming it in the session.** Its issues being labelled `ready-for-agent` is NOT permission:
the repo is a different product (a Go backend + TS frontend, not the Python/Rails chopshop stack),
lives on a system with its own agent, and taking its tracker over reads as a hostile takeover of
someone else's codebase. If the ask was "clear the ready-for-agent items", enumerate the repos,
name which ones you intend to work, and let the user strike the ones that are not yours — the
two-minute confirmation is cheaper than the wave of wasted work.

**Treat these signals as STOP-AND-ASK, not as obstacles to engineer around.** Any one of them means
the repo is not ready for your work regardless of labels: (a) an issue's dependency chain is
unmet (its `Blocked by` targets are unmerged or uncommitted in another agent's worktree); (b) an
acceptance criterion describes a contract that does not exist in the repo (a per-user settings
layer, an auth backend); (c) the worktree holds uncommitted work from a different agent; (d) the
fix requires a stack or toolchain the engagement never mentioned. The failure mode is real:
working around (a)-(d) produces weeks of salvage-review burden for the repo's owner, burns the
box's resources (a Go toolchain in Docker is not welcome on a 3.8 GB VPS), and reads as drift from
the actual job. Ask. "I'm proceeding" is never the answer to a scope question.

**Nothing you spin up stays resident.** Any container, daemon or toolchain a subagent starts for
one test run is torn down in the same session — `docker ps -a` before closing out, and kill what
you did not have at the start. A leftover `sleep infinity` container on a small box is exactly the
memory pressure the operator does not need, and finding it days later is how trust in the whole
session's work evaporates. When dropping unreviewed work into a repo you should not have touched,
push it as NEW branches (never merge, never overwrite), file a handoff note naming it unreviewed
agent work from a drifted session with salvage-or-delete instructions, and stop touching that repo.

**A tool whose default output root is `~/<tool-name>` writes INTO the clone.** With `$DMPOOL_STORE` unset the store root is `~/dmpool` — exactly where the clone lands — so a bare `init` dropped `objects/ index/ packs/ exports/ catalog.jsonl` into the working tree and `git status` grew an untracked `catalog.jsonl`. Read the default out of the code (`default_root()`, the config parser) or `--help` BEFORE the first state-changing command, redirect it to a scratch dir under the Hermes scratch root (`--store` / the tool's env var), and run `git status --porcelain` before and after — and delete that scratch store afterwards, because for `dmpool` the fleet rule is that the store lives on <gpu-box> and this host keeps no copy. WHY: a polluted worktree makes your changes indistinguishable from the tool's artifacts, and the fleet rule is that you commit only your own files.

**Check the README's invocations before quoting them.** `./dmpool pull …` is the README's headline and fails with `Is a directory` — the launcher is `dmpool.py`, and a repo cannot carry both a `dmpool` file and a `dmpool/` package. Run `ls -F` and `python3 -m <pkg> --help` first, and count the documented subcommands against the real ones (`grep add_parser`): a documented `export`/`search` that no subparser implements is one of the most useful defects you can hand back.

**No rasteriser on the box is not a reason to skip a visual check the repo mandates.** When the artifact is an image/SVG and the repo's own rule is "rasterise and LOOK", assert the same property in text: parse the SVG and compare every `<text>`'s `x`/`y` against the canvas `width`/`height`. That is how the off-canvas tick label above was found with no `rsvg-convert` installed.

**An issue query can be refused for token scope, and that is not an empty tracker — but RE-PROBE, because the grant lands late.** `gh issue list -R <owner>/<repo>` once answered `GraphQL: Resource not accessible by personal access token (repository.issues)`; minutes later the same call listed issues and `gh api repos/<o>/<r>/issues` answered 200, so that earlier reading was a LAGGING permission, not a wall (see the re-probe rule in `studio-backend-traps.md`). As of 2026-09-29 the credential files and reads issues on all the fleet's private repos as `geeeze`.

**`dmpool`'s tracker was EMPTY and had no triage labels.** GitHub's default label set only, zero issues — so the five canonical roles exist in `chopshop-studio`, `chopshop-flux`, `chopshop-bp` and `chopshop-svg` but must be created per repo that lacks them (`gh label create <name> -R <owner>/<repo> --description "…"`) before a filed issue can carry one; `wontfix` already exists by default. Eight issues were filed across `geeeze/dmpool` (6: README's `./dmpool` invocations, the store root colliding with the clone path, no in-canvas check on a rendered chart, the missing `export` subcommand, no CI, `pack --json` having no body), `geeeze/chopshop-studio` (1: `storage/uploads` growing unbounded) and `geeeze/chopshop-flux` (2: a second GPU tenant vs the model load, and a step landing in the idle-exit restart window).

**File from a staged file with `scripts/file-issues.py`, then reconcile by listing.** `--dry-run` first, `--results` to keep the numbers, and read back with `gh api "repos/<o>/<r>/issues?state=all&per_page=100" -q '.[] | "#\(.number) [\(.state)] [\(.labels|map(.name)|join(","))] \(.title)"'` — a create that exits 0 is not proof the body and labels landed, and the per-label counts must match what you staged.

**Before filing a bug you already fixed, do not file it open.** The chained-job state bug found by the smoke test was fixed in the same session (`sync_from_runner!` keeping a chain's verdict, plus a test that fails with the fix stashed); the commit and its pin are the record, and an issue opened only to be closed is noise on a tracker that is meant to be the list of what is still WRONG. **The same rule decides what to do with evidence an audit turns up: search the OPEN issues first, and when the measurement belongs to one of them, COMMENT it there rather than filing a sibling.** A failing automated run whose cause is already tracked is evidence, not a new bug — the comment's job is to add what only a live run can show (the job ids, the exact refusal text, which step failed, what the earlier passes looked like), so the tracked issue stops being theoretical. Filing the sibling instead splits the evidence across two rows and neither reads as the live state.

#### Report shape the user wants

Ordered, evidence first, no process narration: (1) one line — where it is cloned, size / commits / licence / stack, tree left clean; (2) a **verified working** table, one row per surface, the right-hand cell the EXACT tool output (the test result line, the route hit, the artifact's byte count); (3) **defects** numbered, each with a reproduction and the mechanism, never a story about how you found it; (4) **where further development pays**, ordered by value and naming the gap the code itself admits; (5) what was NOT verified, and what remains untouched and unpushed. Close by asking which to pursue — never start editing code off the back of a review.

#### `dmpool` — `geeeze/dmpool`, PRIVATE, Apache-2.0, stdlib-only Python (~5.1k lines, 55 tests)

A curated domain-data pool FOR Hermes, not an agent: `pull` (fetch with provenance — SHA-256 content-addressed objects plus an append-only `catalog.jsonl`), `route` (scored keyword expert gate; prints `active N` and the datasets the gate wants but the store lacks), `pack` (a cited context slice plus a machine-readable `.manifest.json` that lists `included` AND `omitted`), `chart` (plan offline, `--render` through the blend-plot service at `CHOPSHOP_PLOT_URL`, default `http://127.0.0.1:8796` = this box's `chopshop-bp`). Variants change what is selected and how it scores, never the store; the ranker only ORDERS and never hides a record. Run as `python3 -m dmpool --store <dir> <cmd>` (launcher `dmpool.py`), tests via `python3 -m unittest discover -s tests`.

All four surfaces verified on this box (4 datasets fetched, `pack --json` manifest, a live render off the blend-plot service); `doctor --probe` reads 8/12 with the four failures being designed UNVERIFIED entries (`hf`, `github-api`, `aflow-api`, `materials-api`). Known defects at that reading: the README's `./dmpool` invocations, the default store root colliding with the clone path, and `chart --render --size 1000x520` emitting a top gridline tick label above the viewBox. Development gaps the README itself admits: no `export` subcommand (the fine-tuning half is unbuilt), no `search` driver (the authority/denylist/`fetch_web` pieces exist, nothing drives them), no CI, and nothing wires `route → pack` into a Hermes session yet. HOST-SPECIFIC: clone `~/dmpool` for the code; the STORE is on <gpu-box> (below).

**The store lives on <gpu-box> and this host keeps NO copy of it (operator rule, 2026-09-29: "we don't want to duplicate datasets — locate data off this host, the <gpu-box> used like the flux service").** `~/dmpool` on `<tailnet-ip>` is the store — content-addressed `objects/`, `catalog.jsonl`, `packs/`, `variants/`, `events.jsonl`, `ranker.json`: 34 catalogue rows / 27 dataset views / 19 distinct content hashes / 8 MB of objects / 22 packs / 140 learning events and a FITTED ranker, i.e. strictly more than this host ever fetched. <gpu-box>'s CODE checkout is a separate directory, `~/Documents/GitHub/dmpool` (same commit as the clone here). The split is forced by the tool's own default root (`$DMPOOL_STORE` or `~/<repo-name>`): on <gpu-box> that is a bare store dir, on this host it is the git clone — which is why the same command polluted the worktree here and not there.

Reach it over SSH — **port 22822** (Tailnet; plain port 22 is refused): `ssh -p 22822 <gpu-handle>@<tailnet-ip>`. One round trip, no daemon, no mirror, nothing installed:

```bash
ssh -p 22822 <gpu-handle>@<tailnet-ip> 'python3 ~/Documents/GitHub/dmpool/dmpool.py route "<question>" --json'
ssh -p 22822 <gpu-handle>@<tailnet-ip> 'python3 ~/Documents/GitHub/dmpool/dmpool.py pack  "<question>" --print --log-shown'
```

`route` FIRST — `active == []` IS the answer, and never build a pack to have something. Use **`pack --print`, not `pack --json`**: the JSON manifest carries `included[]`/`omitted[]` metadata (keys `budget bytes data_meta generated included omitted pool query ranking recipe_hash routing variant variant_path`) but NO body, so the cited text costs either `--print` (5771 bytes on the wire for a 24000-byte budget) or a second read of `<store>/packs/<name>.md` — and every `pack` writes another file into <gpu-box>'s `packs/`.

Carry these facts into any integration: **an empty gate exits 0 with `datasets: []`**, not 2, so branch on `routing.active`, never on the exit code. **`chart --render` runs ON <gpu-box>, not here** — <gpu-box> carries the whole stack, not only the store (podman 5.4.2: `localhost/chopshop-svg:0.1.0` 938 MB, `chopshop-studio-dev:1`, `chopshop-rails-verify:3.2`; the `chopshop-app` studio container up on `127.0.0.1:3001`; every `geeeze` checkout under `~/Documents/GitHub/` including `chopshop-plot` = the BP/blend-plot service; the pipeline at `~/davesnothere`). Start the plot service from that checkout and render locally: `cd ~/Documents/GitHub/chopshop-plot && python3 cli.py serve --bind 127.0.0.1 --port 8796`, then `CHOPSHOP_PLOT_URL=http://127.0.0.1:8796 python3 dmpool.py chart --dataset <d> --render`. Verified: 2085 B SVG, byte-identical (same `-e89c62bf` short hash) to the render this box's `chopshop-bp` produced, so a chart is reproducible across hosts. Nothing on <gpu-box> listens on 8796 until that checkout is started, and a stopped service is killed BY PORT (`ss -ltnp | grep ':8796' | grep -oP 'pid=\K[0-9]+'`), never `pkill -f`, which matches the invoking shell. GitHub-sourced pulls inherit <gpu-box>'s `GITHUB_TOKEN` over SSH; a local store would need its own.

`rsync`ing the store to `~/dmpool-store` (the <gpu-box> handoff's option B) is exactly the duplication the operator ruled out — do not do it as a convenience, and delete any copy you made while probing. The <gpu-box> handoff also calls the repo "public": `gh repo view geeeze/dmpool --json visibility` says **PRIVATE**, which the tagging rule above depends on — do not propagate that line.

### The site datasets (DiffusionDB / MET-Meme) — where each half lives, and what is still missing

None of the DATASETS-page material lives in dmpool; the parts are split three ways:

- **The corpus** (bulk files an ingest reads once: `metadata-slice.jsonl.zst` 159MB, `umap-60k.json`, `umap-1m-topic-data.json`, `phrases-tree.json`) is on **<gpu-box> at `~/datasets/diffusiondb/`**, with `~/datasets/README.md` and `sync-to-vps.sh` (stage on the VPS → run `bin/rails datasets:ingest_diffusiondb` → remove; it never runs the ingest itself). The rule stated there: if a page reads it on a request it is runtime data and stays in the VPS DB; if only an ingest reads it, it is a corpus and lives on <gpu-box>. **dmpool's catalog holds NONE of it** (538/MDN/GDD/HF only) — do not route dataset work through dmpool.
- **The ingested rows** are runtime data: 60,000 DiffusionDB prompts in the VPS production sqlite (`storage/production.sqlite3`, `prompt_sources`, all topic-tagged). Re-runs replace, not append.
- **MET-Meme is schema-only by design**: `MemeVocabulary` (pinned by `bin/generate-meme-vocabulary-fixture --check`) is in the studio; no images or labels exist on either box (Kaggle, its own terms). The vocab is served as JSON at `GET /datasets/meme-labels`, which makes it a usable descriptor axis with no image data.
- **Already built**: `PromptSource`, the LIBRARY page, `datasets#draw` / `#use`, the `dataset_draw` pipeline template (draws at filing, provenance in `spec["prompt_source"]`), `/library.json`. **Missing (as of 2026-10-09)**: a batch driver (walk the library → N jobs), a mashup combinator (subject × descriptor), and curated/abridged dataset views. The dataset feature's home is chopshop-studio, NOT chopshop-flux — flux stays the renderer; details in `references/public-datasets.md`.

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
**"Their measured facts win" holds only when they actually MEASURED.** A concurrent land can bake an
UNTESTED assumption into a new test — one arrived asserting the request envelope carried a `profile`
key that the live service refuses with an opaque 400 — so the rebase goes red on a file you never
touched. A failing assertion in a commit that landed after yours is not evidence against you: read
what it CLAIMS, check that against the measurement you hold, and when the measurement wins, correct
their TEST and their PROSE together, quoting the measurement in the commit message so the next reader
sees why a landed test changed. Fixing only the code and leaving their sentence standing is how the
wrong rule survives in a docstring — and on a live-service contract the wrong rule is what the next
session codes against.
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

### "Is there abandoned <plugin / hook / integration> work on this box?"

Answer this from the two places the user's OWN work can live, and expect a NO to be the answer.

- **`~/.hermes/plugins/` and `~/.hermes/hooks/` are the only homes.** An empty directory there is a
  conclusive answer, not an inconclusive one — say so plainly and stop, which is what the user asked
  for when they said "if you don't find anything, leave it for now". There is no per-profile
  `plugins/` dir unless one was created.
- **Do NOT grep `~/.hermes` wholesale for a concept.** `~/.hermes/hermes-agent/` is the upstream
  checkout WITH its test suite, so a search for `decision`, `approval` or `subagent` returns hundreds
  of upstream hits (`tests/tools/test_approval_*`, `tests/tools/test_subagent_*`, a bundled
  `tirith-package-approval-authority`) that read exactly like pre-existing work on the user's idea.
  Exclude `hermes-agent/`, `tools/`, `sessions/`, `cache/`, `.venv/` and `node_modules/` — and prefer
  `-iname` on the artifact NAME (`*decision*`, `*approval*`) over content search.
- **Three secondary signals are worth one check each:** `~/.hermes/kanban.db` (tasks whose title or
  body mentions the concept), `~/.hermes/plugins/` per profile, and `~/.hermes/pending/` — the
  background review's PENDING proposals. Pending entries are not abandoned work, but they carry facts
  someone was about to record and are how a per-repo fact (e.g. the missing global git identity) gets
  found when it is not in the live memory yet.
- **A missing plugin manifest anywhere under `$HOME` settles it.** If `find ~ -name 'plugin.json'`
  (minus `node_modules`/`.venv`) is empty, no plugin was installed or scaffolded, whatever the search
  noise suggests. Report the absence in one line and move on to the part of the request that does
  have work in it.
