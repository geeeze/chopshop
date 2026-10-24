# Deploying the real svg runner (:8787)

The runner the studio composes against (`chopshop-svg-runner-1`, image
`chopshop-svg:0.1.0`, `docker-compose.yml` at the chopshop-svg repo root) is
NOT a live checkout: `COPY . .` bakes the code into the image, and only DATA
dirs are bind-mounted (`09_filters/`, `01_prepped/`, uploads). Editing
`scripts/*.py` or `runner.py` in the checkout changes nothing inside the
container until the image is rebuilt or the file is patched in.

Find the container: `docker ps --format '{{.ID}} {{.Image}} {{.Names}}
{{.Ports}}' | grep chopshop-svg` — its own `/health` answer also reports the
container id as `host`.

## Clean deploy

1. **Suite first, on the host.** The Dockerfile's build RUNS THE SUITE as a
   gate, so a hanging or crashing suite blocks the image build outright — no
   partial image is produced. Measure the suite on the checkout before
   asking for a build, and attribute any failure first (stash, rerun the
   failing file, restore) so the gate is not being fed your in-flight diff.
2. `docker compose build` from the repo root, then `docker compose up -d`
   (recreates the container from the new image).
3. Verify: `curl -s http://127.0.0.1:8787/health` returns
   `{"ok": true, "host": "<container id>", ...}`, then the wire E2E below.

A build runs the full suite inside it — background it with a log redirect
and poll the log's tail; do not hold a foreground cell on it.

## Hot-patch when the build gate is blocked

The runner imports compose-side modules per-process from `/app/scripts` and
re-reads them on restart, so a script can ship without an image rebuild:

    docker cp scripts/<file> <container-id>:/app/scripts/<file>
    docker restart <container-id>

The container then DIVERGES from its image: any `docker compose up`
recreation from the old image loses the patch. State the divergence in the
report and let the next successful build re-converge — never quietly treat a
hot-patched container as deployed-from-image. A restart is also the only way
an in-process import change takes effect; a running process keeps its old
module.

## Wire E2E

The only check that proves the CONTAINER runs your code: POST the op
straight at the runner with curl and a minimal payload, and assert the
response shape —

- honour path: compose a spec that exercises the new behaviour and check the
  returned document's structure (the nested `<svg>` viewport markup a crop
  produces, for example);
- refusal path: the malformed variant must come back **422** with
  `{"error": ..., "kind": "invalid_spec"}` — never a painted approximation.

This same POST is how you separate runner routing from studio wiring when a
studio feature misbehaves: a 404 here is the runner's routes, and only a 200
here sends you looking at the Rails side.
