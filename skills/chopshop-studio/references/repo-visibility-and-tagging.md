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

Generates `skills/chopshop-studio/` from the on-disk Hermes skill
(`~/.hermes/skills/software-development/chopshop-studio`). Mechanism:

- `GENERATED = ("chopshop-studio",)` — the explicit list of generated skills.
  A listed skill with no on-disk source is a HARD ERROR (exit 1), never a skip:
  the old silent-skip let copies rot while `--check` reported green.
- `SECTION_BANNERS` / `REFERENCE_BANNERS` / `SCRIPT_BANNERS` — dicts keyed by
  the EXACT heading line or filename. The banner is injected right after the
  heading / prepended to the file / prepended as a comment. Key on the exact
  string; a near-miss heading silently gets no banner.
- `inject_legend()` inserts the `HOST-SPECIFIC` legend right after the YAML
  frontmatter (after the second `---` line).
- Refresh removes stale files in the generated dir that are no longer in the
  source (otherwise a deleted reference lingers).
- One-way: never import the repo copy back over the working skill.

Usage: `./sync-skills` (refresh), `--check` (drift only, non-zero on drift or
missing source), `--diff` (show changes).

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
