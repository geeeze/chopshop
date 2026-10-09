# Extending job creation — the Run Job form, templates, and create-path branches

Read before adding a template, a form control, or a new kind of job filing in
chopshop-studio. The form (`app/views/jobs/new.html.erb`, ~3k lines) has ONE
spec pipeline; everything below is about joining it instead of starting a
second one.

## The picker is a GUIDED CHOICE: a KIND of job, then its deeper setting

Two controls, both driven from ONE place. `PipelineConf::GROUPS` (`"heading" =>
%w[template keys]`, in render order) is the only statement of the grouping.

- The FIRST control (`#job_group`) is the guided choice — the KIND of work in
the OPERATOR'S words (Print production / General / Multiphase / 3D & game
assets / Demo / test), never the runner kinds. The server renders one option per
group, each carrying `data-default` (the group's first template) and
`data-sub-label`.
- The SECOND control is still `#job_template` and still posts `job_template`, so
the whole Apply round trip (`POST /templates/use`, the server composing the
spec) is untouched. **Keep it that way.** The group control only sets
`option.hidden`; every template stays an option in the DOM, so revealing a group
needs no re-render and reverting the guided choice is deleting one ERB block and
one JS block. Hiding rather than removing also keeps each option's
`data-levers`/`data-defaults` alive.
- `GROUP_SUB_LABEL` names the second control only where a group is several
presets of ONE shape of job ("Trace tuning" for the four trace presets,
"Render preset" for the three render presets). A group of genuinely DIFFERENT
shapes has no single tuning: leave it out of the map and label the control "Job
shape" — do not invent a tuning label for a group that is just a list.
- Tests pin the grouping in BOTH directions — a template that names no group, and
a group naming a template that does not exist — so a template cannot be added
without a home or silently vanish from the picker. Each option carries its
`blurb` as `title`, so a choice explains itself on hover rather than only after
being picked.

**Picking a kind of job must APPLY, not just narrow the list.** The group handler
runs `tplApply.click()`, because Apply is what switches the RUNNER to the kind's
label and reveals that kind's panel. Narrowing alone left the runner on `svg`
with a trace contract while the operator had chosen a 3D job — the panel and the
contract disagreed about what was about to run. Init calls the same sync WITHOUT
applying: the server has already rendered a consistent default.

**Every panel that reads the spec must be hydrated on the APPLY path, not only on
init.** The apply handler set the textarea then called `hydratePanels()` — which
reads only the FLUX panel. Applying a `bp`/`blender` template therefore wrote
`bp.op: "blender"` into the contract while the bp panel still showed `generate`
and an empty document, so the next `writePanels()` (any panel edit, or the submit
gate) composed `generate` back OVER it and the render silently became a draw.
General rule: when a path writes the spec textarea, hydrate EVERY panel that
writes into it, or the panels' stale values overwrite the composed spec on the
next round trip.

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
   (`data-prompt-source`) read in Apply's success path — control state is
   part of what "applying" means alongside the composed spec.

**A dedicated fieldset must be DISABLED while it is off, never merely `hidden`.**
`hidden` is `display:none` and the browser still SUBMITS those controls, while a
feature param rides TOP-LEVEL and `jobs#create` reads it regardless of which
template is selected. The BP tournament fieldset did exactly this: rendered
unconditionally with only `hidden`, so `tournament_source` — the create path's
tournament TRIGGER (`return create_tournament_job if
params[:tournament_source].present?`) — was posted by EVERY filing, and a flux job
came back "A prompt tournament needs a prompt — describe the bracket's seed". The
fix is `disabled: true` in the ERB (the safe state must not depend on script
running first, or on a no-script client) with the mode hook driving `disabled`
alongside `hidden` to re-enable it. Two consequences for testing: an integration
test that asserts only "the control exists" and "`hidden` is present" PINS the bug
(assert an attribute that changes what is POSTED), and a test that posts the
feature param directly proves nothing about the form — reproduce it by reading
the rendered form's `FormData` (`[...new FormData(form).keys()]`), which is the
only place "what the browser sends" is visible.

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
- **Validate a composed spec against the SERVICE's OWN validator, not only the
  studio's model.** `PipelineConf.compose` and the service's schema are two
  implementations of one contract, so the wiring is proved by importing the
  service's validator and feeding it each template's composed spec — bp's
  `chopshop_bp.spec.validate_generate` / `blender.validate_blender` /
  `query.validate_query` keyed by the spec's `op`, the svg paths against what
  `trace_sweep.py` actually reads, every flux model through `FluxConf.validate`.
  Expect refusals that are CORRECT: the blender presets compose an incomplete
document (`missing required field 'elements'`) because the geometry is the
  operator's to paste, and the form refuses it locally with a named reason. A
  refusal the form does not also explain is the finding; one matching the form's
  own gate is the design.
