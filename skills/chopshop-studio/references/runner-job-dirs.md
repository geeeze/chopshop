> contains HOST-SPECIFIC paths — `RUNNER_ROOT` here is the
> `runner-data/jobs` bind mount on this box's docker host, and the
> `127.0.0.1:8787` runner. The dir-layout rules are generic.

# Runner job directories — inventory, attribution, cleanup

When asked whether the runner "has anything queued/fresh", the answer is on disk under the
job root plus the runner's in-memory index. Both have traps; work the path out from config
rather than assuming the conventional container path.

## Where the state actually is

- Job root = `RUNNER_ROOT` (env), default `/data/jobs`. In the container that is the bind mount
  `./runner-data/jobs` → host `~/chopshop-svg/runner-data/jobs`. `runner-data/` is gitignored.
- `/app/jobs` does **not** exist. Never reason about the job root from the app layout; get it
  from the compose `environment:`/`volumes:` blocks or `docker exec <c> sh -c 'echo $RUNNER_ROOT'`.
- Baked into the image: the code and the venv. Bind-mounted: `runner-data/jobs` (rw), the studio
  uploads (ro), and the output dirs `00_source`–`05_final` (rw). `.preflight-work/` is INSIDE the
  container (not mounted) and holds per-run scratch `candidate_NN.print.pdf` / `.proof.png`.
- Job dirs are root-owned (the container writes them); their parent is user-owned, so a host-side
  `rm -rf` needs sudo — another reason to delete through the runner route below.

## What a job dir holds

`<job_id>/candidate_NN.svg` + `comparison.json` (front half), `spec.json`, `source.png`,
`input/upload_<hash>.<ext>`; after a back-half run also `<job_id>/candidate_NN.proof.png` and the
print PDF. A dir holding only `spec.json` (or only `input/`) is an aborted create.

## The in-memory index, and "is anything queued?"

- State is memory-only. `reindex_jobs()` runs at boot, scans `RUNNER_ROOT` subdirectories and
  inserts each as **`"state": "done"`** — so a restart can never fabricate a queued or running
  job. There is no such thing as a phantom queue on disk.
- There is **no list endpoint**: `GET /jobs` answers `{"error": "unknown route"}`. That is the
  routing working, not a missing feature. State is per-id — `GET /jobs/<id>`; an id this process
  does not know answers `{"error": "no such job"}` (`/validations/<id>` → `"no such validation"`).
  Use the delete route's response and the studio DB for inventory, not a GET list.
- `Handler.authorized()` is `not TOKEN or …`, so with no token configured every route is open.
  Local maintenance calls need no `Authorization` header; that is normal, not a misconfiguration.
- Container start time plus `restarts` (`docker inspect … --format '{{.State.StartedAt}} {{.RestartCount}}'`)
  tells you whether an index rebuild even happened — check before theorising about lost state.

## Attributing dirs to studio jobs (before deleting anything)

1. List the studio side: `RAILS_ENV=production bin/rails runner 'Job.order(:id).each { |j| puts "#{j.id} #{j.name} #{j.runner_job_id}" }'`.
   `Job#runner_job_id` is the runner job id, i.e. the directory name.
2. A dir whose name matches no `runner_job_id` is an orphan (aborted create, or its studio row was
   removed). The reverse — a `runner_job_id` with no dir — means someone cleaned the dir already.
3. Never delete a dir whose id appears in the studio DB.

## Deleting safely

- Delete through the runner so the in-memory entry goes too:
  `curl -X DELETE http://127.0.0.1:8787/jobs/<id>` → `{"deleted": "<id>"}`. A bare `rm -rf`
  leaves the index serving a job whose files are gone until the next restart.
- An orphan dir is not automatically junk: it may hold the ONLY copy of an upload. The studio's
  canonical copy is `~/chopshop-studio/storage/uploads/<name>`, and the job-dir copy may be a
  different file entirely (a derived raster), so **compare hashes, not filenames**, before
  removing. Regenerable scratch (`.preflight-work` proofs) is cheap; an input raster with no
  studio-side twin is not.
- Cleanup never appears in the repo sweep — `runner-data/` is gitignored, so expect a clean
  `git status` and no commit.

## Verifying a proof/PDF still serves

- The studio's validation page fetches `m["proof"]`, a **basename** resolved by `artifact_path()`
  inside the job dir. The absolute `/app/.preflight-work/…` paths recorded under the manifest's
  `artifacts` are a record of where the run wrote them — per-run scratch, usually gone. A missing
  `artifacts` path says nothing about the proof.
- Prove servability by fetching the basename through the runner:
  `curl -s -o /dev/null -w '%{http_code} %{size_download}\n' http://127.0.0.1:8787/files/<job_id>/<basename>`.
- Two candidates can legitimately produce byte-identical proofs: a sweep can emit duplicate
  outputs. Hash the candidate SVGs (`md5sum candidate_NN.svg`) before treating identical proofs as
  a bug — identical inputs explain identical outputs. Do the same `source.png` vs
  `source.inverse.png` comparison when a twin looks suspicious.
