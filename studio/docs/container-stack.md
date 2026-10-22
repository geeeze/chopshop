# The chopshop container stack

How the chopshop services are assembled as containers locally, and how that maps
onto the live deployment. Operator doc: commands and wiring, no prose.

**Rule (whole stack):** every service runs as a container built from its own
repo's `Dockerfile`, never as a bare Python process. Configuration is env-only
(env files / compose `environment`), never hardcoded addresses or tokens.

## Service inventory

| service | repo | port (host) | image | role |
|---|---|---|---|---|
| studio | chopshop-studio | 3001 (loopback; host nginx proxies) | `chopshop-studio:0.1.0` | Rails app: jobs, projects, operators |
| bp | chopshop-bp | 8796 (loopback) | `chopshop-bp:0.1.0` | blend + plot (blender renders) |
| runner | chopshop-svg | 8787 | `chopshop-svg:0.1.0` | trace/validate pipeline runner |
| flux | chopshop-flux | 8795 (loopback default) | `chopshop-flux:0.1.0` | image generation (GPU) |
| laya | chopshop-jev `deploy/laya/` | 8797 (loopback default) | `chopshop-laya:0.1.0` | local decision service (SystemOne wire, `POST /v1/systemone`) |

chopshop-sui (retired) and chopshop-jevrouter (router library) have no
container story; none is planned. chopshop-plot is the plot package inside
chopshop-bp — the repo was renamed chopshop-plot → chopshop-bp, and no separate
chopshop-plot repo or clone remains.

## Topology: local vs live

- **Live (SPLIT install):** the studio runs on the VPS behind Cloudflare + nginx
  (`https://chopshop.geenet.work`); nginx proxies to `127.0.0.1:3001`. The
  GPU-backed services (flux) run on a second box reached over the tailnet.
- **Local:** everything on one box with rootless podman + podman-compose
  (docker compose works too; compose files are engine-agnostic). Same ports,
  same images, same env contract — only the untracked overrides differ.

## The compose convention (every repo)

Each repo ships a tracked `docker-compose.yml` (+ `Dockerfile`) that is safe for
a public repo: `${VAR:-default}` placeholders only, loopback-only publishes,
`restart: unless-stopped`. Host facts live in the untracked
`docker-compose.override.yml` (gitignored) or the `~/.config/chopshop-*.env`
files — never in tracked files.

**Bind rule (why containers differ from the native units):** inside a container,
services bind `0.0.0.0`; exposure is decided at the publish layer. The native
systemd units bound a literal tailnet IP and crash-looped with
`OSError: [Errno 99] Cannot assign requested address` whenever the tailnet
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
| flux | `CHOPSHOP_FLUX_TOKEN` | optional bearer (tailnet hardening) |
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

## State of this stack (2026-10-20)

flux and laya containers are **built and verified, not activated** — GPU compute
access needs a first real generation to prove out, and activation is an explicit
operator step. Everything else here describes the intended steady state.
