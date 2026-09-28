require "test_helper"

# The STATUS page: the candidate-triage LEARNING SIGNAL, drawn.
#
# Two documents are built from the owner's own rows -- a HIERARCHY (source → job
# → candidate) and an EVENT LOG (one row per recorded human action) -- and each
# is POSTed to chopshop-plot's matching operation, with the SVG the service
# answers with inlined.
#
# No service is contacted. PlotClient.post is swapped out (its own wire behaviour
# is covered in test/lib/plot_client_test.rb), so what is asserted here is what
# the page ASKS the service for -- the two specs -- plus the INLINING.
#
# The page has a second rendering path and it is pinned here too: with no plot
# runner configured the SAME two documents are drawn as plain HTML, a nested <ul>
# for the tree and an <ol> for the log. That is what a deployment without a plot
# service reads, and it is the path CI can assert without a live service.
class StatusPageTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # 127.0.0.1:1 rather than a hostname: the nav's runner pill asks every runner
  # for its health on each render, and a refused connection is instant where a
  # DNS lookup is not.
  PLOT_URL = "http://127.0.0.1:1".freeze

  SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="900" ' \
        'viewBox="0 0 1200 900"><text x="1" y="1">drawn</text></svg>'.freeze

  def sign_in
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  # A job with candidates in the (hard, advisory, id) order the table renders:
  # candidate_01 has hard 0 / advisory 1 and passed, candidate_02 has hard 2 and
  # did not pass, so the two exercise the pass and discard states.
  def job_with_candidates(name: "triage", source: "art.png",
                          candidates: [{ file: "candidate_01.svg", passed: true, hard: 0, advisory: 1, mae: 12.5 },
                                       { file: "candidate_02.svg", passed: false, hard: 2, advisory: 0, mae: nil }])
    job = Job.create!(name: name, state: "done", source_kind: "raster",
                      input_path: "/data/#{source}", stem: File.basename(source, ".*"),
                      spec: {}, runner: "mock")
    candidates.each do |c|
      job.candidates.create!(file: c[:file], passed: c[:passed], hard: c[:hard],
                             advisory: c[:advisory],
                             fidelity: c[:mae] ? { "measured" => true, "mae_art" => c[:mae] } : nil)
    end
    job
  end

  # EVERY runner variable is cleared first, so a test sees exactly what it asked
  # for. The box running the suite has real runners configured, and inheriting
  # them would make these assert the deployment instead of the code.
  def with_runners(map = {})
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    begin
      map.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def without_runners
    with_runners({}) { yield }
  end

  def with_plot_runner(url: PLOT_URL)
    with_runners({ "CHOPSHOP_RUNNER_PLOT_URL" => url, "CHOPSHOP_RUNNER_PLOT_KIND" => "plot" }) { yield }
  end

  # Minitest 6 dropped minitest/mock, so swap PlotClient.post and restore it,
  # collecting the (url, body) pairs the page sent.
  def capturing_plot_post(svg: SVG)
    calls = []
    original = PlotClient.method(:post)
    PlotClient.define_singleton_method(:post) do |url, body|
      calls << [url, body]
      { bytes: svg, content_type: "image/svg+xml", name: "plot.svg" }
    end
    yield calls
  ensure
    PlotClient.define_singleton_method(:post, original)
  end

  # A raising swap, for the service-is-down path.
  def refusing_plot_post(message: "plot 503: down")
    original = PlotClient.method(:post)
    PlotClient.define_singleton_method(:post) { |*| raise PlotClient::PlotError, message }
    yield
  ensure
    PlotClient.define_singleton_method(:post, original)
  end

  def nodes_of(spec, kind)
    spec["nodes"].select { |n| n["kind"] == kind }
  end

  def fetch_status
    sign_in
    get status_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
  end

  # -- the route and the nav -------------------------------------------------

  test "the page renders for a signed-in operator" do
    without_runners { fetch_status }
    assert_includes response.body, "STATUS"
  end

  test "the page is login-gated like every other authed page" do
    get status_path
    assert_redirected_to login_path
  end

  test "STATUS left the header nav; the footer's check-engine light leads here" do
    without_runners do
      fetch_status
      links = doc.css("nav.topbar .nav-links a").map { |a| [a.text.strip, a["href"]] }
      labels = links.map(&:first)
      refute_includes labels, "STATUS",
        "STATUS is no longer a header link -- the header row does not grow for a page that is a reference"
      # The one way in: the footer orb, which is an anchor to this page.
      orb = doc.at_css("a.engine-light")
      refute_nil orb, "the footer must carry the check-engine light"
      assert_equal status_path, orb["href"], "the light is the link to this page"
      assert_nil orb["data-popup"],
        "and it navigates rather than opening a popup"
    end
  end

  # -- the head is the house shape ------------------------------------------

  test "the head is the house shape: Run Job top, a secondary action below, blurb last" do
    without_runners do
      fetch_status
      head = doc.at_css(".page-head")
      row = head.at_css(".page-head-row")
      assert_includes row["class"].split, "page-head-row--stacked"
      assert_includes head.at_css(".section-title").text, "STATUS"

      run = head.at_css(".head-action--top")
      assert_equal "Run Job", run.text.strip

      secondary = head.at_css(".head-action--below")
      refute_nil secondary, "the row-2 action is the one the grid places"
      assert_equal events_path, secondary["href"]

      blurb = row.at_css(".page-head-blurb")
      refute_nil blurb
      assert_equal row.element_children.last, blurb,
        "blurb LAST in the row, or the phone media query drops it below the buttons"

      # A fuzzy patch once closed an ERB comment a line early on FLUX, so the
      # body rendered as visible page text and nothing else noticed.
      ["<%#", "%>", "@tree_spec", "status_ordered_candidates", "each do |"].each do |token|
        refute_includes response.body, token, "#{token} is ERB scaffolding, not page text"
      end
    end
  end

  # -- the two specs the page builds and posts -------------------------------

  test "the page posts a tree spec: source, job and candidate nodes with connecting edges" do
    job_with_candidates
    with_plot_runner do
      capturing_plot_post do |calls|
        fetch_status

        url, body = calls.find { |(u, _)| u.end_with?("/tree") }
        refute_nil url, "the tree operation must be called"
        assert_equal "#{PLOT_URL}/tree", url
        assert_equal "tree", body[:op]

        spec = body[:spec]
        assert_equal "tb", spec["layout"]
        assert_equal 1200, spec["size"]["width"]
        assert_equal 900, spec["size"]["height"]

        sources = nodes_of(spec, "source")
        jobs = nodes_of(spec, "job")
        candidates = nodes_of(spec, "candidate")
        assert_equal 1, sources.size, "one source node per job"
        assert_equal 1, jobs.size
        assert_equal 2, candidates.size

        assert_equal "art.png", sources.first["label"], "the root is the job's source"
        assert_equal "triage", jobs.first["label"]
        assert_equal %w[candidate_01.svg candidate_02.svg], candidates.map { |c| c["label"] },
          "candidates in the (hard, advisory, id) order the table renders"

        assert_equal %w[pass discard], candidates.map { |c| c["status"] }
        assert_equal({ "hard" => 0, "advisory" => 1, "mae_art" => 12.5 }, candidates.first["metrics"])
        assert_equal({ "hard" => 2, "advisory" => 0 }, candidates.last["metrics"],
          "mae_art is ABSENT, not zero, when the back half did not measure")

        # Edges: source -> job -> each candidate, and no dangling reference.
        ids = spec["nodes"].map { |n| n["id"] }
        assert_equal ids.uniq, ids, "every node id must be unique"
        edges = spec["edges"].map { |e| [e["from"], e["to"]] }
        assert_includes edges, [sources.first["id"], jobs.first["id"]]
        candidates.each { |c| assert_includes edges, [jobs.first["id"], c["id"]] }
        edges.flatten.each { |ref| assert_includes ids, ref, "#{ref} must name a node" }

        # JSON-safe: the whole envelope has to survive JSON.generate.
        assert JSON.generate(body)
      end
    end
  end

  test "the page posts a log spec, one row per event, in Event order" do
    job = job_with_candidates
    older = Event.create!(event: "star", job_id: job.id, svg_sha: nil, pos: 1,
                          payload: { "name" => "candidate_01.svg" },
                          created_at: 2.hours.ago, updated_at: 2.hours.ago)
    newer = Event.create!(event: "pick", job_id: job.id, svg_sha: "deadbeef", pos: 2,
                          created_at: 1.hour.ago, updated_at: 1.hour.ago)

    with_plot_runner do
      capturing_plot_post do |calls|
        fetch_status

        url, body = calls.find { |(u, _)| u.end_with?("/log") }
        refute_nil url, "the log operation must be called"
        assert_equal "#{PLOT_URL}/log", url
        assert_equal "log", body[:op]

        spec = body[:spec]
        assert_equal 600, spec["size"]["height"]
        events = spec["events"]
        assert_equal [newer.id, older.id], Event.recent.ids, "Event.recent is the source order"
        assert_equal %w[pick star], events.map { |e| e["kind"] }, "newest first"
        assert_equal newer.created_at.iso8601, events.first["t"]
        assert_equal 2, events.first["pos"]
        assert_equal "deadbeef", events.first["label"], "the checksum is the honest name"
        assert_equal "candidate_01.svg", events.last["label"],
          "no checksum -> the action's own payload name"
        assert_equal 1, events.last["pos"]
      end
    end
  end

  test "a log row with neither a checksum nor a payload name falls back to its job" do
    job = job_with_candidates
    Event.create!(event: "delete", job_id: job.id, svg_sha: nil, pos: nil, payload: {})

    with_plot_runner do
      capturing_plot_post do |calls|
        fetch_status
        spec = calls.find { |(u, _)| u.end_with?("/log") }[1][:spec]
        assert_equal "job ##{job.id}", spec["events"].first["label"]
        assert_nil spec["events"].first["pos"]
      end
    end
  end

  test "the service's SVG is inlined into a .status-svg wrapper, one per panel" do
    job_with_candidates
    with_plot_runner do
      capturing_plot_post do |calls|
        fetch_status
        assert_equal %w[tree log], calls.map { |(u, _)| File.basename(u) }

        d = doc
        assert_equal 2, d.css(".status-svg").size
        assert d.at_css("[data-status-svg='tree'] svg"), "the tree SVG is inlined"
        assert d.at_css("[data-status-svg='log'] svg"), "the log SVG is inlined"
        assert_nil d.at_css(".status-tree"), "no HTML fallback when the service answered"
        assert_includes response.body, "drawn"
      end
    end
  end

  # -- the HTML fallback: no runner, and a runner that will not answer --------

  test "with no plot runner the tree renders as the nested source -> job -> candidate list" do
    job_with_candidates
    without_runners do
      fetch_status
      d = doc
      assert_nil d.at_css(".status-svg"), "nothing is drawn without a plot runner"

      tree = d.at_css("[data-status-fallback='tree'] ul.status-tree")
      refute_nil tree, "the tree must still be readable as HTML"

      source = tree.element_children.first
      assert_includes source["class"].split, "status-node--source"
      assert_includes source.text, "art.png"

      job_li = source.element_children.find { |el| el.name == "ul" }.element_children.first
      assert_includes job_li["class"].split, "status-node--job"
      assert_includes job_li.text, "triage"

      cand_lis = job_li.element_children.find { |el| el.name == "ul" }.element_children
      assert_equal 2, cand_lis.size
      assert_equal %w[candidate_01.svg candidate_02.svg],
        cand_lis.map { |li| li.at_css(".status-label").text.strip }
      assert_includes cand_lis.first.text, "pass"
      assert_includes cand_lis.first.text, "hard 0"
      assert_includes cand_lis.first.text, "advisory 1"
      assert_includes cand_lis.first.text, "mae_art 12.5"
      assert_includes cand_lis.last.text, "discard"
      refute_includes cand_lis.last.text, "mae_art",
        "a missing measurement is absent here too, not a zero"
    end
  end

  test "with no plot runner the log renders as an ordered list of rows, in Event order" do
    job = job_with_candidates
    Event.create!(event: "star", job_id: job.id, svg_sha: "abc", pos: nil,
                  created_at: 2.hours.ago, updated_at: 2.hours.ago)
    Event.create!(event: "pick", job_id: job.id, svg_sha: "def", pos: 3,
                  created_at: 1.hour.ago, updated_at: 1.hour.ago)

    without_runners do
      fetch_status
      d = doc
      assert_nil d.at_css(".status-svg")

      log = d.at_css("ol.status-log")
      refute_nil log, "the log must still be readable as HTML"
      rows = log.element_children
      assert_equal 2, rows.size
      assert_equal %w[pick star], rows.map { |r| r.at_css(".status-kind").text.strip },
        "newest first, the same order the spec carries"

      first = rows.first
      assert_equal "def", first.at_css(".status-label").text.strip
      assert_includes first.text, "#3", "the recorded position is shown when there is one"
      refute_nil first.at_css("time")["datetime"], "each row carries a timestamp"
      refute_includes rows.last.text, "#", "star recorded no position, so no # is printed"
    end
  end

  test "the HTML fallback escapes a label instead of rendering it" do
    job = job_with_candidates(name: "<b>triage</b>", source: "<i>art.png",
                              candidates: [{ file: "<script>x</script>", passed: true, hard: 0, advisory: 0, mae: nil }])
    Event.create!(event: "star", job_id: job.id, svg_sha: "<em>café & co</em>", pos: 1)

    without_runners do
      fetch_status
      assert_includes doc.text, "<b>triage</b>", "a label is read as TEXT"
      assert_includes doc.text, "<i>art.png"
      assert_includes doc.text, "<em>café & co</em>"
      refute_includes response.body, "<b>triage</b>", "and never as markup"
      refute_includes response.body, "<script>x</script>"
    end
  end

  test "a configured runner that refuses falls back to the HTML rather than 500ing" do
    job_with_candidates
    with_plot_runner do
      refusing_plot_post do
        fetch_status
        assert_includes response.body, "could not draw these panels"
        assert doc.at_css("ul.status-tree"), "the data is still rendered"
        assert_nil doc.at_css(".status-svg")
      end
    end
  end

  test "an operator with no jobs and no events still gets a page, not an error" do
    without_runners do
      fetch_status
      assert_includes response.body, "No jobs yet"
      assert_includes response.body, "Nothing recorded yet"
    end
  end

  # -- the four cross-page registries list this page -------------------------

  test "this page is registered in every cross-page head list" do
    root = Rails.root
    assert_includes File.read(root.join("test/controllers/page_head_uniformity_test.rb")),
                    '"pages/status.html.erb" => "STATUS"'
    assert_includes File.read(root.join("test/controllers/head_action_size_test.rb")),
                    '"status" => status_path'
    alignment = File.read(root.join("test/controllers/head_alignment_test.rb"))
    assert_includes alignment, "status"
    assert_includes alignment, "assert_equal 8, RUN_JOB_PAGES.size"
    responsive = File.read(root.join("test/controllers/responsive_head_test.rb"))
    assert_operator responsive.scan("pages/status.html.erb").size, :>=, 2,
      "both the ordering list and the short-blurb list name this page"
  end
end
