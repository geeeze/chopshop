require "test_helper"

# The footer's REPORT A PROBLEM button: an operator with an account describes
# what happened, what they expected, or a suggestion, and it becomes a GitHub
# issue carrying a triage label.
#
# NOTHING HERE TALKS TO GITHUB. Every test stubs GithubIssues.create and asserts
# on the ARGUMENTS it was handed, because a suite that filed real issues into the
# project's tracker on every run would be unusable and a suite that trusted a
# live HTTP call would pass on a box with a working token and fail on one
# without. The one thing that must be tested for real is the SHAPE of what the
# controller builds -- the title prefix, the three sections, the context table --
# because that is the part GitHub never sends back.
#
# The tests below pin four guarantees that each have a real failure mode:
#   * the popup is on EVERY page and the button that opens it exists, so the
#     feature is reachable from wherever the operator hit the problem;
#   * it does NOT leak onto /login (the footer renders there too);
#   * the form asks for "what I expected" as its own box, because a single
#     textarea cannot prompt for the second half of a bug report;
#   * an unconfigured box says so, rather than accepting a careful report that
#     cannot be sent.
class BugReportTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  setup do
    @original_token = ENV["CHOPSHOP_GITHUB_TOKEN"]
    ENV["CHOPSHOP_GITHUB_TOKEN"] = "test-token"
    o = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    ENV["CHOPSHOP_PASSWORD"] = o
    # The default operator so the form is never filled with another handle's.
    @captured = nil
  end

  teardown do
    ENV["CHOPSHOP_GITHUB_TOKEN"] = @original_token
  end

  # Capture what the client was asked to create, without a network call.
  #
  # A hand-rolled singleton swap rather than `Object#stub`: minitest 6 dropped
  # minitest/mock, and mocha is not in this bundle. The original is restored in
  # an ensure so one test's stub cannot leak into the next -- a leaked stub would
  # make a later test pass for the wrong reason, which is worse than no stub.
  def stub_github(result: GithubIssues::Result.new(number: 42,
                                                  url: "https://github.com/geeeze/chopshop-studio/issues/42",
                                                  title: "t"))
    singleton = GithubIssues.singleton_class
    singleton.alias_method(:__real_create, :create)
    replacement = result.respond_to?(:call) ? result : ->(**args) { @captured = args; result }
    singleton.define_method(:create) do |**args|
      @captured = args
      replacement.call(**args)
    end
    yield
  ensure
    singleton.alias_method(:create, :__real_create)
    singleton.remove_method(:__real_create)
  end

  def report_params(overrides = {})
    { report: {
      kind: "bug",
      summary: "Trace stalls on the JSON page",
      happened: "I pressed Trace and nothing came back.",
      expected_behaviour: "A candidate list within a minute.",
      details: "Happens every time."
    }.merge(overrides) }
  end

  def post_report(overrides = {})
    stub_github do
      post bug_reports_path, params: report_params(overrides),
                            headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
    end
  end

  # ---- reachability ----

  test "every signed-in page carries the button that opens the popup" do
    %w[/ /jobs /json /about /status /flux].each do |path|
      get path, headers: { "User-Agent" => MODERN_UA }
      assert_response :success, "#{path} did not render"
      doc = Nokogiri::HTML(response.body)
      button = doc.at_css('button[data-popup="bug-report-popup"]')
      refute_nil button, "#{path}: the report button is missing -- an operator " \
                         "reports from wherever they hit the problem"
      refute_nil doc.at_css("#bug-report-popup"), "#{path}: the popup itself is missing"
    end
  end

  test "the popup is the app's standard shape, with the one close mechanism" do
    get root_path, headers: { "User-Agent" => MODERN_UA }
    doc = Nokogiri::HTML(response.body)
    popup = doc.at_css("#bug-report-popup")
    refute_nil popup
    assert_includes popup["class"].split, "popup"
    assert_equal 1, popup.css(".popup-head [data-popup-close]").size,
      "exactly one close, and it is the x in the head like every other popup"
    refute_nil popup.at_css(".popup-panel > .popup-head")
    refute_nil popup.at_css(".popup-panel > .popup-body")
    assert popup.attribute("hidden"),
      "it ships hidden: without the attribute it covers the page on every load"
  end

  test "nothing about the report leaks onto the login page" do
    delete logout_path
    get login_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    assert_nil doc.at_css("#bug-report-popup"),
      "the popup renders inside `if current_user`; the footer bar does NOT, so a " \
      "form that filed issues as whoever happened to be signed in would be public"
    assert_nil doc.at_css(".maint-light")
  end

  # ---- what the operator is asked for ----

  test "the form asks for what happened AND what was expected, separately" do
    get root_path, headers: { "User-Agent" => MODERN_UA }
    doc = Nokogiri::HTML(response.body)
    # The form is in the LAYOUT, so it is in every page's DOM at once -- what
    # must be asserted is that it lives INSIDE the hidden popup, not that it is
    # absent from the document.
    form = doc.at_css("#bug-report-popup #bug-report-form")
    refute_nil form
    assert_equal bug_reports_path, form["action"]

    # The two halves of a bug report are two fields, not one box. A reporter
    # given one textarea writes a description of what they did and stops.
    %w[report_happened report_expected_behaviour].each do |id|
      refute_nil form.at_css("##{id}"), "#{id} must exist: it is half the report"
    end
    # And a label bound to each, not just an id.
    %w[report_happened report_expected_behaviour].each do |id|
      label = form.at_css("label[for='#{id}']")
      refute_nil label, "#{id} needs a label -- a placeholder is not one"
    end
    # The kinds are the operator's vocabulary, not a developer's.
    assert_equal BugReportsController::KINDS.values,
                 form.css("#report_kind option").map(&:text)
  end

  test "the form carries the hook the submit handler matches, and the handler exists" do
    get root_path, headers: { "User-Agent" => MODERN_UA }
    form = Nokogiri::HTML(response.body).at_css("#bug-report-form")

    # The pair that must agree. `data: { report: "form" }` in the view emits
    # `data-report`, which the handler's `closest('[data-report-form]')` does not
    # match: the browser then submits natively, the operator lands on a JSON body
    # and every word they typed is lost. Structure is all Rails can check, and
    # structure is exactly where this breaks.
    refute_nil form["data-report-form"],
      "the form must carry data-report-form -- the attribute aether.js's " \
      "submitReport handler matches on. Its VALUE is irrelevant: `true` is " \
      "what Rails emits for a valueless data flag"
    assert_nil form["data-report"],
      "and not the singular: Rails turns `data: { report: ... }` into " \
      "data-report, which the handler cannot see"

    js = File.read(Rails.root.join("app/javascript/aether.js"))
    # Both halves of the wiring: the selector it matches, and the fact that it is
    # actually bound. An unwired handler passes a test that only greps for the
    # selector's presence.
    assert_includes js, "closest('[data-report-form]')"
    assert_match(/document\.addEventListener\('submit'/, js)
    assert_match(/function wireReportForm\(\) \{\s*\n\s*if \(reportFormBound\) return;\s*\n\s*reportFormBound = true;/, js,
      "the handler must bind ONCE behind its guard: a second binding after a " \
      "Turbo visit would file every report twice")
    assert_includes js, "wireReportForm();", "and it must be called on load"

    # The one close mechanism and the aria-live result line the handler writes to.
    result = Nokogiri::HTML(response.body).at_css("[data-report-result]")
    refute_nil result
    assert_equal "status", result["role"]
    assert_equal "polite", result["aria-live"]
    refute_match(/display:\s*none/, File.read(Rails.root.join("app/assets/stylesheets/application.css"))[/\.report-result \{[^}]*\}/m].to_s,
      "an empty live region is never announced when it fills")
  end

  test "the three textareas are boxes, not 200px-tall JSON editors" do
    css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))
    assert_match(/\.popup-report textarea \{ min-height: 0; \}/, css,
      "the global .field textarea min-height is 200px for the spec editors; " \
      "inherited here it pushed the SUBMIT button below the popup's scroll fold")
    # Regexp.new, not a literal: the literal's `{`/`}` delimiters make Ruby's
    # parser read the pattern as an expression, and the failure is a syntax
    # error far from the line that caused it.
    sticky = Regexp.new("\\.report-actions \\{[^}]*position: sticky;", Regexp::MULTILINE)
    assert_match(sticky, css,
      "the send row stays reachable when the form does scroll")
  end

  # ---- what the controller builds ----

  test "a report is filed with the kind's label and a readable title" do
    post_report
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal 42, body["number"]

    assert_equal "bug", @captured[:kind]
    assert_equal "Bug: Trace stalls on the JSON page", @captured[:title]
  end

  test "each kind prefixes its own title and picks its own label" do
    { "expected" => "Expectation", "suggestion" => "Suggestion" }.each do |kind, prefix|
      post_report(kind: kind)
      assert_equal "#{prefix}: Trace stalls on the JSON page", @captured[:title]
    end
  end

  test "an unknown kind falls back to the default instead of refusing the report" do
    post_report(kind: "invented-by-a-stale-tab")
    assert_response :success
    assert_equal "bug", @captured[:kind],
      "the report matters more than the kind; it must still be filed"
  end

  test "the body carries the three sections and the facts only the box knows" do
    post_report
    body = @captured[:body]
    assert_includes body, "## What happened"
    assert_includes body, "I pressed Trace and nothing came back."
    assert_includes body, "## What I expected"
    assert_includes body, "A candidate list within a minute."
    assert_includes body, "## Anything else"

    # The reporter cannot see these and would otherwise be chased for them.
    assert_includes body, "| Account | `#{User.first&.handle}`", "who reported it"
    assert_includes body, "| Page |", "which page they were on"
    assert_includes body, "| Studio version |", "which build"
    assert_includes body, MODERN_UA, "which browser"
  end

  test "an empty box says so rather than leaving a bare heading" do
    post_report(details: "")
    assert_includes @captured[:body], "_(not given)_",
      "a heading with nothing under it reads as a broken report"
  end

  test "a summary longer than GitHub's title cap is truncated, not refused" do
    post_report(summary: "x" * 400)
    assert_response :success
    assert_operator @captured[:title].length, :<=, 256,
      "GitHub refuses the whole issue past 256 characters in the title, so a " \
      "long paste must not lose the report"
  end

  test "a blank summary still produces a title" do
    post_report(summary: "   ")
    assert_equal "Bug: Untitled report", @captured[:title]
  end

  # ---- the failure paths, which are the ones that cost a reporter their words ----

  test "an unconfigured box refuses to file and says why, without a network call" do
    ENV.delete("CHOPSHOP_GITHUB_TOKEN")
    # Deliberately NOT stubbed: `create` raises Unconfigured on its own before it
    # builds a request, so this exercises the real guard rather than a
    # stand-in for it. A stub here would pass with the guard deleted.
    post bug_reports_path, params: report_params,
                          headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
    assert_response :unprocessable_entity
    assert_equal false, JSON.parse(response.body)["ok"]
    assert_match(/CHOPSHOP_GITHUB_TOKEN/, JSON.parse(response.body)["error"])
  end

  test "the popup warns when filing is not configured, and the button's title says so" do
    ENV.delete("CHOPSHOP_GITHUB_TOKEN")
    get root_path, headers: { "User-Agent" => MODERN_UA }
    doc = Nokogiri::HTML(response.body)
    refute_nil doc.at_css(".report-unconfigured"),
      "an operator must be told before typing, not after"
    assert_includes doc.at_css(".maint-light")["title"], "not configured"
  end

  test "a GitHub failure is reported as data, and the response is not a redirect" do
    stub_github(result: ->(**) { raise GithubIssues::Error, "GitHub 401: Bad credentials" }) do
      post bug_reports_path, params: report_params,
                            headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
    end
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal false, json["ok"]
    assert_includes json["error"], "Bad credentials",
      "GitHub's own message is what the operator can act on"
  end

  # ---- access ----

  test "an anonymous request cannot file" do
    delete logout_path
    stub_github do
      post bug_reports_path, params: report_params, headers: { "User-Agent" => MODERN_UA }
    end
    assert_redirected_to login_path
    assert_nil @captured, "nothing may be filed for an anonymous request"
  end

  test "there is no GET route: a report is filed, not listed" do
    # Recognised, not requested: the assertion is about the ROUTE TABLE, and a
    # bare `get` in a test env is swallowed by the exception app and answers
    # whatever status that renders rather than raising.
    error = assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/reports", method: :get)
    end
    assert_match(/reports/i, error.message)
    # The POST is real, and it is the only verb on it.
    assert_equal({ controller: "bug_reports", action: "create" },
                 Rails.application.routes.recognize_path("/reports", method: :post)
                        .symbolize_keys.slice(:controller, :action))
  end
end
