require "test_helper"

# The colour card's lower half is an explicit 2x3 grid, and the one thing that
# must not drift is the BOTTOM row: the Palettes button and the hex+scissor-orb
# row share a line, Palettes on the right. An earlier two-flex-column structure
# could not express that — each column stacked on its own, so the button landed
# directly under its own strip on a different line, which is what it did.
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

  test "the hex+orb picker and the Palettes button are direct grid siblings" do
    html = rendered

    # Both must be DIRECT children of .colour-set-pair. If either is wrapped in
    # its own column div, they land in independent tracks and stop sharing a line.
    picker = html[/<div class="pal-picker colour-set-picker">.*?<\/div>\s*<div class="colour-set-lib-cell">/m]
    refute_nil picker,
      "the picker and the lib cell must be adjacent direct children of .colour-set-pair"
    refute_includes html, "colour-set-col",
      "the old per-column wrapper is gone; it prevented the shared bottom row"
  end

  test "the Palettes button lives in its own row-3 cell, not inside the strip" do
    html = rendered

    cell = html[/<div class="colour-set-lib-cell">(.*?)<\/div>\s*<\/div>/m]
    refute_nil cell, "the .colour-set-lib-cell wrapper must exist"
    assert_includes cell, 'id="pal_presets_btn"',
      "the Palettes button must be inside .colour-set-lib-cell"

    # It must NOT be inside the strip wrapper any more — that was the bug: the
    # button rendered directly beneath the chips instead of opposite the orb.
    strip = html[/<div class="pal-strip" id="pal_strip".*?<\/div>\s*<div class="pal-count"/m]
    refute_nil strip, "the strip should be a plain grid child followed by the counter"
    refute_includes strip, "pal_presets_btn",
      "the Palettes button must not live inside the strip row"
  end

  test "the source order is row-major so the grid places each pair correctly" do
    html = rendered

    order = %w[f_max_colors pal_quick pal_strip colour-set-picker
               pal_presets_btn].map { |id| html.index(id) }
    assert order.all?, "every control must be present in the markup"
    assert_equal order.sort, order,
      "markup order must be row-major: max_colors, presets, strip, picker, Palettes"
  end

  test "the CSS pins the bottom row to row 3, columns 1 and 2" do
    css = Rails.root.join("app/assets/stylesheets/application.css").read

    assert_match(/\.colour-set-pair > \.colour-set-picker \{[^}]*grid-row: 3;[^}]*grid-column: 1;/m, css,
      "the picker must be pinned to row 3 / column 1")
    assert_match(/\.colour-set-lib-cell \{[^}]*grid-row: 3;[^}]*grid-column: 2;/m, css,
      "the Palettes cell must be pinned to row 3 / column 2")
  end
end
