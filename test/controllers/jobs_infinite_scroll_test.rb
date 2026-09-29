require "test_helper"

# The jobs index shows ONE WINDOW of the run history and loads the rest as you
# reach it. What this file pins, and why each one is a contract:
#
#   * The window is PER_PAGE, and it MOVES with `page` -- an offset, not a
#     second filter. Two pages have to be disjoint and together cover the
#     history, or a run is either unreachable or shown twice.
#   * A junk page is page 1. `params[:page]` is a string, so anything that
#     multiplies it unvalidated is one `?page=-1` away from raising on OFFSET.
#   * BOTH views page. The head toggle swaps two wrappers and never refetches,
#     so a run has to be in the table AND the card for the page it lands on --
#     the scroll fetches the same URL and lifts both out.
#   * The sentinel carries the NEXT page and the server decides when the list
#     ends: `data-next-page` is present only while `@has_more`. A client-side
#     counter that disagrees with the controller is the bug this avoids.
#   * The row and the card are PARTIALS, rendered by the same code as the first
#     page, so an appended run cannot drift from a rendered one.
#   * The markup that arrives after load is re-wired: aether.js exposes
#     `window.csRewireDynamic` precisely because wireViewers/wireJobActions bind
#     per element and cannot see a node that did not exist at DOMContentLoaded.
class JobsInfiniteScrollTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

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
                comparison: { "candidates" => [] })
  end

  def index_doc(page: nil)
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get jobs_path(page ? { page: page } : {}), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def names_in(d, selector)
    d.css(selector).map { |n| n.text.strip }
  end

  def sentinel(d)
    s = d.at_css("#jobs-scroll")
    refute_nil s, "the scroll sentinel is what carries the next page"
    s
  end

  # ---- the window ----

  test "one page holds PER_PAGE runs and page 2 continues where page 1 stopped" do
    with_runners do
      per = JobsController::PER_PAGE
      (per + 5).times { |i| job(format("run-%02d", i)) }
      first = index_doc
      second = index_doc(page: 2)

      page1 = names_in(first, "#jobs-grid .job-card a.cs-job-name")
      page2 = names_in(second, "#jobs-grid .job-card a.cs-job-name")

      assert_equal per, page1.size, "the first window is one full page"
      assert_equal 5, page2.size, "and the second carries what is left"
      assert_empty(page1 & page2, "a run is never on two pages at once")
      assert_equal per + 5, (page1 + page2).size, "the two pages cover the history"

      # Newest first, so the boundary is the order: everything after page 1's
      # last run. Compared by position, not by set, so a wrong ORDER also fails.
      assert_equal Job.recent.limit(per).pluck(:name), page1
      assert_equal Job.recent.offset(per).pluck(:name), page2
    end
  end

  test "both views page together -- every run on a page is a row AND a card" do
    with_runners do
      (JobsController::PER_PAGE + 3).times { |i| job(format("paired-%02d", i)) }
      d = index_doc(page: 2)

      rows = names_in(d, "#jobs-list tbody tr .cs-job-name")
      cards = names_in(d, "#jobs-grid .job-card a.cs-job-name")
      assert_equal cards, rows,
        "the toggle swaps wrappers and never refetches, so a paged run that is " \
        "only in one view disappears in the other"
    end
  end

  test "a junk, zero or negative page is page 1, not a bad OFFSET" do
    with_runners do
      job("only")
      ["-1", "0", "abc", ""].each do |bad|
        d = index_doc(page: bad)
        assert_equal ["only"], names_in(d, "#jobs-grid .job-card a.cs-job-name"),
          "page=#{bad.inspect} must serve the first page, not raise or come up empty"
      end
    end
  end

  # ---- the sentinel ----

  test "the sentinel names the next page only while more runs exist" do
    with_runners do
      per = JobsController::PER_PAGE
      (per + 1).times { |i| job(format("more-%02d", i)) }

      d = index_doc
      assert_equal "2", sentinel(d)["data-next-page"],
        "a full first page with runs behind it is the case that must offer page 2"

      d2 = index_doc(page: 2)
      assert_nil sentinel(d2)["data-next-page"],
        "the last page is the stop condition, and only the server knows it"
      assert_nil d2.at_css("#jobs-scroll .jobs-scroll-more"),
        "and the fallback link goes with it -- the two must not both offer a page"
    end
  end

  test "a history that fits in one page never offers a second one" do
    with_runners do
      job("short-history")
      d = index_doc
      assert_nil sentinel(d)["data-next-page"],
        "one page is not a truncated page when everything fits"
    end
  end

  test "the fallback link works with no JS at all -- it is a real link to page 2" do
    with_runners do
      per = JobsController::PER_PAGE
      (per + 1).times { |i| job(format("noscript-%02d", i)) }
      d = index_doc

      more = d.at_css("#jobs-scroll .jobs-scroll-more")
      refute_nil more, "without the observer the list must still be pageable"
      assert_equal jobs_path(page: 2), more["href"]
      assert_equal "next", more["rel"],
        "rel=next is the crawler hint that the list continues"

      # It does not say `hidden` in the MARKUP: the script hides it only once
      # the observer has taken over, so a no-IntersectionObserver browser sees
      # a working link rather than nothing at all.
      assert_nil more["hidden"]
    end
  end

  # ---- one renderer for every page ----

  test "the row and the card are partials, so an appended run is a rendered run" do
    row = File.read(Rails.root.join("app/views/jobs/_row.html.erb"))
    card = File.read(Rails.root.join("app/views/jobs/_card.html.erb"))
    index = File.read(Rails.root.join("app/views/jobs/index.html.erb"))

    assert_includes index, 'render partial: "jobs/row", collection: @jobs, as: :job'
    assert_includes index, 'render partial: "jobs/card", collection: @jobs, as: :job'
    assert_match(/<tr class="rowlink"/, row)
    assert_match(/class="job-card"/, card)
    # One renderer, one definition: a second inline copy in the index is the
    # drift this exists to prevent.
    refute_includes index, "<tr class=\"rowlink\""
    refute_includes index, "class=\"job-card\""
  end

  # ---- the script's contract with aether.js ----

  test "the scroll re-wires late markup through the hook aether.js exposes" do
    view = File.read(Rails.root.join("app/views/jobs/index.html.erb"))
    js = File.read(Rails.root.join("app/javascript/aether.js"))

    assert_includes js, "window.csRewireDynamic",
      "aether.js must expose the re-wiring hook, or an appended card's preview " \
      "and delete buttons are dead"
    assert_includes view, "window.csRewireDynamic()",
      "the scroll must call it after appending"

    # The next page comes from the RESPONSE's sentinel, not from a local
    # counter, and the fetch is latched: an observer still on screen fires
    # again immediately, so without the latch a tall page fires every request
    # at once.
    assert_includes view, "getElementById('jobs-scroll')"
    assert_includes view, "if (!next || loading) return;"
    assert_includes view, "loading = true;"
    assert_includes view, "!window.IntersectionObserver"
    # Delegated observer, created once: Turbo's body swap would otherwise stack
    # one per visit and leave the old one watching a detached sentinel.
    assert_includes view, "if (!window.__csJobsScroll)"
  end
end
