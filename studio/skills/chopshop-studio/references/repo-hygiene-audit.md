> contains HOST-SPECIFIC paths (the Hermes home). The scan procedure and
> scoring are generic.

# Audit: agent files, skills, docs, and public/private leakage

When the user asks to audit the workspace — duplicate agents/skills/redundant readmes, OR the wider
"check the tracker, check the agent files, note any skill that needs updating, check for leakage
public/private" — the answer is a scored list backed by `file:line` evidence, not an impression. The
duplication half is below; the visibility half is its own section at the end. Scan four things and
report each.

## What to scan

1. **Agent files** — every `AGENTS.md` (and `CLAUDE.md`) on the machine and in the repos. A
   level-3 walk from `$HOME` is enough; prune `.git`, `node_modules`, `.venv`, `__pycache__`, and
   build/output dirs.
2. **Skills on disk** — the Hermes skills tree (`**/SKILL.md`), grouped by directory basename.
3. **In-repo skill copies** — `<repo>/skills/**/SKILL.md`. These are the ones that can silently
   diverge from the on-disk skill they were generated from.
4. **Docs per repo** — `*.md` over ~1.2KB, which skips changelogs and stubs while keeping every
   real document.

## Scoring

Byte-identical files: md5 the whole file. Identical copies across repos are either a deliberate
scaffold or drift — say which by reading one.

Prose (paragraph-level), for near-duplication:

- Strip fenced code blocks, collapse whitespace, lowercase, drop punctuation.
- Keep only paragraphs of >=12 words, so headings and one-liners do not dominate.
- Exact duplicates: hash the normalised paragraph.
- Near duplicates: token-set Jaccard >= 0.70. Below ~0.5 you are matching boilerplate, not
  duplicated content — a section that repeats a table header is not a redundancy finding.

**Precompute the paragraph and shingle sets ONCE per document, then loop the pairs.** Building them
inside the pairwise loop is O(n^2) real work and will blow the execution timeout on a moderate
corpus (84 skills, 6 docs) before printing a single result. Cache per document keyed by path.

Skills specifically: shingle at ~6 words and flag pairs at >= 30% — separate descriptions and
regions of a long skill legitimately overlap, so a low threshold on a big corpus returns noise.

## Interpretation — what is NOT a finding

- **Templated artifacts repeat by design.** Per-run reports (comparison tables, manifests) share
  their whole skeleton; that is the template working. Check whether the path is gitignored before
  reporting it as doc debt — a generated artifact is not a document anyone maintains.
- **Code identifiers repeat.** The same key, function or directory name in two files is the API,
  not duplicated prose.
- **Scope-different skills overlap honestly.** An in-repo skill covering one subsystem and the
  on-disk skill covering the whole project can share ~0% and both be right.
- **Drift is more interesting than duplication.** Between two near-identical files, read for the
  one thing that DIFFERS: two docs describing the same quantity under different names (one says
  "screens declared", the other "inks declared") is a correctness bug in the docs, and it is what
  the user actually needs told. Report the divergence, not just the overlap count.

## The checks that pay off

- **A scaffold's absent files are usually MANDATED, not dangling.** Before reporting a `docs/agents/`
  file that names `CONTEXT.md` and `docs/adr/` as a dangling pointer, read that file: the domain
  template states outright that a missing `CONTEXT.md` is normal and must be proceeded past
  silently, because `/domain-modeling` creates it lazily. Absence is the designed state, so
  reporting it as a defect is a false positive that devalues the whole audit.
- **Hash every copy before calling them identical, and name the exact scope you hashed.** Only part
  of a scaffold is shared: `domain.md` and `triage-labels.md` are byte-identical across the repos
  (they are the generating skill's seed templates, accepted as-is), while `issue-tracker.md` DIFFERS
  per repo BY DESIGN — the root copy reads "Local Markdown" (`.scratch/`) and each repo copy reads
  "GitHub". Grouping all three as identical, or concluding one file "cannot be correct for both",
  both misread a per-repo split that had already happened. Compare md5s, list exactly which paths
  match, and never extrapolate identity to a set you did not hash.
- **These files are the per-repo CONTRACT for the engineering skills**, not spare documentation:
  `triage`, `to-tickets`, `to-spec`, `wayfinder` and `domain-modeling` read them. Repetition across
  repos is the design, so never recommend deleting or centralising them to reduce a duplicate count.
  Before proposing any consolidation, read the skill that generated the artifact — it defines what
  may be removed and what must stay.
- In-repo skill copies with no on-disk source: report them as stale, because they can no longer be
  refreshed — this is the failure the sync generator must refuse rather than skip.
- A second full checkout of a repo you are changing (e.g. under a cache/scratch dir): a second
  working copy is how stale edits and lost commits happen. Report its HEAD and dirty count, and
  do not edit it.
- **A registered worktree whose branch's content merged is still reported UNMERGED.** After a
  rebase/squash landing, `git merge-base --is-ancestor <branch> main` can say false while the code
  is live on main (e.g. `feature/login-js-split` content landed as `39fed5e` but ancestry says
  dangling). A rescuable-looking branch is not lost work. Verify the content is on main (grep
  the key symbols) before `git worktree remove` + `git branch -D`; do not trust the ancestry
  verdict alone.
- **A vendored bundle is a git add -A landmine.** An agent that ran `bundle install --path
  vendor/bundle` leaves an untracked `.bundle/config` (BUNDLE_PATH: vendor/bundle) plus a
  multi-hundred-MB `vendor/bundle/`, and this repo's `.gitignore` has no `vendor/` rule (the
  Rails default does). One `git add -A` commits 171MB of gems. `git status` disguises it as
  "just untracked". Similarly `.ruby-version` on main (3.2.3) can disagree with the Ruby the box
  actually runs (3.3.8). Pin the version the deployment runs, gitignore `vendor/bundle`, and
  never `git add -A` a vendored bundle.

## Consolidating what the audit finds

Give each duplicated block a single OWNER instead of cross-linking two copies. Pick the authoritative
one for that material — usually the deeper, more current doc, which already carries the sections the
other lacks — keep the material there, and reduce the other to the reasoning it alone owns plus a
pointer. Two documents that both state the rule keep the duplication and leave the reader unsure
which is current.

Two traps in the same edit:

- **Colliding H2s.** Two docs with the same section title mean a search lands on whichever comes
  first, often the summary when the reader wanted the list. Rename the summarising side so its
  heading says what it now is, then re-check for title collisions across all the human-facing docs.
- **Assigning beats deleting.** Confirm the survivor actually received each fact before removing the
  copy, and re-read the pointers: a "see the next section" written for the old layout dangles the
  moment sections move.

Prefer rewriting the stale sentence in place over appending a correction underneath it — a
contradicted claim left standing above its own correction is what sends the next reader down the
wrong path.

## Reporting

Lead with the counts per category, then the pairs with their scores, then the divergences. If a
finding needs a repo-wide rename or a structural edit, and another agent is actively pushing to
those repos, recommend it and wait — do not start a structural edit you will collide with. Splitting
a scaffold is not one of those findings: per-repo scaffold copies are per-repo on purpose. State a
claim about a file only as narrow as what you actually measured ("identical in these four paths",
not "identical"), because a scope you did not verify is the one that gets withdrawn later.

## The visibility audit — public/private leakage

Four independent surfaces. The FIRST one is what keeps the other three from being buried in noise:

1. **Scan TRACKED files, not the working tree.** `git ls-files` is the publish surface; a walk of the
   working directory answers a different question. On the studio box a full-tree scan returned 541
   hits, overwhelmingly inside gitignored `runner-data/` (generated job artifacts) and
   `docker-compose.override.yml` (machine-local paths, ignored by design) — a pile of noise that buried
   every finding that mattered. Before reporting ANY hit, confirm the file is tracked
   (`git ls-files <path>`) and read the ignore rule (`git check-ignore -v <path>`). An untracked file
   full of host paths is a finding to NOTE, never headline.
2. **Scan history, not just HEAD.** `git log --all --oneline -S"<literal>" --pickaxe-regex` per
   host-shaped pattern (domain, tailnet and RFC1918 ranges, box nicknames, private-script filenames,
   `-----BEGIN`, `ghp_`/`github_pat_`, the secret env-var names). A fact deleted from HEAD is still
   published, which is how a `/health` host label was found in a public repo's history. Include the
   `assert "<host>" not in source` form: the guard that BANS a literal contains the literal.
3. **Scan commit METADATA — file-content scans cannot see it.** `git log --format='%ae' | sort |
   uniq -c` per repo, and for a PUBLIC repo confirm what GitHub actually publishes with
   `gh api repos/<o>/<r>/commits/<sha> --jq '.commit.author'`. A personal email as author/committer is
   public and indexed like content, and it is unfixable by editing files — only by rewriting the
   commits, which reduces rather than retracts. **The repo's own `user.email` being correct does NOT
   clear it**: an inline `-c user.email=`, a second checkout, or an env override commits under another
   identity, so compare the config against the LOG. Report which account GitHub attributed the commit
   to (`author.login`) instead of assuming, and check all repos — private-today-but-likely-public-later
   is exactly where this rots.
4. **A documented guard is not a leak — but read what the guard itself publishes.** A redaction list
   necessarily contains the literals it exists to scrub (a private-script filename, a section
   heading), and a repo whose policy forbids naming a private stack may still name it in the redactor.
   That is its own finding, not something to suppress or to call a leak.

**Before trusting any green check, confirm it has something to compare.** A generator whose input set
was emptied left its `--check` looping over nothing and printing success — read the main loop and
check the set it iterates is non-empty (`for n in (): …` cannot fail), then prove the check bites by
changing one input and watching it refuse. **File a leak finding PRIVATELY even when it concerns the
public repo**: an issue body naming the private repos, the stack, or the leaked literal repeats the
leak in a searchable public thread, so file it against a private tracker and say why in the body.

**Doc facts rot and nothing catches them.** `AGENTS.md` environment facts ("Python 3.13", "the suite
passes N tests") are the most-quoted and least-checked lines in a repo — one was a minor off on the
interpreter and another was already wrong by 90 tests within hours of being written. Suite counts are
environment-dependent: the same suite read `805 passed, 48 skipped` on a bare host (the container-only
render tools are absent by design) against `853 collected`, so a count means nothing without the box it
was measured on. Grep the agent files for version numbers and counts, re-measure each, and recommend
replacing the number with the command that produces it. That no repo in this fleet has CI is CONTEXT
for why the drift went unnoticed — not a defect to file.
