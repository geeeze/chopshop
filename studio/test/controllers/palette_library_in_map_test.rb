require "test_helper"

# The shop's palette library now lives inside the colour map, in one place.
class PaletteLibraryInMapTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  setup do
    @body = json_body
    @doc = Nokogiri::HTML(@body)
  end

  def json_body
    o = ENV["CHOPSHOP_PASSWORD"]; ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    ENV["CHOPSHOP_PASSWORD"] = o
    get json_path, headers: { "User-Agent" => MODERN_UA }
    response.body
  end

  test "the library lives in the colour map, not a popup of its own" do
    map = @doc.at_css("#colourMapTemplate")
    assert map, "the colour map template is gone"

    # The full cards -- the ones with ＋ and -> bg -- are what the map carries.
    assert map.at_css(".pal-presets"), "the colour map has no preset collection"
    cards = map.css(".pal-preset")
    assert_operator cards.size, :>=, 2, "the library rendered no cards"
    assert cards.first.at_css(".pal-add-one"), "the cards lost their add-one control"
    assert cards.first.at_css(".pal-preset-hit"), "the cards lost their whole-frame control"
    assert_operator map.css(".pal-add-one").size, :>, cards.size,
      "only one card has an add-one control; every colour should"

    # The heading the Palettes button scrolls to, by id.
    head = map.at_css("#cmapLibraryHead")
    assert head, "no #cmapLibraryHead to scroll the button to"
    assert_includes head.text, "library"
  end

  test "the second, plainer copy of the library is gone" do
    # The old popup rendered the same palettes as bare swatch rows -- two places
    # to show the same saved colours, and the poorer one won the button.
    refute @doc.at_css("#palPresetsTemplate"),
      "the duplicate preset template is still on the page"
    assert_nil @body[/getElementById\(['"]palPresetsTemplate['"]\)/, 0],
      "the JS still reaches for the deleted template"

    map = @doc.at_css("#colourMapTemplate")
    assert_empty map.css(".cmap-lib-row"),
      "the old plain swatch rows are still in the map; there is one collection, not two"
  end

  test "the colour button opens the colour map, not the deleted popup" do
    btn = @doc.at_css("#pal_presets_btn")
    assert btn, "the colour button is gone from the card"
    # It used to say "Palettes" while being the one control that reaches EVERY
    # colour in the app. The popup holds both the full grid and the library, so
    # the label has to admit to both or it undersells the control and
    # oversells the library.
    assert_equal "Colours", btn.text.strip
    assert_includes btn["title"].to_s, "grid"
    assert_includes btn["title"].to_s, "library"

    # It is still in the card, in its grid cell.
    cell = btn.ancestors(".colour-set-lib-cell").first
    assert cell, "the button lost its grid cell"
    assert_nil @doc.at_css(".pal-picker.colour-set-picker"),
      "the hex+orb picker row is gone — addition is via the library ＋ and background_hex"
  end

  test "the button opens the map at the GRID, not scrolled to the library" do
    handler = @body[/\$\('pal_presets_btn'\)\.addEventListener\('click', function \(\) \{(.*?)\n  \}\);/m, 0]
    assert handler, "no click handler on the colour button"
    assert_includes handler, "openColourMap",
      "the button must open the colour map now that the library is in it"
    # It used to scrollIntoView the library head, which put the one control
    # that reaches every colour straight past every individual colour. The grid
    # is the top of the popup and the library is below it, so no scroll: the
    # library is still one flick away and the grid is what you land on.
    refute_includes handler, "cmapLibraryHead",
      "no scroll to the library -- the popup opens on the grid"
    refute_includes handler, "scrollIntoView"
  end

  test "the spectrum is still in the map beside the library" do
    map = @doc.at_css("#colourMapTemplate")
    # Relocating the library must not cost the spectrum or the greys.
    assert map.at_css(".cmap-spectrum"), "the spectrum is gone"
    assert map.at_css(".cmap-grey"), "the neutrals are gone"
    assert_operator map.css(".cmap-cell").size, :>, 100, "the colour cells are gone"
  end

  test "the preset actions still work from inside the map" do
    # The handler is delegated on document, and it resolves ＋ / -> bg FIRST
    # with an early return, so a click inside a card cannot also fire the
    # whole-frame branch and load the palette on top of the one colour.
    handler = @body[/ORDER IS THE CONTRACT.*?document\.addEventListener\('click', function \(e\) \{(.*?)\n  \}\);/m, 0]
    assert handler, "the delegated preset handler is gone"

    set_bg = handler.index("pal-set-bg")
    add_one = handler.index("pal-add-one")
    frame = handler.index("closest('.pal-preset')")
    assert set_bg && add_one && frame, "one of the three branches is missing"
    assert_operator set_bg, :<, add_one, "-> bg must resolve before ＋"
    assert_operator add_one, :<, frame, "＋ must resolve before the frame"
    assert_includes handler[add_one..frame], "return",
      "the ＋ branch does not return, so the frame branch would also fire"
  end
end
