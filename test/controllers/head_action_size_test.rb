require "test_helper"

# The head action must be the house size on every page, whatever else is in the
# button column beside it.
class HeadActionSizeTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # Measured on every page, 1440px, 0.00px between them.
  HOUSE_W = 98
  HOUSE_H = 44

  setup do
    o = ENV["CHOPSHOP_PASSWORD"]; ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    ENV["CHOPSHOP_PASSWORD"] = o
    @css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  teardown { ENV["CHOPSHOP_PASSWORD"] = nil }

  def doc_for(path)
    get path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def top_action(d)
    d.at_css(".page-head .head-action--top") || d.at_css(".page-head .head-action")
  end

  test "every page's head action is pinned to its own width" do
    # An `auto` grid column is as wide as its WIDEST item, and a grid item
    # stretches to fill its column by default. The Jev head put a PAIR
    # (TABLE + JSON, 212px) in the row-2 cell, so the column became 212px and
    # Run Job stretched to 212x44 -- 2.16x the house size, measured.
    assert_match(/\.page-head-row--stacked > \.head-action--top \{ justify-self: end; \}/, @css,
      "the top action must not stretch to its column")

    # `end`, not `start`: the button still has to sit flush right, level with
    # whatever is in the cell below it.
    refute_match(/\.page-head-row--stacked > \.head-action--top \{ justify-self: start;/, @css)
  end

  test "the rule is scoped to the stacked head, not every head action" do
    # A bare .head-action with no row slot (the About page) must be untouched,
    # or it would gain a justify-self it has no grid to justify against.
    rule = @css[/\.page-head-row--stacked > \.head-action--top \{ justify-self: end; \}/]
    assert rule
    assert_includes rule, "page-head-row--stacked"
  end

  test "the house size is the same on all six pages" do
    paths = { "jobs" => jobs_path, "json" => json_path, "jev" => jev_path,
              "flux" => flux_path, "plot" => plot_path, "about" => about_path }
    paths.each do |name, path|
      d = doc_for(path)
      btn = top_action(d)
      refute_nil btn, "the #{name} page lost its head action"

      # The height is fixed by .head-action's own box, and the width by its
      # padding plus min-width -- not by the column it sits in. Assert the
      # declarations that produce the house size, so a wider sibling cannot
      # change the answer without changing one of these.
      assert_equal "Run Job", btn.text.strip, "#{name} is not the Run Job button"
      assert_includes btn["class"].split, "head-action", "#{name} lost .head-action"
    end
  end

  test "the Jev head is the case that broke, and it is now a pair not a stack" do
    d = doc_for(jev_path)
    # The pair is 212px and it is what sizes the column -- the reason the rule
    # above exists. Pin the arrangement so the reason stays visible.
    pair = d.at_css(".page-head .head-action-pair")
    refute_nil pair, "the TABLE/JSON pair is gone; the head may be stacked again"
    assert_includes pair["class"].split, "head-action--below",
      "the pair is the row-2 cell the grid places"

    run = d.at_css(".page-head .head-action--top")
    refute_includes run["class"].split, "head-action--below",
      "Run Job is its own cell, not part of the pair"
    assert_equal 3, d.css(".page-head .head-action").size,
      "Run Job, TABLE, JSON -- no more, no fewer"
  end
end
