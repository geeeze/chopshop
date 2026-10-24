require "test_helper"

# The login page must load only the shared core bundle, not the whole site
# bundle. The layout picks the importmap entry by auth state: unauth'd ->
# "login" (aether-core only), authed -> "application" (aether = core + site).
class LoginJsGateTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  setup do
    @original_password = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
  end

  teardown do
    ENV["CHOPSHOP_PASSWORD"] = @original_password
  end

  test "login page emits the login entry, not the application entry" do
    get login_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_match(/import "login"/, response.body,
      "the login page must load the login entry point")
    refute_match(/import "application"/, response.body,
      "the login page must NOT load the full site bundle")
  end

  test "authenticated pages emit the application entry" do
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get root_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_match(/import "application"/, response.body,
      "authenticated pages load the full site entry point")
  end
end
