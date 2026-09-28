# Measuring a LAYOUT change (not an effect)

`references/visual-effect-verification.md` covers glows, rings and animation. This covers the other
half: column geometry, control bands, panel widths — the class of change the operator iterates on
most, and the one where a plausible-looking screenshot check misses real defects.

## A percentage is of the PARENT'S PADDED CONTENT BOX, not the window

`width: 60%` on a child of `.popup` (which carries `padding: clamp(1rem, 4vw, 3rem)`) resolves
against 1500 − 96 = 1404px, so the panel measured **55.6%** of the viewport (833px) while every
string-level test on `width: 60%` passed. When the requirement is phrased against the WINDOW
("60% wide"), use `60vw`. Assert on the ratio (`parseFloat(cs.width) / window.innerWidth`), not on
the declared unit — `60vw` and `60%` differ by the parent's padding and nothing else.

The general form: any percentage sizing or padding that the user described relative to the screen
needs `vw`/`vh`; only grid/flex fractions and parent-relative boxes should use `%`.

## Assert a label FITS the content box, never `scrollWidth <= clientWidth`

`.btn-primary::after` is the conic glow ring at `inset: -3px`, so **every** primary button's
`scrollWidth` is ~3px wider than its `clientWidth` by design. Asserting that difference reports a
clipped label on correct code, and no padding value will clear it (it failed at 2rem AND 2.15rem).
Measure the text instead:

```js
var probe = document.createElement('span');
probe.style.cssText = 'position:absolute;visibility:hidden;white-space:nowrap;font:' +
  getComputedStyle(el).font;
probe.textContent = el.textContent;
document.body.appendChild(probe);
var textW = probe.getBoundingClientRect().width; probe.remove();
var inner = el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
// require textW <= inner, with a little slack for sub-pixel rounding
```

## A control you cannot fit on one line needs a SHAPE change, not more padding

A 72px round `.btn-scissor` cannot hold the words "Run Job". Widening the padding does nothing while
`border-radius: 50%` is still in force — the box stays a circle and the text overflows it. Change
the shape (`border-radius: 999px`, `width: auto`, real horizontal padding) and keep the HEIGHT
constant, so the row it shares with its neighbour is unchanged. A pill that grows the row's height
silently knocks every sibling out of the alignment you just measured.

## `requestSubmit()`, never `submit()`

A confirm-gated run button that calls `form.submit()` **fires no submit event**, so every validation
guard bound to `submit` is bypassed and an empty form posts. Use `form.requestSubmit()`. Any control
that must ask before acting belongs OUTSIDE the `<form>` as `type="button"`; inside it, a button
submits the instant it is pressed and there is no chance to confirm.

## The accessible name must CONTAIN the visible label (WCAG 2.5.3)

A button reading **Run Job** with `aria-label="Run this job"` fails label-in-name, and voice control
("click Run Job") matches nothing. Make the accessible name equal the visible text, or a superset of
it. The same applies to `title` — a tooltip may be more descriptive, but the accessible NAME is not.

## Probe harness traps (each one produced a silently wrong or empty result)

- **`String#sub` treats `\` in the REPLACEMENT as a backreference.** `tpl.sub("__BODY__", body)` on a
  page body full of regexes and JSON rewrites `\1`/`\\`, silently corrupting the HTML into a page
  with no elements at all. Always use the BLOCK form — `tpl.sub("__BODY__") { body }` — whenever the
  replacement is not a literal.
- **Do not wait for `load`.** Under `--virtual-time-budget` with scripts inlined, the `load` event can
  never fire, and a `load` listener produces a probe that reports nothing and raises nothing. Use a
  plain `setTimeout(fn, 600)`.
- **Wrap the whole check body in try/catch and ALWAYS append the result element.** A probe that throws
  half-way emits no output, which is indistinguishable from a page that failed to load.
- **Keep the accumulator at module scope.** `var out = []` inside the `load` handler is invisible to a
  `runChecks()` function or to the catch block, which then throws `out is not defined` and reports
  that instead of your actual failure.
- **A `rect()` helper that returns `getBoundingClientRect()` gives you a RECT, not the element** —
  `ta.value` on it is `undefined` and every property assertion silently degrades. Return the element
  and measure separately, or use a distinctly named `rect()`.
- **Write the throwaway dump test with `.sub(...) { }` block form and `respond_to?` checks**, and
  delete it after the run: a test whose only job is to emit a scratch artifact pins nothing and writes
  a file on every suite run.

If a probe reports NO RESULT, bisect before blaming the app: strip all scripts, then keep one at a
time. The page's own script loading fine alone does not prove a two-script document is at fault, and
neither "it works in the browser" nor a stale harness failure is a reason to skip a real measurement —
but neither is it a reason to rewrite working page code. Confirm the CHECK first (see the
confirm-the-check pitfall in SKILL.md), then the app.

## Pin the invariant in a Rails test so the browser is confirmation, not the only gate

Structural assertions survive the browser being unavailable and fail fast on the next run. Scope
them to NOKOGIRI NODES, never a regex over raw HTML:

```ruby
row = doc.at_css(".actions-row-buttons")
assert_equal 1, row.element_children.count { |el| %w[a button].include?(el.name) }
```

A browser measurement then confirms the geometry; the test keeps the contract.
