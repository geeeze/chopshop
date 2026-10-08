# chopshop-bp — issues (auto-review)

1. __pycache__ untracked in working tree — add to .gitignore
2. docs/README.md + CONTEXT.md reference numpy exception without HOST-SPECIFIC tag (contract violation)

Generated from code scan (stdlib-only, gitignore, contract presence). Vendor TODOs excluded.

## Fixed (this pass)
- .gitignore: added __pycache__, .pytest_cache, .venv, .preflight-work
- docs/contract.md: filled with real routes/registry/stages from code

## UX improvement (next)
- DONE: READMEs linked to docs/contract.md
- Link contract.md from AGENTS.md and README
- Add `make` targets or `justfile` for common flows (test, lint, serve)
