require "test_helper"

# The STATUS page: what the studio has PRODUCED and what the HOST has been doing,
# drawn by chopshop-bp's `digest` operation, plus the candidate-triage event log
# (bp's `log` operation).
#
# No service is contacted. PlotClient.post is swapped out (its own wire behaviour
# is covered in test/lib/plot_client_test.rb), so what is asserted here is what
# the page ASKS the service for -- the three specs -- plus the INLINING.
#
# Two other contracts are pinned here because the page changed shape and they are
# what keep it from drifting back:
#
#   * THE HIERARCHY IS GONE. source -> job -> candidate was replaced by the
#     pipeline-use tally and the server chart; the absence is asserted
#     structurally (no panel, no nested list, no `tree` operation) rather than by
#     grepping a word that could survive in a comment or a title.
#   * the page has a second rendering path: with no blend-plot runner configured
#     the SAME numbers are rendered as the page's own HTML, and with nothing to
#     draw (no samples, nothing produced) NO document is asked for at all. That is
#     what a deployment without the service reads, and it is the path CI can
#     assert without a live service.
class StatusPageTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # 127.0.0.1:1 rather than a hostname: the nav's runner pill asks every runner
  # for its health on each render, and a refused connection is instant where a
  # DNS lookup is not.
  PLOT_URL = "http://127.0.0.1:1".freeze
  BP_URL   = "http://127.0.0.1:2".freeze
  # The generator. A flux runner has to be CONFIGURED for a generated job to be
  # created at all -- Job validates the runner label against the configured list.
  FLUX_URL = "http://127.0.0.1:3".freeze

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
  # did not pass. Two candidates are enough for the use tally's `traced` count.
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

  # A generation job: the only thing that makes `generated` non-zero. It records
  # the images it produced in its OWN spec, which is what the tally counts --
  # not the configured runner kinds, which are deployment configuration.
  def generated_job(images: 2)
    Job.create!(name: "gen", state: "done", source_kind: "raster", runner: "flux",
                input_path: "/data/gen-01.png", stem: "gen-01",
                spec: { "flux" => { "prompt" => "a fox", "rendered" => { "images" => Array.new(images) { |i| { "file" => "gen-#{i}.png" } } } } })
  end

  # A finished proof, so the tally's `proofs` count is real.
  def proof_for(job)
    job.validations.create!(file: "candidate_01.svg", state: "done")
  end

  # Three minutes of the host, one sample per bucket: the server chart's data.
  def seed_host_samples(count: 3, now: Time.current, swap: true)
    count.times do |i|
      HostSample.create!(captured_at: now - i * HostSample::BUCKET_SECONDS,
                         cpu_pct: 20.0 + i, mem_pct: 40.0 + i,
                         mem_total_mb: 3777, mem_used_mb: 1600, load1: 0.5,
                         swap_total_mb: swap ? 1953 : 0, swap_pct: swap ? 18.0 : nil,
                         swap_used_mb: swap ? 350 : nil)
    end
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

  def with_bp_runner(url: BP_URL)
    with_runners({ "CHOPSHOP_RUNNER_BP_URL" => url, "CHOPSHOP_RUNNER_BP_KIND" => "bp" }) { yield }
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

  # The spec the page posted for one operation, or nil when it asked for nothing.
  def spec_for(calls, op = "digest", index: 0)
    matched = calls.select { |(u, _)| u.end_with?("/#{op}") }
    matched[index]&.last&.dig(:spec)
  end

  # The two charts are found by their TYPE, not by call order: the page skips a
  # chart it has nothing to draw, so an index would couple these tests to whether
  # a fixture happened to produce one.
  def digests(calls)
    calls.select { |(u, _)| u.end_with?("/digest") }.map { |(_, body)| body[:spec] }
  end

  def bar_spec(calls)
    digests(calls).find { |spec| spec["chart"] == "bar" }
  end

  def line_spec(calls)
    digests(calls).find { |spec| spec["chart"] == "line" }
  end

  # One recorded action, so the page has a log to draw.
  def event_for(job, kind: "pick")
    Event.create!(event: kind, job_id: job.id, svg_sha: "abc", pos: 1)
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
      ["<%#", "%>", "@use_spec", "@host_spec", "@use_bars", "status_host_size", "each do |"].each do |token|
        refute_includes response.body, token, "#{token} is ERB scaffolding, not page text"
      end
    end
  end

  # -- the hierarchy is gone ------------------------------------------------

  test "the hierarchy is gone: no panel, no nested list, and no tree operation" do
    job_with_candidates
    seed_host_samples
    with_bp_runner do
      capturing_plot_post do |calls|
        fetch_status
        d = doc

        assert_nil d.at_css("[data-status-panel='hierarchy']"), "the hierarchy panel is gone"
        assert_nil d.at_css("[data-status-svg='tree']")
        assert_nil d.at_css(".status-tree"), "and so is its HTML fallback"
        assert_nil d.at_css("[data-status-fallback='tree']")

        # Structurally: the operation is never asked for. A grep for the word
        # "tree" would match this page's own prose and prove nothing.
        refute_includes calls.map { |(u, _)| File.basename(u) }, "tree",
          "the page must not ask the service for a hierarchy at all"

        # The panels that REPLACED it are here.
        assert d.at_css("[data-status-panel='use']")
        assert d.at_css("[data-status-panel='server']")
      end
    end
  end

  # -- the three specs the page builds and posts ----------------------------

  test "the page posts a pipeline-use bar chart with one bar per produced kind" do
    # A flux runner has to be CONFIGURED for a generated job to be created at
    # all: `Job` validates the runner label against the configured list, and a
    # generated job is what makes `generated` non-zero.
    with_runners({ "CHOPSHOP_RUNNER_FLUX_URL" => FLUX_URL, "CHOPSHOP_RUNNER_FLUX_KIND" => "flux",
                   "CHOPSHOP_RUNNER_BP_URL" => BP_URL, "CHOPSHOP_RUNNER_BP_KIND" => "bp" }) do
      job = job_with_candidates
      proof_for(job)
      generated_job(images: 2)
      ScrapbookItem.create!(name: "candidate_01.svg", kind: "candidate", file: "candidate_01.svg")
      Composite.create!(name: "flyer", width: 600, height: 400)
      seed_host_samples

      expected = EngineMetrics.use
      assert_equal 2, expected[:jobs], "the fixture must exercise more than one bar"
      assert_equal 2, expected[:generated]
      assert_equal 2, expected[:traced]
      assert_equal 1, expected[:proofs]
      assert_equal 1, expected[:scrapbooked]
      assert_equal 1, expected[:composited]

      capturing_plot_post do |calls|
        fetch_status

        url, body = calls.find { |(u, _)| u.end_with?("/digest") }
        refute_nil url, "the use chart must be drawn"
        assert_equal "#{BP_URL}/digest", url
        assert_equal "digest", body[:op]

        spec = bar_spec(calls)
        refute_nil spec, "the use chart is drawn"
        assert_equal "bar", spec["chart"],
          "six unrelated totals: a line between them would imply a progression"
        assert_equal 1200, spec["size"]["width"]
        assert_equal %w[jobs generated traced proofs scrapbooked composited], spec["data"]["labels"]
        assert_equal expected.values_at(*PagesController::USE_BARS.map(&:last)),
                     spec["data"]["series"].first["values"],
          "the bars are the SAME hash the tiles and /engine.json read"

        # The tiles carry the numbers beside the drawing, from the same hash.
        d = doc
        assert_equal "2", d.at_css("[data-use-count='traced']").text.strip
        assert_equal "1", d.at_css("[data-use-count='composited']").text.strip
        assert_equal %w[jobs generated traced proofs scrapbooked composited],
                     d.css("[data-use-strip] [data-use-count]").map { |el| el["data-use-count"] },
          "the strip's order is the chart's order, from one list"

        assert JSON.generate(body)
      end
    end
  end

  test "the produced tally counts a generated file from the JOB's record, not from config" do
    # The runner is deliberately NOT a flux label: `generated_variations` reads
    # `spec["flux"]` without asking what is configured, so a box whose
    # CHOPSHOP_RUNNER_FLUX_* line was removed still reports the rasters its jobs
    # produced. A tally that went through the kind would report zero files here.
    job = Job.create!(name: "gen", state: "done", source_kind: "raster", runner: "mock",
                      input_path: "/data/gen-01.png", stem: "gen-01",
                      spec: { "flux" => { "prompt" => "a fox",
                                          "rendered" => { "images" => [{ "file" => "gen-0.png" },
                                                                       { "file" => "gen-1.png" }] } } })
    assert_equal 2, EngineMetrics.use[:generated]
    assert_equal 2, job.generated_variations.size
    assert_empty job.flux_variations, "the kind-gated reader still answers for its own kind only"
  end

  test "the page posts a server line chart: cpu and memory, plus swap when the box has it" do
    seed_host_samples(count: 3, swap: true)

    with_bp_runner do
      capturing_plot_post do |calls|
        fetch_status

        spec = line_spec(calls)
        refute_nil spec, "the server chart is drawn"
        assert_equal "line", spec["chart"]
        assert_equal %w[cpu\ % mem\ % swap\ %], spec["data"]["series"].map { |s| s["name"] }
        assert_equal 3, spec["data"]["labels"].length
        assert_equal 3, spec["data"]["series"].first["values"].length
        assert_equal [20.0, 21.0, 22.0].sort, spec["data"]["series"].first["values"].sort,
          "the values are the samples, aggregated per bucket"

        # Every value is a NUMBER: bp's contract refuses a null, which is exactly
        # why an unmeasured reading must never be smuggled in as one.
        spec["data"]["series"].each do |series|
          series["values"].each { |v| assert_kind_of Numeric, v }
        end
      end
    end
  end

  test "a box with no swap gets two series, not a swap line drawn at zero" do
    seed_host_samples(count: 2, swap: false)

    with_bp_runner do
      capturing_plot_post do |calls|
        fetch_status
        spec = line_spec(calls)
        refute_nil spec
        assert_equal %w[cpu\ % mem\ %], spec["data"]["series"].map { |s| s["name"] },
          "no swap reading exists, so there is no swap series"
      end
    end
  end

  test "the newest reading is shown as tiles, with the moment it was taken" do
    seed_host_samples(count: 3, swap: true)

    without_runners do
      fetch_status
      d = doc
      # The tiles show the NEWEST sample, not the newest value: the fixture's
      # samples step upward as they get OLDER (cpu 20 + i at now - i buckets).
      assert_equal "20.0%", d.at_css("[data-host-value='cpu']").text.strip
      assert_equal "1.6 GB / 3.7 GB", d.at_css("[data-host-value='memory']").text.strip
      assert_includes d.at_css("[data-host-value='swap']").text, "350 MB"
      assert_equal "0.5", d.at_css("[data-host-value='load']").text.strip
      assert_match(/\d{2}:\d{2} UTC/, d.at_css("[data-host-sampled-at]").text)
      assert_nil d.at_css("[data-host-stale]"), "a minute-old sample is not stale"
    end
  end

  test "a stopped sampler says so instead of presenting an old reading as current" do
    HostSample.create!(captured_at: 3.hours.ago, cpu_pct: 12.0, mem_pct: 30.0,
                       mem_total_mb: 3777, mem_used_mb: 1200, swap_total_mb: 0)

    without_runners do
      fetch_status
      stale = doc.at_css("[data-host-stale]")
      refute_nil stale, "the sampler stopped: the page must say it"
      assert_includes stale.text, "stopped"
      assert_includes response.body, "host_sample", "and name the task that should be running"
    end
  end

  test "an unmeasured reading prints a dash, never a zero" do
    # The first sample after a restart has no predecessor, so no CPU percentage.
    HostSample.create!(captured_at: Time.current, cpu_pct: nil, mem_pct: nil,
                       mem_total_mb: 3777, mem_used_mb: nil, swap_total_mb: 0, load1: nil)

    without_runners do
      fetch_status
      d = doc
      assert_equal "—", d.at_css("[data-host-value='cpu']").text.strip
      assert_includes d.at_css("[data-host-value='swap']").text, "none configured"
      assert_equal "—", d.at_css("[data-host-value='load']").text.strip
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

  # -- which runner, and the inlining ---------------------------------------

  test "a bp runner is preferred over the legacy plot kind on the same box" do
    job = job_with_candidates
    event_for(job)
    seed_host_samples

    with_runners({ "CHOPSHOP_RUNNER_PLOT_URL" => PLOT_URL, "CHOPSHOP_RUNNER_PLOT_KIND" => "plot",
                   "CHOPSHOP_RUNNER_BP_URL" => BP_URL, "CHOPSHOP_RUNNER_BP_KIND" => "bp" }) do
      capturing_plot_post do |calls|
        fetch_status
        assert_equal [BP_URL], calls.map { |(u, _)| u.sub(%r{/[^/]+\z}, "") }.uniq,
          "one service, one base URL: the BP action covers all six operations"
        assert_equal %w[digest digest log], calls.map { |(u, _)| File.basename(u) }
        assert_includes doc.css(".status-pill").map(&:text).join(" "), "bp → chopshop-bp"
      end
    end
  end

  test "with only the legacy plot kind configured the page still draws" do
    job = job_with_candidates
    event_for(job)
    seed_host_samples

    with_plot_runner do
      capturing_plot_post do |calls|
        fetch_status
        assert_equal %w[digest digest log], calls.map { |(u, _)| File.basename(u) }
        assert_equal [PLOT_URL], calls.map { |(u, _)| u.sub(%r{/[^/]+\z}, "") }.uniq
      end
    end
  end

  test "the service's SVG is inlined into a .status-svg wrapper, one per panel" do
    job = job_with_candidates
    event_for(job)
    seed_host_samples
    with_bp_runner do
      capturing_plot_post do |calls|
        fetch_status
        assert_equal %w[digest digest log], calls.map { |(u, _)| File.basename(u) }

        d = doc
        assert_equal 3, d.css(".status-svg").size
        assert d.at_css("[data-status-svg='use'] svg"), "the use chart is inlined"
        assert d.at_css("[data-status-svg='server'] svg"), "the server chart is inlined"
        assert d.at_css("[data-status-svg='log'] svg"), "the log is inlined"
        assert_nil d.at_css(".status-tree"), "no HTML fallback when the service answered"
        assert_includes response.body, "drawn"
      end
    end
  end

  test "an SVG answered as a binary body is transcoded, not a 500" do
    job = job_with_candidates
    event_for(job)
    seed_host_samples
    with_bp_runner do
      # Net::HTTP hands the body back as ASCII-8BIT. The page must force it to
      # UTF-8 before splicing it into the UTF-8 template; the old code 500'd
      # with an Encoding::CompatibilityError the moment the service answered.
      binary = SVG.dup.force_encoding(Encoding::ASCII_8BIT)
      capturing_plot_post(svg: binary) do
        fetch_status
        assert_response :success
        assert_equal 3, doc.css(".status-svg").size
        assert_includes response.body, "drawn"
      end
    end
  end

  # -- nothing to draw is nothing to ask for --------------------------------

  test "with no samples and nothing produced the page draws no chart at all" do
    with_bp_runner do
      capturing_plot_post do |calls|
        fetch_status
        assert_equal [], calls, "six zero bars and an empty axis are drawings of an absence"

        d = doc
        assert_nil d.at_css(".status-svg")
        assert_includes response.body, "Nothing produced yet"
        assert_includes response.body, "No samples have ever been taken"
        assert_equal "0", d.at_css("[data-use-count='traced']").text.strip,
          "the numbers are still reported -- they are just not drawn"
      end
    end
  end

  test "with no blend-plot runner the numbers are rendered by the page itself" do
    job = job_with_candidates
    proof_for(job)
    seed_host_samples

    without_runners do
      fetch_status
      d = doc
      assert_nil d.at_css(".status-svg"), "nothing is drawn without a runner"

      # The use tally: the counts, and a note saying why there is no chart.
      assert_equal "2", d.at_css("[data-use-count='traced']").text.strip
      assert_includes d.at_css("[data-status-fallback='use']").text, "Not drawn"
      assert_includes d.at_css("[data-status-fallback='use']").text, "counts above are the same numbers"

      # The server panel keeps its tiles and says the same.
      assert_includes d.at_css("[data-status-fallback='server']").text, "newest reading"
      assert_equal "20.0%", d.at_css("[data-host-value='cpu']").text.strip
    end
  end

  # -- the HTML log fallback -------------------------------------------------

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
      assert_includes doc.text, "<em>café & co</em>", "a label is read as TEXT"
      refute_includes response.body, "<b>triage</b>", "and never as markup"
      refute_includes response.body, "<script>x</script>"
    end
  end

  test "a configured runner that refuses falls back to the HTML rather than 500ing" do
    job = job_with_candidates
    proof_for(job)
    seed_host_samples

    with_bp_runner do
      refusing_plot_post do
        fetch_status
        assert_includes response.body, "could not draw the panels"
        assert_nil doc.at_css(".status-svg"), "the data is still rendered, just not drawn"
        assert_equal "2", doc.at_css("[data-use-count='traced']").text.strip
        assert doc.at_css("[data-host-value='cpu']")
      end
    end
  end

  test "an operator with nothing recorded still gets a page, not an error" do
    without_runners do
      fetch_status
      assert_includes response.body, "Nothing produced yet"
      assert_includes response.body, "Nothing recorded yet"
    end
  end

  # -- gap annotation: a nil bucket that overlaps a run window is explained ----

  test "a gap overlapping a run window is annotated on the page" do
    now = Time.current
    step = HostSample::BUCKET_SECONDS

    # Two samples with a gap between them (same as the model test).
    HostSample.create!(captured_at: now, cpu_pct: 30.0, mem_pct: 40.0,
                       swap_total_mb: 100, swap_pct: 5.0,
                       mem_total_mb: 3777, mem_used_mb: 1500)
    HostSample.create!(captured_at: now - 3 * step, cpu_pct: 20.0, mem_pct: 30.0,
                       swap_total_mb: 100, swap_pct: 4.0,
                       mem_total_mb: 3777, mem_used_mb: 1200)

    # A job that was in-flight during the gap. The job window covers both
    # empty buckets: started before the first gap, finished after the last.
    Job.create!(name: "long-trace", state: "done", runner: "mock",
                source_kind: "raster", input_path: "/data/art.png", stem: "art",
                started_at: now - 3 * step, finished_at: now,
                created_at: now - 3 * step, updated_at: now, spec: {})

    without_runners do
      fetch_status
      d = doc
      annotation = d.at_css("[data-host-gap-annotation]")
      refute_nil annotation, "a gap overlapping a run window must be annotated"
      assert_includes annotation.text, "Sampling was interrupted by a run"
    end
  end

  test "a gap with no overlapping run is not annotated" do
    now = Time.current
    step = HostSample::BUCKET_SECONDS

    # Two samples with a gap, but no jobs.
    HostSample.create!(captured_at: now, cpu_pct: 30.0, mem_pct: 40.0,
                       swap_total_mb: 100, swap_pct: 5.0,
                       mem_total_mb: 3777, mem_used_mb: 1500)
    HostSample.create!(captured_at: now - 3 * step, cpu_pct: 20.0, mem_pct: 30.0,
                       swap_total_mb: 100, swap_pct: 4.0,
                       mem_total_mb: 3777, mem_used_mb: 1200)

    without_runners do
      fetch_status
      d = doc
      assert_nil d.at_css("[data-host-gap-annotation]"),
        "a gap with no run window must NOT be annotated"
    end
  end

  test "no gaps means no annotation" do
    now = Time.current
    step = HostSample::BUCKET_SECONDS

    # Three consecutive samples: no gaps.
    3.times do |i|
      HostSample.create!(captured_at: now - i * step, cpu_pct: 20.0 + i,
                         mem_pct: 40.0 + i, swap_total_mb: 100, swap_pct: 5.0,
                         mem_total_mb: 3777, mem_used_mb: 1500)
    end

    without_runners do
      fetch_status
      d = doc
      assert_nil d.at_css("[data-host-gap-annotation]"),
        "no gaps means no annotation"
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
    # Eight pages now: PLOT and BLENDER merged into ONE page (BP -- Blend-Plot),
    # so the list lost two entries and gained one.
    assert_includes alignment, "assert_equal 8, RUN_JOB_PAGES.size"
    responsive = File.read(root.join("test/controllers/responsive_head_test.rb"))
    assert_operator responsive.scan("pages/status.html.erb").size, :>=, 2,
      "both the ordering list and the short-blurb list name this page"

    # The merged BP page has to be in the same four lists, or the page that
    # replaced two registered pages would be the one that drifts unnoticed.
    assert_includes File.read(root.join("test/controllers/page_head_uniformity_test.rb")),
                    '"pages/bp.html.erb" => "BP"'
    assert_includes File.read(root.join("test/controllers/head_action_size_test.rb")),
                    '"bp" => bp_path'
    assert_includes alignment, '"bp" => bp_path'
    assert_includes responsive, "pages/bp.html.erb"
  end
end
