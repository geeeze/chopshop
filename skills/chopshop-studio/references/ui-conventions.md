> contains one HOST-SPECIFIC fact (the `~/Public` filesystem note). The
> design inventory is generic.

# UI conventions — Chopshop Studio

## Ask when a correction names a CLASS of thing and the site has more than one

Before editing, enumerate what the request could refer to. If that list has more
than one member, ask — one clarifying question is cheaper than a confident wrong
pick, which costs a full change, a measurement round, and a revert.

This bites hardest on **corrections**, where the request has already been
refined once and is usually phrased at the level of a symptom: "the table is
being shrunk" had three candidate tables on the site; "the blurb sub-titles need
to be under the heading" was one of three different head mechanisms across five
pages, only one of which was broken. Neither is answerable by reading the CSS.

It bites on structural instructions too. A request that sounds like a label
change ("make the config button say JSON") can be a whole-page reassignment of
which control opens what; get that wrong and every later instruction inherits the
error. Read the page's current structure and state back what you believe the
mapping is, then act.

The tell that guessing is wrong: you find yourself about to change something and
realise you could name two other things that equally match the words. That is the
moment to ask, not after the revert.

## Confirm the page before building a layout

When a request names a page, OPEN that page's view and read its current structure before writing
anything. Name→file: Run Job = `app/views/jobs/new.html.erb`, JSON builder =
`app/views/pages/schema.html.erb`, Jobs = `app/views/jobs/show.html.erb`, Proof =
`app/views/proofs/show.html.erb`. A layout change to page A built on page B because they feel
similar is the costliest error available here: a large diff on the wrong file, a surgical revert, and
two rounds of the operator's patience. Reverting must be surgical — `git checkout <file>` also
discards every unrelated approved change in that file (the Colour Spec card lives in
`schema.html.erb` too), so hand-revert only the hunks you added.

## Put the data on the page, not behind a control

When the request says **display** a set of rows in a column, that column IS the
table. Do not interpose a button — not a full-width "Proof" button filling the
column, not a heading, not a wrapper. A one-line control standing in front of the
data reads as a deliberate refusal to show it, and it is the single most
provocative thing you can build from an unambiguous instruction.

Read the verb literally: *display* means rendered, *open* means behind a control,
*with a findings button* means the button opens ADDITIONAL detail, not the row
itself. The pairing that satisfies both is: the narrow column carries the table,
each row carries a compact detail button and its domain button, and everything
the width cannot hold moves into the per-row popup. Popup for what does not fit;
never popup for the thing that was asked to be seen.

Corollary — a control that fills a whole column to open something is itself a
layout bug. A button in a 33% track is ~416px wide and reads as a design
element rather than a control. If a button is that big, the content it opens
belongs on the page.

## Layout verification — measure, never eyeball

Geometry claims ("same line", "flush right", "half width", "equal height") are proven by
`getBoundingClientRect()` in headless chromium over the REAL stylesheets, not by reading the CSS.
A green `assert_includes` on markup proves the elements exist, not that they land where you said.

Two non-obvious measurement traps, both of which produced a wrong "fix" before the right one:

- **`scrollWidth > clientWidth` is NOT proof of clipped text when the element has a `::after` glow
  ring.** `.btn-primary::after` is a conic-gradient ring at `inset:-3px`, so a primary button's
  `scrollWidth` is ALWAYS ~3px wider than `clientWidth` — by design, at rest, on a correct layout.
  Chasing it by widening padding "fixes" nothing and silently changes the design. To test whether a
  label fits, measure the TEXT against the CONTENT BOX: clone the text into an absolutely
  positioned `visibility:hidden` span with the button's computed `font`, read its width, and compare
  to `clientWidth - paddingLeft - paddingRight`.
- **`getComputedStyle` cannot distinguish a base rule you failed to override.** A higher-specificity
  rule only wins for the properties it NAMES. An override that set `height` and `min-width` but not
  `width` left the base `width: 48px` in force, `min-width` floored the box at 72px, and the label
  overflowed the padding box entirely. When overriding a size, name EVERY dimension you depend on
  (including `width: auto`), and put the measured symptom in the CSS comment so the next reader knows
  the line is load-bearing.

## Two controls that must share a line

Two independent flex columns cannot express "these two controls share a row" — each stacks on its
own, so the second lands wherever its own content ends. Use an explicit grid and place both in the
same row: `display:grid; grid-template-columns: 1fr 1fr` with the two controls as direct children in
ROW-MAJOR source order, pinned by `grid-row`/`grid-column`. Row-major order is what makes the
alignment survive editing; a wrapper div per column silently breaks it.

Corollary for flex rows: **`align-items: flex-end` bottom-aligns against the TALLEST child, so a
multi-line helper inside the row drags the buttons down past the thing they belong beside.** Measured
a Run Job footer where the hint wrapped to three lines inside the button row: `tile.top=625` vs
`buttons.top=680`, a 55px drop. The hint must be a SIBLING below the row, never a child of it. When
you move a block out of a row, re-check the fields that lived inside it — a `hidden_field` for the
upload path was lost in exactly this move and would have submitted the job with no artwork.

## Equal-height columns

For two cards to take each other's height, `align-items: stretch` (not `start`), both cards as flex
columns so their contents still hug the top, and the growing child gets `flex: 1` — otherwise it
stops at its own `min-height` and the extra space is wasted. Scale a set of sibling controls
TOGETHER (tile + preview + buttons): resizing one alone makes it read as an afterthought beside the
others, and a preview that replaces a tile at runtime must match the tile's dimensions or the swap
changes the row height and nudges the buttons off the alignment you just measured.

## Test-regex traps when asserting on CSS and markup

- **A greedy regex runs past the element you meant to scope.** `html[/<div class="actions-row">.*?<\/div>\s*<\/div>\s*<\/div>/m]`
  matched through the row's real closing tag and picked up a following sibling, failing against
  markup that was already correct. Use Nokogiri (`doc.at_css(".actions-row").at_css("#uploadHint")`)
  for any structural assertion; it scopes properly and its failure message points at the node.
- **CSS comments break `/\{.*?prop:/` patterns.** An explanatory comment sits between a rule's
  selector and its declarations, so the pattern cannot cross it and silently matches nothing — which
  reads as "the CSS says the old value" and sends you editing correct code. Strip comments before
  matching: `read.gsub(%r{/\*.*?\*/}m, "")`.
- A regex whose failure message quotes a number ("got 180px") is indistinguishable from a real
  regression. When the assertion fails, check whether the pattern matched at all before believing
  the value it reported.
- **A block that YIELDS must yield a MUTABLE reference, never a snapshot.** `counting_ask_jev { |calls|
  calls << 1 }` with `assert_equal(1, calls.size)` read 0 at every point: `calls` was bound to a
  fresh integer, and the increment was discarded. Yield an Array/Hash and assert on it after the
  request, so "the runner was called exactly once" is actually measurable.
- **Get the polarity of the assertion right, and prove the element is ABSENT with `assert_nil`.**
  `refute_nil` asserts the node EXISTS; used to mean "the wrapper is gone" it fails against correct
  markup and reads as a regression.
- **A valueless attribute reads as `""`, not `nil`.** `dlg["hidden"]` is `""` for `hidden`, so
  `assert(dlg["hidden"].present?)` fails on a correct dialog. Assert `node.key?("hidden")`, or
  compare the value you authored.
- **Assert the value, not just the container.** A card can render its question and confidence with a
  blank value and still pass "is there a card" — check the value is present, or a wrong fixture key
  reads as a helper bug.

## Pretty-printing JSON in a view

`to_json(pretty: true)` is SILENTLY IGNORED by this app's Rails/ActiveSupport — the contract ships
as one long line, which is the opposite of the formatting it looks like it requests. Use
`JSON.pretty_generate`. Verified by running both forms side by side: `to_json(pretty: true)` emitted
the compact form, `JSON.pretty_generate` emitted the indented one. This bug was live in a collapsed
textarea for a long time precisely because nothing was looking at the rendered text.

## Rendering a view offline for a DOM check

`ApplicationController.render(template: ...)` fails on any view containing `form_with model: @job`
("Passed nil to the :model argument") because the instance variable is not assigned. Stub a request
on the view context, or — more reliable — render through the real route in an integration test
(`get new_job_path`) after POSTing `login_path` with `CHOPSHOP_PASSWORD` set, which is also the only
way the auth-gated pages can be checked at all. Plain `ERB.new(src).src` cannot compile
`<%= form_with ... do |f| %>` (block form is Erubi/Rails-only); compile through the Rails handler
instead. Use `f.button`, not `f.submit`, for a `btn-primary` — an `<input type="submit">` cannot
host the `::after` glow ring.

## Theme tokens (application.css :root)

- Fonts: `--font-sans` Inter · `--font-display` Playfair Display · `--font-mono` JetBrains Mono · `--font-pixel` Press Start 2P (use via `.pixel`)
- Colors: `--primary` #6366f1 · `--secondary` #ec4899 · `--accent` #06b6d4 · success/warning/danger emerald/amber/red
- Surfaces: white-alpha glass (`--surface`, `--surface-hover`, `--surface-active`); borders `--border`, `--border-glow`. `--surface` is 3% white, so it STACKS invisibly — never use it for a table or panel that has to read as solid (see Page structure).
- Glass bars: `--glass-blur: 22px`, `--glass-saturate: 150%`, `--glass-edge: rgba(10,10,15,0.72)`, `--glass-inner: rgba(10,10,15,0.48)`. Both the header and the footer consume these and nothing else, so they cannot drift apart again — they did once, to 0.5 vs 0.85 alpha, and the footer read as a solid slab. `saturate()` is the part that makes it read as GLASS rather than as a plain blur. The gradients are MIRRORED, not copied: the heavy stop lands on each bar's outer edge, the light one where content passes under.
- Radii: `--radius-sm` 8px → `--radius-xxl` 40px; cards use `--radius-xl` + `backdrop-filter: blur(30px)`
- Utility classes: `.gradient-text`, `.text-glow`, `.card-glow`, `.mono`, `.pixel`, `.status-pill status-pass|fail|error`, `.tech-tag`

## Page structure

- Sticky header + sticky footer, body scrolls between them. Both are GLASS from one shared token set (see Theme tokens), not independently tuned.
- Tables: `table.candidates` inside `.tbl-wrap`; `.rowlink` rows navigate (only when `data-href` set) or open the modal; `.col-narrow` for low-value columns. `table.candidates` is backed by `--table-bg: #101018`, NOT `--surface` — a 3%-white table on a 3%-white card lets the `position: fixed` colour orbs show through the cells and under the numbers. When you change the base, re-measure contrast on the new one (AA is 4.5:1).
- Page head: `h1.section-title` (accent word in `<span class="gradient-text">`) + one-line subtitle + `actions-row` of buttons
- Content in `.card`s inside `.grid-2`/`.grid-4`; `align-items:stretch` for row-height matching

## Jobs show — header + candidate table

- Header preview row shows ONLY the source raster and its colour-inverted prep twin (`source.png` + `source.inverse.png`) — two `pv-tile` tiles, never the candidate previews (they squashed the header). The twin is an optional derived artifact: give its `<img>` an `onerror="this.closest('.pv-tile').remove()"` so a job without a twin collapses the tile instead of showing a broken image. Use the same self-hiding `onerror` on any preview whose file may legitimately be absent (e.g. the inverse twin for vector jobs / old runs).
- Candidate table keeps only scan-critical columns — preview, preset, layer A/B, hard/adv, actions. The **Palette column was removed** (the sweep's `use_palette` was already implied by the preset column beside it, and the operator asked for it gone); the proofs table below it lost it too. Each row has a Detail (list-icon) button that opens ONE consolidated findings popup: back-half `findings` (`{rule, severity, layer, detail}`, severity hard/advisory) + the candidate's metrics + a collapsible raw-JSON `<details>`. This replaced the old job-level "Report"/"Raw data" toolbar — findings are per-candidate, not per-job. "Log" (the runner log) stays a toolbar button in the header actions.
- The results body is a **`.results-split` = `2fr 1fr`** grid (candidates left, proofs right), with `min-width: 0` on BOTH children — without it the candidates table's intrinsic width refuses to shrink and the track overflows. Below 900px it becomes one column. The proofs live in that right column as a compact `table.candidates.proofs-tbl` (preview · proof · state · hard · actions) whose columns are `table-layout: fixed` at explicit widths, because auto layout sizes to content and turns a 33% track into a sideways scroller. Advisory, inks, nodes, dpi, the findings, the clearances and the artifact links live in the per-row `proof-detail-<id>` popup, server-rendered so opening one costs no request. The aside is NOT sticky: a box holding a table can outgrow the viewport, and sticky then pins its top and strands the lower rows.
- Row actions are compact icon buttons: download SVG, Detail (findings), Proof. "Proof" is the run label; once a proof exists for that candidate the button becomes a proof-PNG download link.
- The Detail popup fetches `GET /jobs/:id.json?candidate=<file>` → `{file, job, spec, sweep, proof}`; `proof` is null until a proof exists for that candidate, so render the "no proof yet" fallback from the `sweep` entry's layer statuses. Build the list into `#csModalBody` and set text with textContent/escaped innerHTML — never re-parse server SVG as markup.

## Proof page (`/proofs/:id`) and the job page's Proofs table

- The route is `resources :validations, path: "proofs"`: the URL the operator reads is `/proofs/:id`
  while the controller, model and DB table keep their internal `validation` names. Do not rename the
  internals to match — do keep the URL in his vocabulary.
- Header: title **Proof** + the proof name (`proof_06`, no extension → `proof_label`), then a
  sub-line naming the artifact (`proof_06.svg — Layer A (source checks) + Layer B (render preflight)`),
  and the manifest popup heading carries the proof name rather than `#<id>`.
- The job page no longer carries a full-width **Proofs** table under the candidates — that table is now the right-hand column of the results split (see "Jobs show" above), compact, with a per-row detail popup and a per-row Jev button. Its first column is the proof name; the id column is GONE. A proof is identified by the candidate it proves (`candidate_06` → `proof_06`), never by a database id — "`#11`" beside a candidate filename told the operator nothing. Rows sort by fewest hard gates. An UNFINISHED proof still gets a row (with its state and no hard count) and its detail popup, because the pending state is information — but it gets NO Jev button and no Jev dialog, since there is nothing to annotate yet; a dead button is worse than no button.
- **The Findings card is one-sided data, so it needs a positive half.** A manifest records only
  failures, so a clean run rendered as an empty card and read as "nothing was checked". When no HARD
  finding fired, render `cleared_checks(manifest)` (ApplicationHelper) under the findings as a quiet
  list — label + pipeline area (source/render) + the measurement carrying it (declared colours,
  worst-path nodes, peak TAC against the limit, screens, PDF font/image state) — plus a closing
  "Not run (not cleared)" line for gates that were skipped, because an unchecked gate is not a
  cleared one. Every entry must be anchored on a value actually present in that run's manifest and
  be suppressed the moment its rule appears in `findings`, or the panel claims clearances the run
  never proved. Keep it visually quieter than a real finding.

## Modal (aether.js)

- `closeCsModal()` removes the `.open` class but LEAVES THE MARKUP in place — so "is the modal open?" must read `document.getElementById('csModal').classList.contains('open')`, never "does a `.pal-preset` node exist". The popup body is also duplicated in the page whenever a `hidden` template holds the same markup (see Clickable-frame cards), so scope modal selectors to `#csModal …` or you will probe/click the hidden copy.
- `openCsModal(title, bodyHtml, {url, filename, onClose})` / `closeCsModal()`; closes on Escape, backdrop click, ✕; locks body scroll. `onClose` is a callback run after close (strip a modifier class, open the next modal, etc.) — prefer it over watching the modal's `class` attribute with a MutationObserver, which fires re-entrantly and is fragile.
- Wire any element with `data-cs-view="svg|json"`, `data-cs-url`, `data-cs-title` — `svg` renders in the checkerboard `.art-frame`; `json` fetches + pretty-prints in `.log-console`
- "Open in new tab ↗" link shown when a url is passed — the only affordance that legitimately opens a tab; every clickable preview in the page routes through the popup instead
- The candidate viewer opens with the CODE PANE COLLAPSED (user: "default open them in the large mode, collapsed code block"). Height is the tell: `.cs-viewer .cs-modal-art img` is 32vh, and `.cs-viewer.code-collapsed .cs-modal-art img` is 62vh — so `code-collapsed` IS "large mode". `openCsViewer` therefore calls `setCodeCollapsed(true)` on open, which hides `#csCodePane`, sets the toggle to "Code ▸", toggles the class, and keeps the toggle's `aria-expanded` in sync. Stepping with ←/→ must not un-collapse it.
- The candidate viewer's top row carries a **Proof control after the Code toggle**, in a `#csProofSlot` span that `csShow()` re-renders on EVERY step: `.btn-primary` "Proof" while the candidate has no proof, a `Proof ⬇` download link once it does. The listener is DELEGATED on the modal body (`e.target.closest('#csProofRun')`) because a direct listener is lost each time the slot is replaced. The job page feeds it: `#cs-candidates` carries `data-cs-job`, `data-cs-proof-url` (`validations_path`), `data-cs-csrf` (`form_authenticity_token`), and each playlist entry carries `proof` + `proof_url`. It submits a REAL form (not fetch) so the redirect/back-half flow matches the per-row `button_to`.
- The playlist JSON is built in an `<% %>` block above the tag, never inline: a nested ternary inside a hash inside a `data-*` attribute is unreadable and one edit away from breaking the tag.
- Any string the viewer splices into markup goes through `csEsc()` (aether.js) — candidate filenames come from the runner and are external input.
- Assertions about this UI must be form-aware: "the Proof run button is still there after stepping" FAILS once the sweep lands on a proofed candidate, because that is a download link. Assert on the SLOT (either form) and on what it describes, not on one id. Same family as the escaped-attribute trap: `data-cs-playlist` is HTML-escaped in the served page, so `grep '"proof_url"'` never matches — unescape the attribute first (`html.unescape`) and parse the JSON.
- Row-click navigation handler ignores clicks inside `form, a, button` so buttons in rows keep working — refined to `interactive && interactive !== el`, because the wired element can BE an anchor (a `pv-tile`) and a bare `closest()` check rejected the tile's own click so the popup never opened. Regression-test both halves: a nested anchor inside a `.rowlink` row does NOT open the viewer, and the row background still does.
- Jev answer cards render TYPED answers via `ApplicationHelper#jev_answer_view` — one card per question, value + optional legend note + confidence. Never read `ans["choice"]` (blank on `score`/`noul`) and never `if ans["confidence"]` (`0.0` is truthy in Ruby, so a `score` answer prints "confidence 0%"). The folded verdict is one restrained `mono` line above the grid: headline · route · low-confidence keys, no badge and no glow. Details: see the `chopshop-jev` skill (`references/jev-integration.md`).

## Modal action slot (scissor orb → new job)

The shared glass modal's head has ONE right-aligned action row (`.cs-modal-actions`): the scissor orb
first, then Open-in-tab, Download, Close. The orb is rendered by `ensureModal()` and shown only when
the opener passes `useUrl` to `openCsModal` — an action the popup cannot perform is never offered.
The carrier is the inverse preview tile, via `data-cs-use-url` (`use_inverse_job_path`) which the
plain-image viewer branch forwards. Clicking it POSTs (real form, CSRF from the page meta tag) to
`JobsController#use_inverse`, which fetches `source.inverse.png` from the runner, stores it under
`storage/uploads`, and redirects to the new-job form with `input_path`, `preview_url`, `name` and
`carried_from` prefilled — the operator names the run and hits the scissor. The twin is COPIED into
uploads rather than referenced in place: it lives in the old job's directory, which `destroy`
removes, and `storage/uploads` is the only input location the runner contract knows. Scoping
matters: a missing `data-cs-use-url` must leave the orb hidden (verified hidden on the source tile
and on the stepped candidate viewer), so any new "act on this file" button belongs behind the same
option rather than in the head unconditionally.

## Clickable-frame cards (the palette library)

**One home per collection.** The shop's palettes were rendered in TWO places: as
bare swatch rows in the colour map, and as full cards in a "Palettes" popup —
and the Palettes button opened the POORER copy (no ＋, no → bg, no notes, no
pinned maps). When you find the same collection in two views, check which one
the control points at before adding anything, and prefer deleting one: the
colour map now carries the real cards, the popup is gone, and the Palettes
button opens the map and scrolls the library into view (so picking a colour from
it still works — a way to the library, not a dead end).

The cards in the colour map have **no action button** — the whole card frame is the control (a request the user made explicitly: "remove the use this palette button, make the whole frame of each palette the clickable area"). Reproduce this pattern for any card that is itself the action:

- Put a real `<button class="pal-preset-hit">` inside the card as its FIRST child and lay it UNDER the content: `position:absolute; inset:0; z-index:0`, `border:0`, `padding:0`, `background:none`, `border-radius:inherit`. Lift the siblings with `.pal-preset > *:not(.pal-preset-hit) { position:relative; z-index:1 }` so inner controls (`＋`, `→ bg`) keep their own clicks. A `<button>` rather than a clickable `<div>` keeps it tabbable and screen-reader announced.
- Move the card's data onto the frame (`data-colours`) — the button that used to carry it is gone.
- The frame takes `cursor:pointer` + a hover state, and the focus ring goes on the FRAME via `.pal-preset:focus-within` (not `:has`), with `.pal-preset-hit:focus { outline:none }` so the ring is not drawn twice.
- Because the frame has no text of its own, the accessible name must carry the action: `aria-label="Use this palette: <name>, <n> colours"` plus a `title`. The phrase "Use this palette" therefore survives ONLY in `aria-label`/`title` — do not assert its absence by counting the string; assert on visible text (`>Use this palette<`).
- The delegated click handler must resolve the inner controls (`＋`, `→ bg`) FIRST and `return` — the frame branch matches any click inside the card, including one that bubbled from a child button. `stopPropagation()` cannot separate branches that live in the same listener, so the early `return` IS the contract; write that in a comment, because it is invisible otherwise. Pin it with a test that asserts the BRANCH ORDER in the source (set-bg, then add-one, then frame) — moving the library between containers does not break it in the browser and nothing else would notice.

## Log console (job page + Log popup)

- The running-job log is a tail, so the console FOLLOWS the newest output: `refreshLogConsole()` in aether.js replaces the contents and then pins `scrollTop`, and `bindLogFollow()` flips a `data-follow` flag off as soon as the operator scrolls away. Use an 8px tolerance (`scrollHeight - scrollTop - clientHeight <= 8`) — a strict equality check silently stops following under fractional line heights or zoom. Do the `innerHTML` write and the `scrollTop` write in the SAME task: the browser's scroll event then observes the final position and cannot flip `data-follow` off behind the code's back. Replacing `innerHTML` without re-pinning snaps the view to the TOP on every poll, which is exactly when the newest lines are the point.
- Console height is `max-height: 465px` on `.log-console` (~19 lines at 0.8rem/1.7) — the live job log is the one console watched for minutes, so it gets the extra lines; modal consoles override with `max-height:none`.
- Inside a modal the console has `max-height:none`, so the SCROLLER is `.cs-modal-body` (`overflow-y: auto`). Pin `#csModalBody.scrollTop`, not the console's — the Log popup's snapshot should land on the newest lines while still allowing a scroll up.

## Upload (jobs#upload)

- Squarish rounded upload tile (288×115) → on pick, uploads → becomes a 2-line thumbnail (96px, checkerboard-backed) + filename/size + remove ×. The preview is sized to MATCH the tile it replaces, because the two are swapped at runtime: a mismatch changes the row's height and nudges the action buttons off the alignment you just measured.
- Server-side: extension allowlist (.png/.jpg/.jpeg), 50MB cap, magic-byte sniff (PNG `89 50 4E 47`, JPEG `FF D8 FF`) — rejects extension liars with a flash alert
- Files land in `storage/uploads` (private, never nginx-served); Rails returns `{path, preview_url, name, size}` for the hidden input_path field, and the preview is served login-gated through the `upload_preview` action — not a public URL

## Forms

- Spec JSON section on `/jobs/new` is a permanent half-width column beside the form — it is NOT collapsed behind a toggle heading any more (the old `display:none` accordion meant the one thing that configures the run was hidden until asked for). The `/json` builder still hands its spec over via a POST + session handoff.
- **The `form_with` block must WRAP both columns, not just the left one.** Putting the contract `<textarea>` beside the form as a sibling of `<%= form_with %>` looks right in the DOM and silently drops the field on submit — it is outside the `<form>`, so no `job[spec]` param is posted. Assert the field is inside the form element, not merely present on the page.
- The Run Job submit is a labelled **"✂ Run Job"** pill (72px tall, `border-radius: 999px`, `width: auto`) that shares a line with the upload tile, flush right via `margin-left: auto` on `.actions-row-buttons`. A bare ✂ circle had no room for the words. When a `title`/`aria-label` says something different from the visible label (it once said "Trace it"), that mismatch is a live bug — screen readers announce the stale name. There is NO Cancel button on that line: the nav and browser back are the way out, and the pair read as two competing calls to action on a line that already has the picker.
- `/json` builder generates the spec live and hands it to the run form via a POST + session handoff
- The builder owns the SWEEP axes in a **Sweep** card (`print.sweep`: presets / max_candidates /
  filter_speckle / hierarchical / use_palette), because otherwise the presets a job traces are not
  in the contract at all. Multi-value axes are inline checkbox groups (`.check-row` + `.check`),
  which need `width:auto` overrides on `.field input` (the shared rule is `width:100%` and would
  stack them one per line). `use_palette` is a both/off/on select and is omitted when set to both,
  since both IS the pipeline default. The builder JS binds by id, so a new axis must be added to
  BOTH the markup and the `querySelectorAll(...)` input/change binding list or the spec never
  rebuilds.
- `max_candidates` lives in the Sweep card ONLY. It was once in both Sweep and Print & tolerances,
  and resolving one knob in two places is what let a `max_candidates: 3` spec produce 12 candidates.
- `/json` colour input is a hex text field + a non-interactive preview swatch + a quick-pick swatch row. The native `<input type="color">` was removed because its OS-picker eyedropper cannot sample colours outside the browser window, so it never worked for picking from artwork — do not reintroduce it expecting eyedropping to work. The Colour Spec card is an explicit 2×3 GRID, not two stacked flex columns and not a vertical order: row 1 `max_colors`; row 2 preset swatches | selected-colour chip strip; row 3 hex selector + ✂ scissor orb | **Palettes** button. The bottom row is the point — a control that FILLS the thing beside it (the library button loads a whole palette into the strip) belongs on that same row, and two independent columns cannot express it, so both bottom controls are direct grid children in row-major source order pinned by `grid-row`/`grid-column`. The hex box is content-sized (`12ch`, full border/radius/focus, height matched to the swatch) — a 7-character value must never be stretched to the column, and an unstyled input renders 20px tall beside a 34px swatch. Its width must have real slack (measured 18.5px), since a 2px margin looks clipped. `palette-tool.css` loads AFTER `application.css`, so gap overrides must double the selector (`.colour-set-picker, .colour-set-col .colour-set-picker`) to win on equal specificity. The palette textarea (`#f_palette`, the `#rrggbb` source of truth) stays hidden below both columns, and its line order must be preserved verbatim by any chip action, because the operator may be mid-typing a line.

## Buttons & effects

- `.btn-primary` is the brand CTA (blue→pink gradient). It carries a spinning conic-gradient glow ring: a negative-inset (`inset:-3px`) blurred `::after` in the theme colours (blue→pink→cyan) at `z-index:-1`, driven by an `@property --angle` keyframe. `.btn-primary` sets `isolation:isolate` so it is ALWAYS its own stacking context — do not "fix" that back to a context-free button. The ring is `z-index:-1`, so where it paints depends on the nearest stacking context, and leaving that to chance meant the ring resolved against the ancestor (behind the button, barely a fringe) on a fresh page but inside the button (over its fill — the visible glow) as soon as `aether.js`'s magnetic hover had put a transform on it. Pinning the context makes the lit look the resting look. Recolour the ring to the theme palette, never the example's generic red/green/blue.
- The glow that actually READS on screen is the ambient `box-shadow`, not the conic ring — measured, the ring alone contributes ~90 saturated px around a button while the shadow takes it past 2000. It must therefore be on at rest: `.btn-primary` carries `0 20px 60px rgba(99,102,241,0.5)` and hover only deepens it. It was `0 10px 40px` at rest and `0 20px 60px` on hover only, which is why the buttons looked inert until the pointer crossed them.
- `.btn-primary.btn-sm` gets a tighter ambient shadow (`0 6px 20px`) because ten per-row Proof buttons at full strength fill the rows between them. The RING still applies to every `.btn-primary` including `btn-sm` — never re-add a btn-sm exclusion. That said, glow strength is a function of REPETITION, not of the action: the candidates table's Proof buttons additionally carry `.cs-proof-btn`, which damps `::after` to `opacity: 0.62` (the sticky header's value, so the two match exactly) with hover/focus restoring `1`. The LONE Proof button in the candidate viewer popup (`.cs-proof-run`, built in an `aether.js` string) must NOT be damped — one control on screen is not too much highlight. Assert both directions; the popup side is a one-line JS edit no view test would catch. When matching one ring's recipe to another's, assert the RENDERED MOTION (duration/timing/iteration/direction + `filter` + `backgroundImage`), never `animationName` — the header uses `logo-angle-spin` and buttons `btn-angle-spin`, so a name comparison reports a false mismatch on two identical effects.
- ALL `.btn-primary` glow, `btn-sm` included — do not reintroduce a btn-sm static-look exclusion (the user noticed "Add colour", a `btn-sm`, had no effect and wanted it glowing too). "Run Job" needs `f.button`, not `f.submit` — an `<input type="submit">` can't host the `::after` ring (see SKILL.md).
- `@property --angle` needs Chrome/Edge/Safari 16.4+ and Firefox 128+. Older browsers get a static (non-spinning) ring — graceful degradation, so do not add a JS fallback.
- The logo mark and the login-page submit are both a large round ✂ (scissors): the login submit is `.login-scissor` (92px circle) with `aria-label`/`title` "Enter the shop" so the visible text is replaced but the meaning is retained.
- The topbar logo carries a WHITE spinning highlight (`.logo-icon::after` = a blurred white conic band just outside the edge, `z-index:-1`; `::before` = a softer band over the icon face; the wordmark gets the same band clipped to its glyphs), all driven by the same `@property --angle`. White, not the brand gradient, so it reads as a specular highlight and not a second CTA. `nav.topbar` has `backdrop-filter`, so it already provides the stacking context the ring resolves against — but `.logo-icon` still must not create one of its own for the `z-index:-1` ring to sit behind the icon's gradient.
- Keep that highlight SUBDUED: the operator asked for it to come down after it shipped too hot, and the tuned values (alpha 0.85 + opacity 0.72 on the ring, 0.36 on the face sweep, 0.75 on the wordmark band) measure ~75% of the previous intensity. It is a sheen, not a beacon — do not restore the original 0.95/0.85. The 4s period is deliberate too: timing is character, so slow it only on request.
- The wordmark is an OUTLINE (transparent fill + `-webkit-text-stroke`) **because of the highlight**: `--text-primary` is `#f8fafc`, so the name is already white and a white band over a solid white fill is invisible — hollowing the glyphs is the only way the highlight reads. Never "fix" the wordmark back to a solid fill while the highlight is there. Both are behind one `@supports ((-webkit-background-clip: text) and (-webkit-text-stroke: 1px #fff))` guard, because `color: transparent` without the stroke support erases the name; unsupported browsers keep the original solid colours. Under `prefers-reduced-motion` restore the solid mark rather than leaving the band parked on one letter.

## Background engine (aether.js, extracted from Aether.html)

- Particle canvas + gradient-mesh canvas + three orbs: `.orb-1` indigo top-right, `.orb-2` pink bottom-left, `.orb-3` center cyan (subdued — see SKILL.md)
- Pinning an orb behind an element (e.g. `.orb-3` behind the login scissor button): measure the target with `getBoundingClientRect()`, set the orb's `left`/`top` to the target's centre, `transform:translate(-50%,-50%)`, and `animation:none` to kill its float. Two pitfalls — (1) the orbs are created by aether.js on `DOMContentLoaded`, which fires AFTER the inline login `<script>`, so a bare `querySelector('.orb-3')` returns null: wait with a `MutationObserver` on `document.body` (childList) and disconnect once it appears, then re-pin on `resize` and `load` (fonts settle and shift the layout). (2) `trackOrbs()` in aether.js rewrites every `.bg-gradient-orb` transform on each mousemove for parallax — it will override the pin. Tag the pinned orb with an `orb-pinned` class and make `trackOrbs` skip it, or the pin silently un-does itself as soon as the mouse moves.
- Custom cursor (fine pointers only): core + orbit + trail; magnetic hover on `.btn`
- Background canvases are created once and persist across Turbo visits — don't recreate on navigation
- Original Aether source is `~/Public/Aether.html` (unminified single-file site). To port a feature, find its `<canvas id=...>` block plus the matching `mousemove` handler and `animateX()` loop, then adapt: DPR-scale the canvas (`ctx.setTransform(dpr,0,0,dpr,0,0)`), use `addEventListener` rather than inline listeners, and cap the particle array to avoid unbounded growth.
- Two distinct interactive canvas features in that source — do not confuse them: "draw as you move" (`<canvas id=interactiveCanvas>`) spawns particles at the cursor with fade/grow, and "neural" (`neuralCanvas`) makes particles ACCELERATE TOWARD the cursor. Only port the neural one if that is specifically what's asked for.
- Login-canvas tuning easter egg: triple-click the "Chopshop Studio" title (3 clicks within 5s) unlocks a tuning popup; once unlocked, a single click re-opens it. Sliders (node spawn / lifetime / link range) are hard-capped at the shipped canvas defaults and scale down to zero. Give the title `user-select:none` so arming the triple-click doesn't select text. The popup reuses `CsModal.open` with a `cs-modal--tune` modifier (docked bottom, backdrop cleared so the live canvas stays visible) that MUST be stripped on close — pass an `onClose` callback to `CsModal.open` that removes the modifier, so the dock/clear-backdrop look never leaks onto other modals (palette popup, Report/Log/Raw).

### Perf — the login page is the heaviest page on the site

- `cursor:none` hides the OS cursor in favour of the JS custom cursor, so when the main thread stalls the mouse literally vanishes and nothing responds — a compositing hitch reads as a hard freeze ("won't even refresh"), NOT a server outage. When a "server frozen" report lands, check server health first (ports, load, `/up`, logs): the tuning panel and every canvas effect are pure client-side and cannot hang Rails.
- Both particle canvases run an O(n²) pairwise link check every frame. Use squared-distance early-exit (`var d2 = dx*dx + dy*dy; if (d2 < range2)`) and only `Math.sqrt` for in-range pairs — the naive `Math.sqrt`-every-pair form wastes ~90% of its sqrt calls and stalls the tab on integrated graphics.
- The 260px orb blur is the priciest filter on the page; when pinning an orb keep it subdued but tighten to blur 140px rather than layering more blur on top of it.

## Per-page form layout (moved out of SKILL.md)

- JSON spec builder page (`pages/schema.html.erb`) is FOUR cards in a `grid-2` of two `card-stack` columns (Sweep and Prep — expanded were folded into their parents): LEFT — **Job Spec** (top: `print_method` + geometry `min_stroke_width_pt`/`max_nodes_per_path`/`allow_raster_embed`/`allow_gradients`/`allow_open_paths`, PLUS the Sweep fields folded in — presets bw/poster/photo, `max_candidates`, `filter_speckle`, hierarchical cutout/stacked), then **Print & tolerances** (bottom-left: dpi, ink_limit, count_white_as_ink, ink_merge_tolerance). RIGHT — **Prep** (top: `invert`/`invert mode` `.prep-row` PLUS the opt-in benches folded in — filters/tune/node_reduce + params), then **Colour Spec** (bottom-right; NOT "colour set" — the operator corrected the name). So Print & tolerances is bottom-left and Colour Spec bottom-right. All four are NORMAL grid cards; none is full-width, and adding `grid-column: 1 / -1` unprompted was wrongly done twice and rejected both times — Colour Spec sits bottom-right under Prep, Print & tolerances bottom-left under Job Spec. Colour Spec's own layout (top to bottom): a top band `.colour-set-row.colour-set-row-2` = `pitch_shift` | `use_palette` (`use_palette` was MOVED here from Job Spec — it and `pitch_shift` are the two "how colour becomes the palette" axes, so they share the top row); then a second `.colour-set-row.colour-set-row-2` = `background_hex` | `max_colors` (`max_colors` moved UP here from the lower grid to fill the gap the short hex field left beside it; `background_hex` stays a `.pal-picker.hex-pair` — swatch + hex box as one 48px band); and finally a `.colour-set-pair` `1fr auto` grid holding the spec's own chips (`current selected colours`, `.pal-strip` + `.pal-count`) and the **Colours** button (`.colour-set-lib-cell`) sitting BESIDE the strip, not full-width below it — a full `.btn` the same height as the page-head Run Job button, not `btn-sm` and not a fixed height, filled `--btn-plain` with a `--btn-plain-hover` lighter opaque fill + `--primary` border + lift on hover (its hover had been suppressed while it sat quiet beside the now-gone orb). The add-colour picker (swatch + hex + ✂ scissor orb, `.pal-picker.colour-set-picker`) is GONE: colour addition now goes ONLY through the palette library's ＋ and `background_hex`. The hex box is sized to its content, not the column: `.pal-picker.hex-pair input[type="text"] { width: 12ch; flex: 0 0 auto; height: 48px; text-align: center }`. `12ch`, not 7ch: `ch` is the width of a "0" and `#rrggbb` mixes digits with the wider "#" and lowercase letters, so a bare 7ch clipped the value. The selector is compound (`.pal-picker.hex-pair`) for doubled specificity: `palette-tool.css` loads AFTER `application.css` and its `.pal-picker input[type="text"] { width: 100px }` would otherwise win the cascade and stretch the box; `.field input { width: 100% }` is the same trap for a full-width `#rrggbb`. Grep for the retired classes/ids before assuming they exist: `.colour-set-picker`, `.colour-set-grid`, `.colour-set-actions`, `.colour-set-side`, `.colour-set-col`, `.colour-set-strip`, `.colour-set-lib`, `pal_hex`, `pal_swatch`, `pal_add`. **The side-by-side contract column belongs to the RUN JOB page, NOT this one.** An earlier attempt built it here and was reverted: the operator asked for the Run Job page and it was written into this view instead, because this view was the file already open. The JSON page keeps its `#spec-popup` / `.spec-frame` proximity-reveal popup, the textarea-based `out.value` builder, and the `useSpecBtn` + `useSpecBtnMain` orbs bound from one id list. The permanent always-visible contract column lives in `jobs/new.html.erb` — see the Run Job page entry below. Its title row is a `.page-head-row--split` holding the title and a `.page-head-actions` stack of exactly TWO labelled buttons, both right-aligned: **Run Job** (`#useSpecBtn`, a plain `.btn.btn-primary` in the same slot and size as the Jobs list's own) on the first line, and **JSON** (`.btn-secondary.btn-sm`, `data-popup="spec-popup"`) on the line BELOW it. Both are plain words — no ✂ glyph, no leading ＋, and the JSON button is not an SVG icon. The earlier `useSpecBtnMain` / `.btn-scissor-lg` Run Job card on this page was REVERTED; do not reintroduce it. Copy is a labelled `.btn-secondary btn-sm` inside the popup, not a ghost icon. Run Job does NOT submit directly: the POST is extracted into `submitSpec()` and the click opens a `window.CsModal.open('Confirm?', …)` confirm carrying a warning, a `<pre class="cs-confirm-json">` preview of the EXACT bytes about to be posted, a Cancel and a **Run Job** confirm button (not the orb). Both pages MUST present that same confirm — same `Confirm?` title, same Cancel, same Run Job button — so the one irreversible action looks identical wherever it is triggered from. Keep the `if (!window.CsModal) { submitSpec(); return; }` fallback so the button still works if the modal module fails to load. The old standalone "Job" card and "Geometry" card were merged into Job Spec (print_method folded in). Field IDs are stable (`f_pitch_shift`, `f_bg_hex`, `f_max_colors`, `f_palette`, `f_print_method`): the builder JS binds by id, so KEEP the ids when moving fields between cards or the JSON builder silently stops writing them. `.print-grid` is two 50/50 columns (`1fr 1fr`) shared by Job Spec (6 fields) and Print & tolerances (5 fields, last cell empty), both flowing row-major. All these grids collapse to `1fr` under 900px.

- **Run Job page (`jobs/new.html.erb`)** is a `.run-grid` of two 50/50 columns that stacks under 900px, INSIDE a single `form_with`. Left: `.run-form-col`, the form card, which lost its old `max-width:760px` cap. Right: `.run-contract-col`, the job contract JSON, which is now ALWAYS VISIBLE — it used to be a COLLAPSED accordion (`display:none`) behind a `#specToggle` button, which meant the one thing that configures the run was hidden until asked for. (These are the real class names; `.run-job-grid` / `.run-form` / `.run-contract` are the earlier draft's and do not exist — grep before assuming.) `#specToggle` and its handler are gone, the Copy action is `#copySpecBtn`, and a stale handler left behind makes `copyBtn.closest('.spec-frame')` null and throws on load. The contract stays a `<textarea name="job[spec]">` (hand-editable and submitted), unlike the read-only `<pre>` shape used elsewhere, and its default is built with `JSON.pretty_generate` so it renders as ~23 lines with a longest line near 33 chars. The `form_with` WRAPS both columns — see the form-boundary pitfall. The run action is the PAGE-HEAD button `#runJobBtn` — a plain `.btn.btn-primary` reading **Run Job** in the `.page-head-row--split`, the same slot and size as the Jobs list's own button, so the two pages are visibly the same control. It is `type="button"` and sits OUTSIDE the `<form>` on purpose, so it can gate the submit: the click refuses inline if no artwork is loaded, then opens `window.CsModal.open('Confirm?', …)` with Cancel and a **Run Job** confirm, and only the confirm calls `requestSubmit()`. There is no button left in the form's footer — the `.actions-row-buttons` wrapper and the ✂ Trace orb are both gone, and the operator also removed the Cancel link, so browser back and the nav are the way out. A ✂ orb cannot hold the words "Run Job" while `border-radius: 50%`, so a labelled action is a PILL (`border-radius: 999px`, `width: auto`, real horizontal padding) at a constant height; and a higher-specificity override only clears the properties it NAMES, so the base `.btn-scissor`'s `width: 48px` survives unless the override states `width: auto` itself. The upload row is now just `.actions-row.upload-actions` holding `.artwork-field`, and the upload hint is a SIBLING below that row, not a child, because a wrapping hint inside the row dragged its contents ~55px off the tile's line. Once artwork is uploaded, `.upload-thumb` takes `flex: 1 1 auto; min-width: 0` and fills the section's WIDTH while `.upload-thumb img` stays fixed at 96px, so the section never grows vertically on upload (the old `max-width: 220px` on `.upload-thumb-meta` left the extra width unusable). 
