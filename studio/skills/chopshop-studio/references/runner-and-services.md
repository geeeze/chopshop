> HOST-SPECIFIC — `127.0.0.1:8787`, the mock-runner two-path drift,
> `~/chopshop-svg/runner.py` and the fleet venv paths are THIS box.
> The mock-vs-real rule and the manifest/servability reasoning are
> generic.

# Runner and service traps

> Moved out of `SKILL.md` so the always-on file stays a short router; the rules are unchanged.
>
> Complements `runner-deploy.md`, `runner-job-dirs.md`, `orphan-sweep.md` and
> `jev-runner.md`.

- A manifest's absolute `artifacts` paths are NOT evidence the artifact is servable. The studio
  fetches a BASENAME (`m["proof"]`) resolved inside the job dir, so an `/app/.preflight-work/...`
  path that no longer exists says nothing about the proof; fetch
  `http://127.0.0.1:8787/files/<job_id>/<basename>` and check the status. Relatedly, two
  candidates producing byte-identical proofs is correct when their SVGs hash the same — a sweep
  can emit duplicates, so hash the inputs before reporting a proof bug.
- The mock runner has TWO paths: the repo-tracked copy is `mock-runner/runner.py` inside `~/chopshop-studio`, but the launcher (`start-chopshop-stack.sh`) runs `~/chopshop-mock-runner/runner.py`. They drift in BOTH directions and **the live copy is not necessarily the newer one** — it once sat a commit behind the repo copy, so `cp live → repo` silently reverted committed behaviour (the off-loopback `MOCK_BIND` bind). So: `diff` the two FIRST, decide which side is correct from `git log` / `git diff <file>`, copy in THAT direction, re-`diff`, and restart the runner. Editing one and blindly copying it over the other is how a committed fix disappears, and a stale live copy means the running service may not be the code you just read.
- The mock runner and the REAL runner are INDEPENDENT implementations of the same contract (mock: the two paths above; real: `~/chopshop-svg/runner.py`, baked into the docker image). A route existing in one says nothing about the other, and "we tested it before" almost always means the mock — which implements routes the real runner never got, needs no credentials, and answers instantly. When a studio feature 404s, POST the route straight at the runner first (`curl -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:8787/<route>`; `{"error":"unknown route"}` = the route does not exist there). That 404 is the runner's routing, not the studio's wiring, and chasing the Rails side first wastes the whole session.
- **A service that 404s a route may simply be behind its own origin — `git pull --ff-only` and restart BEFORE rewriting the caller.** Drift is expected: a route can exist on origin/main while the running service predates the commit that added it (the plot service 404'd `/log` until `chopshop-plot` was pulled to the commit adding `tree`/`log`, and the studio-side code was already correct). Check the running service's advertised operations (`GET /health`) and its git HEAD against origin before treating the 404 as a caller bug.
- **A host `python3` minor upgrade silently breaks every repo `.venv` in the fleet** (`chopshop-svg`, `chopshop-flux`, `chopshop-jev`): the venv's `bin/python3` symlinks to `/usr/bin/python3`, which now resolves to the new interpreter while site-packages sit under the old `lib/pythonX.Y` — imports fail with a bare `ModuleNotFoundError` and `.venv/bin/python -V` disagrees with `pyvenv.cfg`. Diagnose with `readlink -f .venv/bin/python3` + `ls .venv/lib/`; fix by rebuilding (`python3 -m venv .venv && .venv/bin/pip install -r requirements.txt` — install `python3.X-venv` first if ensurepip is missing). Check whether every pinned wheel still supports the new minor before trusting the rebuild.
