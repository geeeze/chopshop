require "test_helper"

# THE FAVOURITE CONTROL IS A SCISSOR ORB.
#
# It was a star, then it was a scissor on the shop's own disc: the brand gradient
# face plus the login sunspot layers, at REDUCED intensity (a row of these at the
# hero's strength reads as a row of beacons — the same judgement .cs-proof-btn
# already carries for the Proof buttons).
#
# Three properties are load-bearing and each is pinned here:
#
#   1. The ICON is a scissor SVG, not a text glyph and not a star. Glyphs fall
#      back inconsistently across the pixel/Inter stack, which is why every other
#      row-action icon is an inline SVG.
#   2. The orb rules set NO width/height. Its size is the surface's — 1.35rem on
#      the tiles, 2rem in the rows — so a rule here would silently resize one of
#      them. Measured live: 21.6px (tiles) and 32px (rows).
#   3. The word-carrying variant is NOT an orb. The preview popup clones the
#      template and labels it; a word cannot live inside a circular disc.
#
# The shared recipe is the point of the intensity: this control, the login hero
# and the drawer's close all build from the SAME .login-sun-* markup, so none of
# them can drift into a second look.
class FavouriteOrbTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  PARTIAL = "app/views/scrapbook/_fav_button.html.erb".freeze
  LAYOUT = "app/views/layouts/application.html.erb".freeze
  CSS = "app/assets/stylesheets/application.css".freeze
  SUN_LAYERS = %w[login-sun-layer login-sun-burst login-sun-pink].freeze

  def sign_in
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # A RULE'S OWN COMMENT sits between its selector's `{` and its declarations, so
  # a naive `/\A\.fav-orb \{.*?\}/` misses everything and the nil capture reads as
  # "the rule says nothing". Strip comments first, then read the block.
  def css_rule(selector)
    css = File.read(Rails.root.join(CSS)).gsub(%r{/\*.*?\*/}m, "")
    match = css.match(/^\s*#{Regexp.escape(selector)}\s*\{(?<body>[^}]*)\}/m)
    refute_nil match, "#{selector} has no rule"
    match[:body]
  end

  def partial_source
    File.read(Rails.root.join(PARTIAL))
  end

  test "an icon-only favourite renders as a scissor orb" do
    sign_in
    job = Job.create!(name: "orb", state: "done", source_kind: "raster", runner: "mock",
                      input_path: "/data/x.png", stem: "orb", spec: {},
                      comparison: { "candidates" => [ { "file" => "candidate_01.svg",
                                                        "sweep" => {}, "hard" => 0,
                                                        "advisory" => 0, "passed" => true } ] })
    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    orbs = doc.css("button.fav-orb[data-scrap-favourite]")
    refute_empty orbs, "the icon-only favourite must carry the orb class"

    svg = orbs.first.at_css("svg")
    refute_nil svg
    assert_equal 2, svg.css("circle").size,
      "the scissor's two handle rings: the icon is the shop's mark, not a star"
    assert_empty svg.css("polygon"),
      "and no star polygon survives on it"
    assert_equal 3, svg.css("line").size, "the two blades and the crossing"

    # The living light, present as the same three layers the login orb uses.
    light = orbs.first.at_css(".fav-orb-light")
    refute_nil light, "the disc carries the sunspot wrapper"
    SUN_LAYERS.each do |layer|
      assert light.at_css(".#{layer}"), "the orb shares the login recipe: #{layer}"
    end
  end

  test "the word-carrying variant is a pill, not an orb" do
    sign_in
    # RE-POINTED (2026-10 Projects redesign): was `get jobs_path`, and GET /jobs
    # was deleted along with app/views/jobs/index.html.erb -- the jobs list now
    # lives on the project workspace. #csFavTemplate is rendered by the
    # LAYOUT (app/views/layouts/application.html.erb), so the workspace page
    # (the surface the jobs list actually lives on now) is where to read it.
    project = Project.create!(name: "fav-orb-workspace", is_test: true)
    get project_path(project), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    # The popup clones #csFavTemplate, so what the template renders is what the
    # popup shows. Its clone then sets its own class list, dropping the orb.
    tpl = doc.at_css("#csFavTemplate")
    refute_nil tpl, "the popup's template is rendered into the layout"
    button = tpl.at_css("button[data-scrap-favourite]")
    refute_nil button
    refute_includes button["class"].split, "fav-orb",
      "a labelled favourite is a pill: a word cannot live inside a circular disc"
    refute_nil button.at_css(".fav-word"), "and it carries its visible word"

    # aether.js sets the popup's own class list when it clones the template. Pin
    # the list, because dropping `fav-orb` there is what keeps the pill.
    js = File.read(Rails.root.join("app/javascript/aether.js"))
    assert_match(/cs-preview-fav fav-btn/, js,
      "the popup's clone keeps its own pill class list")
  end

  test "the orb rules set no dimensions, so each surface keeps its own size" do
    body = css_rule(".fav-orb")
    refute_match(/(?<![-\w])width\s*:/, body,
      "the orb must not size itself: the tiles are 1.35rem and the rows 2rem, " \
      "and a width here silently resizes one of them")
    refute_match(/(?<![-\w])height\s*:/, body, "same for height")
    assert_match(/border-radius:\s*50%/, body, "the disc is round")
    assert_match(/linear-gradient\(135deg,\s*var\(--primary\),\s*var\(--secondary\)\)/, body,
      "the same face the login hero and the drawer's close wear")
  end

  test "the orb's light is quieter than the login hero's" do
    light = css_rule(".fav-orb-light")
    opacity = light[/opacity:\s*([\d.]+)/, 1]
    refute_nil opacity, "the wrapper carries the intensity"
    assert_operator opacity.to_f, :<, 1.0,
      "dialled down from the hero: a row of these at hero strength reads as beacons"
    assert_operator opacity.to_f, :>, 0.0, "but still lit"
  end

  test "the favourite orb and the frame's cycle orb share one recipe" do
    # Both build from the login sunspot layers, so the effects cannot diverge.
    # This asserts the FRAME orb still carries them: it is the reference the
    # favourite orb was matched to, and a later edit could quietly strip it.
    layout = File.read(Rails.root.join(LAYOUT))
    close = layout[/scrapbook-close.*?<\/button>/m]
    refute_nil close, "the frame's cycle orb (matched through its halo class)"
    SUN_LAYERS.each do |layer|
      assert_includes close, layer,
        "the cycle orb lost #{layer}: the two have drifted apart"
    end
    assert_includes close, "scrapbook-close-orb", "its halo span is part of the look"

    # And the cycle orb keeps its SMALLER size, which the ask called out.
    assert_match(/\.frame-cycle\s*\{[^}]*width:\s*1\.5rem/m,
      File.read(Rails.root.join(CSS)).gsub(%r{/\*.*?\*/}m, ""),
      "the cycle orb stays 1.5rem: matching effects, not matching size")
  end
end
