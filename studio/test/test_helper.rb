ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "tmpdir"

# Tests hash passwords at the minimum bcrypt cost — the suite seeds the test user
# in every test's transaction, and production cost would make that seconds each.
ActiveModel::SecurePassword.min_cost = true

# Reading a 7z bundle back, for the tests that assert what a DOWNLOAD contains.
#
# One implementation because two surfaces produce and serve these bundles (the
# archive service that builds one, and the controller action that streams it)
# and both are unpacked the same way. Entries are listed under one top-level
# folder — the job's stem — which is dropped, so the assertions read as the
# bundle's own layout rather than as 7z's.
# SCOPING A TEST'S FILES TO THE TEST THAT MADE THEM.
#
# The uploads directory is ONE shared, REAL directory: `storage/uploads` is where
# a live job's raster lives, so a test that writes there is writing beside the
# operator's own artwork — and a cleanup that deletes "every flux_*.png" deletes
# THEIR files, not the test's. That is not hypothetical: three helpers cleaned by
# PREFIX alone (`Dir[uploads/"flux_*.png"].each { File.delete }` in
# flux_job_test/flux_archive_test, `blender_*.png` in blender_job_test), so every
# suite run silently emptied the rasters of every live flux job on the box and
# their Jobs-index thumbnails 404'd from then on.
#
# So: snapshot at setup (`@uploads_before`), and delete only what THIS test added
# AND what matches the prefix it is responsible for -- the same shape
# run_bp_test/run_steps_test already use. A file the test did not create is never
# its business, however tempting the glob is.
module UploadsSandboxHelper
  def uploads_dir
    Rails.root.join("storage", "uploads")
  end

  def snapshot_uploads
    Dir[uploads_dir.join("*")].to_h { |path| [path, true] }
  end

  # Delete the uploads THIS test created whose basename matches `pattern`.
  # `before` defaults to the snapshot taken in setup; pass one explicitly when a
  # test has to re-base it mid-run.
  def cleanup_test_uploads(pattern, before = @uploads_before)
    before ||= {}
    Dir[uploads_dir.join("*")].each do |path|
      next if before[path]
      next unless File.basename(path).match?(pattern)
      File.delete(path)
    end
  end
end


module SevenZipTestHelper
  def unpack_7z(bytes)
    skip "7z is not installed" unless FluxArchive.seven_zip
    dir = Dir.mktmpdir("chopshop-7z-test")
    archive = File.join(dir, "job.7z")
    File.binwrite(archive, bytes)
    out = File.join(dir, "out")
    assert system(FluxArchive.seven_zip, "x", "-y", "-bd", "-o#{out}", archive,
                  out: File::NULL, err: File::NULL), "7z could not extract the bundle"

    files = Dir.glob(File.join(out, "**", "*")).select { |path| File.file?(path) }
               .to_h { |path| [ path.sub("#{out}/", "").split("/", 2).last, File.binread(path) ] }
    [ files.keys.sort, files ]
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end
end

# The password-only user system replaced the old shared CHOPSHOP_PASSWORD gate.
# Every auth-gated test logs in with password "test-password", so seed the one
# user that password matches. Current.user_handle is also set to "test" so that
# records a test creates directly (Job.create!, outside any request) are stamped
# with the same handle the signed-in session reads back — otherwise owner scoping
# would hide them from the very test that created them.
class ActiveSupport::TestCase
  include SevenZipTestHelper
  include UploadsSandboxHelper

  # The Run Job form now REQUIRES a project (jobs#create refuses a project-less
  # HTML create — a project-less job is listed nowhere under the Projects
  # workspace), so every test that files a job through the form route carries
  # one. Memoized per test; the per-test transaction rolls it back.
  def picker_project
    @picker_project ||= Project.create!(name: "picker-#{rand(1_000_000)}", is_test: false)
  end

  setup do
    User.find_or_create_by!(handle: "test") { |u| u.password = "test-password" }
    Current.reset
    Current.user_handle = "test"
    @uploads_before = snapshot_uploads
  end
end
