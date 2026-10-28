require "test_helper"

# THE CENSUS LINE (#10) — the kb's right-aligned mono status line ("1004
# records · 8 classes"), backported as ONE helper and ONE slot.
#
# The line exists so every list page states its own scale at a glance, and it
# is asserted against the SERVED page rather than against the helper's return
# value: a helper that formats perfectly and is never rendered is the failure
# mode this file is for.
#
# What it must be:
#   * rendered in the HEADER — the layout's `.nav-side` slot, carrying
#     #header-census — and ONLY there: the views no longer render it, so one
#     line serves the whole app and the header cannot disagree with the page;
#   * mono and right-aligned, in the `.page-census` slot;
#   * the PAGE's numbers, not the workspace's — a ?q= narrows the list, so the
#     census reads "1 of 2 projects", and a filtered workspace reads "1 of 2
#     jobs";
#   * absent where a page has no scale to state (a form), rather than printing
#     "0 jobs".
class CensusLineTest < ActionDispatch::IntegrationTest
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

  # The line's ONE slot: the header's `.nav-side`. Asserting the slot (not just
  # the id) is what pins the header home — a span rendered under the page head
  # would still satisfy `at_css("#header-census")`, and that is the failure this
  # file was written to replace.
  def census(doc)
    span = doc.at_css("nav.topbar .nav-side #header-census")
    refute_nil span, "the census line lives in the header's .nav-side slot"
    span
  end

  def css
    File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  test "the projects index states the workspace's scale, right-aligned and mono" do
    a = Project.create!(name: "census-a", is_test: false)
    Project.create!(name: "census-b", is_test: false)
    3.times { |i| job(a, "census-a-#{i}") }

    span = census(doc_at(projects_path))
    assert_includes span["class"].split, "mono", "the line is mono, like the kb's .status"
    assert_includes span["class"].split, "page-census", "and sits in its own slot"

    text = span.text
    assert_includes text, "2 projects"
    assert_includes text, "3 jobs"
    assert_includes text, "0 candidates"
    assert_includes text, " · ", "the parts are one line, separated, not a list"

    # Right-aligned is the whole look of the line, and it lives in CSS: a span
    # that renders left-hung is the kb idiom only half-copied.
    assert_match(/\.page-census \{[^}]*text-align: right/m, css,
                 "the census slot is right-aligned")
  end

  test "a search states what it found out of what exists" do
    Project.create!(name: "census-needle-project", is_test: false)
    Project.create!(name: "census-other-project", is_test: false)

    text = census(doc_at(projects_path(q: "needle"))).text
    assert_includes text, "1 of 2 projects",
                    "a narrowed list must not claim the workspace's total as its own"
    refute_includes text, "2 of 2", "and the filtered count is the filtered count"
  end

  test "the project workspace states its own runs, candidates and proofs" do
    project = Project.create!(name: "census-workspace", is_test: true)
    done = job(project, "census-done", state: "done")
    job(project, "census-error", state: "error")
    Candidate.create!(job: done, file: "candidate_01.svg")

    text = census(doc_at(project_path(project))).text
    assert_includes text, "2 jobs", "the workspace's own runs, not the studio's"
    assert_includes text, "1 candidate"
    assert_includes text, "0 proofs"
  end

  test "a filtered run list says how many of how many it is showing" do
    project = Project.create!(name: "census-filtered", is_test: true)
    job(project, "census-filtered-done", state: "done")
    job(project, "census-filtered-error", state: "error")

    text = census(doc_at(project_path(project, state: "done"))).text
    assert_includes text, "1 of 2 jobs",
                    "the page is showing one run of two, and says so"
  end

  test "a page with no scale to state renders no census at all" do
    doc = doc_at(new_project_path)
    assert_nil doc.at_css("#header-census"),
               "a form has no corpus to count -- an empty line would be noise"
  end

  test "the census line renders in the header's nav-side slot, exactly once" do
    Project.create!(name: "census-header-slot", is_test: false)

    doc = doc_at(projects_path)
    span = census(doc)

    refute_nil doc.at_css("nav.topbar .nav-side .page-census"),
               "it carries its own class inside the header slot"
    assert_equal 1, doc.css("#header-census").size,
                 "ONE slot, ONE line: the header renders it and the views must not repeat it"
    assert_nil doc.at_css("main #header-census"),
               "the page body no longer renders a second copy under the head"

    # The header slot has its own rule: the helper's block margin is for a line
    # under a page head, and in a centred flex row it would misalign the header.
    assert_match(/\.nav-side \.page-census \{[^}]*margin: 0/m, css,
                 "the header slot drops the block margin")
  end

  test "the ?q= search (#50) and the ?state= run filter (#10) each narrow their own surface" do
    needle = Project.create!(name: "census-needle", is_test: false)
    Project.create!(name: "census-decoy", is_test: false)
    job(needle, "census-needle-done", state: "done")
    job(needle, "census-needle-error", state: "error")

    # The index reads ?q= and ignores ?state= (which belongs to the run list), so
    # a URL carrying BOTH parameters still searches — the new filter did not
    # disturb the search that #50 landed.
    index = doc_at(projects_path(q: "needle", state: "done"))
    assert_equal [ "census-needle" ],
                 index.css("#projects-list tbody tr td a.cs-job-name").map(&:text),
                 "the ?q= search still narrows the projects list"
    assert_includes census(index).text, "1 of 2 projects",
                    "and the census reports the search's own result"

    # The workspace reads ?state= and ignores ?q=, so the run filter still works.
    show = doc_at(project_path(needle, state: "done", q: "needle"))
    assert_equal 1, show.css("#jobs-list tbody tr").size,
                 "the ?state= filter still narrows the run list"
    assert_includes census(show).text, "1 of 2 jobs",
                    "and the census reports the filter's own result"
  end
end
