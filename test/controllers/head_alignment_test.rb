require "test_helper"

# The three page heads must be identical. Verified in a browser:
#   jobs/runjob/json  Run Job button 44x98, delta from the title's midline 0.0px
#   json              JSON button 98px = Run Job 98px, on the line below
#   json              contract panel 450px = 30.0% of a 1500px viewport
class HeadAlignmentTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def css_without_comments
    Rails.root.join("app/assets/stylesheets/application.css").read
         .gsub(%r{/\*.*?\*/}m, "")
  end

  def head_of(path)
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body).at_css(".page-head")
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  test "all three Run Job buttons share one class, so they are one box" do
    css = css_without_comments
    action = css[/\n\.head-action \{[^}]*\}/m]
    refute_nil action, ".head-action must exist: it is what makes the three agree"

    # Measured mismatches this settles:
    #   the Jobs button is a link_to (an <a>) and rendered 45px, while the other
    #   two are <button>s at 40px -- so the heads disagreed with EACH OTHER,
    #   not only with the JSON one.
    assert_match(/height: 2\.75rem/, action,
      "an explicit height settles the <a>-vs-<button> difference")
    assert_match(/min-width: 6\.125rem/, action,
      "6.125rem is the 98px 'Run Job' already occupied, so Run Job is unchanged " \
      "and the JSON button grows to meet it")
    assert_match(/display: inline-flex/, action)

    # Every head button must actually carry it.
    [jobs_path, new_job_path, json_path].each do |path|
      head = head_of(path)
      btn = head.at_css(".head-action")
      refute_nil btn, "#{path}'s head action must carry .head-action"
      assert_equal "Run Job", btn.text.strip
    end
  end

  test "the JSON page's head is a grid so Run Job lines up with the title" do
    head = head_of(json_path)
    row = head.at_css(".page-head-row")
    # at_css matches DESCENDANTS only, so the modifier on `row` itself has to
    # be read off its class list.
    assert_includes row["class"].split, "page-head-row--stacked",
      "the JSON head must be the stacked grid variant"

    # Three SIBLINGS, not a title plus a button column. As a flex column,
    # `align-items: center` centred the 77px column, so the title sank ~10px
    # and the Run Job button (the column's top item) rode up with it.
    kids = row.element_children
    assert_equal 3, kids.size, "title + Run Job + JSON, as siblings"
    assert_nil head.at_css(".page-head-actions"),
      "the button-column wrapper is gone with the grid"

    run = head.at_css("#useSpecBtn")
    json = head.at_css("[data-popup]")
    assert_operator kids.index(json), :>, kids.index(run),
      "JSON comes after Run Job in source order, so it lands on the line below"

    css = css_without_comments
    stacked = css[/\.page-head-row--stacked \{[^}]*\}/m]
    refute_nil stacked
    assert_match(/display: grid/, stacked)
    assert_match(/grid-template-columns: 1fr auto/, stacked,
      "a 1fr/auto split so the actions stay hard right")
    assert_match(/align-items: center/, stacked,
      "row 1 centres the title against Run Job, as on every other page")
    assert_match(/\.page-head-row--stacked > \.section-title \{ grid-row: 1/, css)
    assert_match(/\.page-head-row--stacked > \.head-action:first-of-type\s*\{\s*grid-row: 1/, css)
    assert_match(/\.page-head-row--stacked > \.head-action:last-of-type\s*\{\s*grid-row: 2/, css)
  end

  test "the two head actions are the same width and JSON is not a btn-sm" do
    head = head_of(json_path)
    run = head.at_css("#useSpecBtn")
    json = head.at_css("[data-popup]")

    # `.btn-sm` is what made JSON 57px against Run Job's 98px.
    refute_includes json["class"].split, "btn-sm",
      "the smaller button styling is what this replaced"
    assert_includes json["class"].split, "head-action"
    assert_includes run["class"].split, "head-action"
  end

  test "the contract panel is 30% of the viewport" do
    css = css_without_comments
    term = css[/\.popup-terminal \{[^}]*\}/m]
    refute_nil term

    assert_match(/width: 30vw/, term, "half of the 60vw it was")
    # vw, not %: a percentage resolves against the parent's content box and
    # .popup is padded, so `width: 60%` measured 55.6% of the window.
    refute_match(/width: 30%/, term)
    assert_match(/min-width: 26rem/, term,
      "the floor drops with the width; 34rem would have pinned it at the old " \
      "size on any window under ~1800px and made the 30vw meaningless")

    # Height is untouched, as asked.
    assert_match(/max-height: 92vh/, term)
  end
end
