# Run Job templates — the BOUNDS/TEMPLATES contract and compose semantics

The Run Job page's template picker composes a job SPEC server-side —
`PipelineConf.compose(key, into: base, overrides:)` wired up by
`pages#apply_template` (POST `use_template_path`) — and the form turns the result
back into visible panels through the ONE existing round trip
(`hydratePanels()` reads a spec into the controls, `writePanels()` writes them
back). A JS-side composer, or a template with its own DOM writer, is the exact
drift the design exists to prevent.

## A template is the CHOSEN SUBSET — compose clears what it does not own

Applying a template RESHAPES the contract to that template's subset. It is not
an additive patch and not a full form reset:

- **Every lever (a `BOUNDS` entry) the template does not expose is CLEARED** from
  the base spec at its `spec_path` (via `remove_decay`, before the template's
  own levers are written). `standard -> generate_only` drops `max_colors`,
  `print.sweep.*` and the geometry levers; going back to `standard` later drops
  the whole `flux` block and restores them.
- **Static fragments a DIFFERENT template wrote are cleared too.** Each
  template's `:spec` fragment registers its leaf paths in `ALL_STATIC_PATHS`, so
  `photo`'s `geometry.allow_gradients` and `generate_only`'s `flux.mode` go away
  the moment a template that does not restate them is chosen.
- **Keys no lever or static fragment points at SURVIVE**: a `palette`,
  `print_method`, a `validation` block, `print.invert`, `name`, an operator's
  pasted document. They have no `spec_path`, so the removal cannot see them.

`merge_deep!` runs AFTER the levers, so a lever always wins over a static
fragment; the whole thing still leaves `name`/`palette` alone.

## Editing BOUNDS / TEMPLATES — the removal set is implicit, so new levers auto-clear

The "levers a template does not expose get cleared" set is DERIVED from the
whole `BOUNDS` vocabulary and the union of every template's static fragment,
not listed per template. Consequences when you add to the vocabulary:

- **A NEW lever added to `BOUNDS` that no template exposes will be stripped out
  of every contract compose produces.** If it must persist under a template,
  list it in that template's `:levers`.
- **A NEW `:spec` static fragment registers its leaf paths in
  `ALL_STATIC_PATHS`, so it is auto-cleared whenever a template that does not
  restate it is chosen.**

Decision rule for a new value: "should this follow the operator's choice of
template?" If yes, make it a lever and expose it in every template that needs
it. If it is operator data that must survive any switch, keep it on a path that
no `BOUNDS` `spec_path` and no template `:spec` touches.

## The template's KIND drives the runner — and the form honors it

Each template declares a `kind` (`svg` / `flux` / `bp`; default `svg`) and ships
it as `data-kind` on the picker `<option>` (`PipelineConf.template_kind`).
Applying a template switches the runner to the first runner whose `data-kind`
matches, then calls `showKind()` to reveal that runner's panel — so a flux
template lands on a flux runner with the generation panel, never on a trace
runner with a stray `flux.*` block in the contract. `Job.form_runners` (the
runner `<select>` options, each carrying `data-kind`) is the single source that
both the form and the step-sequence builder clone; legacy `plot` / `blender`
kinds are folded into `bp` (`LEGACY_JOB_KINDS`) and are not offered to new jobs.

## The tests that pin it

`test/models/pipeline_conf_test.rb` and `test/models/pipeline_compose_test.rb`
pin the residue-clearing and key-preservation; `test/controllers/run_job_template_test.rb`
pins the end-to-end POST. Two older tests pinned the OLD add-only behavior
(`print.dpi` surviving under `standard`) and were rewritten — `dpi` is now
CLEARED. Do not "restore" the survival of a lever a template does not expose:
the operator explicitly wants a template switch to reflect only the chosen
subset.

## Pitfall: the Apply handler's order

Before POSTing, the Apply handler calls `writePanels()` so the panel values the
operator just moved win over the stale textarea copy. On success it sets
`specField.value = JSON.stringify(res.j.spec)`, then `hydratePanels()`, then
switches the runner by `data-kind`, then `showKind()`. Keep that ordering and
that single round trip.
