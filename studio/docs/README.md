# chopshop-studio docs — index

Where to start, depending on who you are. Everything here is in-repo on purpose:
an agent driving this system should not have to read a Hermes skill or a chat log
to find out what it is.

## The three orientation documents

| document | what it answers |
|---|---|
| [`SYSTEM.md`](SYSTEM.md) | **What is this whole thing?** The six components and the one repository they live in — what each does, the data flow (raster → trace → candidates → human picks → proof), the runner contract in outline, and the one-way seams. Host-agnostic: no addresses, no hostnames. Start here if you have just landed in this repository. |
| [`SURFACES.md`](SURFACES.md) | **What can I call?** One registry of every invocable surface in the six components — shell commands, CLIs, HTTP routes — with what each does, its input shape and its output shape. |
| [`agent-api.md`](agent-api.md) | **How do I drive this studio from a script?** The canonical HTTP driver contract: login and per-user identity, the two CSRF tokens, filing a job, which routes have JSON and which do not, polling, proofs, downloads, the https-`Location` gotcha, and `GET /engine.json`. |

## Contracts and conventions

| document | what it covers |
|---|---|
| [`runner-contract.md`](runner-contract.md) | The studio ↔ runner HTTP contract in full (v1): every route, payload, status code and the requirements on a runner box. Authoritative for anything the studio sends to a runner. |
| [`jobs-json.md`](jobs-json.md) | The three JSON branches of `GET /jobs/:id.json` — `?log=1`, `?candidate=<file>`, and the default status poll — with their exact response shapes, the 404 case, and the `done`/`log_html` semantics. |
| [`step-lists.md`](step-lists.md) | A job that asks for several runner actions in order: the `steps` shape, who drives the chain (the studio, never a runner), the per-step file rules, and what a mid-chain failure reports. |
| [`ui-conventions.md`](ui-conventions.md) | How the studio looks and reads: layout, controls, colour, typography — the standard a UI change is held to. |
| [`agents/`](agents/) | The shared agent-skill block every repo in the fleet references instead of copying: [`domain.md`](agents/domain.md), [`issue-tracker.md`](agents/issue-tracker.md), [`triage-labels.md`](agents/triage-labels.md). |

## Studies and reviews (read for context, not for rules)

| document | what it is |
|---|---|
| [`agent-surface-gaps.md`](agent-surface-gaps.md) | The audit of this system from an agent's perspective: what was already good, eight gaps and a priority order. `SYSTEM.md`, `SURFACES.md`, `agent-api.md` and `GET /engine.json` are the answers to gaps 1–3 and 7. |
| [`reference-settings-density.md`](reference-settings-density.md) | How the studio keeps a ~40-control settings popup readable: the joined-pill view switch, the always-in-the-DOM two-body swap, the density budget, and the recording rule (every layout decision is a measurement, written down). Landed from #25. |
| [`architecture-review-scrapbook-composite.md`](architecture-review-scrapbook-composite.md) | Architecture review of the composition subsystem (scrapbook + composite), with the four most recent commits as the window. |
| [`game-asset-generation.md`](game-asset-generation.md) | Research report on semi-automated composite generation for indie game assets — a proposal, nothing built. |

## Repo-level pointers

- `../AGENTS.md` — how to work in *this* repo (host facts, hard rules, commands).
- `../CONTEXT.md` — work in progress, blockers and caveats.
- `../README.md` — what the studio is, for a human arriving cold.
- `../skills/` — the Hermes skills for this deployment (operator-facing
  workflows); the documents above are the repo-side equivalent and do not assume
  Hermes.
