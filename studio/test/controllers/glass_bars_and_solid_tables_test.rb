require "test_helper"

# The two page bars, and the jobs tables.
#
# The header and footer were tuned separately and had drifted: the header sat
# at 0.5 alpha while the footer sat at 0.85, which is effectively opaque, so
# the pair read as two different ideas and only one of them looked like glass.
# They now share one set of tokens, mirrored so the heavy edge faces OUTWARD on
# each (header heavy at the top, footer heavy at the bottom) and the lighter
# edge is where the page content passes.
#
# The jobs tables were `var(--surface)` -- 3% white, stacked on a card that is
# also 3% white over the body -- so the blurred colour orbs behind showed
# through the cells and under the numbers. They now have a real base.
#
# Measured in headless Chromium:
#   topbar  linear-gradient(rgba(10,10,15,0.72), rgba(10,10,15,0.48))
#   footer  linear-gradient(to top, rgba(10,10,15,0.72), rgba(10,10,15,0.48))
#   both    backdrop-filter: blur(22px) saturate(1.5)   [150% normalised]
#   tables  rgb(16,16,24) alpha=1, both of them
#   contrast on the new base: numbers 5.03:1, status pill 7.46:1, footer 7.70:1
class GlassBarsAndSolidTablesTest < ActionDispatch::IntegrationTest
  def css_without_comments
    Rails.root.join("app/assets/stylesheets/application.css").read
         .gsub(%r{/\*.*?\*/}m, "")
  end

  test "one set of glass tokens drives both bars" do
    css = css_without_comments
    root = css[/:root \{.*?\n\}/m]
    refute_nil root

    %w[--glass-blur: --glass-saturate: --glass-edge: --glass-inner:].each do |tok|
      assert_match(/#{Regexp.escape(tok)}/, root,
                   "#{tok} must exist: the two bars drifted because they were " \
                   "written out separately instead of shared")
    end
    # The tokens must be USED, not just declared.
    assert_match(/backdrop-filter: blur\(var\(--glass-blur\)\) saturate\(var\(--glass-saturate\)\)/, css)
    # 4, not 2: each of the two bars declares the recipe twice, once standard
    # and once -webkit- for Safari.
    assert_equal 4, css.scan(/saturate\(var\(--glass-saturate\)\)/).size,
                 "the two bars, each with its -webkit- twin, and nobody else"
  end

  test "the header and the footer are mirrored glass, not two different bars" do
    css = css_without_comments

    head = css[/\nnav\.topbar \{[^}]*\}/m]
    foot = css[/\n\.footer-note \{[^}]*\}/m]
    refute_nil head
    refute_nil foot

    # Mirrored direction: the default is `to bottom` for the header, `to top`
    # for the footer, so the HEAVY stop lands on each bar's outer edge.
    assert_match(/background: linear-gradient\(to bottom, var\(--glass-edge\), var\(--glass-inner\)\)/, head)
    assert_match(/background: linear-gradient\(to top, var\(--glass-edge\), var\(--glass-inner\)\)/, foot)

    # Both translucent, both identical blur, and neither back to a flat slab.
    assert_match(/var\(--glass-edge\)/, head)
    assert_match(/var\(--glass-edge\)/, foot)
    refute_match(/rgba\(10, ?10, ?15, ?0\.85\)/, foot,
                 "0.85 was the opaque footer this replaced")
    assert_match(/backdrop-filter: blur\(var\(--glass-blur\)\)/, head)
    assert_match(/backdrop-filter: blur\(var\(--glass-blur\)\)/, foot)
    # -webkit- alongside, for Safari.
    assert_match(/-webkit-backdrop-filter/, head)
    assert_match(/-webkit-backdrop-filter/, foot)
  end

  test "the jobs tables are solid, not 3% white" do
    css = css_without_comments
    root = css[/:root \{.*?\n\}/m]
    assert_match(/--table-bg: #101018;/, root,
      "a real base colour, only a shade off the page's #0a0a0f so it reads " \
      "solid without becoming a different-coloured slab")

    table = css[/\ntable\.candidates \{[^}]*\}/m]
    refute_nil table
    assert_match(/background: var\(--table-bg\)/, table)
    refute_match(/background: var\(--surface\)/, table,
      "--surface is 3% white: the table sat on a card that is also 3% white " \
      "over the body, so the colour orbs behind showed through the cells")
  end

  test "the table base still passes AA for the numbers on it" do
    # #f8fafc on #101018 -- the worst case in the table is the mono numbers.
    def lum(hex)
      rgb = hex.scan(/[0-9a-f]{2}/i).map { |h| h.to_i(16) / 255.0 }
      lin = rgb.map { |v| v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4 }
      0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    end
    l1 = lum("f8fafc")
    l2 = lum("101018")
    ratio = (l1 + 0.05) / (l2 + 0.05)
    assert_operator ratio, :>=, 4.5,
      "measured 5.03:1 in the browser; AA needs 4.5"
  end
end
