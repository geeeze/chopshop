require "test_helper"

# The Colour Spec card's lower half is one grid, and the Colours button is now
# its single add-colour control — the hex+orb picker row is gone, so the button
# spans the full width on the last row. Colour addition goes through the
# palette library's ＋ and background_hex only.
class ColourCardGridTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def rendered
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    get json_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    response.body
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  test "the hex+orb picker row is gone" do
    html = rendered
    refute_includes html, "colour-set-picker",
      "the add-colour picker (swatch + hex + orb) is removed — addition is via " \
      "the library ＋ and background_hex only"
    refute_includes html, 'id="pal_add"'
    refute_includes html, 'id="pal_hex"'
    refute_includes html, 'id="pal_swatch"'
  end

  test "the Colours button is a direct grid child in its own cell" do
    html = rendered
    cell = html[/<div class="colour-set-lib-cell">(.*?)<\/div>\s*<\/div>/m]
    refute_nil cell, "the .colour-set-lib-cell wrapper must exist"
    assert_includes cell, 'id="pal_presets_btn"',
      "the Colours button must be inside .colour-set-lib-cell"
  end

  test "the source order is budget, strip, button" do
    html = rendered
    order = %w[f_max_colors pal_strip pal_presets_btn].map { |id| html.index(id) }
    assert order.all?, "every control must be present in the markup"
    assert_equal order.sort, order,
      "markup order must be max_colors, strip, Colours button"
  end

  test "the CSS spans the button across the full width" do
    css = Rails.root.join("app/assets/stylesheets/application.css").read
    assert_match(/\.colour-set-lib-cell \{[^}]*grid-column: 1 \/ -1;/m, css,
      "the button spans both columns on the last row")
    refute_includes css, "colour-set-picker",
      "the picker's CSS is gone with the picker"
  end
end
