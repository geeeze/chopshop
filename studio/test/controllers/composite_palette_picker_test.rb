require "test_helper"

# The composite builder's PALETTE section.
#
# It used to be a bare `#rrggbb` text box, while the job spec builder had the
# app's colour map (spectrum + neutrals + the shop's proven palettes). A
# compose palette is part of the compose contract, so it is authored the same
# way: Colours opens the SAME map (one shared <template>, so the two pages
# cannot drift into two pickers), a click adds the colour to the palette, and
# the text field stays the source of truth the form posts.
class CompositePalettePickerTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  HEX = /\A#[0-9a-f]{6}\z/.freeze

  setup do
    @original_password = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
  end

  teardown do
    ENV["CHOPSHOP_PASSWORD"] = @original_password
  end

  def page
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get new_composite_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def view
    Rails.root.join("app/views/composites/show.html.erb").read
  end

  test "the palette section carries a strip and a Colours button, not a bare hex box" do
    doc = page

    field = doc.at_css("#compPalette")
    refute_nil field, "the posted field is the palette's source of truth"
    assert_equal "palette", field["name"], "the form posts this field as palette"
    # The field is still hand-editable: an agent or a typist may send a list.
    assert_includes field["placeholder"].to_s, "#rrggbb"

    strip = doc.at_css("#compPalStrip")
    refute_nil strip, "the palette needs a strip: the field made visible"
    assert_includes strip["class"].split, "pal-strip"

    btn = doc.at_css("#compPaletteBtn")
    refute_nil btn, "no way into the colour map from the compose page"
    assert_equal "button", btn.name
    assert_equal "Colours", btn.text.strip,
      "the button must admit to the grid as well as the library"
    assert_includes btn["title"].to_s, "grid"
    assert_includes btn["title"].to_s, "library"

    # label-in-name: the visible words are the accessible name
    assert_equal "Colours", btn.text.strip
    assert_match(/\APalette\z/, doc.at_css('label[for="compPalette"]').text.strip,
      "the section still reads as the palette")
  end

  test "the compose page renders the same colour map the job spec builder does" do
    doc = page

    map = doc.at_css("template#colourMapTemplate")
    refute_nil map, "the shared colour map must render on the compose page too"
    assert map.at_css(".cmap-spectrum"), "the spectrum is gone"
    assert map.at_css(".cmap-grey"), "the neutrals are gone"
    assert_operator map.css(".cmap-cell").size, :>, 100, "the colour cells are gone"

    # Every cell must carry a real #rrggbb: the page's add path validates
    # against that shape, so an hsl() cell would be silently refused.
    bad = map.css(".cmap-cell").reject { |c| c["data-hex"].to_s.match?(HEX) }
    assert_empty bad.map { |c| c["data-hex"] }.uniq

    cards = map.css(".pal-preset")
    assert_operator cards.size, :>=, 2,
      "the shop's proven palettes belong in the map here too"
    assert cards.first.at_css(".pal-add-one"), "a card lost its add-one control"
    assert cards.first.at_css(".pal-preset-hit"), "a card lost its whole-frame control"
  end

  test "the map is the shared template, handed to the same modal" do
    src = view
    assert_match(/render "shared\/colour_map"/, src,
      "one map for the whole app, not a second copy on this page")
    assert_includes src, "function openCompColourMap()"
    assert_includes src, "CsModal.open('Compose palette', tpl.innerHTML)",
      "the same modal as the JSON page, not a bespoke floating picker"
    assert_includes src, "document.getElementById('compPaletteBtn').addEventListener('click', openCompColourMap)"

    # A picked cell becomes a palette entry, and the modal closes.
    assert_match(/var picked = cell\.dataset\.hex;[\s\S]*?addCompColour\(picked\);[\s\S]*?CsModal\.close/,
      src, "clicking a cell must add the colour and close the map")
  end

  test "the field is the source of truth, so the strip cannot disagree with the POST" do
    src = view
    # every write goes back through the field...
    assert_match(/function writeCompPalette\(list\)[\s\S]*?compPalField\(\)\.value = list\.join\(', '\)/,
      src, "the strip must be a view of the field, never a second store")
    # ...and the strip is painted FROM it, so typing updates the chips.
    assert_match(/function compPaletteList\(\)[\s\S]*?compPalField\(\)\.value\.split/,
      src, "the list is parsed from the field")
    assert_includes src, "compPalField().addEventListener('input', function () { renderCompPalette(); });"
  end

  test "a card's inner controls are resolved before its clickable frame" do
    src = view
    handler = src[/ORDER IS THE CONTRACT[\s\S]*?document\.addEventListener\('click', function \(e\) \{(.*?)\n  \}\);/m, 1]
    refute_nil handler, "the delegated palette handler is gone"

    set_bg = handler.index("pal-set-bg")
    add_one = handler.index("pal-add-one")
    frame = handler.index("closest('.pal-preset')")
    assert set_bg && add_one && frame, "one of the three card branches is missing"
    assert_operator set_bg, :<, add_one, "-> bg must resolve before +"
    assert_operator add_one, :<, frame, "+ must resolve before the frame"
    assert_includes handler[add_one..frame], "return",
      "the + branch does not return, so the frame branch would also load the whole palette"
  end

  test "the colour map's background action paints the composite background" do
    doc = page
    bg = doc.at_css("#compBg")
    refute_nil bg, "the composite background field"
    # The setup slot stays a preview (see CompositeTest): the map's -> bg writes
    # the FIELD, and the page's own paint() repaints the swatch from it.
    src = view
    assert_match(/var bg = document\.getElementById\('compBg'\);[\s\S]*?bg\.value = setBg\.dataset\.hex/,
      src, "-> bg must land in the field the form posts")
    assert_includes src, "bg.dispatchEvent(new Event('input', { bubbles: true }))",
      "the swatch is painted by the field's input handler; write it that way, not a second painter"
  end
end
