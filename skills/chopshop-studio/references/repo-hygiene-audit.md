> contains HOST-SPECIFIC paths (`~/.hermes`). The scan procedure and
> scoring are generic.

# Audit: duplicate agent files, skills, and redundant docs

When the user asks to check for duplicate agents/skills/redundant readmes, the answer is a scored
list, not an impression. Scan four things and report each.

## What to scan

1. **Agent files** — every `AGENTS.md` (and `CLAUDE.md`) on the machine and in the repos. A
   level-3 walk from `$HOME` is enough; prune `.git`, `node_modules`, `.venv`, `__pycache__`, and
   build/output dirs.
2. **Skills on disk** — `~/.hermes/skills/**/SKILL.md`, grouped by directory basename.
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
