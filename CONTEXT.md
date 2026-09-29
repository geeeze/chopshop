# CONTEXT.md — chopshop-studio

Working state for agents and humans: what is in flight, what is blocked, and
the caveats that are not obvious from the code. Update this as work lands.

**Repo visibility: private.** Host-specific deployment facts may live here but
must be tagged `HOST-SPECIFIC` (see `skills/README.md` and the
`sync-skills` convention) — subject to change, remove before reuse elsewhere.

## UI standard: the page header (canonical: the Jobs page)

The Jobs page's header is the reference format every page's head should follow.
It is the best-balanced title/subtitle/action layout to date — mirror it, do not
re-invent it.

- **50/50 split.** Title + subtitle own the LEFT half; the action button(s) own
  the RIGHT half. `.page-head-row--stacked` is a `grid-template-columns: 1fr auto`
  grid: `.section-title` is pinned row 1 col 1, the blurb row 2 col 1, the
  primary action row 1 col 2, and secondary controls row 2 col 2 (right-aligned
  with `justify-self: end`).
- **Title.** `.section-title` + `.gradient-text` — `clamp(2rem, 4vw, 3.2rem)`,
  weight 800, gradient across the word. Subtitle is `.page-head-blurb`
  (`--text-secondary`, `max-width: 67%`; the Jobs page uses the `--long` variant).
- **Larger primary action.** "Run Job" is a `.btn.btn-primary.head-action` —
  the LARGEST button in the head (2.75rem tall / 98×44px measured, plus the
  conic glow ring at `inset: -3px` and the ambient `0 20px 60px` glow). The
  accent button is deliberately bigger and brighter than everything beside it.
- **Buttons underneath.** Secondary controls (e.g. the List/Grid view toggle)
  sit DIRECTLY BENEATH the primary, in row 2 col 2 — never beside it, never in
  the title cell. They are small `.btn-secondary` controls, NOT `.head-action`s.
- **Frosted glass.** Secondary controls are frosted: `.btn-secondary` carries
  `backdrop-filter: blur(10px)` over a translucent `--surface` fill, so the
  particle field reads through them.
- **No margin between grouped buttons.** A set of mode buttons is ONE segmented
  control: `.view-toggle { display: inline-flex; gap: 0 }` with square inner
  edges and rounded outer corners only, and `margin-left: -1px` on the second
  half so the two 1px borders collapse into one. They touch; they are one box
  with two stops, not two buttons with air between them. Pinned by
  `jobs_grid_test.rb` (`gap: 0` assertion).

A visual change is a contract change: the header shape is pinned by
`page_head_uniformity_test.rb`, `responsive_head_test.rb`, `head_alignment_test.rb`
and `head_action_size_test.rb` — changing the title, blurb, button size or
arrangement means updating those lists and re-running the suite.

## What this repo is

Chopshop Studio, the Rails 8.1 operator front end for the chopshop pipeline
(private demo). The operator uploads a raster, the runner produces traced SVG
candidates, the operator picks one, and that pick is proved: proof PNG, print
PDF, manifest. The pipeline never picks a winner; the studio is the surface
where the human makes that call.

## Work in progress

- **The left column is a FRAME with two panels (landed).** The composites panel
  was in the layout from `53072b9` and could never be seen: nothing ever gave it
  an `.open` class (its only geometry was `.scrapbook-sidebar`'s
  `translateX(-100%)`), while the inline cycle script that shipped with it
  toggled the `hidden` attribute — and a `hidden` panel is STILL off-screen, so
  it looked identical to a working one. Dead feature, green suite, no test
  covering it. It is now ONE frame: `frameApply`/`frameCycle` in `aether.js` own
  the state (`scrap` / `both` / `comp` / `none`), drive the same `.open` class
  the CSS and `body.scrapbook-open` already read, and the close orb on whichever
  panel is showing advances it (double-click closes the frame). The order is
  star → scrap → both → comp → none: every state is reachable from a control
  that is on screen while you are in it, and the committed order (`both` → comp
  → scrap → close) could not reach `comp` at all. Both panels up
  (`body.frame-split`) SPLIT the column — scrapbook top band, composites bottom.
  The composites panel is the NAVIGATION frame over the composites table
  (`/composite/list`, each row opening `/composite?id=N`), not a second store.
  Pinned by `test/controllers/frame_cycle_test.rb`, which asserts the MECHANISM
  (which class, which states, which control) because that is what a green suite
  missed. Verified in a browser: the cycle, the two bands, the page share and
  the restore across navigation.

- **A flattened composite is a JOB (landed, live).** Compose work used to live
  only as a Composite row plus a scrapbook item, so agent-made composites and
  albums appeared NOWHERE in `/jobs` and clicking their image led to no results
  page. Both flatten paths now record a Job — created ALREADY DONE, because the
  merge has happened — filed against the label whose URL owns the `/compose`
  route, with `spec["compose"]` carrying the composite, its mode, its palette and
  the layers it was made of. `Job#compose?`, `#compose_output_file`,
  `#locally_produced?`; the results page renders the merged document with a link
  back to the composite. **`locally_produced?` is the guard every runner-backed
  action must ask first** — a compose job never dispatched anything, so building
  an archive URL for it puts a nil runner id in a path. Pinned by
  `test/controllers/compose_job_test.rb` (6 tests).
- **A test assertion must be scoped to the test, not to the BOX.** Two more
  assertions were pinning the uploads bug: they asserted global emptiness (or a
  global count) of a `flux_inverse_*.png` glob in the LIVE uploads directory,
  which only ever held while the cleanup was deleting the operator's own files.
  Assert on what the test ADDED (a before/after delta), never on the size of a
  shared directory.

- **The Composite builder composes (landed).** Four faults, all found by driving
  the feature as an agent and none visible to the suite: `composite_path(@composite)`
  redirected to `/composite.5` (id swallowed as a format suffix); migration
  `20260928000500_add_palette_to_composites` was **never applied to production**,
  so every create 500'd; `compose_base_url` picked `labels.first` and `mock` is an
  svg-KIND runner whose URL sorts first, so every vector composite was composed
  against the MOCK (no `/compose`, `404 unknown route`); and
  `ComposeClient#parse_svg` required the body to start with `<svg` while the
  operation answers with an XML declaration first, rejecting a 200 that carried
  the right bytes (`PlotClient` had the same guard and the same fault). Pinned by
  `test/controllers/composite_wiring_test.rb`.
- **A test cleanup must never glob the LIVE uploads directory (landed).** Five
  helpers deleted by prefix in `storage/uploads` — the real directory a live
  job's raster and a bp job's drawing live in — so every suite run silently
  emptied them and those rows' thumbnails 404'd until someone re-checked the live
  page. All now go through `UploadsSandboxHelper` (`test/test_helper.rb`): snapshot
  in setup, delete only what THIS test added and matches its prefix. **When you
  find one of these, grep for the whole class** — fixing the three you found is
  not the same as closing it, and the second sweep is what found `plot_*.svg`.
  Verify with a colliding sentinel file that must survive a full run.
- **A job's drawing is REPRODUCIBLE, so a lost artifact is repairable.** Every bp
  job records the document it drew and the filename it drew it to, so re-posting
  that document to the service and writing the answer back under the recorded name
  restores the row without duplicating it in the history. `repair_drawings.py`
  lives in the agent scratch dir. The wire shape, measured: `{op, spec, runs?}` —
  document under `spec`, a query's records as a top-level SIBLING `runs` (nested
  inside `spec` it is refused with "query needs a 'runs' field"), and the op picks
  the URL PATH.
- **`~/.hermes/.env` had a shell syntax error that broke every tool sourcing it.**
  A value ending in a bare `>` (`JEV_API_KEY=…b7>`) is parsed as a REDIRECTION, so
  `. ~/.hermes/.env` failed with "Syntax error: newline unexpected" — and
  `git-credential-hermesenv` sources that file, so it silently served no
  credential and every `git push` failed with `could not read Username`. The fix
  is to QUOTE the value; a helper that sources a config file inherits every syntax
  error in it.

- **The ambient effects are seeded by the pointer (landed).**
  `app/javascript/aether-entropy.js` is one polled source of randomness: a single
  passive `pointermove` listener (plus a `mousemove`+`touchmove` fallback only for
  an engine without `PointerEvent`) records where and when, and a consumer asks for
  a number when it wants one — `poll()`, `coin()`, `activity()`, `motion()`,
  `stats()`. No timer, no work per event, and no DOM writes of its own: the effects
  keep writing the same custom properties they always did.

  Two consumers. The background particle field draws every spawn value through it
  (a page load's single PRNG sequence was why two visits looked alike) and gains a
  bounded **breeze**: pointer motion bends the field, and the per-axis displacement
  is clamped to the same 0.4 px/frame the spawn already used, so a stirred field is
  never faster than the one that shipped — with the hand still, `activity()` is
  exactly 0 and the field is bit-for-bit the old one. The login orb's sunspot drift
  takes its ebb/flow coin from it and scales the walk step by 0.75x..1.25x
  depending on how busy the last minute was; the `[min, max]` clamp still owns the
  range, and the balance walk is untouched (its direction is state, not a coin).

  Measured on the rendered page: a busy tick walked 0.227s (1.25x, the top of the
  band) and a still tick 0.136s (0.75x, the bottom), both inside the clamp; each
  tick called the polled coin twice and `Math.random` **zero** times. Pinned by
  `pointer_entropy_test.rb`; the ranges themselves by `sunspot_weather_test.rb` and
  `background_budget_test.rb`.

- **The operator surfaces now mirror chopshop-svg's hardened Layer A (landed).**
  `geometry.allow_gradients` became a real Layer A gate on the svg side (a
  two-stop gradient used to pass the source-level gate with zero findings and only
  Layer B's rendered ink count caught it), raster-embed detection widened beyond
  `<image>`, the colour budget learned the implicit black fill and `currentColor`,
  `!important` is ranked, and `filter`/`mask`/`clip-path` references are now a
  NOTE. Four surfaces were brought in line in one pass: the JSON page's
  `allow_gradients`/`allow_raster_embed` hints and their `?` help blocks name the
  gate IDs (`GRADIENT_NOT_ALLOWED`, the broader `RASTER_EMBED`, advisory
  `EFFECT_REFERENCE`); the proof page's cleared-gates checklist carries the
  gradient gate and routes the three advisory tags into its "not cleared" list;
  the About page's Layer A paragraph matches the new counting; and the Run Job
  preset hint states the gradient consequence. No page head, blurb, button or
  column changed.
- **Both builders expose the `-svg` spec keys they used to omit (landed).** The
  `print.prep_expand` sub-keys the pipeline always honoured but the UI never
  offered are wired on the JSON page and the Run Job panel — `filters.keep_alpha`,
  `filters.spec`, `tune.filter_speckle`, `tune.hierarchical`,
  `tune.with_node_reduce`, `node_reduce.tolerance`, `node_reduce.tolerance_cap` —
  each written only when set, so an untouched form still composes the same
  contract. Also added: `print.ramp_min_members` (beside `ink_merge_tolerance`),
  `print.assume_opaque_bg` and `print.prep_colors` (Prep card + the popup's raster
  pass), and `print.substrate` / `print.substrate_index` on the Colour Spec card —
  the fabric colour the runner's `front_common.substrate_hex` implements and the
  proof page already DISPLAYED, with no way to author it until now (an explicit
  `substrate` hex wins over the index; the page keeps them mutually exclusive).
  `validation.variants` can now be a subset request (`{enabled: true,
  transforms: [...]}`) instead of only a bare `true`.
  - Two defaults were wrong and are fixed: the JSON page pre-selected
    `count_white_as_ink: true` against the documented default of false (and
    implied `dark_garment_underbase` with it), and the Run Job default contract
    carried `print.sweep_max_candidates` while the form's own sweep panel writes
    `print.sweep.max_candidates` — two caps in one contract. The default now
    writes the namespaced key only.
  - Three defects the new controls exposed, all fixed: the FLUX popup's raster
    pass read two non-existent elements (`pe_tune_sheet`, `pe_nr_verify`), so every
    tune block it composed silently wrote `contact_sheet: false` and every
    node_reduce block `verify: false`; and a CLEARED speckle box posted
    `filter_speckle: [0]` because `Number('')` is 0 — a sweep axis nobody asked for.
- **The studio's own contract docs now document what the app really calls
  (landed).** `docs/runner-contract.md` had no `/compose` heading and no dataset
  routes although `CompositesController#flatten` POSTs `/compose` through
  `ComposeClient` and the proof page consumes both dataset routes;
  `test/lib/runner_contract_test.rb` then silently omitted them. All three are
  documented (request, response, status codes) and covered in the test as LIVE
  entries, so 15 documented routes == 15 dispatched in `runner.py` == the
  `SURFACES.md` table. The stale "unbuilt" wording for the vector-preserving
  composition is corrected in `docs/agent-surface-gaps.md` (gap 6 and the
  priorities line, history kept) and `docs/game-asset-generation.md`, and the
  About card + README now say a composite holding a vector layer is flattened by
  the runner as vectors.

- Skill publication landed: `sync-skills` now generates a host-tagged copy of
  the working skill into `skills/chopshop-studio/`.
- **Jobs-list preview rule + job-named artifacts — LANDED and LIVE.** The
  thumbnail now shows the run's COLOUR SOURCE (`source.png`) by default and the
  PROOF PNG once a proof has finished (`Job#preview_file` /
  `#preview_from_upload?`, with `proof_preview_file`); the top candidate is no
  longer the default. A job's NAME is part of what it publishes
  (`<name>-candidate-01.svg`, `<name>-proof-01.png/.pdf/.manifest.json`), applied
  at publish time by `chopshop-svg/runner.py`; both spellings resolve, and
  `ApplicationHelper#proof_name` + `ScrapbooksController#kind_from_name` read
  either. Conventions: `docs/ui-conventions.md` ("A job's NAME reaches its
  published filenames"); contract: `docs/runner-contract.md`. Tests:
  `test/controllers/jobs_index_preview_test.rb` (rewritten),
  `test/controllers/proof_naming_test.rb` (new).
- **FLUX registry mirror + proof variants — LANDED and LIVE (`2bc58cd`).**
  `app/models/flux_conf.rb` mirrors
  `~/chopshop-flux`'s three new models (`sana-sprint-0.6b`, `sana-sprint-1.6b`,
  `ssd-1b`), its `MODIFIERS` registry (14 LoRAs) and its `VAES` registry (5
  decoder swaps), and carries `modifier` / `modifiers_for` / `vaes_for` plus
  `validate(modifiers:, vae:)`. `FluxClient.render` and `RunJob` pass
  `modifiers` / `modifier_scales` / `vae` through and the render facts keep
  them. The Run Job flux popup and the JSON builder gained a modifiers
  multi-select, a VAE select and a **Proof variants** opt-in that composes
  `validation.variants`; the proof page grows a **Training set** card when a
  proof's manifest carries a `dataset` key; `GET /jobs/:id/dataset?candidate=…`
  proxies the runner's on-demand `.dataset.7z`. Parity with the sibling repo is
  pinned by `test/lib/flux_repo_parity_test.rb`.

## Blockers

- None known.

## Caveats / known issues

- **The proof page's cleared-gates checklist OVER-CLAIMS when a ban was never on.**
  `app/helpers/application_helper.rb` marks a gate CLEARED from the mere absence of
  its finding, so with `geometry.allow_gradients: true` in the job's spec the page
  still reads "no gradient declaration and no `url(#…)` paint server in the source —
  flat spot colour only" for a check that never ran. Half of it is fixable on the
  studio side now that Layer A records `allow_gradients`,
  `gradient_definitions` and `gradient_paint_references` in the manifest stats; the
  raster half is not, because the manifest does not echo `allow_raster_embed`. The
  honest fix is for the pipeline to echo the banning flags — a change in the svg
  repo, recorded as gap 8 / priority P1 in `docs/agent-surface-gaps.md`.
- **The expanded-prep bench report is archive-only.** The runner returns
  `prep_expand` in `GET /jobs/:id` and the studio stores no column and renders no
  block for it (a migration plus a block inside the pinned `.results-split` would be
  needed), so the bench an operator paid for is read out of the job download. Both
  studio contract docs state this rather than promising a UI.
- **The studio suite's baseline is not what older notes say.** A full
  `bin/rails test` in the container reports **1 failure + 10 errors + 6 skips**
  (900 runs as of this change): the JEV set (`JevHelpTest` 1F + 8E,
  `JevRemediationTest` 2E — the container has no `/chopshop-jev` mount) **plus**
  `JsonInjectionTest#test_the_reflected_script_block_is_still_JavaScript`, which
  dies on `Errno::ENOENT: node` because that test pipes the page's script block to
  `node --check` and the container has no node. All three are environmental and
  pre-existing; anything else red is the change's fault.

- **The FLUX registry is now covered by a cross-repo parity test.**
  `test/lib/flux_repo_parity_test.rb` parses `~/chopshop-flux`'s `models.py` +
  `modifiers.py` with Python's `ast` (stdlib, no import, no torch) and compares
  keys, licences, schedules, commercial-ok flags and resolution rules against
  `FluxConf`. The checkout comes from `CHOPSHOP_FLUX_REPO` (default: the sibling
  at `~/chopshop-flux`); it SKIPS with a reason when there is no checkout or no
  `python3`, and FAILS when a registry the studio mirrors cannot be found. So an
  edit to the flux registry that the studio does not follow breaks this suite
  rather than drifting quietly.
- **The Sana rows' `distilled: true` is not the whole story — and the studio now
  mirrors the rest of it.** `models.py` carries `guidance_embedded: true` for the
  Sana family (guidance is an embedding there and IS honoured, unlike klein's) and
  `resolution_binning: true` (the pipeline re-bins a size it has no bucket for).
  Both are mirrored into every `FluxConf::MODELS` entry, `validate` guards the
  distilled-guidance warning with `!guidance_embedded` and emits the binning
  warning, the `/flux` page's client-side validation mirrors both, and the parity
  test compares both fields — so the two sides cannot drift apart on the two
  facts that decide what the operator is told. Do not key a new behaviour off bare
  `distilled` without asking whether an embedded guidance changes the answer; that
  was the original bug, and it had exactly two behaviour sites (both now fixed).
- **Password-only per-user accounts.** The password IS the identity (no username,
  no LDAP). `User` model + bcrypt; `session[:user_id]`; an `Owned` concern stamps
  `owner` at create and scopes every read, so each user sees only their own jobs,
  validations, scrapbook and composites. Add users with `bin/rails 'users:add[handle,password]'`.
- **`config/master.key` was tracked from the first commit** — the key is in git
  history and must be treated as compromised; rotate it. Untracking does not
  unpublish.
- **No JS build step** (importmap + Propshaft); **Turbo is NOT pinned**, so
  mutating nav must use `button_to method: :delete`, not a `data-turbo-method`
  link.
- **Runner state is in-memory**; a runner restart drops validations, so the
  studio resolves proofs from disk (`job_id` + candidate file), not the stored
  `runner_validation_id`.
- **Jev add-on is optional and advisory**; an unconfigured add-on answers 503
  with a reason (never 404). The key is operator-supplied and lives only in a
  gitignored host-local override + env file.
- **Host-specific detail** (ports, env-file paths, systemd unit, timings) lives
  in `skills/` and is tagged `HOST-SPECIFIC`. The repo's own code stays
  host-agnostic via `CHOPSHOP_RUNNER_<LABEL>_URL`, `CHOPSHOP_EXTRA_HOSTS`, and
  the `@SERVER_NAME@` nginx template.

## Doc layout note (2026-09-28)

`doc/runner-contract.md` moved to `docs/runner-contract.md` (the `doc/` dir is
gone), and `AGENT_USAGE_REPORT.md` was folded into `docs/agent-api.md` (the
canonical studio HTTP driver contract) and then deleted. The cross-repo
orientation now lives in `docs/SYSTEM.md`, `docs/SURFACES.md` and
`docs/README.md`. The `test/lib/runner_contract_test.rb` path was updated and
the suite re-verified.
