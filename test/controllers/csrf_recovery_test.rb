require "test_helper"

# A page the browser kept from a PREVIOUS session — restored from back/forward
# cache, or revalidated with a 304, since HTML here is deliberately
# revalidatable via `stale_when_importmap_changes` — submits an
# authenticity_token the current session never minted. Rails keeps that token
# INSIDE the session, so it can no longer be verified, and the default
# `with: :exception` strategy raises WITHOUT resetting the session: that is
# exactly what made the Log out button answer 422 with a raw error page while
# the operator stayed signed in (issue #92).
#
# These tests pin the recovery, and the first one reproduces the production
# failure faithfully rather than by handing the server a made-up token: a real
# token is read off a rendered page, the session is then rotated by a real
# logout -> login cycle, and that once-valid token is submitted. It must
# recover — no write, session ended, operator landed on the login page told
# why — instead of dead-ending in a 422.
#
# Forgery protection is OFF in the test environment
# (config/environments/test.rb), so each test switches it on once signed in and
# restores it in teardown. Signing in happens FIRST: with protection already
# on, the login POST itself would carry no token and be recovered-by-logout,
# leaving every later assertion passing for the wrong reason.
class CsrfRecoveryTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  setup do
    sign_in
    @forgery_before = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_before
  end

  test "a Log out clicked from a page of a previous session signs out instead of answering 422" do
    stale_token = authenticity_token_from_page

    # Rotate the session underneath that page, exactly as any logout does. Both
    # requests carry the tokens a real browser would, so forgery protection
    # steps out of their way for the span of the rotation ONLY — otherwise the
    # rotation would be recovered-by-logout itself, and the assertion below
    # would pass without a session ever having moved on.
    with_forgery_protection_disabled do
      delete logout_path, headers: { "User-Agent" => MODERN_UA }
      assert_response :redirect
      sign_in
    end

    delete logout_path, params: { authenticity_token: stale_token },
           headers: { "User-Agent" => MODERN_UA }

    assert_response :redirect,
                    "a token from a previous session must recover with a redirect, not a 422"
    assert_equal "/login", URI.parse(response.location).path

    # The recovery really ends the session: the next page that needs one bounces.
    get root_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path
  end

  test "the recovery tells the operator what happened" do
    delete logout_path, params: { authenticity_token: "stale" },
           headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect

    follow_redirect!
    assert_response :success
    assert_match(/previous session/, response.body)
  end

  test "a stale token on a write action performs no write and recovers the same way" do
    assert_no_difference "Job.count" do
      post jobs_path, params: { job: { name: "forged" } },
           headers: { "User-Agent" => MODERN_UA }
    end

    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path
  end

  test "a CURRENT token still logs out cleanly — the recovery masks nothing" do
    delete logout_path, params: { authenticity_token: authenticity_token_from_page },
           headers: { "User-Agent" => MODERN_UA }

    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path
    assert_nil flash[:alert], "a verified logout is not an error and must not claim one"
  end

  private

  # Forgery protection is global (a class attribute on ActionController::Base),
  # so a request that must behave like a real browser's — one carrying the
  # token the current page minted — needs it out of the way for that request
  # alone. Restored in the ensure, so no test leaks the switch to the next.
  def with_forgery_protection_disabled
    ActionController::Base.allow_forgery_protection = false
    yield
  ensure
    ActionController::Base.allow_forgery_protection = true
  end

  def sign_in
    post login_path, params: { password: "test-password" },
         headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal "/", URI.parse(response.location).path, "setup must end signed in"
  end

  # The token a rendered page would submit, read from the meta tag every layout
  # carries (csrf_meta_tags). The page this reads is the very thing that goes
  # stale in production.
  def authenticity_token_from_page
    get root_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    response.body[/meta name="csrf-token" content="([^"]+)"/, 1].presence ||
      flunk("no csrf-token meta tag on the rendered page")
  end
end
