require "test_helper"

# Two cosmetic rules with a load-bearing coupling between them, plus the help
# audit's regression guard. Both were verified in a real browser first:
#   .logo-icon      44x44, border-radius 50% (resolved 22px = half the box)
#   .logo-icon::after  inset -3px, radius 50%, opacity 0.62, blur(9px)
#   .help-btn       box-shadow rgba(99,102,241,0.18) 1px ring + 10px -2px glow
class ChromeChromeTest < ActionDispatch::IntegrationTest
  def css_without_comments
    Rails.root.join("app/assets/stylesheets/application.css").read
         .gsub(%r{/\*.*?\*/}m, "")
  end

  test "the sticky header scissor is a circle, not a rounded square" do
    css = css_without_comments
    logo = css[/\.logo-icon \{.*?\}/m]
    refute_nil logo

    assert_match(/border-radius: 50%/, logo,
      "the mark must be a circle. It was a rounded square (--radius-sm).")
    refute_match(/border-radius: var\(--radius-sm\)/, logo,
      "the rounded-square radius must be gone, not merely overridden")

    # Load-bearing: the tile has no overflow:clip, so the ::after ring is a
    # separate box. A square ring around a round tile reads as a square halo.
    ring = css[/\.logo-icon::after \{.*?\}/m]
    refute_nil ring
    assert_match(/border-radius: 50%/, ring,
      "the glow ring must follow the tile to a circle; a square ring around a " \
      "round mark reads as a square halo")
    refute_match(/border-radius: calc\(var\(--radius-sm\)/, ring,
      "the square ring's radius expression is meaningless on a circle")

    # The glow itself must survive the reshape.
    assert_match(/inset: -3px/, ring)
    assert_match(/opacity: 0\.62/, ring, "the ring is still lit")
    assert_match(/filter: blur\(9px\)/, ring, "and still diffuses past the edge")
  end

  test "the ? buttons carry a faint accent glow that strengthens on hover" do
    css = css_without_comments
    rest = css[/\n\.help-btn \{[^}]*box-shadow[^}]*\}/m]
    refute_nil rest, "the ? button must carry a box-shadow at rest"

    assert_match(/rgba\(99, 102, 241, 0\.18\)/, rest,
      "the halo is the accent indigo, at a low alpha")
    assert_match(/rgba\(99, 102, 241, 0\.35\)/, rest,
      "with a soft outer glow")
    assert_match(/transition: box-shadow/, rest,
      "it must ease rather than snap, or it reads as a flash")

    hover = css[/\.help-btn:hover,\s*\.help-btn:focus-visible \{[^}]*\}/m]
    refute_nil hover, "a hover/focus rule must exist"
    assert_match(/rgba\(99, 102, 241, 0\.45\)/, hover,
      "hover intensifies the ring")
    assert_match(/0 0 16px -1px rgba\(99, 102, 241, 0\.6\)/, hover,
      "and widens the glow")

    # Deliberately NOT the header scissor's conic-gradient ring: four spinning
    # rings on one page out-shout the single one the rest of the UI matches.
    refute_match(/conic-gradient/, css[/\n\.help-btn \{[^}]*\}/m].to_s,
      "the ? buttons use a static halo, not a spinning ring")
    refute_match(/\.help-btn[^}]*::after/, css,
      "no ::after ring on the ? buttons")
  end
end
