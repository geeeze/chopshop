# Agent usage of the deployed stack — verification report

Date: 2026-09-27
Repo: the studio checkout on the deployment host (deployed services, production env)
Method: curl against the running `chopshop-rails.service` on 127.0.0.1:3001, no
browser, no Rails test harness. A pinning integration test was added separately.

## Answer to the question

**Yes.** A local agent can interact with the deployed stack without a browser,
and jobs an agent sets DO appear in the job history for this single-user
deployment.

The whole path — login, upload, create, list, view, download, cancel, delete —
was driven end to end with `curl` and a cookie jar. The created job
(`agent-curl-probe`, id 37) appeared in `GET /jobs` as a real row linking to
`/jobs/37`, reached state `done` on the runner, and produced a valid 7z archive
over `GET /jobs/37/download`.

## Environment facts observed (no secret values)

- `chopshop-rails.service`: production Rails on 127.0.0.1:3001 via
  `EnvironmentFile=~/.chopshop-studio.env`.
- `chopshop-mock-runner.service`: 127.0.0.1:8790, running from
  `~/chopshop-mock-runner/runner.py`.
- Env file keys present (names only): `CHOPSHOP_PASSWORD` (gate ENABLED),
  `SECRET_KEY_BASE`, a `CHOPSHOP_RUNNER_<LABEL>_URL`, `CHOPSHOP_JEV_API_KEY`.
- `RUNNER_TOKEN` is **not present** in either process environment, and the mock
  runner unit has no `EnvironmentFile`. `RunnerClient.token` therefore returns
  nil and studio -> runner calls carry no `Authorization` header. The deployed
  loopback runner accepted those unauthenticated calls (job 37 reached `done`).
  The brief's "bearer RUNNER_TOKEN" premise does not match this deployment.

## The curl steps that worked

Base: `http://127.0.0.1:3001`. Cookie jar `cookies.txt`. CSRF token read from
the `csrf-token` meta tag / `authenticity_token` field. Password sourced from
the env file inside the shell; never printed or persisted.

1. `GET /login` -> **200**, HTML with `<meta name="csrf-token">` and a
   `name="authenticity_token"` form field (tokens redacted here, length 86).
   Note: `allow_browser versions: :modern` did NOT reject curl's default user
   agent, so no browser UA spoofing was needed for any step.

2. `POST /login` (`authenticity_token`, `password`) -> **302**,
   `Location: https://127.0.0.1:3001/`. Session cookie set (flags `path=/;
   secure; httponly; samesite=lax`). The scheme in Location is `https` because
   the app runs behind nginx, but the session worked over plain http loopback:
   a follow-up `GET /jobs` returned **200** with the Jobs index (contained
   "Run Job" and the jobs table, not the login gate).

3. `POST /jobs/upload` (multipart `file=@agent_probe.png`, a generated 4x4 PNG)
   -> **200**, `application/json`:
   `{"path":"<app-root>/storage/uploads/upload_e66d24ce4721.png","preview_url":"/jobs/upload_preview/upload_e66d24ce4721.png","name":"agent_probe.png","size":75}`
   The JSON contract (`path`, `preview_url`, `name`, `size`) holds.

4. `POST /jobs` with `job[name]=agent-curl-probe`, `job[source_kind]=raster`,
   `job[input_path]=<stored path>`, `job[spec]={"print_method":"screen_print","max_colors":6}`
   -> **302**, `Location: https://127.0.0.1:3001/jobs/37`.
   **Workaround:** the brief's field list omits `runner`. `Job` validates
   `runner` inclusion in `RUNNERS.keys`, so `job[runner]=mock` had to be added
   or validation fails. (Existing jobs are all `runner=mock`.)

5. `GET /jobs` (history) -> **200**. Parsed the HTML, did not assume:
   - the string `agent-curl-probe` occurred 5 times in the page,
   - `href="/jobs/37"` occurred 3 times,
   - the parsed row is exactly
     `<a class="cs-job-name" href="/jobs/37"><strong>agent-curl-probe</strong></a>`.

6. `GET /jobs/37` -> **200**, page carries the job name.

7. `GET /jobs/37/download` -> **200**, 14,513 bytes,
   `content-type: application/x-7z-compressed`,
   `content-disposition: attachment; filename="agent-curl-probe.7z"`; file
   recognised as `7-zip archive data, version 0.4`, magic `37 7a bc af 27 1c 00 04`.
   The job had settled to `done` (confirmed via the runner-backed state), which
   is what the download route requires.

8. `POST /jobs/37/cancel` -> **302** to `/jobs` (job was already `done`, so the
   cancel was a safe no-op); `DELETE /jobs/37` -> **302** to `/jobs`;
   then `GET /jobs/37` -> **404**. The uploaded file was removed from
   `storage/uploads/` and the record was confirmed gone from the production
   database. The deployment is back as it was found.

## Job state / polling note

`create` sets local state `running` after calling the runner, and the runner
reports `queued|running|done|error`. Polling the show page by the first
`status-pill status-*` class is unreliable: candidate/pass pills can match
before the job-state span. The authoritative job state on the show page is
`<span class="gradient-text job-state">· <state></span>`; `GET /jobs/:id.json`
also exposes a `done` boolean. Job 37 became `done` and produced the archive.

## What failed / needed a workaround

- `job[runner]` was required but absent from the brief's step list — added
  `job[runner]=mock`.
- No `RUNNER_TOKEN` exists in this deployment, contrary to the brief. Studio ->
  runner worked unauthenticated over loopback.
- A manual `bin/rails runner` reads the **development** database by default;
  inspecting the deployed data needs `RAILS_ENV=production` plus
  `SECRET_KEY_BASE` sourced from the env file. Used read-only for verification.
- Login's redirect `Location` is `https://...` while the listener is http on
  loopback; the session still worked over http (verified, not assumed).

## Pinning test

Added `test/controllers/agent_driven_job_test.rb` (new file only; no existing
test file touched). It is an `ActionDispatch::IntegrationTest` that logs in via
`POST`, uploads a generated 4x4 PNG, asserts the upload JSON contract
(`path`/`preview_url`/`name`/`size`), creates a job, asserts the `302` to
`/jobs/:id`, and parses `GET /jobs` with Nokogiri to confirm the row and its
link. `RunnerClient.create_job` and `RunnerClient.get_job` are stubbed with the
repo's hand-rolled `define_singleton_method` pattern, so no live runner is
needed.

- `bin/rails test test/controllers/agent_driven_job_test.rb` -> 2 runs,
  19 assertions, 0 failures, 0 errors.
- `bin/rubocop test/controllers/agent_driven_job_test.rb` -> no offenses.
