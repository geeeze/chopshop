# chopshop-studio — issues (auto-review)

1. docs/contract.md missing — interface contract file absent; add or link
2. systemd restart step (systemctl --user restart chopshop-rails.service) must be in CONTEXT.md deploy section

Generated from code scan (stdlib-only, gitignore, contract presence). Vendor TODOs excluded.

## Fixed (this pass)
- .gitignore: added __pycache__, .pytest_cache, .venv, .preflight-work
- docs/contract.md: filled with real routes/registry/stages from code

## UX improvement (next)
- DONE: READMEs linked to docs/contract.md
- Link contract.md from AGENTS.md and README
- Add `make` targets or `justfile` for common flows (test, lint, serve)
