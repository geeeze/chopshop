# UI conventions — Chopshop Studio

The single source of truth for how the studio looks and reads. When a request
mentions a title, a subtitle, a button size, or a font, this is the doc that
owns the rule. Change the convention here, then apply it to the views — never
the other way around.

## Vocabulary (what the operator reads)

- A finished back-half run is a **PROOF**, never a "validation"; its page is the
  proof page. The word "validation" survives only as a real identifier
  (`validate_svg.py`, `04_validated/`, `source_validation`).
- A proof's number is **inherited from the candidate it proves**:
  `candidate_06.svg` → `proof_06` (`proof_06.svg` when naming the artifact).
- Never show the database id as a run's identity — the proof's own name IS its
  identity.
- "front half" / "back half" are internal pipeline words, kept out of page copy,
  flashes and user-facing JSON keys. User-facing stages are the **trace stage**
  and the **print check**; headings and flashes use proof / proofs / candidates,
  and dispatching a job reports "Job started."

## Page titles and headings

- The accent gradient word on page titles: **Projects** (and the project's own
  name on its workspace page), Run **Job**, **JSON**, **FLUX**, **JEV**,
  **BP**. Button and nav labels use Title Case.
- Body page titles (`.section-title`) render in **Inter** (`--font-sans`), not
  the display serif. The login hero `.login-title` is the exception (pixel
  font).
- Header nav order: Projects · JSON · FLUX · JEV · BP (the served order —
  `layouts/application.html.erb`, oldest to newest). Jobs and Run Job left the
  header: the jobs list is now each project's workspace (`root` is the Projects
  index), and Run Job is reached from it. The nav is the
  WORKING path — the pages that act on a job. A REFERENCE surface does not grow
  the row: STATUS is reached from the footer's engine light, TOURNAMENT from the
  BP head (a bracket is a DRAWN DOCUMENT, which is BP's plot half), DATASETS from
  the FLUX head (a prompt is taken FROM it and generated WITH). Adding a page
  updates `engine_light_test`'s `labels.last` line; that assertion is the
  ordering contract.
- A RECORD page's header is the shared skeleton — see "Record-page skeleton"
  below. The `.page-sub`/`.page-sub-main` band is a different thing and is
  unchanged: it is where a record page's own controls and run-summary tiles go
  (actions left, the reduced `.job-stat` tiles right). The skeleton is the
  record's identity; `.page-sub` is its controls.

## Page layout

- The record pages (job, project, candidate/proof) lead with the RECORD SKELETON
  (`.record-head`: breadcrumb → gradient heading → badge/meta row → `.record-alias`
  sub-title — see the "Badge / chip vocabulary" section) and their controls keep
  their own `.page-head` / `.page-sub` wrappers. `.page-head-line` (title left,
  controls right) is the KEPT FALLBACK behind `RECORD_TEMPLATE_V2` and no shipped
  page renders it while the switch is on. The title line carries the title and
  its controls, nothing else: a preview dock on it crowds the heading.
- The results are the FIRST content of the job page: the candidates table and
  the proofs column (`.results-split`), read in that order. Work before
  provenance.
- The expanded-prep bench (`prep_expand`) renders as a block inside the
  right-hand column of `.results-split`, after the proofs and before the
  sources. It appears only when the runner reported a bench (the job's spec
  asked for `print.prep_expand` and the job completed). The block is a card
  with the bench's own sub-sections (filters, tune, node_reduce), styled to
  match the existing result blocks.
- Every preview of the run's sources — the raster pair, an img2img reference, a
  flux job's generated variations, a plot job's drawn SVG — lives in ONE
  vertical, bottom-aligned `.source-stack` BELOW the proofs, never in the page
  head and never above the candidates table. It keeps the dock's 78x54
  `.pv-tile` size for the pair; the wide previews (a `.variations-grid`, a plot
  card) span the column, which is why `.source-stack > .card` is `width: 100%`.
  Right-aligned to the edge the old dock sat on (`align-items: flex-end`), so
  the tiles stay a dock rather than drifting to the left margin under a
  full-width table.
- Moving a preview changes ONLY its position. Its `data-*` attributes, the
  self-hiding `onerror` and the shared `scrapbook/fav_button` partial travel
  with it, and the new location gets its own test (see
  `test/controllers/job_source_stack_test.rb`).
- **The project workspace's jobs-list thumbnail shows the run's COLOUR SOURCE by default, and the
  PROOF once one has been delivered.** The default is the raster the sweep was
  fed (`source.png` on a pipeline job — the stable name a runner publishes
  beside its inverted twin); the top candidate is deliberately NOT the default.
  A FINISHED proof supersedes it: that is the run's result, and the row should be
  recognised by it. Only a proof in state `done` counts, and a manifest naming no
  render does not displace the source. The decision lives in ONE place,
  `Job#preview_file` / `#preview_from_upload?`, which also answers the two-sided
  route question (runner file proxy vs the login-gated `upload_preview`).
- **The STATUS page reports ONE count per thing, and every drawing on it is drawn
  by the blend-plot service.** Four panels: PIPELINE USE (the produced tally as a
  BAR chart), SERVER (the host's CPU/memory/swap as a LINE chart plus the newest
  reading as tiles), EVENT LOG (the training signal a ranker reads), and ML /
  RANKING (read-only configuration). The two charts and the log are POSTed to
  chopshop-bp's `digest` (twice) and `log` (once) and inlined as the SVG it
  answers with; with no blend-plot runner, the SAME numbers render as the page's
  own HTML. A bar chart for the tally because six unrelated totals joined by a
  line would imply a progression that does not exist.
- **The source → job → candidate HIERARCHY was REMOVED from STATUS, and must not
  come back as a card.** It restated the jobs table in a shape no number could be
  read out of, and the operator asked for measurements. Its fallback list and CSS
  (`.status-tree`, `.status-node`, `.status-metrics`) were deleted with it — an
  orphaned rule is a trap for the next reader — and
  `test/controllers/status_page_test.rb` pins the absence STRUCTURALLY: no
  hierarchy panel, no nested list, and the `tree` operation is never called (a
  grep for the word would match the page's own prose and prove nothing).
- **A count appears ONCE on the page.** The strip at the top carries the learning
  signal (events, by kind) only: the produced-file counts — jobs, generated,
  traced, proofs, scrapbooked, composited — belong to the PIPELINE USE panel,
  where they are both listed and drawn, and the bar order and wording live in
  `PagesController::USE_BARS` so the chart, the tiles and `/engine.json` cannot
  disagree. One count in two places is one count too many.
- **Nothing to draw is nothing to ASK for.** With no samples and no recorded
  events the page asks the service for nothing at all (a bar chart of six zeros
  and an empty timeline are drawings of an absence) and prints the numbers.
- **An unmeasured server reading is a dash, not a zero, and a stopped sampler
  says so.** CPU is a percentage BETWEEN two samples: the first reading after a
  restart is absent rather than 0%, a box with no swap reads "none configured",
  and a sample older than five minutes prints "the sampler has stopped" with the
  moment it was taken instead of presenting an old number as the current one.

## Fonts

- Self-hosted in `public/fonts`. Never introduce Google-hosted font calls.
- The pixel font is **"Press Start 2P"** (the "gamer font"), exposed as
  `var(--font-pixel)` and the `.pixel` utility class. It is WIDE — a full-size
  word like "Run Job" runs ~110px — so every use needs a size drop of roughly
  two steps from its Inter/mono equivalent.
- Where it belongs: **header + login page + chips/buttons/stats.**
  - Header: nav links 0.72rem, logo wordmark 0.9rem, runner pill 0.6rem.
  - Login: `.login-title` 1.7rem, the "Private demo" `.section-tag`, the
    scissor hero.
  - Candidate page: status pills + `.tech-tag` 0.5rem, `.btn` 0.6rem,
    `.job-stat` value 0.85rem / label 0.5rem.
- A scoping instruction is ADDITIVE unless it explicitly says "replace". Never
  silently strip an already-approved use of the font.
- Glyphs ✂ ↗ ⬇ ‹ › ▸ are not in Press Start 2P and silently fall back mid-word;
  check any control that carries one.

## Buttons

- Round scissor-only submit: `.btn-scissor` (48×48, `border-radius: 50%`, ✂, no
  visible label). A bare icon button must carry its action verb in
  `title`/`aria-label`.
- A labelled action is a **PILL** (`border-radius: 999px`, `width: auto`, real
  horizontal padding) at a constant height — never a round orb, which cannot
  hold the words "Run Job" while circular.
- `.btn-primary` carries an animated conic-gradient glow ring
  (`@property --angle` + blurred `::after`, blue→pink→cyan), pinned as its own
  stacking context (`isolation: isolate` + `overflow: visible`). ALL `.btn-primary`
  glow, `.btn-sm` included.
- **Glow strength is a function of repetition, not of the action's importance.**
  A column of buttons damps to `.cs-proof-btn` (`::after` opacity 0.62); the
  single Proof button in a popup stays full strength.
- `f.submit` renders an `<input>`, which cannot host `::before`/`::after` — use
  `f.button "Label →", class: "btn btn-primary"` for any submit that needs the
  glow.

## Popups, pages and panels — ONE navigation rule

A surface is reached ONE way, and which way is decided by what the surface does,
not by how big it is:

| kind | what belongs there | how it is opened | trigger |
|---|---|---|---|
| **PAGE** | anything that WRITES, or that needs its own URL to be shared/bookmarked (the composite builder, the spec builder, the library) | the nav, or a page action in the head (`Compose` on Run Job) | `.btn` in `.page-actions`, or a nav link |
| **POPUP** | a REFERENCE surface you read and close: a registry, a configuration, a table, the labels | a trigger in the page head | `.btn.btn-secondary.head-action`; partners in ONE `.head-action-pair` |
| **SECTION popup** | settings that belong to one section of a form | beside that section | `.btn.btn-secondary.btn-sm` |
| **ROW popup** | one row's detail (a proof, one candidate's manifest) | on the row | `.btn.btn-icon`, verb in `title`/`aria-label` |
| **INLINE affordance** | a reference named INSIDE prose ("one per line, from `remediation_table.json`") | in the sentence | `a.jev-file-link`-style inline link |
| **DRAWER** | a cross-page collection you keep coming back to (Scrapbook, Composites) | the side toggle, on every page | the drawer toggle, never a nav entry and never a popup |

Rules that make the table hold:

- **Colour: one primary per page, not "popups are always secondary".** A popup
  trigger is normally SECONDARY (a reference surface is not the page's action),
  and the proof page is the named exception: its **Ask Jev** trigger is
  `btn-primary` because asking the decision sidecar IS what that page is for —
  which is the same rule, applied correctly. `manifest-block` is the other
  named exception in the same direction: it opens a **document**, so it is
  styled as one (no fill, a dotted underline) rather than as a command, and
  still carries `.head-action` so it shares the box. Both are pinned by
  `proof_head_controls_test`; do not "normalise" them into pills.
- **Size is the BOX, and the box class wins.** A page-level trigger is the
  `.head-action` box (`2.75rem` × `min-width 7.325rem`) wherever it appears. A
  `btn-sm` left on such a trigger is INERT — `.head-action`/`.jev-btn`/
  `.manifest-block` set the height and the min-width afterwards — so seeing
  `btn-sm` beside `head-action` is not evidence of the small size, and removing
  it changes nothing. Section and row controls are deliberately smaller and
  carry no `head-action`.
- **A popup that mirrors a page is a DOOR to it, not a second copy.** Render the
  page's own partial (`datasets/_surface.html.erb`,
  `pages/_tournament_surface.html.erb`) — fetched on open with `data-popup-url` +
  a `[data-popup-body]` slot, so a page load never waits on a drawing nobody
  asked for — and let its inner links (pagination, filters) navigate to the page.
  A popup with its own private navigation is how two copies drift; that is why
  the tournament popup has no layout switch and the datasets popup no own pager.
- **A JS-opened dialog is still a SECTION popup.** `compScrapPicker` has no
  `data-popup` attribute because it is opened by code that has to hand it state
  (an "add from scrapbook" picker); it is a section popup in the table's terms
  and belongs beside the control it serves, not in the page head.
- **A failure leaves the popup OPEN with the reason in it.** Closing on error
  reads as "the button did nothing", the same trap as the runner's 503-vs-404
  rule.

## Footer buttons

The footer carries ONE reference button — the About page, labelled `???` — as a
PILL at the page-action footprint, in `.footer-demo`. A large button's extra
width is the button's OWN horizontal padding, never spaces in the label: HTML
collapses leading/trailing whitespace, so padding is the only place the gap can
be honoured. The pixel font is kept (footer = chrome); the old gradient
underline went with the text-link shape it was drawn for.

A reference surface goes to the page that OWNS ITS SUBJECT (Tournament → BP's
plot half, Datasets → FLUX) before it goes to the footer, which is for the About
page and the engine light only. The footer is the last resort, not the shelf.

## Aesthetic invariants

- `grid-2` means equal columns with `align-items: stretch`.
- Keep layouts restrained; no decorative badges beside headings.
- One animated control per cluster; two light sources in a 44px header read as
  a fault.
- SVG/manifest viewing uses the blurred glass modal, not navigation.
- The background orb is deliberately subdued: opacity 0.18, blur 260px,
  saturate 0.75, 40s drift. Do not brighten it without being asked.

## Badge / chip vocabulary (semantic token layer, #93)

One colour per MEANING, not per page. The sheet carries a semantic token block
(`--band-*`, `--state-*`, `--radius-pill`, `--miss-opacity`) and shared classes;
a new view COPIES these instead of inventing a pill:

- `.badge` (base; shares one rule with legacy `.status-pill`) + a meaning
  suffix: bands `.badge.pass .warn .fail .pending`, state
  `.badge.pending .queued .running .done .error .cancelled`. The legacy
  `.status-<state>` selectors are folded into the same rules — one rule, two
  names, so they cannot drift. The band words are the studio's own
  (`Job.fidelity_status` maps faithful/drift/lost/unmeasured onto
  pass/warn/fail/pending); do not introduce tier letters (tA–tD).
- `.chip` (shares one rule with legacy `.tech-tag`) is the neutral pill.
- `.chip.miss` — the dashed border for absent-but-optional data (the
  `.thumb[data-missing]` / `.job-card-thumb[data-missing]` carriers read the
  same convention). "Missing" must read as intentional, never as broken.
- Every rule keeps its old literal as the token's fallback, so deleting the
  token block restores the old sheet — keep that property when adding rules.

## Record-page skeleton (facelift 2/4, #94)

A job, a project and a candidate each open on the SAME skeleton, in the same
order — a reference app's entity-page rhythm, in the studio's tokens:

```
breadcrumb  ->  gradient heading  ->  badge/meta row  ->  alias/muted line
            ->  UPPERCASE h3 sections
```

- One partial renders the head: `app/views/application/_record_header.html.erb`
  (`.crumb`, `h1.record-title` + `.gradient-text`, `.record-meta`, `.record-alias`).
  A view passes CONTENT for each part; the ORDER lives in the partial and nowhere
  else. The three record views are `jobs/show`, `projects/show` and
  `validations/show` (a proof IS a candidate's record — there is no
  `candidates#show` route).
- One helper renders every section heading: `record_section(label)` →
  `h3.record-section`. The rule is `h3.record-section`, and the TAG is part of
  the selector on purpose: it TIES with `.card h3` at (0,1,1) and wins on source
  order (the rule sits at the foot of the sheet). A bare `.record-section` at
  (0,1,0) loses, and the proof page's sections would keep the card's 1.25rem
  size.
- The meta row is `state badges + machine values`: the badges are the phase-1
  semantic classes (`.badge.<state>` — one colour per meaning), the values are
  mono + `--text-tertiary` (`.id`), so an id or a date can never be read as
  prose.
- A part with nothing to say renders an EM-DASH rather than disappearing
  (`.chip.miss` for an absent badge) — the kb's convention, so the rhythm does
  not move on a thin record.
- **The previous per-page head is KEPT, not removed.** `RECORD_TEMPLATE_V2`
  (`config/initializers/record_template.rb`) is the single switch: `false`
  restores each page's old title line and sub-title exactly. The old markup stays
  in the view as `unless RECORD_TEMPLATE_V2` guards around the parts the skeleton
  replaced, so exactly one branch renders — never both, and never two `<h1>`s.
  It is a Ruby constant and NOT an ERB comment block: a record head is full of
  ERB tags and an ERB comment ends at the first `%>` in its body, which would
  swallow the rest of the page and still return HTTP 200.
- What is deliberately NOT in the skeleton: each page's own CONTROLS (Run Job /
  Compose, Ask Jev / manifest, Refresh / back, the run-summary tiles). They keep
  their own wrappers and their measured boxes; the skeleton replaced the title
  and the sub-title only.
- **A page that is not a record does NOT get the skeleton.** `GET /audit` (#95)
  is a DASHBOARD — every class's gaps and the per-project breakdown — so it
  renders the house page head (`.page-head-row--split page-head-row--stacked`)
  and the STATUS page's `.card` / `.card-head` panel rhythm, exactly as STATUS
  does. It reuses the phase-1 vocabulary (`.badge.<state>` for the state row,
  `.chip.miss` for an absent value) and introduces no new pill or colour. A
  record page has ONE entity and a breadcrumb; a dashboard has many rows and a
  count per row, so giving it the record head would be the wrong skeleton rather
  than a stylistic choice.

## Rules are about what the operator reads

A naming instruction (e.g. "candidate_06 becomes proof_06") is a DISPLAY
mapping, not a rename of the pipeline's artifacts: `candidate_NN.svg` and
`.proof.png`/`.print.pdf`/`.manifest.json` keep their names. It is also not a
rename of identifiers — `validate_svg.py`, the `back_half` JSON key, the
`04_validated/` directory stay. Sweep the prose, leave the identifiers, and name
the survivor in the same paragraph.

## A job's NAME reaches its published filenames

An artifact may carry the JOB'S NAME, so a downloaded 7z or a scrapbook
favourite says which run it came from:

```
<name>-candidate-01.svg     <name>-proof-01.png / .pdf / .manifest.json
```

- The name is slugged (`Job`-side the runner does it: lowercase, runs of
  non-alphanumerics to `-`), so `jobby the boat` publishes
  `jobby-the-boat-proof-01.png`.
- **This is a PUBLISH-time rename, not a pipeline rename.** The runner copies an
  artifact into the job directory under a published name and rewrites the two
  things that carry a name back to the caller: the comparison entry's `file` and
  the manifest's `proof`/`print_pdf`. `02_traced/<stem>/candidate_NN.svg` and
  `05_final/<candidate stem>.proof.png` are untouched — that half's names are a
  frozen contract (`chopshop-svg`'s hard rules) other tools read.
- **BOTH spellings are live and must keep working.** A job directory published
  before the rename holds `candidate_01.svg` / `candidate_01.proof.png`, and a
  job dict with no name of its own (a reindex after a restart) publishes exactly
  those. So the artifact resolver serves either name, the scrapbook classifies
  either, and `proof_name` maps either to its proof label
  (`ApplicationHelper#proof_name`: `candidate_06.svg` → `proof_06`,
  `<job>-candidate-06.svg` → `<job>-proof-06`).
- The studio posts the PUBLISHED candidate name back for a proof, so the runner
  maps it to the pipeline's own spelling before the print check runs.

> The measured pixel-by-pixel calibrations, the headless-chromium geometry
> harness, and the per-page structural notes live in the working Hermes skill
> (`ui-conventions.md`, `layout-and-probe-pitfalls.md`), where they carry
> host-specific measurement detail. This doc holds the durable rules.
