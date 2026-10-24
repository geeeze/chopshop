# chopshop-mock-runner

A containerised **mock** of the `chopshop-svg` runner: same HTTP contract
(`/health`, `/jobs`, `/validations`), so the studio can be driven without the real
pipeline. It listens on `127.0.0.1:8790`; the real svg runner is on `8787`.

It is a separate image on purpose. A mock that shipped *inside* the svg image
could not mock the svg image.

## Run it

```bash
cd mock           # from this repo's root
docker compose --profile mock up -d      # start
docker compose --profile mock logs -f    # follow
docker compose --profile mock down       # stop, hand 8790 back
```

The service sits behind a `profiles:` key, so a bare `docker compose up -d`
starts **nothing**. That is deliberate: the studio points at 8787 for the real
runner and 8790 for this one, and quietly running the mock when you meant the
real thing is the exact confusion worth preventing.

`restart: unless-stopped` plus docker being enabled at boot means it comes back
on its own after a reboot.

## Editing runner.py — read this

**`runner.py` is COPYied into the image, not bind-mounted** (the same choice
`chopshop-svg` makes). So editing it on the host changes nothing until you
rebuild:

```bash
docker compose --profile mock build && docker compose --profile mock up -d
```

This is a deliberate trade: the container always runs the code that was built,
never a half-edited working tree.

## What was fixed here, and why it matters

The runner used to run from a host venv at
`~/chopshop-studio-runner-venv`, whose `bin/python` symlinks to
`/usr/bin/python3`. When the system Python moved 3.12.3 → 3.14.4 the venv
followed it, stopped finding its own `lib/python3.12/site-packages`, and lost
Pillow without a word — putting the service into a 799-restart loop while
systemd reported only `status=1/FAILURE`.

The interpreter and its packages now live **in the image**, so the host's Python
is irrelevant to this service. `requirements.txt` pins `pillow==12.3.0`, and the
Dockerfile proves the import at **build** time, so a broken dependency is a failed
build rather than a silent runtime crash loop.

## Layout

| path | what |
|---|---|
| `runner.py` | the service (host source of truth; rebuild after editing) |
| `requirements.txt` | pinned deps — the file whose absence caused the outage |
| `Dockerfile` | `python:3.14-slim` + Pillow + a build-time import check |
| `docker-compose.yml` | profile-gated service, loopback-only publish |
| `${MOCK_ARTIFACTS_DIR:-./data/mock-artifacts}` | persistent job artifacts (bind-mounted at `/tmp/chopshop-mock`) |

Artifacts used to land in `/tmp/chopshop-mock`, which a reboot empties. They now
persist in `./data/mock-artifacts` (override with `MOCK_ARTIFACTS_DIR`).

`MOCK_BIND` is set to `0.0.0.0` **inside the container** only. The runner
defaults to `127.0.0.1`, which is correct on a host but unreachable in a
container: docker publishes to the container's eth0, so a loopback-bound
listener accepts the connection and resets it. The service is still loopback-only
as seen from the host, because the published port binds `127.0.0.1`.

## Reverting to the host venv

The unit was disabled, not deleted, so this is one command:

```bash
systemctl --user enable --now chopshop-mock-runner
```

The venv is still on disk at `chopshop-studio-runner-venv` (and the old dead
3.12 one at `chopshop-studio-runner-venv.py312-dead`, safe to delete).
