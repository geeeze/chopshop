# Layout, CSS-cascade and browser-probe pitfalls

Durable rules for the studio's front-end work. Each is a mechanism, not an
incident: the WHY is what makes it survive a different page.

## 1. Open the target page before you touch it

The single largest time sink in this repo is building a change on the wrong
view. The app has four pages that all look like "the" page from the nav:
`/jobs` (list), `/jobs/new` (Run Job), `/json` (spec builder), `/jev`.

**Read the view file you are about to edit, and the route that renders it,
before you decide where the change belongs.** "The run job page rounded block"
is `/jobs/new`'s `card card-glow`; "the JSON page" is `pages/schema`. They are
different templates with different helpers, and a layout built on the wrong one
has to be reverted, not adjusted.

Corollary: when a request names a page, treat the page as part of the
requirement, not as incidental context. If it is ambiguous, ask before writing
markup.

## 2. Confirm-before-submit buttons

A button that starts an irreversible run is `type="button"` and lives **outside**
the `<form>`, so it can ask first:

- `form.requestSubmit()` — not `form.submit()`. `submit()` fires no `submit`
  event, so every existing `submit` guard is silently bypassed. On `/jobs/new`
  that guard is "upload an artwork file first"; bypassing it posts an empty job.
- No artwork → refuse inline, do not open a confirm for something that cannot run.
- Keep `aria-label` equal to the visible label (WCAG 2.5.3 label-in-name).
  Visible "Run Job" with `aria-label="Run this job"` means voice control
  ("click Run Job") matches nothing.

## 3. Percentage widths are not viewport widths

`width: 60%` resolves against the **parent's content box**, and `.popup` carries
`clamp(1rem, 4vw, 3rem)` padding — so a panel that measures 55.6% of the window
is doing exactly what it was told. When the requirement is a share of the
window, write `60vw`. Verify by measuring `getComputedStyle(el).width` against
`window.innerWidth`; the declared string proves nothing.

## 4. A higher-specificity override only wins for properties it NAMES

`.upload-actions .btn-scissor` beat `.btn-scissor { width: 48px }` on height and
min-width and left the 48px width standing, so a labelled button floored to
72px with its text overflowing the padding box. When overriding, either name
every property you are changing (including the ones you assume cascade) or
reset deliberately. `width: auto` was load-bearing and looked redundant.

## 5. The `::after` glow ring is a separate box

`.btn-primary::after` / `.logo-icon::after` are conic-gradient rings at
`inset: -3px`, blurred, carrying the brand cycle.

- **Reshape the element, reshape the ring in the same breath.** A circle tile
  with a `border-radius: calc(var(--radius-sm) + 3px)` ring is a square halo
  around a round mark. There is no `overflow: clip` on these elements, so the
  ring is genuinely its own box.
- **`isolation: isolate` on the parent is load-bearing**, not tidy-up: a
  `z-index: -1` child resolves against its stacking-context root's own
  background, so without the context the ring paints behind the header and the
  mark reads flat.
- **`scrollWidth` is always ~3px wider than `clientWidth` on these buttons.** That
  is the ring's inset, by design — it is decorative bleed, not a clipped label.
  To test for clipping, measure the **text** against the content box
  (`clientWidth - paddingLeft - paddingRight`). Asserting scrollWidth made a test
  fail at 2rem padding and again at 2.15rem; the padding never mattered.
- `calc(50% + 3px)` is the literal translation of a square radius and is
  meaningless on a circle — write `50%`.

## 6. `min-width: 0` on every growing flex child

A flex item's automatic minimum size is its min-content width, so a long label
or a text input refuses to shrink and forces its box wider than its column.
`min-width: 0` on the item that must absorb or give up space; `flex: 1 1 auto`
for the one that should fill.

## 7. Grid rows cannot be expressed by stacked columns

"Put these two controls on the same line, the second one in the right column" is
**not** two flex columns — each stacks on its own and the buttons land on
different rows. It is one grid with explicit `grid-row` / `grid-column` on the
cells, children in row-major DOM order, so source order and visual order agree.

Corollary: when a row must align, the hint/help text that wraps to three lines
must not be a child of that row. Bottom-aligning a row containing it aligns the
controls to the bottom of the *hint*, not the thing they belong beside.

## 8. Rendering the contract: `JSON.pretty_generate`

`to_json(pretty: true)` is **silently ignored** on this Rails version — the
contract shipped as one 290-character line, which is the opposite of the
requirement. `JSON.pretty_generate(hash)` is the one that indents. Verify by
running both, not by reading the call site.

## 9. Headless-browser probe discipline

Measured assertions beat reading box metrics off a template. The harness that
works:

- **Run on a plain `setTimeout`, not the `load` event.** Under
  `--virtual-time-budget` + `--dump-dom`, a `load` listener can simply never
  fire, and the probe produces a silent no-result with nothing to debug.
- **`String#sub` with a string replacement treats `\1` / `\\` in the REPLACEMENT
  as backreferences.** Page bodies are full of backslashes (inline regexes,
  JSON), so `tpl.sub("__BODY__", body)` silently corrupts the document into a
  page whose elements do not exist. Use the **block form**: `tpl.sub("__BODY__") { body }`.
- **Always write the output block in a `try/catch` and append it after**, so a
  throw is reported rather than vanishing.
- **A measurement helper that returns a rect, not the element, produces silent
  nonsense** (`el.value` on a `DOMRect` is `undefined` → `TypeError` on `.split`).
  Be explicit about which one you return.
- **Strip only EXTERNAL scripts: `doc.css("script[src]").each(&:remove)`.** Never
  strip inline ones. When the probe measures layout, the page's inline script is
  noise; when the probe CLICKS something, that inline script IS the handler under
  test, and removing it makes a working page report every button dead.
- **Inject the page's module dependencies as a real `<script type="module">`, not
  a stub.** `javascript_importmap_tags` emits a MODULE script, and module scripts
  are DEFERRED, so they run after any classic inline script. A probe that defines
  `window.Foo` itself before load passes against a page that is genuinely broken
  in the browser. Inject the real file, assert the failure mode reproduces
  (dependency undefined at parse time), then assert it works — otherwise the
  probe is testing the stub.
- `:hover` cannot be faked without CDP. Assert the **rule exists with the right
  values** in the sheet rather than pretending to observe the state.
- Never assert against a decorator you did not measure: a `box-shadow` on a
  parent is not proof a child is lit. Measure the child, or check the rule.
- **Do not build the probe's later phases on `requestAnimationFrame`.** Under
  `--dump-dom` rAF does not fire reliably: measured a handler counter that
  stayed at 1 across a dispatched `resize`, an `orientationchange` and an
  explicit forced call. Drive sequential steps with `setTimeout` and assert on
  each result, exactly as with `load`.
- **A probe that never writes its result is indistinguishable from one that
  failed.** Give the tail an idempotent watchdog — `var written = false;
  function finish() { if (written) return; written = true; /* write the <pre> */
  }` plus `setTimeout(finish, 2500)` — so a stall reports the partial output
  instead of a bare "NO RESULT".
- **`node --check` the probe's JS after any string surgery on the template.** A
  replacement that turns `'\n'` into a real newline yields a page that loads
  cleanly and measures nothing; the only symptom is an empty result, which
  reads like a product bug. Extract the trailing script and check it before
  blaming the page.

## 10. An ERB comment that does not close eats the rest of the page

`<%# ... %>` runs to the next `%>` **anywhere in the file**. A terminator typo
(`-->` instead of `%>`) makes the comment swallow every card up to the next ERB
tag in the file — three whole cards vanished from the JSON page and it still
returned **HTTP 200**. Nothing in the response said so.

So after editing a view, assert the STRUCTURE rendered, not just the status:
count the `.card` elements, the `h3` headings, the `id="f_…"` fields you expect.
`assert_response :success` proves the template ran; it does not prove the markup
you wrote is in the output. This is the same class of bug as a section that is
present-but-nested — count at the top level you mean.

Corollary for the same file: when you rewrite a view by slicing one string and
splicing another, **read it into a variable and write once**. `open(p,
"w").write(open(p).read()[:i] + open(p).read()[j:])` opens for write FIRST, so
the file is already 0 bytes when the reads run. `git checkout --` recovers it,
but only because the work was committed — commit before any destructive
rewrite.

**The patch tool's fuzzy matching corrupts ERB/HTML when the old_string does not
match exactly.** It is not a find-and-replace: a near-miss old_string (a typo in
your own copy, a whitespace difference) is still "matched" and the replacement
lands mangled — a `btn btn-secondary` becomes `btn btn btn-secondary`, a
`<% end %>` becomes `<% endnd %>`, a `json_path` becomes `json_path%= json_path`,
and whole blocks get re-indented. The diff looks plausible and the file is
broken. For a single-line ERB fix, **use `sed -i` via terminal** (the reliable
path for this repo's views); reserve the patch tool for edits where the
old_string is copied verbatim from a fresh read. After ANY view edit, re-read
the touched lines and compile the ERB before restarting — a mangled tag is
invisible to `assert_response :success`.

## 11. Assert what Chromium COMPUTES, not what you wrote

Computed values are normalised, so an assertion against the authored string
fails on correct CSS:

- `saturate(150%)` computes to **`saturate(1.5)`**.
- `linear-gradient(to bottom, …)` computes **without** `to bottom` — it is the
  default, so the engine drops it. Assert the property that matters (which
  edge the heavy stop sits on) rather than the direction keyword.
- `min-width: 6.125rem` computes to `98px`, and content can still push the box
  wider — `min-width` is a **floor, not a target**.

Rule: when a probe assertion fails, **print the computed value before touching
the CSS**. Most such failures are the assertion, not the stylesheet.

## 12. Fixed-position percentages resolve against the LAYOUT viewport

`left: 50%` on a `position: fixed` element resolves against the initial
containing block, which **excludes the scrollbar**; `window.innerWidth`
**includes** it. A 15px scrollbar therefore reads as a permanent 7.5px
centring "error" on an element that is in fact dead-centre. Compare against
`document.documentElement.clientWidth`.

Same family: `scrollWidth`/`clientWidth` are integer-rounded while
`getBoundingClientRect().width` is fractional, so `scrollWidth > clientWidth`
can be sub-pixel rounding. Compare `scrollWidth` against the fractional width
before calling it a clip.

## 13. Specificity is arithmetic — count it before assuming your rule wins

`table.candidates td.col-thumb` is **(0,2,2)** and BEATS a bare
`.proofs-tbl td:nth-child(1)` at **(0,2,1)**. The override compiled, shipped,
and did nothing: every column collapsed to `1%` while the name column took the
rest, so the table measured correct and its contents still spilled.

When overriding a rule that shares a base class, prefix the whole compound:
`table.candidates.proofs-tbl td:nth-child(n)`.

Corollary (extends §5): an `<a>` and a `<button>` carrying the same class can
render different heights from UA defaults. Give shared GEOMETRY its own class
and set it on both.

## 14. A table wider than its column needs `table-layout: fixed`

With auto layout a five-column table measured **477px inside a 416px column**
and scrolled sideways — a worse failure than the full-width table it replaced,
because nothing looks broken until you scroll. Fix with `table-layout: fixed;
width: 100%` plus an explicit width per column, letting the name column take the
remainder and ellipsis it (`max-width: 0` + `overflow: hidden` +
`text-overflow: ellipsis`). Then **measure the table against its wrapper** —
`table.scrollWidth` vs the column width is the assertion that catches this.

## 15. "Same width" means a shared box, not a copied number

Two controls measured 96.8px and 90.7px and neither matched the 98px
`.head-action` the other pages used. Set the geometry through a **two-class**
selector — `.a.head-action, .b.head-action` — so it outranks both the base
class and each control's own single-class rule whatever order the sheet ends up
in. Order-dependent geometry is exactly how the two drifted apart.

Keep that geometry class free of `background`/`border` so an existing control
can adopt the box **without becoming a button** — a "document you read" should
not start competing with the command above it. A test should then assert the
base class carries no fill, or the next person will fill it in.

## 16. `:of-type` counts ELEMENT TYPE, so it is wrong for mixed siblings

`:first-of-type` / `:last-of-type` select among siblings **of the same tag name**,
ignoring everything else in the row. A head row holding a Run Job `<a>` and a
CONFIG `<button>` makes each element both first and last of its own type: both
match the placement rules, the later rule wins for both, and the two controls
land in the SAME grid cell. Measured: both at row 2 col 2, both `top: 355px`.

Worse, the fix you reach for loses: `:last-of-type` is **(0,3,0)** and beats a
plain `.my-class` at **(0,2,0)**, so re-declaring the class does nothing.

**Rule: place mixed-element siblings with explicit modifier classes**
(`--top` / `--below`) set in the markup, and delete the `:of-type` rules rather
than trying to out-specify them. Apply the classes to EVERY such head, and let a
test assert the rules AND the per-page classes, so a new page cannot skip them.

## 17. `width` on a flex item is a request, not a size

A flex item defaults to `flex-shrink: 1`, so `width: 2rem` is a starting point
the container may reduce. Inside a `nowrap` row with a fixed-width sibling, a
32px icon button measured **7.48px wide** while every other button in the same
row was 32px — nothing in the markup or the stylesheet distinguished them, so
reading the CSS could never find it.

`flex: 0 0 auto` makes the width a size. The general rule: **any fixed-size
control that sits in a flex row needs `flex: 0 0 auto`**, and the assertion is
the rendered box, not the declaration.

## 18. A `1fr auto` grid collapses on a phone — measure three viewports

`grid-template-columns: 1fr auto` puts a flexible title beside an `auto` column
holding the controls. `auto` wins the space fight when there is little of it: at
a phone width the title collapsed to a few words a line and the controls were
pushed toward the edge. The head did not stack, it collapsed.

Below a breakpoint make it **one column in reading order**, and place each child
by an explicit `grid-row` rather than DOM order — in a stacked head the sub-title
is frequently the LAST child, so by DOM order it drops below the controls it
belongs to. Use `minmax(0, 1fr)` so a long word cannot force the grid wider than
the viewport, and `justify-self: start` so controls do not stretch to fill it.

Two things that bite alongside it:

- **A percentage cap is the squashing.** `max-width: 67%` of an already-narrow
  column is a handful of words per line. Un-squash to `100%` in the breakpoint.
- **A condensed font size is only condensed for wide columns.** Shrinking a
  sub-title to `0.85rem` to buy vertical space is right at 1fr beside the
  controls and wrong at full width on a phone. Scope the bump to the elements
  that are actually long, by class on the ELEMENT, not on the page.

Rule: **any layout check must run at three widths** (narrow, tablet, desktop),
because a single viewport hides exactly this class of bug. Also verify the
desktop-only measures still hold at the wide width — a fix for mobile must not
silently change the desktop measure. Headless Chromium clamps its window to
~500px, so state that limit rather than claiming a 375px pass you did not render.

## 19. Probe: look up elements AFTER the action that creates them

- **A DOM reference captured before the click that creates it is null forever.**
  Reading `getElementById('modalBody')` up front and reusing it after the click
  reports an empty modal on a modal that opened correctly. Make the lookup a
  function and call it inside the handler path.
- **A text-only cell has no element children.** `td.children[0]` is `undefined`
  for a cell containing only text, so a centring check measures nothing and
  reports an impossible `0.0` vs `-16.0`. Use a `Range` over
  `nodeContents` and its `getBoundingClientRect()` to measure the text.
- **Assert the real geometry, not the declared value**: for a centred cell,
  compare the gap from the cell's content edge to the text on each side and
  assert they are equal. `text-align: center` computed is necessary, not
  sufficient.
- **Scope mobile-only assertions to the mobile width.** A "not squeezed"
  threshold and a "not wedged" ordering check are both false positives at
  desktop width, where the narrow measure and the side-by-side placement are
  the intended design.
- **An alignment invariant can be satisfied on a DIFFERENT EDGE per layout, so
  branch the assertion instead of hard-coding one.** "Flush right with the
  button above" is true in the two-column head (the `auto` track shrinks to the
  widest control) and false in the single-column one, where the same box spans
  the row and the correct invariant is that the CONTROLS share the button's
  LEFT edge. Asserting one fixed edge produced a false failure at 700px against
  markup that was right. Detect the layout (e.g. is the reference button wider
  than itself, is the row one track) and check the edge that belongs to it —
  and report which layout was measured, so the number is interpretable.
- **In a `<template>`, the browser sees inert content the parser exposes.** A
  browser probe counting a link the template holds reports it as dead until the
  popup renders it. Open the owning popup and click it there; that is the only
  assertion that covers the real path.

## 20. Test-hygiene rules that keep biting

- **Strip CSS comments before regex-matching a rule.** An explanatory comment
  sits between the selector's `{` and its declarations, so `/\.x \{.*?width:/`
  cannot cross it and silently matches nothing — it reads as "got 180px" when it
  matched no rule at all.
- **Compare class LISTS, not class strings.** `refute_includes cls, "popup-close"`
  fails on `"popup-close-text"` because it is a substring.
- **`at_css(".some-class")` returns the FIRST match, and a shared class name is
  common.** `.field` / `.btn` / `.pal-picker` are reused across a page, so
  `at_css(".btn")` binds the first button, not the one you mean (this once
  bound the wrong `.pal-picker` node and an assertion about a row failed on
  correct markup). Scope to a distinguishing class or a nearer ancestor
  whenever a class is reused, and prefer `.css(...).last` over `.first` only
  when you have verified the order.
- **A `/s`-flagged regex literal can compile with a non-UTF-8 encoding** on this
  box and then raise `Encoding::CompatibilityError: incompatible encoding regexp
  match` against a UTF-8 string — reproducible outside the test suite, and the
  file itself is valid UTF-8, so it reads as a test bug. Use `include?` /
  `refute_includes` on a substring extracted once (`css[/(\.rule \{[^}]*\})/,
  1]`) rather than a spanning regex; it is also easier to read.
- **Scope with Nokogiri, not a greedy regex.** `/<div class="actions-row">.*?<\/div>/`
  runs past the row's closing tag into the next sibling and reports correct
  markup as broken.
- **Normalise label text before matching keys.** `"colour palette — pick"` and
  `"ink_limit_percent (TAC)"` are `colour palette` and `ink_limit_percent`;
  checkbox options (`bw`/`poster`/`photo`) are the options of ONE documented key,
  not separate fields; a label that heads a *view* of another field needs no
  entry of its own.
- A test that fails against correct markup is a bug in the test. Say so in the
  failure message and fix the test — do not "fix" the page to satisfy it.
- **When a UI contract's SHAPE changes — a class/data-attribute rename, or
  collapsing duplicated per-instance controls into ONE shared control — grep the
  whole test tree for the OLD symbol BEFORE editing, and re-pin every hit to the
  NEW contract in the same change.** The pins live in three layers (the markup in
  the layout, the rule in `application.css`, the binding in `aether.js`), and
  their tests are spread across files you would not associate with the feature: a
  "shared recipe" test matched a close button by its halo class, and a screen test
  pinned its exact positioning rule. Two failure modes to expect: tests that pin
  the old shape fail (useful — the grep is your work list), but tests that assert
  only the PRESENCE of the new thing pass on a half-migrated page where the old
  copies still render. So assert the new invariant BOTH ways: positively (the
  single control exists, binds directly, shows under the right visibility rule)
  and negatively (`assert_nil panel.at_css('.old-copy')`, `refute_match` the old
  selector in the JS) — the assert_nil on the per-instance copies is what proves
  the duplicates are really gone. State the WHY in the failure message ("an orb
  per panel showed twice in the both-up state"), so the next edit knows the
  duplication is the bug, not the count.
- **Name the RULE in an ordering assertion, never the current incumbent.** Two
  tests asserted `labels.last == "BP"` because BP was the newest nav entry at the
  time. Adding one page broke both, and the temptation is to retype the new
  incumbent — which produces a test that fails every time anything is added and
  enforces an accident. The real contract was "the nav reads oldest to newest",
  so assert THAT: pin the relative order of the entries you actually care about
  (`index("BP") < index("Tournament")`) and assert the newest is last by
  establishing which is newest from the data, not from a hard-coded string. Same
  shape as the uniformity test in §21: the assertion should describe the
  invariant so it keeps holding as the content changes.
- **Nokogiri does not implement `<template>` inertness.** Its HTML4 parser treats
  a template's children as ordinary descendants, so `doc.css('a.link')` counts
  links that the browser leaves dead until something renders the template. A
  Nokogiri count and a browser count are both correct about different documents —
  do not "fix" one to match the other. Assert the live count in the browser probe
  (and clicking a link that lives inside a `?` template, to prove it works once
  the popup renders it), and let the Nokogiri test assert the markup only.

## 21. One mechanism per element, pinned across every page

When the same UI element is placed by a DIFFERENT mechanism on each page, the
repeated "why is this still wrong" is not bad luck — every page quietly picked its
own approach, and only the page whose approach is wrong shows it. The fix is
never another nudge to one page: **enumerate every page, unify on one mechanism,
then pin it with a test that lists the pages.**

The trap is a mechanism that is correct in only one configuration. A bare `<p>`
after the head row reads correctly while the row is a single line, and diverges
the moment a second action makes the row two lines tall — so the pages using it
pass every check you can run against them, and the page using the correct
mechanism is the only one that ever reports a fault. The mechanism that "works"
on the simplest page is the dangerous one.

Corollary: a uniformity test is its own kind of test. It asserts that every page
uses mechanism X, not that any one page looks right — so it keeps passing after
the shared mechanism is quietly replaced on one page, unless it names the pages.

Corollary for placement classes: adding a third control to a stack needs a new
explicit modifier class and a new grid row, not a reordering of the existing
ones. Verify the stack still reads in the intended order after the move.

**A third AUTO-PLACED control lands in the LEFT `1fr` column, not the right
`auto` one.** In the `1fr auto` head grid, auto-placement scans row-major, so
after two head-actions fill row 1 col 2 and row 2 col 2, the next free cell is
**row 3 col 1** — the wide flexible column. `justify-self: end` then right-aligns
it *within that wrong column*, so the control floats mid-page (measured x=941
against the buttons' x=1089) instead of under them. The served HTML is
structurally fine; only the rendered position is wrong. Pin the control
explicitly — `style="grid-row: 3; grid-column: 2; justify-self: end;"` — and
verify by measuring its `getBoundingClientRect().x` against the button above,
not by checking the element exists. This is the same class as §19's
"alignment invariant satisfied on a different edge": the auto column is the
only place `justify-self: end` means "under the buttons".

**Pin to the row BELOW the last auto-placed button, not the row it occupies.**
If you pin the new control to row 2 col 2 while an auto-placed button already
sits there, that button re-flows into the next free cell — row 3 col 1, the
`1fr` column — and stretches to full width (measured 1001px against the other
buttons' 127px). The head then shows a giant button where a normal one should
be. The toggle belongs at row 3 (under Run Job at row 2), and after pinning it
re-measure the button above to confirm it kept its width.

**But a new ROW is the wrong answer when the new control belongs beside an
existing one.** Two controls that open the same kind of thing (a file, a view of
the same data) each in their own grid row make the head three lines tall for
nothing. Wrap them in one cell that flexes — the pair carries the placement
class and the grid places the PAIR, not either button — and DOM order decides
left-to-right, so "the second one on the left" needs no ordering CSS. Measured:
a 16px gap on one row against a third row before. Keep the buttons' own shared
geometry class so they still match the control above, and delete the now-unused
row class from the stylesheet as well as the markup, or the next person counts
three rows from a rule that no element carries.

**But a pair-wrap is ONLY for controls that belong on the SAME side of the line.**
Do not reach for it when two controls share a row but belong on OPPOSITE ENDS
of it — classic case: the back-navigation button must sit under the title on
the LEFT, and the view toggle under the right-column actions on the RIGHT.
Wrapping those two into one flex pair jams the toggle against the back button
on the left instead of under the actions on the right (the operator calls it
"crammed together"). Place each as its own direct grid child in its own column
— `.project-back { grid-row: 3; grid-column: 1; justify-self: start }` and
`.view-toggle { grid-row: 3; grid-column: 2; justify-self: end }` — so they
share the line but face outward. The pair-wrap exists for controls that open
the same thing and sit side by side in ONE column; the decoder for "same line,
opposite ends" is two cells, not one flex box.

**A page-scoped head variant that re-places a globally-placed element must
override it with a CLASS, never an inline style — an inline `grid-row` beats
the media query and collides on mobile.** The project head is the example,
scoped by `.project-head` so the other house pages are untouched. The blurb
KEEPS its global row 2 — the variant adds two row-3 children on top of the base
rows: the back button under the blurb (`.project-back`, row 3 col 1,
`justify-self: start`) and the view toggle under the right-column actions
(`.view-toggle`, row 3 col 2, `justify-self: end`). The equal-specificity,
later-source override wins on desktop; the `max-width: 860px` media query then
re-declares those two to rows 5 and 6 (`justify-self: start`) so they stack
under the actions left-aligned. An inline `style="grid-row: N"` would beat
that media query and leave the element on its desktop row at phone width,
colliding with the action the media query also moves there. Keep the
page-scoped mobile override in the same breath as the desktop override.

## 22. Halving a container halves the field track too

Moving two cards side by side is where a page's other grid assumptions break.

- **`1fr` is `minmax(auto, 1fr)`** — the automatic minimum is min-content. Put two
  cards in a `1fr 1fr` grid and the one with a wider min-content (two selects on a
  single flex line) pushes the grid wider and starves its sibling: measured 337px
  against 263px, which is not equal columns. `minmax(0, 1fr)` on the grid removes
  the automatic floor, so the tracks are genuinely equal and the contents reflow
  inside them. Distinct from §18, where the overflow is the viewport.
- **A multi-column FIELD grid does not survive halving** — so do not halve.
  `1fr 1fr` is right in a full-width card and wrong in a half-width one: each
  control measured 87px and every label clipped. The tempting fix, collapsing
  the field grid to one column inside the narrowed block, makes the block
  TALLER than the two stacked cards it replaced — you have traded width for
  height and lost on both. The block usually already sits in one track of a
  two-column page grid, so let it take that track WHOLE (measured 624px in a
  1440px window), keep the global `1fr 1fr`, and each control lands at 267px in
  a block that came to 583px against the two-column version's 824px. Reach for
  the narrower inner grid only when the block genuinely must be narrower than
  its track.
- **Do not cap a block that is already in a grid track.** `max-width:
  calc(50% - gap)` on an element sitting in one track of a `1fr 1fr` grid halves
  it a SECOND time: 624px became 300px. The cap is only meaningful when it is
  the thing that creates the constraint.
- **A single long word has no break opportunity.** At 197px `ink_merge_tolerance`
  still clipped, so labels in a narrowed block need `overflow-wrap: anywhere`.
- **Prove "more compact" with the number.** Measure the block's height against
  what the same cards cost stacked, so the claim is a measurement rather than an
  impression. The current Prep/Print block is 583px against 1385px for the same
  two cards as full-width rows.

## 23. In a modal, the SCROLLER is `.popup-body`, not `.popup-panel`

`.popup-panel` is `overflow: hidden` with `max-height: 100%`; `.popup-body` is
`overflow-y: auto` and `flex: 1; min-height: 0`. So a probe that asks the PANEL
whether the content overflows reads `scrollHeight == clientHeight`, concludes
"fits", and the bottom of the content is silently clipped and unreachable.

This is the worst class of probe miss because it reports PASS. Measure
`body.scrollHeight > body.clientHeight` and `getComputedStyle(body).overflowY`,
then prove reachability by setting `scrollTop = scrollHeight` and checking the
last child's rect against the body's bottom edge — not just that some overflow
exists. Six palette cards plus a spectrum measured 1585px of content in a 736px
box: correct, scrollable, and only correct because the probe looked at the right
element.

The same trap applies wherever a flex/grid parent is `overflow: hidden` and a
child is the scroller: **find the element whose `overflow` is `auto` before
asserting anything about fit.**

## 24. An ERB comment is closed by `%>` and by NOTHING else

Two distinct traps, both hit in one sitting on `jobs/index.html.erb`. The
signature is the same: the page renders, returns 200, and looks right.

(a) An expression inside a comment: `<%# ... <%= @threshold %> ... %>` closes
at the FIRST `%>`, which is the one in the middle of the expression, so the rest
of the comment is served as page text.

(b) A comment closed with `-->` instead of `%>`. ERB does not know what `<!--
-->` means, so the comment runs on past its own apparent terminator and swallows
everything up to the next `%>` in the file. Here that was 200 lines later,
inside an unrelated comment — so it ate an entire `<script>` block. The
row-click and view-toggle scripts on either side rendered perfectly, which is
what made it look fine.

**Rule: `-->` is not a terminator.** Every `<%#` closes with `%>`, and a
comment must contain no ERB tag and no `%>` other than its own.

**The failure was invisible to eight tests because every one of them read the
TEMPLATE FILE. The file contains the script. Nothing asked the server what it
sends.** So: for anything with a `<script>` in it, assert on the RENDERED
BODY, and walk the template's comments asserting none spans a `<script>`. Pin
the SHAPE, not the one occurrence.

Corollary, learned the hard way: a substring assertion on the raw HTML cannot
distinguish a rendered element from a selector naming one — `jobs-scroll-more`
appears both as an `<a class=...>` and inside the script that queries it.
Assert on the parsed DOM (`Nokogiri::HTML(body).at_css(...)`) for "is this
element present".

## 25. Correct GEOMETRY can still draw broken — assert the RENDERED boxes

A bracket card's label overflowed its 220px card and collided with the next
column. Every geometry assertion passed: x and y right, the fold right, the
midpoint property held. Only the PAINT was wrong, and **no assertion on
coordinates can see it**, because the coordinates were correct.

**Rule: for any drawn figure, also assert on rendered geometry in a real
browser** — compare `getBoundingClientRect()` across elements and fail on
overlap, and compare one element's width against a known sibling's. A card that
should be one size measuring 3.35× its neighbour is the tell.

Corollary: **"the element is in the HTML" is not "the layout is right".** A
served-HTML check that counts `#jobs-list`, `.view-toggle`, and the rowlink rows
passes on a page whose buttons are scattered across grid cells and whose toggle
floats mid-page — the markup is present, the placement is wrong. When the ask is
a LAYOUT, verify the rendered positions (each control's `getBoundingClientRect()`
against the one it must align with), never just that the elements exist. Reporting
structure checks as layout verification is how a page that is visibly broken
gets signed off as correct.

Screenshot analysis is too weak to be the check: the dark theme crops to
unreadable and a vision model will confidently report a correct mirrored
bracket as "one-sided". The DOM rectangles are exact and cheap.

Corollary: **SVG has no `text-overflow: ellipsis`**, so a long label must be
clipped in the DATA (a `display_name` on the model), never styled. Keep the
full string somewhere visible — here the match log below the figure — so
clipping loses nothing.

## 26. An infinite scroll's contract: the server owns the stop, and late nodes need re-wiring

Two things make an "append the next page" list wrong in ways that still look
right on screen.

**The stop condition belongs in the MARKUP.** Put the next page number in a
sentinel attribute rendered by the same view that renders the rows, and read the
following page from the RESPONSE's sentinel rather than from a local counter. A
client-side counter is a second opinion about the same question, and two opinions
disagree — the counter says "page 3" while the server is already out of rows, and
you fetch an empty page forever. Server-side `@has_more` is one boolean; the
markup carrying it is what makes the client agree for free.

**Extract the repeated markup into a PARTIAL before you append it.** If the
scroll re-fetches the same URL and lifts nodes out of the response, the first page
and every later one are the same template — so that template must be a partial
shared by both. Two copies of a row or a card is the drift you are trying to
avoid, and the drift is invisible until the appended page renders slightly
differently from the original.

**Late-arriving nodes need their handlers re-bound, and the wirers are rarely
delegated.** Per-element wirers guard themselves with a `data-…-wired` flag so
re-running them is free, which makes them look idempotent — but they can only see
nodes that existed when they last ran, so an appended button is dead. Expose an
explicit re-wire hook (`window.csRewireDynamic()`) and call it after appending.
Delegated handlers (one listener on `document`) need none; the split is exactly
which handlers are per-element, and it is not visible from the appending code.

Keep a no-JS fallback link in the markup. `IntersectionObserver` is not universal
and a page whose only path to row 200 is an observer it may not have is a page
that appears to truncate again.

## 27. A layout that "keeps breaking" across rounds is usually a STALE served bundle

The app serves a PRECOMPILED CSS bundle, so a rule that is correct in
`application.css` can render broken because the served bytes never changed.
Before touching the source again on a layout that keeps regressing, confirm the
rule is actually in the served bundle:

```
curl -sS http://127.0.0.1:3001$(curl -sS http://127.0.0.1:3001/login \
  | grep -oE '/assets/application[^"]*\.css' | head -1) | grep -c '<new-selector>'
```

Zero hits means the bundle is stale — no source edit fixes it, only
`assets:precompile` + `systemctl --user restart chopshop-rails.service` does.
A changed digest is NOT proof the rule is in the bundle; grep the served bytes
for the selector itself. This is the failure that made a correctly-placed
`justify-self: start` render as a full-column-stretched button: the rule was
right in source and absent from the served CSS, and every "fix" to the source
left the page unchanged.

## 28. An ERB comment that ships as TEXT can delete a page's whole script

Extends §24 with the worst variant: the comment is not malformed ERB, it is
**doubled delimiters**. A partial base whose header was written `<%%# … %%>`
(an artefact of escaping a `%`-format string) is *valid ERB*: `<%%` emits a
literal `<%`, the prose emits as page text, `%%>` emits `%>`. Nothing raises.

The damage comes from the PROSE. A comment explaining "it is a `<template>`
handed to CsModal" then puts a real, never-closed `<template>` element in the
document — and an unclosed `<template>` makes everything after it **inert
content**. On the compose page that swallowed the colour map and then the
page's 50 KB inline script.

The symptoms never look like a markup fault, and they arrive as three unrelated
complaints: the colour picker does nothing, the canvas "has shrunk and is
useless" (it is still the 300x150 default, because `fit()` never ran), and
drag-drop of images "doesn't work" (the document-level handlers were never
bound). One dead script, reported as three bugs — which is what makes it survive
a round of "fixes" to the picker.

**Detection that actually works:**
- Judge `node --check` on the extracted script only tells you the source is
  valid JS; a script inside a template is never `--check`ed *as the page runs
  it*. Extract the served page's scripts and check the server's own files
  compile — not enough.
- **Run the page in jsdom and assert the script RAN.** A cheap canary is
  `canvas.width !== 300` (the default is what proves `fit()` never executed),
  or any DOM mutation the script performs at boot.
- **Count `<script>` elements in the parsed document against the raw HTML.**
  jsdom reported 3 scripts where `grep -c '<script'` found 4 — that discrepancy
  WAS the bug, and I explained it away instead of chasing it. A missing script
  element in a DOM you just built from served bytes is never a parser curiosity.
- Nokogiri does not implement template inertness (see §20), so
  `doc.at_css('#colourMapTemplate .cmap-cell')` still finds cells in a page
  whose script is dead. In jsdom, `<template>` content lives in `.content`, so
  `templateEl.querySelectorAll(…)` returns 0 for the SAME correct markup — read
  the cells through `template.innerHTML` (the modal's own path) or `.content`.

**Pin it, and pin the running:** assert the page's script is present AND
`script.ancestors("template").empty?`, assert the prose does not appear in
`body.text`, and assert `<template` and `</template>` balance on the served
bytes. A structural assertion that the markup EXISTS passes on a page where
nothing executes; "the script runs" is the assertion that was missing.
