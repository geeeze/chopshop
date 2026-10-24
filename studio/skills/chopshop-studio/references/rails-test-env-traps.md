# Rails test-environment traps

Traps that make a Rails test suite fail for reasons unrelated to the code under
test. Verify the environment before debugging a failing test.

## RAILS_ENV defaults to whatever the container booted with

A container image can carry `RAILS_ENV=development` in its environment, and
`ENV["RAILS_ENV"] ||= "test"` in `test_helper.rb` does NOT override it — `||=`
leaves an already-set variable alone. The consequence is silent and severe:
the suite boots development config and the development database, so config
changes in `config/environments/test.rb` never apply and tests that depend on
test-env behaviour fail mysteriously.

**Run the suite with the env explicit every time:**

```bash
podman exec <container> env RAILS_ENV=test bundle exec ruby -Itest <path>
```

Before debugging any integration-test failure, print the env the test actually
sees:

```bash
podman exec <container> env RAILS_ENV=test bundle exec ruby -Itest -e '
require "test_helper"; puts ENV["RAILS_ENV"]'
```

If it does not say `test`, that is the bug, not the test.

## Host authorization rejects integration-test requests

Rails 7.1+ blocks requests to hosts outside `config.hosts`. Integration tests
post to hosts like `www.example.com`, so without an allowlist every request
dies at middleware with a `Blocked host` 403 rendered as
`Action Controller: Exception caught` — it looks like a controller error, not
a host filter. The response body's `<h2>` naming the missing host is the tell.

Fix once in `config/environments/test.rb` (Rails already allowlists IP ranges):

```ruby
config.hosts << "www.example.com"
config.hosts << "127.0.0.1"
config.hosts << "localhost"
```

## The test database needs its own migration

The development database being migrated says nothing about the test database.
A pending migration there aborts the suite with `Migrations are pending` before
any test runs:

```bash
podman exec <container> env RAILS_ENV=test bundle exec rails db:migrate
```

## Debugging a 403 that is really an exception page

A 403 from an integration test carries a full HTML error document, which
swallows `JSON.parse(response.body)` with `unexpected character: '<!DOCTYPE'`.
Read the exception identity from the body before assuming anything about auth:

```ruby
b = response.body
exc = b[/<h2[^>]*>([^<]*)<\/h2>/, 1]
```

- title is `Action Controller: Exception caught` — an exception was raised;
  the `<h2>` holds its message.
- title mentions host authorization — the `config.hosts` trap above.
- otherwise inspect `response.status` and the redirect target; a `before_action`
guard redirecting to login produces HTML where the test expects JSON.

## Password-only auth seeds its user in the global test setup

When the app authenticates by comparing the posted password against DB users,
the test suite seeds its user in a global `setup` block, not via fixtures.
`User.count == 0` means login can never succeed and every auth-gated request
redirects — the model layer works while every request looks unauthenticated.

## An interrupted or crashed subagent may have finished the work

A subagent killed by a repetition loop or timeout can leave a complete,
passing implementation behind — the crash often happens while it writes its
final summary, after the code and tests landed. Before re-dispatching a
"failed" agent's task, run the tests for the files it touched: a green suite
means the work is done and only the report was lost.

## Distinguishing product bugs from test-harness bugs

A controller test that fails while its model test passes is usually the test's
stubbing, not the code. When a stub counts calls globally and each HTTP request
re-reads state from the database, the counter desynchronizes from the state and
the test asserts the wrong sequence — the product behavior is fine. Drive the
model directly in a probe to prove which one is broken before fixing anything.

## The deployed instance, not the suite, is the final verifier

The container runs an older checkout than the working tree, and an app that
has not been `db:migrate`d since the last deploy returns 500 on every page —
`check_pending_migrations` in the log is the whole diagnosis, and
`bin/rails db:migrate` in the container fixes it. After any
migration-bearing change, run `bin/rails db:migrate:status` in the
container and migrate before concluding the app is broken.

Smoke-test a NEW feature on the live instance, not just the suite: seed a
fixture library, drive the real operator surface (a rake task or a runner
script), and prove the property the feature promises (determinism,
distinctness, refusal). A rake task that correctly REFUSES on an empty
library is the honest path — a batch that filed zero jobs silently would
be the bug.

## `rails runner` quoting: pass a FILE, not an inline script

Inline `rails runner "... #{...} ..."` loses to three layers of shell
interpolation (the host shell, `bash -lc`, and the double-quoted string), and
a single-quoted variant still gets mangled. The reliable shape is a scratch
file, `podman cp`'d in and run by path:

```bash
podman exec <container> bash -lc 'bin/rails runner /tmp/probe.rb'
```

Model gotchas the file approach also sidesteps: `PromptSource` validates
`dataset` against a hardcoded `DATASETS` allowlist (only `diffusiondb`
today), and `Project` requires `owner` (the `Owned` concern) or the
insert dies on a `NOT NULL` constraint. Seed those fields or the probe
fails on validation, not on the behavior under test.

## Verify tracker state against origin before asserting it

A comment that says "X is still open" is a claim about the REMOTE tree,
and the local checkout may be behind another agent's push. Before posting
a tracker comment that asserts or corrects state (open/closed/landed),
`git fetch origin` and re-read the file or commit from `origin/main`, not
the working tree — a stale local read produces a wrong assertion that then
needs its own correcting comment. Git history (`git log --all --grep=`
across the sibling repos) is the authority on whether a fix landed; a
local tree is only a cache of it. When two comments contradict, the one
backed by a fetched commit hash is the one to trust — and post the
correction promptly rather than letting a wrong record stand.