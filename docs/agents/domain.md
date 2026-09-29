# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## This repo's shape (single-context)

chopshop-bp is a **single-context repo**: the one context document is
**`CONTEXT.md` at the repo root**, and it is where domain vocabulary, working state and caveats live. There is **no `CONTEXT-MAP.md`** and **no `docs/adr/`** in this repo today — do not go looking for either, and do not create them speculatively. A decision worth an ADR gets one lazily, when a term or decision actually needs it.

The domain language is the **blend-plot** vocabulary: the two halves (`plot` draws documents, `blender` renders 3D), the six operations (`generate`, `digest`, `query`, `tree`, `log`, `blender`), and the metrics schema (`metrics_version`, `source_sha256` + `recipe_hash`, a flat field registry). `docs/contract.md` is where those names are defined as an interface; `CONTEXT.md` is where their caveats live.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — this repo's context document, and the only one.
- **`CONTEXT-MAP.md`** at the repo root *if it ever appears*: it would point at one `CONTEXT.md` per context, and you should read each one relevant to the topic. It does not exist here yet.
- **`docs/adr/`** *if it ever appears*: read ADRs that touch the area you're about to work in. It does not exist here yet either.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

This repo today (single-context; `docs/adr/` waits for a decision that needs one):

```
/
├── CONTEXT.md            ← the context document (repo root)
├── AGENTS.md             ← agent orientation / hard rules (protected; see below)
├── README.md
├── cli.py                ← the CLI (generate, digest, query, tree, log, blender, serve)
├── chopshop_plot/        ← the package: spec.py (validation), the five SVG
│                           operations, metrics.py (the schema), query.py
│                           (scatter/pareto/diff), server.py (the HTTP surface),
│                           config.py (env only), svg.py, png.py, fractals.py
├── blender/              ← bpy_geometry.py: the script that runs INSIDE Blender
├── docs/                 ← contract.md (the interface), agents/
├── demo/                 ← the geometry / fractals / animation generators
├── examples/             ← specs and .run.json records (examples/runs/)
└── tests/
```

The generic single-context shape, for comparison (most repos, not this one):

```
/
├── CONTEXT.md
├── docs/adr/
└── src/
```

Multi-context repo (presence of `CONTEXT-MAP.md` at the root):

```
/
├── CONTEXT-MAP.md
├── docs/adr/                          ← system-wide decisions
└── src/
    ├── ordering/
    │   ├── CONTEXT.md
    │   └── docs/adr/                  ← context-specific decisions
    └── billing/
        ├── CONTEXT.md
        └── docs/adr/
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_

There are no ADRs in this repo yet, so today this rule applies to the settled positions in `CONTEXT.md` — its "What this repo is NOT" list and its caveats. Contradicting one of those needs the same explicit treatment.

## Notes for this repo

- **`AGENTS.md` is a protected agent-instruction file.** The write guard requires human approval to write it (one operation at a time, no persisted scope), so an agent session cannot correct a stale line there. Correct the record in `CONTEXT.md` and name the `AGENTS.md` line that needs a human.
- **`docs/contract.md` is the interface, not commentary.** A change to a chart type, a metric field or the schema updates the contract and the tests in the same commit (`AGENTS.md`, `CONTEXT.md`).
- **`docs/agents/` is plain documentation**, not protected: `issue-tracker.md` (GitHub issues via the `gh` CLI) and `triage-labels.md` (the five triage roles, each label string equal to its name).
