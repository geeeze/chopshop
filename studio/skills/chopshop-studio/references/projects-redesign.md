# The Projects redesign — the studio's jobs surface (landed 2026-09-30)

Read this before touching any jobs-list code, docs or tests in chopshop-studio.
Older material describing a `GET /jobs` page is stale: that route 404s.

## The surface

- Nav: **Projects · JSON · FLUX · JEV · BP**.
- `GET /` = the Projects index (owner-scoped cards, each linking its workspace).
- The jobs list lives ONLY on the per-project workspace `GET /projects/:id`
  (`projects#show`): `@project.jobs.recent.includes(:validations)`, the same
  `jobs/_row` / `jobs/_card` partials the old index used, a List/Grid toggle
  (`data-view-toggle`, localStorage key, `#jobs-list` / `#jobs-grid` wrappers),
  and **no pagination** — the old PER_PAGE / infinite-scroll / scroll-signal
  machinery is deleted.
- Entry points that used to be the Jobs page: the JSON page's Run Job posts
  its spec to `json/use`, which stores a draft and redirects to the Run Job
  form; the FLUX/JEV/BP head buttons are plain `new_job_path` links.

## Project scoping is load-bearing

`Job belongs_to :project, optional: true` — but a job with NO project is
listed **nowhere** in the UI, reachable only by its direct URL.

- The Run Job form carries a project picker (a real select of the operator's
  owned projects + "Create a new project…", which reveals a name input
  posting `job[project_name]`; `jobs#create` makes the project — owner stamped
  by the `Owned` concern, `is_test: false` — then files the run under it).
- `jobs#create` refuses a project-less **HTML** submit (422, re-renders the
  picker intact via `assign_form_context`). JSON/agent posts may still omit
  the project — `docs/agent-api.md` owns that contract.
- Tests that file jobs through the form route use the shared `picker_project`
  helper in `test_helper.rb`.
- **Rails pitfall**: a non-numeric `project_id` (the picker's `"__new__"`
  sentinel, or junk) casts to integer **0**, not nil — and `0.blank?` is
  false. Normalise non-positive ids to nil BEFORE testing `blank?`, or you
  file an invisible run under a project that does not exist.
- The picker RULE is shared: `app/controllers/concerns/project_picker.rb`
  exposes `pick_project(raw_id, raw_name, what:)` → `[id, error]` (normalise
  the 0-cast, create-from-name, refuse an HTML post with neither, keep JSON
  optional). `jobs#create` (`resolve_form_project!`), `composites#create` and
  `composites#update` all include it — a THIRD form that files
  workspace-visible work should `include ProjectPicker`, not re-derive the
  rule.
- The composite builder files under the same rule with FLAT params
  (`project_id` / `project_name` at top level, like `job_template`) and
  preselects from the projects-workspace Compose links (`?project_id=`) and the
  composite being edited; a save that posts a project MOVES the composite (an
  update that posts none leaves it where it is).
- **A new create-guard breaks every test that posts without it — sweep the
  POST SITES BY COUNT, not by memory.** `grep -rn 'post <path>' test/ | wc -l`
  gives the exact number; open each site (helpers and inline blocks alike — a
  site buried in a test body is how a "fixed" suite returns red on the next
  run). One shared factory in `test_helper.rb` (e.g. `picker_project`) beats a
  per-file helper: the guard is a property of the route, so the fix is one
  line at each post site.

## Suite stewardship

- Counts are **measured, never asserted**: re-run `bin/rails test`, quote the
  number you got. CONTEXT.md holds the single canonical count and lists
  superseded ones so none gets re-quoted.
- After a page-removing redesign, a red suite is usually orphaned tests
  hitting the deleted route. Decision rule: behavior that MOVED → re-point at
  the workspace successor (with project-scoped fixtures); behavior pinned to
  a DELETED feature (pagination, scroll sentinels) → RETIRE with a tombstone
  comment naming what was deleted and where the behavior lives now — never
  delete silently.
- Real bugs surface as pinned tests failing for non-selector reasons (nil
  derefs on failure paths, records created without the owning FK) — fix the
  app, cite the test that found it.

## GitHub issue hygiene (this fleet)

- Long comment bodies go to a scratch file + `gh issue comment --body-file`;
  inline bodies die on f-string `{...}` interpolation and shell quoting.
- Closing a stale-fixed issue: verify on CURRENT main first
  (`git merge-base --is-ancestor <branch> main`, a live re-measure, a test
  run), then close with that evidence in the comment — never close on the
  issue's own claim. A merge message referencing `(#N)` does not close N.
- Dedupe against open issues before filing; retract-and-close (never delete)
  when a filed issue is disproven.
