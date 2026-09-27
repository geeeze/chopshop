require "test_helper"

# The head's non-accent actions must carry the same weight as the accent one --
# same box AND same painted footprint.
class HeadActionParityTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  setup do
    o = ENV["CHOPSHOP_PASSWORD"]; ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    ENV["CHOPSHOP_PASSWORD"] = o
    @css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  teardown { ENV["CHOPSHOP_PASSWORD"] = nil }

  def jev_doc
    get jev_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  test "the head's plain actions paint the same footprint as the accent one" do
    # The BOX was never the problem -- 98.0 x 44.0, 0.0px delta, measured. The
    # complaint was that they looked smaller, and the cause is .btn-primary's
    # `::after` ring at inset:-3px with a blurred glow: the accent button covers
    # 104px of visible width and throws light, the quiet one covered 98.
    assert_match(/\.page-head \.btn-secondary\.head-action::after \{[^}]*inset: -3px;/m, @css,
      "the plain head action must carry the same 3px outset ring as the accent one")
    assert_match(/\.page-head \.btn-secondary\.head-action \{[^}]*background: var\(--surface-hover\)/m, @css,
      "and a solid fill, not the flat --surface the other secondary buttons use")

    # Static, not spinning: the conic gradient IS the accent's tell, and
    # "not accented" is the whole requirement.
    ring = @css[/\.page-head \.btn-secondary\.head-action::after \{([^}]*)\}/m, 1]
    refute_match(/conic-gradient/, ring, "the ring must not carry the accent gradient")
    refute_match(/animation/, ring, "nor spin like the accent ring")
  end

  test "the rule is scoped to the head, so other secondary buttons are untouched" do
    # .btn-secondary is used all over the site; only the head's are restyled.
    assert_match(/^\.page-head \.btn-secondary\.head-action/m, @css)
    # Multi-line body, so match the declaration not the opening brace.
    assert_match(/\.btn-secondary \{\s*background: var\(--surface\);/m, @css,
      "the site-wide .btn-secondary is unchanged")
  end

  test "every head action sets the same line-height" do
    # Run Job is an <a> and the others are <button>s. The link inherited the
    # body's line-height (15.36px) and the buttons fell back to the UA's
    # `normal`, so the same 9.6px type sat on a different baseline in the same
    # 44px box.
    # On the rule that already carries the box -- NOT as a trailing bare rule.
    # head_alignment_test.rb matches that one to assert the shared size, and a
    # later bare .head-action rule shadows it and fails that test. My first
    # attempt here did exactly that.
    box_rule = @css[/^\.head-action \{[^}]*\}/m]
    assert_includes box_rule, "height: 2.75rem", "matched the rule carrying the box"
    assert_includes box_rule, "line-height: 1.6"

    d = jev_doc
    actions = d.css(".page-head .head-action")
    assert_equal 3, actions.size, "Run Job, TABLE, JSON"
    tags = actions.map(&:name)
    assert_includes tags, "a"
    assert_includes tags, "button",
      "the mixed element types are why the line-height differed in the first place"
  end

  test "the accent stays on Run Job only" do
    d = jev_doc
    actions = d.css(".page-head .head-action")
    primary = actions.select { |a| a["class"].split.include?("btn-primary") }
    assert_equal 1, primary.size, "exactly one head action is the accent button"
    assert_equal "Run Job", primary.first.text.strip
  end
end
