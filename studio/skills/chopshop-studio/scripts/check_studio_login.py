#!/usr/bin/env python3
# HOST-SPECIFIC — this box's studio (http://127.0.0.1:3001) and the operator's
# env files. Subject to change; generalize before reuse on another host.
"""Prove a studio account's credential in an env file is the LIVE one.

Answers the recurring incident: "the password is different from what I set and put
in .env". Reads the password from the env file (or a file path), logs in over
loopback HTTP exactly the way the studio expects, and reports the verdict from the
SERVED response — a 302 to / followed by an authenticated page, or a 401. The
password is never printed and never appears on a command line, so it never lands in
`ps` or shell history.

Usage:
    python3 check_studio_login.py                      # <test-handle> / ~/.hermes/.env
    python3 check_studio_login.py --handle <disposable-handle>
    python3 check_studio_login.py --against /tmp/e2e_pw.txt   # a second opinion

The `--against` file is the point when diagnosing a reset: if the env value is
REFUSED while `--against` is ACCEPTED, somebody wrote that second value into the
account, and the fix is to restore the env value — never to "re-reset" the account.

Exit code 0 only when the env value is accepted (and `--against`, if given, is not).
"""

import argparse
import http.cookiejar
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("CHOPSHOP_BASE", "http://127.0.0.1:3001").rstrip("/")
ENV_FILE = os.path.expanduser("~/.hermes/.env")
ENV_KEYS = {
    "<operator-handle>": ("~/.chopshop-studio.env", "CHOPSHOP_PASSWORD"),
    "<test-handle>": (ENV_FILE, "CHOPSHOP_UNODOS2_SECRET"),
    "<disposable-handle>": (ENV_FILE, "CHOPSHOP_UNODOS3_SECRET"),
}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """The studio sets assume_ssl, so a loopback client must NOT follow the
    https redirect — it is the 302 itself that proves the credential."""

    def redirect_request(self, *a, **k):
        return None


class _Policy(http.cookiejar.DefaultCookiePolicy):
    """The session cookie is `secure`; a plain-http loopback client still has to
    send it back, so http must count as a secure protocol here."""

    def __init__(self):
        super().__init__()
        self.secure_protocols = ("https", "wss", "socks", "http")


def read_env_var(path, key):
    path = os.path.expanduser(path)
    if not os.path.exists(path):
        return None
    for line in open(path):
        m = re.match(r"\s*(?:export\s+)?" + re.escape(key) + r"\s*=\s*(.*)$", line)
        if m:
            return m.group(1).strip().strip('"').strip("'")
    return None


def attempt(password):
    """Return (login_status, authed_status_or_None)."""
    cj = http.cookiejar.CookieJar(_Policy())
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(cj), NoRedirect()
    )
    body = opener.open(BASE + "/login").read().decode("utf-8", "replace")
    m = re.search(r'name="csrf-token"\s+content="([^"]+)"', body) or re.search(
        r'name="authenticity_token"[^>]*value="([^"]+)"', body
    )
    token = m.group(1) if m else ""
    req = urllib.request.Request(
        BASE + "/login",
        data=urllib.parse.urlencode(
            {"authenticity_token": token, "password": password}
        ).encode(),
    )
    try:
        status = opener.open(req).status
    except urllib.error.HTTPError as e:
        status = e.code
    if status != 302:
        return status, None
    # An accepted session must then serve an authenticated page — a 302 alone can
    # be a redirect to /login, which proves nothing. Probe /projects: GET /jobs
    # 404s BY DESIGN since the Projects redesign, so a /jobs probe made every
    # successful login report "the password is NOT the env value" (a false alarm
    # whose suggested remedy — restore/reset — must never rest on that evidence).
    follow = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
    try:
        return status, follow.open(BASE + "/projects").status
    except urllib.error.HTTPError as e:
        return status, e.code


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--handle", default="<test-handle>", choices=sorted(ENV_KEYS))
    ap.add_argument("--against", help="a second file whose password should be REFUSED")
    args = ap.parse_args()

    path, key = ENV_KEYS[args.handle]
    password = read_env_var(path, key)
    if not password:
        print(f"no {key} in {path} — nothing to prove", file=sys.stderr)
        return 2

    print(f"login as {args.handle} against {BASE}")
    status, authed = attempt(password)
    print(f"  {key}: {'ACCEPTED (302)' if status == 302 else f'REFUSED (HTTP {status})'}"
          + (f", /projects {authed}" if authed else ""))
    ok = status == 302 and authed == 200

    if args.against:
        other = open(args.against).read().strip() if os.path.exists(args.against) else ""
        if other:
            s2, _ = attempt(other)
            print(f"  {args.against}: {'ACCEPTED' if s2 == 302 else f'REFUSED (HTTP {s2})'}")
            ok = ok and s2 != 302

    print("RESULT:", "PASS" if ok else "FAIL",
          "— the env credential is the live one" if ok else
          "— the account's password is NOT the env value; restore it, do not re-reset")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
