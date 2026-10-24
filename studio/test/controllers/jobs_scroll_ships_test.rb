require "test_helper"

# The class of bug this file exists for, and it is a humbling one.
#
# The infinite scroll was built, tested eight ways, and shipped. It did not
# work. The whole <script> block was inside an ERB comment that was terminated
# by `-->` instead of `%>`, so ERB swallowed every line from the comment's
# opening tag to the next `%>` in the file -- which was two hundred lines later,
# in an unrelated comment. The template still parsed. The page still returned
# 200. The row-click script and the view-toggle script on either side of it
# rendered perfectly, because they were OUTSIDE the swallowed span.
#
# Every test passed, because every test read the TEMPLATE FILE. The file
# contains the script. The server was never asked.
#
# So the assertion that matters is the one against the rendered response body,
# and it is here so the next person does not learn this twice.
#
# The infinite scroll itself was deleted in the Projects redesign
# (2026-09-30): GET /jobs and its scroll script are gone, and the jobs list
# now lives on the project workspace (GET /projects/:id), which lists all the
# project's runs unpaginated. What this file keeps is the contract the scroll
# bug taught, re-pointed at the script the workspace list ACTUALLY ships -- the
# List/Grid toggle -- because an ERB-comment-swallowed script is a bug of any
# template, not of the deleted one.
class JobsScrollScriptActuallyShipsTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"

  setup do
    @previous = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect, "the test could not log in, so every assertion below is vacuous"
  end

  teardown { ENV["CHOPSHOP_PASSWORD"] = @previous }

  # The project whose workspace page carries the jobs list and its script.
  # Job belongs_to :project (optional: true), so the probe job is named with
  # the project -- a job with no project is UI-invisible.
  def workspace
    @workspace ||= Project.create!(name: "ships-workspace", is_test: true)
  end

  test "the jobs-list script is IN THE RENDERED PAGE, not merely in the template" do
    # Re-pointed from the deleted infinite scroll to the script the workspace
    # list actually ships: the List/Grid toggle (projects/show.html.erb). The
    # contract is the same one the scroll bug broke -- the script must survive
    # ERB and reach the BROWSER, so it is asserted against the response body,
    # not the template file.
    Job.create!(name: "ships-job", state: "done", source_kind: "svg",
                input_path: "/d/s.svg", stem: "s", spec: {}, runner: "mock",
                comparison: { "candidates" => [] }, project: workspace)
    get project_path(workspace), headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    body = response.body

    # The three things the toggle script is made of, all of which have to
    # survive ERB.
    assert_includes body, "window.__csJobsView",
      "the toggle script did not reach the browser. An ERB comment closed with " \
      "--> rather than %> swallows everything up to the next %> in the file, " \
      "and the swallowed script leaves no trace in the template or the status."
    assert_includes body, "getElementById('jobs-list')",
      "the script reached the page but does not know what it is watching"
    assert_includes body, "localStorage",
      "the script is present but the view choice it persists is missing"

    # And the trap itself, asserted directly so it cannot come back wearing a
    # different template: no ERB comment in the workspace template may run past
    # a <script>.
    src = File.read(Rails.root.join("app/views/projects/show.html.erb"))
    i = 0
    while (start = src.index("<%#", i))
      stop = src.index("%>", start)
      break if stop.nil?
      span = src[start...stop]
      refute_includes span, "<script",
        "an ERB comment starting at byte #{start} swallows a <script> block; " \
        "a comment is closed by %> and by nothing else"
      i = stop + 2
    end
  end

  # ---------------------------------------------------------------------------
  # RETIRED -- "the fallback link appears only while there IS a next page".
  # Pinned to a surface the Projects redesign (2026-09-30) deleted: the
  # .jobs-scroll-more fallback link, the #jobs-scroll sentinel that decided
  # whether to render it, and the page-2 URL it pointed at. The project
  # workspace lists all the project's runs unpaginated -- there is no next
  # page to offer, in either direction, so the contract has no live surface.
  # Named here rather than silently dropped so the absence is deliberate.
  # ---------------------------------------------------------------------------
end
