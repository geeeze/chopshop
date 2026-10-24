require "test_helper"
require "tmpdir"
require "fileutils"

# AGE-BASED RETENTION FOR GENERATED ARTIFACTS (issue #12).
#
# storage/uploads is both the private home of the operator's source rasters
# (upload_*) and the place every step's produced artifact is written so
# upload_preview can serve it. Nothing ever removed either kind, and the
# generated half was unbounded: a chained run writes one plot_*.svg per
# drawing step and one blender_*.png per render, and the hourly smoke test
# files such a chain every hour.
#
# UploadRetention deletes generated artifacts older than N days, scoped to the
# exact prefixes the app itself generates (plot_/blender_/step_/flux_).
# upload_* are the operator's originals and are NEVER eligible — the
# operator cannot regenerate them from a job record.
#
# Safety is proven here against a tmpdir sandbox: the real storage/uploads is
# never touched by these tests.
class UploadRetentionTest < ActiveSupport::TestCase
  def setup
    @tmpdir = Dir.mktmpdir("upload-retention-test")
    @retention = UploadRetention.new(directory: @tmpdir, days: 7)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  # Write a file with an mtime older than the threshold.
  def write_old_file(name, days_old: 30)
    path = File.join(@tmpdir, name)
    File.write(path, "old #{name}")
    old_time = Time.now - days_old.days
    File.utime(old_time, old_time, path)
    path
  end

  # Write a file with a fresh mtime.
  def write_new_file(name)
    path = File.join(@tmpdir, name)
    File.write(path, "new #{name}")
    path
  end

  # --- upload_* safety -----------------------------------------------------

  test "upload_* files are never eligible for deletion" do
    path = write_old_file("upload_abc123.png", days_old: 60)
    report = @retention.run
    # The candidate list must NOT contain any upload_* file.
    refute_includes report[:candidates].map { |f| File.basename(f) },
                   File.basename(path),
                   "upload_* must NEVER appear in the deletion candidates"
    assert File.exist?(path), "upload_* file must still exist after retention run"
  end

  test "upload_* files are not deleted even when explicitly targeted" do
    path = write_old_file("upload_important.tif", days_old: 365)
    report = @retention.run
    assert File.exist?(path)
    assert_empty report[:deleted].select { |f| File.basename(f).start_with?("upload_") }
  end

  # --- unknown prefix safety ------------------------------------------------

  test "files with unknown prefixes are left alone" do
    path = write_old_file("mystery_old_file.bin", days_old: 60)
    report = @retention.run
    refute_includes report[:candidates], path
    assert File.exist?(path), "unknown prefix file must still exist"
  end

  test "a file whose prefix is not in the known-generated set is never a candidate" do
    path = write_old_file("other_prefix_12345.dat", days_old: 60)
    report = @retention.run
    refute_includes report[:candidates].map { |f| File.basename(f) },
                   File.basename(path),
                   "unknown prefixes must not appear in candidates"
    assert File.exist?(path)
  end

  # --- generated prefix eligibility -----------------------------------------

  test "old plot_ files are eligible for deletion" do
    path = write_old_file("plot_abc123.svg", days_old: 10)
    report = @retention.run
    assert_includes report[:candidates].map { |f| File.basename(f) }, File.basename(path)
  end

  test "old blender_ files are eligible for deletion" do
    path = write_old_file("blender_def456.png", days_old: 10)
    report = @retention.run
    assert_includes report[:candidates].map { |f| File.basename(f) }, File.basename(path)
  end

  test "old step_ files are eligible for deletion" do
    path = write_old_file("step_789abc.svg", days_old: 10)
    report = @retention.run
    assert_includes report[:candidates].map { |f| File.basename(f) }, File.basename(path)
  end

  test "old flux_ files are eligible for deletion" do
    path = write_old_file("flux_xyz999.png", days_old: 10)
    report = @retention.run
    assert_includes report[:candidates].map { |f| File.basename(f) }, File.basename(path)
  end

  test "fresh generated files are NOT eligible for deletion" do
    path = write_new_file("plot_fresh01.svg")
    report = @retention.run
    refute_includes report[:candidates].map { |f| File.basename(f) }, File.basename(path)
    assert File.exist?(path)
  end

  # --- dry-run --------------------------------------------------------------

  test "dry-run deletes nothing but reports the candidates" do
    old_plot = write_old_file("plot_old123.svg", days_old: 10)
    old_blender = write_old_file("blender_old456.png", days_old: 10)
    new_plot = write_new_file("plot_new789.svg")

    dry = UploadRetention.new(directory: @tmpdir, days: 7, dry_run: true)
    report = dry.run

    assert_equal 2, report[:count]
    assert_includes report[:candidates].map { |f| File.basename(f) }, File.basename(old_plot)
    assert_includes report[:candidates].map { |f| File.basename(f) }, File.basename(old_blender)
    refute_includes report[:candidates].map { |f| File.basename(f) }, File.basename(new_plot)

    # Nothing was actually deleted.
    assert File.exist?(old_plot), "dry-run must not delete old_plot"
    assert File.exist?(old_blender), "dry-run must not delete old_blender"
    assert File.exist?(new_plot), "dry-run must not delete new_plot"
    assert_empty report[:deleted]
  end

  # --- actual deletion -------------------------------------------------------

  test "non-dry-run deletes old generated files and leaves the rest" do
    old_plot = write_old_file("plot_delete01.svg", days_old: 10)
    old_blender = write_old_file("blender_del02.png", days_old: 10)
    new_plot = write_new_file("plot_keep03.svg")
    upload = write_old_file("upload_keep99.tif", days_old: 100)
    mystery = write_old_file("other_keep88.bin", days_old: 100)

    apply = UploadRetention.new(directory: @tmpdir, days: 7, dry_run: false)
    report = apply.run

    refute File.exist?(old_plot), "old plot_ must be deleted"
    refute File.exist?(old_blender), "old blender_ must be deleted"
    assert File.exist?(new_plot), "fresh plot_ must survive"
    assert File.exist?(upload), "upload_* must survive"
    assert File.exist?(mystery), "unknown prefix must survive"
    assert_equal 2, report[:deleted].size
  end

  # --- idempotency -----------------------------------------------------------

  test "running retention twice is safe and idempotent" do
    old_plot = write_old_file("plot_idem01.svg", days_old: 10)
    old_blender = write_old_file("blender_idem02.png", days_old: 10)

    first = UploadRetention.new(directory: @tmpdir, days: 7, dry_run: false)
    first.run

    second = UploadRetention.new(directory: @tmpdir, days: 7, dry_run: false)
    report = second.run

    assert_equal 0, report[:count], "second run finds nothing to delete"
    assert_equal 0, report[:deleted].size
  end

  # --- directory edge cases ---------------------------------------------------

  test "non-existent directory returns empty report" do
    retention = UploadRetention.new(directory: "/nonexistent/path/xyz", days: 7)
    report = retention.run
    assert_equal 0, report[:count]
    assert_empty report[:candidates]
  end

  # --- prefix matching precision ----------------------------------------------

  test "a file named exactly like a generated prefix is not treated as one without underscore" do
    path = write_old_file("plot.svg", days_old: 30)
    report = @retention.run
    refute_includes report[:candidates].map { |f| File.basename(f) }, "plot.svg"
    assert File.exist?(path)
  end
end
