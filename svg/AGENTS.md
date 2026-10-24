# chopshop-svg
Repo: chopshop-svg. Stack: Python/JS/Rust (see docs/contract.md). Hard rules: one-way seam (pipeline never calls back), stdlib-first, live deploy = done. Edit contract + tests together; host facts tagged HOST-SPECIFIC. Read full rules before edits.

**English only.** Every file, comment, doc, string and commit message in this repo is English — no CJK characters; a parser that genuinely needs them writes `\uXXXX` escapes, never the literal (see `docs/agents/standards.md`).

**Public repo.** Never commit deployment hostnames, private IPs, VPN names, or machine nicknames, or generation-stack references. A public vendor API base may exist only as an env-first documented fallback (env var read first, literal as fallback, so behavior is unchanged when unset — see `runner.py`'s `JEV_BASE_URL` pattern). `sync-skills` enforces this for every tracked text file (`scan_for_private_names` / `scan_for_non_english`), not just `skills/`.
