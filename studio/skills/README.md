# Skills

`chopshop-studio` is the agent skill for this repo. It is plain Markdown with
YAML frontmatter (Hermes/Claude-skill format), so it doubles as deep
documentation and can be re-imported by any agent running Hermes or a
compatible skill system.

| Skill | Covers |
|---|---|
| `chopshop-studio` | The operator UI and the whole studio surface: the operator vocabulary (candidates / jobs / proofs), the password-only per-user auth model (a bcrypt `users` table where the password is the identity, with owner-column isolation), change-and-deploy, the live-verification gate, the runner contract, the Jev add-on, the front-end layout/aesthetic invariants, and the backend/runner/deploy trap list. |
| `chopshop-studio-ui` | A focused complement: changing the studio UI (validation/job pages, popups, CSS effects, the mock runner), the private-repo rules, Turbo-safe JS, stacking-context traps, and the container render harness. |

The directory mirrors a Hermes skill directory (`SKILL.md` plus `references/`),
so importing it is a straight copy:

```bash
cp -r skills/chopshop-studio "$HERMES_SKILLS_DIR/chopshop-studio"
# (HERMES_SKILLS_DIR is your Hermes skills root — the directory Hermes loads skills from)
```

## This copy is GENERATED from the working skill — and host-tagged

This directory is **generated** by `./sync-skills` from the author's on-disk
Hermes working skill at `$HERMES_SKILLS_DIR/software-development/chopshop-studio`
(that is the skill an agent loads, so it is the source of truth). Generation was
retired on 2026-09-28 on the false premise that the disk skill was dead; the two
copies then drifted while `--check` stayed green by construction, and this repo
copy kept instructing a password reset of the operator's own account long after
the disk copy was corrected (chopshop-studio issue #15). Generation is restored:
`GENERATED` names the skill, `--check` compares and can fail, and the tag+redact
passes described below run on every publish. **Never hand-edit this tree without
folding the change back into the disk skill first** — a `./sync-skills` publish
overwrites it.

Since 2026-10-08 `SKILL.md` is a short router and its body is split into domain
reference files (`design-and-vocabulary`, `change-and-live-verification`,
`ux-and-frontend`, `backend-rails-and-infra`, `runner-and-services`,
`verification-and-probes`, `working-agreements`, `dataset-derivation-rules`), so
an agent loads the topic it needs instead of the whole 100 KB body.

This repo is **private**, so host-specific knowledge may stay — but every
host-specific fact is tagged `HOST-SPECIFIC` so a reader can tell deployment
details apart from host-agnostic knowledge. The tag appears as:

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
