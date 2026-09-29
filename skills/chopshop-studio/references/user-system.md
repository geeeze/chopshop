# Per-user accounts (password-only)

Settled direction, shipped 2026-09-28: **the password IS the identity** — no username,
no directory, no LDAP. Each user's password gates access to their own data.

## Layers

- `app/models/user.rb` — `User < ActiveRecord::Base` with `has_secure_password`
  (bcrypt; Gemfile `gem "bcrypt"`, installed system-wide under `/var/lib/gems/3.2.0`
  via `sudo gem install bcrypt`). `validates :handle, presence, uniqueness`.
  `User.authenticate_by_password(raw)` scans users for a bcrypt match (O(n), fine at
  single-digit user count) and returns nil on a miss — a blank/wrong password is
  indistinguishable by design. No username field exists or should.
- `app/models/current.rb` — `Current < ActiveSupport::CurrentAttributes` with
  `attribute :user_handle`. Set per-request in `ApplicationController#set_current`
  (`Current.user_handle = current_user&.handle`). Rails resets it between requests and
  jobs; in the Solid Queue worker it is nil, which is what lets RunJob reach any job.
- `app/models/concerns/owned.rb` — the `Owned` concern, included by `Job`,
  `Validation`, `ScrapbookItem`, `Composite`. `before_validation :assign_owner,
  on: :create` (`self.owner ||= Current.user_handle`) plus a `default_scope` returning
  `where(owner: handle)` when signed in and `all` otherwise.
- `owner` columns: `jobs` + `validations` added; `scrapbook_items` + `composites`
  already carried nullable `owner`.

## Auth controller

`ApplicationController`: `require_login` redirects unless `current_user`;
`authenticate` sets `session[:user_id] = user.id` on a match, else 401 and writes
`log/chopshop-auth.log` (fail2ban-parsed); `logout` resets the session. The old `session[:authed]` boolean and `gate_password`/`gate_disabled?` helpers are gone.
`CHOPSHOP_PASSWORD` is no longer read — the operator's original password was migrated
unchanged into the `users` table as `<operator-handle>`, so their regular login still works.

## Queue safety

Solid Queue runs inside Puma, and `Job`'s default scope would have silently made the
queue cap per-user. `JobsController#enqueue_run` therefore counts
`Job.unscoped.where(state: "queued")` — the cap is global.

## Adding a user

**Adding a user ADDS a new handle — never overwrite an existing user's password.**
The operator's regular password was migrated unchanged into `<operator-handle>`; when they ask to
"add another", create a NEW handle (e.g. `<test-handle>`) with the new password and leave
`<operator-handle>`'s password untouched. Re-seeding `<operator-handle>` with the newcomer's password reads as
"you deleted my password" and draws a hard correction.

`cd ~/chopshop-studio && RAILS_ENV=production bin/rails 'users:add[handle,password]'`
(or `bin/rails runner 'User.create!(handle: "x", password: "y")'`). List handles:
`bin/rails users:list`.

## Schema + migration

Schema is hand-maintained (`db/schema.rb`, no `db/migrate/`), so production changes
apply via an idempotent `bin/rails runner` script: `create_table "users" unless
table_exists?`, `add_column :owner unless column_exists?`, backfill
`where(owner: nil).update_all(owner: "<operator-handle>")`, then seed/rotate the operator. Never
`db:schema:load` against the live file (drops data).

## Tests

- `test/test_helper.rb` seeds `test`/`test-password` and sets
  `Current.user_handle = "test"` per test, so records created directly in a test are
  stamped with the same handle the signed-in session reads back.
- `ActiveModel::SecurePassword.min_cost = true` keeps the per-test bcrypt hash cheap.
- `test/controllers/user_auth_test.rb` pins: wrong password → 401; right password →
  session + redirect; auto-stamp on create; owner scope hides foreign rows; the index
  lists only the signed-in user's jobs.

## Verification

Correct password POSTs 302 → root; wrong password → 401; authed root → 200.

## Resetting an owner's workspace (`users:reset`)

Clearing a test user is a routine operator job, so it is a TASK, not a recipe to
improvise:

    RAILS_ENV=production bin/rails 'users:reset[test-user-a,test-user-b]'          # DRY RUN
    APPLY=1 RAILS_ENV=production bin/rails 'users:reset[test-user-a,test-user-b]'   # applies
    bin/rails users:inventory                                                       # rows + bytes per owner

It deletes the owner's **jobs, candidates, validations, composites, events and
scrapbook rows**, plus the scrapbook FILES those rows copied into
`storage/scrapbook/` (a scrapbook row owns bytes, so deleting rows alone leaks
disk quietly — see `scrapbook.md`). The `users` row is KEPT: the account still
logs in to an empty workspace. `users:reset` refuses a handle that is not a user
rather than resetting nothing and reporting success.

**Owner scoping is per-table and guessing it orphans rows.** `owner` exists on
`jobs`, `validations`, `composites`, `events` and `scrapbook_items` — but
**`candidates` has NO owner column**; it is job-scoped. The task therefore
resolves the job ids FIRST and deletes children by `job_id`, because
`delete_all` (chosen so a DB behind the code cannot raise on a missing attribute)
fires no callbacks and the `dependent: :delete_all` on `Job` never runs.

### Run it against the RIGHT database or you will reset nothing

`storage/` holds TWO sqlite databases and a bare `bin/rails runner`/`db:migrate:status`
defaults to **development**:

| | file | who uses it |
|---|---|---|
| development | `storage/development.sqlite3` | a `bin/rails console` with no env var |
| **production** | `storage/production.sqlite3` | the live Puma service |

So always `set -a; . ~/.chopshop-studio.env; set +a; RAILS_ENV=production bin/rails …`
for anything operational. Recon without it reported **"0 users"** while the live
app served three — a near miss that would have read as "the users aren't there".

### Rake splits the argument — one name is not enough

`users:reset[a,b]` arrives as TWO rake args, and a task declaring
only `%i[handles]` binds the first and silently drops the rest: it reset ONE
owner and exited 0. Read `args.extras` too. The dry run is what caught this.

### Artifacts are NOT the reset's job

Deleting the rows leaves the pipeline's shared output dirs and the studio's
upload copies behind, because they are keyed by input STEM. The hourly
`chopshop-orphan-sweep` timer (see `orphan-sweep.md`) reclaims exactly the stems
with no live job — with a 24h grace (`CHOPSHOP_SWEEP_GRACE_HOURS`). **Do not force
grace to 0 while a job is running**: a mid-run job can write `flux_*` artifacts
whose stem has no job row yet, and they would be swept out from under it. Let the
timer age them out. `storage/datasets/` is a GLOBAL corpus (no `owner` column) —
never part of a per-user reset.
