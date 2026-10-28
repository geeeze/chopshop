require "test_helper"

# THE RUN-STATE FILTER ON THE JOBS LIST (#10) — the kb's `per (294)` idiom.
#
# The list is the project workspace (GET /projects/:id); the standalone /jobs
# index was deleted in the Projects redesign, so this is where the run list
# lives and where the filter belongs. The filter is `?state=<Job::STATES>` and
# its options CARRY THE COUNTS, so the operator sees the distribution before
# choosing instead of filtering to find out.
#
# The contract, asserted here rather than assumed:
#   * every option's number is the number of rows that option produces (read
#     off the served page for each state, not off a second calculation);
#   * the whole closed vocabulary is offered, zeros included, so an option
#     never appears or disappears between renders;
#   * an unknown or blank value is NO filter -- a stale bookmark cannot empty
#     the list;
#   * an empty RESULT SET says "no records match. clear the filters." and
#     offers the reset link, while an empty PROJECT still says it has no runs.
class JobsStateFilterTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def login!
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
  end

  def doc_at(path)
    login!
    get path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def job(project, name, state: "done")
    Job.create!(name: name, state: state, source_kind: "svg",
                input_path: "/data/#{name}.svg", stem: name, spec: {},
                runner: "mock", project: project,
                comparison: { "candidates" => [] })
  end

  def options(doc)
    select = doc.at_css("#jobs-state-filter")
    refute_nil select, "the run list carries a state filter"
    select.css("option").map { |o| [ o["value"].to_s, o.text.strip ] }
  end

  def seeded_project
    project = Project.create!(name: "state-filter-probe", is_test: true)
    job(project, "filter-done-a", state: "done")
    job(project, "filter-done-b", state: "done")
    job(project, "filter-error", state: "error")
    project
  end

  test "every option carries the count of the rows it would show" do
    project = seeded_project
    doc = doc_at(project_path(project))

    assert_equal [ [ "", "any (3)" ],
                   [ "pending", "pending (0)" ],
                   [ "queued", "queued (0)" ],
                   [ "running", "running (0)" ],
                   [ "done", "done (2)" ],
                   [ "error", "error (1)" ],
                   [ "cancelled", "cancelled (0)" ] ],
                 options(doc),
                 "the closed vocabulary, in Job::STATES order, each with its count"
  end

  test "an option's number IS the number of rows it produces" do
    project = seeded_project
    doc = doc_at(project_path(project))

    # Read the count off the served select, then ask the page for that state
    # and count what came back. A count computed in one place and rows in
    # another is exactly the drift this pins against.
    options(doc).reject { |value, _| value.empty? }.each do |value, label|
      count = label[/\((\d+)\)/, 1].to_i
      rows = doc_at(project_path(project, state: value)).css("#jobs-list tbody tr").size
      assert_equal count, rows, "state=#{value}: the option said #{count}, the list rendered #{rows}"
    end
  end

  test "a state with no runs is still offered, so the vocabulary never shifts" do
    project = Project.create!(name: "state-filter-quiet", is_test: true)
    job(project, "filter-only-done", state: "done")

    assert_equal 6, options(doc_at(project_path(project))).reject { |v, _| v.empty? }.size,
                 "all six states are always in the select, zeros included"
  end

  test "an unknown or blank state is no filter at all" do
    project = seeded_project

    assert_equal 3, doc_at(project_path(project, state: "bogus")).css("#jobs-list tbody tr").size,
                 "a stale bookmark cannot silently empty the list"
    assert_equal 3, doc_at(project_path(project)).css("#jobs-list tbody tr").size,
                 "and the plain page is unchanged"
  end

  test "the counts are this project's own, not the workspace's" do
    project = seeded_project
    other = Project.create!(name: "state-filter-other", is_test: true)
    5.times { |i| job(other, "other-done-#{i}", state: "done") }

    labels = options(doc_at(project_path(project))).to_h
    assert_equal "any (3)", labels[""], "another project's runs do not inflate the census"
    assert_equal "done (2)", labels["done"]
  end

  test "an empty result set says so honestly and offers the way out" do
    project = Project.create!(name: "state-filter-empty-result", is_test: true)
    job(project, "empty-result-done", state: "done")

    doc = doc_at(project_path(project, state: "error"))
    assert_empty doc.css("#jobs-list tbody tr"), "nothing matched, so nothing is listed"

    empty = doc.at_css("#jobs-list .empty-state")
    refute_nil empty, "the empty-state card renders"
    assert_includes empty.text, "no records match. clear the filters."
    reset = empty.at_css("a.query-clear")
    refute_nil reset, "and the reset link is there"
    assert_equal project_path(project), reset["href"], "pointing back at the unfiltered list"
    refute_includes empty.text, "No runs in this project yet",
                    "an empty result is not an empty project"

    # The grid view renders the same partial, so it cannot disagree.
    assert_includes doc.at_css("#jobs-grid .empty-state").text,
                    "no records match. clear the filters."
  end

  test "an unfiltered empty project still says it has no runs yet" do
    project = Project.create!(name: "state-filter-empty-project", is_test: true)
    doc = doc_at(project_path(project))

    empty = doc.at_css("#jobs-list .empty-state")
    refute_nil empty
    assert_includes empty.text, "No runs in this project yet"
    refute_includes empty.text, "no records match", "there was no filter to clear"
  end
end
