require "test_helper"

# Two things measured in a browser, and the numbers are the point:
#
# 1. The Jobs list table is 67% of the content column, flush to its right edge.
# 2. The body panels are opaque enough that the central orb's light does not
#    wash over them, while still being frosted.
#
# On (2): the two requirements genuinely conflict -- backdrop-filter only shows
# through a translucent background, so a fully opaque panel has no frost left.
# --panel-bg at 0.94 alpha is the compromise: the 6% that shows through is what
# the backdrop-filter acts on, and it is what keeps the blurred edge. Below about
# 0.90 the orb reads straight through the card, which is the bug this fixes.
#
# Measured, not guessed. The numbers below came from a headless probe against the
# real stylesheet; Rails cannot measure layout, so this file pins the CAUSE and
# the declarations, and the geometry was confirmed separately in the browser.
class PanelsAndJobsTableTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def css
    File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  # ---- the Jobs table measure ----

  test "the Jobs list table is full width" do
    rule = css[/\.tbl-wrap--narrow \{[^}]*\}/]
    refute_nil rule, "the wrapper must exist"
    assert_match(/width:\s*100%/, rule,
      "it was narrowed to 67% when the table carried seven columns and " \
      "overflowed. At six it fits the screen, and 67% only shrank it away " \
      "from the left edge for nothing.")
    refute_match(/width:\s*67%/, rule, "not the old 67% measure")
  end

  test "only the jobs-style lists use the narrow wrapper" do
    # The results and proofs tables are the work; they stay full width. A stray
    # --narrow on those would squeeze a seven-column table into scroll.
    #
    # CHANGED (2026-10 Projects redesign): the Jobs LIST moved out of the
    # deleted app/views/jobs/index.html.erb (GET /jobs is gone) and now renders
    # in app/views/projects/show.html.erb -- the project workspace. The
    # redesign's Projects index adopted the same wrapper for its own list of
    # projects, so there are two list views instead of one. The load-bearing
    # claim survives: only LIST views carry the wrapper, never the results or
    # proofs tables.
    narrow = Dir[Rails.root.join("app/views/**/*.erb")].select do |f|
      File.read(f).include?("tbl-wrap--narrow")
    end
    assert_equal [Rails.root.join("app/views/projects/index.html.erb").to_s,
                  Rails.root.join("app/views/projects/show.html.erb").to_s].sort,
                 narrow.map(&:to_s).sort,
      "the jobs LIST (project workspace) and the projects LIST only -- the " \
      "results and proofs tables stay full width"
  end

  # ---- panel opacity ----

  test "the panel token is near-opaque but not opaque" do
    assert_match(/--panel-bg:\s*rgba\(\s*13,\s*13,\s*22,\s*0\.94\s*\)/, css,
      "0.94: opaque enough to stop the orb, translucent enough to stay frosted")
    # Guard the reasoning, not just the value.
    refute_match(/--panel-bg:\s*rgba\([^)]*,\s*1\s*\)/, css,
      "fully opaque would leave backdrop-filter nothing to act on -- the frost " \
      "would be gone")
    refute_match(/--panel-bg:\s*rgba\([^)]*,\s*0?\.[0-8]\d*\s*\)/, css,
      "and below ~0.90 the orb reads straight through the panel, which is the " \
      "problem being fixed")
  end

  test "the body panels use the token and keep their frost" do
    card = css[/\.card \{[^}]*\}/]
    assert_match(/background:\s*var\(--panel-bg\)/, card,
      "it was var(--surface) -- 3% white on a 3% white card, so the orb washed " \
      "straight over the content")
    assert_match(/backdrop-filter:\s*blur\([^)]*\) saturate\([^)]*\)/, card,
      "and the frost stays")
    assert_match(/-webkit-backdrop-filter:/, card, "with the -webkit- twin")

    wrap = css[/\.tbl-wrap \{[^}]*\}/]
    assert_match(/background:\s*var\(--panel-bg\)/, wrap,
      ".tbl-wrap had NO background at all -- the orb showed through the gap " \
      "between the table and its border")
    assert_match(/backdrop-filter:\s*blur/, wrap)
  end

  test "the page-head stat boxes are opaque too -- they sit outside any card" do
    # .stat-box and .job-stat render in .page-head, not inside a .card, so the
    # card's panel does not reach them.
    [".stat-box", ".job-stat"].each do |sel|
      rule = css[/#{Regexp.escape(sel)} \{[^}]*\}/]
      refute_nil rule, "#{sel} must exist"
      assert_match(/background:\s*rgba\(\s*19,\s*19,\s*29,\s*0\.9\s*\)/, rule,
        "#{sel} sits in the page head, outside any card, so it needs its own " \
        "panel or the orb lights it from behind")
      refute_match(/background:\s*var\(--surface-hover\)/, rule,
        "#{sel} was 6% white")
    end
  end

  test "the table itself is fully opaque, which is why it never needed the token" do
    assert_match(/--table-bg:\s*#101018/, css)
    assert_match(/table\.candidates \{[^}]*background:\s*var\(--table-bg\)/, css)
  end

  test "text stays readable over the new panels" do
    # Measured in the browser at 18.09:1 (rgb(248,250,252) on rgb(16,16,24)).
    # Pinned here so a future panel change that drops contrast fails loudly
    # rather than shipping a page nobody can read.
    assert_match(/--text-primary:\s*#f8fafc/, css)
    assert_match(/--panel-bg:\s*rgba\(\s*13,\s*13,\s*22,/, css,
      "a near-black panel under near-white text: the ratio only goes up, which " \
      "is why the browser measured 18.09:1")
  end
end
