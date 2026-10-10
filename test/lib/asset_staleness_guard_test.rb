require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"
require "logger"
require "rake"
# The test runner does not load lib/tasks (only `bin/rails` does), so the
# rake task tests need to load it explicitly, the same way
# e2e_testing_skill_test does. `load` rather than `require` because the file
# is a PATH, not a gem, and it is idempotent.
load File.join(Rails.root, "lib", "tasks", "assets.rake")
Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)

# A DEPLOY THAT SKIPS assets:precompile NEVER FAILS (studio #8).
#
# The Dockerfile precompiles at image build time, so the container ships
# assets baked to the image. But if anything ever serves stale bytes -- a
# non-container deploy, a CDN with old cached files, a box rebuilt without
# the precompile step -- the page renders fine with no error and no signal.
# The served CSS/JS is simply not what `main` says.
#
# So this guard compares the compiled manifest's mtime against the newest
# source under app/assets. When the manifest is older than a source, the
# warning names the manifest, the source, and the fix. Missing manifest
# does NOT false-alarm (dev / CDN / pre-first-deploy boxes have none).
class AssetStalenessGuardTest < ActiveSupport::TestCase
  NOW    = Time.utc(2026, 10, 10, 12, 0, 0).freeze
  LATER  = Time.utc(2026, 10, 11, 12, 0, 0).freeze
  EARLIER = Time.utc(2026, 10,  9, 12, 0, 0).freeze

  # Builds a minimal asset tree inside a tmpdir. Returns [root, assets_dir,
  # source_dir]. Callers then create manifest/source files with controlled
  # mtimes.
  def with_asset_tree
    Dir.mktmpdir("asset-guard") do |dir|
      assets_dir  = File.join(dir, "public", "assets")
      source_dir = File.join(dir, "app", "assets")
      FileUtils.mkdir_p(assets_dir)
      FileUtils.mkdir_p(source_dir)
      yield dir, assets_dir, source_dir
    end
  end

  def write(path, content = "x")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # Sets mtimes on a list of files. `spec` is [file, time] pairs.
  def set_mtimes(spec)
    spec.each { |file, time| File.utime(time, time, file) }
  end

  # Points ENV["ASSET_ROOT"] at `root` for the duration of the block, and
  # restores it after. The rake task reads this env var.
  def with_asset_root(root)
    original = ENV["ASSET_ROOT"]
    ENV["ASSET_ROOT"] = root
    yield
  ensure
    ENV["ASSET_ROOT"] = original
  end

  # --- guard logic -----------------------------------------------------------

  test "a stale manifest (older than a newer source) is flagged" do
    with_asset_tree do |root, assets_dir, source_dir|
      manifest = File.join(assets_dir, ".manifest.json")
      source   = File.join(source_dir, "application.css")
      write(manifest, "{}")
      write(source)
      set_mtimes([[manifest, EARLIER], [source, LATER]])

      guard = AssetStalenessGuard.new(root: root)
      assert guard.stale?, "a manifest older than a source is stale"
      refute guard.ok?

      finding = guard.findings.sole
      assert_equal manifest, finding.manifest
      assert_equal source, finding.newest_source
      assert_equal LATER, finding.source_mtime
      assert_equal EARLIER, finding.manifest_mtime
    end
  end

  test "a fresh manifest (newer than all sources) is NOT flagged" do
    with_asset_tree do |root, assets_dir, source_dir|
      manifest = File.join(assets_dir, ".manifest.json")
      source   = File.join(source_dir, "application.css")
      write(manifest, "{}")
      write(source)
      set_mtimes([[manifest, LATER], [source, EARLIER]])

      guard = AssetStalenessGuard.new(root: root)
      refute guard.stale?, "a manifest newer than every source is the healthy steady state"
      assert guard.ok?
    end
  end

  test "a missing manifest does NOT false-alarm" do
    with_asset_tree do |root, _assets_dir, source_dir|
      source = File.join(source_dir, "application.css")
      write(source)
      set_mtimes([[source, LATER]])

      guard = AssetStalenessGuard.new(root: root)
      refute guard.stale?, "no manifest means nothing to compare -- not a stale state"
      assert guard.ok?
      assert_empty guard.findings
    end
  end

  test "a tree with neither manifest nor sources does NOT false-alarm" do
    with_asset_tree do |root, _assets_dir, _source_dir|
      guard = AssetStalenessGuard.new(root: root)
      refute guard.stale?, "an empty tree is not stale"
      assert guard.ok?
    end
  end

  test "manifest at the SAME mtime as the newest source is NOT flagged" do
    # Boundary: source mtime == manifest mtime means the source was
    # touched at the same second as the precompile -- either it was
    # precompiled in the same run or the clock resolution hid a difference.
    # Treating that as stale would false-alarm on every precompile that
    # finishes in the same second as a source write.
    with_asset_tree do |root, assets_dir, source_dir|
      manifest = File.join(assets_dir, ".manifest.json")
      source   = File.join(source_dir, "application.css")
      write(manifest, "{}")
      write(source)
      set_mtimes([[manifest, NOW], [source, NOW]])

      guard = AssetStalenessGuard.new(root: root)
      refute guard.stale?, "same mtime means the manifest is not older than the source"
      assert guard.ok?
    end
  end

  test "the newest source is reported (not the first alphabetically)" do
    with_asset_tree do |root, assets_dir, source_dir|
      manifest    = File.join(assets_dir, ".manifest.json")
      old_source  = File.join(source_dir, "aaa_old.css")
      new_source  = File.join(source_dir, "zzz_new.css")
      write(manifest, "{}")
      write(old_source)
      write(new_source)
      set_mtimes([[manifest, EARLIER], [old_source, NOW], [new_source, LATER]])

      guard = AssetStalenessGuard.new(root: root)
      assert guard.stale?
      assert_equal new_source, guard.newest_source.to_s,
        "the finding must name the NEWEST source -- the one an operator " \
        "recompiling now is responding to"
    end
  end

  test "nested source directories are scanned recursively" do
    with_asset_tree do |root, assets_dir, source_dir|
      manifest = File.join(assets_dir, ".manifest.json")
      nested   = File.join(source_dir, "sub", "dir", "nested.js")
      write(manifest, "{}")
      write(nested)
      set_mtimes([[manifest, EARLIER], [nested, LATER]])

      guard = AssetStalenessGuard.new(root: root)
      assert guard.stale?, "sources in subdirectories of app/assets count"
      assert_equal nested, guard.newest_source.to_s
    end
  end

  # --- the warning content ---------------------------------------------------

  test "the warning names the manifest, the newest source, and the fix" do
    with_asset_tree do |root, assets_dir, source_dir|
      manifest = File.join(assets_dir, ".manifest.json")
      source   = File.join(source_dir, "application.css")
      write(manifest, "{}")
      write(source)
      set_mtimes([[manifest, EARLIER], [source, LATER]])

      guard = AssetStalenessGuard.new(root: root)
      report = guard.report

      assert_match(/\.manifest\.json/, report,
        "the warning must name the manifest file -- the operator needs " \
        "to know WHICH artifact is stale")
      assert_match(/application\.css/, report,
        "and the source that is newer -- the operator needs to know what " \
        "changed since the last build")
      assert_match(/assets:precompile/, report,
        "and the fix -- a warning without a remediation step is noise")
    end
  end

  test "the warning is loud (not a debug-level log line)" do
    with_asset_tree do |root, assets_dir, source_dir|
      manifest = File.join(assets_dir, ".manifest.json")
      source   = File.join(source_dir, "application.css")
      write(manifest, "{}")
      write(source)
      set_mtimes([[manifest, EARLIER], [source, LATER]])

      output = StringIO.new
      logger = Logger.new(output)

      result = AssetStalenessGuard.verify!(root: root, logger: logger)

      refute result, "verify! returns false when the deploy is stale"
      log_output = output.string
      assert_match(/WARN/, log_output,
        "the warning must be at WARN level -- a stale-asset state is a " \
        "deploy smell that should be impossible to miss in the boot log")
      assert_match(/ASSET STALENESS/, log_output)
      assert_match(/application\.css/, log_output)
    end
  end

  test "verify! returns true and logs nothing when the deploy is sound" do
    with_asset_tree do |root, assets_dir, source_dir|
      manifest = File.join(assets_dir, ".manifest.json")
      source   = File.join(source_dir, "application.css")
      write(manifest, "{}")
      write(source)
      set_mtimes([[manifest, LATER], [source, EARLIER]])

      output = StringIO.new
      logger = Logger.new(output)

      result = AssetStalenessGuard.verify!(root: root, logger: logger)

      assert result
      assert_empty output.string, "no log output when the deploy is healthy"
    end
  end

  test "verify! returns true and logs nothing when no manifest exists" do
    with_asset_tree do |root, _assets_dir, source_dir|
      source = File.join(source_dir, "application.css")
      write(source)
      set_mtimes([[source, LATER]])

      output = StringIO.new
      logger = Logger.new(output)

      result = AssetStalenessGuard.verify!(root: root, logger: logger)

      assert result
      assert_empty output.string,
        "a missing manifest must be silent -- every dev boot and CI run " \
        "has no precompiled assets, and a false alarm there gets the guard " \
        "muted by the second deploy"
    end
  end

  # --- initializer wiring ----------------------------------------------------

  test "the boot initializer calls verify! with the Rails root" do
    initializer = Rails.root.join("config/initializers/asset_staleness_guard.rb")
    assert initializer.exist?, "the boot-time guard is the half that catches it"
    body = initializer.read
    assert_match(/AssetStalenessGuard\.verify!/, body,
      "the initializer must call the SAME entry point the tests exercise")
  end

  # --- the rake task ---------------------------------------------------------

  test "the rake task prints OK and exits zero when the deploy is sound" do
    with_asset_tree do |root, assets_dir, source_dir|
      manifest = File.join(assets_dir, ".manifest.json")
      source   = File.join(source_dir, "application.css")
      write(manifest, "{}")
      write(source)
      set_mtimes([[manifest, LATER], [source, EARLIER]])

      output, _err = nil, nil
      with_asset_root(root) do
        output, _err = capture_io do
          Rake::Task["assets:staleness_check"].invoke
        end
      end

      assert_match(/OK/, output)
      Rake::Task["assets:staleness_check"].reenable
    end
  end

  test "the rake task exits non-zero and prints the warning when stale" do
    with_asset_tree do |root, assets_dir, source_dir|
      manifest = File.join(assets_dir, ".manifest.json")
      source   = File.join(source_dir, "application.css")
      write(manifest, "{}")
      write(source)
      set_mtimes([[manifest, EARLIER], [source, LATER]])

      exit_error = nil
      _out, err = nil, nil
      with_asset_root(root) do
        _out, err = capture_io do
          begin
            Rake::Task["assets:staleness_check"].invoke
          rescue SystemExit => e
            exit_error = e
          end
        end
      end

      assert_not_nil exit_error, "the task must exit non-zero when stale"
      assert_equal 1, exit_error.status,
        "the exit status must be non-zero so a deploy gate can fail the build"
      assert_match(/ASSET STALENESS/, err,
        "the report must go to stderr -- that is where a human reads it " \
        "when a deploy gate fails")
      assert_match(/assets:precompile/, err)
    ensure
      Rake::Task["assets:staleness_check"].reenable
    end
  end

  test "the rake task does NOT false-alarm on a tree with no manifest" do
    with_asset_tree do |root, _assets_dir, source_dir|
      source = File.join(source_dir, "application.css")
      write(source)
      set_mtimes([[source, LATER]])

      output, err = nil, nil
      with_asset_root(root) do
        output, err = capture_io do
          Rake::Task["assets:staleness_check"].invoke
        end
      end

      assert_match(/OK/, output,
        "no manifest means nothing to compare -- the task must pass, " \
        "not fail or warn")
      assert_empty err
      Rake::Task["assets:staleness_check"].reenable
    end
  end
end
