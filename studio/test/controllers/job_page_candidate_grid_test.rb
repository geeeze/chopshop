require "test_helper"

# THE CANDIDATES' LIST/GRID SWITCH, on the job page.
#
# Twelve traces of one artwork is the case the table is bad at: the operator is
# comparing PICTURES, and a table of presets and gate pills makes you click each
# row to see anything. The grid is the same candidates as thumbnails.
#
# Two things make it safe, and both are asserted here rather than assumed:
#   * the tiles carry the same data-cs-group/data-cs-index the rows do, so a tile
#     opens the SAME stepped viewer at the same position — the playlist is read
#     from #cs-candidates' data-cs-playlist, not from DOM order;
#   * it is a SECOND rendering of one `cands` list, so the two cannot disagree
#     about what the run produced.
class JobPageCandidateGridTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  CANDIDATES = [
    { "file" => "candidate_01.svg", "hard" => 0, "advisory" => 1,
      "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" } },
    { "file" => "candidate_02.svg", "hard" => 2, "advisory" => 0,
      "layer_a" => { "status" => "fail" }, "layer_b" => { "status" => "warn" } },
    { "file" => "candidate_03.svg", "hard" => 0, "advisory" => 3,
      "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "fail" } }
  ].freeze

  def job_with_candidates
    Job.create!(name: "grid", state: "done", source_kind: "svg",
                input_path: "/data/grid.svg", stem: "grid", spec: {}, runner: "mock",
                comparison: { "candidates" => CANDIDATES })
  end

  def login!
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def doc
    get job_path(@job)
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def css
    File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  setup do
    @job = job_with_candidates
    login!
  end

  test "the candidates carry a List/Grid switch, in the list's own head" do
    d = doc
    bar = d.at_css(".cand-view-bar")
    refute_nil bar, "the switch sits in a bar above the candidates"
    assert_equal "Candidates", bar.at_css("h3").text.strip

    buttons = bar.css(".view-toggle button")
    assert_equal %w[List Grid], buttons.map { |b| b.text.strip }
    assert_equal %w[list grid], buttons.map { |b| b["data-cand-view"] }
    assert_equal %w[true false], buttons.map { |b| b["aria-pressed"] },
                 "list is the default view, so it starts pressed"

    # The same segmented pair the Jobs index uses, and NOT the page-action box:
    # this is a display mode, not an action on the job.
    buttons.each do |b|
      assert_includes b["class"].split, "view-toggle-btn"
      assert_includes b["class"].split, "btn-secondary"
      refute_includes b["class"].split, "head-action",
                      "a view switch is not a head action (2.75rem × 7.325rem)"
      assert b["title"].present?, "and it says what it does"
    end
  end

  test "the grid is one tile per candidate, built from the same list as the table" do
    d = doc
    tiles = d.css("#cs-cand-grid .cand-tile")
    rows = d.css("#cs-cand-list table.candidates tbody tr")
    assert_equal CANDIDATES.size, tiles.size, "one tile per candidate"
    assert_equal rows.size, tiles.size, "and the same count as the table's rows"

    CANDIDATES.each_with_index do |c, i|
      tile = tiles[i]
      assert_equal c["file"], tile["data-cs-title"]
      assert_equal i.to_s, tile["data-cs-index"], "tile #{i} carries its list position"
      assert_equal "cs-candidates", tile["data-cs-group"]
      assert_equal file_job_path(@job, name: c["file"]), tile["data-cs-url"]
      assert_equal ApplicationController.helpers.proof_name(c["file"]),
                   tile.at_css(".cand-tile-name").text.strip,
                   "the tile is labelled with the same proof name the table shows"
      gates = tile.css(".cand-tile-gates .status-pill").map { |p| p["class"].to_s }
      assert_equal 2, gates.size, "both gate statuses ride on the tile"
      assert gates[0].include?("status-#{c.dig('layer_a', 'status')}")
      assert gates[1].include?("status-#{c.dig('layer_b', 'status')}")
      assert tile.at_css("img")["src"].present?, "a tile is a picture"
    end
  end

  test "the grid is hidden until asked for, and the table is the default" do
    d = doc
    # `hidden` is a boolean attribute: present means "" (so `.present?` is false)
    # — ask the node whether it carries the attribute at all.
    assert d.at_css("#cs-cand-grid").key?("hidden"), "the grid starts hidden"
    refute d.at_css("#cs-cand-list").key?("hidden"), "and the table is what you see"

    # The one playlist stays the view's, on the element that owns it: the tiles
    # are a second DOOR to it, not a second playlist.
    assert_equal 1, d.css("[data-cs-playlist]").size
    owner = d.at_css("[data-cs-playlist]")
    assert_equal "cs-candidates", owner["id"]
    refute_nil d.at_css("#cs-cand-grid")
  end

  test "the switch has its own storage key, not the Jobs index's" do
    src = File.read(Rails.root.join("app/views/jobs/show.html.erb"))
    assert_match(/chopshop\.candidatesView/, src, "its own key")
    refute_match(/chopshop\.jobsView/, src,
                 "sharing the index's key would flip the JOBS list from this page")
    assert_match(/window\.__csCandView/, src, "bound once, delegated")
    assert_match(/turbo:load/, src, "and re-applied after a Turbo swap")
  end

  # ---- the sizes: previews must not outgrow the results ----

  test "source previews are bounded, so no artifact can set the page's size" do
    stack = css[/\.source-stack \{[^}]*\}/]
    refute_nil stack
    assert_match(/max-width:\s*100%/, stack,
                 "the source stack never exceeds its column")

    wide = css[/\.variation-tile img \{[^}]*\}/]
    refute_nil wide
    assert_match(/max-height:\s*220px/, wide,
                 "a 1200px plot SVG and a 480px frame both read as previews, not as the page")

    aside = css[/\.results-side \.source-stack \.pv-tile \{[^}]*\}/]
    refute_nil aside
    assert_match(/max-width:\s*132px/, aside,
                 "beside the candidates table the source tiles are thumbnails, " \
                 "not column-wide slabs that out-size the table they are provenance for")
  end

  test "a candidate tile is sized like the table's own row thumbnail" do
    tile = css[/\.cand-tile img \{[^}]*\}/]
    refute_nil tile
    assert_match(/aspect-ratio:\s*1\s*\/\s*1/, tile)
    assert_match(/object-fit:\s*contain/, tile)

    # And the grid can never be wider than the card it lives in.
    grid = css[/\.cand-grid \{[^}]*\}/]
    refute_nil grid
    assert_match(/grid-template-columns:\s*repeat\(auto-fill,\s*minmax\(/, grid)
  end
end
