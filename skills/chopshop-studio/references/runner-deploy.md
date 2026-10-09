> HOST-SPECIFIC — the docker container on `127.0.0.1:8787`, the
> `chopshop-svg:0.1.0` image name, reference timings, disk-reclaim
> numbers, and the mock-runner two-path drift are THIS deployment.
> The runner contract itself is host-agnostic in the public repo.

## Local real runner (docker, `:8787`) and shared-path gate

The pipeline image and the studio HTTP runner are separate deliverables.

- A built `chopshop-svg` image or successful `docker compose run` proves only the pipeline. It does not prove an HTTP runner is listening on `127.0.0.1:8787`.
- Runners are configured by env, not hardcoded: `CHOPSHOP_RUNNER_<LABEL>_URL` (label = env name stripped and lower-cased) merged over a mock-only default in `Job::RUNNERS`. On this box the real runner is the docker container on `127.0.0.1:8787`; the dropdown label is whatever env var defines it — do not assume a literal `svg` label. Call a runner operational only after its URL serves the runner contract. The new-job form must NOT hardcode `runner: "mock"`: it defaults to the first non-mock runner when one is configured (`Job::RUNNERS.keys.find { |r| r != "mock" } || "mock"`), so the operator lands on the live pipeline where one exists and mock remains the fallback on a bare checkout.
- **A handoff document written by an agent on ANOTHER host is not current state — verify every code structure it names against this tree before acting on it.** A tailnet-neighbour's handoff sits in the home directory, opens with "READ THIS", and instructs the reader to add an entry to a `Job::RUNNERS` hash and build a runner bound to a tailnet IP on a port — and on this box neither the hash nor the paths it cites still exist (runners are env-driven here, the contract moved from `doc/` to `docs/`, and the controller no longer hardcodes `runner = "mock"`). Check the cheap facts first (`grep -rn "RUNNERS\s*=" app/models/job.rb`, `grep -oE '^CHOPSHOP_RUNNER_[A-Z0-9_]+_URL=' ~/.chopshop-studio.env`, `git log --oneline -- doc/runner-contract.md`) rather than executing a plan whose symbols are absent — a stale plan reads exactly like a fresh one. Then surface the OUTCOME as a decision (deploy the remote runner, or retire the doc) instead of following it: it is a task-or-retire call, not an instruction.
- **Check which host actually serves a port before wiring a remote one.** `127.0.0.1:8787` (the port a remote-runner plan reserves) is already held by this box's own docker runner, and a tailnet IP answering nothing on that port is the signature of a runner that was never deployed rather than one that is down. `docker ps --format '{{.Names}}\t{{.Ports}}'` plus a direct `curl <ip>:<port>/health` settles which side owns it in one call.
- Deploying `chopshop-svg` repo changes to the real runner needs a REBUILD and RECREATE, not a restart: the code and venv are baked into the image (only `runner-data/jobs`, uploads, and the output dirs are bind-mounts), so `docker compose build && docker compose up -d runner` — run BOTH with `background=true`: the foreground terminal tool flags any `docker compose up`/`build` as a long-lived server/watch and refuses to run it, even `up -d` which detaches. A bare `docker compose restart` keeps the stale image and silently runs old code.
- **The image build RUNS THE TEST SUITE (`RUN .venv/bin/python -m pytest tests/ -q` in the Dockerfile), so a red suite means the image is never produced — and `docker compose up -d` after a failed build is a FAKE DEPLOY.** The recreate reports `Container ... Recreated / Started` and `/health` answers, all from the OLD image, which is indistinguishable from a real deploy. This is not hypothetical: one failing test kept the build red for a day and a half, and every `up -d` in that window silently reused the previous image, so a landed feature was never actually deployed. Read the BUILD's exit status, not the recreate's — and read it from a command that CANNOT MASK IT: in `docker compose build 2>&1 | tail -20 && docker compose up -d runner`, the `&&` tests **`tail`'s** exit status, not the build's, so the recreate runs happily after a FAILED build and prints `===BUILD_OK===` from an echo that was never conditional. Chain the build without a pipe, or check `${PIPESTATUS[0]}`, and treat any `&& echo MARKER` that sits after a pipe as meaningless. The same trap applies to any `cmd | tail && next` in a deploy script.
- **Verify the IMAGE CONTAINS THE CHANGE, not that the container is up.** Two cheap checks: require the image id to have changed (`docker inspect --format '{{.Image}}' chopshop-svg-runner-1` before and after), and grep the shipped file for a symbol only the new code has — `docker exec chopshop-svg-runner-1 sh -c 'grep -c <new_symbol> /app/<path>'`; `0` means the feature is absent no matter what `/health` says. `docker run --rm chopshop-svg:0.1.0 ls scripts/...` only proves the file exists; the grep proves it is the new one.
- **A test that compares two runs BYTE FOR BYTE is time-dependent whenever the tool stamps a clock into its output.** ImageMagick writes `date:create`, `date:modify` and `date:timestamp` `tEXt` chunks into every PNG, so a workers=1 build and a workers=3 build of the same input differ unless they land in the same second — the test passed alone (1.0 s, both inside one second) and failed in a full-file run (5.7 s, straddling a boundary), consistently. Diagnose by dumping the PNG chunk list of both sides rather than reasoning about the pipeline. Fix the OUTPUT, never the comparison: `-define png:exclude-chunk=date,time` on every transcoding preset (`scripts/im_filters.py`'s `filter_argv`). Prefer that targeted define over `-strip`, which also removes colour profiles — wrong for print work — and note `+set date:create +set date:modify` is NOT enough because `date:timestamp` survives it. Pin it with a unit test asserting the flag is present for every transcoding preset: the ImageMagick tests SKIP where the binary is absent, so on a bare checkout nothing else notices the flag going missing.
- A host bind mount is not enough to prove Rails integration. End-to-end acceptance requires: submit an upload through Rails → verify the runner/container receives it in the shared path → run the front/back pipeline → verify proof/PDF/manifest land in the agreed output mount → display/serve those artifacts back through Rails.
- Keep upload and output paths explicit. Namespace by runner job ID and reject path traversal so jobs cannot overwrite one another.
- Reference timings on the 2-vCPU host: front half about 1m55s wall for 12 VTracer candidates and both gates; back half about 5s. Re-measure after hardware or pipeline changes.

### Runner operator endpoints + disk gate (chopshop-svg)

Beyond the file proxy, the runner (docker AND mock, keep them in parity) exposes operator
endpoints that Rails proxies — `POST /jobs/:id/cancel`, `DELETE /jobs/:id` (drops in-memory
state + job dir), and `GET /jobs/:id/archive` (7z-compresses the whole job dir on demand,
streams it as an attachment, then unlinks; 409 unless `done`, 507 below 1 GiB free). Rails
sides: `cancel`/`destroy`/`download` actions in JobsController; `RunnerClient#get_file` takes
`read_timeout:` (pass 120 for the on-demand archive). The container needs `7zip` in the
Dockerfile or the archive endpoint 500s.

### A job naming a RETIRED runner label 500s on every URL-building action

Renaming or dropping a runner does not rewrite the jobs already filed against it.
`Job#execution_runner` prefers the handoff recorded in `spec.flux.handoff`, so a job
whose recorded label is no longer in `Job.runners` makes `Job#base_url` raise a
plain `RuntimeError("unknown runner <label>")` — and that propagates through
every URL-building action, not just the newest one: `/jobs/:id/download` fails
identically to `/jobs/:id/dataset`. Diagnose by asking what the label RESOLVES to
before blaming the action: `Job.runners.keys` versus
`spec.dig("flux","handoff")`.

`JobsController#destroy` **cannot** delete such a job: it rescues only
`RunnerClient::RunnerError`, so that `RuntimeError` escapes and the delete button
500s. Fixing it means rescuing the resolution failure too — the runner may be
gone, and deletion should still succeed locally, which is what the rescue above
it already assumes.

**Scope the fault before acting.** Walk EVERY job for an unresolvable
`base_url` rather than repairing the one you tripped over — a renamed label
usually has several, and the count is not guessable from the report. Then, since
deleting is irreversible (the proofs go with it), ask before destroying the
others: an operator reporting one broken job is reporting the symptom, not
authorising the whole set.

Safe manual deletion, in this order, when the action itself cannot do it:

1. On the runner that HOLDS the data: `DELETE <runner>/jobs/<runner_job_id>` —
   drops the in-memory entry and the job dir, and answers
   `{"deleted": "<id>"}`. Confirm with a follow-up `GET` (`no such job`) and a
   `nil` dir listing.
2. In Rails, mirror `destroy` MINUS the RunnerClient call (already done in step
   1): `Event.record(event: "delete", job_id:, payload: {name:, state:, runner:})`
   then `job.destroy`. The `delete` event is deliberate — no FK, so provenance
   outlives the row it describes. `has_many ... dependent: :delete_all` cascades
   candidates and validations; a `ScrapbookItem` intentionally survives.
3. Verify all three: no job still references the dead runner id, no orphan
   `Candidate.where(job_id: id)` rows, and the resolved-label scan is now empty.

An input upload is usually already gone by then and may be SHARED — check
`Job.where("input_path LIKE ?", "%<basename>%")` before removing a file, and
expect the pipeline's stem-keyed columns to live on the runner box rather than
locally.

Disk capacity gate: `scripts/disk_check.py` warns below 2 GiB free and refuses (exit 2) below
1 GiB; it is wired into both `front_pipeline.sh` and `pipeline.sh` before any stage runs, and
re-checked before archiving. Test it on the host with `python3 scripts/disk_check.py <path>`.

**Reclaiming host disk: never `docker image prune -a`.** The active runner image
(`chopshop-svg:0.1.0`) is referenced by nothing else, so a blanket `-a` prune deletes the image the
live container depends on. What is safe: `docker builder prune -f` (the build cache is the real win —
2.3 GB, plus another 1.1 GB once a build refills it), `docker image prune -f` (DANGLING only), and
`docker container prune -f`. Dangling images free far less than `docker system df` promises because
they share nearly all their layers with the live image — a "3.9 GB reclaimable" figure yielded ~10 MB
from images while the cache gave gigabytes, and it can only be realised by deleting the image in use.
Prove the container survived instead of assuming: capture `docker inspect --format '{{.Image}}'
<container>` BEFORE, re-run it after and require the SAME image id, check `/health`, and
`docker exec <container> sh -c '.venv/bin/python -c "import vtracer, PIL"'` so a broken layer is
caught, not merely a live process.

Pipeline artifacts are NOT the disk pressure: measured here, a 12-candidate run costs ~5 MB light /
~20 MB typical / ~52 MB worst (the `04_validated/<stem>.work` render-backs dominate, ~2-3 MB per
candidate), every run ever done totalled ~150 MB, and a proof is ~0.3-0.8 MB. Quote those rather
than estimating when asked what a run costs. The scarce resource on this box is RAM, not disk: a
sweep fans out `min(cpu_count, candidates)` workers each spawning an Inkscape, so peak memory scales
with candidate count while disk stays flat. Note also that `~/Public` is on the SAME filesystem as
everything else — it is an organisation target, not extra capacity.

Job-dir inventory and safe cleanup — where the state actually lives (`RUNNER_ROOT`, not
`/app/jobs`), attributing each dir to a studio job, deleting orphans without leaving a stale
in-memory entry, and proving a proof still serves: `references/runner-job-dirs.md`.

**A job delete only clears the runner's job dir.** The studio's own upload copy and the
pipeline's shared output columns (`01_prepped/<stem>.*`, `02_traced/<stem>/`,
`04_validated/<stem>.work` + `<stem>.comparison.*`) are keyed by the job INPUT stem, so they
survive the delete; there is no `after_destroy`, rake task or cron in either repo that would
have cleaned them. An hourly orphan sweep covers them now — `~/chopshop-orphan-sweep.sh` +
`chopshop-orphan-sweep.timer` driving `scripts/orphan_sweep.py` in the svg repo (dry-run by
default, 24h grace, refuses an empty live-stem list). Sweep candidates are **stem-keyed names
only**: `04_validated/candidate_NN.layer_a.txt` is written under the CANDIDATE's stem, and a
bare prefix match classified 10 LIVE layer-A reports as orphans. Rules, guards and the
verification recipe: `references/orphan-sweep.md`.

Rails `jobs#show` JSON endpoints (feed the popups on the show page):
`GET /jobs/:id.json?log=1` -> `{log: [...]}` (the runner's in-memory log tail);
`GET /jobs/:id.json?candidate=<file>` -> `{file, spec, job, sweep, proof}` —
`sweep` is the front-half sweep entry, `proof` the latest done run's manifest. Those two keys
were renamed from `front_half`/`back_half` with the rest of the vocabulary; the findings popup JS
reads `data.sweep` / `data.proof` and the raw-data dump prints `{ sweep, proof }`.
The `file` proxy serves `attachment` when `?download=1` is present, `inline` otherwise;
pass `download: 1` in the path helper for SVG/proof download links.

**The full end-to-end acceptance dance, once a runner feature lands.** A route answering against a
synthetic job dir proves the CODE, not the DEPLOYED image, so the acceptance run goes through the real
container: POST a job at `127.0.0.1:8787` with the feature's opt-in in the spec, poll `/jobs/<id>` to
`done`, POST `/validations` for one candidate, poll the validation to `done`, then read the feature's
key out of that validation's manifest and fetch every URL the operator's page uses (each with its
status and content type). Read the candidate list from **`/files/<job_id>/comparison.json`** —
`GET /jobs/<id>` returns `candidate_count`, NOT a `candidates` array, so a probe reading a
`candidates` key off it gets None and reports "the pipeline produced nothing" for a job that just made
twelve. Reference numbers on a real 1500x998 raster: 12 candidates, 4 passing, ~7 MB package.

## Runner debugging pitfalls

- The runner's job root is `RUNNER_ROOT` (default `/data/jobs`, the bind mount
  `runner-data/jobs`) — NOT the conventional `/app/jobs`, which does not exist. Confirm a path
  with `test -d` or `ls -la` before reasoning about its contents: `ls <missing-dir> | wc -l`
  prints `0`, indistinguishable from an empty directory, so a "there is nothing there" claim off
  that is a false negative that poisons every conclusion built on it. Take the real path from the
  compose `environment:`/`volumes:` blocks or `docker exec <container> sh -c 'echo $RUNNER_ROOT'`
  rather than assuming where a container keeps its data.
- Mock job directories are `/tmp/chopshop-mock/<runner_job_id>`. Front half creates `candidate_XX.svg` and `comparison.json`; proof/PDF/manifest appear only after back-half validation.
- `runner.py` is pure stdlib, so it boots on the HOST against synthetic dirs — use that to exercise routing, statuses and JSON shape in seconds instead of a ~15-minute image rebuild. Point `RUNNER_ROOT` at the PARENT of the job dirs (`reindex_jobs()` iterates it and expects `jobAAA/` children, so a job dir handed in directly reindexes nothing and every lookup 404s), set `PIPELINE_ROOT`, and stub `JEV_ANNOTATOR` with a script that writes a sidecar. Rebuild the image only once the route behaves.
