# Verifying an INTERACTION in a real browser

When the complaint is a gesture that "does nothing" — a drag that will not import,
a button that silently fails, a "page loads empty" — **reading the code is not
evidence**. A drag chain can look correct at every link (source is `draggable`, the
payload is written, the drop target is bound, the handler parses it) and be dead,
because the throw happens inside a JavaScript handler where nothing the operator
can see reports it.

Use the skill's own `scripts/verify-ui-clicks.js`. Drive **production** over https
with `--ignore-cert` (`--base https://127.0.0.1`), so the very box the operator
uses is what gets tested; the origin cert is issued for the public hostname, and
plain http breaks the CSRF Origin check.

```bash
node scripts/verify-ui-clicks.js --base https://127.0.0.1 --ignore-cert \
  --path "/composite?id=33" --eval "(async () => { ... })()"
```

## The rules that make a probe honest

- **Collect errors in the same result.** `window.addEventListener('error', …)` and
  `('unhandledrejection', …)` pushed into an array returned by the eval. A
  delegated handler's throw is INVISIBLE otherwise: `dispatchEvent` returns
  normally to the caller, the DOM looks untouched, and the operator's only symptom
  is "nothing happened". The probe is the only thing that can see it.
- **Assert the SIDE EFFECT, never that the handler ran.** Measured on a completely
  dead drag: `dragover` was `defaultPrevented: true` and the payload arrived in the
  drop (`seenInDrop: 242`) — the handler had run and parsed everything — while the
  app's own state did not move (`8 -> 8` layers). A probe that checks "did the drop
  handler receive the payload" PASSES on a broken feature. Read the app's own
  readable state before and after: a hidden field the page syncs
  (`#compLayers`), the thumbnail's visibility, a row count.
- **`awaitPromise: true` is what lets you poll.** The script enables it, so the
  eval may be `async`. Anything rendered by an AJAX call — the scrapbook drawer's
  items are fetched, not in the markup — does NOT exist when the eval starts, and a
  synchronous probe reports the element MISSING. That is a false negative that
  reads as a missing feature. Poll instead:

  ```js
  let thumb = null;
  for (let i = 0; i < 40 && !thumb; i++) { await wait(150); thumb = document.querySelector('.scrap-thumb'); }
  ```

  Report `document.querySelectorAll('.scrap-item').length` alongside it, so
  "drawer is empty" and "drawer had not loaded yet" are distinguishable.
- **An `inert <template>`'s children are not in `querySelector` space.**
  `document.querySelector('#csFavTemplate [data-x]')` returns null and reads as a
  missing control; the markup is real and lives under `tpl.content`. Query
  `tpl.content.querySelector(...)` when probing a template's contents.
- **A throw in a *shared* helper kills every route into it.** Probe EACH entry
  point that reaches the same code, not just the one the operator reported: one
  null-hostile helper broke the drag, the file-picker path AND the "add blank"
  button, and fixing only the reported gesture would have shipped two dead
  controls. When the harness finds one, enumerate the siblings in the same run.

## Synthesising a drag

A drag is a sequence, and each step is what makes the next one legal:

```js
const dt = new DataTransfer();
thumb.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, dataTransfer: dt }));
// read it back to prove the SOURCE wrote what you think:
dt.getData('application/x-scrapbook+json');   // and Array.from(dt.types)

const dt2 = new DataTransfer();               // fresh one for the receiving side
for (const t of dt.types) dt2.setData(t, dt.getData(t));
const over = new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer: dt2 });
target.dispatchEvent(over);
over.defaultPrevented;                        // a browser refuses a drop it is not asked to allow
target.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt2 }));
```

- **Dispatch `dragover` too.** It is `preventDefault()` on dragover that makes the
drop legal, so a probe that only fires `drop` proves nothing about a real drag.
- **Drop on a DIFFERENT element than the one you expect**, to prove a page-level
  binding actually is one: the head, the page title, anywhere. Dropping on the same
  element the old code targeted cannot distinguish "bound to the page" from "bound
  to this element".
- **Prove the more specific target kept its own meaning.** Where two drops mean
  different things on one page (a reference image vs the job's source), assert that
  the narrower target still does ITS job and that the general handler did NOT also
  fire — otherwise the same drag does both.
- **An element that scrolls, clips or is behind an overlay** is a hit-testing
  question, which is what `--probe SEL` / `--click-probe SEL` answer (they report
  the top-most element at the centre). `elementFromPoint` tells you what the DOM
  says; a dispatched mouse event goes through the browser's own hit-testing.

## Pin it, then prove the pin bites

Turn the measurement into a test, and confirm the test FAILS without the fix:
re-apply the original defect, run the test, restore. A pin that passes both ways is
not a pin — it is a check that cannot fail, and it will be trusted.

For a markup/JS defect the assertion usually has to be over the source (the
stylesheet, the view, the script) because there is no unit under test. Keep those
assertions NARROW and name the behaviour, not the literal text:

- extract the function and assert its shape (`/function keyOf\(l\)\s*\{[^}]*\}/` then
  `/l\s*&&\s*l\.key/`), not a whole-file `assert_match`;
- assert the invariant *and* the call site that needs it, so the check cannot pass
  by describing nothing;
- refute the remover explicitly (`refute_match(/canvas\.addEventListener\('drop'/`, "the
  canvas-only target is what required a precise hit") so a revert is caught.

## Viewing the LIVE authenticated page when the browser cannot reach the origin

When the browser backend is remote (cannot reach `127.0.0.1:3001`) but CAN reach
the public URL, and you need to SEE the rendered page (not just the served HTML),
inject the Rails session cookie into the browser via CDP instead of logging in:

1. Get a session cookie from the urllib harness (login over loopback, read the
   `_chopshop_studio_session` cookie from the jar). The value is URL-encoded and
   the cookie is `Secure`.
2. `cdp('Network.setCookie', name='_chopshop_studio_session', value=<url-encoded>,
   domain='<public-host>', path='/', secure=True)` — the domain must be the
   PUBLIC host, not 127.0.0.1, or the browser will not send it.
3. `goto_url('https://<public-host>/projects/1')` — the page is now
   authenticated.

The cookie is the same signed/encrypted session regardless of which hostname
served it, so a loopback login transfers to the public origin. Re-fetch a fresh
cookie after every server restart (the session is invalidated). This is the
fallback when the vision model cannot process screenshots and the browser cannot
reach the local origin — it is how you actually LOOK at the page instead of
reporting structure checks.

## Distinguish "never worked" from "regressed"

A user saying "it used to work" is a hypothesis, not a fact — the gesture that used
to work may be a DIFFERENT one on the same page. Both are worth checking, and both
are cheap:

```bash
git log -L '/function keyOf/,+1:app/views/<page>.html.erb' --oneline   # the helper's whole life
git log --oneline -S 'keyOf(null)' -- app/views/<page>.html.erb       # when a call site arrived
```

If a helper and the call site that breaks it arrived in the SAME commit and the
line never changed since, the feature **never worked** — no regression to hunt, and
no bisect worth running. Say which it is; it changes what the next reader looks for.
