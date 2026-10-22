require "test_helper"

# Every head action is the SAME WIDTH, whatever its label says.
#
# Press Start 2P is a full em per glyph, so a label's width is decided by how
# many characters it has: "Run Job" is 7, "TABLE" 5, "JSON" 4. With 1.5rem side
# padding and a 1px border that is 117.2px / 98.0px / 86.4px of box.
#
# The bug this pins: .head-action carried `min-width: 6.125rem` (98px). That
# floor is hit EXACTLY by the two short labels and does nothing for the long one,
# so the head read Run Job 117.2 next to TABLE 98.0. min-width can only raise a
# width -- a floor below the longest label can never make them equal.
#
# The fix is the floor being the longest label's own width, so every head action
# is at least that and they all land on it.
class HeadActionWidthTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  setup do
    @css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  # 117.2px measured with the real font embedded. 6.125rem was 98px.
  FLOOR = 7.325

  test "the floor is the widest label, not a round number under it" do
    rule = @css[/\.head-action \{([^}]*)\}/m, 1]
    refute_nil rule, ".head-action has no rule"
    assert_match(/min-width:\s*#{Regexp.escape(FLOOR.to_s)}rem/, rule,
      "the floor must be the width of the longest head label (117.2px). A floor " \
      "below it can only ever raise the SHORT labels, never match the long one.")

    # And it must not be a px literal that will drift from the rem.
    refute_match(/min-width:\s*\d+px/, rule, "declared in px, next to a rem scale")
  end

  test "the proof page's two head controls share that floor too" do
    # Ask Jev and the manifest are on the proof page, where they deliberately
    # borrow the JSON button's geometry. They were on 6.125rem while the JSON
    # button moved to 7.325rem, which would have re-introduced a 19px
    # disagreement between the button and the block copying it.
    rule = @css[/\.jev-btn\.head-action,\s*\.manifest-block\.head-action \{([^}]*)\}/m, 1]
    refute_nil rule, "the proof page's head controls have no rule"
    assert_match(/min-width:\s*#{Regexp.escape(FLOOR.to_s)}rem/, rule)
  end

  test "no other head-action rule reintroduces a smaller floor" do
    # A later bare .head-action rule shadows the one the size test matches, and a
    # per-state override with the old number undoes the whole fix silently.
    offenders = @css.scan(/min-width:\s*([\d.]+rem)/).flatten
                  .select { |v| v.to_f < FLOOR && v.to_f > 0 }
    # 6.125rem appears nowhere; anything left below the floor that is applied to
    # a head action is a regression. Reported rather than silently allowed.
    assert_empty offenders.select { |v| v.to_f < FLOOR && @css =~ /\.(?:[\w-]*head-action[\w-]*)[^{}]*\{[^}]*min-width:\s*#{Regexp.escape(v)}rem/m },
      "a head-action rule still floors at #{offenders.inspect}, below #{FLOOR}rem"
  end
end
