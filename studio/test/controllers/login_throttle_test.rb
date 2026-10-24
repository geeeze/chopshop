require "test_helper"

# The in-app login throttle — `rate_limit to: 10, within: 3.minutes, only:
# :authenticate` in ApplicationController. It sits beside the fail2ban jail that
# reads log/chopshop-auth.log: fail2ban drops the ADDRESS at the firewall, this
# refuses the REQUEST in the app, and neither one locks the account — both states
# expire on their own.
#
# Attempts are counted per remote address in the cache store, so each test drives
# its addresses explicitly (remote_addr=) instead of sharing the session default.
class LoginThrottleTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # TEST-NET-3 (RFC 5737) — reserved for documentation, never a real host.
  THROTTLED_IP = "203.0.113.10"
  OTHER_IP = "203.0.113.11"

  # An approximation of fail2ban's own <HOST> expansion, so the shipped filter
  # can be exercised with Ruby's Regexp instead of a hand-copied pattern. Ruby
  # spells the named group (?<host>…) where fail2ban spells it (?P<host>…) —
  # same pattern, its syntax. This form matches IPv4, host names and the
  # ::ffff:-mapped form; the shipped filter also matches bare IPv6 literals,
  # which is verified with fail2ban-regex rather than duplicated here.
  FAIL2BAN_HOST = '(?:::f{4,6}:)?(?<host>[\w.\-^_]+)'.freeze

  def attempt(password, ip:)
    self.remote_addr = ip
    post login_path, params: { password: password }, headers: { "User-Agent" => MODERN_UA }
  end

  test "eleven rapid failures from one address are throttled, another address is not" do
    10.times { attempt("not-the-password", ip: THROTTLED_IP) }
    assert_response :unauthorized, "the first ten attempts must still be ordinary 401s"

    attempt("not-the-password", ip: THROTTLED_IP)
    assert_response :too_many_requests, "the eleventh attempt from the same address must be throttled"
    assert_match(/Too many login attempts/, response.body,
                 "the throttled response must carry a plain retry message")
    assert_nil session[:user_id], "a throttled attempt must not sign anyone in"

    attempt("not-the-password", ip: OTHER_IP)
    assert_response :unauthorized, "a different address must still get an ordinary 401"
  end

  test "a successful login still works after failures inside the limit" do
    3.times { attempt("not-the-password", ip: THROTTLED_IP) }
    assert_response :unauthorized

    attempt("test-password", ip: THROTTLED_IP)
    assert_redirected_to root_path
    assert session[:user_id].present?, "the right password must still sign in under the limit"
    assert_equal "test", User.find(session[:user_id]).handle
  end

  test "a wrong password is still a plain 401" do
    attempt("not-the-password", ip: THROTTLED_IP)
    assert_response :unauthorized
    assert_nil session[:user_id]
    assert_match(/Wrong password/, response.body)
  end

  # The filter ships in the repo, so it is pinned against the line the app
  # actually writes rather than against a copy of the format kept in the test.
  test "the shipped fail2ban filter matches the line the app writes" do
    attempt("not-the-password", ip: THROTTLED_IP)
    assert_response :unauthorized

    log = Rails.root.join("log/chopshop-auth.log")
    lines = log.readlines.grep(/chopshop login failed for/)
    flunk("the failed attempt was not written to log/chopshop-auth.log") if lines.empty?

    filter = Rails.root.join("config/fail2ban/filter.d/chopshop-auth.conf").read
    failregex = filter[/^failregex\s*=\s*(.+)$/, 1]
    flunk("config/fail2ban/filter.d/chopshop-auth.conf declares no failregex") if failregex.blank?

    assert_match Regexp.new(failregex.gsub("<HOST>", FAIL2BAN_HOST)), lines.last,
                 "the shipped filter must match the line the app writes"
  end
end
