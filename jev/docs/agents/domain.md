# Domain Docs

How the engineering skills should consume this repo's domain documentation when
exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — the single context document for this repo.
  It holds what is in flight, what is blocked, and the caveats that are not
  obvious from the code.
- **`AGENTS.md`** at the repo root — the binding policy: Jev is optional and
  advisory, the annotator is never reimplemented in another repo, and the
  remediation loop is dry-run only until steps 3+ land.
- **`docs/`** — `local-decision-service.md` (hosted vs local backend, the one
  certainty trap), `dataset-translation.md` (the second vocabulary and its honest
  limits), `remediation-loop.md` (the plan; steps 1–2 of its §10 are built).

`chopshop-jev` is a **single-context repo**. There is no `CONTEXT-MAP.md`, no
`docs/adr/`, and no `src/` tree — the code is `scripts/` plus `tests/`. A
document that sends you to any of those is stale; say so rather than creating one.
The `/domain-modeling` skill may add a context document lazily, but the repo
already has its one, so adding a second is a change worth arguing for.

## Where the domain vocabulary lives

The vocabulary is **data in the code**, and the code is the specification — not
an ADR:

- `scripts/jev_annotate.py` holds `QUESTIONS`, `MEME_QUESTIONS`, `SLOP_QUESTIONS`
  and `PROFILES` (a template is a projector + questions + a fold), plus
  `ENVELOPE_KEYS`, `QUESTION_TYPES` and `UNSUPPORTED_QUESTION_TYPES` — the last
  two carry the live measurements behind what the service accepts.
- `scripts/remediation_table.json` holds the `failure_mode` → remedy policy, with
  its own `_deviations_from_plan_doc` note where the plan was overtaken by code.
- `scripts/slop_cannon.py` holds the raster measurements (`slop_*`) and the
  keep/escalate/drop bucketing, which is the caller's job and never the
  annotator's.
- `tests/` is the behavioural spec for all of it.

Use the terms the way `CONTEXT.md` and those constants define them: a **template**
(or **profile**) is a question set plus its projector and fold; a **state** is the
projection that leaves the machine; a **verdict** is the folded answers; a
**failure_mode** is one `choice` value, never a free-form label. Do not drift to
synonyms the docs avoid — in particular, Jev **annotates** and never **ranks**,
**picks** or **gates**.

If the concept you need isn't defined yet, that's a signal: either you're
inventing language the project doesn't use (reconsider) or there's a real gap
(record it in `CONTEXT.md`).

## Flag conflicts, don't rewrite around them

If your output contradicts a recorded position — a `CONTEXT.md` caveat, an
`AGENTS.md` hard-policy rule, or a `_deviations_from_plan_doc` entry — surface it
explicitly rather than silently overriding:

> _Contradicts `CONTEXT.md`'s settled "no `--questions` flag" position, but worth
> reopening because…_
