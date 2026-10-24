require "test_helper"

# The About page is the high-level overview of the -studio and the stack it
# sits on (-svg / -jev / -flux). Two things are easy to lose and both are pinned
# here: the nav link has a real name instead of the "???" placeholder it shipped
# with, and the Flux section names the generation layer the way the Jev card
# names the decision one.
class AboutPageTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def fetch(path)
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def about
    @about ||= fetch(about_path)
  end

  # --- the sequence, which the Run Job page offers and nothing else explains ---

  test "About explains what a sequence is and who drives the chain" do
    card = about.at_css("[data-about-sequences]")
    refute_nil card, "the sequence needs its own card: the Run Job page offers it"

    body = card.text.gsub(/\s+/, " ")
    assert_match(/ordered list/i, body, "what a sequence IS")
    assert_match(/one job/i, body, "and that the list is one job, not several")
    assert_match(/stateless/i, body,
      "the reason the chain is orchestrated here rather than by a runner")
    assert_match(/posts step one|posts step 1/i, body, "who actually drives it")
    assert_match(/step before(\s+it)?\s+produced/i, body, "the hand-off")
    assert_match(/which one it was/i, body, "and what a mid-chain failure reports")
    assert_match(/no steps key|steps\D{0,20}key/i, body,
      "back-compat: a contract without the key behaves as it always did")
  end

  test "the run story names bp as the action, and the legacy labels as still running" do
    # Found by iterating the headings rather than `at_css("h3", text: /re/)`:
    # this Nokogiri's `text:` takes a String, and a Regexp raises a TypeError
    # rather than matching nothing -- a probe bug that reads as a real absence.
    heading = about.css("h3").find { |h| h.text.include?("How you drive it") }
    refute_nil heading, "the run story heading must exist"
    story = heading.parent.text.gsub(/\s+/, " ")
    assert_match(/bp/, story, "the combined action is the one a job is filed against")
    assert_match(/still run/i, story,
      "and a legacy plot/blender label is said to keep working, rather than being written out")
  end

  test "About left the sticky header; the footer button is its home now" do
    # The header nav no longer carries About — it moved to make room, and the
    # footer's buttons are where it lives. The label is "about" (it carried the
    # literal placeholder "???" until #101); the BUTTON is large because
    # .footer-demo pads it, not because the label carries spaces (HTML collapses
    # those).
    links = about.css("nav.topbar .nav-links a").map { |a| a.text.strip }
    refute_includes links, "About", "About is out of the sticky header"
    refute_equal "about", links.last, "and the About label is not a nav entry"

    footer = about.css(".footer-demo").find { |a| a["href"] == about_path }
    refute_nil footer, "the footer carries the About button"
    assert_equal "about", footer.text.strip, "the label reads about"
    refute_match(/\A\s|\s\z/, footer.text,
      "no leading/trailing spaces in the label: the size comes from the button's " \
      "own padding, so it does not depend on HTML preserving whitespace")
  end

  test "Datasets left the header for a FLUX popup" do
    # Datasets was a REFERENCE surface in the nav; the row is for the working
    # path. It went to the page that owns its subject: a prompt is taken FROM
    # the library and generated WITH flux.
    links = about.css("nav.topbar .nav-links a").map { |a| a.text.strip }
    refute_includes links, "Datasets", "Datasets is out of the sticky header"

    # The footer's reference BUTTONS are About, Audit (#95) and Graph (#96) — all
    # three are chrome for a page that cannot act on a job, which is why none is
    # in the working-path nav.
    labels = about.css(".footer-demo").map { |a| a.text.strip }
    assert_equal %w[about audit graph], labels,
                 "the footer chrome is About, Audit and Graph, and nothing that acts on a job"
  end

  test "the Composite builder card states the vector path, not just the PNG one" do
    heading = about.css("h3").find { |h| h.text.include?("The Composite builder") }
    refute_nil heading, "the composite card must exist"
    card = heading.parent
    body = card.text.gsub(/\s+/, " ")

    assert_match(%r{POST /compose}, body,
      "a composite holding a vector layer is flattened by the svg runner, not the canvas")
    assert_match(/stays a trace/i, body, "and the card says why that matters")
    assert_includes card.css(".tech-tag").map { |t| t.text.strip }, "vectors stay vectors"
  end

  test "the four services each keep their own card after the five-section rewrite" do
    # The 2026-09-30 rewrite (103fcf3, "sixteen flat sections into the five an
    # operator needs") split the old full-width Runners / Jev / Flux stack into
    # one card per service inside a grid. Pin the new shape: all four cards
    # exist and each names what it owns.
    %w[svg flux bp jev].each do |svc|
      card = about.at_css("[data-about-svc-#{svc}]")
      refute_nil card, "the chopshop-#{svc} service card must exist"
    end
    assert_match(/generation/, about.at_css("[data-about-svc-flux]").text,
      "the flux card names its half")
    assert_match(/System One/, about.at_css("[data-about-svc-jev]").text,
      "the jev card names its half")
    refute_nil about.at_css("[data-about-made-of]"),
      "the ownership block above the cards still anchors the section"
  end

  test "the Flux section names the stack repo and the licence split" do
    body = about.text.gsub(/\s+/, " ")
    assert_includes body, "chopshop-flux"
    assert_includes body, "klein-4b"
    assert_includes body, "sdxl-turbo"
    assert_includes body, "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1"
    assert_includes body, "chopshop-svg"
    assert_includes body, "chopshop-jev"
  end

  test "the FLUX help targets still resolve to rendered help blocks" do
    targets = fetch(flux_path).css(".help-btn[data-help-target]").map { |b| b["data-help-target"] }
    assert_includes targets, FluxConf::CARDS.find { |c| c[:title] == "Service" }[:help]
    assert_includes targets, FluxConf::CHECKS[:help]

    flux = fetch(flux_path)
    [FluxConf::CARDS.find { |c| c[:title] == "Service" }[:help], FluxConf::CHECKS[:help]].each do |id|
      refute_nil flux.at_css("##{id}"), "##{id} must exist as rendered help"
      assert flux.at_css("##{id}").css("dt").any?, "##{id} must carry help entries"
    end
  end
end
