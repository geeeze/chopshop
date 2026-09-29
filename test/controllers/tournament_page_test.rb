require "test_helper"

# The TOURNAMENT page — the one place a bracket appears, and the only page that
# shows something the studio does not do.
#
# The rule the page is built under is the studio's own: THE PIPELINE NEVER PICKS
# A WINNER. So this is a SIMULATION, and it is deliberately hollow — it touches
# no Job, no Candidate, no Event, and reads nothing owner-scoped. A page that
# quietly decided a real pick would be the worst regression this codebase could
# take, so that is asserted first and in isolation.
#
# What the page has to get right, and why each is a test rather than an eyeball:
#
#   * The MIRROR is a fold at the ROOT with the final in the CENTRE column, and
#     round one at BOTH outer edges. That is what "mirrored" means in the
#     literature (bracket-layout-spec §2a, citing BracketHQ's "Double Sided" and
#     US 2009/0098937). It is NOT per-round alternation — the zig-zag in any
#     bracket is emergent from the pairing and needs no transform at all. A page
#     that alternated the rounds would look wrong in a way that is easy to
#     mistake for right.
#   * The small-field rule: below 16 slots the plain left-to-right bracket is
#     both smaller and simpler, and the mirror is pointless. The page says so and
#     defaults accordingly rather than mirroring an 8-slot field for show.
#   * The BYE is a real slot in the grid, drawn and labelled — never a row
#     removed. A bracket that reflows to its data has no uniform pitch.
#   * The MEME CANDIDATE is present and loses, because its job is to make the
#     loser path visible.
class TournamentPageTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get tournament_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # ---- the rule ----

  test "the sim writes nothing: the page demonstrates, it does not decide" do
    # Asserted at the PAGE, not just the model, because the page is what an
    # operator reaches for when they want the studio to choose.
    before = { jobs: Job.count, events: Event.count, validations: Validation.count }
    doc
    after = { jobs: Job.count, events: Event.count, validations: Validation.count }
    assert_equal before, after,
      "loading /tournament must not record a pick, a star or a validation -- " \
      "the pipeline never picks a winner, and a page that looks like it might " \
      "is worse than no page"
  end

  test "the page says so in its own copy, not only in a comment" do
    d = doc
    text = d.text.downcase
    assert_includes text, "simulat",
      "an operator must not have to read the source to know this decides nothing"
    refute_match(/picks? (the )?winner\b(?!\s+—)/, text.sub("never picks a winner", ""))
  end

  # ---- the bracket is actually drawn ----

  test "the bracket is drawn as SVG, one card per match" do
    d = doc
    svg = d.at_css("svg.tournament-bracket")
    refute_nil svg, "the bracket has to be a real drawing, not a table"
    # The declared field is 8 names + the meme candidate = 10 entrants, padded
    # to a 16-slot grid, which is 15 matches. The count is asserted against the
    # model rather than hard-coded so a change to the field does not silently
    # pass with a stale number.
    expected = TournamentSim.new(
      PagesController::TOURNAMENT_ENTRANTS + [TournamentSim::MEME_NAME])
    expected.simulate
    assert_equal expected.matches.size, svg.css(".bracket-match").size,
      "one card per match, and the count comes from the model"
  end

  test "the mirror is the two-sided fold: round one at both outer edges" do
    d = doc
    cards = d.css("svg.tournament-bracket .bracket-match")
    xs = cards.map { |c| c["data-x"].to_f }.uniq.sort
    refute_operator xs.size, :<, 5, "a three-round fold occupies five columns"
    left_edge = xs.min
    right_edge = xs.max
    firsts = cards.select { |c| c["data-round"] == "0" }.map { |c| c["data-x"].to_f }
    assert_includes firsts, left_edge, "round one must reach the LEFT edge"
    assert_includes firsts, right_edge, "and the RIGHT edge — that is the fold"
    later = cards.select { |c| c["data-round"].to_i >= 1 }.map { |c| c["data-x"].to_f }
    assert later.all? { |x| x > left_edge && x < right_edge },
      "later rounds move inward, toward the final"
  end

  test "the final is drawn once, in the centre column" do
    d = doc
    finals = d.css("svg.tournament-bracket .bracket-match").select { |c| c["data-round"] == "3" }
    assert_equal 1, finals.size, "one final, not one per half"
    svg = d.at_css("svg.tournament-bracket")
    centre = svg["data-total-width"].to_f / 2
    assert_in_delta centre, finals.first["data-x"].to_f, TournamentSim::CARD_W / 2.0,
      "the final sits in the CENTRE column of the sheet"
  end

  test "connectors are axis-aligned elbows, never diagonals" do
    d = doc
    paths = d.css("svg.tournament-bracket path.connector")
    assert_operator paths.size, :>, 0, "a bracket is its connectors as much as its cards"
    # H and V only, no L and no bare M-pair: a connector between two vertically
    # separated cards is a horizontal stub, a vertical spine and another stub.
    # A diagonal is the visual signature of a bracket laid out by eye rather
    # than by the midpoint rule, and it is the failure this rule prevents.
    paths.each do |p|
      d_attr = p["d"].to_s
      assert_match(/\A[\d.\s,MVHL-]+z?\z/, d_attr, "connector uses only M/V/H/L: #{d_attr}")
      refute_match(/[\d.]\s+[\d.]+\s*L/, d_attr, "no diagonal segments: #{d_attr}")
    end
    # And at least one connector per non-first round, so the fold is wired.
    rounds_with_connectors = @sim_round_count = d.css("svg.tournament-bracket .bracket-match").map { |c| c["data-round"].to_i }.uniq.size
    assert_operator paths.size, :>=, rounds_with_connectors - 1
  end

  # ---- the things that go wrong ----

  test "a bye is a real, labelled slot — never a removed row" do
    # Force a non-power-of-two field so byes exist, and assert the grid is
    # unchanged and the bye is visible.
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get tournament_path(params: { entrants: %w[a b c d e] }), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    d = Nokogiri::HTML(response.body)
    svg = d.at_css("svg.tournament-bracket")
    assert_equal 8, svg["data-size"].to_i, "5 entrants still occupy an 8-slot grid"
    assert svg.css(".bracket-bye").any?, "the bye must be DRAWN, not omitted"
  end

  test "the meme candidate is drawn and is not the champion" do
    d = doc
    assert d.at_css(".bracket-meme-name"), "the joke entrant has to be named on the sheet"
    champion = d.at_css("svg.tournament-bracket")["data-champion"].to_s
    refute_equal TournamentSim::MEME_NAME, champion,
      "a simulation whose joke entrant sometimes wins is not a joke"
  end

  test "the layout defaults from the SIZE, and the page states the threshold" do
    # The default is not a matter of taste: the sim picks the layout the field
    # warrants. The declared field pads to 16, which is exactly the threshold,
    # so it folds -- and the rule is asserted against the model's own size, not
    # a hard-coded string, so widening the field does not silently pass.
    d = doc
    svg = d.at_css("svg.tournament-bracket")
    size = svg["data-size"].to_i
    assert_operator size, :>=, PagesController::MIRROR_THRESHOLD
    assert_equal "mirror", svg["data-layout"],
      "a field at or over the threshold defaults to the mirrored fold"

    # And the threshold is stated in the copy, not left mystical.
    assert_includes d.text.downcase, "16",
      "the page must state the threshold rather than leaving the default mystical"
  end

  test "both layouts are reachable, and the layout does not change the entrants" do
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get tournament_path(params: { layout: "mirror" }), headers: { "User-Agent" => MODERN_UA }
    d = Nokogiri::HTML(response.body)
    svg = d.at_css("svg.tournament-bracket")
    assert_equal "mirror", svg["data-layout"]
    mirrored = svg["data-bracket"].to_s
    get tournament_path(params: { layout: "ltr" }), headers: { "User-Agent" => MODERN_UA }
    ltr = Nokogiri::HTML(response.body).at_css("svg.tournament-bracket")["data-bracket"].to_s
    assert_equal ltr, mirrored,
      "the fold is a rendering of one bracket, never a second bracket"
  end

  # The failure this pins: a long entrant name overflowing its card. It is
  # invisible to every geometry test, because the GEOMETRY stays correct -- only
  # the paint is wrong -- and the symptom is text from one column sitting on top
  # of the next. The meme candidate's name is long enough to do it.
  test "every drawn name fits inside its card" do
    d = doc
    d.css("svg.tournament-bracket .bracket-name").each do |t|
      assert_operator t.text.length, :<=, TournamentSim::NAME_CHARS,
        "#{t.text.inspect} is longer than a #{TournamentSim::CARD_W}px card holds, " \
        "so it spills into the next column"
    end
    # And the truncation is honest: an ellipsis, not a silent cut.
    clipped = d.css("svg.tournament-bracket .bracket-name").map(&:text).find { |t| t.length == TournamentSim::NAME_CHARS }
    assert clipped.nil? || clipped.end_with?("\u2026"),
      "a clipped name ends in an ellipsis so the reader knows it was clipped"
  end

  test "the full name is still readable in the log" do
    # Truncating the DRAWING must not lose the name anywhere. The log below the
    # bracket carries it in full.
    d = doc
    log = d.at_css(".tournament-log")
    refute_nil log
    assert_includes log.text, TournamentSim::MEME_NAME,
      "the meme candidate's full name has to survive the clipping"
  end
end
