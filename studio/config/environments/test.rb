# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true
  # NOT :null_store. The login throttle (rate_limit on ApplicationController#authenticate)
  # counts attempts in the cache store, and a null store never counts — increment
  # is a no-op returning nil, so the 429 path would be dead code here. A memory
  # store is per-process, which is exactly the scope the throttle has in
  # development too, and each test clears it (test/test_helper.rb) so one test's
  # attempts cannot trip the limit for the next.
  config.cache_store = :memory_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Integration tests drive requests through hosts Rails would otherwise block
  # (the default test host "www.example.com", plus 127.0.0.1 / localhost when a
  # test posts by IP). Rails 7.1+ host authorization rejects unknown hosts with
  # a "Blocked host" 403 before any controller runs, so every auth-gated
  # integration test fails at the middleware unless these are allowlisted here.
  config.hosts << "www.example.com"
  config.hosts << "127.0.0.1"
  config.hosts << "localhost"

  # Jobs enqueue to the in-memory test adapter; perform_enqueued_jobs runs them.
  config.active_job.queue_adapter = :test

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true
end
