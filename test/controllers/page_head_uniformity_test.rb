require "test_helper"

# ONE page-head mechanism, enforced across every page.
#
# The blurb under the heading has been "fixed" repeatedly because three
# different mechanisms were in use and each page quietly picked one:
#
#   A  .page-head-blurb INSIDE .page-head-row--stacked  -> grid row 2, col 1
#   B  a bare <p> after the row, inside .page-head       -> reads fine ONLY
#                                                          because a one-action
#                                                          row is a single line
#   C  the blurb inside .page-sub, a SIBLING of the row  -> renders below the
#                                                          whole block and
#                                                          shares a line with
#                                                          other content
#
# /proofs/:id was on C, which is why its sub-title drifted away from the
# heading. B looks identical to A on a one-action page, so it hid the problem
# until a second action was added and the row grew two lines.
#
# Every page is on A now, and this file fails if one drifts back. Rails cannot
# measure layout, so the geometry is confirmed separately in a browser probe;
# what this pins is the STRUCTURE that produces it.
class PageHeadUniformityTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # Every page that renders a .page-head. jobs/show is excluded on purpose: its
  # head carries the source/inverse preview tiles, so its row is a different
  # shape by design and it has no sub-title blurb.
  PAGES = {
    "jobs/index.html.erb" => "Jobs",
    "pages/schema.html.erb" => "JSON",
    "pages/jev.html.erb" => "JEV",
    "pages/flux.html.erb" => "FLUX",
    "pages/plot.html.erb" => "PLOT",
    "pages/status.html.erb" => "STATUS",
    "pages/about.html.erb" => "About",
    "validations/show.html.erb" => "Proof"
  }.freeze

  def view(name)
    File.read(Rails.root.join("app/views", name))
  end

  def css
    File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  test "every page puts its blurb inside the stacked head row" do
    PAGES.each do |name, label|
      s = view(name)
      row = s[/<div class="page-head-row[^"]*">.*?\n  <\/div>/m]
      refute_nil row, "#{label}: a .page-head-row must exist"

      assert_includes row, "page-head-blurb",
        "#{label}: the blurb must be INSIDE .page-head-row --grid row 2, col 1, " \
        "under the heading. Outside it, it is a sibling and drifts."
      # A blurb SIBLING of the row: the row closes at 2-space indent, then the
      # blurb sits at the same 2-space level. In-row blurbs sit at 4-space
      # indent (after a nested child like head-action-pair), so anchoring both
      # tags to 2 spaces tells the two apart -- a loose `</div> ... <p>` would
      # match the pair's own close and call a correct row a bug.
      refute_match(/\n  <\/div>\s*\n  <p class="page-head-blurb">/, s,
        "#{label}: the blurb is after the row closed, not inside it")
    end
  end

  test "the row is the stacked grid, so the blurb has a cell to sit in" do
    PAGES.each do |name, label|
      assert_includes view(name), "page-head-row--stacked",
        "#{label}: without --stacked the row is a flex line and the blurb has " \
        "no grid cell -- it would sit beside the title"
    end
  end

  test "no page keeps the old mechanisms" do
    PAGES.each do |name, label|
      s = view(name)
      # C: a blurb inside .page-sub, which is a sibling of the head row.
      next if name == "validations/show.html.erb" # it keeps .page-sub for actions
      refute_match(/<div class="page-sub">.*?page-head-blurb/m, s,
        "#{label}: the blurb must not live in .page-sub")
    end

    # B: a bare <p> as a direct child of .page-head. It reads correctly only
    # while the row is a single line, so it is a trap rather than a style.
    PAGES.each do |name, label|
      refute_match(/<div class="page-head">\s*\n\s*<p[ >]/, view(name),
        "#{label}: a bare <p> straight inside .page-head is mechanism B")
    end
  end

  test "the grid places the blurb at row 2 col 1" do
    rule = css[/\.page-head-row--stacked > \.page-head-blurb \{[^}]*\}/]
    refute_nil rule, "the placement rule must exist"
    assert_match(/grid-row:\s*2/, rule)
    assert_match(/grid-column:\s*1/, rule,
      "col 1 is what puts it under the title rather than under the buttons")
    assert_match(/margin:\s*0/, rule,
      "the .page-head p rule would otherwise add a top margin inside the grid")
  end

  test "the title itself is pinned to row 1 col 1 on every page" do
    assert_match(/\.page-head-row--stacked > \.section-title \{ grid-row: 1; grid-column: 1; \}/, css)
  end

  test "the proofs page keeps its two buttons exactly where they were" do
    s = view("validations/show.html.erb")
    row = s[/<div class="page-head-row[^"]*">.*?\n  <\/div>/m]

    jev = row[/class="btn btn-primary btn-sm jev-btn head-action head-action--top"/]
    refute_nil jev, "Ask Jev stays head-action--top: grid row 1"
    man = row[/class="manifest-block head-action head-action--below"/]
    refute_nil man, "the manifest stays head-action--below: grid row 2"

    # The blurb joins them in row 2 col 1, so the manifest keeps row 2 col 2.
    assert_includes row, "page-head-blurb"
    assert_match(/head-action--top\s*\{\s*grid-row: 1;\s*grid-column: 2;/, css)
    assert_match(/head-action--below\s*\{\s*grid-row: 2;\s*grid-column: 2;/, css)
  end

  test "the proofs blurb is no longer in .page-sub" do
    s = view("validations/show.html.erb")
    sub = s[/<div class="page-sub">.*?\n  <\/div>/m]
    refute_nil sub, ".page-sub still holds the actions and the stats"
    refute_includes sub, "page-head-blurb",
      "the sub-title must be in the head row, not in .page-sub"
    assert_includes sub, "actions-row", "and .page-sub keeps the actions"
  end

  test "the back button is a bare arrow with the destination in its tooltip" do
    s = view("validations/show.html.erb")
    refute_match(/link_to\s+"[^"]*Job[^"]*",\s*job_path/, s,
      "the job name is already the heading; repeating it on the button was noise")
    assert_match(/link_to "<--", job_path\(@job\)/, s, "a bare back arrow")
    assert_match(/title: "Back to Job"/, s, "tooltip says where it goes")
    assert_match(/aria: \{ label: "Back to Job" \}/, s,
      "and the accessible name says it too, so it is not read as \"less than\"")
  end
end
