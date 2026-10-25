> HOST-SPECIFIC — the auth model names this box's accounts (the
> `~/.chopshop-studio.env` password, the migrated `<operator-handle>`
> user) and the runner map is this deployment. The BP/sequence contract
> and the who-owns-what boundary are generic.

# Design and vocabulary — BP actions, ownership, operator vocabulary

> Moved out of `SKILL.md` so the always-on file stays a short router; the rules are unchanged.
>
> Read before touching the runner map, the Run Job form, `RunJob`, or any
> service constant (`FluxConf`/`BpConf`/`Telemetry`).

## The BP action, and sequences

**BP is ONE Run Job action for the whole blend-plot service, and a sequence is an ordered list of actions in one job.** Both are settled design; read this before touching the runner map, the Run Job form, or `RunJob`.

- **One action, six operations.** The site used to offer two runner actions for one service (`plot` drew a document, `blender` rendered 3D) and the BLENDER page admitted they were the same service. The offered target is now a single `bp` label whose op selector covers all six: `generate`, `digest`, `query`, `tree`, `log` (all draw, answering one SVG) and `blender` (renders, answering PNG frames / a GLB manifest). `Job::BP_OPS` is the one list the model, the worker and the form read. The request rides in `spec["bp"] = { op, doc, runs? }` and the answer is written back under the same block, so one record carries the ask and the result.
- **`BpClient` is a DISPATCHER, not a third wire implementation.** It routes `blender` to `BlenderClient` and everything else to `PlotClient`, so the envelope, the bearer token, the timeouts and the refusal parsing stay where they are and where they are tested. Adding a "bp client" that re-implemented the wire would be a second thing to keep in step.
- **The legacy `plot` and `blender` kinds are KEPT VALID and no longer OFFERED.** This is the load-bearing part: an already-filed job must keep resolving its URL and running, so `JOB_KINDS` still contains both and their validators and accessors are untouched. Two separate questions, two separate methods — `JOB_KINDS` ("may a job be filed against this kind at all", YES for legacy) versus `Job.form_runners` ("what does a NEW job get offered", `bp` only). Removing a kind instead is the bug that once made an operator's jobs **undeletable and unrunnable** ("unknown runner" from `base_url`). There is no fallback in `form_runners` and it would be dead code: `RUNNER_DEFAULTS` always supplies `mock`, so the dropdown can never be empty. The remedy for a missing BP action is the `CHOPSHOP_RUNNER_BP_*` env line.
- **Anything that SHOWS a runner list must read `Job.form_runners`, never `Job.runners.keys`.** `Job.runners` is every CONFIGURED label, including the superseded legacy `plot`/`blender` — valid for the jobs already filed against them, but not on offer for a new one. A census built from it advertises a runner the operator cannot choose and cannot explain ("plot up" in the footer, with no `plot` option in the dropdown). It bit in TWO places at once — the layout's footer runner menu and `jobs#create`'s `runner_health_rows`, which feeds the Run Job form's own runner hint — so grep for `Job.runners` when touching anything that lists runners. A legacy label still serving its old jobs is not a reason to advertise it.
- **A failure carries ONE name.** The delegated clients raise their own errors, so a bp job whose service was down would report `PLOT: …` — a surface the site no longer offers. `run_bp` re-raises either as `BpClient::Error`, keeping the half's own reason in the message.
- **Sequences: `spec["steps"]`, an ordered array, one job.** Each step is `{ "runner" => <label>, "input" => "previous"|"job"?, <kind> => <that kind's block> }`. The hand-off declaration sits BESIDE the runner label, never inside the kind's block, because the block is posted to the service untouched. **The studio drives the chain, NOT the runner**: a runner is stateless and serves one operation per request, so `RunJob#run_steps` posts a step, waits for it to terminate, then posts the next with the previous step's file handed in (a pipeline step is polled to done, because the next step's input is its output). No runner change is needed or wanted — do not go looking for one.
- **Back-compat is the default and is pinned.** A spec with no `steps` key behaves exactly as before and `Job#steps` answers one implicit step, so the single-action path and the chain path share every reader and no existing row needed migrating. Validation REUSES the per-kind validators once per step (`STEP_VALIDATORS`) rather than copying them, naming the step index in the message.
- **A BP step's `produces` is op-dependent**, which the static `STEP_FILE_RULES` cannot express: the drawing operations leave an SVG and `blender` leaves a PNG, so `produced_extension` reads the step's own op. A following `svg` step accepts either, which is what makes a chain through bp derivable. A render step handed a file converts that SVG studio-side into the blend vocabulary, because the render operation takes GEOMETRY and has no file-input slot — the same rule the legacy blender step follows.
- **The form edits each step's block as JSON rather than re-rendering every panel per step.** A step IS the single-action request, so a document stays defined in one place instead of two that can disagree. The panel's rows compose only a document that PARSES, and unticking the box DELETES `steps` rather than leaving a chain in a contract that no longer claims to be one. Verified end-to-end in a browser (tick creates a row, add/reorder restamp the ordinals and move the row, a bad paste reports the step index and leaves the contract intact, untick removes the key) — a server-side test cannot check any of that.

## Who owns what — the metrics-engine boundary

Three repos, three jobs, and the seam is worth stating because two of them once claimed the same one:

- **`chopshop-svg` (the pipeline) COMPUTES the ML.** The learned ranker and the bucket bandit (`scripts/triage_ranker.py`) and the triage gates (`scripts/triage.py`) live there and that repo is the source of truth for the constants it ships.
- **`chopshop-studio` OWNS THE METRICS ENGINE** — the *configuration* of that ML and the *presentation of server statistics*: the footer's **check-engine light**, the **STATUS page** (`/status`) it leads to, and the machine-readable twin `GET /engine.json` (`Telemetry` + `EngineController`, both Ruby). The studio does not compute the ML, and says so. `Telemetry`'s transcription of the pipeline's constants is **pinned, not trusted** — `test/models/runner_conf_drift_test.rb` + `test/fixtures/runner_conf_drift.json` (the same generated-fixture + optional `CHOPSHOP_SIBLING_ROOT` live-read pattern that pins `FluxConf` and `BpConf`). Never re-mirror a service constant by hand without enrolling it in that pin: an unchecked transcription is free to lie about the pipeline it describes, and the drift is invisible until an operator reads a number that is no longer shipped.
- **`chopshop-bp` is CALLED BY the studio for blend-plot tasks** — it draws documents and renders 3D under one JSON contract (`generate`/`digest`/`query`/`tree`/`log` draw; `blender` renders 3D through headless Blender). **Drawing a document IS a blend-plot task**, which is why the studio POSTs the STATUS page's hierarchy (`tree`) and event timeline (`log`) to bp rather than drawing them in Ruby — that is the correct division, not a leak. bp applies no scoring, keeps no telemetry, and never picks a winner. It is **NOT "a metrics engine"**; its `metrics_version: 1` schema is a shared flat **data contract** (the shape of the run records the chart operations read), not a scoring engine. That framing was corrected deliberately — see the `blend-plot:` tag in each repo.

## Operator vocabulary — candidates, jobs, PROOFS

A finished back-half run is a **PROOF**, never a "validation", and its page is the proof page.
His vocabulary goes in every string he can read:

- A proof's number is INHERITED from the candidate it proves: `candidate_06.svg` → **`proof_06`**
  (`proof_06.svg` when naming the artifact). `proof_name()` / `proof_label()` in
  `ApplicationHelper` are the single place that mapping lives.
- Never show the database id as a run's identity. "`#11`" beside `candidate_06.svg` told the
  operator nothing; the proof's own name IS its identity, so drop the id column rather than label it.
- **Never rename the pipeline's own artifacts to match.** The front half's tracing outputs stay
  `candidate_NN.svg`; the back half's stay `candidate_NN.proof.png` / `.print.pdf` /
  `.manifest.json`. The proof name is a DISPLAY mapping — a naming instruction is about what the
  operator reads, not about files, the public pipeline repo, or the runner's contract.
- **Sweeping a word out of the docs does not mean renaming its identifiers.** Enumerate the hits
  per file and classify every one BEFORE quoting a scope: prose gets reworded, an identifier stays.
  A retired stage word is usually also a real filename, a JSON key, a directory, a check type, or a
  string a script PRINTS — `front_pipeline.sh` and `front_common.py` as filenames, the `back_half`
  key and `back_half_passed` check type (read by `closeout.py` / `requirements.json`), the
  `04_validated/` directory, and `validate_svg.py`'s own `VALIDATION PASSED for <file>` output.
  Reword the prose, leave the identifier, and name the survivor in the same paragraph so the reader
  is not left guessing. Renaming a key or a check type is a CONTRACT change, not a wording change:
  it wants its own commit, updated tests, and a note that the old name is gone. An offer of
  "docs only" is wrong the moment the same word is a live JSON key.
- "front half" / "back half" are internal pipeline words — kept out of page copy, flashes and
  user-facing JSON keys. Headings and flashes use proof / proofs / candidates, and dispatching a
  job reports **"Job started."**
- The repo's own docs then renamed the two stages: the front half is the **trace stage** in
  README/AGENTS/OVERVIEW and the back half is the **print check**, with the stage doc at
  `scripts/TRACE_STAGE.md` (renamed from `FRONT_HALF.md`). Script filenames (`front_pipeline.sh`,
  `front_common.py`) and the `back_half` JSON key / `back_half_passed` check type were left alone
  deliberately — the last two are a contract `closeout.py` and `requirements.json` read, so renaming
  them is a contract change with tests, not a wording change.

**Act on the display layer; do not ask which layer was meant.** An instruction like "candidate_06
becomes proof_06" is unambiguous under the display reading, and offering "rename the pipeline
outputs" as an option in a clarification form reads as not listening. Change views, page and
section titles, flashes, table headings, and the URL path (`resources :validations, path:
"proofs"` — the controller and model keep their internal names), then verify.

**A wording sweep is not done until the served pages are clean.** Grep every authenticated page
(jobs index, job show, jobs new, about, json, proof, jev) and assert ZERO hits for each retired
term: `[Ff]ront[ -]half`, `[Bb]ack[ -]half`, `dispatched`, `Validation`, and any bare id. Source
grepping is not the check — the same words also live on pages the edit never touched (about, json,
the layout footer) and inside served JavaScript, while internal names (manifest keys,
`source_validation`, class names) legitimately survive — so read the hits before calling it done.

## Auth model (password-only per-user accounts)

Users are real now: a `User` model (`has_secure_password` + bcrypt), and **the password IS the identity** — no username, no directory, no LDAP. Each user's password gates their own data. `session[:user_id]` holds the signed-in user; `current_user` returns that `User` (or nil); `Current.user_handle` (`ActiveSupport::CurrentAttributes`, set per-request in `ApplicationController#set_current`) is read by the `Owned` concern, which stamps `owner` at create and scopes every read via `default_scope` (`where(owner: handle)` when signed in, `all` otherwise — the latter is what lets the Solid Queue worker, which has no session, load any user's job by id). `owner` columns exist on `jobs`, `validations`, `scrapbook_items` and `composites`. Add a user with `bin/rails 'users:add[handle,password]'` (production) or `bin/rails runner 'User.create!(handle: "x", password: "y")'`; list handles with `bin/rails users:list`. `CHOPSHOP_PASSWORD` is no longer read by the app — the operator's original password was migrated unchanged into the `users` table as the `<operator-handle>` user's password, so their regular login still works. Never reintroduce usernames or LDAP — password-only is the settled direction. See `references/user-system.md`.

