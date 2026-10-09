# Repo visibility, host-tagging, and the sync-skills scripts

How knowledge flows between the on-disk Hermes working skill and the repos. The
split is the single rule that keeps the PUBLIC repo clean without forcing the
private side to pretend it is host-agnostic.

## The umbrella model

**There is ONE public repo (`chopshop-svg`) and ONE private umbrella (studio).**
Everything else — `chopshop-studio` (the Rails app), `chopshop-jev` (Jev),
`chopshop-sui` (SwarmUI/ComfyUI), the repo-fleet sweep, and any `-svg`-side
knowledge that is not public-safe (e.g. the studio-side runner) — is under the
studio umbrella. `chopshop-studio` is Apache-2.0 licensed, **private today, but
likely to be made public eventually** — which is exactly why every host-specific
fact must be tagged `HOST-SPECIFIC`: the tags are the scrub line for that
future flip. One on-disk working skill (`chopshop-studio`) covers the umbrella;
the public repo keeps its own repo-owned, host-agnostic skill.

## The rule: redact in public, TAG in private

- `chopshop-svg` is **PUBLIC**. Host-specific and private-stack detail must
  never reach it. Its `sync-skills` **REDACTS**.
- `chopshop-studio`, `chopshop-jev`, `chopshop-sui` are **PRIVATE**. They need
  NOT be purely host-agnostic — host knowledge (paths, ports, timings, this
  box's deploy steps) is useful locally. But every host-specific fact MUST be
  tagged **`HOST-SPECIFIC`**, noted as subject to change and to be removed
  before the skill is reused on another host or published. `chopshop-studio`'s
  `sync-skills` **TAGS** instead of redacting.

The tag token `HOST-SPECIFIC` is the marker to grep for. It appears as:
- a banner (`> HOST-SPECIFIC — …`) immediately under a host-specific section
  heading, and atop a host-specific reference file;
- a `// HOST-SPECIFIC — …` comment banner in a host-specific script (scripts
  are otherwise copied verbatim);
- a legend at the top of the generated SKILL.md explaining the convention.

Everything tagged is subject to change and must be removed or generalized
before reuse. Everything unmarked is host-agnostic and must stay that way.

## sync-skills (chopshop-studio) — TAGS

**The published tree is GENERATED from the working skill again (restored 2026-10-08).**
`GENERATED = ()` had been emptied in `53f2046` (2026-09-29) on the premise that the disk
skill was retired; with an empty list the `for name in GENERATED:` loop in `main()` never
ran, so `drift`/`missing`/`refused` stayed 0 and `./sync-skills --check` **exited 0 by
construction** — it compared nothing while the published tree drifted (measured 2026-09-29:
17 files differed, 11 existed only on disk, 0 only in the repo, and the repo copy still
instructed a `<test-handle>` password reset long after the disk copy was corrected). That is
chopshop-studio issue #15, fixed by repopulating the list: the disk skill at
`~/.hermes/skills/software-development/chopshop-studio` is the source of truth, `GENERATED`
names it, and `--check` now compares and can fail. What follows is the mechanism it runs:

- `GENERATED = ("chopshop-studio",)` — the explicit list of generated skills.
  A listed skill with no on-disk source is a HARD ERROR (exit 1), never a skip:
  the old silent-skip let copies rot while `--check` reported green.
- `SECTION_BANNERS` / `REFERENCE_BANNERS` / `SCRIPT_BANNERS` — dicts keyed by
  the EXACT heading line or filename. The banner is injected right after the
  heading / prepended to the file / prepended as a comment. Key on the exact
  string; a near-miss heading silently gets no banner. **So a banner MOVES when
  its content moves:** splitting SKILL.md into `references/` files (or relocating
  one section) means the moved section's `SECTION_BANNERS` key must be folded
  into the target file's `REFERENCE_BANNERS` entry, and every NEW reference file
  needs its own entry — otherwise the host banner silently vanishes from the
  published copy while `--check` still reports `in sync`.
- `inject_legend()` inserts the `HOST-SPECIFIC` legend right after the YAML
  frontmatter (after the second `---` line).
- Refresh removes stale files in the generated dir that are no longer in the
  source (otherwise a deleted reference lingers).
- One-way: never import the repo copy back over the working skill.

### A TAG MARKS A HOST FACT; IT DOES NOT REMOVE ONE — generation needs TWO passes

A `HOST-SPECIFIC` banner records *where* a host fact is. It removes nothing. So a
tag-only generator and a scrubbed committed copy contradict each other:
regenerating rewrites the file back to the tagged LITERAL, re-publishing exactly
what the scrub removed. A refresh is then an UN-PUBLISH, and `--check` reports
`DRIFTED` forever because the two copies were never meant to be equal.

Generation therefore has two passes, in this order, and the order matters:

1. **TAG** — inject the banners/legend (above). Says where the host material is.
2. **REDACT** — apply an ORDERED `REDACTIONS` tuple of plain string replacements,
   literal → placeholder. Both are needed: tags alone publish the literals, and
   redaction alone scrubs a file without telling a reader which parts are
   this-box facts that must not travel.

**Ordering in `REDACTIONS` is load-bearing**, because they are sequential plain
replacements: `~` must precede `<operator-handle>` (or the home path becomes
`/home/<handle>`), and `chopshop.<domain>` must precede `<domain>`.
`127.0.0.1`/`0.0.0.0` are deliberately NOT redacted — loopback is not a location.
A user HANDLE becomes a visibly-fake placeholder rather than prose, so
`handle: "<operator-handle>"` still parses as Ruby and still says what to
substitute, where `handle: "the operator"` would read as a real broken value.

**A map of today's literals is the same trap one host later**, so every rendered
file is also scanned by `LEAK_GUARDS` and a hit REFUSES the publish — nothing
written for that skill, non-zero exit, whichever mode is running. That makes a
green `--check` mean "published copy is current AND carries no host facts".
State the guard's own limit next to it rather than overselling it: it catches
host-SHAPED facts (domains, handles, home paths, tailnet and RFC1918 addresses),
and an ARBITRARY new hostname it has never been told about still needs a
`REDACTIONS` entry — no regex tells a fresh hostname from the word `nginx`.
Verify the guard by injecting a novel private address into a reference file and
confirming it refuses with file and line, then restoring the file byte-identical.
Verify the redaction with an INDEPENDENT grep of the published tree, never with
the guard that wrote it.

### A PUBLISH OVERWRITES REPO-SIDE EDITS — read `--diff` first

The one-way rule (never import a repo copy back over the working skill) is about
the LITERALS. It is not a licence to publish blind: the committed copy gets
hand-edited in place, and regenerating from a stale source silently reverts that
work. A reference file carried P1–P5 progress recording a subsystem shipped,
added in-repo across three commits that each touched that ONE file — while the
on-disk skill still said the phases were unstarted. Redaction cannot cause that
loss; regenerating from a stale source can.

So the workflow is: **`--diff` → read it → fold anything the repo copy knows and
the disk copy does not back INTO the on-disk skill → publish → `--check` green.**
A commit touching a single file under `skills/` is the signature of a hand edit
(a publish rewrites many files at once); `git log --oneline -- <that file>`
settles it. And when a diff shows a paragraph "removed", check the DISK copy for
the distinctive phrase before calling it lost content — a unified diff reports
rewording as a line on both sides, so most of a long diff is usually phrasing,
not deletion. Grep for the rule's own words (`minitest/mock`, the convention it
names) one file at a time.

Editing the on-disk skill after a publish makes the repo copy stale by design,
so re-run `./sync-skills` and commit — an uncommitted publish leaves `--check`
green against a repo copy nobody else can see.

Usage: `./sync-skills` (refresh), `--check` (drift only, non-zero on drift,
missing source, or a refused leak), `--diff` (show changes; run it before
publishing).

## sync-skills (chopshop-svg) — REDACTS

Same split, opposite direction for a public repo:

- `GENERATED` tuple (currently empty) lists skills copied from disk WITH
  sanitisation; everything else under `skills/` is REPO-OWNED (hand-maintained,
  no disk source).
- `REDACTED_SECTIONS` — H2-heading → replacement pointer text, for sections
  whose backing code is absent from the repo (e.g. the SwarmUI bridge).
- `REDACTIONS` — regexes that scrub hostnames/private IPs/private-script
  filenames even mid-sentence (`*.tail*.ts.net`, `10.`, `192.168.`, `100.`,
  `swarm_bridge.py`, `SWARMUI_PLAN.md`).
- A listed generated skill with no source is a hard error, not a skip.

## CONTEXT.md (all four repos)

Each repo carries a root `CONTEXT.md` tracking **work in progress, blockers,
and caveats** — the standing convention is to keep it current as work lands. A
landed feature moves out of WIP; an open follow-up stays with an owner and a
note. Record a caveat there rather than letting suite-count / port / flag prose
drift across README/OVERVIEW/AGENTS. The public repo's CONTEXT.md must stay
host-agnostic like the rest of it.

## Hard policy + root of origin (where a rule lives)

Every repo's `AGENTS.md` (the agent-facing doc) carries a **"Hard policy"**
section at the top: the non-negotiable rules for that repo. The split is by
origin, not by convenience:

- **Repo-level rules** (deploy/restart discipline, visibility, the unit-of-done)
  live in that repo's `AGENTS.md` hard-policy section — they apply to anyone
  editing that repo, on any host.
- **System-specific minutiae** (title/subtitle structure, button sizes, fonts,
  the operator vocabulary) live at their **root of origin** — the repo that owns
  the system. For the studio UI that is `docs/ui-conventions.md` in
  `chopshop-studio`. A one-off inline change to a font size or button shape is
  a bug against that convention, not a new rule.

This is the same direction as the host-tagging split: canonical repo facts go
in the repo; this box's deployment specifics stay in the working skill.

## Doc layout + the doc-move pitfall

- Canonical shape: `docs/` holds repo docs; `docs/agents/` holds the
  agent-skill references (issue-tracker, triage-labels, domain). A bare `doc/`
  directory is the legacy shape — consolidate into `docs/`.
- **Moving/renaming a doc file breaks whatever reads it by path.** A
  prose-reference sweep (grep the filename in `.md`/views) misses the one reader
  only a test run catches: `test/lib/runner_contract_test.rb` loads the contract
  doc via `Rails.root.join("doc", ...)`, so moving `doc/runner-contract.md` →
  `docs/` fails every case with `Errno::ENOENT`. Grep the TEST tree and app code
  for the literal path (not just docs), update it, and run the affected suite.
