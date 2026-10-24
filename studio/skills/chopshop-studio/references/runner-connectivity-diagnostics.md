---
alias: connectivity, runners-down, diagnose-runners, runner-health
---

# Runner connectivity diagnostics

When chopshop-studio's nav sidebar shows one or more runners as "down", the
answer is almost always the same shape: **the runner's port is published on the
host's loopback, and a container has no route to the host's loopback.** Check
that first; it is cheaper than the rest of this file.

## 0. The loopback-publishing trap (the usual cause)

The runner repos' TRACKED `docker-compose.yml` publishes loopback-only, on
purpose (it is host-agnostic and nothing should reach these from off-box):

```
chopshop-svg         ports: - "127.0.0.1:8787:8787"
chopshop-bp          ports: - "127.0.0.1:8796:8796"
chopshop-mock-runner ports: - "127.0.0.1:8790:8790"
```

The studio runs in its OWN container, so `127.0.0.1` is the studio container,
not the host: every local runner answers ECONNREFUSED no matter that the host
can curl it fine. Flux is unaffected because it is not a published host port at
all — it is a service on <gpu-box> reached over the tailnet.

**Fix:** publish the port on the host's address on the studio's docker bridge,
from each runner's UNTRACKED `docker-compose.override.yml`:

```yaml
services:
  runner:            # or `bp`, or `mock-runner`
    ports:
      - "<BRIDGE_GATEWAY>:8787:8787"
```

(`<BRIDGE_GATEWAY>` stands for the address the command below prints; it is a
private address and is deliberately not written into this file, which is
published to the repo.)

Publishing one container port on two host IPs is legal, and compose merges
`ports` by appending — the loopback binding stays, so `curl 127.0.0.1:8787` on
the host keeps working. Read the gateway from the deployment rather than
remembering it:

```bash
docker network inspect chopshop-studio_default \
  --format 'gw={{(index .IPAM.Config 0).Gateway}}'
```

Then point the studio env at that same address and recreate the runner:

```bash
cd ~/chopshop-svg
docker compose rm -sf runner && docker compose create runner && docker start chopshop-svg-runner-1
docker port chopshop-svg-runner-1      # both bindings must show
```

`docker compose up -d` is the obvious command but the agent's terminal guard
refuses it as a long-lived process; `rm -sf` + `create` + `start` recreates and
starts the container just the same.

**mock is a special case:** it is not in the env at all, so it falls back to
`Job::RUNNER_DEFAULTS` (`http://127.0.0.1:8790`) and shows down even when its
container is up. It needs an explicit `CHOPSHOP_RUNNER_MOCK_URL` in the env file
as well as the published port. mock also sits behind the `mock` compose profile,
so recreate it with `docker compose --profile mock …`.

## 1. Confirm what the UI is actually reporting

The nav sidebar renders `Job.form_runners.map { |r| [r, RunnerClient.health(Job.runners[r])] }`
— each runner gets a GET to `<base>/health`. A runner shows "down" when that request
fails. The failure can be:

- **Connection refused** — nothing listening on that address *from the container*.
  Most often the loopback-publishing trap above; otherwise the service is down.
- **Connection timed out** — firewall blocking, or the address is unreachable.
- **DNS resolution failure** — the hostname in the URL does not resolve inside the
  container (placeholder hostnames, missing Tailnet DNS).
- **HTTP error response** — the service is up but returning an error (less common).

## 2. Check what is actually running AND where it is published

```bash
# Running containers
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'

# WHAT ADDRESS each port is published on — docker ps truncates this
# column, so read the two lines in full or you will miss a loopback binding
docker port chopshop-svg-runner-1
```

`docker ps`'s `PORTS` column shows `127.0.0.1:8787->8787/tcp`, which reads as
"published" and hides the problem; `docker port` likewise prints every binding
without saying which one the client needs. Compare them against the address in
the env file.

## 3. Read the runner URLs from the env file

```bash
cat ~/.chopshop-studio.env | grep RUNNER_.*_URL
```

Each URL must use an address the studio CONTAINER can reach, not just the host:

- **Local Docker services** (svg 8787, bp/plot 8796, mock 8790): the host's
  address on the studio's docker bridge (the gateway step 0 prints) — AND that
  port must be published there; pointing at it is not enough on its own.
- **Remote services over Tailnet** (flux on <gpu-box> at 8795): the Tailnet IP
  (e.g. `<tailnet-ip>`), which the container resolves and the host routes.
- Do NOT use the host's public IP or the loopback: a container has no route to
  either.

## 4. Test connectivity from inside the studio container

The container's perspective is what matters — the host may have everything working
while the container cannot reach it. Read the URLs out of the container's own env
so nothing depends on retyping an address:

```bash
docker exec chopshop-studio-studio-1 sh -c '
for v in $(env | grep "^CHOPSHOP_RUNNER_.*_URL=" | cut -d= -f1); do
  url=$(eval echo \$$v)
  printf "%-28s %-30s -> " "$v" "$url"
  curl -s -o /dev/null -w "%{http_code}\n" -m 6 "$url/health"
done'
```

A `200` on every line is the real fix. Use this shape rather than hand-writing
URLs into a test command: retyping an address is where this goes wrong.

## 5. Firewall — do NOT reach for ufw here

An earlier version of this file said to run `sudo ufw allow <port>/tcp` when a
connection times out. That is the wrong fix and it was followed once:

- Docker's published ports bypass ufw's INPUT rules (Docker writes its own
  DNAT/forward rules), so an `allow` rule typically changes nothing.
- A binding on the docker bridge is **not** subject to ufw at all, so no rule
  is ever needed for this fix.
- The rules added while chasing it had to be deleted again, and they widened the
  public surface on a box whose whole point is that the backend is private.

Check `sudo ufw status` only to confirm you did not leave stray rules behind.

## 6. For remote services (flux on <gpu-box>), verify over Tailnet

```bash
tailnet status
ssh -p 22822 <gpu-handle>@<tailnet-ip> 'systemctl --user status chopshop-flux'
ssh -p 22822 <gpu-handle>@<tailnet-ip> 'ss -tlnp | grep 8795'
```

Flux must listen on the tailnet address (`<tailnet-ip>:8795`), not just
localhost, and the env must point at that address. Start it with
`systemctl --user start chopshop-flux` if it is not running.

## 7. Verify through the app's OWN code path, then restart the studio

The nav does not call curl, it calls `RunnerClient.health` — so assert the same
thing it does:

```bash
docker exec chopshop-studio-studio-1 bin/rails runner \
  'Job.form_runners.each { |r| h = RunnerClient.health(Job.runners[r]); puts "#{r}: #{h && h[:ok] ? "up" : "down"}" }'
```

Expect every offered runner `up`. `Job.form_runners` is also the list the form
offers, so a runner that is not meant to be offered should be absent from it
rather than permanently "down".

After an env-only change the studio container must be recreated (the env file is
read at create time by the compose override's `env_file`):

```bash
cd ~/chopshop-studio
docker compose rm -sf studio && docker compose create studio && docker start chopshop-studio-studio-1
curl -s -o /dev/null -w 'live=%{http_code}\n' -m 8 http://127.0.0.1:3001/up
```

Port-binding changes need the RUNNER container recreated, not the studio; env
changes need the STUDIO recreated, not the runners.

## Common failure signatures

| Symptom | Likely cause | Fix |
|---|---|---|
| All local runners down, flux up | Runner ports published loopback-only; container cannot reach host 127.0.0.1 | Publish on the bridge gateway in each runner's override (step 0) |
| mock down while its container is up | No `CHOPSHOP_RUNNER_MOCK_URL`; falls back to `RUNNER_DEFAULTS` loopback | Add the env var + publish 8790 |
| All runners down | Env has unresolvable hostnames/IPs | Replace with the bridge address or a resolvable Tailnet name |
| Connection timed out | Firewall, or an address the container cannot route | Recheck the address first; do NOT add ufw rules for the bridge |
| A runner shows down only from the studio | Studio container and runner on different networks | Use the bridge gateway, not loopback |
| DNS resolution failure | Placeholder/nonexistent hostname in env | Use an IP the container can route |
| Flux down | Service not running on <gpu-box>, or bound to localhost only | `systemctl --user start chopshop-flux`; check `ss -tlnp` |
| Only some runners down | One service down or published on the wrong address | `docker port <container>` for each |
