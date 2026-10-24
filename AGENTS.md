# AGENTS.md — chopshop

One repository for the app and its sidecars. Before this file the rules lived in
six per-repo `AGENTS.md` files with a word-for-word identical preamble and
different component details; an agent moving between repos lost half of them.
The shared rules are here, ONCE. Component-specific rules stay beside the
component.

## The components

| dir      | what it is                                                   | port |
|----------|--------------------------------------------------------------|------|
| `studio/`| Rails 8 app — the operator's surface                         | 3001 |
| `svg/`   | trace + validate pipeline, and its HTTP runner               | 8787 |
| `bp/`    | blend + plot: Blender renders, geometry, digests             | 8796 |
| `flux/`  | generation service; needs a GPU                               | 8795 |
| `jev/`   | decision annotator + gateway + the local laya model          | 8799 |
| `sui/`   | RETIRED (2026-10-12). Research only — do not extend.         | —    |
| `mock/`  | mock of the svg runner, for driving studio with no pipeline  | 8790 |

Each component keeps its own `README.md`, `CONTEXT.md`, `LICENSE`, `NOTICE` and
`docs/`, which travelled with the subtree import and are authoritative for that
component. `docker-compose.yml` at the root runs the lot; read its header before
changing how services are wired.

## Hard rules (every component, no exceptions)

1. **The seam is one-way.** The pipeline never calls back into the app. Data
   flows app → runner → pipeline; a runner that needs something from the app
   gets it in the request.
2. **Stdlib first.** A dependency has to earn its place. The services are
   stdlib Python on purpose; the heavy stacks (torch, Blender, Clipper) are
   mounted or baked at the edge, never pulled in for convenience.
3. **Live deploy is done.** A change that is not running is not finished. The
   stack under `docker-compose.yml` is the deployment.
4. **Host facts are not code.** No hostname, private IP, VPN name, machine
   nickname, or absolute host path in a tracked file. Configuration goes in the
   untracked `docker-compose.override.yml` or an env file, and a service that
   lacks a key says so (503 with its reason) rather than pretending.
5. **Edit the contract with the tests.** If a component's `docs/contract.md`
   changes, the tests that pin it change in the same commit.
6. **English only.** Every file, comment, doc, string and commit message is
   English — no CJK characters. A parser that genuinely needs them writes
   `\uXXXX` escapes, never the literal.
7. **Address services by NAME.** Inside the compose network a caller says
   `http://bp:8796`, never `127.0.0.1:8796` and never a docker bridge address.
   The loopback publishes exist for the host's convenience, not for callers.

Per-component detail: `<component>/AGENTS.md`, `docs/agents/standards.md`, and
`docs/contract.md`.

## Working here

- **One stack, one command.** `docker compose up -d --build`, adding
  `--profile mock`, `--profile decision` or `--profile flux` as needed. Every
  service is reachable by name from every other. Verify at the HTTP surface:
  `curl 127.0.0.1:3001/up`, `:8787/health`, `:8796/health`, `:8790/health`.
- **The pipeline is a tool, not a service.** `docker compose --profile tool run
  --rm pipeline ./pipeline.sh 00_source/art.svg`.
- **Issues are GitHub issues** on `geeeze/chopshop`, driven with `gh`. File
  against the component the change lands in and name the subdirectory.
- **`svg/` is Apache-2.0 and was a public repo.** `sui/` is retired: read it,
  never extend it, and do not lift its SwarmUI assumptions into `flux/`.
- **Do not re-house a component.** Each component's top level is a contract:
  the compose file, the docs and every other component name those paths, and a
  `git mv` of one moves all of them. Move files within a component freely.
  (The components' history is not here — it is in the frozen repositories named
  in `NOTICE` — so `git log --follow` has nothing to follow in this tree.)

