require "test_helper"

# The JSON page's colour map, and the Prep card.
#
# COLOUR MAP. The two big swatches -- print background, and the colour about to
# be added to the spec palette -- were `<span aria-hidden="true">` elements that
# only mirrored whatever hex was typed. Clicking them did nothing, which is
# what "the swatches aren't working" meant. They are now real buttons that open
# the map.
#
# The cells must carry REAL #rrggbb, not `hsl(...)`: the builder's HEX_RE is
# /^#[0-9a-fA-F]{6}$/, so an hsl() cell would be refused by addColour() with
# "not a #rrggbb colour" and every map click would silently fail.
#
# PREP. `pr.invert = true` was hardcoded with no control at all. The pipeline
# accepts false / true / {"mode": "photometric"|"negative"}, and there is an
# upstream regression where a bare boolean loses the mode, so the mode has to
# travel with the toggle.
class ColourMapAndPrepTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  HEX = /\A#[0-9a-f]{6}\z/.freeze

  def page
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get json_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def view
    Rails.root.join("app/views/pages/schema.html.erb").read
  end

  test "both swatches are real buttons that open the map" do
    doc = page
    %w[f_bg_swatch pal_swatch].each do |id|
      el = doc.at_css("##{id}")
      refute_nil el, "##{id} must exist"
      assert_equal "button", el.name,
        "##{id} was an aria-hidden span that only mirrored the typed hex; " \
        "as a span it cannot be clicked or focused"
      refute_nil el["aria-label"], "and it needs a name"
      refute_includes el["aria-label"].to_s, "aria-hidden"
    end
    # The old spans must be gone, or there would be two controls per field.
    assert_equal 0, doc.css("span.pal-swatch-lg").size
  end

  test "the map is a template fed to the same modal as the palettes" do
    doc = page
    tpl = doc.at_css("template#colourMapTemplate")
    refute_nil tpl, "the map is served as a <template> and handed to CsModal"

    src = view
    assert_match(/function openColourMap\(/, src)
    assert_match(/CsModal\.open\(title, tpl\.innerHTML\)/, src,
      "one modal on this page, not a bespoke floating picker")
    # Wired to both targets. Plain substrings: as regexes the literal parens in
    # addEventListener( ... ) are unbalanced groups.
    assert_includes src, "$('f_bg_swatch').addEventListener('click'"
    assert_includes src, "$('pal_swatch').addEventListener('click'"
    # A pick closes the modal and hands the hex to the right target.
    assert_match(/var fn = cmapPick;[\s\S]*?fn\(hex\);/, src)
  end

  test "every map cell carries a real #rrggbb, because HEX_RE rejects hsl()" do
    doc = page
    cells = doc.css(".cmap-cell")
    assert_operator cells.size, :>=, 200, "24 hues x 8 lightnesses + neutrals + library"

    bad = cells.reject { |c| c["data-hex"].to_s.match?(HEX) }
    assert_empty bad.map { |c| c["data-hex"] }.uniq,
      "these would be refused by addColour() with 'not a #rrggbb colour'"
    cells.each do |c|
      refute_nil c["aria-label"], "a cell must be announced: #{c['data-hex']}"
      refute_nil c["title"]
      # Without the inline background the map is 233 transparent buttons.
      assert_equal "background:#{c['data-hex']}", c["style"].to_s.sub(/;\s*\z/, ""),
        "#{c['data-hex']} does not paint itself"
    end
  end

  test "the spectrum is hue x lightness, and lightness descends on screen" do
    doc = page
    rows = doc.css(".cmap-spectrum .cmap-row")
    assert_equal 8, rows.size, "8 lightness levels"

    # Top row lightest, bottom row darkest -- the ramp everyone already knows.
    first, last = rows.first, rows.last
    lum = ->(hex) { hex.scan(/[0-9a-f]{2}/i).map { |h| h.to_i(16) }.sum }
    top = lum.call(first.at_css(".cmap-cell")["data-hex"])
    bottom = lum.call(last.at_css(".cmap-cell")["data-hex"])
    assert_operator top, :>, bottom, "lightness descends down the page"

    # 24 distinct hues across a row.
    # A full-saturation hue at L=100% is white, so the lightest row used to be
    # 24 identical #ffffff cells. Every row must now be 24 DISTINCT colours.
    first.css(".cmap-cell").each_with_index do |c, i|
      refute_equal "#ffffff", c["data-hex"],
        "cell #{i} of the lightest row is white -- full saturation at L=100% " \
        "is white for every hue, so the ramp has to stop below it"
    end
    hues = first.css(".cmap-cell").map { |c| c["data-hex"] }.uniq
    assert_operator hues.size, :>=, 20, "a real spectrum, not a handful of swatches"
    assert_equal 24, first.css(".cmap-cell").size
  end

  test "the neutrals ramp and the shop's library are both in the map" do
    doc = page
    greys = doc.css(".cmap-grey .cmap-cell")
    assert_equal 11, greys.size, "0% to 100% in steps of 10"
    # Greys really are neutral: r == g == b.
    greys.each do |c|
      rgb = c["data-hex"].scan(/[0-9a-f]{2}/i).map { |h| h.to_i(16) }
      assert_equal 1, rgb.uniq.size, "#{c['data-hex']} is not neutral"
    end
    # The library moved: it used to be plain .cmap-cell-lib swatch rows here, and
    # now the full preset cards (with ＋ and -> bg) live in the map too. The
    # one place the library is shown is the colour map.
    cards = doc.css("#colourMapTemplate .pal-preset")
    assert_operator cards.size, :>=, 2, "the shop's palettes, as cards in the map"
    assert_operator doc.css("#colourMapTemplate .pal-add-one").size, :>=, 25,
      "and every saved colour is still individually reachable"
    assert_empty doc.css(".cmap-cell-lib"),
      "the old plain swatch rows are gone -- one collection, not two"
  end

  test "Prep leads the tracer's column, and its two controls stay on one line" do
    doc = page
    # Prep, Prep — expanded and Sweep are one column now. Prep leads it: it is
    # the stage that decides what gets measured, and the other two either feed it
    # or measure against it.
    stack = doc.css(".card-stack").find { |s| s.text.include?("Prep — expanded") }
    refute_nil stack, "the tracer's column must hold the prep benches"
    titles = stack.element_children
                  .select { |e| e["class"].to_s.split.include?("card") }
                  .map { |c| c.at_css("h3").text.strip }
    assert_equal "Prep", titles.first,
      "Prep is the first stage of the column, not one of the benches"
    assert_equal ["invert", "invert mode"], doc.css(".prep-row label").map { |l| l.text.strip }
    # One line, per the ask.
    assert_equal 1, doc.css(".prep-row").size
    assert_equal 2, doc.at_css(".prep-row").element_children.count { |e| e.name == "div" },
      "the two controls, in a single flex row"
    assert_equal 0, doc.at_css(".prep-row").element_children.count { |e| e.name == "p" },
      "the explanation moved into the ? popup -- on the card it was a near-" \
      "verbatim subset of what help-prep already said"
  end

  test "Prep is documented by its own help block, and only its own" do
    doc = page
    entries = doc.at_css("#help-prep").css("dt").map { |d| d.text.strip }
    assert_includes entries, "invert"
    assert_includes entries, "invert mode"
    assert_equal doc.css(".prep-row label").map { |l| l.text.strip }.sort, entries.sort

    btn = doc.at_css('[data-help-target="help-prep"]')
    refute_nil btn, "the Prep card needs its ?"
    assert_includes btn["aria-label"].to_s, "Prep",
      "the accessible name must CONTAIN the visible label (WCAG 2.5.3)"
  end

  test "the invert mode travels with the toggle, as the pipeline requires" do
    src = view
    refute_match(/pr\.invert = true;(\s*\/[^\n]*)?\n\s*var bg/, src,
      "the hardcoded pr.invert = true is gone -- it had no control")

    # false -> false; on + photometric -> true (the pipeline default);
    # on + negative -> a dict carrying the mode.
    assert_match(/if \(inv === 'false'\) \{\s*pr\.invert = false;/, src)
    assert_match(/pr\.invert = true;/, src)
    assert_match(/pr\.invert = \{ mode: val\('f_invert_mode'\) \};/, src,
      "a bare boolean would LOSE the mode -- the documented upstream regression")

    # Both selects rebuild the spec live, like every other field.
    assert_match(/querySelectorAll\('#f_invert,#f_invert_mode,/, src)
  end

  test "hsl_hex is a real HSL -> #rrggbb conversion" do
    h = ApplicationController.helpers
    assert_equal "#ffffff", h.hsl_hex(0, 0, 100)
    assert_equal "#000000", h.hsl_hex(0, 0, 0)
    assert_equal "#ff0000", h.hsl_hex(0, 100, 50)
    assert_equal "#00ff00", h.hsl_hex(120, 100, 50)
    assert_equal "#0000ff", h.hsl_hex(240, 100, 50)
    # Hue wraps, and out-of-range values clamp rather than emit junk.
    assert_equal h.hsl_hex(0, 100, 50), h.hsl_hex(360, 100, 50)
    assert_match HEX, h.hsl_hex(-30, 100, 50)
    assert_match HEX, h.hsl_hex(30, 400, 50)
  end
end
