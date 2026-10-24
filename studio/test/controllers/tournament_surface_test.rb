require "test_helper"

# THE TOURNAMENT SURFACE — one definition, two doors, exactly like the datasets
# one. It renders on /tournament (whose page head supplies the title, the layout
# toggle and the blurb) and it is what the BP page's TOURNAMENT popup FETCHES.
#
# The move is the point: the bracket was a reference PAGE in the nav, and a
# bracket is a DRAWN DOCUMENT — BP's plot half draws documents — so it belongs to
# BP's subject rather than to a header row that is for pages acting on a job.
# Same rule that kept STATUS out of the header.
class TournamentSurfaceTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # A card only the surface renders. If it is in both responses, both rendered
  # the partial.
  SURFACE_MARKER = "tournament-log".freeze

  def login!
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  test "/tournament renders the head AND the surface" do
    login!
    get tournament_path
    assert_response :success
    assert_includes response.body, SURFACE_MARKER, "the page renders the bracket"
    assert_includes response.body, "Left to right",
                    "the layout toggle is the PAGE head's, so it is not in the partial"
    assert_includes response.body, 'class="topbar"', "the page is a page: it has the chrome"
  end

  test "/tournament/surface renders the bracket alone, with no layout and no page head" do
    login!
    get surface_tournament_path
    assert_response :success
    assert_includes response.body, SURFACE_MARKER

    refute_includes response.body, 'class="topbar"'
    refute_includes response.body, "footer-demo"
    refute_includes response.body, "<html"
    refute_includes response.body, "page-head", "the popup's own head replaces it"
    # No private navigation: the layout toggle is the page's, so a popup cannot
    # strand you inside a second set of controls.
    refute_includes response.body, "view-toggle",
                    "the popup shows the layout the sim chose and offers no switch"
    assert_includes response.body, "tournament-verdict"
  end

  test "the popup fetches the surface the page renders" do
    login!
    get bp_path
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    trigger = doc.at_css("button[data-popup='tournament-popup']")
    refute_nil trigger, "BP carries a TOURNAMENT trigger"
    assert_equal surface_tournament_path, trigger["data-popup-url"],
                 "and it fetches the server's own surface route, not a copy of it"
    assert_equal "TOURNAMENT", trigger.text.strip

    dialog = doc.at_css("#tournament-popup")
    refute_nil dialog, "the dialog it opens exists on the page"
    refute_nil dialog.at_css("[data-popup-body]"), "with a body slot for the fetched HTML"
    refute_nil dialog.at_css("button[data-popup-close]"), "and a close control"

    # It sits in the PLOT half's own action pair, beside that half's other
    # references — not in the global page head, and not in the blender half.
    pair = doc.at_css("section[data-bp-half='plot'] .head-action-pair")
    refute_nil pair
    assert_equal %w[FIELDS TOURNAMENT JSON], pair.css("button[data-popup]").map { |b| b.text.strip }
    assert_nil doc.at_css("section[data-bp-half='blender'] button[data-popup='tournament-popup']")
  end

  test "the tournament page is still reachable and still does the bracket" do
    # The popup must not have replaced the page: the layout toggle, the seed and
    # a shared URL only exist here.
    login!
    get tournament_path(layout: "mirror")
    assert_response :success
    assert_includes response.body, SURFACE_MARKER
  end

  test "the surface is behind the login, like the page it mirrors" do
    get surface_tournament_path
    assert_response :redirect
    assert_match %r{/login}, response.location
  end
end
