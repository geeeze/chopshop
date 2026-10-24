require "test_helper"

# GET /logout (#11). The nav form posts, so DELETE has always been routed; a
# plain GET answered 404. Both now end the session. This is a single-operator
# app and the SESSION is the only state, so ending it is idempotent and safe
# from a link -- there is no server-side record to create or remove, and a GET
# that finds no session redirects to the login page it would have shown anyway.
class LogoutRouteTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def sign_in
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    get root_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success, "the session took"
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  test "GET /logout ends the session and redirects to the login page" do
    sign_in

    get logout_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path

    get root_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path,
                 "the session is gone after GET /logout"
  end

  test "DELETE /logout still ends the session" do
    sign_in

    delete logout_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path

    get root_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path
  end

  test "GET /logout with no session is still a redirect, not an error" do
    get logout_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path
  end
end
