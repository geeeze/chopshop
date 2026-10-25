# UI control inventory — every form control and feature button, wired or not

Date: 2026-10-25 · Refs #16 (the UI integration audit).

This is the map the audit asked for: **every form control and feature button on
every page, traced to the code that consumes it and classified.** It is a
snapshot of the current tree (base `origin/main` 8c56525), not a snapshot of the
day the operator reported the problem. Several of the controls the original
audit table named have since been fixed or made honestly read-only; the stale
rows are listed at the bottom so the next pass does not re-audit them.

## Method

- Enumerated the controls in `app/views/**/*.erb` mechanically (a
  multi-line-aware scan for `<input>`, `<button>`, `<select>`, `<textarea>`),
  then read each page's own inline `<script>` block and the shared
  `app/javascript/aether*.js` / `graph.js` / `dataset_vocabulary.js` to trace the
  handler.
- "Wired" means: a route line, a JS listener, or a form target was found and the
  value reaches something the operator can see. Where the handler exists but
  cannot fire, that is **PARTIAL**, not WIRED.
- Controls that are intentionally non-editing (the JEV page after #42/#85, the
  read-only conf mirrors) are **INTENTIONAL-READ-ONLY**, not broken.
- Prose blocks that stand in for functionality are a separate class, tracked in
  #17/#80; they are counted per page in the summary but are not controls.

**Scope note.** The audit's own comment enumerated 1,238 controls from the live
DOM (it counted every `data-*` hook and every hint block). This pass enumerates
the *interactive* controls (303 across 24 view files) plus the runtime-generated
ones the drawer and modals build in JS. The difference is the hint/prose class,
which is not a control.

## Classification

| class | meaning |
|---|---|
| **WIRED** | a handler or route exists and the control's value reaches something visible |
| **UNWIRED** | the control renders and looks live, but nothing consumes it |
| **PARTIAL** | wired, but the result is invisible or wrong |
| **INTENTIONAL-READ-ONLY** | deliberately non-editing; the honest label says so |

## Summary

| page | controls | wired | unwired | partial | intentional-read-only | prose blocks |
|---|---|---|---|---|---|---|
| Run Job (`/jobs/new`) | 96 | 95 | 0 | 1 | 0 | ~78 |
| JSON spec builder (`/json`) | 62 | 62 | 0 | 0 | 0 | ~46 |
| BP (`/bp`) | 31 | 30 | **1** | 0 | 0 | ~31 |
| FLUX (`/flux`) | 16 | 15 | **1** | 0 | 0 | ~14 |
| JEV (`/jev`) | 18 | 10 | **1** | 0 | **7** | ~6 |
| Composites (`/composite`) | 29 | 29 | 0 | 0 | 0 | ~5 |
| Job page (`/jobs/:id`) | 14 | 13 | 0 | **1** | 0 | ~6 |
| Proof page (`/proofs/:id`) | 7 | 7 | 0 | 0 | 0 | ~4 |
| Projects (`/`) | 2 | 2 | 0 | 0 | 0 | 0 |
| Project workspace (`/projects/:id`) | 2 | 2 | 0 | 0 | 0 | 0 |
| New project (`/projects/new`) | 4 | 4 | 0 | 0 | 0 | 0 |
| Datasets (`/datasets`) | 2 | 2 | 0 | 0 | 0 | ~4 |
| Mashup (`/mashup/:token`) | 0 | — | — | — | — | — |
| Bug reports (footer popup) | 2 | 2 | 0 | 0 | 0 | 0 |
| Status (`/status`) | 2 | 2 | 0 | 0 | 0 | ~5 |
| About (`/about`) | 0 | — | — | — | — | ~8 |
| Graph (`/graph`) | 6 | 6 | 0 | 0 | 0 | 0 |
| Audit (`/audit`) | 0 | — | — | — | — | ~4 |
| Layout chrome (every page) | 3 | 3 | 0 | 0 | 0 | 0 |
| Login (`/login`) | 7 | 7 | 0 | 0 | 0 | 0 |
| Colour map (schema + composite) | 5 | 5 | 0 | 0 | 0 | 0 |
| Scrapbook favourite (shared) | 1 | 1 | 0 | 0 | 0 | 0 |
| **total** | **309** | **297** | **3** | **2** | **7** | ~200 |

The literal ERB tag scan finds **303** `<input>/<button>/<select>/<textarea>` tags;
the other 6 are Rails-helper fields (New project's four) and the job page's two
feature-button anchors. The spread is narrow, not epidemic: 297 of 309 are wired.
Three controls render and look live but drive nothing, and two are wired but
inert — a label that never relabels itself and a viewer branch that never fires.

---

## Run Job — `/jobs/new` (`app/views/jobs/new.html.erb`, 96 controls)

| control | selector / id | looks like | trace | class |
|---|---|---|---|---|
| Run Job | `#runJobBtn` | starts the run | confirm dialog → `#new-job-form` submit (`:1791`, `:1805`) | WIRED |
| Compose | head link | opens the builder | `new_composite_path` | WIRED |
| PROMPTS | `data-popup="prompts-popup"` | recall a filed prompt | `openPopup` (`aether.js:1775`); recall writes `flux_prompt` (`:3740`) | WIRED |
| MASHUP | `data-popup="mashup-popup"` (head + beside the prompt field) | merge ideas into a prompt | `POST /mashup` → `putPrompt` (`:3775-3847`) | WIRED |
| JSON | `data-popup="job-json-popup"` | the contract as JSON | `writePanels()` on open (`:985`) | WIRED |
| project picker | `[data-project-picker]` | choose / create a project | reveal (`:98`); posts `project_id` | WIRED |
| Job group | `#job_group` | narrows the template list | `syncTemplateGroup` → Apply (`:1523`) | WIRED |
| Job shape | `#job_template` | picks a template | Apply → `POST /templates/use` (`:1681`) | WIRED |
| Apply | `#tplApplyBtn` | applies the template | `fetch(use_template_path)` (`:1699`) | WIRED |
| job-type row | `.job-type-btn[data-job-type]` | picks a job type | `syncJobTypeButtons` → Apply (`:1629`) | WIRED |
| **job-type label** | `#jobTypeLabel` | relabels itself to the group's shape | **JS reads `#jobTemplateLabel`, which does not exist** (`:1506` vs `:185`) → the relabel is inert | **PARTIAL** |
| Runner | `#job_runner` + `.mode-btn` | picks the runner | `showKind()` / `writePanels()` (`:1846`, `:1898`) | WIRED |
| Source kind | `#job_source_kind` + `.mode-btn` | raster / vector / prompt | `showKind()` (`:1846`) | WIRED |
| Job name | `#job_name` | names the run | posts `job[name]` | WIRED |
| Source upload | `#sourceFile`, `#thumbRemove` | upload / remove the artwork | `POST /jobs/upload` → `applySource` (`:1432`) | WIRED |
| carried path | `#inputPathField` | hidden source path | `applySource` (`:1415`) | WIRED |
| FLUX prompt | `#flux_prompt` | the generation prompt | `fluxBlock()` (`:2014`) | WIRED |
| FLUX reference | `#fluxRefFile`, `#fluxRefRemove`, `#fluxRefAdd` | img2img reference | `refNames` / `enforceRefGate` (`:2067`) | WIRED |
| FLUX size / mode | `#flux_width`, `#flux_height`, `#flux_mode` | dimensions and trace-or-raster | `fluxBlock()` (`:2014`) | WIRED |
| FLUX settings | `data-popup="flux-settings-popup"` | deeper generation settings | `writePanels()` (`:1054`) | WIRED |
| FLUX model | `#flux_model` | picks the checkpoint | `syncSchedule` / `fluxBlock` (`:1998`) | WIRED |
| FLUX seed/steps/guidance/strength/images | `#flux_seed`, `#flux_steps`, `#flux_guidance`, `#flux_strength`, `#flux_images` | generation knobs | `fluxBlock()` (`:2014`) | WIRED |
| FLUX negative prompt | `#flux_negative_prompt` | steering | `negpromptModel()` gate (`:2025`) | WIRED |
| FLUX LoRA | `#flux_modifiers`, `#flux_modifier_scales`, `#flux_vae` | adapters and decoder | `syncRegistry` / `fluxBlock` (`:1960`) | WIRED |
| Plot operation | `#plot_op` | which plot operation | `plotBlock()` (`:2095`) | WIRED |
| Plot document / runs | `#plot_doc`, `#plot_runs` | the pasted document / records | `parseJsonField` (`:2067`) | WIRED |
| Blender document | `#blender_doc` | the scene document | `blenderBlock()` (`:2137`) | WIRED |
| BP operation | `#bp_op` | which of the six operations | `bpBlock()` (`:2193`) | WIRED |
| BP document / runs | `#bp_doc`, `#bp_runs` | the pasted document / records | `parseJsonField` (`:2067`) | WIRED |
| BP render block | `#bp_render_width/height/background/projection/elevation/azimuth/views/engine/depth/bevel_depth` | the 3D render block | `applyBpRenderControls` (`:2278`) | WIRED |
| Proof variants | `#proof_variants`, `#proof_variant_transforms` | build a training set | `writePanels` (`:2695`) | WIRED |
| Prompt source | `#prompt_source`, `#prompt_topic` | typed / random prompt | `applyPromptSourceFromTemplate` (`:509`) | WIRED |
| Sequence | `#seq_on`, `#addStepBtn` | a multi-step chain | `readSteps()` / `addStep` (`:2439`) | WIRED |
| step rows | `[data-step-*]` (runtime) | add / move / delete a step | `stepsList` listener (`:3562`) | WIRED |
| Copy JSON | `#copySpecBtn` | copy the contract | `navigator.clipboard` (`:1476`) | WIRED |
| Prompts recall | `.prompt-recall` | put a prompt back | `putPrompt` (`:3747`) | WIRED |
| Mashup | `#mashupGoBtn`, `#mashupAgainBtn`, `#mashupRevertBtn`, `#mashupDrawBtn`, `#mashupUseBtn`, `#mashupSources`, `#mashupPrompt` | mash / re-mash / revert / draw / use | `POST /mashup`, `/remash`, `/revert`, `GET /datasets/draw` (`:3775-3847`) | WIRED |
| `?` help | `.help-btn[data-help-target]` | explains a block | `openCsModal` (`aether.js:1888`) | WIRED |

---

## JSON spec builder — `/json` (`app/views/pages/schema.html.erb`, 62 controls)

Every control writes the spec through the one `build()` (`:892`) and the
`specOutput` terminal is what Run Job posts (`useSpecBtn` → `POST /json/use`,
`:1073`). All **WIRED**.

| group | controls | trace |
|---|---|---|
| Job spec | `#f_print_method`, `#f_min_stroke`, `#f_max_nodes`, `#f_raster_embed`, `#f_gradients`, `#f_open_paths`, `#f_preset_bw/poster/photo`, `#f_sweep_max`, `#f_speckle`, `#f_hier_cutout/stacked` | `build()` (`:892`) |
| Print & tolerances | `#f_dpi`, `#f_ink_limit`, `#f_white_ink`, `#f_ink_merge`, `#f_ramp_min_members`, `#f_proof_variants` | `build()` (`:892`) |
| Prep | `#f_invert`, `#f_invert_mode`, `#f_prep_opaque_bg`, `#f_prep_colors`, `#f_pe_filters`, `#f_pe_filters_presets`, `#f_pe_filters_sheet`, `#f_pe_filters_alpha`, `#f_pe_filters_spec`, `#f_pe_tune`, `#f_pe_tune_presets`, `#f_pe_tune_cells`, `#f_pe_tune_sheet`, `#f_pe_tune_speckle`, `#f_pe_tune_hier`, `#f_pe_tune_nr`, `#f_pe_nr`, `#f_pe_nr_nodes`, `#f_pe_nr_tolerance`, `#f_pe_nr_tolerance_cap`, `#f_pe_nr_verify` | `build()` (`:892`) |
| Colour spec | `#f_pitch_shift`, `#f_use_palette`, `#f_bg_hex`, `#f_bg_swatch`, `#f_max_colors`, `#f_substrate_hex`, `#f_substrate_swatch`, `#f_substrate_index`, `#f_palette` | `build()` + `syncSubstrate` (`:744`) |
| Palette map | `#pal_presets_btn`, `.cmap-cell`, `.pal-preset`, `.pal-add-one`, `.pal-set-bg` | `openColourMap` / delegated (`:786-880`) |
| Actions | `#useSpecBtn` (Run Job), `#copySpecBtn`, `.popup-close` | `submitSpec` / `clipboard` (`:1060`) |
| `?` help | `.help-btn[data-help-target]` | `aether.js:1888` |

---

## FLUX — `/flux` (`app/views/pages/flux.html.erb` + `_flux_fields`, 16 controls)

Every card field carries `data-flux-field`; `build()` (`:449`) reads them into
`fluxConfOutput`. All **WIRED**.

| group | controls | trace |
|---|---|---|
| Service / Model / Resolution / Hand-off / GPU cards | `data-flux-field` × 24 (bind, port, out_dir, token, url, model, steps, guidance, negative_prompt, strength, offload, vae_tiling, ack_noncommercial, width, height, images, pipeline, sweep, skip_prep, guard, guard_vram_gb, guard_wait, guard_poll, lmstudio_url) | `build()` (`:440`); `syncSchedule` on model change (`:628`) |
| Run Job link | `#fluxRunJobLink` | rewrites href with the chosen model (`:18`) | 
| MODELS / DATASETS / JSON | `data-popup` | `aether.js:1775`; DATASETS fetches `/datasets/surface` (`:48`) |
| Copy conf | `#copyFluxConfBtn` | `clipboard` (`:676`) |
| **default negative prompt** | `#f_flux_default_negative_prompt` | the service's default negative prompt | **nothing reads it** — `build()` composes `negative_prompt`, never this; its own help says "Read, not edited" | **UNWIRED** |
| `?` help | `.help-btn[data-help-target]` | `aether.js:1888` |

---

## BP — `/bp` (`app/views/pages/bp.html.erb`, 31 controls)

Two halves, each with its own conf composer. All **WIRED**.

| group | controls | trace |
|---|---|---|
| Plot cards (Service, Operations, Charts, Geometry) | `data-plot-field` × 17 | `build()` (`:1019`); static facts are display-only, never read |
| Plot Checks | `data-plot-field` = op/chart/x/y/color | `check()` (`:968`) → `#plotCheckVerdict` / `#plotCheckProblems` |
| Blender cards (Service, Operation, Scene, Render, Responses) | `data-blender-field` × 15 | `build()` (`:1214`) |
| Blender Checks | `data-blender-check` = document/views/engine | `check()` (`:1152`) → `#blenderCheckVerdict` / `#blenderCheckProblems` |
| FIELDS / JSON | `data-popup` | `aether.js:1775` |
| Copy conf | `#copyBpPlotConfBtn`, `#copyBpBlenderConfBtn` | `clipboard` (`:1100`, `:1309`) |
| Example spec copy | `.bp-example-copy[data-bp-example-copy]` | `clipboard` + `script[data-bp-example-json]` (`:698`) |
| **Blender background** | `#f_blender_render_background` | the frame's background colour | **nothing reads it** — `build()` reads only the env block and the Checks card's views/engine; its four siblings on the card are `:static` | **UNWIRED** |
| `?` help | `.help-btn[data-help-target]` | `aether.js:1888` |

---

## JEV — `/jev` (`app/views/pages/jev.html.erb` + `_jev_conf_fields`, 18 controls)

#42 made the question blocks, the confidence floor and the metrics list
read-only: they mirror `chopshop-jev`'s own constants and the annotator has no
flag that reads them. They are **INTENTIONAL-READ-ONLY**, not broken. The conf
popup still composes the JSON from them (the honest "copy the value out"
pattern) and its copy button works.

| control | selector / id | looks like | trace | class |
|---|---|---|---|---|
| TABLE | `data-popup="jev-remediation-popup"` | view / edit `remediation_table.json` | `openPopup` (`aether.js:1775`) | WIRED |
| JSON | `data-popup="jev-conf-popup"` | view / edit `jev.conf.json` | `write()` on open (`:467`) | WIRED |
| 4 question blocks | `_jev_conf_fields` — type select, question input, instructions textarea, criteria value/desc inputs | edit the annotator's questions | `conf()` reads them (`:405`); every control is `readonly`/`disabled` (#42) | INTENTIONAL-READ-ONLY |
| Confidence floor | `#cf-floor` | tune the floor | `conf()` reads it (`:405`); `readonly` (#42) | INTENTIONAL-READ-ONLY |
| Metrics | `#cf-metrics` | edit the metrics list | nothing reads it; `readonly` (#85) | INTENTIONAL-READ-ONLY |
| Remediation working copy | `#jevRemediationOutput` | edit a copy of the table | a designed copy-out flow; no write-back | INTENTIONAL-READ-ONLY |
| **Copy (remediation)** | `#copyJevRemediationBtn` | copy the working copy | **no handler anywhere** — the only `.copy-ghost` button with none | **UNWIRED** |
| Copy (conf) | `#copyJevConfBtn` | copy `jev.conf.json` | `clipboard` (`:456`) | WIRED |
| `?` examples | `.help-btn[data-jev-examples]` | examples for a question | `openExamples` → `CsModal` (`:370`) | WIRED |

---

## Composites — `/composite` (`app/views/composites/show.html.erb`, 29 controls)

All **WIRED**.

| group | controls | trace |
|---|---|---|
| Head | `#compRunJob` | save → flatten → hand off to Run Job (`:1349`) |
| Project picker | `[data-project-picker]` | reveal (`:60`) |
| Name / size / background | `#compName`, `#compWidth`, `#compHeight`, `#compBg`, `#compPalette`, `#compPaletteBtn` | form posts; colour map (`:1257`) |
| Layers | `data-comp-action` (add-blank / add-scrapbook / add-upload), `#compUpload`, `.comp-layer-name`, `data-comp-vis/up/down/del`, `.comp-num`, opacity/hue ranges, `data-comp-kind`, `data-comp-uncouple` | layer-list listener (`:906`) |
| Canvas modes | `data-comp-couple`, `data-comp-crop`, `data-comp-crop-reset`, `data-comp-template` | `:1002-1012` |
| Workspace / Flatten | `data-comp-action="workspace"`, `data-comp-action="flatten"` | `:1014-1020` |
| Scrapbook picker | `[data-comp-add-scrap]` | `:1060` |
| Delete | `button_to :delete` | `DELETE /composite/:id` |

---

## Job page — `/jobs/:id` (`jobs/show.html.erb` + `_row` + `_card` + `_process` + `_source_stack`, 14 controls)

| control | selector | looks like | trace | class |
|---|---|---|---|---|
| Refresh / ← Project / composite link | links | navigate | `refresh_job_path`, `project_path`, `composite_path` | WIRED |
| List/Grid | `[data-cand-view]` | switch candidate view | `apply()` (`jobs/show.html.erb:797`) | WIRED |
| Findings | `[data-cs-detail]` | per-candidate detail | `CsModal` + `GET /jobs/:id.json?candidate=` (`:900`) | WIRED |
| Proof detail | `data-popup="proof-detail-<id>"` | the proof popup | `aether.js:1775` | WIRED |
| Cancel / delete | `[data-cs-job-action]` | cancel or delete the run | `wireJobActions` (`aether.js:829`) | WIRED |
| Preview tiles | `[data-cs-view]` | view a candidate | `aether.js:755` | WIRED |
| Ask Jev | `.jev-btn[data-jev-url]` | ask the sidecar | `askJev` (`aether.js:1849`) | WIRED |
| **Process / results tiles** | `data-cs-view="image"` (`_process.html.erb:75,102`) | view a non-SVG step output | **the viewer has no `image` branch** — anything that is not `svg` falls into the JSON branch and reports "Could not load." (`aether.js:773-790`) | **PARTIAL** |

---

## Proof page — `/proofs/:id` (`validations/show.html.erb` + `_proof_detail`, 7 controls)

All **WIRED**.

| control | selector | trace |
|---|---|---|
| Ask Jev | `.jev-btn[data-jev-url]` | `askJev` (`aether.js:1849`) |
| manifest / proof-gates | `data-popup` | `aether.js:1775` |
| Refresh / ← job / downloads | links | `refresh_validation_path`, `job_path`, `file_job_path` |
| Proof render / training sheet | `[data-cs-view]` | `aether.js:755` |
| Proof detail (shared partial) | `data-popup` | `aether.js:1775` |

---

## Other pages

| page | controls | class | trace |
|---|---|---|---|
| Projects (`/`) | 2 (`data-view-toggle` ×2) | WIRED | `apply()` (`projects/index.html.erb:126`) |
| Project workspace (`/projects/:id`) | 2 | WIRED | `apply()` (`projects/show.html.erb:161`) |
| New project | 4 (name, is_test, submit, cancel) | WIRED | `form_with model: @project` → `POST /projects` |
| Datasets (`/datasets`) | 2 (`data-vocab-more` ×2) | WIRED | `dataset_vocabulary.js:133` |
| Mashup (`/mashup/:token`) | 0 | — | JSON-only surface, no controls |
| Bug reports (footer popup) | 2 (kind select, submit) | WIRED | `POST /reports` (`aether.js:2036`) |
| Status (`/status`) | 2 (EVENTS link, ML popup) | WIRED | `events_path`, `aether.js:1775` |
| About (`/about`) | 0 | — | plain `link_to`s only |
| Graph (`/graph`) | 6 (find, 4 kind checkboxes, hops, labels, relax, fit) | WIRED | `graph.js:570-588` |
| Audit (`/audit`) | 0 | — | plain `link_to`s only |
| Layout chrome | 3 (scrapbook toggle, frame cycle, engine light, logout) | WIRED | `aether.js:890-1040`; `button_to :delete` |
| Login (`/login`) | 7 (orb, password, submit, 3 tune sliders, reset) | WIRED | inline script (`login.html.erb:43+`) |
| Colour map | 5 (cells, preset hit, add-one, set-bg) | WIRED | schema/composite inline scripts |
| Scrapbook favourite | 1 | WIRED | `aether.js:1099` |
| Scrapbook drawer (runtime) | thumbnails, delete, trace, edit, tools, reset | WIRED | `aether.js:1210-1240`, `:1634` |

---

## Dispositions

### UNWIRED (3)

| control | proposed disposition |
|---|---|
| `#copyJevRemediationBtn` (`pages/jev.html.erb:332`) | **wire it** — one line, identical to the five working copy buttons: `var b = document.getElementById('copyJevRemediationBtn'); if (b) b.addEventListener('click', function () { navigator.clipboard.writeText(document.getElementById('jevRemediationOutput').value); });`. The remediation working copy is the only `.copy-ghost` button with no handler. |
| `#f_flux_default_negative_prompt` (`pages/flux.html.erb`, Model card) | **hide it as a control** — make the field `:static` (a value, like the BP cards' facts) or add `readonly`. Its own help already says "Read, not edited: this is the mirror of what the service would apply", so the input is the lie. `test/controllers/flux_page_test.rb:699` pins `:text`; that assertion is the one to change. Same shape as #85's fix for the JEV `#cf-metrics`. |
| `#f_blender_render_background` (`pages/bp.html.erb`, Blender Render card) | **hide it as a control** — make it `:static` to match its four siblings on the card (size, views, engine, export), or wire it into the composed document. As it stands the operator can type a colour the composer never reads. |

### PARTIAL (2)

| control | proposed disposition |
|---|---|
| `#jobTypeLabel` (`jobs/new.html.erb:185`) vs the JS's `#jobTemplateLabel` (`:1506`) | **wire it** (align the id) — the guided-choice relabel ("Job shape" / the group's sub-label) is dead code today. Either rename the span to `#jobTemplateLabel` or change the script to `#jobTypeLabel`; the latter is the smaller diff and keeps the label's own meaning. |
| `data-cs-view="image"` (`jobs/_process.html.erb:75,102`) | **wire it** — the viewer's branch is `svg` vs JSON; `image` falls into the JSON branch and reports "Could not load." Add an `image` branch that opens the `<img>` modal (the same body the `svg` branch builds), or make the view emit `svg` for images too. The latter is a one-line view change and matches how every other image tile is marked. |

### INTENTIONAL-READ-ONLY (7)

The JEV page's question blocks (4), the confidence floor, the metrics list and the
remediation working copy. They mirror `chopshop-jev`'s own constants; the page
says so on the card (the `code · read-only` scope chip, #42) and the conf popup's
copy button is the honest way to take the value out. No disposition needed —
this is the fix, not a gap.

---

## Stale rows in the original #16 audit table

The audit comment's table is now wrong on four rows. This inventory replaces them:

| audit row | then | now |
|---|---|---|
| `/jev` question blocks + `confidence_floor` — **WIRED** | editable form | **INTENTIONAL-READ-ONLY** (#42): `readonly`/`disabled`, with the scope chip saying so |
| `/jev` `#cf-metrics` — **DEAD** | editable, nothing read it | **INTENTIONAL-READ-ONLY** (#85): `readonly`, labelled a reference |
| `/jobs/new` JSON + `/status` ml-popup `popup-wide` backdrops — **DISGUISED** | width cap on `.popup` | **fixed**: every `popup-wide` now sits on `.popup-panel` (`application.css:4539`), so the backdrop is full-viewport |
| `/jobs/new` four `%>}` brace leaks — **DEAD render** | 4 stray `}` in the DOM | **fixed**: no `%>}` remains in the view |
| `/jobs/new` MASHUP trigger — **DISGUISED** | head only | **fixed**: a second door sits beside the FLUX prompt field (`:458`) |

The two rows the audit got right and this pass confirms: the BP Checks cards are
live query surfaces (#42), and the `popup-wide` fix is the shared-component
change #82 named.

---

## Limits

- The counts are of *interactive* controls (303). The audit's 1,238 included
  every `data-*` hook and every hint block; the hint class is prose, not
  controls, and is tracked in #17/#80.
- Runtime-generated controls (the scrapbook drawer, the CsModal toolbox, the
  composite layer rows) are counted once at their generator, not per instance.
- "Wired" was verified by reading the handler and its target, not by driving a
  browser. All five defects found are cases where the handler is absent or
  cannot fire, which is a code-level fact.
