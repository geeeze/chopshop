# Extending job creation — the Run Job form, templates, and create-path branches

Read before adding a template, a form control, or a new kind of job filing in
chopshop-studio. The form (`app/views/jobs/new.html.erb`, ~3k lines) has ONE
spec pipeline; everything below is about joining it instead of starting a
second one.

## The form's contract

- **One spec round trip.** Controls write into panels; `writePanels()` writes
  the panels into the `#job_spec` textarea; `hydratePanels()` reads a contract
  back into the panels. A new control that posts its own JSON or has its own
  DOM writer is a second spec path that can quietly disagree with the first —
  the comment at the Template field states this rule.
- **Templates** are `PipelineConf::TEMPLATES` entries: `label`, `blurb`,
  `kind`, `levers`, `overrides`, optional `spec` fragment. A test pins the
  structure: a template must COMPOSE something — `levers.any? || spec.present?`
  (a lever-less, fragment-less template is "a label"). `kind` becomes the
  option's `data-kind`; Apply POSTs `templates/use`
  (`pages#apply_template` → `PipelineConf.compose`), then selects the first
  runner option whose `data-kind` matches and calls `showKind()`.
- **Levers map to EXISTING controls** (`run_job_lever_controls`); a lever with
  no control on the form is simply absent from the map — never invent a second
  control for a number some other control already edits.
- **Panels are `[data-run-fields="<kind>"]`**, hidden/shown by `showKind()`
  from the RUNNER select's kind. Because `showKind()` runs at several call
  sites (runner change, template Apply, init), any extra visibility rule
  belongs INSIDE `showKind()` — a listener on one call site gets overridden by
  the next.

## Template-scoped controls: the dedicated-fieldset pattern

A template whose request is not a composed pipeline spec (a fieldset of its
own params) joins the form like this:

1. Render the fieldset near the template field with a contract attribute
   (`data-<feature>-fields`), `hidden`.
2. Expose `window.<feature>On()` / `window.sync<Feature>Mode()` from an EARLY
   script block (later scripts — Apply, submit gate, init — must reach them;
   an IIFE keeps its functions private, so assign to `window` explicitly).
3. Hook: `#job_template` change, after Apply's `showKind()`, and once at init.
4. Hide the panels the feature makes irrelevant inside `showKind()` itself.
5. Gate `missingForRun()` FIRST for the feature (`return null` — real
   validation belongs server-side where the refusal message lives), and gate
   per-kind branches (e.g. the flux prompt check) for source switches like
   "random draws at filing".
6. A template may pre-set sibling controls via an option attribute
   (`data-prompt-source`) read in Apply's success path — control state is part
   of what "applying" means alongside the composed spec.

## Params: top-level, never `job[…]`

`jobs#create` does `Job.new(job_params)` with a fixed permit list; a form-only
param posted as `job[x]` where Job has no column raises
`ActiveModel::UnknownAttributeError` (a 500). Feature params therefore ride
TOP-LEVEL, like `job_template` does: `prompt_source`, `prompt_topic`,
`tournament_source`, `tournament_prompt`, `tournament_entrants`,
`tournament_seed`. Read them from `params[:…]`, not from `params.require(:job)`.

## The create path, in order

1. Build `@job` + parse `job_spec`.
2. `resolve_form_project!` — the shared ProjectPicker rule (HTML must name a
   project; see `references/projects-redesign.md`).
3. **Branches run BEFORE the normalizers and before any enqueue** — that is
   the window for (a) a server-side draw that rewrites the spec
   (`apply_prompt_source!`: `PromptSource.draw` → `spec.flux.prompt` +
   provenance in `spec["prompt_source"]` — draw SERVER-side so the spec can
   record which row was used) and (b) inline jobs the studio completes itself.
4. Normalizers → trace-source check → flux inline generate / `enqueue_run`.

### Filing a job the studio completes itself (the sim-job pattern)

- Branch on the feature param, build the feature spec, then save with
  `state: "done"`, `input_path: ""`, a `prep_summary` — NO `enqueue_run`
  (same precedent as recorded compose jobs).
- **Validators stand aside** the way the step list's do: add
  `return if sequenced? || <feature>?` to each of the four kind validators
  (flux/plot/blender/bp) plus a `Job#<feature>?` predicate reading the spec —
  a feature with no runner block must not be asked for one.
- The runner LABEL still has to satisfy inclusion, even though nothing
  dispatches: pick a configured label (bp by family) or the create 422s with
  "Runner is not included in the list".
- Determinism is the contract when the sim is seeded: same inputs → same
  outputs, and any URL that reproduces the artifact (the bracket link) must
  derive layout/params exactly as the original surface does — share the
  constants (`TournamentSim::MIRROR_THRESHOLD` etc.), never a second copy.
- Results render on the job page in the chain's first-content slot:
  `elsif @job.<feature>? → render "<feature>"` beside the existing
  `sequenced? → render "process"` branch.

## Testing rules for this surface

- **Runner-label hermeticity**: runner labels are env-driven, so a test that
  creates a job must set them ITSELF in `setup` (save + clear
  `CHOPSHOP_RUNNER_*`, set `CHOPSHOP_RUNNER_<LABEL>_URL`/`_KIND`, call
  `Job.reset_runners_cache!`) and restore in `teardown`. Inheriting the box's
  real runners asserts the deployment instead of the code.
- **Generation stubbing**: to exercise a create that generates, copy the
  trio from `FluxJobTest` — `with_flux_runners` (isolated env) +
  `stubbing(render:, create_job:)` (redefine/restore the singleton methods) +
  `perform_enqueued_jobs` — and scope raster cleanup to what the test wrote
  (`cleanup_test_uploads(/\Aflux_/)`; see
  `references/composites-and-test-uploads.md`).
- **Guard-wave sweep**: a new required create-guard breaks every test that
  posts without it — count the post sites and open each one before declaring
  the suite fixed (full rule in `references/projects-redesign.md`).
- **A test asserting WHICH row a random draw picked must constrain the draw**
  (leave exactly one row in the table, or post the filter that selects it) —
  an unconstrained `ORDER BY RANDOM()` turns the assertion into a coin flip.
- **Surface the refusal, don't guess it.** While developing a create-path
  branch, assert as `assert_response :redirect, flash[:alert].to_s` — the
  refusal arrives as a flash message, so the failing assertion then NAMES the
  real reason (a failed validator, the project picker, an empty draw) instead
  of `Expected redirect, got 422`. Drop the message argument for the final
  form of the test.
- **Boolean HTML attributes read back inconsistently**: a bare `hidden` attr is
  `""` in Nokogiri while a tag-helper `hidden: true` may render `hidden="true"`
  — assert presence with `has_attribute?("hidden")` (or assert the exact value
  you render), never `refute blank?` / `== "true"` on assumption.
