> HOST-SPECIFIC — this whole file is THIS deployment: the systemd
> user unit (`chopshop-rails.service`), the `~/.chopshop-studio.env`
> file, the precompile command, this box's ports/hostname, the
> playwright chromium path and the cookie-jar login. The one generic
> principle to keep: verify at every layer (public gateway, origin,
> runtime process, served HTML), because any single check can hide an
> origin error.

# Change, deploy and live verification

> Moved out of `SKILL.md` so the always-on file stays a short router; the rules are unchanged.
>
> Read before any edit that ships (the unit of done is the LIVE page, not the
> edited file).

## The deploy is CONTAINERIZED (the native unit is retired)

The studio runs as `chopshop-studio-studio-1` (compose, 127.0.0.1:3001); the old
`chopshop-rails.service` user unit is gone. So the deploy is a REBUILD, and the
recreate is what picks up new code:

```bash
cd ~/chopshop-studio
docker compose build studio          # long; background it
docker compose rm -sf studio && docker compose create studio && docker start chopshop-studio-studio-1
curl -s -o /dev/null -w 'up=%{http_code}\n' http://127.0.0.1:3001/up
```

(`docker compose up -d` is the obvious form but the agent's terminal guard
refuses it as a long-lived process; `rm -sf` + `create` + `start` is the same
thing.)

**RUN PENDING MIGRATIONS BEFORE THE RECREATE — this is the step that gets
missed, and skipping it 500s the app.** A rebuild bakes in whatever is on the
working tree, including OTHER sessions' landed commits, and a template that
reads a new COLUMN raises `undefined method '<column>' for an instance of Job`
on every page that renders it:

```bash
docker exec chopshop-studio-studio-1 bin/rails db:migrate:status | grep '  down  '
docker exec chopshop-studio-studio-1 bin/rails db:migrate      # before restarting
```

Measured: a rebuild for two unrelated fixes baked in a landed `_prep_bench.html.erb`
whose `@job.prep_expand` reader did not exist on the production DB (the migration
was unapplied), so EVERY job page 500ed. The tell is precise — `undefined method`
for a method that greps as a COLUMN in `db/schema.rb` means the DB, not the code,
is behind. Back the DB up first (`cp -a storage/production.sqlite3`); the
migrations here are additive.

After migrating, **restart** the container so Rails reloads the column
information — a migrated column is not visible to an already-booted process.

## Change and deploy procedure

**The unit of done is the LIVE page, not the edited file.** An edit under `~/chopshop-studio` with a
green test suite and a passing `bin/rails runner` DOM check is a *draft*: the operator is on
production, so until the digest is recompiled and Puma is restarted they are looking at the old
page. Steps 2–3 are not a follow-up task, they are part of the same edit — shipping the layout and
reporting it before deploying is what draws "did you update the live shit". When a request is
visibly about what the operator SEES, do steps 1→2→3→5 with no pause between, then hand back the
live URL. Only an edit you can state is already live gets reported as done.

1. Edit under `~/chopshop-studio`.
2. If CSS/JS changed, precompile (the env file is the source of truth for SECRET_KEY_BASE and the runner URLs, so source it — a bare `RAILS_ENV=production bin/rails assets:precompile` aborts with `Missing secret_key_base`):
   `cd ~/chopshop-studio && set -a && . ~/.chopshop-studio.env && set +a && RAILS_ENV=production bin/rails assets:precompile`
   **Propshaft digests RAW source (+ `config.assets.version`), not compiled output.** A change only a
   COMPILER makes (adding/changing a `config.assets.compilers` entry such as the comment-stripping
   `CommentRedactor`, or tweaking a minifier) leaves every digest unchanged, so far-future-cached
   bundles (`max-age=1.year`) keep serving the old bytes. Bump `config.assets.version` whenever a
   compiler's output changes — it forces all digests to rotate. Verify by reading `.manifest.json`
   digested_paths and confirming they differ from the last deploy; `precompile` exit 0 proves nothing.
   The manifest is also FROZEN AT BOOT: an asset file ADDED after Puma started (even one committed
   directly to disk without any precompile — e.g. by an external agent working in the live checkout)
   is not in the load path, and every page whose layout `stylesheet_link_tag`s it 500s with
   `Propshaft::MissingAssetError` until `systemctl --user restart chopshop-rails.service`. A 500 whose
   log says an asset 'was not found in the load path' while the file clearly exists on disk means:
   check the file's mtime against the service's start time and restart.
2b. **If the branch adds a file under `db/migrate/`, apply it to production BEFORE the restart** — `RAILS_ENV=production bin/rails db:migrate`. The repo carries schema.rb AND migrations in parallel (each migration guarded with `table_exists?`/`column_exists?`), so a DB built fresh from schema.rb already has every column while a live DB that predates a later migration file does not. Skipping this step is how a landed feature 500s everywhere (see the schema-drift pitfall).
3. The live app runs under a systemd USER unit (`chopshop-rails.service`, `Type=simple`, `ExecStart=bin/rails server -b 127.0.0.1 -p 3001`, `EnvironmentFile=~/.chopshop-studio.env`, `Restart=always`). Restart it — do NOT hand-roll a stop/start against the :3001 PID:
   `systemctl --user restart chopshop-rails.service` then `systemctl --user is-active chopshop-rails.service`.
   The mock runner has its own unit: `chopshop-mock-runner.service` (:8790).
4b. The runner map is env-driven (`Job::RUNNERS` defaults to mock-only), so ensure `CHOPSHOP_RUNNER_<LABEL>_URL` is exported before Puma starts or the dropdown shows only "mock". On this box: `CHOPSHOP_RUNNER_SVG_URL=http://127.0.0.1:8787` (keeps the existing "svg" label), `CHOPSHOP_RUNNER_FLUX_URL=http://<tailnet-ip>:8795` + `_KIND=flux`, and `CHOPSHOP_RUNNER_PLOT_URL=http://127.0.0.1:8796` + `_KIND=plot`. The service runs from the **`chopshop-bp`** repo (`~/chopshop-bp`): `python3 cli.py serve --bind 127.0.0.1 --port 8796` (canonical module is `chopshop_plot/server.py` — a `serve.py` also once existed from a duplicate build; `server.py` is the one on origin/main, so grep for `server.py` when checking).

**The repo was renamed `chopshop-plot` → `chopshop-bp` (blend-plot), and the name reaches further than the repo.** It holds SIX operations, not five plus a visitor: `generate`, `digest`, `query`, `tree`, `log` are the **plot** half (they draw documents) and `blender` is the **blend** half (it renders 3D PNG frames / GLB through headless Blender), all one service behind one JSON contract. The rename touches, together, or the next reader finds a dir that no longer exists:
- the local clone **`~/chopshop-bp`** (moved, not copied) and its remote (`https://github.com/geeeze/chopshop-bp.git` — GitHub redirects the old URL, so a stale remote still *works*, which is exactly why it silently rots);
- the systemd USER unit **`chopshop-bp.service`** (`WorkingDirectory` + both `ExecStart` and the `StandardOutput/Error` paths name the directory — a dir move without this edit leaves the unit pointing at a path that is gone, and it only fails on the next restart);
- the service's own `SERVICE_NAME` (`chopshop_plot/config.py`), which is the string `GET /health` reports as `"service"`, plus the tests asserting it;
- the studio's `PlotConf::SERVICE` / `BlenderConf::SERVICE`, its About copy and its page/nav labels.
**Deliberately NOT renamed:** the Python package `chopshop_plot/`, and the Ruby classes `PlotConf` / `BlenderConf`. Both halves are tagged in place with a one-line `blend-plot:` comment instead of being renamed — the operator's call, so a grep for `blend-plot:` finds the seam. **Blender IS installed here** — 4.2.9 LTS as a portable tarball at `~/opt/blender/blender`, wired via `CHOPSHOP_BLENDER_BINARY` in `~/.chopshop-bp.env` (`libegl1` was the one missing system package). A box without it answers 503 by design — an uninstalled renderer is a STATE, not a fault. `start-chopshop-stack.sh` sources `~/.chopshop-studio.env` and exports it (the env file holds the `CHOPSHOP_RUNNER_SVG_URL` line; the `export` list and the Rails command line pass it through). The env file is the source of truth — add a new runner by appending a `CHOPSHOP_RUNNER_<LABEL>_URL` line there and to the `export`, never by editing `Job::RUNNERS`.
5. Complete the live verification gate before reporting success.
6. View/CSS/JS changes need the restart; HTML is not hash-stamped, so recommend a hard refresh only after the served-page assertions pass.
7. For a VISUAL change (font, colour, layout, button), the deliverable is the live URL for the operator to judge in their own browser — deploy, then hand them `https://<public-host>/...` to reload. Screenshots are supplementary, never the headline: an image on a remote box is not "seeing" the change, and reporting screenshots as the result reads as evading the actual deliverable.

**Detect an already-stale live box before trusting a deploy.** The operator is looking at production,
and it is routine for it to sit behind the repo with nobody having noticed: assets precompiled at
16:47, Puma started at 19:51, and two commits landed after both, so the running app serves
`application-9fed90df.css` while the tree holds newer CSS. Compare THREE timestamps before concluding
the live app is current — `git log -3 --format='%h %cI %s'`, the Puma process start (`ps -o
lstart,cmd -p <the :3001 pid>`), and `public/assets/.manifest.json`'s mtime — and confirm the
DIGEST the served page references matches the one in the manifest. A commit whose env-driven runner
(a `CHOPSHOP_RUNNER_<LABEL>_URL` line) is unset on the box is the same class of half-deployed state:
the runner kind exists in code and is unconfigured in production. The 500-shaped face of the same
state: a `NoMethodError` for a method that GREPS as present on disk means the running Puma predates
the commit (new template, old in-memory class) — restart `chopshop-rails.service` and re-verify the
page authenticated (the <disposable-handle> smoke account), because a 302 from the auth gate proves nothing.

## Live verification gate

Use one red/green check at every layer; a public gateway status or `/up` alone can hide an origin error or stale process.

1. Public: `curl -sS -o /dev/null -w '%{http_code}\n' https://<public-host>/` must reach the login flow.
2. Origin: `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3001/` must not return 500.
3. Runtime: inspect the :3001 process and confirm production Puma. `/up` returning 200 only proves some process owns the port.
4. Login using a known user's password (operator `<operator-handle>` — its password is the operator's original regular one, migrated into the table; it also still sits in `~/.chopshop-studio.env` as `CHOPSHOP_PASSWORD`); retain a cookie jar, GET `/login`, take CSRF from `meta[name=csrf-token]`, POST, and follow redirects. For a headless-browser (playwright) login the same user's password is the source — do NOT read the password from `/proc/<puma-pid>/environ`: a service restart changes the PID and the read silently returns empty (it read the dead PID once and every fill failed). The password input is NOT initially visible — it sits in a hidden `#login-gate-holder` until the orb is clicked, so `page.fill('input[name=password]')` times out. Either click `#login-orb-btn` then fill the revealed input, or skip the modal entirely with an in-page `page.evaluate(() => fetch('/login', { method:'POST', headers:{'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content}, body:'password='+pw, credentials:'same-origin' }))` — the fetch keeps the session cookie and needs no orb click.
5. Assert on served authenticated HTML. For runner changes, require the configured runner label(s) (from `CHOPSHOP_RUNNER_*_URL`, not a hardcoded name) and the expected runner-row count. Source grep alone is not deployment proof.
6. For CSS/JS, extract the digested `/assets/application-<hash>.css|js` URL from served HTML and fetch that bundle.

Two layers the curl gate cannot reach — anything interactive (click targets, hover state, focus order,
modals):

7. Drive it in a real browser with `scripts/verify-ui-clicks.js` (launches playwright's chromium over
   CDP, logs in through the real orb→password→submit flow, then probes/clicks by coordinates).
   `.click()` and `elementFromPoint` only report what the DOM says; a dispatchMouseEvent at a real
   coordinate goes through the browser's hit-testing, which is where a whole-frame hit area, an overlay
   z-index mistake, or "the control is behind its own content" actually shows up. Needs no npm install:
   chromium ships at `~/.cache/ms-playwright/chromium-*/chrome-linux64/chrome` and node has a global
   `WebSocket`. The run gets a FRESH chromium profile per run (temp dir); pass `--profile-dir DIR` only
   when you want a cookie to survive between runs. A reused profile keeps a cached `/login` page and a
   stale session cookie, and the first run after a server restart then dies with
   `login was refused — wrong password?` — that is a 422 `InvalidAuthenticityToken` in production.log,
   nothing to do with the password. Probe BEFORE clicking when the action navigates: the script runs
   probes in order, so an eval that reads a modal element listed after a navigating click reports
   `MISSING`, and its "PROBLEMS: N" is counting your argument order, not app bugs.
8. You CAN drive production in a browser — over **https**, which keeps `force_ssl`/`assume_ssl` and therefore the CSRF Origin check happy: point the driver at `https://127.0.0.1` with the cert check disabled (the origin cert is issued for `<public-host>`, so `--ignore-certificate-errors`) — `scripts/verify-ui-clicks.js` takes `--ignore-cert` and also adds that flag automatically for any `https` base, so `--base https://127.0.0.1 --path /json` drives production as-is, and one session can do the served-HTML assertion, the click probe and the JS-state check against the very box the operator uses. This tests the very box the user sees and removes the need for the second server. Plain http is what breaks (`HTTP Origin header … didn't match request.base_url` → 422 `InvalidAuthenticityToken`), not the browser. If a dev server on a spare port is used instead (`RAILS_ENV=development bin/rails server -b 127.0.0.1 -p 3999`, `background=true`), kill the extra listener afterwards and confirm the port is free.
9. `getComputedStyle` on a TRANSITIONED property can return the pre-transition value on the first read: `.cs-viewer .cs-modal-art img` animates `max-height 180ms`, and a read 300ms after the toggle still reported the old 62vh in headless chromium while the settled value is 32vh. Settle-poll instead of sleeping a fixed time (read until the value stops changing), or assert on a non-transitioned property. A red check here is a measurement bug, not the app — confirm with a second read before editing anything.
10. Computed styles cannot prove an effect RENDERS. A `z-index:-1` glow ring is happy in `getComputedStyle` while painted behind an ancestor's background, and a highlight can resolve perfectly while being invisible on screen. Close the loop with two screenshots and a diff: capture the header with the effect live and again with it suppressed (inject a `<style>` that zeroes the ring opacity / clears the clipped background), then compare. Freeze animations first (`for (const a of document.getAnimations()) { a.pause(); a.currentTime = 1000; }`) so the comparison is not confounded by the band sitting elsewhere.
11. That diff needs a CONTROL baseline: the three `.bg-gradient-orb` elements carry `blur(150px)`/`blur(260px)` and re-rasterize between frames, so a page-wide low-delta noise floor exists and "N pixels changed" proves nothing on its own. Measure the same-size region at several control spots first (the honest baseline came out at mean abs diff 0.01, peak ≤91) and require the region under test to beat it by a large factor (7.3 and 45.5 mean — 586× and 3635× — with peaks 227/241, which is what made the claim defensible).
- Measurement traps for a rendered effect — phase-dependent "brightest pixel" readings, per-layer
computed values, control baselines that move between runs, and reference frames that change two
variables at once — are collected in `references/visual-effect-verification.md`, together with the
honest before/after calibration numbers for the logo highlight. Read it before tuning or re-measuring
any animated effect. To measure what COLOUR an animated highlight is, pin the rotation to several angles (`--angle` is a registered `@property`, so an injected rule can freeze it) and DIFFERENCE the angles: anything static — the element's own gradient, its `box-shadow`, the page background — cancels out, and only the travelling light survives. A naive annulus around a 44px tile reads the tile's own indigo/pink gradient at its rounded corners (the face reaches r ~= 31, i.e. 22*sqrt2) and its static indigo `box-shadow`, which is how a pure-white highlight first measured "43% chromatic, blue". Sample outside the element's bounding RECTANGLE, not a centre radius.

Run nginx config checks with `sudo -n nginx -t`; an unprivileged check can report certificate-read errors that do not reflect the root-run service.

## Deploy and boot traps
- **A rebuild bakes in OTHER sessions' landed work, migrations and all.** The
  working tree is shared, so `docker compose build` ships whatever is there —
  including a commit whose migration was never applied. Check
  `db:migrate:status` for `down` rows BEFORE recreating the container; a landed
  template that reads an unapplied COLUMN 500s every page that renders it.
- **A new asset FILE added to the live checkout while Puma is running 500s every page that loads the layout** — Propshaft builds its digest manifest at boot, so a stylesheet created after boot raises `Propshaft::MissingAssetError` until the container is restarted. Same family as the stale-code rule: the running app is boot-frozen. (This also fires for an EXTERNAL agent's uncommitted files landing in the live checkout — check `ls -la` mtimes on the named asset before debugging the code.)
- `start-chopshop-stack.sh` embeds the stack topology in several places — header comment, ufw `allow` rule, fail2ban jail `port =`, and the final `echo` help text — and they drift when ports/hosts change (they once named a dead :8804 GUI port and an `<gpu-box>` host long after both were gone). After any topology change, grep the launcher for the old port/host and update every occurrence AND the live system state (`ufw status`, `/etc/fail2ban/jail.d/*.local`), then `fail2ban-client reload` — not just the echo text.
- **Deploy at the END of a layout task, but never treat "the layout is still moving" as a reason to skip it.** A multi-round re-layout is exactly where the deploy gets forgotten, because each round feels like a draft being iterated and the next instruction arrives before you finish. If a layout conversation spans more than one round, the precompile + restart belong to the LAST round, and the report must state the live digest — not "Done". This fires even when a later round is a pure VERIFICATION of an already-deployed change: re-run precompile + restart for any round that touched CSS or ERB after the last deploy, and read the new `digested_path` out of `.manifest.json` before reporting. Saying "Done" while the served digest is two builds stale is what drew "did you update the live shit"; the fix is to make the deploy a numbered step of the SAME turn as the edit, not a follow-up task. See the change-and-deploy procedure above.
