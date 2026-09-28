ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Tests hash passwords at the minimum bcrypt cost — the suite seeds the test user
# in every test's transaction, and production cost would make that seconds each.
ActiveModel::SecurePassword.min_cost = true

# The password-only user system replaced the old shared CHOPSHOP_PASSWORD gate.
# Every auth-gated test logs in with password "test-password", so seed the one
# user that password matches. Current.user_handle is also set to "test" so that
# records a test creates directly (Job.create!, outside any request) are stamped
# with the same handle the signed-in session reads back — otherwise owner scoping
# would hide them from the very test that created them.
class ActiveSupport::TestCase
  setup do
    User.find_or_create_by!(handle: "test") { |u| u.password = "test-password" }
    Current.reset
    Current.user_handle = "test"
  end
end
