## Verify an issue's live state before acting on it

A ticket's `state` field is the source of truth, not your memory of the
backlog. Before implementing, commenting, or "closing" an issue, fetch the
issue AND its comments AND its timeline:

```python
import urllib.request, json, os
token = os.environ.get("GH_TOKEN")
def get(p):
    r = urllib.request.Request("https://api.github.com"+p,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"})
    return json.load(urllib.request.urlopen(r, timeout=30))
issue = get(f"/repos/{owner}/{repo}/issues/{n}")          # state, state_reason
comments = get(f"/repos/{owner}/{repo}/issues/{n}/comments")  # the decision, usually
        # in the LAST comment by the closer
timeline = get(f"/repos/{owner}/{repo}/issues/{n}/timeline?per_page=100")
        # closed/referenced events + the commit_id a close references
```

The closing commit (`timeline` event `referenced` with a `commit_id`) is the
proof the fix landed — `git branch -r --contains <sha>` and `git show --stat
<sha>` confirm it is on `main` and what it changed. A ticket that reads like
open work but is `closed` with a recorded decision and a landed commit is
DONE: report the resolution, do not re-open or re-implement. Re-opening a
closed ticket (or re-doing closed work) is the failure this rule prevents.

## A subagent that dies in a repetition loop leaves an intact working tree

When a dispatched `delegate_task` child fails with "repetition loop / stream
cut mid-loop", its PARTIAL WORK IS ALREADY ON DISK in the working tree / branch
it was told to use. Do not re-dispatch from scratch. Instead:

1. `git branch --show-current && git status --short` — recover the files it wrote.
2. Read the partial diff (`git diff`, the new files) and finish the remaining
   steps yourself — the loop usually dies mid-TEST-DEBUGGING, so the code is
   written and one or two tests are failing. Fix the tests, run them green.
3. Commit on the feature branch (children must not push; the parent commits).
4. THEN dispatch a fresh REVIEWER subagent against the commit — do not trust
   your own just-written code, and do not re-dispatch a second implementer.

The two most common reasons a child's test fails at death: a test that
references a route-helper / symbol that does not exist as written (grep
`config/routes.rb` for the real `as:` name), and a test that posts an INVALID
enum value (e.g. a `runner:` label that is not in `Model.runners.keys`) so a
model validation fails and the recording silently returns nil. Both are TEST
bugs, not action bugs — fix the test, and harden the action so a bogus override
falls back safely instead of dropping a recording.
