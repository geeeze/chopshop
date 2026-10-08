# chopshop-jev — issues (auto-review)

1. .venv + .pytest_cache untracked — add to .gitignore
2. docs/contract.md missing — interface contract file absent; add or link
3. remediation loop steps 3-7 open per docs/remediation-loop.md — --remediate refuses by design; track open steps

Generated from code scan (stdlib-only, gitignore, contract presence). Vendor TODOs excluded.

## Fixed (this pass)
- .gitignore: added __pycache__, .pytest_cache, .venv, .preflight-work
- docs/contract.md: filled with real routes/registry/stages from code

## UX improvement (next)
- DONE: READMEs linked to docs/contract.md
- Link contract.md from AGENTS.md and README
- Add `make` targets or `justfile` for common flows (test, lint, serve)
