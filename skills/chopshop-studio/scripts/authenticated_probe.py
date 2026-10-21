#!/usr/bin/env python3
"""Log in to the studio as a disposable operator and probe URLs over the same
session, with the two loopback login traps baked in.

The traps (see references/studio-backend-traps.md): the session cookie is
`secure`, so a plain-http jar must count http as a secure protocol or the
session silently drops; and the login POST must NOT follow the 302 (assume_ssl
makes its Location an https URL on a plain-http loopback). The password is read
from an env file and never printed or passed on a command line.

Usage:
    python3 authenticated_probe.py /jobs/461/download /audit /audit.json
    python3 authenticated_probe.py --handle <test-handle> /projects/14

Per path it prints: HTTP status, byte count, and whatever fact decides the
question — 7z magic for archives, flash-alert text for redirect landings,
class/markup markers for HTML (edit `classify` to the probe at hand). Paths
that 302 to an https Location are reported as the alert path, not crashed.
"""
import argparse, http.cookiejar, os, re, sys, urllib.error, urllib.parse, urllib.request

BASE = os.environ.get("CHOPSHOP_BASE", "http://127.0.0.1:3001").rstrip("/")
ENV_KEYS = {
    "<test-handle>": ("~/.hermes/.env", "CHOPSHOP_UNODOS2_SECRET"),
    "<disposable-handle>": ("~/.hermes/.env", "CHOPSHOP_UNODOS3_SECRET"),
}
MAGIC_7Z = b"7z\xbc\xaf\x27\x1c"


def read_env_var(path, key):
    for line in open(os.path.expanduser(path)):
        m = re.match(r"\s*(?:export\s+)?" + re.escape(key) + r"\s*=\s*(.*)$", line)
        if m:
            return m.group(1).strip().strip('"').strip("'")
    return None


class _Policy(http.cookiejar.DefaultCookiePolicy):
    def __init__(self):
        super().__init__()
        self.secure_protocols = ("https", "wss", "socks", "http")  # the trap


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def login(handle):
    path, key = ENV_KEYS[handle]
    pw = read_env_var(path, key)
    if not pw:
        sys.exit(f"no {key} in {path} — nothing to prove")
    cj = http.cookiejar.CookieJar(_Policy())
    lo = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj), NoRedirect())
    body = lo.open(BASE + "/login").read().decode("utf-8", "replace")
    m = (re.search(r'name="csrf-token"\s+content="([^"]+)"', body)
         or re.search(r'name="authenticity_token"[^>]*value="([^"]+)"', body))
    req = urllib.request.Request(
        BASE + "/login",
        data=urllib.parse.urlencode(
            {"authenticity_token": m.group(1) if m else "", "password": pw}).encode())
    try:
        status = lo.open(req).status
    except urllib.error.HTTPError as e:
        status = e.code
    if status != 302:
        sys.exit(f"login POST: {status} (302 expected — the credential or the token shape)")
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))


def classify(body):
    """The facts a probe cares about. Edit per probe; keep it read-only."""
    if body[:6] == MAGIC_7Z:
        return f"ARCHIVE 7z magic OK ({len(body)} bytes)"
    txt = body.decode("utf-8", "replace")
    flash = [re.sub(r"\s+", " ", f)[:90]
             for f in re.findall(r'class="flash alert[^"]*">(.*?)</div>', txt)]
    facts = {k: (k in txt) for k in ("csrf-token", "record-head", "cs-job-download-none")}
    return f"html {len(body)} bytes flash={flash[:1]} facts={facts}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--handle", default="<disposable-handle>", choices=sorted(ENV_KEYS))
    ap.add_argument("paths", nargs="+")
    args = ap.parse_args()
    op = login(args.handle)
    print(f"login POST: 302 (as {args.handle})")
    for path in args.paths:
        try:
            r = op.open(BASE + path)
            print(f"{path}: {r.status} {classify(r.read())}")
        except urllib.error.HTTPError as e:
            print(f"{path}: HTTP {e.code}")
        except urllib.error.URLError:
            print(f"{path}: 302 to an https Location (assume_ssl) — a redirect/alert path")


if __name__ == "__main__":
    main()
