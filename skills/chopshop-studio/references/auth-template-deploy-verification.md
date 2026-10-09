## Auth gating, template tests, and AM5 runner verification

Always verify through primary evidence (controller source, routes, live endpoint), never assume from docs or prior sessions.

### Auth gating verification
For any new endpoint (`/datasets/draw`, `/datasets/library`, etc.):
- Controller: assert `before_action :require_login` exists (`datasets_controller.rb` line 34).
- Routes: `config/routes.rb` maps the path to the protected controller (`datasets#index`, `datasets#draw`, `datasets#library`, `datasets#surface`, `datasets#meme-labels`, `post datasets/use`).
- Live: unauthenticated external request returns 403 from upstream (Cloudflare/nginx full-strict → nginx proxy → Rails); the Rails auth redirect (302 to `/login`) only applies when the request reaches Puma. Distinguish upstream 403 from auth failure by checking `log/production.log` (`Started GET` + `Processing by ...Controller#...`) — 200 OK there with 403 externally confirms upstream blocking, not missing auth.
- `pages_controller.rb`: `before_action :require_login, except: []` (every reference page gated). `bug_reports_controller.rb`, `engine_controller.rb`, `validations_controller.rb`, `scrapbooks_controller.rb`, `composites_controller.rb`, `events_controller.rb`, `projects_controller.rb` all enforce it too.
- Never claim a leak based on an unauthenticated external 403 alone — verify the controller first.

### Template and generation test verification
- Controller-level tests cover the form contract (`test/controllers/run_job_template_test.rb`): picker exists, offers every `PipelineConf.template_keys`, names kind/blurb/levers, opens on default (`standard`).
- Template-related tests to exercise: `run_job_template_test.rb`, `bp_job_form_test.rb`, `run_job_layout_test.rb`, `flux_job_test.rb`, `job_dataset_proxy_test.rb`, `datasets_surface_test.rb`, `run_job_name_tooltip_test.rb`.
- Generation (`generate_*`, `bp_op`) relies on external services: verify `CHOPSHOP_RUNNER_*_URL` responds (`curl <url>/health`), verify `laya-rl-agent` endpoint (`localhost:8797/v1/systemone`), and verify the AM5 runner (`<gpu-box>` tailnet IP). Controller test passing does NOT prove the live pipeline runs — only that the contract and form compose correctly.
- `PipelineConf.BOUNDS` is the source of truth for lever bounds; `TEMPLATES` is the subset; `PipelineConf.compose()` produces the spec fragment. A new template must name its `kind` (`svg`/`flux`/`bp`) and expose only existing `BOUNDS` lever names.

### AM5 / remote runner deployment and verification
Runners are env-driven (`CHOPSHOP_RUNNER_<LABEL>_URL` / `_KIND`), not constants. Key durable rules:
- Check current code before acting on handoffs: `grep -n "RUNNERS\s*=" app/models/job.rb` (method, not frozen constant); `grep -oE '^CHOPSHOP_RUNNER_[A-Z0-9_]+_URL=' ~/.chopshop-studio.env`; `git log --oneline -- doc/runner-contract.md`. Handoff symbols may be stale (`RUNNERS` hash vs env method; `doc/` vs `docs/`; controller no longer hardcodes `"mock"`).
- Verify which host owns a port before wiring it: `docker ps --format '{{.Names}}\t{{.Ports}}'` (this host owns `[IP_ADDRESS]:8787`), plus direct `curl <tailnet-ip>:8787/health`. A tailnet IP answering nothing is the signature of a runner never deployed, not a down one.
- `Job::RUNNERS` merges env over `RUNNER_DEFAULTS` (`{"mock"=>...}`). Adding `<gpu-box>` makes it a `bp` kind runner; the new-job form defaults to the first non-mock pipeline (`svg`) runner, so `<gpu-box>` (`bp`) will not become the form default unless the controller is edited or a dropdown is added.
- Deploy to a remote host requires live SSH/network (`<gpu-box>` at tailnet `[IP_ADDRESS]`) and a built/deployed runner at `~/davesnothere`. Without SSH/network access, remote deploy is blocked regardless of local env config.
- Auth token (`RUNNER_TOKEN`) is a shared secret; never commit it, never log it, never include it in chat.
- Never rely on `docker compose restart` for deployed code changes — the image bakes the venv; use `docker compose build && docker compose up -d runner`. A failed build followed by `&& echo BUILD_OK` is a fake deploy (pipe masks exit status); verify image id changed (`docker inspect --format '{{.Image}}'`) and grep for a new symbol.
- A byte-for-byte comparison of outputs is time-dependent when the tool stamps a clock (`date:timestamp` chunk in PNG). Fix the output (`-define png:exclude-chunk=date,time`) not the comparison; `+set date:create +set date:modify` does NOT remove `date:timestamp`. Assert the flag is present per transcoding preset.
