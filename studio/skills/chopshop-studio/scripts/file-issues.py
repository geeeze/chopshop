#!/usr/bin/env python3
"""File a batch of staged issues to a GitHub repo via `gh`.

WHY IT EXISTS: an issue body is markdown full of backticks, `$`, pipes and quotes,
so it goes to `gh` through `--body-file` and never through an inline `--body "..."`
that the shell would mangle (the issue still files, so the damage is silent).
Staging the batch in a file also makes the whole thing re-runnable after a fix.

INPUT FORMAT — one block per issue, `=== ISSUE` separated:

    === ISSUE
    TITLE: What is wrong, in one line
    LABELS: ready-for-agent
    BODY:
    ## What happened
    ...

LABELS may be comma-separated. Use the exact strings from the target repo's own
triage-label doc rather than inventing a scale.

USAGE
    python3 file-issues.py --repo OWNER/REPO --file issues.md
    python3 file-issues.py --repo OWNER/REPO --file issues.md --dry-run

AFTER RUNNING, verify by listing rather than trusting the create output:
    gh api "repos/OWNER/REPO/issues?state=all&per_page=100" \
      -q '.[] | "#\(.number) [\(.state)] [\(.labels|map(.name)|join(","))] \(.title)"'
A create that exits 0 is not proof the body and labels landed.
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def parse_blocks(text):
    """Return [{title, labels, body}] from the staged-issue format."""
    issues = []
    for block in text.split("=== ISSUE"):
        if not block.strip():
            continue
        title = re.search(r"^TITLE: (.*)$", block, re.M)
        labels = re.search(r"^LABELS: (.*)$", block, re.M)
        if not title or "BODY:" not in block:
            raise SystemExit(f"malformed block (needs TITLE:, LABELS:, BODY:):\n{block[:200]}")
        issues.append({
            "title": title.group(1).strip(),
            "labels": [s.strip() for s in labels.group(1).split(",")] if labels else [],
            "body": block.split("BODY:", 1)[1].strip() + "\n",
        })
    return issues


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", required=True, help="staged issues file")
    ap.add_argument("--repo", required=True, help="OWNER/REPO")
    ap.add_argument("--results", default=None, help="write the filed numbers here as JSON")
    ap.add_argument("--dry-run", action="store_true", help="parse and print, file nothing")
    args = ap.parse_args()

    issues = parse_blocks(Path(args.file).read_text())
    if not issues:
        raise SystemExit("no issue blocks found")

    results = []
    for issue in issues:
        if args.dry_run:
            print(f"DRY  [{','.join(issue['labels'])}]  {issue['title']}")
            continue

        # A temp file, not a shell string: the body reaches gh byte-for-byte.
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as fh:
            fh.write(issue["body"])
            body_path = fh.name

        cmd = ["gh", "issue", "create", "--repo", args.repo,
               "--title", issue["title"], "--body-file", body_path]
        for label in issue["labels"]:
            cmd += ["--label", label]

        proc = subprocess.run(cmd, capture_output=True, text=True)
        url = proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else ""
        m = re.search(r"/(?:issues|pull)/(\d+)$", url)
        number = int(m.group(1)) if m else None

        results.append({"number": number, "title": issue["title"],
                        "labels": issue["labels"], "url": url,
                        "returncode": proc.returncode, "stderr": proc.stderr.strip()[:300]})

        status = f"#{number}" if number else f"FAILED rc={proc.returncode}"
        print(f"{status:>8}  [{','.join(issue['labels'])}]  {issue['title']}")
        if proc.returncode != 0:
            print(f"          err: {proc.stderr.strip()[:200]}")

    if args.dry_run:
        print(f"\nparsed {len(issues)} issues (nothing filed)")
        return 0

    if args.results:
        Path(args.results).write_text(json.dumps(results, indent=2))

    ok = sum(1 for r in results if r["number"])
    print(f"\nfiled {ok}/{len(results)}")
    if ok != len(results):
        print("NEXT: re-check the credential (a fresh grant can land late) and re-run;"
              " then verify by LISTING the repo's issues before reporting.")
    return 0 if ok == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
