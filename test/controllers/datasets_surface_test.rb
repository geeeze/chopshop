require "test_helper"

# THE DATASETS SURFACE — one definition, two doors.
#
# It renders as a page (/datasets, which carries the head, the blurb and the
# census tiles) and it is what the FLUX page's DATASETS popup FETCHES into its
# body. The popup is a fetch rather than a second copy because the two would
# drift: the test that matters is therefore that BOTH doors serve the same
# markup, not that each renders something plausible.
#
# The nav assertions are here because that is where the move shows: Datasets left
# the sticky header (a reference surface; the row does not grow for a page that
# cannot act on a job) and its new door is the FLUX head.
class DatasetsSurfaceTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # A card that only the surface renders, at any census. Used as the shared
  # marker: if it is in both responses, both rendered the partial.
  SURFACE_MARKER = "dataset-labels-card".freeze

  def login!
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def seed_prompt!
    PromptSource.create!(dataset: "diffusiondb", prompt: "a woodcut phoenix emblem",
                         part: "part-000001", topic: "art", phrase_root: "a woodcut")
  end

  test "/datasets renders the head AND the surface" do
    login!
    seed_prompt!
    get datasets_path
    assert_response :success
    assert_includes response.body, SURFACE_MARKER, "the page renders the surface partial"
    assert_includes response.body, "prompts", "the census tiles are the page's own head"
    assert_includes response.body, 'class="topbar"', "the page is a page: it has the chrome"
  end

  test "/datasets/surface renders the surface alone, with no layout and no page head" do
    login!
    seed_prompt!
    get surface_datasets_path
    assert_response :success
    assert_includes response.body, SURFACE_MARKER

    # No wrapper: the popup supplies the head, so this response must not carry a
    # second page's chrome, title or census tiles.
    refute_includes response.body, 'class="topbar"'
    refute_includes response.body, "footer-demo"
    refute_includes response.body, "<html"
    refute_includes response.body, "page-head", "the popup's own head replaces it"

    # …and it is the SAME markup, not a summary: both doors carry the library
    # table's own class.
    assert_includes response.body, "dataset-table-card"
  end

  test "the popup fetches the surface the page renders" do
    login!
    flux = nil
    get flux_path
    assert_response :success
    flux = Nokogiri::HTML(response.body)

    trigger = flux.at_css("button[data-popup='datasets-popup']")
    refute_nil trigger, "the FLUX head carries a DATASETS trigger"
    assert_equal surface_datasets_path, trigger["data-popup-url"],
                 "and it fetches the server's own surface route, not a copy of it"
    assert_equal "DATASETS", trigger.text.strip

    dialog = flux.at_css("#datasets-popup")
    refute_nil dialog, "the dialog it opens exists on the page"
    refute_nil dialog.at_css("[data-popup-body]"),
               "with a body slot for the fetched HTML"
    refute_nil dialog.at_css("button[data-popup-close]"), "and a close control"
  end

  test "the FLUX head keeps one trigger per popup, all the same size and colour" do
    login!
    get flux_path
    doc = Nokogiri::HTML(response.body)
    pair = doc.at_css(".head-action-pair")

    triggers = pair.css("button[data-popup]")
    assert_equal %w[flux-models-popup datasets-popup flux-conf-popup],
                 triggers.map { |b| b["data-popup"] },
                 "MODELS · DATASETS · JSON, in that order"

    triggers.each do |b|
      classes = b["class"].split
      assert_includes classes, "btn-secondary", "#{b.text.strip} is a secondary action"
      assert_includes classes, "head-action", "#{b.text.strip} carries the page-action size"
      refute_includes classes, "btn-sm", "a page-level popup trigger is never the small size"
      assert b["title"].present? && b["aria-label"].present?,
             "#{b.text.strip} names its action for a tooltip and a screen reader"
    end
  end

  test "Datasets is out of the nav and reachable from FLUX" do
    login!
    get flux_path
    labels = Nokogiri::HTML(response.body).css("nav.topbar .nav-links a").map { |a| a.text.strip }
    refute_includes labels, "Datasets", "the nav is the working path, not a reference index"
    # The final Projects-redesign nav: PROJECTS is the container and the working
    # path's first entry, and Jobs/Run Job left the header -- a project's runs
    # are reached through a project, not through a global list. Datasets is
    # still absent, which is what this test is about.
    assert_equal %w[Projects JSON FLUX JEV BP], labels
  end

  test "the surface is behind the login, like the page it mirrors" do
    get surface_datasets_path
    assert_response :redirect
    assert_match %r{/login}, response.location
  end
end
