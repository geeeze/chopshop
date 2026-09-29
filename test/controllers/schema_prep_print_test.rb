require "test_helper"

# The JSON page's two COLUMNS of cards: what the job IS on the left (its
# contract, the tolerances it is measured against, its colour policy), and what
# the TRACER does on the right (prep, the raster-side benches, the sweep).
#
# This was one flow grid across the page, and these tests are the ones that
# pinned that arrangement. They are rewritten for the new one, but the CSS
# guarantees they carried are kept, because each was a fix for a real bug: one
# track per column (a nested block capped twice measured 300px), min-width: 0
# (a wide min-content child pushed the track open and left Print at 263px
# against Prep's 337), and the long-label wrap (ink_merge_tolerance is one
# 20-character word with nowhere to break).
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

  # The cards of a column, in the order they stack.
  def column(d, n)
    stack = d.css(".card-stack")[n]
    refute_nil stack, "column #{n} must exist"
    stack.element_children
         .select { |e| e["class"].to_s.split.include?("card") }
         .map { |c| c.at_css("h3").text.strip }
  end

  # -- the two columns ------------------------------------------------------

  test "the left column is the job's own definition, Print directly under Job Spec" do
    titles = column(doc, 0)
    assert_equal ["Job Spec", "Print & tolerances"], titles,
      "the contract and the conditions it is measured under -- the colour " \
      "policy moved to the right column's bottom, and the sweep folded into " \
      "Job Spec"
    assert_equal titles.index("Job Spec") + 1, titles.index("Print & tolerances"),
      "the tolerances sit UNDER Job Spec: they were in the other column, a " \
      "column away from the contract that states the limits they measure"
  end

  test "the right column is the tracer's stages, in the order the pipeline runs them" do
    assert_equal ["Prep", "Colour Spec"], column(doc, 1),
      "prep (with its benches folded in) and the palette the sweep is checked " \
      "against -- Colour Spec now sits bottom-right, under Prep"
  end

  test "there are two columns and no card escapes them" do
    d = doc
    assert_equal 2, d.css(".card-stack").size
    d.css(".card").each do |c|
      title = c.at_css("h3")&.text&.strip
      next if title.nil? # not a page card
      assert c.ancestors(".card-stack").any?,
        "#{title} is outside both columns, so it would flow into the page grid " \
        "and unbalance the rows again"
    end
  end

  test "each column is ONE track of the page grid, not capped again" do
    # A nested block capped a second time left a card at 300px; the column is
    # already one track of a two-column page grid and takes it whole -- measured
    # 624px at a 1440px window.
    block_rule = css[/\.card-stack \{[^}]*\}/].to_s
    assert_includes block_rule, "grid-template-columns: minmax(0, 1fr);"
    refute_includes block_rule, "max-width",
      "the column already caps it; capping again halves it twice"
    assert_match(/\.card-stack > \.card \{ min-width: 0; \}/, css,
      "minmax(0,1fr) plus min-width:0, so a wide min-content child cannot " \
      "push the track open")
  end

  test "the old single-column block is gone, not just unused" do
    d = doc
    assert_equal 0, d.css(".prep-print-grid").size
    refute_includes css, "prep-print-grid",
      "dead CSS naming a class that matches nothing survives forever"
  end

  test "the tolerance fields are two-up, like everywhere else" do
    assert_match(/^\.print-grid \{ display: grid; grid-template-columns: 1fr 1fr;/m, css,
      "the full-width page default is unchanged, so every card shares it")
    assert_match(/\.card-stack \.print-grid \{ min-width: 0; \}/, css,
      "and an inner 2-up grid must not be what widens the column")
  end

  test "a long single-word label can break rather than clip" do
    assert_match(/\.card-stack \.field label \{ overflow-wrap: anywhere; \}/, css,
      '"ink_merge_tolerance" is one 20-character word with nowhere to break, ' \
      "and it now sits in the left column's Print card")
  end

  # -- the Prep card itself, unchanged by the move --------------------------

  test "the big info text is off the Prep card" do
    prep = card(doc, "Prep")
    refute_nil prep
    assert_nil prep.at_css(".prep-note"),
      "the prose on the card was a near-verbatim subset of what the ? already " \
      "said, which is why it read as noise -- it belongs in the popup"
    # The invert controls are the card's only <select>s; the benches below are
    # checkboxes/text/number, so no new select slipped in.
    assert_equal %w[f_invert f_invert_mode], prep.css("select").map { |s| s["id"] }
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

  test "the controls themselves are untouched" do
    p = card(doc, "Print")
    %w[f_dpi f_ink_limit f_white_ink f_ink_merge f_ramp_min_members].each do |id|
      refute_nil p.at_css("##{id}"), id
    end
    prep = card(doc, "Prep")
    assert_equal "true", prep.at_css("#f_invert option[selected]")["value"]
    assert_equal "photometric", prep.at_css("#f_invert_mode option[selected]")["value"]
  end

  test "count_white_as_ink ships the documented default, which is false" do
    # It used to pre-select true, so an untouched build always posted
    # white-as-ink -- and the writer's implied dark_garment_underbase with it, on
    # a sheet nobody had said was dark. The pipeline's documented default is
    # false: white is the substrate, not a screen.
    p = card(doc, "Print")
    assert_equal "false", p.at_css("#f_white_ink option[selected]")["value"],
      "the pipeline's default is false -- see chopshop-svg's README/spec.example.json"
    refute p.at_css("#f_white_ink option[value='true']")["selected"]

    v = File.read(Rails.root.join("app/views/pages/schema.html.erb"))
    assert_includes v, "if (pr.count_white_as_ink) pr.dark_garment_underbase = true;",
      "the implied underbase travels with the toggle, not with the page"
    # ...and the card says what that implication is, so turning it on is an
    # informed choice about a DARK garment rather than a mystery key appearing.
    hint = p.css(".hint").map(&:text).join(" ").gsub(/\s+/, " ")
    assert_match(/dark/i, hint, "the hint must say the page then assumes a dark garment")
    assert_includes hint, "dark_garment_underbase"
  end

  test "the ramp floor sits beside the merge tolerance it is read with" do
    p = card(doc, "Print")
    assert_equal "number", p.at_css("#f_ramp_min_members")["type"]
    assert_equal "6", p.at_css("#f_ramp_min_members")["value"],
      "6 is the documented default, and the page states the number it measured against"

    v = File.read(Rails.root.join("app/views/pages/schema.html.erb"))
    assert_match(/var rm = num\('f_ramp_min_members'\); if \(rm\) pr\.ramp_min_members = rm;/, v)
    assert_includes doc.at_css("#help-print").css("dt").map(&:text).map(&:strip),
      "ramp_min_members"
  end

  test "the fabric can be AUTHORED on the Colour Spec card, not only displayed" do
    # print.substrate and print.substrate_index were real, honoured keys the
    # studio could display (the proof page's substrate chip) and never write.
    colour = card(doc, "Colour Spec")
    refute_nil colour.at_css("#f_substrate_hex"), "print.substrate needs a control"
    refute_nil colour.at_css("#f_substrate_index"), "print.substrate_index needs a control"
    assert_equal "number", colour.at_css("#f_substrate_index")["type"]
    %w[f_substrate_hex f_substrate_index].each do |id|
      refute_nil colour.at_css("##{id}")["placeholder"], "#{id} must show its empty state"
    end
    # The swatch is a real picker button, like the print background's.
    swatch = colour.at_css("#f_substrate_swatch")
    refute_nil swatch
    assert_equal "button", swatch.name

    v = File.read(Rails.root.join("app/views/pages/schema.html.erb"))
    # Only one of the two is ever emitted, and the hex wins: the pipeline
    # resolves print.substrate first.
    assert_match(/if \(validHex\(subHex\)\) \{\s*\n\s*pr\.substrate = subHex;/, v)
    assert_match(/var subIdx = num\('f_substrate_index'\);\s*\n\s*if \(subIdx !== null && subIdx >= 0\) pr\.substrate_index = subIdx;/, v)
    # index 0 is a real palette position, so it is not tested for truth
    refute_match(/if \(subIdx\) pr\.substrate_index = subIdx;/, v,
      "palette entry 0 is the fabric too, and a truthy test would drop it")
  end
end
