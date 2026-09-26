---
name: chopshop-studio-ui
description: Use when changing the Rails studio UI (validation/job pages, popups, CSS effects, the mock runner). Covers the private-repo rules, Turbo-safe JS, stacking-context traps, and the container render harness.
---

# chopshop-studio — the operator UI

**This repo is PRIVATE.** `chopshop-svg` is the public one. Nothing here may
assume a fixed host, and nothing from the SwarmUI layer (`chopshop-sui`) or the
Jev credentials belongs in the public repo. `JEV_API_KEY` and any key are
held runner-side and must never appear in a view, a log line, or output.

## Verify changes in a real render, not by reading the template

There is no local Ruby on the dev host. Render the app in a container and
drive it with curl; that is the only way to know a view parses.

```bash
podman run --rm -v "$REPO:/app" -p 127.0.0.1:3001:3001 ... ruby:3.3-slim sh render_studio.sh
```

Traps that cost real time:

- `ruby:3.3-slim` ships **no bundler, no curl, and no python3**. Install what
  the script needs; a readiness probe that silently no-ops because `curl` is
  absent looks exactly like a healthy boot.
- `-v "$PWD:/w"` inside a `sh -c` whose `$PWD` did not expand mounts
  **nothing** and the run still appears to work. Absolute paths, always.
- A stale `tmp/pids/server.pid` from an aborted run blocks boot. `rm -f`.
- `tail -3` swallows the real `bundle install` error. Use `tail -25`.
- Seeding must use the job's **real id** after the fact. A `delete_all` +
  re-seed does not reliably produce id 1, and a wrong id 404s while the app is
  healthy.

Then confirm the thing you actually changed, not just that the page is 200:
a 200 can be a page missing the feature entirely. Check the markup, and
screenshot it — see the layering trap below for why the DOM alone is not
enough.

## Turbo: bind delegated, or bind once per element

Any per-element `addEventListener` bound inside an init that Turbo re-runs is
re-bound on **every navigation**, because Turbo replaces the body. The
`dataset.bound` guard does not help: fresh elements have no flag set, so it
never fires and the code looks handled while getting worse.

This is not theoretical. The magnetic-button effect bound one `mousemove` per
button; after a few page changes a single mousemove fired N transforms and a
row of buttons visibly moved in sync. Fix: one delegated listener on
`document`, bound exactly once, with writes coalesced into a single
`requestAnimationFrame`. Test it by counting how many elements hold a
`style.transform` after ONE synthetic mousemove — the answer must be 1.

**Clear transforms with `transform = ''`, never `translate(0,0)`.** Any
transform value, including the identity, makes the element a stacking
context, and a leftover one flips a `.btn-primary`'s `z-index:-1` glow ring
from behind the button to over its fill — so a button looks subtly wrong for
the rest of the session.

## Stacking contexts: the bug a DOM assertion cannot see

A popup that opens, reports itself laid out at 1088x481, has a correct
computed `z-index` and correct bounding box — and paints **nothing**. Every
DOM-level assertion passes. Only a screenshot shows it, because the element
is genuinely being composited *behind* an opaque full-screen layer.

Two traps in this repo specifically:

- The first-run welcome overlay is `z-index: 9500`. Any new popup must clear
  that, not just beat `position: fixed` defaults.
- `z-index: -1` on a pseudo-element needs a **stacking context on its own
  parent**. `.logo-icon` was `position: relative` with no stacking context, so
  its `::after` highlight ring resolved against an ancestor's
  `backdrop-filter` and painted behind the header — the effect had never once
  been visible on any page. `isolation: isolate` is the fix, and the comment
  needs to say *why*, or someone will remove it as redundant.

Rule: **when an effect is declared but cannot be seen, suspect the stacking
context before suspecting the gradient.** Check `isolation`,
`getComputedStyle(el).isolation`, and `document.elementFromPoint()` at the
element's own centre.

## Animations must read as continuous

A conic-gradient highlight sweeping 50deg of a 360deg rotation is on screen an
eighth of the time. It does not look like a travelling sheen, it looks broken.
Widen the band and slow the rotation. Under `prefers-reduced-motion`, do not
merely stop the animation — a frozen conic-gradient reads as a rendering fault;
swap it for a static soft ring.

One animated control per cluster. Two light sources in a 44px header read as a
fault, and text you read is not an indicator.

## Distinguish actions from documents

An action gets a decorated button; a document gets a text block with a dotted
underline. A manifest presented as an icon button makes a thing you read look
like a thing you do. Put both on the line they describe (`Validation #N`), not
in a column at the far right — off to the side they stop being attributable.

Show state on load, not only after the interaction that produced it: a button
that turns green only in the session that asked it is green for one operator
and grey for the next.

## Privacy

`/about`, `/json`, `/jev` were ungated by omission. Gate by default and set
`X-Robots-Tag: noindex, nofollow, noarchive, nosnippet`; verify with curl on an
**unauthenticated** request, expecting a 302 to `/login`.

`config/master.key` was tracked from the first commit. Untracking it does not
unpublish it — say so in `.gitignore` and treat any key ever pushed as
compromised and rotate it. Prove the app still boots with the key absent
(`bin/rails runner` printing a marker) **before** `git rm --cached`.

Deployment config is environment-specific, not secret, but still must not be
tracked: keep hosts in `CHOPSHOP_EXTRA_HOSTS` and friends.
