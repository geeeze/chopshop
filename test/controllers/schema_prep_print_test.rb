require "test_helper"

# The JSON page's Prep and Print & tolerances cards, and where Prep's prose went.
class SchemaPrepPrintTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get json_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def css
    File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  def card(d, name)
    d.css(".card").find { |c| c.at_css("h3")&.text.to_s.include?(name) }
  end

  test "the big info text is off the Prep card" do
    prep = card(doc, "Prep")
    refute_nil prep
    assert_nil prep.at_css(".prep-note"),
      "the prose on the card was a near-verbatim subset of what the ? already " \
      "said, which is why it read as noise -- it belongs in the popup"
    # The card is now just the two controls.
    assert_equal %w[f_invert f_invert_mode], prep.css("select").map { |s| s["id"] }
    assert_operator prep.text.strip.length, :<, 200
  end

  test "the ? carries everything the card stopped saying" do
    d = doc
    prep = card(d, "Prep")
    btn = prep.at_css(".help-btn")
    refute_nil btn
    assert_equal "help-prep", btn["data-help-target"]
    assert_includes btn["aria-label"].to_s, "Prep"

    panel = d.at_css("#help-prep")
    refute_nil panel
    t = panel.text
    # Every claim the removed .prep-note made, still made somewhere.
    assert_includes t, "photometric", "both invert modes are explained"
    assert_includes t, "negative"
    assert_includes t, "twin", "and what the twin is"
    assert_includes t, "knockout", "and when negative is the right choice"
  end

  test "Prep and Print & tolerances share ONE column, Print below Prep" do
    d = doc
    prep = card(d, "Prep")
    print_ = card(d, "Print")
    refute_nil print_

    # One block, one column, Print second. DOM order is Prep then Print, so a
    # single-column grid puts them in that order without any ordering CSS.
    assert_equal prep.parent["class"], print_.parent["class"]
    assert_includes prep.parent["class"], "prep-print-grid"
    assert_operator prep.parent.children.index(prep), :<, print_.parent.children.index(print_),
      "Prep comes first in the block, so the grid renders Print below it"
  end

  test "the block is ONE track of the page grid, not capped again" do
    # Side by side gave each card half a page. The block is already one track of
    # a two-column page grid, so it takes that track whole -- measured 624px at a
    # 1440px window. A max-width on top of that capped it to 300px, which is
    # what the first attempt did.
    block_rule = css[/(\.prep-print-grid \{[^}]*\})/, 1].to_s
    assert_includes block_rule, "grid-template-columns: minmax(0, 1fr);"
    refute_includes block_rule, "max-width",
      "it already sits in one track; capping it again halves it twice"
    assert_match(/\.prep-print-grid > \.card \{ min-width: 0; \}/, css,
      "minmax(0,1fr) plus min-width:0, so a wide min-content child cannot " \
      "push the track open -- that is what made Print 263px against Prep's 337")
  end

  test "the tolerance fields are two-up in the block, like everywhere else" do
    # Collapsing the inner grid to one column was a fix for a 300px card. The
    # card is 624px now, so the global 1fr 1fr applies and each control is
    # 267px -- measured, not assumed.
    assert_match(/^\.print-grid \{ display: grid; grid-template-columns: 1fr 1fr;/m, css,
      "the full-width page default is unchanged, so Sweep and the rest are too")
    inner = css[/(\.prep-print-grid \.print-grid \{[^}]*\})/, 1].to_s
    assert_includes inner, "min-width: 0;"
    refute_includes inner, "grid-template-columns: 1fr;",
      "and this block no longer forces a single column"
  end

  test "a long single-word label can break rather than clip" do
    assert_match(/\.prep-print-grid \.field label \{ overflow-wrap: anywhere; \}/, css,
      '"ink_merge_tolerance" is one 20-character word with nowhere to break')
  end

  test "the controls themselves are untouched" do
    p = card(doc, "Print")
    %w[f_dpi f_ink_limit f_white_ink f_ink_merge].each do |id|
      refute_nil p.at_css("##{id}"), id
    end
    prep = card(doc, "Prep")
    assert_equal "true", prep.at_css("#f_invert option[selected]")["value"]
    assert_equal "photometric", prep.at_css("#f_invert_mode option[selected]")["value"]
  end
end
