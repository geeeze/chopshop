# Skills

`chopshop-studio` is the agent skill for this repo. It is plain Markdown with
YAML frontmatter (Hermes/Claude-skill format), so it doubles as deep
documentation and can be re-imported by any agent running Hermes or a
compatible skill system.

| Skill | Covers |
|---|---|
| `chopshop-studio` | The operator UI and the whole studio surface: the operator vocabulary (candidates / jobs / proofs), the password-only per-user auth model (a bcrypt `users` table where the password is the identity, with owner-column isolation), change-and-deploy, the live-verification gate, the runner contract, the Jev add-on, the front-end layout/aesthetic invariants, and the backend/runner/deploy trap list. |

The directory mirrors a Hermes skill directory (`SKILL.md` plus `references/`),
so importing it is a straight copy:

```bash
cp -r skills/chopshop-studio ~/.hermes/skills/chopshop-studio
```

## This copy is generated — and host-tagged

`./sync-skills` refreshes this directory from the author's on-disk Hermes
working skill. This repo is **private**, so host-specific knowledge may stay —
but every host-specific fact is tagged `HOST-SPECIFIC` so a reader can tell
deployment details apart from host-agnostic knowledge. The tag appears as:

* a banner under a fully host-specific section heading, and
* a banner at the top of any reference file that names this box's paths/ports.

Grep `HOST-SPECIFIC` to enumerate everything flagged. Everything tagged is
**subject to change** and must be removed or generalized before this skill is
reused on another host or published elsewhere.

```bash
./sync-skills            # refresh the tagged copy
./sync-skills --check    # report drift, change nothing; non-zero on drift or a missing source
./sync-skills --diff     # show what would change
```

The direction is one-way on purpose: **never import a repo copy back over a
working skill.** A repo copy is downstream; importing it would silently undo
local work. A generated skill whose on-disk source is missing is a hard error,
not a skip — the silent skip is what once let copies rot.

## Why the public repo is different

`chopshop-svg` is the public repo, and its `skills/` carry only host-agnostic
pipeline knowledge — its `sync-skills` *redacts* host detail instead of merely
tagging it. This repo can afford to keep host specifics in place, so it tags
them rather than deleting them.
