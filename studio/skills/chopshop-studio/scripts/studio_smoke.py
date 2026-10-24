#!/usr/bin/env python3
"""Hourly smoke test for a third studio account.

Logs in as one user and files a small, STAGED set of runs so the account fills
with real demos instead of staying empty — and so the box is never asked to do
more than it should.

ONE RUN IS ONE JOB, AND THE RUN ID IS IN ITS NAME.

This is the shape the operator asked for (2026-09-29): a test pass must not
fill the job list with single items, and the jobs that DO exist must be
identifiable as one set. Both halves are load-bearing:

  * **One job per pass.** The eight operations ride as `spec["steps"]` — an
    ordered step list on ONE record — so an hourly pass adds ONE row to the job
    list, not eight. The studio drives the chain itself (`RunJob#run_steps`),
    which is also why nothing is parallelised: the single Solid Queue worker
    thread means one job in flight IS one unit of work.
  * **A run id every job of the pass carries.** `RUN_ID` is stamped ONCE, before
    the first submit, and every job name starts `smoke-<RUN_ID>`. Before this,
    names were stamped at SUBMIT time to the minute, so a pass that crossed a
    minute boundary filed `bp-digest-…-1712` and `flux-…-1713` and the set was
    no longer greppable as one thing (measured on the live box: jobs 432-439 of
    the 17:12 pass carry two different stamps). `--individual` now stamps every
    job with the SAME run id.
  * **Old runs are bounded, not accumulated.** `--keep N` deletes this account's
    own `smoke-*` jobs beyond the newest N runs — and only those: the scope is
    the signed-in account plus the name prefix, so the operator's jobs and other
    users' jobs are unreachable from here. The cron uses `--keep 3`.

THE STAGING RULE, and why it is here rather than left to taste:

The studio already serialises every job through ONE Solid Queue worker thread
(`config/queue.yml`: queues "runs", threads 1) and caps a user's queue at
`RunJob::MAX_QUEUE_PER_USER = 5`. So the studio cannot be made to run two jobs
at once by submitting many. What it CAN be made to do is fill a queue, and what
that costs depends entirely on WHAT you submit:

  * A bp PLOT op (generate/digest/query/tree/log) is a document drawn in
    process: no GPU, no model, seconds. Cheap.
  * A bp BLENDER op renders geometry: CPU, tens of seconds. Moderate.
  * A pipeline TRACE sweeps candidates: CPU, one to three minutes. The
    expensive one.
  * A FLUX generation is a GPU diffusion run: the most expensive thing on the
    box, and it lives on a DIFFERENT host.

So this script submits exactly ONE job at a time and WAITS for it to reach a
terminal state before filing the next. It never has more than one job in
flight, which keeps it at one unit of work whatever unit that is — and it
means a slow run delays this script rather than piling onto the box. In a chain
the same rule is kept by construction: the steps of one job run in order, and
the next job is not filed until this one is terminal.

Step order is DEPENDENCY-FREE, and that is the rule to keep: the trace goes
first because it is the only step that needs a file and it takes the JOB's own
upload; every other step takes nothing. So dropping any of them (`--skip`) or
losing one (a busy GPU) cannot take another step down with it — measured on this
box, where an LM Studio llama-server holding 14.7 GB of the card's 17.1 GB makes
the flux step fail with a CUDA OOM while the six steps above it are green. Flux
is last and once per pass because it is the one op that reaches for a GPU on
another machine; a flux failure is therefore reported as ONE failed step.

Usage:
    python3 studio_smoke.py                    # ONE job, eight steps
    python3 studio_smoke.py --individual       # one job per step, one run id
    python3 studio_smoke.py --keep 3           # after the pass, keep 3 runs
    python3 studio_smoke.py --password-file F  # read the password from a file
    python3 studio_smoke.py --list             # print the plan and exit
    python3 studio_smoke.py --dry-run          # log in and report, file nothing
    python3 studio_smoke.py --only bp          # substring filter over the steps
    python3 studio_smoke.py --skip flux        # drop a step whose dependency is busy

The password NEVER appears on a command line (it would land in `ps` and in shell
history); it comes from a file, or from CHOPSHOP_DISPOSABLE_ACCOUNT_SECRET in
the Hermes env file, or from stdin.

Exit codes: 0 ok, 1 a step did not reach `done`, 2 usage/refused.
"""

import argparse
import http.cookiejar
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("CHOPSHOP_BASE", "http://127.0.0.1:3001").rstrip("/")

# Every job this script files is named with this prefix. Pruning keys off it, so
# it must not be used by hand-filed jobs in the same account.
RUN_PREFIX = "smoke-"

# The two demo run records the `query` op draws across, read from bp's
# consolidated location in the one repository (~/chopshop/bp/examples; the
# pre-monorepo path ~/chopshop-bp is honoured only via the override). The
# script reads the service's own examples at import time rather than pasting
# them in. They are the service's
# fixture data, so a query against them is a query against something the service
# already accepts -- and if the repo is not where it is expected, the query step
# fails loudly instead of drawing an empty chart.
BP_EXAMPLES = os.path.expanduser(
    os.environ.get("CHOPSHOP_BP_EXAMPLES", "~/chopshop/bp/examples"))


def _run_record(stem):
    with open(os.path.join(BP_EXAMPLES, "runs", stem)) as f:
        return json.load(f)


RUN_RECORD_01 = _run_record("demo-01.run.json")
RUN_RECORD_02 = _run_record("demo-02.run.json")

# How long one JOB may take before this script stops waiting and moves on. The
# studio's own pipeline step timeout is 1800s; this is deliberately SHORTER,
# because a smoke test that waits 30 minutes is a smoke test nobody keeps. A
# chain of eight steps is one job, so this covers the WHOLE pass: the cheap
# steps answer in seconds and the trace dominates, so the budget is what a
# single pass legitimately needs rather than what one step needs.
JOB_TIMEOUT = 900
POLL_INTERVAL = 5

# A source raster for the trace run. Generated here rather than shipped so the
# script has no binary dependency and no upload step that can fail: a small
# pure-Python PNG (a 64x64 four-quadrant colour block) is enough for a sweep to
# find edges, which is all a smoke test asks of it.
SOURCE_PNG_W = 64
SOURCE_PNG_H = 64


# --------------------------------------------------------------------------
# the plan, cheapest first
# --------------------------------------------------------------------------

def build_plan():
    """The steps one pass runs, in order. Each entry is (name, runner, spec).

    `bp` is the one action that reaches both halves of the blend-plot service, so
    six of these eight cover its WHOLE surface: five drawing ops on the plot side
    and one 3D render on the blender side, then a trace and a generation for the
    pipeline and the generator.

    THE `doc` BLOCKS ARE NOT INVENTED. They are taken from chopshop-bp's own
    `examples/*.json`, each of which the service's own validator accepts --
    that is the only reason to trust a spec enough to submit it unattended. An
    earlier hand-written set was wrong in three separate ways and the service
    refused it, which is the point: a smoke test that submits plausible-looking
    JSON tests nothing but its own author's imagination. (The shapes that bit:
    `generate` needs a `canvas` block and points are COORDINATE PAIRS, not an
    SVG points string; `tree` needs `nodes` + `edges` with a `kind` on every
    node, not a `root`; `query` takes a CHART plus axes, not labels/series, and
    needs a non-empty `runs`.)

    Size is trimmed from the examples where the operation allows it -- a 1024px
    four-view blender render is a real render, but it is also minutes of CPU
    for a test that only needs to know the half is wired.
    """
    return [
        # 1. The pipeline: a real trace of the script's OWN uploaded raster. It
        #    goes FIRST for two measured reasons. It is the only step that needs
        #    a file, and a trace step can only take the JOB's artwork when it is
        #    the first step (`step_takes_previous?` counts only "previous" or a
        #    blank input as a hand-off, so any later trace step is validated
        #    against the step above it) — putting it first removes the only
        #    inter-step dependency in the chain, so no step's failure can take
        #    another with it. And the upload is what lets it run at all, so both
        #    modes exercise /jobs/upload.
        #
        #    `input: "job"` is declared by the chain builder, never here: the
        #    declaration goes BESIDE the runner label, not inside the block.
        ("trace", "svg", {
            "print_method": "screen_print",
            "max_colors": 4,
            "sweep_max_candidates": 3
        }),

        # 2. bp plot: the geometry source. Cheapest thing on the box.
        ("bp-geometry", "bp", {
            "bp": {"op": "generate", "doc": {
                "title": "smoke: geometry source",
                "canvas": {"width": 600, "height": 400, "background": "#0f1020"},
                "elements": [
                    {"type": "rect", "x": 30, "y": 30, "width": 540, "height": 340,
                     "fill": "none", "stroke": "#6366f1", "stroke_width": 6, "rx": 12},
                    {"type": "circle", "cx": 300, "cy": 200, "r": 120, "fill": "#22d3ee"},
                    {"type": "polygon", "points": [[300, 60], [430, 300], [170, 300]],
                     "fill": "#f472b6"}
                ]}}
        }),

        # 3. bp plot: the metrics digest. Two series, so the bar chart has
        #    something to group.
        ("bp-digest", "bp", {
            "bp": {"op": "digest", "doc": {
                "chart": "bar",
                "title": "smoke: candidate scores",
                "size": {"width": 800, "height": 420},
                "data": {
                    "labels": ["c1", "c2", "c3", "c4", "c5", "c6"],
                    "series": [
                        {"name": "score", "values": [0.92, 0.71, 0.88, 0.44, 0.95, 0.62]},
                        {"name": "ink", "values": [0.6, 0.82, 0.45, 0.71, 0.55, 0.66]}
                    ]}}}
        }),

        # 4. bp plot: the cross-run query. `runs` is required for this op and
        #    for no other, and it must not be empty -- the service draws ACROSS
        #    the records it is given, so an empty list is a refusal, not an
        #    empty chart. The records are the service's own demo run files.
        ("bp-query", "bp", {
            "bp": {"op": "query",
                   "runs": [RUN_RECORD_01, RUN_RECORD_02],
                   "doc": {"chart": "scatter",
                           "x": "node_count_max", "y": "mae_art",
                           "color": "preset",
                           "title": "smoke: candidates by preset"}}
        }),

        # 5. bp plot: the hierarchy tree -- the STATUS page's own document
        #    shape. `layout` "tb" is what the service's validator accepts as the
        #    default; the studio's status page overrides it to "lr".
        ("bp-tree", "bp", {
            "bp": {"op": "tree", "doc": {
                "title": "smoke: source to candidates",
                "layout": "tb",
                "nodes": [
                    {"id": "source", "label": "source.png", "kind": "root", "status": "ok"},
                    {"id": "prep", "label": "prep", "kind": "step", "status": "done"},
                    {"id": "tracer", "label": "tracer", "kind": "tool", "status": "done"},
                    {"id": "gate_a", "label": "Layer A gate", "kind": "gate", "status": "passed"},
                    {"id": "gate_b", "label": "Layer B gate", "kind": "gate", "status": "warning"},
                    {"id": "report", "label": "report", "kind": "note"}
                ],
                "edges": [
                    {"from": "source", "to": "prep"},
                    {"from": "prep", "to": "tracer"},
                    {"from": "tracer", "to": "gate_a"},
                    {"from": "gate_a", "to": "gate_b"},
                    {"from": "gate_b", "to": "report"}
                ]}}
        }),

        # 6. bp plot: the event log -- one row per recorded action, and `pos`
        #    is a position in the candidate order the run ranked them in, so a
        #    log whose positions do not exist is not a log.
        ("bp-log", "bp", {
            "bp": {"op": "log", "doc": {
                "title": "smoke: run events",
                "size": {"width": 800, "height": 320},
                "events": [
                    {"t": "00:00:01", "kind": "start", "label": "run started", "pos": 1},
                    {"t": "00:00:09", "kind": "read", "label": "source.png -> 12 colours"},
                    {"t": "00:00:31", "kind": "write", "label": "3 candidates traced", "pos": 3},
                    {"t": "00:00:34", "kind": "gate", "label": "Layer A: pass", "pos": 4},
                    {"t": "00:00:35", "kind": "gate", "label": "Layer B: 3 advisories", "pos": 5},
                    {"t": "00:00:36", "kind": "end", "label": "run complete", "pos": 6}
                ]}}
        }),

        # 7. bp blender: the 3D render. CPU, slower than the five above, and
        #    the ONLY op that renders rather than draws -- so it is the one that
        #    proves the blend half is wired at all. views 1 and the cheap
        #    workbench engine, because a four-view 1024px Eevee render is
        #    minutes of CPU for a test that only needs an answer.
        ("bp-blender", "bp", {
            "bp": {"op": "blender", "doc": {
                "title": "smoke: tray",
                "elements": [
                    {"type": "rect", "x": 0, "y": 0, "width": 300, "height": 200,
                     "fill": "#e04030"},
                    {"type": "circle", "cx": 430, "cy": 100, "r": 90, "fill": "#3080e0"},
                    {"type": "polyline", "points": [[0, 260], [200, 340], [400, 260]],
                     "stroke": "#20c060", "stroke_width": 6}
                ],
                "render": {
                    "size": {"width": 480, "height": 360},
                    "views": 1,
                    "background": "#1a1a24",
                    "engine": "workbench"
                }}}
        }),

        # 8. The generator: one small raster. The GPU run, and it lives on
        #    another host — so it is LAST, and nothing depends on it. Measured
        #    on this box: the card is SHARED, and another tenant (an LM Studio
        #    llama-server holding 14.7 GB of the 17.1 GB) makes this step fail
        #    with a CUDA OOM while every other step is green. A smoke test has
        #    to report that as ONE failed step, not as a broken run, which is
        #    why nothing above consumes its output and why `--skip flux` exists.
        ("flux", "flux", {
            "flux": {
                "prompt": "a single woodcut circle, flat two-colour print",
                "mode": "raster",
                "model": "klein-4b",
                "width": 512, "height": 512,
                "images": 1
            }
        }),
    ]


# --------------------------------------------------------------------------
# the HTTP session
# --------------------------------------------------------------------------

class Studio:
    def __init__(self, base):
        self.base = base
        policy = http.cookiejar.DefaultCookiePolicy()
        # The studio sets assume_ssl + a `secure` session cookie, so a loopback
        # client has to be allowed to carry that cookie over http. Without this
        # every request comes back anonymous and every POST is a redirect to
        # /login.
        policy.secure_protocols = ("https", "wss", "socks", "http")
        self.jar = http.cookiejar.CookieJar(policy)
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar), NoRedirect())
        self.opener.addheaders = [
            ("User-Agent",
             "Mozilla/5.0 (X11; Linux x86_64) Chrome/149.0.0.0 Safari/537.36")
        ]

    def get(self, path, **kw):
        return self.opener.open(self.base + path, **kw)

    def body(self, path):
        return self.get(path).read().decode("utf-8", "replace")

    def token(self, path="/login"):
        page = self.body(path)
        m = re.search(r'name="csrf-token" content="([^"]+)"', page)
        if not m:
            raise RuntimeError(f"no csrf-token on {path}")
        return m.group(1)

    def login(self, password):
        tok = self.token("/login")
        data = urllib.parse.urlencode({"password": password}).encode()
        try:
            self.opener.open(urllib.request.Request(
                self.base + "/login", data=data,
                headers={"X-CSRF-Token": tok}))
        except urllib.error.HTTPError as e:
            if e.code in (301, 302, 303):
                pass  # the success case
            else:
                raise RuntimeError(f"login failed: HTTP {e.code}")
        # A session that did not take is a 200 login page, not an error, so the
        # check is what the POST-LOGIN HOME answers rather than what /login did.
        # GET / is the projects index (routes.rb: root "projects#index"): it
        # answers 200 when signed in and redirects to /login when it is not.
        # NoRedirect makes that redirect an HTTPError(302) rather than a follow,
        # so the URL it carries is the answer. /jobs is deliberately NOT used:
        # the global jobs index is gone (the Projects redesign moved it under
        # each project) and GET /jobs answers 404, which is what killed this
        # check.
        try:
            home = self.get("/")
            landed = home.geturl()
        except urllib.error.HTTPError as e:
            landed = e.headers.get("Location", "")
        if "/login" in landed:
            raise RuntimeError("login did not take — wrong password?")

    def post_json(self, path, fields):
        """POST form fields, return (status, Location, body)."""
        tok = self.token()
        data = urllib.parse.urlencode(fields, doseq=True).encode()
        try:
            r = self.opener.open(urllib.request.Request(
                self.base + path, data=data,
                headers={"X-CSRF-Token": tok, "Accept": "text/html"}))
            return r.status, r.headers.get("Location"), r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.headers.get("Location"), e.read().decode("utf-8", "replace")

    def delete(self, path):
        """DELETE, as the app's own jobs index does it (form-style _method)."""
        tok = self.token()
        data = urllib.parse.urlencode({"_method": "delete"}).encode()
        try:
            r = self.opener.open(urllib.request.Request(
                self.base + path, data=data,
                headers={"X-CSRF-Token": tok, "Accept": "text/html"}))
            return r.status
        except urllib.error.HTTPError as e:
            return e.code

    def upload(self, png_bytes):
        import uuid
        boundary = "----hermes" + uuid.uuid4().hex
        parts = [
            f"--{boundary}\r\n".encode(),
            b'Content-Disposition: form-data; name="file"; filename="smoke.png"\r\n',
            b"Content-Type: image/png\r\n\r\n",
            png_bytes,
            f"\r\n--{boundary}--\r\n".encode(),
        ]
        body = b"".join(parts)
        req = urllib.request.Request(
            self.base + "/jobs/upload", data=body,
            headers={"X-CSRF-Token": self.token(), "Content-Type":
                     f"multipart/form-data; boundary={boundary}",
                     "Accept": "application/json"})
        r = self.opener.open(req)
        return json.loads(r.read().decode())

    def submit(self, name, runner, source_kind, input_path, spec):
        status, location, body = self.post_json("/jobs", {
            "job[name]": name,
            "job[source_kind]": source_kind,
            "job[input_path]": input_path or "",
            "job[runner]": runner,
            "job[spec]": json.dumps(spec),
        })
        if status not in (200, 302) or not location:
            # The refusal is the model's own message rendered as the page's
            # flash (`flash.now[:alert]`), so lift THAT rather than reporting a
            # bare status -- it names the step index and the remedy. Falling
            # back to the stripped body only when no flash is present (a 500 or
            # a redirect chain) keeps a real error visible either way.
            m = re.search(r'class="flash alert"[^>]*>(.*?)</div>', body, re.S)
            if m:
                hint = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", m.group(1))).strip()
            else:
                hint = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", body)).strip()[:300]
            raise RuntimeError(f"submit refused: HTTP {status} {location} {hint}")
        m = re.search(r"/jobs/(\d+)", location)
        if not m:
            raise RuntimeError(f"no job id in Location: {location}")
        return int(m.group(1))

    def state(self, job_id):
        """(state, error) for one job, read off the job page's own markup.

        The JSON branch carries only `done` and a log tail, so the STATE and any
        error message are read from the served page — which is also the branch
        the operator looks at, so a smoke test that reads it is testing what
        they see.

        Two pieces of markup, both verified against the served pages:
        `job-state">· <state>` for the state, and the job page's
        `<div class="flash alert mono">` for the failure reason. A refusal at
        CREATE time renders the same flash WITHOUT `mono` (the form's own
        alert), which is why the refusal path matches the shorter class.
        """
        page = self.body(f"/jobs/{job_id}")
        m = re.search(r'job-state">\s*·\s*([a-z]+)', page)
        state = m.group(1) if m else "unknown"
        err = re.search(r'class="flash alert mono"[^>]*>(.*?)</div>', page, re.S)
        return state, (re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", err.group(1))).strip()
                       if err else None)

    def steps_table(self, job_id):
        """Per-step (number, state) off the job page's process table.

        A chained job answers ONE state for the whole run; the per-step ledger
        is what says WHICH step failed, so a red pass names it instead of
        leaving the operator to open the page. The rows are
        `<tr data-step="N" data-state="...">` — the machine-readable pair the
        page's own CSS keys off — not the styled span inside them.
        """
        page = self.body(f"/jobs/{job_id}")
        return [(int(n), s) for n, s in
                re.findall(r'data-step="(\d+)" data-state="([a-z]+)"', page)]

    def wait(self, job_id, timeout=JOB_TIMEOUT):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            state, err = self.state(job_id)
            if state != last:
                print(f"      {state}" + (f" — {err}" if err else ""), flush=True)
                last = state
            if state in ("done", "error", "cancelled"):
                return state, err
            time.sleep(POLL_INTERVAL)
        return "timeout", None

    def projects(self):
        """This account's project workspaces, as a de-duplicated list of ids.

        The jobs index is PER-PROJECT since the Projects redesign: there is no
        global GET /jobs any more (routes.rb lists jobs under their project),
        so the list of workspaces is read off the projects index and each one's
        own page is read separately. The anchor is the project row's own
        `data-href="/projects/<id>"`.
        """
        page = self.body("/")
        seen = []
        for pid in re.findall(
                r'<tr class="rowlink" data-href="/projects/(\d+)"', page):
            pid = int(pid)
            if pid not in seen:
                seen.append(pid)
        return seen

    def _job_rows(self):
        """Every job row this account can see, across its project workspaces.

        Yields (job_id, row_html). The anchor is the row partial's own
        `data-href="/jobs/<id>"` -- the same markup the old global jobs index
        rendered; only the page it is read from changed.
        """
        for pid in self.projects():
            page = self.body(f"/projects/{pid}")
            for job_id, row in re.findall(
                    r'<tr class="rowlink" data-href="/jobs/(\d+)"[^>]*>(.*?)</tr>',
                    page, re.S):
                yield int(job_id), row

    def runs(self):
        """This account's smoke runs, newest first: {run_id: [job_id, ...]}.

        Read across the project workspaces the signed-in user can see, so the
        scope is the app's own per-user scoping rather than a query this script
        writes; only names this script filed (`RUN_PREFIX`) are considered.

        ROW-SCOPED, and there is deliberately NO "if that matched nothing, try
        something looser" fallback: an earlier version paired the page's job ids
        with the page's run ids by document order, which is not a pairing at all
        -- every job is rendered TWICE (a row and a grid card) and the two lists
        have different lengths, so it deleted a scatter of unrelated rows in this
        account (56 delete attempts, most already gone) instead of the runs it
        named. A prune keyed off a wrong pairing is worse than a prune that
        refuses, so a page whose rows do not parse prunes NOTHING. The anchor is
        the row partial's own `data-href="/jobs/<id>"`, and the name is read out
        of THAT row.
        """
        found = {}
        for job_id, row in self._job_rows():
            m = re.search(re.escape(RUN_PREFIX) + r'(\d{8}-\d{6})', row)
            if m:
                found.setdefault(m.group(1), []).append(job_id)
        return found

    def legacy_runs(self):
        """This account's jobs from the PRE-2026-09-29 naming, run-scoped.

        The script used to file one job per step named `<step>-<stamp>` (and an
        earlier demo filed `demo-<stamp>-<kind>`), so those sets have no `smoke-`
        prefix to key a prune off and `--keep` cannot see them. They are still
        this script's own rows in the test account, so `--prune-legacy` collects
        them by the old plan's names, again ROW-SCOPED, and never touches anything
        whose name is not one of those shapes.
        """
        shapes = (r'bp-(?:geometry|digest|query|tree|log|blender)-\d{8}-\d{4}|'
                  r'(?:trace|flux)-\d{8}-\d{4}|'
                  r'demo-\d{6}-(?:bp|trace|flux)')
        found = {}
        for job_id, row in self._job_rows():
            m = re.search(r'(' + shapes + r')', row)
            if m:
                found.setdefault(m.group(1), []).append(job_id)
        return found


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


# --------------------------------------------------------------------------
# a source raster, made here
# --------------------------------------------------------------------------

def make_source_png(width=SOURCE_PNG_W, height=SOURCE_PNG_H):
    """A small PNG built in pure python: four colour quadrants.

    A sweep wants EDGES, and a quadrant boundary is the cheapest edge there is.
    Written by hand rather than pulled from disk so the script has no binary
    dependency and nothing to upload-but-forget.
    """
    import struct
    import zlib

    quads = [(0xF8, 0xFA, 0xFC), (0x63, 0x66, 0xF1),
             (0x22, 0xD3, 0xEE), (0xF4, 0x72, 0xB6)]

    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0 for every scanline
        for x in range(width):
            q = (0 if y < height // 2 else 2) + (0 if x < width // 2 else 1)
            raw.extend(quads[q])

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) +
            chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


# --------------------------------------------------------------------------
# the password, the pass, and cleaning up after earlier passes
# --------------------------------------------------------------------------

def read_password(args):
    if args.password_file:
        with open(args.password_file) as f:
            return f.read().strip()
    if os.environ.get("CHOPSHOP_SMOKE_PASSWORD"):
        return os.environ["CHOPSHOP_SMOKE_PASSWORD"].strip()
    if not sys.stdin.isatty():
        line = sys.stdin.readline().strip()
        if line:
            return line
    # The operator's Hermes env file. Rule 1 permits an expanduser-based default for
    # the operator's Hermes home; HERMES_ENV_FILE overrides it.
    env = os.path.expanduser(os.environ.get("HERMES_ENV_FILE") or "~/.hermes/.env")
    if os.path.exists(env):
        with open(env) as f:
            for line in f:
                if line.startswith("CHOPSHOP_DISPOSABLE_ACCOUNT_SECRET="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit(
        "no password: pass --password-file, set CHOPSHOP_SMOKE_PASSWORD, pipe it "
        "on stdin, or put CHOPSHOP_DISPOSABLE_ACCOUNT_SECRET in the Hermes env file")


def prune(studio, keep, current_run, dry=False):
    """Delete this account's smoke runs beyond the newest `keep`, oldest first.

    Scope is the SIGNED-IN account (the app scopes the index per user) plus the
    `smoke-` name prefix, so no other user's job and no hand-filed job in this
    account is reachable. The current run is never a candidate. `dry=True` prints
    the plan and deletes nothing — the only honest way to show what a prune would
    do before it does it.
    """
    runs = studio.runs()
    order = sorted(runs, reverse=True)
    doomed = [r for r in order[keep:] if r != current_run]
    if not doomed:
        print(f"prune: {len(order)} run(s) held, keep={keep}, nothing to delete",
              flush=True)
        return []
    deleted = []
    for run_id in doomed:
        ids = sorted(runs[run_id])
        print(f"prune: run {run_id} -> {len(ids)} job(s) {ids}"
              + ("  [dry run, nothing deleted]" if dry else ""), flush=True)
        if dry:
            continue
        for job_id in ids:
            status = studio.delete(f"/jobs/{job_id}")
            if status in (200, 302):
                deleted.append((run_id, job_id))
            else:
                print(f"prune:   job {job_id} -> HTTP {status} (left alone)", flush=True)
    return deleted


def prune_legacy(studio, dry=False):
    """Delete this account's jobs filed under the PRE-2026-09-29 naming.

    A one-off tidy-up for the rows the old one-job-per-step script left behind;
    kept because a fresh pass of it is safe (it matches only those name shapes),
    but it is never part of a normal pass -- `--keep` cannot see those rows and
    the cron does not need them gone twice.
    """
    runs = studio.legacy_runs()
    deleted = []
    for run_id in sorted(runs):
        ids = sorted(runs[run_id])
        print(f"prune-legacy: {run_id} -> {len(ids)} job(s) {ids}"
              + ("  [dry run, nothing deleted]" if dry else ""), flush=True)
        if dry:
            continue
        for job_id in ids:
            status = studio.delete(f"/jobs/{job_id}")
            if status in (200, 302):
                deleted.append((run_id, job_id))
            else:
                print(f"prune-legacy:   job {job_id} -> HTTP {status} (left alone)", flush=True)
    return deleted


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--password-file")
    ap.add_argument("--list", action="store_true",
                    help="print the plan and exit; no login, no jobs")
    ap.add_argument("--only", help="substring: run only the matching steps")
    ap.add_argument("--skip", action="append", default=[], metavar="SUBSTR",
                    help="substring: drop matching steps (repeatable) — use it "
                         "when one step's dependency is known to be busy, e.g. "
                         "--skip flux while another tenant holds the GPU")
    ap.add_argument("--dry-run", action="store_true",
                    help="log in and report, but file nothing")
    ap.add_argument("--individual", action="store_true",
                    help="file one job per step instead of one chained job "
                         "(same run id on every job)")
    ap.add_argument("--run-id", help="override the run id (default: now, seconds)")
    ap.add_argument("--keep", type=int, default=0,
                    help="after the pass, keep only the newest N smoke runs of "
                         "this account (0 = keep everything, the default)")
    ap.add_argument("--prune-only", action="store_true",
                    help="prune old runs against --keep and exit; file nothing")
    ap.add_argument("--prune-legacy", action="store_true",
                    help="delete this account's jobs from the PRE-run-id naming "
                         "(<step>-<stamp>) and exit; combine with --dry-run to "
                         "see the list first")
    args = ap.parse_args()

    plan = build_plan()
    if args.only:
        plan = [p for p in plan if args.only in p[0]]
        if not plan:
            print(f"--only {args.only!r} matched no step", file=sys.stderr)
            return 2
    for drop in args.skip:
        kept = [p for p in plan if drop not in p[0]]
        if len(kept) == len(plan):
            print(f"--skip {drop!r} matched no step", file=sys.stderr)
            return 2
        plan = kept
    if not plan:
        print("every step was filtered out", file=sys.stderr)
        return 2

    if args.list:
        mode = "individual" if args.individual else "one job, %d steps" % len(plan)
        for name, runner, spec in plan:
            kind = spec.get("bp", {}).get("op") or next(
                (k for k in spec if k in ("flux",)), "trace")
            print(f"{name:14s} {runner:5s} {kind}")
        print(f"mode: {mode}")
        return 0

    # ONE run id, taken before anything is filed. Every job this pass creates
    # carries it, so the set survives a minute boundary -- which is exactly what
    # per-submit stamps broke.
    run_id = args.run_id or time.strftime("%Y%m%d-%H%M%S")

    password = read_password(args)
    studio = Studio(BASE)
    studio.login(password)
    print(f"logged in to {BASE}", flush=True)

    if args.prune_only:
        deleted = prune(studio, max(args.keep, 1), current_run=None, dry=args.dry_run)
        print(f"prune: {len(deleted)} job(s) deleted"
              + ("  [dry run]" if args.dry_run else ""))
        return 0

    if args.prune_legacy:
        deleted = prune_legacy(studio, dry=args.dry_run)
        print(f"prune-legacy: {len(deleted)} job(s) deleted"
              + ("  [dry run]" if args.dry_run else ""))
        return 0

    # The ONE upload, done once and reused by every step that needs an artwork
    # -- a second upload would be a second file in storage/uploads for no
    # reason. The trace step is what needs it, in BOTH modes, since the trace
    # is the first step of the chain and takes the JOB's own artwork.
    needs_source = any(name == "trace" for name, _, _ in plan)
    source_path = None
    if needs_source and not args.dry_run:
        up = studio.upload(make_source_png())
        source_path = up["path"]
        print(f"  uploaded source -> {source_path}", flush=True)

    if args.dry_run:
        for name, runner, _ in plan:
            print(f"  [dry] {name} ({runner})")
        print(f"  [dry] run id {run_id}, mode "
              f"{'individual' if args.individual else 'one job'}")
        return 0

    filed = []       # (label, job_id)
    failures = []

    if args.individual:
        for name, runner, spec in plan:
            stamped = f"{RUN_PREFIX}{run_id}/{name}"
            print(f"  filing {stamped} on {runner}", flush=True)
            try:
                # A single-action job reads its kind's own block, and `input`
                # is a STEP key -- strip it so the standalone validators see
                # the document they expect.
                job_id = studio.submit(stamped, runner, "raster",
                                       source_path if name == "trace" else "", spec)
            except Exception as e:
                print(f"    REFUSED: {e}", flush=True)
                failures.append((name, str(e)))
                continue
            filed.append((name, job_id))
            print(f"    job {job_id}", flush=True)
            state, err = studio.wait(job_id)
            print(f"    -> {state}" + (f" ({err})" if err else ""), flush=True)
            if state != "done":
                failures.append((name, f"{state}: {err or 'no error message'}"))
    else:
        # ONE job, the whole set as ordered steps. The hand-off declaration
        # sits BESIDE the runner label (never inside the kind's block, which is
        # the service's document and is posted to it untouched).
        steps = []
        for name, runner, spec in plan:
            step = {"runner": runner}
            if name == "trace":
                # The trace takes the JOB's own artwork — the raster the script
                # uploaded — which is only legal because the trace is STEP 1:
                # `step_takes_previous?` counts only "previous" or a blank
                # input as a hand-off, so a LATER trace step is validated
                # against the step above it and `input: "job"` is refused there
                # with a message about that step's extension. Keeping the trace
                # first is what makes every other step droppable with --skip.
                step["input"] = "job"
            step.update(spec)
            steps.append(step)

        stamped = f"{RUN_PREFIX}{run_id}"
        print(f"  filing {stamped} — one job, {len(steps)} steps", flush=True)
        try:
            job_id = studio.submit(stamped, steps[0]["runner"], "raster",
                                   source_path or "", {"steps": steps})
        except Exception as e:
            print(f"    REFUSED: {e}", flush=True)
            return 1
        filed.append(("<chain>", job_id))
        print(f"    job {job_id}", flush=True)
        state, err = studio.wait(job_id)
        print(f"    -> {state}" + (f" ({err})" if err else ""), flush=True)
        if state != "done":
            failures.append(("chain", f"{state}: {err or 'no error message'}"))
        per_step = studio.steps_table(job_id)
        if per_step:
            print("    steps: " + " ".join(f"{n}:{s}" for n, s in per_step), flush=True)
            bad = [(n, s) for n, s in per_step if s != "done"]
            if bad:
                failures.append(("steps", "; ".join(f"step {n} {s}" for n, s in bad)))

    print()
    print(f"run {RUN_PREFIX}{run_id}: {len(filed)} job(s) — " +
          ", ".join(f"{label}={jid}" for label, jid in filed))

    if args.keep > 0:
        prune(studio, args.keep, current_run=run_id)

    if failures:
        print(f"smoke: {len(plan) - len(failures)}/{len(plan)} ok, "
              f"{len(failures)} not done:")
        for name, why in failures:
            print(f"  - {name}: {why}")
        return 1
    print(f"smoke: all {len(plan)} ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
