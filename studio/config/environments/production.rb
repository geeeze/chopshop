require "active_support/core_ext/integer/time"
require "logger"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Behind nginx (Let's Encrypt) / Cloudflare proxy. Trust the forwarded
  # proto/for headers from nginx and Cloudflare's published ranges so secure
  # cookies and URL generation work over HTTPS.
  config.assume_ssl = true
  config.force_ssl = true
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }
  config.action_dispatch.trusted_proxies = [
    IPAddr.new("127.0.0.1"),
    # Cloudflare (https://www.cloudflare.com/ips-v4)
    IPAddr.new("173.245.48.0/20"), IPAddr.new("103.21.244.0/22"), IPAddr.new("103.22.200.0/22"),
    IPAddr.new("103.31.4.0/22"), IPAddr.new("141.101.64.0/18"), IPAddr.new("108.162.192.0/18"),
    IPAddr.new("190.93.240.0/20"), IPAddr.new("188.114.96.0/20"), IPAddr.new("197.234.240.0/22"),
    IPAddr.new("198.41.128.0/17"), IPAddr.new("162.158.0.0/15"), IPAddr.new("104.16.0.0/13"),
    IPAddr.new("172.64.0.0/13"), IPAddr.new("131.0.72.0/22")
  ]

  # Log to a file with real timestamps — fail2ban needs a parseable date on
  # each line (Rails 8's default production format drops it). Plain ::Logger
  # writes "I, [2026-09-24T15:30:42.123 #pid]  INFO -- : [tags] msg".
  config.logger = ActiveSupport::TaggedLogging.new(
    Logger.new(Rails.root.join("log/production.log"))
  )
  # keep the default ::Logger format (with timestamp) — SimpleFormatter
  # strips it and fail2ban needs a date on each line
  config.log_formatter = Logger::Formatter.new
  config.log_tags = [ :request_id ]

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  # config.cache_store = :mem_cache_store

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # DNS rebinding protection is off for this demo: requests legitimately
  # arrive via the bare public IP, which can't be host-listed cleanly.
  config.host_authorization = { exclude: ->(request) { true } }
end
