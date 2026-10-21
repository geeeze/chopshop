# More ways to build a probe that cannot fail

## A programmatic `.focus()` is not a keyboard user

Asserting an element becomes visible "on focus" with `el.focus()` reports a
FALSE NEGATIVE when the reveal is written with `:focus-visible`: Chrome only
matches `:focus-visible` for focus that came from real keyboard interaction, so a
scripted `.focus()` leaves the element at `opacity: 0` and the probe reads
"keyboard users cannot see this control" about CSS that works. Drive real Tab
keys through CDP instead:

```python
for _ in range(3):
    cdp('Input.dispatchKeyEvent', type='rawKeyDown', windowsVirtualKeyCode=9, key='Tab', code='Tab')
    cdp('Input.dispatchKeyEvent', type='keyUp', windowsVirtualKeyCode=9, key='Tab', code='Tab')
    print(js("JSON.stringify({a: document.activeElement.id, o: getComputedStyle(document.activeElement).opacity})"))
```

Same family as the traps below: an element inside a `hidden` popup cannot be
focused at all, so a focus probe run after closing the popup reports "not
focusable" about a button that is fine. Open the container first, and assert
the thing you actually care about (that a keyboard user SEES it), not the
mechanism you happened to reach for.

Extracted from SKILL.md (it was 2.4 KB of the always-loaded body). Every one of these
reports a CONFIDENT GREEN, which is why they are worth reading before trusting a probe
that passed on the first run.

  **Four more ways to build a probe that cannot fail, all of which report a confident green:**
  (1) **The mutation never landed.** A `sed` whose pattern does not match exits 0 having changed
  nothing, and the untouched control then "passes" — the file wrote Python `scheduler="lcm"` while the
  pattern looked for `"scheduler": "lcm"`. After any edit you make as part of a probe, ASSERT the
  change took (`grep` for the new value) before running the check on it, and assert the check's own
  failure message names the field you corrupted.
  (2) **You compared the wrong invariant.** A palette CYCLE permutes colours among themselves, so
  comparing the colour SET reports "nothing changed" for a transform that is working; compare the
  ordered per-element sequence. Ask what the strongest available comparison is before concluding a
  feature is dead: byte hash > ordered sequence > set > count.
  (3) **Your harness varied a variable the artifact records.** Two runs into DIFFERENT output
  directories differ in the field that stores the output path — that is not nondeterminism, and
  reporting it as one is a false finding in a feature that was correct. Hold everything you are not
  testing constant, or normalise the recorded value out before comparing.
  (4) **The harness read its OWN bug as the system's answer.** Whenever a probe treats "it raised" as
  the expected outcome — a refusal path, a rejected input, an inapplicable transform — the probe's own
  wrong call produces an exception that the harness records as the behaviour under test. Measured
  twice in one session: a probe passed a keyword the function does not accept, and another passed
  bytes where a path was expected; each raised `TypeError` and the harness wrote "REFUSED, nothing
  left behind" — a confident PASS built entirely out of the probe's own mistake, on a claim that was
  never exercised. So assert on the exception's TYPE **and its MESSAGE**, never merely that one
  arrived, and have the harness name its own bugs explicitly (`except TypeError: verdict =
  "HARNESS-BUG"`, never PASS). A refusal you cannot quote is a refusal you did not observe.
  Before reporting ANY finding, ask two questions: "would this check report the same thing if the
  feature were absent?" and "did my change actually land?" Both false alarms above were caught by
  asking the second one, and discarding them is as much the job as finding the real one.

## A source-reading test greps text the renderer will never show

When a change keeps the OLD markup reachable behind a switch (hide, do not remove —
the revert-is-a-deletion rule), the kept fallback stays in the file's TEXT while the
DOM no longer renders it. A test that greps the view file for the old marker then
passes in BOTH switch states — a source read cannot tell live markup from dead
markup — and it can contradict a rendered test while both are green. Worse, it
false-alarms on the documented recovery: deleting the fallback removes the very text
the source read looks for, so the test fails on the revert path it was protecting.
Two directions of wrong, one cause. Rules:

- The rendered contract belongs in a DOM-walk test asserting BOTH branches: switch
  on -> the old marker ABSENT from the render and the new one present; switch off ->
  the old marker back where it was.
- When a fallback lands, grep the test tree for source-reading assertions on the
  markers it keeps (the defect's literal is usually pinned in an assertion that looks
  unrelated), and re-pin each onto the rendered contract or drop the migrated pages
  from its list. A source read should cover only what still renders by default.
- The same shape of false green applies to kept CSS rules and kept dead branches in
  any language: if the artifact under test can contain unreachable text, the test
  must assert the RENDERED (or executed) surface.
