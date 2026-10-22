> HOST-SPECIFIC — the chromium binary path (`~/.cache/ms-playwright/…`)
> is this box's. The probe technique is generic.

# Verifying layout in a real browser

Any claim about a box — "67%", "fits its column", "the same size as", "does not
grow vertically" — is a claim about pixels. Rails tests see strings; they cannot
see a box. Measure it, or do not say it.

The suite proves structure. Chromium proves layout. Both, always.

## The harness

Three parts, all disposable. Nothing here ships.

**1. A temporary integration test that writes the page out.** It renders through
the real route (so auth and real data apply), strips `<script>`, and writes an
HTML file with the real stylesheet inlined. Delete it afterwards — it is not a
test, and leaving it behind means the next person inherits a fixture dump.

```ruby
doc = Nokogiri::HTML(response.body)
doc.css("script").each(&:remove)
frag = doc.at_css(".results-split").to_html
css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))
        .gsub("</style", "<\\/style")      # the one CSS escape that matters
html = File.read(TPL).sub("__HEAD__", css).sub("__FRAG__", frag)
File.write(OUT, html)
```

**2. A template that carries a result slot.** The probe writes into a
`<pre id="result">` at the end of body; nothing else reads it.

```html
<div id="stage" style="width:1272px">__FRAG__</div>
<pre id="result">running</pre>
<script>
setTimeout(function () {
  var out = [], fails = 0;
  function ok(c, m) { if (!c) fails++; out.push((c ? 'PASS  ' : 'FAIL  ') + m); }
  /* ... measure ... */
  out.push(fails === 0 ? 'ALL PASS' : fails + ' FAILURES');
  document.getElementById('result').textContent = out.join('\n');
}, 900);
</script>
```

Pin the stage width explicitly. Percentages of an unconstrained body measure
against whatever the browser picked, not the real container.

**3. Chromium, then parse the `<pre>` out of the dumped DOM.**

```bash
~/.cache/ms-playwright/chromium-*/chrome-linux64/chrome \
  --headless --disable-gpu --no-sandbox \
  --virtual-time-budget=9000 --window-size=1500,1000 \
  --dump-dom file://$PWD/probe.html > probe_dom.html 2>/dev/null
python3 -c "import re,html; d=open('probe_dom.html').read(); \
  print(html.unescape(re.search(r'<pre id=\"result\">(.*?)</pre>',d,re.S).group(1)))"
```

## Chromium rewrites the value you wrote

`getComputedStyle` returns a NORMALISED value, not the authored one. A probe
asserting on the literal source text reports failures against correct CSS — three
of them at once once:

- `saturate(150%)` computes to `saturate(1.5)`. Match `/saturate\(1\.5\|150%\)/`.
- `linear-gradient(to bottom, …)` loses the `to bottom` — it is the default, so
  Chromium drops the keyword. To assert DIRECTION, test the stop ORDER: the
  first stop is the `to` edge, so a mirrored bar is proven by its heavy stop
  moving to the other end, not by a keyword that may not survive.
- With the gradient in `background-image`, `backgroundColor` is `rgba(0,0,0,0)`.
  To measure glass alpha read the `rgba(...)` stops out of `backgroundImage`;
  asserting on `backgroundColor` measures nothing and reads `0`.

Rule: when a check fails, **print the raw computed value and compare it against
the authored rule before editing CSS.** Every one of these was the probe's bug.

## Pitfalls

Each of these produced a wrong or passing-but-false result.

- **The page's own inline `<script>` sitting next to the probe script in `<head>`
  makes Chromium refuse the whole file** ("Your file couldn't be accessed", and
  `--dump-dom` emits a `neterror` document). Not a size limit, not a permissions
  problem. Put the probe AFTER the page's script at the end of body, or write the
  page script to a separate `.js` and pass `--allow-file-access-from-files`.

- **Extract fragments with Nokogiri, never regex.** A non-greedy
  `/<div class="popup".*?<\/div>\s*<\/div>/` cut a five-deep popup at the wrong
  close — 4 opens against 6 closes. The panel then sat outside its padded parent
  and every measurement was an artefact of broken markup. Count opens against
  closes and raise before measuring.

- **`getBoundingClientRect()` on an `<img>` with `object-fit: contain` returns
  the ELEMENT BOX, which is identical for every aspect ratio.** It looks like a
  pass while a portrait raster paints at 8% of the box. Derive the painted size
  from `naturalWidth`/`naturalHeight` with the contain formula, or assert the
  ratio of the box to the painted art.

- **`img.src = x; read naturalWidth` in the same tick reports the PREVIOUS
  image.** Await `img.decode()`, or all "aspects" measure as the first one.

- **Ternary selector keys must match the array they are tested against.**
  `'head-action' === '.head-action'` is never true, so every branch falls through
  to the first element and the page looks broken when it is fine.

- **`:hover` cannot be faked without CDP.** A class-based stand-in loses to
  `!important` ordering in ways that mislead. Assert the rule EXISTS in the
  stylesheet with the right values, and say plainly that the hover state is
  verified as a rule, not as a computed style.

- **A helper that returns the element where the caller expects the rect lies
  quietly.** Report the raw value on failure so the probe cannot hide a `TypeError`
  behind a pass.

- **A `--surface`-backed element is 3% white, and 3% white on 3% white is
  invisible.** A table or panel that "looks translucent" is usually not
  translucent by intent — it is inheriting the ambient surface token on top of a
  card that already used it, and the `position: fixed` colour orbs behind show
  through the cells. Solid means a real base colour that is only a shade off the
  page (`--table-bg: #101018` against a `#0a0a0f` body), not a different-coloured
  slab. Re-measure contrast on the NEW base; AA is 4.5:1.

- **`open(p, "w").write(open(p).read()[:i] + open(p).read()[j:])` truncates the
  file to zero bytes.** The outer `open(p, "w")` is evaluated BEFORE the argument
  expressions, so both reads return `""`. Read into a variable, slice the
  variable, write once.

## Proving a behaviour-preserving re-point (rename / migrate / token change)

When the change's claim is "computes exactly what it computed before" — a CSS
re-point onto tokens, a class rename, a shared-rule merge — the proof is A/B
computed values over real rendered pages, not a green suite:

1. Render the same real pages under the OLD sheet and the NEW sheet (inline
   each into the harness; `git show <old-rev>:app/assets/stylesheets/application.css`
   is the baseline) and assert each legacy carrier's computed values are
   IDENTICAL across the two — compare strings (bg, color, border-*, radius,
   font-*, opacity, display), never eyeball.
2. When rules read `var(--token, old-literal)`, prove the FALLBACK property:
   delete the token block, re-run the A/B, and require the old values.
3. **Mutation-test the probe itself** — flip one token value and require the
   comparison to FAIL. An A/B probe that cannot tell 0.15 from 0.25 reports
   "identical" forever (`probe-verification-failures.md`).
4. Count the elements actually matched per page: a comparison over zero
   elements is vacuously green.

## CSS rules this harness actually caught

- **A percentage width resolves against the parent's CONTENT box.** `.popup` is
  padded, so `width: 60%` measured 55.6% of the window. When the ask is "N% of
  the viewport", the rule is `Nvw` — and a `min-width` in `rem` will silently
  become the binding constraint and pin the panel at a fixed pixel size on any
  window narrower than `Nvw / rem × 16`. Drop the floor with the width.

- **`.col-narrow` / `.col-thumb { width: 1% }` rules have specificity (0,2,2)**
  and beat `.my-table td:nth-child(n)` at (0,2,1). Every column collapses to 1%
  and one auto column eats the rest — the table reports a plausible total width
  while its contents spill sideways. Prefix overrides with the full base selector
  (`table.candidates.proofs-tbl td:nth-child(1)`) or the override loses silently.

- **`table-layout: auto` sizes a table to its content and will exceed a narrow
  grid track**, turning the column into a sideways scroller. Use
  `table-layout: fixed` + explicit per-column widths + `max-width: 0` on the
  name cell to make the ellipsis bite.

- **Stretching an element to fill its container and letting `object-fit: contain`
  letterbox the art inside leaves MORE dead space than hugging the art.** When
  the ask is "fit the preview to the space", prefer `flex: 0 1 auto` with
  `width: auto`; reserve `flex: 1` for when the element should be a frame.

- **`position: sticky` on a box that can outgrow the viewport strands its lower
  rows** — the top pins and the rest is unreachable. Sticky suits a short control
  rail, not a list.
