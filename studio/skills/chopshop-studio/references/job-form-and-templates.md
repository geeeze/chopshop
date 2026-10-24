# Extending job creation — the Run Job form, templates, and create-path branches

Read before adding a template, a form control, or a new kind of job filing in
chopshop-studio. The form (`app/views/jobs/new.html.erb`, ~3k lines) has ONE
spec pipeline; everything below is about joining it instead of starting a
second one.

## A contract seeded from a LITERAL leaks keys nothing owns

The Run Job form used to open on a hand-written `spec_default` literal carrying
`print_method`, a 6-ink `palette`, `geometry.allow_open_paths` and
`print.invert`. A template switch runs `PipelineConf.compose(key, into: base)`,
and `compose` clears only what the previous template OWNED — its levers
(`remove_decay` walks `BOUNDS`) and its static fragment (`ALL_STATIC_PATHS`). A
key that is neither a lever nor a template fragment is uncleard by construction,
so it survived EVERY switch: reported as "changing the job template type doesnt
clear the json... still have screenprint shit".

**Rule:** seed the form with
`PipelineConf.compose(PipelineConf::DEFAULT_TEMPLATE, into: {})`, never a
literal. Guard it with a test that every top-level key of that compose is owned
by `BOUNDS` or the template's `static_spec`, plus one that composes EVERY
template over it and asserts the unowned keys are absent.

## A page's setting does not reach the form through a bare link

The FLUX page's model control configures the generation SERVICE, but its head's
Run Job was a bare `new_job_path`. Nothing carried the choice, so an operator who
picked a hosted model there filed a job on the form's own default (`klein-4b`)
and was told nothing. When a page shows a setting the form also has, the link
must carry it (`?flux_model=…`, rewritten by a change listener) and the form must
VALIDATE it against the registry and open on the panel that shows it — a carried
model also switches the runner to a flux one, because the model's own control
lives in the flux panel and is otherwise hidden.

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
- **A model-following synchroniser runs INSIDE `updateModelGates()` and must NOT
  call `writePanels()` back.** `writePanels()` calls `updateModelGates()`, which
  calls each model-following sync (`enforceRefGate()`, `syncDimensionRules()`,
  `syncRegistry()`). A new sync that needs to refresh the composed spec must do
  it at the CALL SITE — the model-change listener, which IS `writePanels` — never
  by calling `writePanels()` from inside the sync: that closes the loop
  `writePanels → updateModelGates → sync → writePanels` and recurses to a stack
  overflow (`Maximum call stack size exceeded`). Rails renders no JS, so NO
  integration test sees it — it is a live browser-breaker, found only by
  executing the served script against a DOM or driving the live page (see
  `references/browser-interaction-verification.md`). Pin it with a source
  assertion over the EXTRACTED function body (`refute_match(/writePanels\s*\(/,
  body)`), proven to bite by re-adding the call.

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

## A popup that writes the form: two silent no-ops, and how to prove it works

The head's popups (PROMPTS recall, MASHUP, JSON contract) are the pattern for
anything that reads or writes the form from a dialog. They follow the same
"one spec path" rule: they write the prompt field and stop, never the spec.
Four traps, all measured:

1. **A popup calling an IIFE-private function is a SILENT no-op.** The page's
   main script is an IIFE, so `showKind()` and aether's `closePopup()` are not
   global. `window.showKind && window.showKind()` therefore does nothing at all
   -- no throw, no console line. It cost two separate bugs: a recalled prompt
   could fill a field in a HIDDEN panel, and the dialog stayed open covering the
   form it had just filled. **Export what you call**: `window.showKind = showKind`
   (page script) and `window.closePopup = closePopup` (aether.js, beside the
   existing `csRewireDynamic` export). Go through aether's `closePopup` rather
   than setting `el.hidden = true` by hand -- it is also what restores
   `body.overflow`, so hiding the node directly leaves the page unscrollable.
2. **Check the ROUTE VERB before writing the fetch.** `datasets#draw` is
   `get "datasets/draw"`; posting to it 404s. Read `config/routes.rb` (or
   `bin/rails routes`) rather than inferring from the controller's other
   actions.
3. **Markup assertions do not prove a request works.** "The button exists" and
   "clicking it works" are different claims, and every one of these bugs shipped
   green through tests that asserted the controls were present. Pin the REQUEST
   SHAPE (`assert body.include?("getJson('#{draw_datasets_path}'")`, and
   `assert_raises(ActionController::RoutingError) { recognize_path(path, method:
   :post) }` for the verb), or drive it in a browser.
4. **The textarea's RUNTIME position, not its markup position.** `portalPopups()`
   (`aether.js`) reparents EVERY `main .popup` to `<body>` on DOMContentLoaded (it
   escapes `.container`'s stacking context, which is why it exists). A form control
   that lands outside its form with no `form="…"` attribute is **not submitted**, so
   a popup carrying form fields stops posting its contents the moment it is portaled
   -- silently, with no throw. Moving the job contract into `#job-json-popup` did
   exactly this: every Run Job submit arrived with NO `job[spec]` key, `job_spec`
   returned `{}`, `Job#flux?` (kind-based, so still true) refused the empty prompt as
   **"a FLUX job needs a prompt"**, and the whole page was dead for every runner.
   `run_job_layout_test.rb` asserts the popup is inside the form and PASSES -- it
   reads static markup. **Detection: the production params.** Compare a working POST's
   `job` hash with the failing one (`grep 'Processing by JobsController#create' -A 2
   log/production.log`): a missing KEY, not a wrong value, is this bug.

   **FIXED** (studio #88, `84e53af`): `portalPopups()` now calls `reassociateFormControls()`
   BEFORE the move -- each control that belongs to the form it sits in gets an explicit
   `form="<the form's id>"`, the one HTML mechanism that survives a DOM move. It reads the
   owner with `closest("form")` while the popup is still in place, only re-points controls
   whose `el.form` is that form, and no-ops without a form id. Any NEW form-bearing popup
   is covered by that; a view-only `form="…"` on one textarea would not be.

   The pin is a SOURCE TRIPWIRE on the ORDER (re-associate, then `appendChild`) because
   Ruby has no JS runtime -- the real gate is a browser reading back the submission. Proven
   both ways: with the attribute `job[spec]` is present (137 chars), removed it is absent.

   **Root cause of the missed diagnosis: the dev server serves STALE PRECOMPILED assets.**
   `public/assets/` is gitignored build output, and Propshaft in development serves it in
   preference to `app/javascript/`, so an edit to `aether.js` has NO effect on a running dev
   server and a probe reports the OLD behaviour. Worse, the RUNNING server caches its digest
   map at boot: after deleting `public/assets` it keeps emitting digests whose files are gone
   (404) until it is restarted -- and a 404'd login asset makes the harness report
   `login was refused -- wrong password?`, which is a lie about the password. So: to verify a
   JS change, delete `public/assets`, RESTART the dev server, then confirm the page references
   a fresh digest before measuring anything.

   **A dev-DB form needs a Project.** `requestSubmit()` respects constraint validation, so it
   silently does nothing while the `required` project select is blank -- and `bin/rails runner`
   reading 0 rows then looks like "the submit did not file". Set the picker to `__new__` and
   fill `job[project_name]` first, or check `Array.from(form.elements).filter(e =>
   e.willValidate && !e.checkValidity())` before blaming the app.
5. **`assert_includes` is fooled by a comment.** `assert_includes body,
   "window.showKind = showKind;"` PASSED against `// window.showKind =
   showKind;` -- the substring is still there. Anchor to the start of a line
   with `assert_match(/^\s*window\.showKind = showKind;/, body)`. And prefer
   `assert body.include?(x), "why"` over `assert_includes body, x`: a failure on
   a full page dumps ~180KB of HTML into the terminal.

### Verifying the popups without a login

The app's session cookie is `secure`, so a browser on loopback HTTP will not
send it and every submit is a 422 `InvalidAuthenticityToken` -- the python
harness only works because it is told to send secure cookies over http. Two
ways through, both used here:

- **Layout/interaction, no session needed**: write the authenticated page's HTML
  to a file, inline the stylesheets it links (strip the `<script>` tags), append
  a probe that writes computed values into a `<pre id="result">`, and open it in
  the browser as `file://`. This is what confirmed the two-column grid
  (`515.5px 515.5px`, fields at x=97 and x=653, `.actions-row` spanning 1071px)
  and that `hidden` still wins on the other three panels.
- **The real thing**: log in through the page and deliver the session to the
  browser. Never type a password into the browser -- if there is no vault entry,
  stop and ask. For a click-path, reuse the operator's own session: log in with
  the repo's python harness, then `cdp('Network.setCookie', name:…, value:…,
  domain:"127.0.0.1", path:"/", secure:False, httpOnly:True)`.

  Caveat measured the hard way: a POST from an injected session 422s even with
  the page's own `csrf-token`, because the masked token does not verify against
  that session. Do NOT read that as a product bug -- reproduce the exact request
  from the python session first. `POST /mashup` with an `X-CSRF-Token` header and
  repeated `sources` params answered 200 with a real merged prompt, and
  `/remash` (temp 0.2→0.35) and `/revert` (back to 0.2) both worked, which is
  what cleared the popup's JS.

## "Two columns" means two CARDS, not a grid inside one card

When the ask is a multi-column page, look at what the other pages' TOP LEVEL is
before writing any CSS. Every page in this app whose content is columnar uses a
pair of sibling cards in `.run-grid` or `.grid-2` (`1fr 1fr`):

```erb
<form>
  <div class="run-grid">
    <div class="card run-form-col">  the form's own fields  </div>
    <div class="card run-kind-col">  the fields the job-type row swaps  </div>
  </div>
</form>
```

I built it the other way round — a two-column grid *inside* the single existing
card — which leaves the page one full-width card with a small grid in it. The
inner grid measures correctly (`515.5px 515.5px`), so every check I ran passed
while the page was not two columns in any sense the operator meant. **A
measurement that confirms the thing you built is not evidence that you built the
right thing**; compare the structure against a page that already does it.

Two consequences of the card split worth knowing:

- The panels must move to the second card, or switching the job type does not
  swap anything visible — the button row swaps a COLUMN now, not a section of one
  card. A test asserting "two cards, and all the `[data-run-fields]` live in the
  second" is what pins it.
- `.run-grid` is shared with the composite builder and New Project. Its base rule
  is already `1fr 1fr`, so the job page needs NO modifier — and any modifier that
  collapses it (`.run-grid--job`) must be deleted rather than left dead.

## The three things that state the job, and they must agree

The form names the job in three places at once: the **template picker** (what
shape of work), the **runner select** (whose kind decides which panel shows),
and the **contract textarea** (whose spec the run actually posts). Any two of
them disagreeing is a form that lies about what is about to run, and this has
now been the bug three separate times — applying a `bp` template while the panel
showed `generate`, a group control that narrowed without applying, and the
runner not following `DEFAULT_TEMPLATE`.

**Changing `DEFAULT_TEMPLATE` is a cross-cutting change, not a one-liner.**
It is read by the view (the contract's seed AND the notes' blurb), the helper
maps, the controller (`#new` chooses the opening runner), and a long tail of
tests. Setting it to a template of another KIND moves the opening runner with
it, because the runner select has to open on a runner of the default's kind or
the page opens on one kind's panel beside another kind's spec. When the default
became `generate_only` (flux) and the controller still picked by the old rule
("a generator is never the default even when it sorts first"), the form opened
on the artwork panel with a flux generation in the textarea.

So: **assert the AGREEMENT, not either side of it.** `assert_equal
PipelineConf.template_kind(DEFAULT_TEMPLATE), selected["data-kind"]` survives a
change of default; `assert_equal "svg", selected["data-kind"]` is a test that
pins today's default and has to be re-pointed every time. Four tests had to be
re-pointed for the last default change (the opening runner, the flux-job form
test, the layout contract test, and one whose assertion had become vacuous — it
checked the runner said something about a carried model, which stopped being
true once the form opened on the generator anyway).

Also state a test's OWN runner ENV when it asserts a kind: labels are
ENV-driven and `Job::RUNNER_DEFAULTS` always supplies `mock`, so with only that
configured the kind rule reads the fallback instead of the rule.

## Removing a control the page's own scripts drive

Replacing the two dropdowns with a button row worked **because the selects stayed
in the DOM, hidden**. The whole Apply round trip (`POST /templates/use`, the
composed spec, and the `data-levers`/`data-defaults` maps read off each option)
is unchanged, and the buttons are a second VIEW of one control rather than a
second control with its own copy of that data. Two rules fall out:

- **Keep one copy of the data.** The lever->control map stays on the OPTION, not
duplicated onto the buttons, where it would drift.
- **A control that moves on CLICK has to move BACK when the server refuses.**
The button row moved with the click, so a refused apply left the row naming
"Screen print" while the contract still held Generate only — the panel/contract
split, one level up. The handler records what the server actually composed and
restores the row to it on failure. Two ordering traps, both measured: the revert
repaints the notes and those write the blurb, so **revert FIRST, then write the
error**, or the refusal is overwritten by the template's own description; and
pin that order by POSITION (`assert_operator i_revert, :<, i_error`), because
both calls exist either way and only their sequence is wrong.

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
- Validate a composed spec against the SERVICE's OWN validator, not only the
  studio's model. `PipelineConf.compose` and the service's schema are two
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

## Adding a combined-feature template (e.g. iconography)

When a new template combines existing feature patterns (e.g. screen-print colour budget + sprite-style transparent square + hard-edged trace), build it from existing BOUNDS levers and a `spec` fragment for the unique settings (`geometry.allow_open_paths => false`, square dimensions). Never invent new levers unless the form has the control; a lever without a mapped control is a silent no-op. Add the entry to `TEMPLATES` and to the group's array in `GROUPS`, file the issue on `chopshop-studio` first (plan-first), seed with `PipelineConf.compose(key, into: {})`, and verify syntax with `ruby -c`. Keep it reversible: deleting the two lines (template + group entry) restores the previous state.
