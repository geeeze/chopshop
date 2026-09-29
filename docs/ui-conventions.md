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

- The accent gradient word on page titles: **Jobs**, Run **Job**, **JSON**,
  **FLUX**, **JEV**. Button and nav labels use Title Case.
- Body page titles (`.section-title`) render in **Inter** (`--font-sans`), not
  the display serif. The login hero `.login-title` is the exception (pixel
  font).
- Header nav order: Jobs · Run Job · JSON · FLUX · JEV · BP. The nav is the
  WORKING path — the pages that act on a job. A REFERENCE surface does not grow
  the row: STATUS is reached from the footer's engine light, TOURNAMENT from a
  footer button, DATASETS from the FLUX head (it is where a prompt is taken FROM
  and generated WITH, so it is FLUX's own subject). Adding a page updates
  `engine_light_test`'s `labels.last` line; that assertion is the ordering
  contract.
- The shared header layout is `.page-head-line` + `.page-sub`/`.page-sub-main`:
  line 1 = title (left) + right-aligned controls; line 2 = actions (left) + the
  reduced `.job-stat` tiles (right). Job/proof/candidate pages all share this
  one layout.

## Page layout

- The page head is the title line (`.page-head-line` — title left, controls
  right) plus the `.page-sub` band (actions left, the reduced `.job-stat` tiles
  right). The title line carries the title and its controls, nothing else: a
  preview dock on it crowds the heading.
- The results are the FIRST content of the job page: the candidates table and
  the proofs column (`.results-split`), read in that order. Work before
  provenance.
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
- **The Jobs-list thumbnail shows the run's COLOUR SOURCE by default, and the
  PROOF once one has been delivered.** The default is the raster the sweep was
  fed (`source.png` on a pipeline job — the stable name a runner publishes
  beside its inverted twin); the top candidate is deliberately NOT the default.
  A FINISHED proof supersedes it: that is the run's result, and the row should be
  recognised by it. Only a proof in state `done` counts, and a manifest naming no
  render does not displace the source. The decision lives in ONE place,
  `Job#preview_file` / `#preview_from_upload?`, which also answers the two-sided
  route question (runner file proxy vs the login-gated `upload_preview`).

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

- **Colour: a popup trigger is SECONDARY.** `btn-primary` is the page's own
  action (Run Job, Proof, the one submit that finishes the task) and carries the
  glow; a reference surface is not that. One primary per cluster, and the glow
  is a function of repetition, not of importance.
- **A popup that mirrors a page is a DOOR to it, not a second copy.** Render the
  page's own partial (`datasets/_surface.html.erb`) — fetched on open with
  `data-popup-url` + a `[data-popup-body]` slot, so a page load never waits on a
  drawing nobody asked for — and let its inner links (pagination, filters)
  navigate to the page. A popup with its own private navigation is how two
  copies drift.
- **Size follows the kind**, so a page-level trigger is always the same box
  (`.head-action`: 2.75rem × min 7.325rem) wherever it appears, and a section or
  row control is deliberately smaller. A popup trigger is never the small size
  and a section control is never the page size.
- **A failure leaves the popup OPEN with the reason in it.** Closing on error
  reads as "the button did nothing", the same trap as the runner's 503-vs-404
  rule.

## Footer buttons

The footer carries the reference buttons — `Tournament` and `???` (the About
page) — as PILLS at the page-action footprint, in `.footer-demo`. A large
button's extra width is the button's OWN horizontal padding, never spaces in the
the label: HTML collapses leading/trailing whitespace, so padding is the only place
the gap can be honoured. The pixel font is kept (footer = chrome); the old
gradient underline went with the text-link shape it was drawn for.

## Aesthetic invariants

- `grid-2` means equal columns with `align-items: stretch`.
- Keep layouts restrained; no decorative badges beside headings.
- One animated control per cluster; two light sources in a 44px header read as
  a fault.
- SVG/manifest viewing uses the blurred glass modal, not navigation.
- The background orb is deliberately subdued: opacity 0.18, blur 260px,
  saturate 0.75, 40s drift. Do not brighten it without being asked.

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
