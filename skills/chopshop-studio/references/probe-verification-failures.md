# Four more ways to build a probe that cannot fail

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
