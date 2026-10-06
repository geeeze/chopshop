# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## This repo

**Single-context.** One `CONTEXT.md` at the repo root, and that is the only
domain document: there is no `CONTEXT-MAP.md` and no `docs/adr/`. Read
`CONTEXT.md` first — it is the working state (what is in flight, the measured
facts, the caveats that are not obvious from the code) and it is updated as work
lands, so it is more current than `README.md` for anything in flight.

Two facts about this repo change how the docs are read:

- **The repo is private, and its registry encodes licence facts and measured
  machine behaviour.** Keep the model/LoRA/VAE registry, licence findings and
  measured timings out of any public repo (notably the public `chopshop-svg`).
- **`chopshop_flux/models.py` is hand-mirrored by `chopshop-studio`'s
  `app/models/flux_conf.rb`, and nothing syncs them.** The studio renders its
  FLUX page from that copy, including the model list, the per-family dimension
  constraints and the service's route list. An edit to the registry with no
  matching edit in the studio silently makes the studio claim facts this service
  no longer has. `models.py` is the source; the studio is the mirror.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — what it is, what is in flight, the
  measured facts, the caveats that are not obvious from the code.
- **`AGENTS.md`** — the binding hard policy: never modify the GPU environment
  this runs against; `torch` is imported inside methods, never at module scope;
  the tests run with no GPU, no torch, no models and no network; nothing in the
  repo names a host, a port or a path; the licence gate lives in
  `models.check_usable` and is not advisory; do not weaken a caveat into a knob;
  comments are section-level WHY blocks with a `#label-name-function`
  breadcrumb.
- **`README.md`** — the shape of the thing: running the service, the env table,
  the measured timings, the example set.
- **`docs/API.md`** — the contract, route by route, with the measured numbers
  behind each output-side pass.

The real layout (there is no `src/` tree):

```
/
├── CONTEXT.md            ← the one context document
├── AGENTS.md             ← hard policy for edits
├── README.md             ← running it, the env table, measured timings
├── issue-tracker.md      ← a POINTER; GitHub issues are the tracker
├── chopshop_flux/        ← service + client; no torch at module scope
│   ├── config.py         every environment variable, read at call time
│   ├── guard.py          the GPU-contention guard (#flux-gpu-guard)
│   ├── models.py         the registry: licences, VRAM, resolution rules, flags
│   ├── modifiers.py      LoRA adapters and VAE swaps, with their own gate
│   ├── styles.py         named styles: prompt suffix + trace preset
│   ├── engine.py         the diffusers seam; the only module touching torch
│   ├── postprocess.py    the output-side passes; stdlib only (no PIL, no torch)
│   ├── server.py         the HTTP service; stdlib only, engine injected
│   ├── client.py         the stdlib client; the network is two methods
│   ├── cli.py            serve, health, models, generate, edit, gen2pipe
│   └── examples.py       loads and validates examples/prompts.json
├── docs/                 API.md, MODELS.md, MODELS-PLAN.md, agents/ how-tos
├── deploy/               the systemd user unit and its EnvironmentFile example
├── examples/prompts.json the machine-readable example/test prompt set
├── scripts/              smoke.py, smoke_examples.py, probe_output_path.py,
│                         measure_output_passes.py
└── tests/                the suite — no GPU, no torch, no models, no network
```

If any of these files don't exist, **proceed silently**. Don't flag their
absence; don't suggest creating them upfront. The `/domain-modeling` skill
(reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates
decisions documentation lazily when terms or decisions actually get resolved.

## Use the vocabulary the docs already use

Terms this repo pins down: **the service** (`chopshop_flux serve`), **the
client** (`chopshop_flux` as a module, whose network is two methods), **the
registry** (`models.py`), **the gate** (`_guard_gate`: `off`/`warn`/`wait`/
`block`), **a pass** (the output-side ones: `hires`, `ink_cap`, `background`,
`seeds` — opt-in, in a fixed order, each reporting what it measured),
**provenance** (inputs and measurements a later comparison reads — never a
score), **the mirror** (the studio's hand-copied `flux_conf.rb`), **distilled**
vs **CFG**, **guidance-embedded**, **the licence gate**, **modifier/VAE
targets**. `CONTEXT.md`'s caveats carry the same vocabulary in more detail; use
those terms.

When your output names a domain concept (an issue title, a refactor proposal, a
hypothesis, a test name), use these — don't drift to synonyms: not "filter pass"
for a `generate`-with-`hires`, and not "best" or "winner" for anything this
layer produces (it never judges the art — `AGENTS.md`'s first rule).

If the concept you need isn't here, that's a signal: either you're inventing
language the project doesn't use (reconsider) or there's a real gap (note it for
`/domain-modeling`).

## Flag conflicts with the hard policy

There are no ADRs here; decisions live in `AGENTS.md` (binding rules) and
`CONTEXT.md` (caveats and measured facts). If your output contradicts one,
surface it explicitly rather than silently overriding:

> _Contradicts AGENTS.md's "nothing in the repo names a host, a port or a path
> belonging to one machine", but worth reopening because…_
