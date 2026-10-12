# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — the single context document for this repo: what it is, work in progress, blockers, and the caveats that are not obvious from the code.
- **`AGENTS.md`** — the binding hard policy for edits (the one-way pipeline seam, "never judge art", VTracer-only tracing, `colormode=color` on generated images, host-specific material stays private, the comment convention).
- **`README.md`** — the shape of the thing: the two pieces (bridge, workflow), the three bridge modes, the workflow files.

This is a **single-context** repo. There is no `CONTEXT-MAP.md`, no per-directory `CONTEXT.md`, no `docs/adr/` directory, and no `src/` tree. The real layout is:

```
/
├── CONTEXT.md          ← the one context document
├── AGENTS.md           ← hard policy for edits
├── README.md
├── scripts/            ← swarm_bridge.py, front_common.py (2-helper vendored shim),
│                         comfy_to_swarmui.py, swarm_styles.json, SWARMUI_PLAN.md
├── swarm_workflows/    ← the ComfyUI API graph, the SwarmUI wrapper, the ChopShopTrace node
├── tests/              ← the bridge suite (SwarmUI HTTP layer stubbed)
├── skills/             ← the private-stack integration skill
└── docs/               ← workflow research (workflow-candidates.md) + agents/ how-tos
```

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates decisions documentation lazily when terms or decisions actually get resolved.

## Use the vocabulary the docs already use

Terms this repo pins down: **the bridge** (`scripts/swarm_bridge.py`), **the seam** (the one-way call into chopshop-svg's `front_pipeline.sh`, reached by `gen2pipe` only), **candidate** (a traced SVG awaiting a human pick), **sweep** (the trace-parameter grid handed to the pipeline), **style recipe** (a style entry: prompt suffix + trace preset — the bridge's `BUILTIN_STYLES`, historically a `swarm_styles.json` entry; that fork was retired 2026-10-12 and the vocabulary lives in chopshop-flux's `styles.py`), **the node** (`ChopShopTrace`, the in-graph VTracer).

When your output names a domain concept (an issue title, a refactor proposal, a hypothesis, a test name), use these — don't drift to synonyms: not "filter pass" for a `generate`-with-style, not "best" or "winner" for anything this layer produces (it never ranks art — `AGENTS.md` policy 2).

If the concept you need isn't here, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag conflicts with the hard policy

There are no ADRs here; decisions live in `AGENTS.md` (binding rules) and `CONTEXT.md` (caveats). If your output contradicts one, surface it explicitly rather than silently overriding:

> _Contradicts AGENTS.md policy 4 (`colormode=color`, never `binary`, on generated images), but worth reopening because…_
