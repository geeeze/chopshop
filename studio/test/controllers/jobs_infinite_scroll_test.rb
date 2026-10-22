require "test_helper"

# The jobs list lives on the PROJECT WORKSPACE (GET /projects/:id): the
# project's own runs, in the List/Grid two-view layout the old jobs index had.
# The standalone GET /jobs index was deleted in the Projects redesign
# (2026-09-30). With it went everything this file used to pin about how that
# page WINDOWED the run history:
#
#   * PER_PAGE and the `page` offset -- projects#show lists
#     @project.jobs.recent IN FULL. No PER_PAGE, no page param, no window.
#   * The #jobs-scroll sentinel (data-next-page, decided by @has_more) and the
#     .jobs-scroll-more fallback link -- nothing offers a "next page" any more,
#     because there is no second page to offer.
#   * The infinite-scroll script itself -- the fetch/append/observer block is
#     gone from the rendered page along with the index template.
#
# Those six contracts are RETIRED below, each named, so their absence is
# deliberate rather than a silent deletion. What SURVIVED the redesign was
# re-pointed at the workspace and is pinned there instead: the two wrappers
# still render together (the toggle swaps them and never refetches, so every
# run must be both a row and a card), and the row and the card are still
# PARTIALS rendered by the one workspace template, so no second inline copy
# can drift from the first.
class JobsInfiniteScrollTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # The project that owns the runs under test. Job belongs_to :project
  # (optional: true), so a job with no project is UI-invisible and would never
  # reach the workspace list these assertions read.
  def workspace
    @workspace ||= Project.create!(name: "scroll-workspace", is_test: true)
  end

  def with_runners
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    begin
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def job(name)
    Job.create!(name: name, state: "done", source_kind: "raster", runner: "mock",
                input_path: "/data/#{name}.png", stem: name, spec: {},
                project: workspace,
                comparison: { "candidates" => [] })
  end

  # The served jobs list: the project workspace, which lists every run the
  # project owns. There is no `page` argument any more -- GET /jobs and its
  # windowing were deleted in the Projects redesign, and the workspace serves
  # the whole history in one response.
  def index_doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get project_path(workspace), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def names_in(d, selector)
    d.css(selector).map { |n| n.text.strip }
  end

  # ---------------------------------------------------------------------------
  # RETIRED -- pinned to surfaces the Projects redesign (2026-09-30) deleted.
  # The workspace lists all runs unpaginated, so each of these named contracts
  # has no live surface to assert against. Named here rather than silently
  # dropped, so the next reader knows the absence is deliberate:
  #
  #   * "one page holds PER_PAGE runs and page 2 continues where page 1
  #     stopped" -- PER_PAGE and the `page` offset are gone; there is no
  #     window to measure and no page 2 to continue from.
  #   * "a junk, zero or negative page is page 1, not a bad OFFSET" -- there is
  #     no page param to be junk; the workspace ignores any such query string.
  #   * "the sentinel names the next page only while more runs exist" -- the
  #     #jobs-scroll sentinel and its data-next-page attribute were deleted
  #     with the scroll script.
  #   * "a history that fits in one page never offers a second one" -- nothing
  #     offers a second page at all any more, which is the stronger statement.
  #   * "the fallback link works with no JS at all -- it is a real link to
  #     page 2" -- the .jobs-scroll-more link and the page it pointed at are
  #     both gone.
  #   * "the scroll re-wires late markup through the hook aether.js exposes" --
  #     the scroll script no longer ships, so window.csRewireDynamic has no
  #     caller on this page. (aether.js may still expose the hook; nothing in
  #     the workspace list calls it.)
  # ---------------------------------------------------------------------------

  # ---- both wrappers, one response ----

  test "both views carry every run -- every job is a row AND a card" do
    # Survived the redesign: the workspace renders #jobs-list (the table) and
    # #jobs-grid (the cards) TOGETHER for every run, and the List/Grid toggle
    # swaps the two wrappers without refetching -- so a run that is only in
    # one view disappears the moment the operator flips the toggle. What is
    # gone is the PAGING around it: there is no page 2, so the contract is now
    # about every run rather than every run on a page.
    with_runners do
      5.times { |i| job(format("paired-%02d", i)) }
      d = index_doc

      rows = names_in(d, "#jobs-list tbody tr .cs-job-name")
      cards = names_in(d, "#jobs-grid .job-card a.cs-job-name")
      assert_equal 5, rows.size, "every run the project owns is a row"
      assert_equal 5, cards.size, "and every one is a card too"
      assert_equal cards, rows,
        "the toggle swaps wrappers and never refetches, so a run that is " \
        "only in one view disappears in the other"
    end
  end

  # ---- one renderer for every run ----

  test "the row and the card are partials, so every run is a rendered run" do
    # Survived the redesign, with the scroll's "appended" runs gone: the
    # workspace template is still the ONE renderer. It renders both partials
    # for the same @jobs collection, so no second inline copy of a row or a
    # card can drift from the first. jobs/index.html.erb -- the template the
    # old assertions read -- was deleted with the index.
    workspace_view = File.read(Rails.root.join("app/views/projects/show.html.erb"))
    row = File.read(Rails.root.join("app/views/jobs/_row.html.erb"))
    card = File.read(Rails.root.join("app/views/jobs/_card.html.erb"))

    assert_includes workspace_view, 'render partial: "jobs/row", collection: @jobs, as: :job'
    assert_includes workspace_view, 'render partial: "jobs/card", collection: @jobs, as: :job'
    assert_match(/<tr class="rowlink"/, row)
    assert_match(/class="job-card"/, card)
    # One renderer, one definition: a second inline copy in the workspace
    # template is the drift this exists to prevent.
    refute_includes workspace_view, "<tr class=\"rowlink\""
    refute_includes workspace_view, "class=\"job-card\""
  end
end
