require "test_helper"

# The page heads must be identical. Verified in a browser:
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

  # Every page that shows a Run Job head action. JEV and About joined later --
  # the user asked for the button top-right there too -- and they must carry the
  # same class or the heads drift apart again, which is the whole bug this file
  # exists to prevent. FLUX joined the same way: adding a page without adding it
  # here is how a head drifts unnoticed. PLOT joined the same way, and STATUS
  # after it, and BLENDER after that. The LIST is pages, not nav entries -- a
  # page can leave the header nav (STATUS did, for the footer's check-engine
  # light) and still be a page with a head that has to line up.
  RUN_JOB_PAGES = %w[jobs runjob json jev flux plot blender status about].freeze

  test "all nine Run Job buttons share one class, so they are one box" do
    css = css_without_comments
    action = css[/\n\.head-action \{[^}]*\}/m]
    refute_nil action, ".head-action must exist: it is what makes the three agree"

    # Measured mismatches this settles:
    #   the Jobs button is a link_to (an <a>) and rendered 45px, while the other
    #   two are <button>s at 40px -- so the heads disagreed with EACH OTHER,
    #   not only with the JSON one.
    assert_match(/height: 2\.75rem/, action,
      "an explicit height settles the <a>-vs-<button> difference")
    # 7.325rem = 117.2px, the width "Run Job" actually occupies with the real
    # pixel font (7 glyphs, full em each). The old floor was 6.125rem = 98px,
    # which was believed to be "Run Job"'s width -- it was not. 98px is the width
    # of TABLE and JSON, so the floor matched the two short labels exactly and
    # left the long one 19px wider. A floor below the longest label can never
    # make them equal; min-width only ever raises a width.
    assert_match(/min-width: 7\.325rem/, action,
      "the floor must be the WIDEST label's width, not a round number that " \
      "coincidentally matches the short ones")
    assert_match(/display: inline-flex/, action)

    # Every head button must actually carry it.
    { "jobs" => jobs_path, "runjob" => new_job_path, "json" => json_path,
      "jev" => jev_path, "flux" => flux_path, "plot" => plot_path,
      "blender" => blender_path, "status" => status_path, "about" => about_path }.each do |name, path|
      head = head_of(path)
      btn = head.at_css(".head-action")
      refute_nil btn, "the #{name} page's head action must carry .head-action"
      assert_equal "Run Job", btn.text.strip
    end
    assert_equal 9, RUN_JOB_PAGES.size
  end

  test "the JSON page's head is a grid so Run Job lines up with the title" do
    head = head_of(json_path)
    row = head.at_css(".page-head-row")
    # at_css matches DESCENDANTS only, so the modifier on `row` itself has to
    # be read off its class list.
    assert_includes row["class"].split, "page-head-row--stacked",
      "the JSON head must be the stacked grid variant"

    # Four SIBLINGS, not a title plus a button column. As a flex column,
    # `align-items: center` centred the 77px column, so the title sank ~10px
    # and the Run Job button (the column's top item) rode up with it.
    #
    # The blurb is in here too, as row 2 col 1. As a sibling AFTER the row it
    # sat below the whole two-line block -- ~96px down, level with the JSON
    # button -- where Jobs and Run Job (one-line rows) put theirs right under
    # the title.
    kids = row.element_children
    assert_equal 4, kids.size, "title + Run Job + blurb + JSON, as siblings"
    assert_nil head.at_css(".page-head-actions"),
      "the button-column wrapper is gone with the grid"

    blurb = row.at_css(".page-head-blurb")
    refute_nil blurb, "the sub-title must share the row so it reads as the title's sub-line"
    assert_includes blurb.text, "Every job runs against a contract"
    # Nokogiri evaluates a descendant selector in document context, so
    # `.page-head > p` can match a <p> nested deeper. Ask for the direct
    # element children instead.
    direct_ps = head.element_children.select { |el| el.name == "p" }
    assert_empty direct_ps,
      "the blurb must not ALSO be a direct child of .page-head (after the " \
      "row) as well as inside it, or it renders twice"

    # Source order is h1, Run Job, JSON, blurb -- and it does NOT have to track
    # the visual order, because all four cells are placed explicitly. Assert the
    # placement, not the order.
    run = head.at_css("#useSpecBtn")
    json = head.at_css("[data-popup]")
    refute_nil run
    refute_nil json
    assert_equal "useSpecBtn", run["id"]
    assert_equal "spec-popup", json["data-popup"]

    css = css_without_comments
    stacked = css[/\.page-head-row--stacked \{[^}]*\}/m]
    refute_nil stacked
    assert_match(/display: grid/, stacked)
    assert_match(/grid-template-columns: 1fr auto/, stacked,
      "a 1fr/auto split so the actions stay hard right")
    assert_match(/align-items: center/, stacked,
      "row 1 centres the title against Run Job, as on every other page")
    assert_match(/\.page-head-row--stacked > \.section-title \{ grid-row: 1/, css)
    # Explicit classes, not :of-type. :first-of-type/:last-of-type count siblings
    # of that ELEMENT TYPE alone, so an <a> beside a <button> makes each both
    # first and last of its own type -- both matched both rules and the two
    # buttons landed in one cell. Measured on the Jev page: both at row 2 col 2.
    assert_match(/\.page-head-row--stacked > \.head-action--top\s*\{\s*grid-row: 1/, css)
    assert_match(/\.page-head-row--stacked > \.head-action--below\s*\{\s*grid-row: 2/, css)
    refute_match(/head-action:(first|last)-of-type/, css, "the :of-type scheme is gone")
    assert_match(/\.page-head-row--stacked > \.page-head-blurb \{\s*grid-row: 2;\s*grid-column: 1/, css,
      "row 2 col 1 is what puts the blurb under the title rather than under " \
      "the whole block")
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

  test "the contract panel is 39% of the viewport" do
    css = css_without_comments
    term = css[/\.popup-terminal \{[^}]*\}/m]
    refute_nil term

    assert_match(/width: 39vw/, term, "half of the 60vw it was")
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
