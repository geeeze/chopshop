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

  setup do
    User.find_or_create_by!(handle: "test") { |u| u.password = "test-password" }
    Current.reset
    Current.user_handle = "test"
  end
end
