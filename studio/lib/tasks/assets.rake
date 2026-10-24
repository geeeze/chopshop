# Asset-related tasks. The staleness check exists so a deploy gate (CI, a
# wrapper around `docker build`, a systemd unit) can catch a stale-asset state
# BEFORE it reaches production, the same warning the boot initializer emits.
namespace :assets do
  desc "Warn (and exit non-zero) when public/assets/.manifest.json is older than the newest app/assets source"
  task staleness_check: :environment do
    # ASSET_ROOT lets a deploy gate point the check at a build output dir or
    # staging tree without the guard knowing anything about it. Defaults to
    # Rails.root for the normal `bin/rails assets:staleness_check` invocation.
    root = ENV["ASSET_ROOT"].presence || Rails.root
    guard = AssetStalenessGuard.new(root: root)

    if guard.ok?
      puts "asset staleness: OK — #{guard.manifest_path} is up to date with app/assets"
    else
      warn guard.report
      # Exit non-zero so a deploy gate can fail the build. `abort` would print
      # the report to stderr and raise SystemExit(1) in one step, but `warn` +
      # `exit` keeps the report visible on stderr (where a human reads it)
      # AND makes the exit status explicit to whatever invoked the task.
      exit 1
    end
  end
end
