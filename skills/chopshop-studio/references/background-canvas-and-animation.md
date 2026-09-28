# Background canvas and animation code

Rules for `app/javascript/aether.js` and anything else that animates, resizes a
canvas, or registers a callback. Layout and probe rules live in
`layout-and-probe-pitfalls.md`; this file is the runtime half.

## "Fewer background nodes" means the PARTICLES, not the DOM

The background is five or so DOM elements. You cannot cut 20-30% of five and mean
anything. The cost is a **node-link graph**: every pair of particles within a
radius is joined by a stroked line, so the per-frame cost is O(n^2). At 120 nodes
that is 7,140 distance checks a frame, ~428k a second at 60fps, for decoration
behind a page of forms.

So when the ask is a percentage cut in background work, **identify what the nodes
actually are before choosing a number** — and report the pair count alongside the
node count, because a 30% cut in nodes is a 51% cut in work when the loop is
quadratic. A budget expressed only in nodes undersells the change.

Scale on **width and orientation, not pointer type.** The file already had
`isDesktop()` testing `(pointer: fine)`; reaching for it keeps the full budget in
a narrow desktop window, which is the same constrained device as a phone.

## A hardcoded population gets ADDED to the budget, not replaced by it

Moving a fixed `for (i = 0; i < 120; i++)` into a viewport-driven `setCount(n)`
means deleting the loop. Left in place it runs *after* the budget and the narrow
viewport ends up with 204 nodes. Pin it with a test that asserts the literal
`i < 120` is gone and that particles are created in exactly one place.

Grow and shrink (`while (length > n) pop(); while (length < n) push();`) so
dragging a window back across the breakpoint is reversible without a reload.

## Measure the element that is CSS-sized, not the canvas

A canvas with no CSS box has `clientWidth === 300` — its intrinsic default, and
**truthy**, so a `clientWidth || window.innerWidth` fallback never fires and the
buffer is silently pinned to 300x150 forever. `.gradient-mesh` is the fixed
full-size element; the canvas inside it is a bare child.

Use `getBoundingClientRect()` on the sized element, passing the wrapper in
explicitly, and let a zero rect fall back to the viewport.

This is the dangerous class of bug because **it looks correct**: a smooth radial
gradient stretched from 300x150 is indistinguishable from one drawn at full size.
Nothing about the page is visibly wrong, so only a measurement catches it.

## A callback that fires immediately runs before later ASSIGNMENTS

A registration helper that invokes its handler synchronously (`fn();` on register)
runs that handler at the point of registration. Function *declarations* hoist, so
a constructor still resolves — but a method installed by **assignment** further
down the function does not exist yet, and `new Thing()` throws
`this.method is not a function`.

Register such handlers at the BOTTOM, and pin the ordering with a test that
compares index positions (`onResize(...)` must come after
`Prototype.method =`).

**Worse, the throw escapes the initialiser.** It aborted the particle setup, so
the *next* initialiser never ran and its canvas sat at its default size with no
error surfaced to the user. After touching an initialiser chain, assert that
every canvas got a real size — not just that the first one did.

## rAF is suspended in hidden tabs, so a debounce latch can stick

`requestAnimationFrame` does not fire in a background tab. A debounce written as
"set the latch, then request a frame" therefore leaves the latch `true` forever if
the frame never comes, and **every later event is dropped** — the background
freezes at one size until a reload.

```js
var ran = false;
function run() { if (ran) return; ran = true; latch = false; /* handlers */ }
if (window.requestAnimationFrame) requestAnimationFrame(run);
setTimeout(run, 100);   // the backstop, not tidiness
```

rAF is still the right primary clock — it lines the work up with the frame that
will show it. The timeout is what makes the latch self-healing.

## What a headless probe can and cannot prove about a fixed canvas

`position: fixed` resolves against the **viewport**, not the root or any
container. So narrowing a container correctly leaves a fixed canvas untouched —
that is the correct result, and it is worth asserting so the boundary is a tested
fact rather than an assumption.

A real viewport change **cannot be simulated** under `--dump-dom`. Say so in the
probe output rather than implying a viewport-resize pass. What IS provable: the
handler chain runs for a dispatched `resize` / `orientationchange`; a handler
re-derives the canvas from an element box you force to a known size (e.g. set a
wrapper to 600x400 and assert the backing store follows, then restore).

## Expose a read-only diagnostic for anything inside a closure

A test cannot see into an IIFE. Expose a small read-only hook — the node count,
the pair count, the canvas backing sizes, a handler-invocation counter, the
budgets — and the browser probe can assert real numbers instead of inferring.
Include the derived figure the cost actually depends on (pairs, not particles),
and a counter, so "did the handler even run" is answerable separately from "did
it produce the right value".
