# Reference: body-swapping buttons — how `chopshop-studio` shows two renderings of one thing

**Status:** guidance, not a directive. Nothing here is a spec for how the settings
UI in this repo *must* look. It is a read of one working implementation, recorded
because its handling of density is good and the reasoning is portable.

**Source:** `geeeze/chopshop-studio` @ `99e36d2` (Rails 8 + Propshaft +
importmap-rails, hand-written CSS, no Tailwind, no component library).
All line numbers are from that commit.

---

## 0. What this actually is

Not a tab bar, and not a nav. **A row of small buttons that swap the body of the
region underneath them to entirely different content — the same data, re-rendered
into a different shape.**

The pattern appears three times in this repo, always the same mechanism:

| Where | Buttons | What the body becomes |
|---|---|---|
| Jobs index | `List` / `Grid` | a table of runs → a grid of thumbnail cards |
| Job page, candidates | `List` / `Grid` | a table with gate columns → a dense grid of tiles |
| Tournament bracket | `Left to right` / `Mirrored` | a conventional bracket → the same tree folded at the root |

It is a tab in *behaviour* — one body region, N renderings, chosen by a click —
and deliberately not a tab in *markup*: the bodies are siblings in the document,
not `role="tabpanel"` children keyed to a `role="tablist"`. §6 explains why that
distinction is the whole point.

The mechanism itself is about 25 lines. The density win is not in the mechanism.

---

## 1. The control: `.view-toggle`

```erb
<div class="view-toggle" role="group" aria-label="Jobs view">
  <button type="button" class="btn btn-secondary view-toggle-btn"
          data-view-toggle="list"  aria-pressed="true"
          title="List view — the table">List</button>
  <button type="button" class="btn btn-secondary view-toggle-btn"
          data-view-toggle="grid" aria-pressed="false"
          title="Grid view — thumbnails">Grid</button>
</div>
```

`app/views/jobs/index.html.erb:36` · `app/views/jobs/show.html.erb:290` ·
`app/views/pages/tournament.html.erb:27`

```css
.view-toggle { display: inline-flex; gap: 0; }
.view-toggle .view-toggle-btn {
  height: 2rem; padding: 0 0.7rem; min-width: 0; border-radius: 0;
  color: var(--text-secondary);
}
.view-toggle .view-toggle-btn:first-child { border-radius: var(--radius-md) 0 0 var(--radius-md); }
.view-toggle .view-toggle-btn:last-child  { border-radius: 0 var(--radius-md) var(--radius-md) 0; }
.view-toggle .view-toggle-btn + .view-toggle-btn { margin-left: -1px; }
.view-toggle .view-toggle-btn.is-active {
  background: rgba(99, 102, 241, 0.18);
  border-color: var(--primary);
  color: var(--text-primary);
}
```

`application.css:1775-1802`

Five properties, each a deliberate decision with the reasoning in a comment
beside it:

1. **`gap: 0` — the halves touch.** The single most important line. Two buttons
   with air between them read as two separate actions; joined into one box they
   read as **one switch with two stops**. That is the entire visual difference
   between a tab bar and a pile of buttons, and it is one declaration.
2. **Only the outer corners round.** `border-radius: 0` on the button, with
   `:first-child` / `:last-child` each rounding one side. The inner seam stays
   square, so the two halves form one pill.
3. **`margin-left: -1px` on the second child.** Collapses the two 1px borders
   into one where the halves meet, the way a real segmented control does.
4. **`height: 2rem` against the page's measured `2.75rem` actions.** The source
   is blunt: *".head-action is a measured 2.75rem-tall, 7.325rem-wide page action,
   which is the right size for 'Run Job' and the wrong size for a display
   switch."* A mode switch sized like a page action competes with the page's real
   actions for the same attention.
5. **`aria-pressed`, not `aria-selected`.** It is a toggle group, not a tablist.
   The ARIA follows the behaviour, not the resemblance.

### Where it sits

Three placements, each justified in the source, and the reasoning transfers:

- **Page head, right column, under the primary action** (`jobs/index.html.erb`).
  The grid is `1fr auto`; the title is pinned row 1 col 1 and the blurb row 2
  col 1, so auto-placed Run Job lands row 1 col 2 and the toggle lands row 2
  col 2 — directly beneath it, right-aligned. The comment notes that giving it
  an *explicit* row/column would put it in the same cell as Run Job, and
  squeezing it beside that button would mean widening the grid the other eight
  page heads share.
- **Inside the card it controls** (`jobs/show.html.erb:288`, in `.cand-view-bar`,
  beside the "Candidates" heading):

  > In the LIST card's head, not the page head: it controls the candidates list,
  > and the page head's controls act on the JOB.

  A mode switch belongs to the region it switches, not to the page.
- **Above the content, standalone** (`tournament.html.erb:27`).

---

## 2. The bodies: siblings, both always rendered

```erb
<%# #jobs-list-view: the table, wrapped so the toggle has one element to hide. %>
<div id="jobs-list"> …table… </div>

<%# #jobs-grid-view: the same runs as cards … Hidden in the markup so a JS-less
    page shows the table, and so the default is 'list' without the script having
    to run. %>
<div id="jobs-grid" hidden> …grid of cards… </div>
```

`app/views/jobs/index.html.erb:42, 74` · `#cs-cand-list` / `#cs-cand-grid` at
`show.html.erb:292, 392`

Four properties, all load-bearing:

- **Both renderings exist in the document at all times.** Nothing is built on
  click, nothing is fetched. The swap is a single attribute flip — so there is no
  loading state and no flash of an empty panel.
- **Each body is one wrapper element.** The table gets a wrapper purely so the
  toggle has one thing to hide; the source says so.
- **The inactive one carries `hidden` in the markup**, not "hidden by the
  script". A JS-less page shows the table, and `'list'` is the default without
  the script having to run at all.
- **The grid is deliberately lower-information than the table.** `jobs/index`
  drops the runner column and all headers: *"Deliberately LOW information: no
  runner column and no headers (the table is where you read those), so a card
  stays a picture you recognise rather than a paragraph."*

That last point is the design thesis, and it is the part most worth taking:

> **A mode switch earns its place only if each mode is edited for its job.** The
> table drops to a picture; the grid drops the numbers. If both modes were the
> same content at two widths, the switch would be pure cost — and this codebase
> would not have built it.

It is also the test for whether a third mode should be added. Two renderings that
differ in *what they are for* justify a switch. A third that differs only in
density does not, and should be a density control on the existing body instead.

### The `[hidden]` guard is mandatory, not optional

```css
[hidden] { display: none !important; }
```

Every `.btn` in this codebase sets its own `display`, which would otherwise beat
the `hidden` attribute's UA rule. Without the `!important` guard, `hidden` is
silently ignored on anything with a class that sets `display` — the classic
attribute-vs-stylesheet specificity trap. The source calls it out at both use
sites.

---

## 3. The swap: ~25 lines, and five decisions in it

```js
var KEY = 'chopshop.jobsView';

function readView() {
  try { return localStorage.getItem(KEY) === 'grid' ? 'grid' : 'list'; }
  catch (e) { return 'list'; }
}

function apply(view) {
  var grid = view === 'grid';
  var list = document.getElementById('jobs-list');
  var cards = document.getElementById('jobs-grid');
  if (list)  list.hidden = grid;
  if (cards) cards.hidden = !grid;
  document.body.classList.toggle('jobs-view-grid', grid);
  document.querySelectorAll('[data-view-toggle]').forEach(function (btn) {
    var on = (btn.dataset.viewToggle === 'grid') === grid;
    btn.classList.toggle('is-active', on);
    btn.setAttribute('aria-pressed', on ? 'true' : 'false');
  });
}

function writeView(view) {
  try { localStorage.setItem(KEY, view); } catch (e) { /* forget it, show it */ }
  apply(view);
}

if (!window.__csJobsView) {                    // bind ONCE
  window.__csJobsView = true;
  document.addEventListener('click', function (e) {
    var btn = e.target.closest('[data-view-toggle]');
    if (!btn) return;
    e.preventDefault();
    writeView(btn.dataset.viewToggle === 'grid' ? 'grid' : 'list');
  });
  document.addEventListener('turbo:load', function () { apply(readView()); });
}

apply(readView());
```

`app/views/jobs/index.html.erb:224-280` (the candidates version is the same shape
at `show.html.erb:610-666`)

1. **Three writers, and they are not redundant.** `hidden` on the two wrappers is
   what actually swaps them. The class on `<body>` exists so CSS can key off the
   mode. The `is-active` / `aria-pressed` pair is the control's own state. Three
   consumers, three different needs — collapsing them would break one.
2. **The listener is delegated from `document` and bound exactly once** behind a
   `window.__csJobsView` guard. The script re-executes on every Turbo visit; a
   per-visit binding would stack listeners, so the second click would fire twice.
   The most copyable line in the file.
3. **`apply()` re-runs on `turbo:load`** because Turbo replaces `<body>`, and the
   freshly-swapped-in body starts in the markup's default state — `'list'`, hidden
   grid. Without the re-apply, a user who chose Grid gets List after any
   navigation.
4. **Every `localStorage` call is individually try/caught.** A private-mode
   browser throws on *both* read and write, and the comment is explicit that the
   page must still work — it just forgets. A missing guard here takes out the
   toggle entirely in private mode.
5. **Null-guards on the elements** (`if (list)`, `if (cards)`) so the same
   `apply` runs on a page carrying only one of the two bodies.

### Storage keys are per-instance, never shared

The candidates toggle is its own script with its own key, and the reason is
written down:

> Its own script and its own storage key, NOT the Jobs index's — the index's key
> holds the JOBS view, and sharing one would make switching the candidates flip
> the jobs list the next time you visit it.

`jobs/show.html.erb:610-616`

This is the failure mode of a shared preference: two unrelated controls, one key,
and the second visit to an unrelated page silently changes a view the user set
days ago. **One key per toggle, named for what it toggles.**

---

## 4. The same idea applied to a settings surface

The FLUX page's head carries a pair of small uppercase buttons that open dialogs
rather than navigate:

```erb
<div class="head-action-pair head-action--below">
  <button class="btn btn-secondary head-action" data-popup="flux-models-popup"
          title="The model registry, licences and schedules">MODELS</button>
  <button class="btn btn-secondary head-action"
          data-popup="datasets-popup" data-popup-url="…"
          title="The prompt library and the labels">DATASETS</button>
  <button class="btn btn-secondary head-action" data-popup="flux-conf-popup"
          title="View the generated service configuration as JSON">JSON</button>
</div>
```

`app/views/pages/flux.html.erb:13-27`

```css
.head-action-pair { display: flex; gap: var(--space-sm); align-items: stretch; }
```

`application.css:2832`

**Two buttons that belong together share ONE grid cell and flex inside it, so the
head stays two lines tall instead of three.** The pair is what the grid places,
not the buttons. That is the anti-overwhelming move at page-head scale, and it is
the same idea as `gap: 0` on the segmented control: group first, then items.

The ordering is a recorded decision:

> A PAIR, like the Jev head: MODELS first because the licence and the VRAM are
> what decide the settings on this page, so they are what you reach for when a
> setting looks wrong. JSON second.

Order by *when the operator needs it under duress* — not alphabetically, not by
implementation order.

The label stays a 5-character uppercase token and the one-line purpose lives in
`title`, so the affordance row costs almost no width and still carries meaning.

### The dialog shell those buttons open

Every dialog is the same three-part shape, written per dialog in ERB with no
component behind it — the *shape* is the convention, and tests enforce it.

```erb
<div class="popup" id="flux-settings-popup" role="dialog" aria-modal="true"
     aria-labelledby="flux-settings-popup-title" hidden>
  <div class="popup-panel popup-wide">
    <header class="popup-head">
      <h2 id="flux-settings-popup-title">FLUX settings</h2>
      <button type="button" class="popup-close" data-popup-close aria-label="Close">&times;</button>
    </header>
    <div class="popup-body"> … </div>
  </div>
</div>
```

`app/views/jobs/new.html.erb:570-577`

- **`hidden` on the root, not a class.** The dialog is in the DOM from first
  paint; `.popup[hidden] { display: none; }` (`:4228`) is the only reason it is
  invisible. "Which dialog is open" is one queryable attribute, and there is no
  class to forget to remove.
- **The close control is a glyph, never a word.** 1.85rem square, `&times;`:

  > Every popup dismisses the same way: a single × in the head's top-right
  > corner, plus a click on the backdrop and Escape. One mechanism, so no popup
  > drifts into a word button or an icon.

  A word button costs panel width and reads as a decision; a glyph costs nothing
  and reads as furniture.
- **Three dismiss routes, one function** — the ×, a backdrop click that is
  *exactly* the backdrop (`ev.target === pop`), and `Escape`.
  `app/javascript/aether.js:1745-1871`. The `keydown` note is worth keeping: a
  click listener has no `.key`, so the original Escape handler was dead code and
  Escape closed nothing.

**Panel widths are chosen per content, in `rem`/`vw`, never `%`:**

```css
.popup-panel       { width: min(46rem, 100%); }   /* settings list — the default */
.popup-wide        { width: min(68rem, 100%); }   /* a page of cards */
.popup-terminal    { width: 39vw; min-width: 26rem; }
.popup-remediation { width: 67vw; min-width: 30rem; }
```

`application.css:4246-4271`

The `%` warning is real and was learned the hard way: `.popup` carries
`clamp(1rem, 4vw, 3rem)` padding, so a percentage resolves against the *content
box* — `width: 60%` measured 55.6% of the window.

---

## 5. Inside the dialog: the density rules

The FLUX settings dialog (`jobs/new.html.erb:570-870`) carries ~40 controls. Four
rules keep it readable.

**1. Two-column grid, collapsing to one.** `.print-grid { display: grid;
grid-template-columns: 1fr 1fr; gap: var(--space-md); align-items: start; }`
(`:2628`), and `1fr` under `max-width: 900px` (`:2673`). Plus
`.print-grid > .field { min-width: 0; }` — without it a long `<select>` refuses
to shrink and blows the column out.

**2. Section headings inside the scroll, not more sections on the page.**

```erb
<h4 class="flux-settings-h">Raster passes — before tracing</h4>
<p class="hint">…</p>
<div class="print-grid"> … </div>
<h4 class="flux-settings-h">Sweep — what gets traced</h4>
```

An `<h4>` partitions without restarting the document. A page `<h2>` would read as
a new page starting mid-dialog.

**3. Every control carries a one-line hint, and the hint carries the judgement.**

```erb
<label for="flux_guidance">guidance</label>
<input type="number" id="flux_guidance" step="0.1" placeholder="the model's">
<div class="hint">1.0 on distilled klein, 0.0 on sdxl-turbo, 4.5 on Sana Sprint. On a
  distilled model with no guidance embedding it is ignored, and the service says so in
  its warnings; on Sana Sprint guidance is embedded and IS honoured.</div>
```

Three lines of prose containing the per-item defaults, the exception, *which way*
the exception goes, and where the service will tell you. Rendered
`font-size: 0.75rem; color: var(--text-tertiary)` (`:1455`) — visually recessive,
so forty hints do not shout while still being there to be read.

The hints are written as decisions with numbers, not as descriptions:

- Weak: "Number of inference steps."
- Here: *"4 on distilled klein, 2 on the turbo, 28–30 on the undistilled
  checkpoints. Slow to change: this is the denoise loop."*

The second half matters as much as the first. *"this is the denoise loop"* tells
the operator this is a different class of knob from `variations` — without adding
a control or a heading.

**Placeholders name *whose* default applies.** `placeholder="the model's"`,
`placeholder="16 — the pipeline's default"`, `placeholder="random"`. A blank field
does not mean zero. That removes a whole class of "did leaving this blank do
something?" anxiety without adding one control.

**4. Conditional controls are hidden, not disabled.** `#fluxNegPromptField` is
`hidden` and the model `<select>` drives it via `data-negprompt` / `data-img2img`
flags on each `<option>`. Where a `<select>` cannot hide an option, the JS
rebuilds the list down to the chosen model's targets, so an adapter that cannot
load is never offered:

> a modifier that cannot load is never OFFERED (a load that fails after the GPU
> has been paid for is the expensive way to learn this)

`jobs/new.html.erb:656-666`. Never-offer beats offer-and-fail, and both beat
disable-because-deprecated.

**One contract preview, always visible.** `<p class="spec-frame mono"
id="fluxSettingsPreview">` at the bottom of the dialog, written by the same writer
that composes the hidden fields. The prose above the grid says so: *"Everything
here lands in the spec … and the contract on the right is where you can see it."*

Every popup in the app is allowed exactly **one** terminal-ish well, and it is the
same visual object every time (`application.css:4283-4320`):

```css
.popup-terminal .popup-head h2 { font-family: var(--font-mono); color: var(--text-secondary); }
.spec-terminal {
  background: #0b0d10; color: #7ee787; caret-color: #7ee787;
  border: 1px solid #21262d; border-radius: var(--radius-sm);
  padding: 1rem 1.1rem; line-height: 1.55; font-size: 0.85rem; tab-size: 2;
}
```

> Terminal styling: a dark, recessed well with phosphor text, so the panel reads as
> "raw contract" rather than as a form field.

The head `h2` drops to mono and to secondary colour in terminal mode — the dialog
*changes character* when it shows raw output instead of controls. One CSS
declaration doing a lot of work.

The copy control is a **proximity-revealed ghost** pinned over the well
(`:4330-4370`): `opacity: 0` until the pointer nears it or it takes focus,
`translateY(-2px)` → `0`. No label, so zero added height. And it copies the
**form field**, not a re-serialisation:

> Copy the contract. The textarea is the form field, so the bytes copied are the
> bytes that will be posted — not a re-serialised approximation.

If there are two representations of one thing, the one the user acts on is the one
you copy.

---

## 6. Why it is not a tab bar — the transferable part

A conventional tab implementation is `role="tablist"` > `role="tab"` >
`role="tabpanel"`, with the panel usually rendered lazily. This codebase's version
is deliberately the other thing, and four of its choices are why it stays calm:

- **No ARIA tab semantics.** `role="group"` + `aria-pressed`. It is a display
  switch and it is announced as one.
- **No lazy rendering.** Both bodies are always in the DOM — no loading state, no
  flash of an empty panel, no "click and wait" moment.
- **No navigation.** `e.preventDefault()`; the controls are
  `<button type="button">`, not links. The page never reloads and the scroll
  position never moves.
- **Progressive enhancement, backwards.** The default rendering is in the markup
  and the other is `hidden`. With JS off you get a complete, working page — just
  in one mode.

And the principle underneath it is §2's: **each mode is edited for its own job.**
A switch is only worth building when the two renderings differ in *purpose*, not
in width.

---

## 7. The density budget, as a rule

| Element | Budget | Note |
|---|---|---|
| Mode-switch buttons per region | 2 | 3+ and it is a nav, not a switch |
| Height of a switch button | 2rem | vs 2.75rem for a page action |
| Gap between switch halves | `0` | joined into one box |
| Body renderings per switch | 2 | both always in the DOM |
| Panel width | 46rem default / 68rem cards / 39vw terminal | per content, `rem`/`vw` |
| Columns in a settings dialog | 2, → 1 at 900px | |
| Close control | 1 glyph, 1.85rem square | never a word |
| Head actions per page | 2–3 uppercase tokens | each opens a dialog, none navigates |
| Prose per hint | 1–3 lines, with numbers and an exception | tertiary colour, 0.75rem |
| Terminal wells per dialog | 1 | the generated contract |

---

## 8. What is worth taking, and what is not

**Worth taking as-is**

- The joined-pill switch: `gap: 0`, outer corners only, `margin-left: -1px`,
  sized below the page-action scale.
- Both renderings always in the DOM; `hidden` on the inactive one *in the markup*,
  so the default is right with JS off and needs no script to be correct.
- A `[hidden] { display: none !important }` guard, because a component library's
  own `display` will otherwise beat the attribute.
- The delegated, once-bound, `window.__`-guarded listener, plus a `turbo:load`
  re-apply.
- One storage key per switch, named for what it switches.
- try/catch around *every* `localStorage` call, both read and write.
- `aria-pressed` + `role="group"` — announce what it is, not what it resembles.
- Each mode edited for its own job; the switch justified by a difference in
  purpose, not by density.
- The switch living inside the region it controls.
- Grouping paired actions into one grid cell so a head stays two lines tall.
- Recessive hints carrying per-item defaults, exceptions and cost.
- Placeholders naming whose default applies.
- One raw-contract well per dialog in a consistent treatment, with a
  proximity-revealed copy that copies the posted bytes.

**Probably not worth taking**

- **The pixel font** (`--font-pixel`, Press Start 2P) on nav labels and pills. It
  is a brand choice, it forces every size down ~2 steps to fit, and it is not
  what makes the density work.
- **The animated background layers** — orbs, particle canvas, cursor trail, login
  sun. Orthogonal to this pattern, and `prefers-reduced-motion` only partly covers
  it: the burst layer is a sharp intermittent flash, which the source itself
  flags as the most motion-sensitive thing on the page.
- **A 5198-line hand-written stylesheet.** The conventions are portable; the file
  is not. Take the rules, re-express them as tokens.
- **ERB duplication of the dialog shell** in every view. Convention plus tests
  works here; a component would be cheaper.

---

## 9. A note on the comments, which are the real asset

Roughly 40% of `application.css` and a comparable share of `aether.js` is
comment, and the comments do not restate the code — they record **a measurement, a
failure, or a decision**:

> Measured, not guessed: the first-run welcome overlay sits at 9500 and the
> existing glass modal at 1000, so a popup at 200 opened BEHIND the overlay and
> was invisible while the DOM still reported it laid out.

> An `auto` grid column is as wide as its WIDEST item, and a grid item stretches
> to fill its column by default. On the Jev head the row-2 cell holds a PAIR
> (TABLE + JSON), 212px wide, so the column became 212px and the row-1 Run Job
> stretched to match it: measured 212x44 against 98x44 on every other page — the
> doubling.

> The first attempt used `--surface-hover`, which is 6% white — in effect
> transparent. It was the right size and still read as the smaller button, because
> a body you can see the page through is not the same object as one with a solid
> fill. Opacity was the missing third of size, weight and colour, and it is the
> one `getBoundingClientRect` cannot see.

That last one is the pattern. Every layout decision that looks like taste is
actually a measurement, and the measurement is written down so the next person does
not "clean it up". Whatever settings UI lands here, this is the standard worth
matching — not the widths, not the fonts, the *recording*.

---

## 10. File index

| Concern | Location |
|---|---|
| Switch markup — jobs | `app/views/jobs/index.html.erb:36` |
| Switch markup — candidates | `app/views/jobs/show.html.erb:288-290` |
| Switch markup — bracket layout | `app/views/pages/tournament.html.erb:27-33` |
| Swap script — jobs | `app/views/jobs/index.html.erb:224-280` |
| Swap script — candidates | `app/views/jobs/show.html.erb:610-666` |
| The two bodies (jobs) | `app/views/jobs/index.html.erb:42, 74` |
| The two bodies (candidates) | `app/views/jobs/show.html.erb:292, 392` |
| `.view-toggle` + `.cand-view-bar` | `app/assets/stylesheets/application.css:1775-1802, 2996-3015` |
| Settings dialog markup (reference) | `app/views/jobs/new.html.erb:570-870` |
| Per-model field gating | `app/views/jobs/new.html.erb:591-655` |
| Option-level filtering (LoRA/VAE) | `app/views/jobs/new.html.erb:656-711` |
| `data-popup` triggers, page scope | `app/views/pages/flux.html.erb:13-27`, `app/views/pages/bp.html.erb:41-53` |
| Popup open / close / fetch | `app/javascript/aether.js:1740-1900` |
| `.popup` geometry, widths, z-index | `app/assets/stylesheets/application.css:4228-4271` |
| Terminal well + copy ghost | `app/assets/stylesheets/application.css:4283-4370` |
| `.popup-head` / `.popup-close` | `app/assets/stylesheets/application.css:4372-4394` |
| `.field` + `.hint` | `app/assets/stylesheets/application.css:1422-1455` |
| `.print-grid` | `app/assets/stylesheets/application.css:2628-2637` |
| `.head-action-pair` | `app/assets/stylesheets/application.css:2832` |
| `.nav-links` + underline | `app/assets/stylesheets/application.css:1045-1070` |
