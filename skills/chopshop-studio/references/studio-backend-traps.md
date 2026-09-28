> HOST-SPECIFIC — `127.0.0.1:3001` / `:8790`, `~/.chopshop-studio.env`,
> `~/start-chopshop-stack.sh`, the mock runner and the tailscale note are
> THIS deployment. The Rails/Ruby/process traps are generic.

# Studio backend, runner, deploy and tooling traps

The application-side pitfalls that are not layout: the runner contract, uploads,
auth and session, deploy/asset commands, the Rails/Ruby version traps, and process
handling. Front-end and browser-probe rules are in
`layout-and-probe-pitfalls.md` and `headless-layout-probe.md`.

- `RunnerClient` (app/lib): NEVER add a keyword argument to `post` again without converting every
  call site to an explicit braces hash. With a keyword in the signature, a trailing bare
  `key: value` list is parsed as KEYWORDS, the positional `body` arg disappears, and every caller
  raises `ArgumentError (wrong number of arguments (given 1, expected 2))` — which surfaced as a
  500 on Proof/`create_validation` and on job dispatch/`create_job`. One signature change broke two
  call sites silently; braces at the call site are the contract.
- Runner (the real docker runner) keeps its job index in memory only; a container restart 404s
  every `/files/<job>/...` request until jobs are re-indexed from disk (`reindex_jobs()` scans
  `runner-data/jobs/*/` at boot, inserting every dir as `state: "done"` so a restart cannot
  fabricate a queued job). The mock runner is ephemeral by design — its `/tmp/chopshop-mock/` is
  wiped on reboot.
- Source-preview contract: Rails requests `source.png`; the mock runner writes
  it, the docker runner stores the source as `input/<upload>.<ext>`, and
  `artifact_path` falls back to `input/` for `source.png` ONLY — never a
  `name.startswith("source.")` prefix fallback. A prefix fallback serves the
  original upload for DERIVED names too (`source.inverse.png`), so a job with
  no prep twin shows the plain source as its own "inverse twin". Derived names
  resolve via their real prep file (`01_prepped/<stem>.prepped.inverse.png`) or
  return None and the studio tile self-hides (see the img-onerror rule in
  ui-conventions). When verifying the fix, HASH-COMPARE `source.png` against
  `source.inverse.png` (md5/sha) — the old bug served both with HTTP 200 and
  identical bytes, so two 200s is NOT proof the twin is actually inverted.
- Source uploads MUST live under `storage/uploads` (private), never
  `public/uploads` — the latter is served statically with no auth, leaking raw
  source rasters without a session. The runner bind-mount and
  `HOST_UPLOAD_ROOT` both point at `storage/uploads`; keep them in sync.
- `upload_preview/:name` route needs `format: false` (or a dot-friendly
  constraint) or `.png`/`.jpg` is split into the format segment and the action
  404s.
- Nothing in the stack auto-starts at boot: nginx and the Docker real runner (`restart` policy) come back, but production Puma on :3001 and the mock runner on :8790 do not — the public URL then serves 502 from nginx while `tailscale serve` may also report "No serve config". After any reboot run `bash ~/start-chopshop-stack.sh`, then walk the full verification gate instead of reporting the 502 as fixed.
- During outage recovery, finish repair plus live verification before sending a progress or success message. Repeated partial attempts create stale processes and misleading diagnostics.
- The validation row is created `pending` BEFORE the runner call, so any failure in between strands a phantom queued back-half run (no `runner_validation_id`, nothing on the runner side, never executes). Rescue only `RunnerClient::RunnerError` and a stray `ArgumentError` produces a phantom row per retry, which is exactly what "there are jobs queued I didn't start" looked like. The controller now also rescues `StandardError`, marks the row terminal, then re-raises. When asked to clear such a queue: attribute every row from the nginx access log (`sudo -n grep "POST /validations" /var/log/nginx/access.log` — the User-Agent separates the operator's real browser at the Cloudflare IP from local `curl`/`HeadlessChrome` verification, and a log of 500s explains the identical retries), dump the rows to JSON before touching them, then set them `error` (STATES has no `cancelled`; `error` is the terminal state) and confirm `pending`+`running` is 0.
- **Never precompile without `RAILS_ENV=production`.** A bare `bin/rails assets:precompile` succeeds, prints only `Warning: You are precompiling assets in development`, and writes digests the production `.manifest.json` does not point at — so the deploy looks clean and the served page keeps the old CSS. With the env prefix but WITHOUT sourcing `~/.chopshop-studio.env` it fails loudly with `Missing secret_key_base`; that failure is the env file, not a broken app. And an existing `public/assets/.manifest.json` from a development run is itself the reason Rails will not serve changed assets — check the manifest's `application.css` `digested_path` (top-level key, not an `assets` sub-key) against the file you just built before restarting anything.
- An auth-gated page cannot be verified by fetching the page. `curl /json` returns **302** to the login flow, so a green `HTTP 302` plus a grep of the body proves nothing about the layout. For a change to a gated page, verify in two independent places instead: (a) fetch the DIGESTED asset by name and grep the new class/rule out of it (`curl http://127.0.0.1:3001/assets/application-<hash>.css` → 200, new selector present), and (b) render the view offline with `ApplicationController.render` and walk the DOM. Say plainly which of those you ran — do not present a 302 as a page check.
- `bin/rails runner` defaults to `RAILS_ENV=development`, but the app the operator uses is production — `storage/production.sqlite3`, a DIFFERENT database with different jobs. Querying it without the prefix shows a nearly empty world while the GUI lists jobs the runner never heard of, which reads as a contradiction instead of a mistake. Always `RAILS_ENV=production bin/rails runner` for anything about live state, and print `ActiveRecord::Base.connection_db_config.database` to prove which file answered. The `prod` DB is also multi-database (`primary`/`cache`/`queue`).
- Minitest here is 6.x, which DROPPED `minitest/mock` — `Object#stub` does not exist and `require "minitest/mock"` is a LoadError. Stub by hand: save `RunnerClient.method(:create_validation)`, `define_singleton_method` the replacement, `ensure` restores it. Integration controllers also need a modern `User-Agent` header or `allow_browser versions: :modern` returns 406, and the login gate is satisfiable in-test by setting `CHOPSHOP_PASSWORD` then POSTing `login_path` (restore the env var in an `ensure`).
- Stop a service by PID, not `pkill -f <pattern>`: if the pattern string also appears in your own command line, pkill matches the shell itself and SIGTERMs it, leaving the target alive. The same self-match fires inside a WAIT loop (`for i in $(seq 1 40); do pgrep -f 'pytest tests/' >/dev/null || break; ...`) — it matches its OWN command line, never breaks, burns its full budget, and reports "STILL RUNNING" for a suite that finished minutes earlier. Resolve the PID from `ss -ltnp` or a separate `ps -eo pid,args | grep` call, kill by number, then confirm the port is free. Match the interpreter and module you actually mean (`.venv/bin/python -m pytest`), or take the result from the background process's own completion notification rather than polling a pattern you are also typing.
