# Serving one box's GPU to another machine

The service runs where the card is. Everything else — the studio, the trace
pipeline, a VPS — talks to it over a private network and needs no GPU of its own:

```
[ GPU box: flux, published on the private address ] <--private network--> [ caller ]
```

This is the *optional* half of the deployment story, and it is deliberately
separate from `docs/gpu-runtime.md`. That page is about getting the card into the
container at all (NVIDIA or ROCm); this one is about letting a second machine
reach the result, and it applies to either vendor unchanged.

**The default install is loopback-only, and that is not a limitation to work
around.** Everything below is a deliberate act, and the acts are additive: base
compose → one vendor overlay (`docker-compose.nvidia.yml` for NVIDIA,
`docker-compose.rocm.yml` for AMD) → the untracked override.

## Exposure is the PUBLISH layer, not the bind

Two different things are called "listening", and confusing them is where the
first hour goes:

| layer | where it lives | what it decides |
|---|---|---|
| the service's bind | `CHOPSHOP_FLUX_BIND` | which address **inside** the container's network namespace the process listens on |
| the publish | `ports:` in compose | which host address is forwarded to it |

The base file already sets the in-container bind to `0.0.0.0` and publishes on
**`127.0.0.1`** only. Do not "fix" the bind to a host address: a literal host or
private-network IP **cannot** bind inside a container netns, and the failure is a
crash loop ending in

```
OSError: [Errno 99] Cannot assign requested address
```

To serve another machine, change the **left side of the publish line** in the
untracked `docker-compose.override.yml` (`docker-compose.override.yml.example`
has the stanza):

```yaml
services:
  flux:
    ports:
      - "${PRIVATE_ADDRESS}:8795:8795"   # the address on the private interface
```

Publishing on `0.0.0.0` also works and is simpler, but then the exposure control
is a host firewall rule rather than the bind — see "The firewall may not be the
control you think" below before choosing that.

The right side stays `8795` inside the container. The port is not configurable per
side; `CHOPSHOP_FLUX_PORT` moves both.

## Set a token BEFORE the bind leaves loopback

An unauthenticated generation endpoint on a shared network is somebody else's free
GPU, so `CHOPSHOP_FLUX_TOKEN` is part of the change, not a follow-up:

```bash
openssl rand -hex 32        # generate one; put it in the env file, never in a tracked file
```

```yaml
# docker-compose.override.yml  (or an env_file)
services:
  flux:
    environment:
      CHOPSHOP_FLUX_TOKEN: "${CHOPSHOP_FLUX_TOKEN}"
```

What is and is not gated, measured against a running service:

| route | without the token | with it |
|---|---|---|
| `/health` | **200** — public route, by design | 200 |
| `/generate`, `/edit`, `/models`, `/files/<name>` | **401** `{"kind": "unauthorised"}` | 200 |

`/health` is deliberately public: *a health check that itself needs a secret
cannot be used to decide whether to send the secret*. It reports
`"auth_required": true`, which is how a caller knows a token is needed before
trying.

Two consequences that are easy to miss:

- **`/files/<name>` is a second endpoint, and it is gated too.** `/generate`
  answers with a *path*, and the bytes come from `GET /files/<name>`. A remote
  caller that only handles the generate response gets a valid JSON body and no
  image.
- **the caller needs the same token.** `chopshop-studio`'s `FluxClient` sends
  `Authorization: Bearer …` when `CHOPSHOP_FLUX_TOKEN` is set in its own
  environment, so a split install is one value in two env files. Set it in one
  place and it 401s its own GUI; that is the failure to expect, and it looks like
  a broken service rather than a missing key.

## Budget the cold load, not the request

A generation request **loads the model**, so the first one after a restart pays
for that:

```
MEASURED, weights on a network store, 512x512, 20 steps:
  cold load  69.9 s   |   frame  6.4 s   |   total  84.6 s
  warm                 |   frame  4.9 s
```

So a caller's read timeout has to cover **load + frames**, not the frames. A
naive 30–60 s timeout reads as a dead service on the first call of the day. The
studio's `FluxClient` uses a 300 s generate read timeout for exactly this reason;
anything you write against the API should do the same.

The load happens **once per process**, so the cost is amortised — but see the next
section, because the process may not still be there.

## The container may exit on purpose after going quiet

`CHOPSHOP_FLUX_IDLE_UNLOAD` frees the loaded model after N quiet seconds, and an
unload does not always return the host RAM it held. `CHOPSHOP_FLUX_IDLE_EXIT`
therefore lets the process *drain and exit* (exit code **1**) when the memory did
not come back — ending the process is what returns it. Off by default; it changes
the service's lifecycle, so a remote caller has to expect it.

**Do not assume a restart policy will bring it back.** `restart: unless-stopped`
is recorded on the container and enforced by the container runtime — and at least
one current rootless combination ignores it: MEASURED, a container created with
that policy exited and stayed exited, inside a compose project and outside one
alike. Verify with a kill, not with the compose file:

```bash
podman kill <container>                      # or: docker kill <container>
sleep 15; podman ps --format '{{.Names}}' | grep <container>    # did it return?
```

If it did not, the lifecycle needs a keeper — and the keeper must be **narrow**,
because restarting everything makes "stop it to free the card" impossible:

```bash
#!/usr/bin/env bash
# Restart the service after its OWN idle exit, and nothing else.
set -u
NAME=${1:?container name}
state=$(podman inspect -f '{{.State.Running}} {{.State.ExitCode}}' "$NAME" 2>/dev/null) || exit 0
[ "${state%% *}" = "true" ] && exit 0        # running: nothing to do
[ "${state##* }" = "1" ] || exit 0           # idle exit only
podman start "$NAME" >/dev/null 2>&1 || true
```

Why exit **1** only: that is the idle path's code. A `stop` records 143 and a
crash records its own code — an operator's decision, or a fault that deserves to
be seen rather than restarted into silence. Run the keeper on a timer shorter than
the caller's reconnect budget, and let it no-op when the service is up: the
client side already retries a refused connection
(`CHOPSHOP_FLUX_RECONNECT_ATTEMPTS` / `CHOPSHOP_FLUX_RECONNECT_BACKOFF`), so a gap
of a few seconds is covered without the caller noticing.

## The firewall may not be the control you think

If the host firewall filters the private interface, scope the rule to the
**caller** and the **port** — never to a whole address range, because every other
machine in that range then has an unauthenticated generation endpoint:

```bash
sudo firewall-cmd --permanent --zone=public \
  --add-rich-rule='rule family="ipv4" source address="<caller-address>" port port="8795" protocol="tcp" accept'
sudo firewall-cmd --reload
```

**But check the packet path before believing the rule is what protects you.** A
mesh-VPN agent commonly installs its own table and an `accept` for its whole
interface, jumped ahead of the host firewall's chain:

```bash
sudo nft list ruleset | grep -B2 -A8 'chain .*input'
# an `iifname "<iface>" ... accept` at the head of that chain means every peer on
# the network reaches the port, whatever the host firewall's zone says
```

If that is what you find, the host firewall rule still does real work for the
LAN interface and none at all for the private one. The controls that remain are
the **token** (this page) and the **network's own access control** (per-node
grants/ACLs on the VPN, which is where "only this caller" is actually expressed).
Do not add a rule to a chain the VPN agent rewrites on its next sync and call it
done — it disappears, silently, at some unrelated moment.

## Verify the seam at four levels

Host-side `curl` succeeding says nothing about what the caller can reach, so climb
the ladder instead of stopping at the first rung:

1. **The listener** — the publish actually happened:

   ```bash
   ss -ltn | grep 8795        # 0.0.0.0:8795 or <private>:8795, not 127.0.0.1 only
   ```

2. **The gate, from off-box** over the private address:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://<private-address>:8795/generate -X POST \
        -H 'Content-Type: application/json' -d '{"prompt":"x"}'      # 401
   curl -s http://<private-address>:8795/health | grep auth_required  # true
   ```

3. **A real generation with the token**, at a size the model can actually render
   (256 px proves the API, not the model), and then fetch the bytes back through
   `/files/<name>` — the route a caller usually forgets is gated.

4. **From the caller's own client**, not from the host. For the studio that is
   its own code, inside its own container:

   ```bash
   docker compose exec studio bin/rails runner \
     'puts FluxClient.health(ENV["CHOPSHOP_RUNNER_FLUX_URL"]).inspect'
   ```

   A response whose `device_name` and `torch` are null while the host's `/health`
   is populated means the caller is reaching a *different* service, or one whose
   engine has not loaded yet — not that the network is broken.

## Troubleshooting

| symptom | cause |
|---|---|
| `[Errno 99] Cannot assign requested address` in a restart loop | `CHOPSHOP_FLUX_BIND` was set to a host/private IP; a container netns cannot bind it — leave it `0.0.0.0` and move the publish line instead |
| connection refused from the caller, `200` on the host | published on loopback only; the publish left side is still `127.0.0.1` |
| `401` from the caller with the token set | the token differs between the two machines (or has whitespace/a trailing newline from the env file) |
| the generate body is fine and the image is empty | `/files/<name>` was not sent the token |
| first call of the day times out, later ones are fine | read timeout shorter than the cold load; see "Budget the cold load" |
| the service answers, then vanishes after a quiet period | `IDLE_EXIT` fired and nothing restarted it — see the keeper above |
| a host firewall rule appears to have no effect on the private address | the VPN agent's chain accepts the interface before the firewall sees the packet |
