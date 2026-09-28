require "test_helper"

# Starting a PLOT job: paste a document, the service draws it, the SVG is kept.
#
# No service is contacted. PlotClient's three operations are swapped out (their
# own wire behaviour is covered in test/lib/plot_client_test.rb) so what is
# asserted here is the ORCHESTRATION, which cannot be tested anywhere else:
# what the studio asks the service for, what it stores, what the job ends up
# filed as, and what happens when the document or the service refuses.
#
# Drawing is ASYNC like every other run: the POST only queues a RunJob and
# returns immediately, so a test that needs the drawing to have happened wraps
# the POST in perform_enqueued_jobs, which runs it inline.
class PlotJobTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" ' \
        'viewBox="0 0 10 10"><rect width="10" height="10"/></svg>'.freeze

  GEOMETRY = { "canvas" => { "width" => 10, "height" => 10 }, "elements" => [] }.freeze
  CHART = { "chart" => "scatter", "x" => "hard", "y" => "mae_art" }.freeze
  RUNS = [{ "stem" => "run-1", "candidates" => [] }].freeze

  # Runner variables that are not the registry but are read at the same moment,
  # so they have to be isolated with it.
  EXTRA_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  # Hermetic on purpose: EVERY runner variable is cleared first, so a test sees
  # exactly what it asked for. The box running the suite has real runners
  # configured, and inheriting them would make these assert the deployment
  # instead of the code.
  def with_plot_runners
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    EXTRA_RUNNER_ENV.each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_PLOT_URL"] = "http://plot.invalid:8796"
      ENV["CHOPSHOP_RUNNER_PLOT_KIND"] = "plot"
      ENV["CHOPSHOP_RUNNER_SVG_URL"] = "http://pipeline.invalid:8791"
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      EXTRA_RUNNER_ENV.each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  # Replace any of the service's three operations for the duration of a block and
  # put them back in ensure -- the same define_singleton_method swap the flux
  # tests use for FluxClient.render.
  def stubbing_plot(generate: nil, digest: nil, query: nil)
    swaps = { generate: generate, digest: digest, query: query }.reject { |_, v| v.nil? }
    originals = swaps.keys.to_h { |m| [m, PlotClient.method(m)] }
    swaps.each do |name, block|
      PlotClient.define_singleton_method(name) { |*a, **k| block.call(*a, **k) }
    end
    yield
  ensure
    originals.each { |name, m| PlotClient.define_singleton_method(name, m) }
  end

  def rendered(op: "generate")
    { name: "plot-#{SecureRandom.hex(6)}.svg", bytes: SVG,
      content_type: "image/svg+xml", op: op, spec: {} }
  end

  def login
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def start_plot(spec:, name: "chart")
    login
    post jobs_path,
         params: { job: { name: name, runner: "plot", source_kind: "raster",
                          spec: JSON.generate(spec) } },
         headers: { "User-Agent" => MODERN_UA }
  end

  def cleanup_plots
    Dir[Rails.root.join("storage", "uploads", "plot_*.svg")].each { |f| File.delete(f) }
  end

  # --- the request is queued, not drawn on the web thread ------------------

  test "a plot job saves and queues without contacting the service" do
    asked = []
    with_plot_runners do
      stubbing_plot(generate: ->(base, doc) { asked << [base, doc]; rendered }) do
        start_plot(spec: { "plot" => { "op" => "generate", "doc" => GEOMETRY } })
      end

      # Asserted INSIDE the runner environment: Job#plot? asks the registry what
      # the runner's kind is, and the kind only exists while it is configured.
      assert_response :redirect
      job = Job.last
      assert job.plot?, "the job is filed against a plot runner"
      assert_equal "queued", job.state
      assert_equal "generate", job.plot_op
      assert_equal GEOMETRY, job.plot_doc
      assert_empty asked, "the POST only queues: the drawing itself is the worker's"
    end
  end

  # --- the worker draws it ------------------------------------------------

  test "the worker draws the document, stores the SVG and finishes the job" do
    asked = []
    with_plot_runners do
      cleanup_plots
      begin
        stubbing_plot(
          generate: ->(base, doc) { asked << [base, doc]; rendered },
          query: ->(*_a) { flunk "a generate job must not query" }
        ) do
          perform_enqueued_jobs do
            start_plot(spec: { "plot" => { "op" => "generate", "doc" => GEOMETRY } })
          end
        end

        assert_response :redirect
        job = Job.last
        assert_equal "done", job.state, "the drawn SVG IS the deliverable, so the job is finished"
        assert_equal 0, job.candidate_count, "a plot traces nothing, so it has no candidates"
        assert job.finished_at.present?
        assert_match(/plot generate/, job.prep_summary.to_s)

        # The draw went to the plot runner's own serve surface, with the document.
        base, doc = asked.first
        assert_equal "http://plot.invalid:8796", base
        assert_equal GEOMETRY, doc

        # And the SVG landed where every other upload lives, named for what it is.
        file = job.plot_output_file
        assert_match(/\Aplot_[0-9a-f]+\.svg\z/, file.to_s)
        stored = Rails.root.join("storage", "uploads", file.to_s)
        assert stored.file?, "the drawn SVG is on disk"
        assert_equal SVG, File.binread(stored)
        assert_equal "generate", job.spec.dig("plot", "rendered", "op")
      ensure
        cleanup_plots
      end
    end
  end

  test "a digest job calls digest and a query job carries its run records" do
    seen = {}
    with_plot_runners do
      cleanup_plots
      begin
        stubbing_plot(
          digest: ->(base, doc) { seen[:digest] = [base, doc]; rendered(op: "digest") },
          query: ->(base, runs, doc) { seen[:query] = [base, runs, doc]; rendered(op: "query") }
        ) do
          perform_enqueued_jobs do
            start_plot(name: "digest-run",
                       spec: { "plot" => { "op" => "digest", "doc" => CHART } })
          end
          perform_enqueued_jobs do
            start_plot(name: "query-run",
                       spec: { "plot" => { "op" => "query", "doc" => CHART, "runs" => RUNS } })
          end
        end
      ensure
        cleanup_plots
      end
    end

    assert_equal "http://plot.invalid:8796", seen[:digest].first
    assert_equal CHART, seen[:digest].last
    assert_equal "http://plot.invalid:8796", seen[:query].first
    assert_equal RUNS, seen[:query][1], "a query carries the records it draws across"
    assert_equal CHART, seen[:query].last
    assert_equal "done", Job.last.state
  end

  # --- what the operator is told ------------------------------------------

  test "a plot job without an operation or a document is refused, with the reason" do
    asked = []
    with_plot_runners do
      stubbing_plot(generate: ->(base, doc) { asked << [base, doc]; rendered }) do
        start_plot(spec: { "plot" => { "op" => "generate" } })
        assert_response :unprocessable_entity
        assert_match(/PLOT job needs a document/, response.body)

        start_plot(spec: { "plot" => { "doc" => GEOMETRY } })
        assert_response :unprocessable_entity
        assert_match(/PLOT job needs an operation/, response.body)

        start_plot(spec: { "plot" => { "op" => "draw", "doc" => GEOMETRY } })
        assert_response :unprocessable_entity
        assert_match(/PLOT job needs an operation/, response.body,
                     "an op outside the contract's three is not a fourth operation")

        start_plot(spec: { "plot" => { "op" => "query", "doc" => CHART } })
        assert_response :unprocessable_entity
        assert_match(/PLOT query needs run records/, response.body)
      end
    end

    assert_empty asked, "nothing was drawn"
    assert_equal 0, Job.unscoped.where(runner: "plot").count,
      "a refused job is not saved and never queued"
  end

  test "a spec whose document arrives as a JSON string is still drawn" do
    asked = []
    with_plot_runners do
      cleanup_plots
      begin
        stubbing_plot(generate: ->(base, doc) { asked << [base, doc]; rendered }) do
          perform_enqueued_jobs do
            start_plot(name: "pasted",
                       spec: { "plot" => { "op" => "generate", "doc" => JSON.generate(GEOMETRY) } })
          end
        end

        assert_response :redirect
        assert_equal GEOMETRY, asked.first.last,
          "a pasted string document is parsed once, server-side, like the form's is"
      ensure
        cleanup_plots
      end
    end
  end

  test "the service's refusal is recorded on the job, not swallowed" do
    with_plot_runners do
      cleanup_plots
      begin
        stubbing_plot(generate: ->(*_a) {
          raise PlotClient::PlotError,
                "plot 400: scatter: axis 'preset' is not a numeric metric field"
        }) do
          perform_enqueued_jobs do
            start_plot(spec: { "plot" => { "op" => "generate", "doc" => GEOMETRY } })
          end
        end

        assert_response :redirect
        job = Job.last
        assert_equal "error", job.state
        assert_match(/\APLOT: plot 400/, job.error)
        assert_match(/axis 'preset' is not a numeric metric field/, job.error,
          "the service's own refusal is the one message that has to reach the operator")
        assert_nil job.plot_output_file, "nothing was stored for a refused draw"
      ensure
        cleanup_plots
      end
    end
  end

  # --- the wire, through the real client -----------------------------------

  test "the stored SVG is the service's own bytes, through the real client" do
    seen = []
    with_plot_runners do
      cleanup_plots
      begin
        # Only the HTTP transport is swapped here, so PlotClient.render,
        # parse_svg and svg_name all run for real: what is asserted is that the
        # envelope goes to the operation's own route and that the bytes stored
        # are the document the service answered with.
        original = PlotClient.method(:post)
        PlotClient.define_singleton_method(:post) do |url, body, **kwargs|
          seen << [url, body]
          { bytes: SVG, content_type: "image/svg+xml", name: PlotClient.svg_name(SVG) }
        end
        begin
          perform_enqueued_jobs do
            start_plot(spec: { "plot" => { "op" => "generate", "doc" => GEOMETRY } })
          end
        ensure
          PlotClient.define_singleton_method(:post, original)
        end

        job = Job.last
        assert_equal "done", job.state
        assert_equal "http://plot.invalid:8796/generate", seen.first.first,
          "the envelope goes to the operation's own route on the plot runner"
        assert_equal({ op: "generate", spec: GEOMETRY }, seen.first.last)
        assert_equal SVG, File.binread(Rails.root.join("storage", "uploads", job.plot_output_file)),
          "the bytes stored are the SVG the service answered with"
        assert_equal "image/svg+xml", job.spec.dig("plot", "rendered", "content_type")
      ensure
        cleanup_plots
      end
    end
  end

  # --- the form ------------------------------------------------------------

  test "the form offers a plot runner with a panel of its own" do
    with_plot_runners do
      login
      get new_job_path, headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    options = doc.css("#job_runner option").map { |o| [o["value"], o["data-kind"]] }
    assert_includes options, ["plot", "plot"],
      "the plot runner is a job target, so it must be offered"

    panel = doc.at_css("[data-run-fields='plot']")
    refute_nil panel, "the plot kind must have a panel of its own, or the option is a dead end"
    assert panel["hidden"], "and it starts hidden, like the flux panel"
    refute_nil panel.at_css("#plot_op"), "the operation selector"
    refute_nil panel.at_css("#plot_doc"), "the document textarea"
    refute_nil panel.at_css("#plot_runs"), "and the run-records textarea"

    assert_includes doc.css("[data-run-intro='plot']").text, "Paste",
      "the blurb must say what this panel takes"
  end

  test "the form parses the pasted document in the browser and gates query on runs" do
    with_plot_runners do
      login
      get new_job_path, headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :success
    body = response.body

    # The parse is client-side: the panel's own reader must exist and be wired
    # to the submit guard, and the run-records box must follow the operation.
    assert_includes body, "function plotDocParsed"
    assert_includes body, "function plotRunsParsed"
    assert_includes body, "function plotBlock"
    assert_includes body, "function updatePlotGates"
    assert_includes body, "That document is not valid JSON",
      "an invalid paste is refused in the form rather than posted"
    assert_includes body, "A plot query draws across runs",
      "a query without records is refused before it is queued"
  end

  # --- the job page --------------------------------------------------------

  test "the job page shows the drawn SVG through the login-gated preview route" do
    with_plot_runners do
      cleanup_plots
      begin
        file = "plot_a1b2c3.svg"
        File.binwrite(Rails.root.join("storage", "uploads", file), SVG)
        job = Job.create!(name: "chart", state: "done", source_kind: "raster",
                          runner: "plot", input_path: "", stem: "chart", owner: "test",
                          spec: { "plot" => { "op" => "generate", "doc" => GEOMETRY,
                                              "rendered" => { "file" => file, "op" => "generate" } } })
        login
        get job_path(job), headers: { "User-Agent" => MODERN_UA }
        assert_response :success

        doc = Nokogiri::HTML(response.body)
        assert_includes doc.text, "Plot output"
        refute_nil doc.at_css("a[href='#{upload_preview_jobs_path(name: file)}']"),
          "the SVG is served through the existing authenticated preview route"

        # And that route really does serve it, as an SVG document.
        get upload_preview_jobs_path(name: file), headers: { "User-Agent" => MODERN_UA }
        assert_response :success
        assert_equal "image/svg+xml", response.media_type
        assert_includes response.body, "<svg"
      ensure
        cleanup_plots
      end
    end
  end

  test "a plot job with no output yet shows no plot card" do
    with_plot_runners do
      job = Job.create!(name: "pending-chart", state: "queued", source_kind: "raster",
                        runner: "plot", input_path: "", stem: "pending-chart", owner: "test",
                        spec: { "plot" => { "op" => "generate", "doc" => GEOMETRY } })
      login
      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      refute_includes response.body, "Plot output",
        "there is nothing to show until the service has drawn it"
    end
  end
end
