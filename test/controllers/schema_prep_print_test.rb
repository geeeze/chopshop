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

  test "Prep and Print & tolerances share one two-column block" do
    d = doc
    prep = card(d, "Prep")
    print_ = card(d, "Print")
    refute_nil print_

    # Same parent grid, so they land side by side rather than as two full-width
    # rows -- six tolerance fields under a two-control card was a lot of width
    # for very little content.
    assert_equal prep.parent["class"], print_.parent["class"]
    assert_includes prep.parent["class"], "prep-print-grid"
    assert_includes prep.parent["class"], "grid-2"
  end

  test "the two columns are genuinely equal" do
    # `1fr` is minmax(auto,1fr): Prep's two selects on one flex line gave it a
    # wide min-content, pushed the grid wider, and left Print 263px against
    # Prep's 337. minmax(0,1fr) removes the automatic floor.
    assert_match(/\.prep-print-grid \{ grid-template-columns: minmax\(0, 1fr\) minmax\(0, 1fr\); \}/, css)
  end

  test "the print fields are one column in a half-width card" do
    assert_match(/\.prep-print-grid \.print-grid \{ grid-template-columns: 1fr;/, css,
      "1fr 1fr in a 300px card left each control 87px and clipped every label")
    # The full-width page default is unchanged, so Sweep and the others are.
    assert_match(/^\.print-grid \{ display: grid; grid-template-columns: 1fr 1fr;/m, css)
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
