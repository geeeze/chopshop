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

**Account roles — do not confuse them.** `<operator-handle>` is the operator's migrated
account (password from `CHOPSHOP_PASSWORD`, never reset). `<test-handle>` is the
operator's own for live demos (secret in `CHOPSHOP_TEST_ACCOUNT_SECRET`). `<disposable-handle>` is
the throwaway smoke account. `demo` and `<operator-handle>4` are purpose-built disposable
accounts created for one-off smoke passes — safe to recreate, no env-file secret.
Adding a user ADDS a handle; "reset the demo user" only ever means `<disposable-handle>`, and
only `<disposable-handle>`.

## Schema + migration

The repo carries BOTH `db/schema.rb` and `db/migrate/` (9 migrations as of
2026-09-29), and each migration is guarded with `table_exists?`/`column_exists?`
so a DB built from either source converges. An idempotent `bin/rails runner`
script still works for a hand-repair (`create_table "users" unless table_exists?`,
`add_column :owner unless column_exists?`, backfill
`where(owner: nil).update_all(owner: "<operator-handle>")`), but for a schema change the
migration is the artifact — and it must be applied to production BEFORE the
restart (`RAILS_ENV=production bin/rails db:migrate`), or the live app 500s on a
column the code already reads. Never `db:schema:load` against the live file
(drops data).

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
