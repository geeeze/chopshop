require "test_helper"

# Session fixation. The session a browser holds while still anonymous must not be
# the session it holds once signed in: authenticate calls reset_session before
# stamping the user, so the identifier is rotated and everything the anonymous
# session carried is dropped. Without the reset, whoever could get a visitor to
# hold a session identifier of their choosing would find it promoted into a
# signed-in one.
#
# A FAILED login is what gives the browser an anonymous session to hold — it is
# the one pre-login request that writes one (the login page itself writes
# nothing) — so each test starts there rather than from a made-up identifier.
class SessionFixationTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  test "a successful login rotates the session identifier" do
    post login_path, params: { password: "not-the-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :unauthorized
    anonymous_id = session.id.to_s
    assert anonymous_id.present?,
               "the anonymous attempt must have minted a session identifier"

    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_redirected_to root_path
    signed_in_id = session.id.to_s

    assert signed_in_id.present?, "the signed-in session must have an identifier of its own"
    refute_equal anonymous_id, signed_in_id,
                 "the anonymous session identifier must not survive into the signed-in session"
    assert_equal "test", User.find(session[:user_id]).handle
  end

  # reset_session is why the ORDER matters: the flash is written after the reset,
  # so the welcome survives into the rotated session instead of being discarded
  # with the anonymous one.
  test "the welcome flash lands in the rotated session" do
    post login_path, params: { password: "not-the-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :unauthorized

    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_redirected_to root_path
    follow_redirect!
    assert_match(/welcome-overlay/, response.body,
                 "the welcome flash must survive the session reset")
  end
end
