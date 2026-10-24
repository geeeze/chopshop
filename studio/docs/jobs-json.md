# GET /jobs/:id.json — the three JSON branches

The studio's job page polls this endpoint and its popups read it. The shape is
produced inline in `JobsController#show` (`app/controllers/jobs_controller.rb`,
the `format.json` block, lines ~16–68) — there is no jbuilder view. **The
controller is the source of truth; this document is the contract.** If you
change one, change the other.

All three branches are login-gated. A session cookie is required; CSRF is not
(GET). The response is always `Content-Type: application/json`.

---

## Branch 1 — `?log=1` (Log popup, on-demand)

```
GET /jobs/:id.json?log=1
→ 200 { log: [ <string>, … ] }
```

The runner's log tail as an array of strings. The runner holds the tail in
memory, so this works for done jobs too. On a `RunnerClient::RunnerError` the
array is empty (`[]`) — the popup shows nothing rather than erroring.

```json
{ "log": ["[prep] source: artwork.png", "[trace] 12 candidates written", …] }
```

---

## Branch 2 — `?candidate=<file>` (Findings button)

```
GET /jobs/:id.json?candidate=<file>
→ 200 { file, job, spec, sweep, proof }
→ 404 (head :not_found) when no comparison entry matches <file>
```

Fires only when `@job.comparison` is a Hash (the job has a parsed
`comparison.json`). The `<file>` value is matched against the `file` key of each
entry in `comparison["candidates"]`.

| key | type | meaning |
|---|---|---|
| `file` | string | the candidate filename that matched |
| `job` | object | `{ id, name, state, runner, created_at }` — the job's own record |
| `spec` | object | the job's spec hash (the print contract it was filed with) |
| `sweep` | object | the `comparison["candidates"]` entry whose `file` == the param |
| `proof` | object or null | the last done Validation's manifest for that file, or `null` |

`proof` is `null` when no validation has completed for that candidate. The
sweep entry's shape is documented in
[`chopshop-svg/docs/pipeline-schemas.md`](../../svg/docs/pipeline-schemas.md)
(`comparison.json` → one candidate record).

```json
{
  "file": "candidate_04.svg",
  "job": { "id": 37, "name": "phoenix", "state": "done", "runner": "mock",
            "created_at": "2026-10-10T12:00:00Z" },
  "spec": { "print_method": "screen_print", "max_colors": 6 },
  "sweep": { "file": "candidate_04.svg", "preset": "poster", "…": "…" },
  "proof": { "passed": true, "hard": 0, "advisory": 0, "stats": { … } }
}
```

---

## Branch 3 — default (status polling)

```
GET /jobs/:id.json
→ 200 { done: <boolean>, log_html: <string> }
```

The poll the job page's status card uses. `done` is `true` when the job state
is **not** in `Job::IN_FLIGHT_STATES` (`pending`, `queued`, `running`) — so
`done: true` covers `done`, `error`, and `cancelled`.

`log_html` is the log tail lines, HTML-escaped and joined with `\n`. For an
in-flight job with a `runner_job_id` it is the runner's log tail. For an
in-flight job **without** a `runner_job_id` (queued, or mid-generation on the
flux box) it is the studio-side `prep_summary` or the literal `"waiting…"`.

```json
{ "done": false, "log_html": "[prep] source: artwork.png\n[trace] 12 candidates written" }
```

---

## Branch precedence

The controller checks `?log` first, then `?candidate`, then falls through to
the default. A request with both `?log=1` and `?candidate=<file>` gets the log
branch. A `?candidate=` on a job whose `comparison` is not a Hash (no
comparison yet, or the job is not a pipeline job) falls through to the default
`{done, log_html}` — it does **not** 404.

---

## Cross-reference

The `sweep` entry and the `proof` manifest are pipeline-side artefacts. Their
shapes are documented in
[`chopshop-svg/docs/pipeline-schemas.md`](../../svg/docs/pipeline-schemas.md)
(`comparison.json` and the run record). This document does not duplicate them.
