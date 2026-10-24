# chopshop

One repository for the app and its sidecars: a Rails studio, the vector
pipeline it drives, and the services that generate, render and draw alongside
it. Apache-2.0.

This is a personal playground — a place to learn how these pieces fit together
and to play with the creative possibilities of each. It is multifaceted on
purpose: the core loop traces a raster into vector candidates, but the sidecars
generate images, render in 3D, and draw documents. A human chooses from the
candidates and the metrics; the pipeline presents options and proves the pick
rather than picking for you. Everything else in here exists to serve or extend
that loop: the studio is where the human works, the runner executes, the
sidecars generate and draw.

## Components

Each component is a subdirectory with its own `README.md`, `CONTEXT.md`,
`docs/`, `LICENSE` and `NOTICE`. Each used to be its own repository; those six
repositories are frozen and named in [`NOTICE`](NOTICE), and they hold the
per-component history. **This repository starts at one commit** — it is the
publication tree, not the archaeology, so `git log` here says nothing about a
file's earlier life.

| dir | what it is | port | state |
|---|---|---|---|
| [`studio/`](studio/README.md) | Rails 8 app — the operator's surface, the only orchestrator | 3001 | active, private |
| [`svg/`](svg/README.md) | the trace + validate pipeline, and its HTTP **runner** | 8787 | active, Apache-2.0, was public |
| [`bp/`](bp/README.md) | blend + plot: Blender renders, geometry, digests, chart SVGs | 8796 | active |
| [`flux/`](flux/README.md) | generation service; needs a GPU, so it runs behind a profile | 8795 | active |
| [`jev/`](jev/README.md) | decision annotator + gateway + the local laya model (advisory) | 8799 | active, optional |
| [`jev/deploy/caption/`](jev/deploy/caption/Dockerfile) | image → text, so Jev's `image_visible` evidence can exist (profile `caption`) | 8798 | active, needs ~2.5 GB RAM |
| [`sui/`](sui/README.md) | SwarmUI/ComfyUI bridge, replaced by `flux/` | — | **retired** — read, never extend |
| [`mock/`](mock/README.md) | mock of the svg runner, for driving the studio with no pipeline | 8790 | test aid |

The data flow, in one line: `studio → runner → pipeline`, with `bp`, `flux` and
`jev` as capabilities the studio calls. **The seam is one-way** — no component
calls back into the app. `studio/docs/SYSTEM.md` is the map of the whole thing;
this file is only the front door.

## Run it

```sh
cp .env.example .env          # addresses only; empty is a valid state
docker compose up -d --build  # studio + runner + bp
```

Every service is reachable by NAME inside the compose network (`http://bp:8796`),
never by host address; the loopback publishes are for the host's convenience.
Profiles add the services that are not always wanted:

```sh
docker compose --profile mock up -d        # + the deterministic mock runner
docker compose --profile decision up -d    # + laya + the Jev gateway
docker compose --profile caption up -d     # + the captioner (needs a key + RAM)
docker compose --profile flux up -d        # + the generator (needs a GPU)
docker compose --profile tool run --rm pipeline ./pipeline.sh 00_source/art.svg
```

Verify at the HTTP surface:

```sh
curl -s -o /dev/null -w '%{http_code}\n' 127.0.0.1:3001/up      # 200
curl -s 127.0.0.1:8787/health; curl -s 127.0.0.1:8796/health
```

Host facts are configuration, not code. Paths, keys and addresses live in the
untracked `docker-compose.override.yml` and `.env`; a tracked file never carries
a hostname or a private address.

## Test it

Each component owns its suite; there is no cross-repo test runner.

| dir | command |
|---|---|
| `studio/` | `bin/rails test` (needs `vendor/bundle`; Rails + minitest) |
| `svg/` | `.venv/bin/python -m pytest tests/` (or a bare `pytest` in `svg/`) |
| `bp/` | `python3 -m unittest discover -s tests -v` |
| `flux/` | `python -m pytest` (no GPU, no torch, no models, no network) |
| `jev/` | `python3 -m pytest tests/` (the `justfile`'s `just test` runs the same) |
| `sui/` | `python3 -m pytest tests/` |

## Read next

| document | what it covers |
|---|---|
| [`AGENTS.md`](AGENTS.md) | the hard rules for working in this repo — read before editing anything |
| [`studio/docs/README.md`](studio/docs/README.md) | the documentation index: orient yourself from here |
| [`studio/docs/SYSTEM.md`](studio/docs/SYSTEM.md) | the components, the data flow, the one-way seams |
| [`studio/docs/SURFACES.md`](studio/docs/SURFACES.md) | every invocable surface — routes, CLIs, contracts — in one registry |
| [`studio/docs/agent-api.md`](studio/docs/agent-api.md) | the HTTP driver contract for scripting the studio |
| [`studio/docs/runner-contract.md`](studio/docs/runner-contract.md) | the studio ↔ runner contract, in full |
| [`svg/docs/OVERVIEW.md`](svg/docs/OVERVIEW.md) | the pipeline's design: front half, back half, the print gates |
| [`svg/docs/HOWTO-print-check.md`](svg/docs/HOWTO-print-check.md) | the print check, step by step |
| [`bp/docs/contract.md`](bp/docs/contract.md) | the blend-plot JSON contract |
| [`flux/docs/API.md`](flux/docs/API.md) · [`flux/docs/MODELS.md`](flux/docs/MODELS.md) | the generation API, and the model registry with licences |
| [`jev/docs/decision-core.md`](jev/docs/decision-core.md) · [`jev/docs/remediation-loop.md`](jev/docs/remediation-loop.md) | what Jev asks, and how answers drive remediation |
| [`sui/docs/`](sui/docs/) | the retired bridge's research: workflow candidates, model notes |

Component `CONTEXT.md` files hold work in progress, blockers and caveats —
`studio/CONTEXT.md`, `svg/CONTEXT.md`, `bp/CONTEXT.md`, `flux/CONTEXT.md`,
`jev/CONTEXT.md`, `sui/CONTEXT.md`.

## Issues

Issues live on **`geeeze/chopshop`**, driven with `gh`. File against the
component the change lands in and name the subdirectory in the body; the five
triage labels are listed in [`.github/ISSUES.md`](.github/ISSUES.md), which also
carries the map from the old issue numbers.

The six per-component repositories (`chopshop-studio`, `-svg`, `-bp`, `-flux`,
`-jev`, `-sui`) are **frozen**: history and attribution only, no new commits, no
new issues. Their open issues were transferred here on 2026-10-22.

## Licence

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). Every
component keeps the `LICENSE`/`NOTICE` that travelled with its subtree import;
the root pair is the consolidated notice for the combined work. Third-party
tools (Blender, VTracer, PyTorch, Rails and others) are called as dependencies
under their own licences; no dependency source is redistributed here.
