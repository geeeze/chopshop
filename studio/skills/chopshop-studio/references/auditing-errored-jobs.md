# Auditing the errored jobs on a live box

The Jobs list's `state: "error"` rows are the cheapest source of real bugs in this
system, because each one is a request that got past every check and then failed in
a service the operator cannot see. Group them by ROOT CAUSE, not by job: nine
errored jobs in one audit collapsed into three classes, and two of those were the
same rule reached by different doors.

## Class 1 — a rule that was WRONG, not missing

`STEP_FILE_RULES["svg"]` accepted `.svg` from the previous step, so the natural
chain `bp generate → svg trace` validated, ran step 1, and died inside the runner:

```
UnidentifiedImageError: cannot identify image file '/data/uploads/plot_x.svg'
```

The trace stage preps its source with **PIL, which has no SVG reader**. A drawing
has to be RENDERED to PNG first (a bp `blender` step does). Nothing about the page
looked wrong — both steps were individually valid.

**The same rule was reachable three ways**, and fixing one is not fixing the class:

| route | what to fix |
|---|---|
| a step list chaining a drawing into a trace step | the step's `accepts` list |
| a composite's VECTOR flatten handed to Run Job | the create gate below |
| a direct `POST /jobs` naming `uploads/*.svg` | the create gate below |
| the scrapbook drop route | its own extension check |

### Where the check belongs

**`JobsController#create` — the one door every real job comes through** (the form,
the composite/inverse/reuse hand-offs that prefill it, and an agent posting the
contract). NOT a model validation: the suite's dominant fixture convention is a
filler `.svg` input path, so a model invariant rewrite ~40 test files for no extra
coverage (measured: 376 errors).

Ask it of the **KIND and the FILE**, never `source_kind` — that column is
studio-side bookkeeping the runner IGNORES, and every failed job carried
`"raster"` while pointing at an SVG.

Word the refusal in **ONE place** (`Job.trace_source_refusal`) and call it from
every surface, including the upload route. And name the **WAY OUT** — "cannot open
an SVG" is a dead end when tracing a drawing is a reasonable intent with a real
answer (render it, or flatten as pixels).

## Class 2 — a test that was pinning it

Two tests asserted the broken behaviour, and both said so in their own words:

- `run_bp_test`: `assert_includes …[:accepts], ".svg"` under the comment *"which is
  what makes a chain through bp derivable at all"* — that derivability WAS the bug.
- `run_steps_test`: an ordering test whose first hand-off was `plot(.svg) →
  pipeline`, using **swapped clients**, so it never noticed the real runner cannot
  open the file.

When a rule change breaks a test, read the assertion's MESSAGE before touching it
— an intent statement tells you whether it guards a contract or a bug. Both here
guarded a bug. Fix the FIXTURE, not the rule: the ordering test keeps every
structural assertion by swapping its first step for a generator (a PNG).

## Class 3 — not bugs, and saying so

The rest of the errored rows were **working correctly** and should be reported as
such rather than "fixed":

- `generate spec.canvas: missing required field 'width'` — the caller nested the
  size wrongly.
- `tree spec: missing required field 'nodes'` — the caller sent `root`.
- `unknown element type 'sphere'` — not in the contract's element set.
  These are 400s doing their job: they teach the contract, and an agent probing the
  surface SHOULD get them.
- `the queue is full (5 jobs waiting for you)` — the per-user guard, by design.
- `flux service connection failed: end of file reached` — transient. Check the
  service's own journal before blaming the studio: it had been **restarted by
  another operator** at the moment the job ran (`systemctl --user show
  chopshop-flux -p ActiveEnterTimestamp`).

## The collision that wastes a round

A full-suite run reported **865 errors in 9.6 s** (vs ~48 s green). Every one was
`SQLite3::BusyException`: another Rails test run was holding `storage/test.sqlite3`.

The signature is the SPEED and the COUNT — a green suite here is ~950 runs in
~45 s. Confirm with `fuser -v storage/test.sqlite3`, then wait for the specific
PID (`kill -0 <pid>`, bounded — never a self-matching `pgrep`) and re-run. Do not
debug the "failures".
