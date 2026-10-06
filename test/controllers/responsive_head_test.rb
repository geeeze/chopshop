require "test_helper"

# The head squashed on a phone, and nothing caught it because every layout
# check in this suite ran at one viewport.
#
# Cause: `.page-head-row--stacked` is `1fr auto` -- a flexible title column
# beside an `auto` column holding the buttons. `auto` wins the space fight when
# there is not much of it, so at 375px the title collapsed to a few words a line,
# the sub-title below it was squeezed into a narrow column, and the buttons were
# pushed toward the right edge. The head did not stack; it collapsed.
#
# Below 860px it is a single column in reading order. Each child is placed by an
# explicit grid ROW rather than DOM order, because in the stacked markup the
# sub-title is the LAST child: by DOM order it would land below the buttons
# instead of under the title it belongs to.
#
# The geometry is confirmed in a browser probe at 500/768/1280px. Rails cannot
# measure layout, so what this file pins is the CSS that produces it.
class ResponsiveHeadTest < ActionDispatch::IntegrationTest
  def css
    File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  def view(name)
    File.read(Rails.root.join("app/views", name))
  end

  def media
    @media ||= css.scan(/@media \(max-width: 860px\) \{(.*?)\n\}/m).flatten.join("\n")
  end

  test "there is a narrow-viewport rule for the head" do
    refute_empty media, "the @media (max-width: 860px) block must exist"
  end

  test "the head becomes a single column, not a squeezed two" do
    assert_match(/grid-template-columns:\s*minmax\(0,\s*1fr\)/, media,
      "one column. minmax(0,1fr) rather than 1fr, so a long word in the title " \
      "cannot force the grid wider than the viewport and scroll the page.")
    refute_match(/grid-template-columns:\s*1fr auto/, media,
      "the 1fr auto pair is what collapsed; it must not survive here")
  end

  test "each child is placed by an explicit row, in reading order" do
    assert_match(/> \.section-title\s*\{ grid-row: 1; grid-column: 1; \}/, media, "the title")
    assert_match(/> \.page-head-blurb\s*\{ grid-row: 2; grid-column: 1; \}/, media,
      "the sub-title directly under the title")
    assert_match(/> \.head-action--top\s*\{ grid-row: 3; grid-column: 1; \}/, media, "then the actions")
    assert_match(/> \.head-action--below\s*\{ grid-row: 4; grid-column: 1; \}/, media)
  end

  test "the sub-title is under the title BY ROW, not by DOM order" do
    # In every stacked view the blurb is the last child of the row. Relying on
    # DOM order would put it below the buttons once the grid is one column.
    #
    # jobs/index.html.erb was deleted by the Projects redesign; the Projects
    # index is its successor — same stacked head, blurb after the last
    # head-action. The PROJECT WORKSPACE head is deliberately NOT listed here:
    # its Projects(back)/toggle row-3 children carry .head-action/.view-toggle
    # AFTER the blurb, which is the shape projects_page_test pins separately —
    # a different arrangement, not a drifted one.
    %w[projects/index.html.erb pages/jev.html.erb pages/schema.html.erb
       pages/about.html.erb pages/flux.html.erb pages/bp.html.erb
       pages/status.html.erb validations/show.html.erb].each do |name|
      row = view(name)[/<div class="page-head-row[^"]*">.*?\n  <\/div>/m]
      refute_nil row, name
      assert_operator row.rindex("page-head-blurb"), :>, row.rindex("head-action"),
        "#{name}: the blurb is the LAST child, so the media query must place it " \
        "by grid-row or it drops below the buttons on a phone"
    end
  end

  test "the buttons do not stretch across the single column" do
    assert_match(/> \.head-action \{ justify-self: start; \}/, media,
      "otherwise the buttons fill the column and the 'condensed' head is a wall")
  end

  test "nothing is capped at a percentage of an already-narrow column" do
    assert_match(/\.page-head p,\s*\n\s*\.page-head-row--stacked > \.page-head-blurb \{ max-width: 100%; \}/, media,
      "67% of a 375px column is 251px, which is the squashing")
  end

  test "the Jobs table is full width at every viewport" do
    assert_match(/^\.tbl-wrap--narrow \{ width: 100%; \}$/m, css,
      "six columns fit the screen, so there is no measure to negotiate")
  end

  test "the two long blurbs go back to body size on a narrow screen" do
    assert_match(/\.page-head-blurb--long \{\s*font-size: 1rem;\s*line-height: 1\.55;\s*\}/m, media,
      "the condensation pass set every blurb to 0.85rem, which reads as a quiet " \
      "sub-line in a 1fr column beside the buttons but as 13.6px four words a " \
      "line under a 32px heading on a phone")
    %w[projects/index.html.erb pages/jev.html.erb].each do |name|
      assert_includes view(name), "page-head-blurb--long",
        "#{name}: the Projects and Jev blurbs are the long ones"
    end
    # The short ones are deliberately left alone.
    %w[pages/about.html.erb pages/schema.html.erb pages/flux.html.erb
       pages/bp.html.erb pages/status.html.erb
       validations/show.html.erb].each do |name|
      refute_includes view(name), "page-head-blurb--long",
        "#{name}: a two-line blurb is fine at 0.85rem"
    end
  end

  test "the title does not stay at its desktop clamp on a phone" do
    assert_match(/\.section-title \{ font-size: clamp\(1\.5rem, 7vw, 2rem\); \}/, media,
      "the desktop clamp bottoms out at 2rem, which is large beside a 1rem blurb")
  end
end
