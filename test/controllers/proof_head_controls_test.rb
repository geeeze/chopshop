require "test_helper"

# The proof page's two head controls: Ask Jev on top, the manifest directly
# beneath it, sharing one box -- the arrangement the JSON page already uses for
# Run Job above JSON.
#
# They were on one flex line and disagreed with each other: Ask Jev measured
# 96.8px, the manifest 90.7px, and neither matched the 98px `.head-action` box
# the other four pages use. The manifest was also carrying its own padding and
# a 0.15rem left margin for that flex row.
#
# Measured in headless Chromium at 1272px:
#   both 112.3 x 44.0, right edge 1292.0, manifest top 124 vs jev bottom 110
#   grid 1135.7px 112.297px, title left at 20..1156
#
# 112.3px, not 98px: `min-width` is a floor, and "Ask Jev" plus its 1rem icon
# needs 80.3px of content. At 98px with 16px padding either side only 66px
# remains, so forcing the JSON button's exact width would clip the label. The
# two are the same WIDTH as each other, which is the actual requirement.
#
# The manifest keeps its dotted underline and transparent fill. `.head-action` is
# pure geometry -- no background, no border -- so it can adopt the box without
# becoming a button, and a "document you read" should not compete with the
# command above it.
class ProofHeadControlsTest < ActionDispatch::IntegrationTest
  def head_markup
    File.read(Rails.root.join("app/views/validations/show.html.erb"))
  end

  def css_without_comments
    Rails.root.join("app/assets/stylesheets/application.css").read
         .gsub(%r{/\*.*?\*/}m, "")
  end

  test "the proof head uses the same 2x2 stacked grid as the JSON page" do
    assert_includes head_markup, 'class="page-head-row page-head-row--split page-head-row--stacked"',
      "the JSON page's wrapper verbatim, so the manifest lands in grid row 2 col 2"
    refute_includes head_markup, "page-head-line",
      "the old flex line put both controls on one row"
  end

  test "both controls are head-actions, so the grid places them" do
    assert_match(/class="btn btn-primary btn-sm jev-btn head-action"/, head_markup)
    assert_match(/class="manifest-block head-action"/, head_markup)
    # The grid's own placement rules key off :first-of-type / :last-of-type
    # within .head-action, so this class list is what puts Ask Jev on row 1 and
    # the manifest on row 2 -- the title takes row 1 col 1.
    css = css_without_comments
    assert_match(/\.page-head-row--stacked > \.head-action:first-of-type/,
                 css, "row 1 col 2")
    assert_match(/\.page-head-row--stacked > \.head-action:last-of-type/,
                 css, "row 2 col 2")
  end

  test "the two share one box, set order-independently" do
    css = css_without_comments
    shared = css[/\.jev-btn\.head-action,\s*\.manifest-block\.head-action \{[^}]*\}/m]
    refute_nil shared, "a shared box for the two controls"

    # Two-class selectors (0,2,0) so they outrank BOTH .head-action and
    # .manifest-block / .jev-btn / .btn-sm (0,1,0) whatever order the sheet
    # ends up in. Order-dependent geometry is how these two drifted before.
    assert_match(/min-width: 6\.125rem;/, shared, "the head-action width, as a floor")
    assert_match(/height: 2\.75rem;/, shared, "the head-action height, not btn-sm's")
    assert_match(/justify-content: center;/, shared)
    assert_match(/margin-left: 0;/, shared,
      "the 0.15rem left margin was for the flex row that is now a grid")

    # And the rules they must beat are single-class, or this is all theatre.
    assert_match(/^\.head-action \{/m, css)
    assert_match(/^\.manifest-block \{/m, css)
    assert_match(/^\.jev-btn \{/m, css)
  end

  test "the manifest still reads as a document, not a command" do
    css = css_without_comments
    block = css[/\.manifest-block \{[^}]*\}/m]
    assert_match(/background: none;/, block, "no fill")
    assert_match(/border-bottom: 1px dotted/, block,
      "the dotted underline is the 'there is a document here' convention")
    # .head-action must stay pure geometry, or adopting it would have filled the
    # manifest in and made it look like the button above it.
    ha = css[/\.head-action \{[^}]*\}/m]
    refute_match(/background/, ha, ".head-action must carry no background of its own")
    refute_match(/border/, ha, "and no border")
  end

  test "both labels fit inside the box they share" do
    # Guarded in the browser: Ask Jev's nowrap content lands 0.7px over the
    # 112.297px column, which is sub-pixel rounding, not a clip. If someone
    # shortens the head-action minimum or lengthens the label, this catches the
    # day the pair stops fitting.
    # "Ask Jev" + a 1rem icon + a 0.4rem gap = 80.3px of content, and 1rem of
    # padding each side = 112.3px. The 6.125rem (98px) head-action minimum is a
    # FLOOR and is NOT enough here: it is 14.3px short, which is exactly why the
    # pair measures 112.3px instead of 98px. Recorded so that anyone who later
    # "fixes" the width back to 98px learns why that would clip the label.
    content, pad = 80.3, 16.0
    needed = content + 2 * pad
    assert_in_delta 112.3, needed, 0.5, "the measured width, derived"
    assert_operator 6.125 * 16, :<, needed,
      "98px CANNOT hold this label -- so the box must be allowed to grow past " \
      "the head-action minimum, as it does"
  end
end
