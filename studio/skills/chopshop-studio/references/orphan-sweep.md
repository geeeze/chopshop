> HOST-SPECIFIC — the sweep runs as a systemd timer on this box
> (`chopshop-orphan-sweep.timer` + `~/chopshop-orphan-sweep.sh`) driving
> `scripts/orphan_sweep.py`. The dry-run/grace/stem-key rules are generic.

# Orphan sweep — the artifacts a job delete leaves behind

## The leak

Job delete clears exactly one thing: the runner's job dir (`runner.py` `do_DELETE`
→ `shutil.rmtree(job_root/<id>)`). Two other layers are keyed by the **job INPUT
stem**, not the job id, so they survive the delete forever:

* the studio's own copy of the upload — `~/chopshop-studio/storage/uploads/<stem>.<ext>`
  (`JobsController#destroy` calls the runner then `@job.destroy`; `Job` has no
  `after_destroy`, only `dependent: :delete_all` on its rows, and git history has
  no cleanup callback or rake task to restore — `lib/tasks` is empty)
* the pipeline's shared output columns, bind-mounted into the container —
  `01_prepped/<stem>.*`, `02_traced/<stem>/`, `04_validated/<stem>.work` and
  `<stem>.comparison.{json,md}`

Measured on the live box once: 5 orphan stems held ~215 MiB plus 14 orphan uploads
(~25 MiB) — including exact duplicate uploads and job 6's `public/uploads` source,
which no longer exists anywhere else. Nothing bounds it: the pipeline's own
`disk_check.py` (warn <2 GiB, refuse <1 GiB) is the only backstop.

## The sweep

`scripts/orphan_sweep.py` (pure stdlib, host-agnostic — this repo is public, so it
never asks the database anything; the caller supplies the live stems).

```
--live-stems-file FILE   one stem per line, or a JSON list  (REQUIRED)
--root DIR               repo root: sweeps 01_prepped/, 02_traced/, 04_validated/
--uploads-dir DIR        studio upload dir, source copies by stem
--runner-root DIR --runner-url URL   a runner's job root: sweeps dirs the runner
                         itself no longer knows (probe GET <url>/jobs/<id> → 404)
--keep STEM              extra protected stem (repeatable)
--grace-hours N          default 24: anything modified more recently is kept
--max-delete N           default 2000: over the cap, the whole run aborts
--apply                  without it the run is a DRY RUN
--json-out FILE          machine-readable report of plan + outcome
```

Exit codes: 0 ok, 2 guard refusal, 3 delete failures.

### Safety rules it encodes (each one is a bug that was caught)

* **Refuses to run on an empty live set** (exit 2, deletes nothing). An empty list
  classifies every artifact as an orphan. A failed Rails query must abort the
  sweep, never widen it.
* **Only stem-keyed names are candidates.** Matching is `name == stem` or
  `name.startswith(stem + ".")`, and per column only a whitelist of suffixes the
  pipeline actually writes: `01_prepped` → `prep.json`, `prepped.png`,
  `prepped.inverse.png`; `04_validated` → `work`, `comparison.json`,
  `comparison.md`. **`04_validated/candidate_NN.layer_a.txt` is written by
  `pipeline.sh` under the CANDIDATE's stem** — a bare prefix match classified 10
  LIVE layer-A reports as orphans on the first dry run. Anything unrecognised is
  reported as `not stem-keyed` and left alone.
* **24 h grace window** (dir = newest mtime inside), so an upload the operator just
  dropped on the new-job form is never swept.
* **Symlinks are skipped, never followed**, so the sweep cannot delete outside the
  tree it was handed.
* **`--dry-run` is the default**; the wrapper passes `--apply` explicitly.
* A stem equals the input basename **up to the FIRST dot** (`upload_x.prepped.inverse.png`
  → `upload_x`), which is why `04_validated/<stem>.work` and the prep twin travel
  with their stem.

## The hourly schedule (host-local, outside the repos)

* `~/chopshop-orphan-sweep.sh` — the wrapper. Sources `~/.chopshop-studio.env`
  (without it `bin/rails runner` aborts on `SECRET_KEY_BASE`), builds the live-stem
  list with `RAILS_ENV=production bin/rails runner 'Job.pluck(:input_path)…'`
  (basename, first-dot split), refuses below 1 live stem, then runs the script via
  `sudo -n /usr/bin/python3` because the container writes those columns as root.
  `--dry-run` as `$1` gives a plan.
* `~/.config/systemd/user/chopshop-orphan-sweep.{service,timer}` — `OnCalendar=hourly`,
  `Persistent=true`, `RandomizedDelaySec=180`. Enabled; linger is already on for the
  user, so it runs without a login session.
* Latest run: `~/.local/state/chopshop/orphan-sweep.json` (plan, bytes, skips).
  History: `journalctl --user -u chopshop-orphan-sweep.service`.
* Knobs (env, when editing the wrapper): `CHOPSHOP_SVG_ROOT`, `CHOPSHOP_SWEEP_KEEP`
  (default `00-example`), `CHOPSHOP_SWEEP_GRACE_HOURS` (default 24).

**`00-example` is protected by DEFAULT and must stay that way**:
`01_prepped/00-example.prepped.png`, `02_traced/00-example/candidate_01..12.svg` and
`04_validated/00-example.comparison.*` are TRACKED in git (the .gitignore lists the
output dirs, but tracked files stay tracked), so sweeping them would dirty the
working tree.

## Verifying a change to the sweep

1. Unit tests: `.venv/bin/python -m pytest tests/test_orphan_sweep.py -q` (15 tests,
   synthetic tmp trees only). `.venv/bin/python -m pyflakes scripts/orphan_sweep.py`.
2. Dry run against the live box: `bash ~/chopshop-orphan-sweep.sh --dry-run`. READ THE
   PLAN — the per-entry reasons are what caught the candidate-stem bug. Check the
   `not stem-keyed` count matches the `04_validated/candidate_NN.layer_a.txt` count.
3. Apply, then assert the live side survived: every `Job#input_path` stem still has
   its `02_traced/<stem>/` (13 candidates), `04_validated/<stem>.work` and
   `01_prepped/<stem>*`; the `*.layer_a.txt` count is unchanged; `00-example` is intact.
4. Serve path: `curl -s -o /dev/null -w '%{http_code} %{size_download}\n'
   http://127.0.0.1:8787/files/<job_id>/<basename>` for a live proof, then the Rails
   gate (login, `/jobs` 200, `/jobs/<id>/file?name=candidate_01.svg` 200).
5. Runner-side dirs: the mock root's dirs stay until the runner forgets them AND the
   grace window passes — 404 from `GET <runner>/jobs/<id>` is the signal, so a probe
   dry run at `--grace-hours 0` is the way to prove that rule still fires.

## Still open (deliberately not swept)

* **`05_final/`** holds `candidate_NN.proof.png|.print.pdf|.manifest.json` (candidate
  stem, no upload stem) alongside hand-run `pipeline.sh` outputs named
  `<timestamp>-<hash>.*`. Neither is attributable to a job, and the canonical copies
  of a proof live in the JOB DIR, so these are duplicates rather than orphans — but a
  hand-run artifact has no other copy. Left alone until there is a rule that can tell
  them apart.
* **Runner job dirs** (`runner-data/jobs/`) are cleaned by the UI delete already, and
  the probe rule keeps anything the runner can still serve; they are not part of the
  hourly sweep's roots (root-owned, would need sudo for nothing).
* The studio-side fix is still available as an alternative: an `after_destroy` that
  unlinks the upload and the stem's columns. The sweep covers the same ground within
  the hour and also catches jobs deleted before it existed.
