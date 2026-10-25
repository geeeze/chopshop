# The chopshop container stack

How the chopshop services are assembled as containers locally, and how that maps
onto the live deployment. Operator doc: commands and wiring, no prose.

**Rule (whole stack):** every service runs as a container built from its own
repo's `Dockerfile`, never as a bare Python process. Configuration is env-only
(env files / compose `environment`), never hardcoded addresses or tokens.

## Service inventory

| service | repo | port (host) | image | role |
|---|---|---|---|---|
| studio | chopshop-studio | 3001 (loopback; host nginx proxies) | `chopshop-app` (built from `Dockerfile.dev`) | Rails app: jobs, projects, operators |
| bp | chopshop-bp | 8796 (loopback) | `chopshop-bp:0.1.0` | blend + plot (blender renders) |
| runner | chopshop-svg | 8787 | `chopshop-svg:0.1.0` | trace/validate pipeline runner |
| flux | chopshop-flux | 8795 (loopback default) | `chopshop-flux:0.1.0` | image generation (GPU) |
| laya | chopshop-jev `deploy/laya/` | 8797 (loopback default) | `chopshop-laya:0.1.0` | local decision service (SystemOne wire, `POST /v1/systemone`) |

chopshop-sui (retired) and chopshop-jevrouter (router library) have no
container story; none is planned. chopshop-plot is the plot package inside
chopshop-bp — the repo was renamed chopshop-plot → chopshop-bp, and no separate
chopshop-plot repo or clone remains.

## Topology: local vs live

- **Live (SPLIT install):** the studio runs on the VPS behind Cloudflare + nginx;
  nginx proxies to `127.0.0.1:3001`. The GPU-backed services (flux) run on a
  second box reached over a private network. The names and addresses of both
  live in the deployment's env files, never here.
- **Local:** everything on one box with rootless podman + podman-compose
  (docker compose works too; compose files are engine-agnostic). Same ports,
  same images, same env contract — only the untracked overrides differ.

## The compose convention (every component)

The root `docker-compose.yml` is the canonical stack — it builds every component
and wires them on one network. Each component also keeps the tracked
`docker-compose.yml` (+ `Dockerfile`) that travelled with its subtree import and
still runs that service alone; those files are safe for
a public repo: `${VAR:-default}` placeholders only, loopback-only publishes,
`restart: unless-stopped`. Host facts live in the untracked
`docker-compose.override.yml` (gitignored) or the `~/.config/chopshop-*.env`
files — never in tracked files.

**Bind rule (why containers differ from the native units):** inside a container,
services bind `0.0.0.0`; exposure is decided at the publish layer. The native
systemd units bound a literal private-network IP and crash-looped with
`OSError: [Errno 99] Cannot assign requested address` whenever that
address was not up yet — a container netns does not even hold that address, so a
literal bind there can never work. For a native unit on the host, "bind a real
IP" remains valid; for containers it is always `0.0.0.0` + publish.

## Build / verify (per repo)

```sh
cd ~/Documents/GitHub/<repo>
podman-compose build          # or: docker compose build
podman-compose config         # renders the effective file — must be clean
```

Service-specific smoke checks (build-time; do not `up` unattended):

```sh
podman run --rm chopshop-flux:0.1.0 python3 -m chopshop_flux --help
podman run --rm --entrypoint sh chopshop-laya:0.1.0 -c "python3 -c 'import laya.serve'"
#   NOT `laya-serve --help`: it ignores --help and boots the server instead.
curl 127.0.0.1:3001/up        # studio, only when the stack is up
```

## Assembly order (full local stack)

1. `chopshop-bp` — `podman-compose up -d` → `curl 127.0.0.1:8796/health`
2. `chopshop-svg` — the runner (`runner.py`, port 8787)
3. `chopshop-flux` — generation (GPU; see below)
4. `chopshop-jev/deploy/laya` (merged; main now carries container) — decisions (CPU)
5. `chopshop-studio` — the app; needs the others' URLs via the override

## Cross-service env wiring (override files)

The wiring between services is configuration, so it lives in the untracked
override per repo (placeholders — fill locally, never commit):

| consumer | variable | points at |
|---|---|---|
| studio | `CHOPSHOP_FLUX_URL` | flux base URL (local: `http://127.0.0.1:8795`) |
| studio | `CHOPSHOP_FLUX_REPO` / `CHOPSHOP_FLUX_REPO_HOST` | flux checkout (read-only mount, parity suite) |
| svg runner | `JEV_ANNOTATOR` | annotator script mount (`chopshop-jev` checkout) |
| svg runner | `JEV_API_KEY` | operator key (same key the client sends to laya) |
| laya | `LAYA_API_KEY` | bearer for `POST /v1/systemone` |
| flux | `CHOPSHOP_FLUX_TOKEN` | optional bearer (private-network hardening) |
| flux | `CHOPSHOP_FLUX_NOVITA_API_KEY` | remote backend key (read at call time) |

Tokens are read at call time from env — never baked into an image, never printed.
Per-host env files: `~/.config/chopshop-flux.env`, `~/.config/chopshop-laya.env`
(systemd EnvironmentFile format; the compose equivalents are the `.env` /
override files).

## GPU caveat (flux)

flux generates on AMD ROCm. For the container:

- devices: `--device /dev/kfd --device /dev/dri` (in the override; rootless
  podman passes them through when the user is in `video` and `render` groups)
- the ROCm userspace in the container must match the host driver; the shipped
  image is torch-free (stdlib service code) and takes the GPU runtime from a
  bind-mounted venv (`/gpu-venv`, path supplied in the untracked override;
  `CHOPSHOP_FLUX_PYTHON=/gpu-venv/bin/python` names the interpreter) or a
  per-host extension layer
- GPU guard: `CHOPSHOP_FLUX_GUARD=wait`, `_GUARD_VRAM_GB`, `_GUARD_WAIT` —
  configure before the first generation (the card is shared with LM Studio)
- idle memory: `CHOPSHOP_FLUX_IDLE_UNLOAD` + `CHOPSHOP_FLUX_IDLE_EXIT` — an
  unload leaves ~16 GB resident until the process exits; do not run without them
  on a shared box

## State of this stack

flux, laya and the studio are **running** as containers on the dev box. flux
(:8795) and laya (:8797) are published on loopback + the tailnet address; laya
is quadlet-managed (`~/.config/containers/systemd/chopshop-laya.container`), so
it starts at boot without compose. The studio (:3001) runs from
`Dockerfile.dev` built as `chopshop-app`, started by the `podman run` in
`chopshop-studio/README.md` with `--env-file .env`.

A container cannot reach another container's loopback publish through
`host.containers.internal` (169.254.1.2) — measured: refused on a
`-p 127.0.0.1:<port>` publish while the tailnet address answered 200. Point
`CHOPSHOP_RUNNER_*_URL` at the published tailnet/LAN address, or at the compose
service name when both are on the compose network.

The pipeline runner (:8787) and bp (:8796) are not started on this box today, so
the studio's dropdown shows them DOWN. That is a true reading, not a bug.
