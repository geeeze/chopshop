"""Prove the consolidated path: annotator's own request -> gateway -> laya.

    python verify_gateway.py [--gateway http://127.0.0.1:8799]

Uses the REPO'S OWN build_request and projection, so this exercises the real
envelope rather than a hand-written one: if the gateway accepts this, it accepts
what the annotator actually sends.
"""

import argparse
import json
import os
import sys
import urllib.request

REPO = os.path.expanduser("~/repos/chopshop-jev")
sys.path.insert(0, os.path.join(REPO, "scripts"))

import jev_annotate  # noqa: E402


def post(url, payload, headers=None, timeout=120):
    request = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", **(headers or {})},
        method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as exc:  # noqa: F821
        return exc.code, json.loads(exc.read() or b"{}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gateway", default="http://127.0.0.1:8799")
    args = parser.parse_args()

    # A real artifact, projected by the repo's own function.
    artifact = {
        "prompt": "a two-colour woodcut of a fox, high contrast black ink on white",
        "settings": {"seed": 42, "steps": 4, "width": 1024, "height": 1024,
                     "model": "klein-4b"},
        "image": {"file": "flux.png"},
        "measurements": {"colors_present": 2},
    }
    state = jev_annotate.project_artifact(artifact)
    request_body = jev_annotate.build_request(state, "jev-latest")
    print("request: %d question(s) from profile, state evidence: %s"
          % (len(request_body["questions"]),
             json.dumps(state["evidence"], sort_keys=True)))

    status, document = post(args.gateway + "/v1/systemone", request_body,
                            timeout=240)
    print("\nHTTP %s" % status)
    print(json.dumps(document, indent=2, sort_keys=True)[:1800])

    failures = []
    if status != 200:
        failures.append("gateway returned %s" % status)
    answers = document.get("answers") or {}
    routing = document.get("routing") or {}
    if not answers:
        failures.append("no answers came back")
    # Type-aware validation: the three question types answer in three DIFFERENT
    # shapes, so a blanket "does it have a choice" check is wrong. MEASURED from
    # the live service: choice -> {"choice"}, score -> {"score","legend"},
    # noul -> {"noul"} (a calibrated P(true)).
    print("\nper-question:")
    for name, question in request_body["questions"].items():
        kind = question["type"]
        answer = answers.get(name)
        if answer is None:
            failures.append("%s: not answered" % name)
            continue
        if kind == "score":
            score = answer.get("score")
            legend = answer.get("legend")
            ok = (isinstance(score, (int, float))
                  and isinstance(legend, dict) and len(legend) == len(question["criteria"]))
            detail = "score=%r legend_levels=%s" % (
                score, len(legend) if isinstance(legend, dict) else "none")
        elif kind == "noul":
            value = answer.get("noul")
            ok = isinstance(value, (int, float)) and 0.0 <= float(value) <= 1.0
            detail = "noul=%r" % (value,)
        else:
            choice = answer.get("choice")
            ok = choice in question["criteria"]
            detail = "choice=%r confidence=%r" % (choice, answer.get("answer_confidence"))
        print("  %-24s %-6s %s  %s" % (name, kind, "ok " if ok else "BAD", detail))
        if not ok:
            failures.append("%s (%s): %s" % (name, kind, detail))
    if routing.get("backend") != "local":
        failures.append("expected backend 'local', got %r" % routing.get("backend"))
    print("\nanswers: %d   backend: %s   elapsed: %ss"
          % (len(answers), routing.get("backend"),
             routing.get("elapsed_seconds")))
    if failures:
        print("FAIL:")
        for failure in failures:
            print("  - %s" % failure)
        return 1
    print("PASS: /v1/systemone served by the gateway from local laya.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
