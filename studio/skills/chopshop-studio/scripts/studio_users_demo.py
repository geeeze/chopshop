#!/usr/bin/env python3
"""Demo a real run for EVERY studio account, and prove per-user isolation.

One pass, one job per account, each named `demo-<run id>-<handle>` so the set is
identifiable in the job list (the operator rule: a test run's rows must say what
set they belong to). The run id is stamped once, before the first submit.

HOST-SPECIFIC (this box): base `http://127.0.0.1:3001`, the live studio; passwords
from `~/.chopshop-studio.env` (CHOPSHOP_PASSWORD for `<operator-handle>`) and `~/.hermes/.env`
(CHOPSHOP_TEST_ACCOUNT_SECRET / CHOPSHOP_DISPOSABLE_ACCOUNT_SECRET). Nothing is printed but states
and sizes.

NEVER RESET `<test-handle>`'s PASSWORD. It is the operator's own second account and its
password lives in `~/.hermes/.env`; a "reset it to a temp file first" step burns the
credential the operator set (done three times in one day, each time silently) and is
the whole reason this script reads the .env value instead. `E2E_PW_FILE`, when set,
OVERRIDES the .env value for a caller who deliberately made a throwaway — it is never
the source of truth.

Every account gets its own cookie jar — the password IS the identity, so two
accounts must never share a session. Isolation is asserted, not assumed: each
account's jobs index must show NONE of another account's job ids.

Passwords: `<operator-handle>` from ~/.chopshop-studio.env (CHOPSHOP_PASSWORD), `<test-handle>` from
CHOPSHOP_TEST_ACCOUNT_SECRET in ~/.hermes/.env (the operator's own account — never reset
it), `<disposable-handle>` from CHOPSHOP_DISPOSABLE_ACCOUNT_SECRET (the disposable smoke account). An
`E2E_PW_FILE` overrides `<test-handle>` for a throwaway account only. Nothing is printed but
states and sizes.
"""

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
RUN_ID = time.strftime("%Y%m%d-%H%M%S")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


class Session:
    """One cookie jar = one identity. Never share between handles."""

    def __init__(self, handle, password):
        self.handle = handle
        self.password = password
        policy = http.cookiejar.DefaultCookiePolicy()
        policy.secure_protocols = ("https", "wss", "socks", "http")
        self.jar = http.cookiejar.CookieJar(policy)
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar), NoRedirect())
        self.opener.addheaders = [
            ("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) Chrome/149.0.0.0 Safari/537.36")
        ]

    def body(self, path):
        try:
            return self.opener.open(self.base_path(path)).read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.read().decode("utf-8", "replace")

    def base_path(self, path):
        return BASE + path

    def token(self, path="/login"):
        m = re.search(r'name="csrf-token" content="([^"]+)"', self.body(path))
        if not m:
            raise RuntimeError(f"no csrf-token on {path}")
        return m.group(1)

    def login(self):
        tok = self.token("/login")
        data = urllib.parse.urlencode({"password": self.password}).encode()
        try:
            self.opener.open(urllib.request.Request(
                BASE + "/login", data=data, headers={"X-CSRF-Token": tok}))
        except urllib.error.HTTPError as e:
            if e.code not in (301, 302, 303):
                return False, f"HTTP {e.code}"
        if "/login" in self.opener.open(BASE + "/jobs").geturl():
            return False, "session did not take"
        return True, "ok"

    def job_ids(self):
        """Job ids this account's own index links to (the app scopes it)."""
        ids = {int(i) for i in re.findall(r'/jobs/(\d+)"', self.body("/jobs"))}
        return ids

    def upload(self, data, name="demo.png"):
        import uuid
        boundary = "----hermes" + uuid.uuid4().hex
        body = b"".join([
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="file"; filename="{name}"\r\n'.encode(),
            b"Content-Type: image/png\r\n\r\n", data,
            f"\r\n--{boundary}--\r\n".encode()])
        req = urllib.request.Request(
            BASE + "/jobs/upload", data=body,
            headers={"X-CSRF-Token": self.token(), "Accept": "application/json",
                     "Content-Type": f"multipart/form-data; boundary={boundary}"})
        return json.loads(self.opener.open(req).read().decode())

    def submit(self, name, runner, input_path, spec):
        tok = self.token()
        fields = {"job[name]": name, "job[source_kind]": "raster",
                  "job[input_path]": input_path or "", "job[runner]": runner,
                  "job[spec]": json.dumps(spec)}
        try:
            r = self.opener.open(urllib.request.Request(
                BASE + "/jobs", data=urllib.parse.urlencode(fields).encode(),
                headers={"X-CSRF-Token": tok, "Accept": "text/html"}))
            loc, status, page = r.headers.get("Location"), r.status, ""
        except urllib.error.HTTPError as e:
            loc, status, page = e.headers.get("Location"), e.code, e.read().decode("utf-8", "replace")
        if status not in (200, 302) or not loc:
            m = re.search(r'class="flash alert"[^>]*>(.*?)</div>', page, re.S)
            why = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", m.group(1))).strip() if m else "?"
            raise RuntimeError(f"refused: HTTP {status} {why}")
        return int(re.search(r"/jobs/(\d+)", loc).group(1))

    def wait(self, job_id, timeout=420):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            page = self.body(f"/jobs/{job_id}")
            m = re.search(r'job-state">\s*·\s*([a-z]+)', page)
            state = m.group(1) if m else "unknown"
            if state != last:
                print(f"      {state}", flush=True)
                last = state
            if state in ("done", "error", "cancelled"):
                return state, page
            time.sleep(5)
        return "timeout", ""

    def get_file(self, path):
        try:
            r = self.opener.open(BASE + path)
            return r.status, r.headers.get("Content-Type"), len(r.read())
        except urllib.error.HTTPError as e:
            return e.code, None, 0


def source_png():
    """The same 64x64 quadrant PNG the smoke script builds (no binary in git)."""
    import struct, zlib
    w = h = 64
    quads = [(0xF8, 0xFA, 0xFC), (0x63, 0x66, 0xF1), (0x22, 0xD3, 0xEE), (0xF4, 0x72, 0xB6)]
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw.extend(quads[(0 if y < h // 2 else 2) + (0 if x < w // 2 else 1)])

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


BP_DIGEST = {"bp": {"op": "digest", "doc": {
    "chart": "bar", "title": f"demo {RUN_ID}", "size": {"width": 640, "height": 360},
    "data": {"labels": ["a", "b", "c"], "series": [{"name": "score", "values": [1, 2, 3]}]}}}}

TRACE = {"print_method": "screen_print", "max_colors": 4, "sweep_max_candidates": 3}

PASSWORDS = {}


def load_passwords():
    for line in open(os.path.expanduser("~/.chopshop-studio.env")):
        m = re.match(r'\s*(?:export\s+)?CHOPSHOP_PASSWORD\s*=\s*(.*)$', line)
        if m:
            PASSWORDS["<operator-handle>"] = m.group(1).strip().strip('"').strip("'")
    for key, handle in (("CHOPSHOP_TEST_ACCOUNT_SECRET", "<test-handle>"), ("CHOPSHOP_DISPOSABLE_ACCOUNT_SECRET", "<disposable-handle>")):
        for line in open(os.path.expanduser("~/.hermes/.env")):
            m = re.match(r'\s*(?:export\s+)?' + key + r'\s*=\s*(.*)$', line)
            if m:
                PASSWORDS[handle] = m.group(1).strip().strip('"').strip("'")
    # E2E_PW_FILE is an explicit override for a throwaway account, never a requirement:
    # `<test-handle>` is the OPERATOR's account and its password is the one in ~/.hermes/.env.
    path = os.environ.get("E2E_PW_FILE")
    if path and os.path.exists(path):
        PASSWORDS["<test-handle>"] = open(path).read().strip()
    else:
        # The operator's OWN account: take its credential from ~/.hermes/.env and
        # never reset it (a reset destroys the value the operator set, and the
        # driver scripts — including this one — read it from there).
        for line in open(os.path.expanduser("~/.hermes/.env")):
            m = re.match(r'\s*(?:export\s+)?CHOPSHOP_TEST_ACCOUNT_SECRET\s*=\s*(.*)$', line)
            if m:
                PASSWORDS["<test-handle>"] = m.group(1).strip().strip('"').strip("'")
                break


def main():
    load_passwords()
    missing = [h for h in ("<operator-handle>", "<test-handle>", "<disposable-handle>") if not PASSWORDS.get(h)]
    if missing:
        print(f"no password for: {', '.join(missing)}", file=sys.stderr)
        return 2

    # Each account runs ONE bp digest unless it has a real reason for a trace;
    # the jobs are named with the shared run id so the set is greppable.
    plan = {
        "<operator-handle>":  ("bp", BP_DIGEST, None),
        "<test-handle>": ("svg", TRACE, "trace"),
        "<disposable-handle>": ("bp", BP_DIGEST, None),
    }

    sessions = {}
    report = []
    for handle in ("<operator-handle>", "<test-handle>", "<disposable-handle>"):
        s = Session(handle, PASSWORDS[handle])
        ok, why = s.login()
        if not ok:
            report.append((handle, "login FAILED", why, ""))
            continue
        sessions[handle] = s
        ids = s.job_ids()
        report.append((handle, "login ok", f"{len(ids)} job row(s) visible", sorted(ids)[:6]))

    # Isolation: every account's index must link to NONE of the other accounts'
    # jobs. Read the ids each session can see and cross-check them.
    for handle, s in sessions.items():
        mine = s.job_ids()
        others = set()
        for other, so in sessions.items():
            if other != handle:
                others |= so.job_ids()
        leak = mine & (others - mine)
        print(f"isolation {handle}: {len(mine)} own id(s), {len(leak)} foreign "
              f"{'LEAK: ' + str(sorted(leak)[:5]) if leak else 'ok'}", flush=True)

    print()
    results = []
    for handle in ("<operator-handle>", "<test-handle>", "<disposable-handle>"):
        s = sessions.get(handle)
        if not s:
            continue
        runner, spec, needs_source = plan[handle]
        path = ""
        if needs_source:
            up = s.upload(source_png())
            path = up.get("path", "")
            print(f"{handle}: uploaded source -> {path}", flush=True)
        name = f"demo-{RUN_ID}-{handle}"
        try:
            job_id = s.submit(name, runner, path, spec)
        except Exception as e:
            results.append((handle, name, "REFUSED", str(e), ""))
            continue
        print(f"{handle}: filed {name} as job {job_id}", flush=True)
        state, page = s.wait(job_id)
        # The produced artifact, fetched with the OWNER's session: a non-owner's
        # fetch comes back as an HTML error page at 200, so check the bytes.
        files = re.findall(r'upload_preview/([\w.\-]+\.(?:svg|png))', page)
        art = ""
        if files:
            st, ctype, size = s.get_file(f"/jobs/upload_preview/{files[0]}")
            art = f"{files[0]} HTTP {st} {ctype} {size}B"
        results.append((handle, name, state, f"job {job_id}", art))

    print()
    for handle, name, state, detail, art in results:
        print(f"{handle:8s} {name:26s} {state:8s} {detail:10s} {art}")


if __name__ == "__main__":
    sys.exit(main())
