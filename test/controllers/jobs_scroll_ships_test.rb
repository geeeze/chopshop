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
class JobsScrollScriptActuallyShipsTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"

  setup do
    @previous = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect, "the test could not log in, so every assertion below is vacuous"
  end

  teardown { ENV["CHOPSHOP_PASSWORD"] = @previous }

  test "the scroll script is IN THE RENDERED PAGE, not merely in the template" do
    get jobs_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    body = response.body

    # The three things the scroll is made of, all of which have to survive ERB.
    assert_includes body, "IntersectionObserver",
      "the scroll script did not reach the browser. An ERB comment closed with " \
      "--> rather than %> swallows everything up to the next %> in the file, " \
      "and the swallowed script leaves no trace in the template or the status."
    assert_includes body, "getElementById('jobs-scroll')",
      "the script reached the page but does not know what it is watching"
    assert_includes body, "appendPage",
      "the script is present but the append path is missing"

    # And the trap itself, asserted directly so it cannot come back wearing a
    # different template: no ERB comment in this file may run past a <script>.
    src = File.read(Rails.root.join("app/views/jobs/index.html.erb"))
    depth, i = 0, 0
    while (start = src.index("<%#", i))
      stop = src.index("%>", start)
      break if stop.nil?
      span = src[start...stop]
      refute_includes span, "<script",
        "an ERB comment starting at byte #{start} swallows a <script> block; " \
        "a comment is closed by %> and by nothing else"
      i = stop + 2
    end
    assert depth.zero?
  end

  test "the fallback link appears only while there IS a next page" do
    # The link and the observer are two answers to one question, and the honest
    # answer when the list fits is "there is no next page" -- so the link is
    # absent, not present-and-pointing-nowhere. Both directions are asserted,
    # because a link that always renders is a link to an empty page and an
    # operator clicking it sees a blank list and concludes the data is gone.
    3.times do |i|
      Job.create!(name: "short-#{i}", state: "done", source_kind: "svg",
                  input_path: "/d/#{i}.svg", stem: "s#{i}", spec: {},
                  runner: "mock", comparison: { "candidates" => [] })
    end
    get jobs_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    # On the PARSED DOM, not the raw body: the string "jobs-scroll-more" also
    # occurs inside the script, so a substring assertion on the HTML cannot
    # tell a rendered link from a selector for one.
    refute Nokogiri::HTML(response.body).at_css("a.jobs-scroll-more"),
      "three jobs fit one page, so offering a 'Load more' link is a link to an empty page"
    assert_includes response.body, "IntersectionObserver",
      "and the script still ships regardless of how full the page is"
  end
end
