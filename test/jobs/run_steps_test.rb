require "test_helper"

# RunJob's side of a STEP LIST: the studio drives the chain, the runners do not.
#
# Nothing is contacted. The clients are swapped out (their own wire behaviour is
# covered in test/lib) so what is asserted here is the SEQUENCING, which cannot
# be tested anywhere else: that the steps run in order, that each one is handed
# the file the one before it produced, that a pipeline step is waited for, that
# the job is marked done only after the LAST step, that a mid-chain failure names
# the step it failed on, and that a cancel stops the chain where it stands.
class RunStepsTest < ActiveSupport::TestCase
  PNG = ("\x89PNG\r\n\x1a\n".b + "one-frame").freeze
  # A drawing primitive the blend vocabulary has, so the SVG -> blend conversion
  # has something real to convert.
  SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 10 10">' \
        '<path d="M0 0 L10 0 L10 10 Z" fill="#e04030"/></svg>'.freeze

  OTHER_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  def with_runners
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    OTHER_RUNNER_ENV.each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_PIPELINE_URL"] = "http://pipeline.invalid:8791"
      ENV["CHOPSHOP_RUNNER_FLUXBOX_URL"] = "http://flux.invalid:8795"
      ENV["CHOPSHOP_RUNNER_FLUXBOX_KIND"] = "flux"
      ENV["CHOPSHOP_RUNNER_DOCS_URL"] = "http://docs.invalid:8796"
      ENV["CHOPSHOP_RUNNER_DOCS_KIND"] = "plot"
      ENV["CHOPSHOP_RUNNER_BP_URL"] = "http://bp.invalid:8796"
      ENV["CHOPSHOP_RUNNER_BP_KIND"] = "blender"
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      OTHER_RUNNER_ENV.each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  # Replace methods for the length of a block and put them back in ensure — the
  # same define_singleton_method swap the plot, flux and blender tests use
  # (Minitest 6 dropped minitest/mock, so there is no Object#stub here).
  def with_swaps(swaps)
    originals = swaps.keys.to_h { |mod, name| [[mod, name], mod.method(name)] }
    swaps.each do |(mod, name), replacement|
      mod.define_singleton_method(name) { |*a, **k| replacement.call(*a, **k) }
    end
    yield
  ensure
    originals.each { |(mod, name), method| mod.define_singleton_method(name, method) }
  end

  # A runner that does not really wait: the poll interval is a real sleep in
  # production (a trace is minutes) and would make this suite minutes long.
  def runner
    RunJob.new.tap { |r| r.define_singleton_method(:sleep) { |*| nil } }
  end

  def create_chain(steps:, runner:, input_path: "", name: "chain")
    Job.create!(name: name, runner: runner, source_kind: "raster", input_path: input_path,
                state: "queued", spec: { "steps" => steps })
  end

  # Only the uploads THIS run added, so a test never deletes a file another test
  # (or another suite, on this box) is using.
  def uploads_snapshot
    Dir[Rails.root.join("storage", "uploads", "*")].to_h { |p| [p, true] }
  end

  def cleanup_uploads(before)
    Dir[Rails.root.join("storage", "uploads", "*")].each do |path|
      next if before[path]
      next unless File.basename(path).match?(/\A(flux_|plot_|blender_|step_)/)
      File.delete(path)
    end
  end

  def plot_rendered(op: "generate")
    { name: "plot-#{SecureRandom.hex(4)}.svg", bytes: SVG, content_type: "image/svg+xml",
      op: op, spec: {} }
  end

  def flux_rendered
    { name: "flux-#{SecureRandom.hex(4)}.png", bytes: PNG, content_type: "image/png",
      entries: [{ name: "flux.png", bytes: PNG, entry: { "seed" => 7 } }],
      entry: { "seed" => 7 }, meta: {} }
  end

  def blender_rendered
    { name: "blender-#{SecureRandom.hex(4)}.png", bytes: PNG, content_type: "image/png",
      views: 1, frames: nil, glb: nil, entries: nil, spec: {} }
  end

  # A runner job that is finished, with one candidate to hand on.
  def runner_job_done(candidate: "candidate_01.svg")
    { state: "done", candidate_count: candidate ? 1 : 0, prep_summary: "traced",
      comparison: { "candidates" => candidate ? [{ "file" => candidate, "passed" => true }] : [] } }
  end

  # --- the chain runs, in order, and hands the work forward ------------------

  test "the steps run in order, each handed the file the one before it produced" do
    seen = []
    chain = nil
    polls = 0
    state_when_posting = nil
    state_when_rendering = nil
    before = uploads_snapshot

    with_runners do
      begin
        with_swaps(
          [FluxClient, :render] => lambda { |base, **opts|
            seen << [:flux, base, opts]
            flux_rendered
          },
          [RunnerClient, :post] => lambda { |url, body|
            seen << [:post, url, body]
            state_when_posting = Job.find(chain.id).state
            { id: "runner-1" }
          },
          [RunnerClient, :get] => lambda { |url|
            seen << [:get, url]
            polls += 1
            # Still tracing on the first poll: the chain has to WAIT for a
            # pipeline step, because the next step's input is its output.
            polls < 2 ? { state: "running" } : runner_job_done
          },
          [RunnerClient, :get_file] => lambda { |url, **_k|
            seen << [:file, url]
            { status: 200, body: SVG, content_type: "image/svg+xml" }
          },
          [BlenderClient, :render] => lambda { |base, doc|
            seen << [:blender, base, doc]
            state_when_rendering = Job.find(chain.id).state
            blender_rendered
          }
        ) do
          # A chain that can actually RUN: a generator leaves a raster, the
          # trace stage reads rasters, and the blend step is handed the traced
          # candidate (it takes an SVG and converts it into geometry). The first
          # step used to be a plot, which leaves an SVG — a file the trace stage
          # cannot open at all, so this ordering was never runnable.
          chain = create_chain(runner: "fluxbox", steps: [
            { "runner" => "fluxbox", "flux" => { "prompt" => "a phoenix" } },
            { "runner" => "pipeline", "svg" => { "sweep" => { "preset" => "bw" } } },
            { "runner" => "bp", "input" => "previous",
              "blender" => { "doc" => { "extrude" => { "depth" => 40 } } } }
          ])

          runner.perform(chain.id)
        end

        chain.reload
        assert_equal "done", chain.state, chain.error.to_s
        assert chain.finished_at.present?

        # ORDER: the plot drew first, then the pipeline step was posted, then the
        # blend step rendered. Nothing was posted before the step before it ran.
        tags = seen.map(&:first)
        assert_equal :flux, tags.first
        assert_equal :post, tags[1], "the second step is posted after the first produced its file"
        assert_operator tags.index(:post), :<, tags.index(:blender)
        assert_operator tags.index(:file), :<, tags.index(:blender),
                        "the traced candidate is fetched before the blend step that renders it"

        # The HAND-OFF, generator -> pipeline: the runner is given the raster
        # the first step stored, at the uploads root the runner contract reads
        # from.
        posted = seen.find { |e| e.first == :post }[2]
        stored_plot = chain.spec.dig("steps", 0, "flux", "rendered", "images", 0, "file")
        assert_match(/\Aflux_[0-9a-f]+\.png\z/, stored_plot.to_s)
        assert_equal "http://pipeline.invalid:8791/jobs", seen.find { |e| e.first == :post }[1]
        assert_equal "raster", posted[:source_kind]
        assert_equal Rails.root.join("storage", "uploads").to_s, File.dirname(posted[:input_path]),
                     "a stored upload is handed over as a path, not copied"
        assert_equal stored_plot, File.basename(posted[:input_path]),
                     "and it is the generator step's own stored raster"
        # ...and it leaves here in the form the runner contract prefers. The
        # absolute path above is the call site's own bookkeeping; `post` is what
        # turns it into a store-relative name, so the two compose here.
        assert_equal stored_plot, RunnerClient.runner_input_path(posted[:input_path]),
                     "which reaches the runner relative to the upload store, so no " \
                     "prefix of ours can drift under it"
        assert_equal({ "sweep" => { "preset" => "bw" } }, posted[:spec], "the step's own block is posted")

        # The HAND-OFF, pipeline -> blend: the traced candidate was fetched from
        # the runner, converted into the blend vocabulary, and merged into the
        # step's own document (which keeps its extrude block).
        _tag, blend_base, blend_doc = seen.find { |e| e.first == :blender }
        assert_equal "http://bp.invalid:8796", blend_base
        assert_equal [{ "type" => "path", "d" => "M0 0 L10 0 L10 10 Z", "fill" => "#e04030" }],
                     blend_doc["elements"]
        assert_equal({ "depth" => 40 }, blend_doc["extrude"], "the step's own document is kept")
        assert_match(%r{/files/runner-1/candidate_01\.svg\z}, seen.find { |e| e.first == :file }[1])

        # DONE ONLY AFTER THE LAST STEP: while the second step was being posted,
        # and while the third was rendering, the job was still running.
        assert_equal "running", state_when_posting
        assert_equal "running", state_when_rendering
        assert_operator polls, :>=, 2, "a pipeline step is polled until the runner job finishes"

        # The ledger: three steps, all finished, in order.
        progress = chain.steps_progress
        assert_equal 3, progress["total"]
        assert_equal 3, progress["current"]
        assert_equal "done", progress["state"]
        assert_equal %w[fluxbox pipeline bp], progress["steps"].map { |s| s["runner"] }
        assert_equal %w[done done done], progress["steps"].map { |s| s["state"] }
        assert_equal "runner-1", progress["steps"][1]["runner_job_id"]
        assert_equal "candidate_01.svg", progress["steps"][1]["candidate"]
        assert_match(/\Astep_[0-9a-f]+\.svg\z/, chain.spec.dig("steps", 2, "blender", "document_from").to_s)
        assert_equal 1, chain.spec.dig("steps", 2, "blender", "elements_from_svg")
        assert chain.steps_recorded.all? { |s| s["started_at"].present? && s["finished_at"].present? }
      ensure
        cleanup_uploads(before)
      end
    end
  end

  test "a flux step generates a raster and the pipeline step traces THAT raster" do
    seen = []
    chain = nil
    before = uploads_snapshot

    with_runners do
      begin
        with_swaps(
          [FluxClient, :render] => lambda { |base, **opts|
            seen << [:flux, base, opts]
            flux_rendered
          },
          [RunnerClient, :post] => lambda { |url, body|
            seen << [:post, url, body]
            { id: "runner-2" }
          },
          [RunnerClient, :get] => lambda { |url|
            seen << [:get, url]
            runner_job_done(candidate: nil)
          }
        ) do
          chain = create_chain(runner: "fluxbox", steps: [
            { "runner" => "fluxbox", "flux" => { "prompt" => "a phoenix" } },
            { "runner" => "pipeline", "svg" => {} }
          ])
          runner.perform(chain.id)
        end

        chain.reload
        assert_equal "done", chain.state, chain.error.to_s

        _tag, flux_base, opts = seen.first
        assert_equal "http://flux.invalid:8795", flux_base, "generation goes to the GENERATOR the step names"
        assert_equal "a phoenix", opts[:prompt]
        assert_nil opts[:reference], "nothing was handed to the first step"

        posted = seen.find { |e| e.first == :post }[2]
        assert_equal "raster", posted[:source_kind]
        stored = chain.spec.dig("steps", 0, "flux", "rendered", "images", 0, "file")
        assert_match(/\Aflux_[0-9a-f]+\.png\z/, stored.to_s)
        assert_equal stored, File.basename(posted[:input_path]),
                     "the pipeline step traces the raster the generator just produced"
        assert_equal File.dirname(posted[:input_path]),
                     Rails.root.join("storage", "uploads").to_s
        # The wire form the runner actually reads, composed from the above.
        assert_equal stored, RunnerClient.runner_input_path(posted[:input_path]),
                     "handed to the runner relative to the upload store"
      ensure
        cleanup_uploads(before)
      end
    end
  end

  # --- failure and cancellation --------------------------------------------

  test "a mid-chain failure marks the job failed and names the step" do
    chain = nil
    before = uploads_snapshot
    with_runners do
      begin
        with_swaps(
          [PlotClient, :generate] => ->(_base, _doc) { plot_rendered },
          [BlenderClient, :render] => lambda { |_base, _doc|
            raise BlenderClient::Unavailable, "blender 503: no blender binary on the runner"
          }
        ) do
          chain = create_chain(runner: "docs", steps: [
            { "runner" => "docs", "plot" => { "op" => "generate", "doc" => { "canvas" => 1 } } },
            { "runner" => "bp", "blender" => { "doc" => { "elements" => [] } } }
          ])
          runner.perform(chain.id)
        end

        chain.reload
        assert_equal "error", chain.state
        assert_match(/\Astep 2 \(bp\): blender 503/, chain.error.to_s,
                     "the operator is told WHICH step failed, in the runner's own words")
        assert chain.finished_at.present?

        progress = chain.steps_progress
        assert_equal "failed", progress["state"]
        assert_equal "done", progress["steps"][0]["state"], "step 1's work stands"
        assert_equal "failed", progress["steps"][1]["state"]
        assert_match(/blender 503/, progress["steps"][1]["error"].to_s)
      ensure
        cleanup_uploads(before)
      end
    end
  end

  test "a step that produces no file stops the chain, naming the step that needed it" do
    chain = nil
    before = uploads_snapshot
    with_runners do
      begin
        with_swaps(
          [RunnerClient, :post] => ->(_url, _body) { { id: "runner-3" } },
          [RunnerClient, :get] => ->(_url) { runner_job_done(candidate: nil) },
          [BlenderClient, :render] => ->(_base, _doc) { flunk "the render must not be attempted" }
        ) do
          chain = create_chain(runner: "pipeline", input_path: "/uploads/art.png", steps: [
            { "runner" => "pipeline", "svg" => {} },
            { "runner" => "bp", "input" => "previous", "blender" => { "doc" => { "elements" => [] } } }
          ])
          runner.perform(chain.id)
        end

        chain.reload
        assert_equal "error", chain.state
        assert_match(/\Astep 2 \(bp\): the step before it produced no file/, chain.error.to_s)
      ensure
        cleanup_uploads(before)
      end
    end
  end

  test "a cancel stops the chain where it stands" do
    seen = []
    before = uploads_snapshot
    chain = nil

    with_runners do
      begin
        with_swaps(
          [PlotClient, :generate] => lambda { |_base, _doc|
            seen << :plot
            # The operator's Cancel lands while the first step is drawing, which
            # is exactly what JobsController#cancel does to the record.
            Job.find(chain.id).update_columns(state: "cancelled", error: "cancelled by operator")
            plot_rendered
          },
          [BlenderClient, :render] => ->(_base, _doc) { flunk "the chain must stop after a cancel" }
        ) do
          chain = create_chain(runner: "docs", steps: [
            { "runner" => "docs", "plot" => { "op" => "generate", "doc" => { "canvas" => 1 } } },
            { "runner" => "bp", "blender" => { "doc" => { "elements" => [] } } }
          ])
          runner.perform(chain.id)
        end

        chain.reload
        assert_equal [:plot], seen
        assert_equal "cancelled", chain.state, "the chain does not overwrite the operator's verdict"
        assert_equal "cancelled by operator", chain.error
        assert_nil chain.finished_at
      ensure
        cleanup_uploads(before)
      end
    end
  end

  # --- the SVG -> blend conversion itself ----------------------------------

  test "an SVG the blend vocabulary cannot express is refused, naming the node" do
    blend = RunJob.new

    refuses = lambda do |svg|
      assert_raises(RunnerClient::RunnerError) { blend.send(:blend_elements_from_svg, svg) }.message
    end

    assert_match(/a <g> element cannot be expressed/,
                 refuses.call('<svg><g transform="translate(3,4)"><rect x="1" y="1" width="2" height="2"/></g></svg>'))
    assert_match(/a <rect> element carries a transform/,
                 refuses.call('<svg><rect x="1" y="1" width="2" height="2" transform="scale(2)"/></svg>'))
    assert_match(/carries "style"/,
                 refuses.call('<svg><rect x="1" y="1" width="2" height="2" style="fill:red"/></svg>'))
    assert_match(/has no drawing primitives/,
                 refuses.call('<svg><metadata>nothing to draw</metadata></svg>'))
    assert_match(/is not an SVG/,
                 refuses.call("<html><body>not an svg</body></html>"))
  end

  test "the conversion maps the primitives, and records what it had to drop" do
    elements, dropped = RunJob.new.send(
      :blend_elements_from_svg,
      '<svg><circle cx="10" cy="20" r="5" fill="#ff0000" fill-rule="evenodd"/>' \
      '<polyline points="0,0 10,10" stroke="#00ff00" stroke-width="3"/></svg>'
    )

    assert_equal [{ "type" => "circle", "cx" => 10, "cy" => 20, "r" => 5, "fill" => "#ff0000" },
                  { "type" => "polyline", "points" => [[0, 0], [10, 10]],
                    "stroke" => "#00ff00", "stroke_width" => 3 }],
                 elements
    assert_equal ["fill-rule"], dropped,
                 "the drop is recorded rather than silently invented into a field"
  end

  # --- back-compat ---------------------------------------------------------

  test "a job with no step list still runs through the single-action path" do
    before = uploads_snapshot
    with_runners do
      begin
        with_swaps([PlotClient, :generate] => ->(_base, _doc) { plot_rendered }) do
          job = Job.create!(name: "single", runner: "docs", source_kind: "raster", input_path: "",
                            state: "queued",
                            spec: { "plot" => { "op" => "generate", "doc" => { "canvas" => 1 } } })
          refute job.sequenced?
          runner.perform(job.id)

          job.reload
          assert_equal "done", job.state, job.error.to_s
          assert_match(/plot generate/, job.prep_summary.to_s)
          assert_match(/\Aplot_[0-9a-f]+\.svg\z/, job.plot_output_file.to_s)
          assert_nil job.steps_state, "a single-action job writes no step ledger"
        end
      ensure
        cleanup_uploads(before)
      end
    end
  end

  # --- the COMPOSE step: composed studio-side, out of the chain's own files ----

  # A compose step is the one step the STUDIO executes: it resolves every layer's
  # source, and a layer that says `step:<n>` means the file an earlier step of
  # this same chain produced. Both halves are asserted for real here — the flux
  # step's raster is actually stored, so `ComposeSpec` reads it off disk and
  # inlines it, which is the whole reason the resolution lives studio-side.
  test "a compose step composes an earlier step's file, studio-side" do
    seen = []
    chain = nil
    before = uploads_snapshot

    with_runners do
      begin
        with_swaps(
          [FluxClient, :render] => ->(_base, **_opts) { flux_rendered },
          [ComposeClient, :compose] => lambda { |base, spec|
            seen << [base, spec]
            { name: "compose-#{SecureRandom.hex(4)}.svg", bytes: SVG, content_type: "image/svg+xml" }
          }
        ) do
          chain = create_chain(runner: "fluxbox", steps: [
            { "runner" => "fluxbox", "flux" => { "prompt" => "a phoenix" } },
            { "runner" => "pipeline", "op" => "compose",
              "svg" => { "width" => 200, "height" => 100, "background" => "transparent",
                         "layers" => [{ "name" => "art", "src" => "step:1",
                                        "x" => 0, "y" => 0, "w" => 200, "h" => 100 }] } }
          ])
          runner.perform(chain.id)
        end

        chain.reload
        assert_equal "done", chain.state, chain.error.to_s

        # It went to the COMPOSE route of the runner the step names, with the
        # studio-built spec — not to /jobs as a trace would.
        assert_equal 1, seen.size, "exactly one compose, for the one compose step"
        base, spec = seen.first
        assert_equal "http://pipeline.invalid:8791", base
        assert_equal 200, spec["width"]
        assert_equal 100, spec["height"]
        assert_equal 1, spec["layers"].size

        # THE HAND-OFF, step 1 -> the compose: the layer's `step:1` was resolved
        # to the raster the flux step stored, and INLINED (a data URI), because
        # the runner cannot see this app's storage.
        stored = chain.spec.dig("steps", 0, "flux", "rendered", "images", 0, "file")
        assert_match(/\Aflux_[0-9a-f]+\.png\z/, stored.to_s)
        layer = spec["layers"].first
        assert_equal "raster", layer["type"]
        assert_match(%r{\Adata:image/png;base64,}, layer["src"].to_s)

        # The composed SVG is the step's output: stored, recorded in the ledger,
        # and there on disk for a later step (or the page) to read.
        entry = chain.steps_recorded.find { |e| e["index"] == 2 }
        assert_equal "done", entry["state"]
        assert_equal "image/svg+xml", entry["content_type"]
        assert_match(/\Astep_[0-9a-f]+\.svg\z/, entry["file"].to_s)
        assert File.exist?(Rails.root.join("storage", "uploads", entry["file"].to_s)),
               "the composed document is in storage/uploads, like any other step's output"
        assert_equal "compose", chain.spec.dig("steps", 1, "svg", "rendered", "operation")

        # And the ledger is the only place the operation could have been read
        # from: the STEP's own record, beside the document it asked with.
        assert_equal 1, chain.spec.dig("steps", 1, "svg", "rendered", "layers")
      ensure
        cleanup_uploads(before)
      end
    end
  end

  # --- GPU-busy refusal: retry and distinct state ----------------------------

  test "a gpu_busy refusal in a flux step is retried, then records a distinct state" do
    chain = nil
    before = uploads_snapshot
    render_calls = 0

    with_runners do
      begin
        with_swaps(
          [FluxClient, :render] => lambda { |_base, **_opts|
            render_calls += 1
            # Refuse twice, then succeed: the retry should kick in.
            if render_calls < 3
              raise FluxClient::FluxGpuBusy, "flux 503: GPU busy, held by LM Studio"
            end
            flux_rendered
          },
          [RunnerClient, :post] => ->(_url, _body) { { id: "runner-1" } },
          [RunnerClient, :get] => ->(_url) { runner_job_done(candidate: nil) }
        ) do
          chain = create_chain(runner: "fluxbox", steps: [
            { "runner" => "fluxbox", "flux" => { "prompt" => "a phoenix" } },
            { "runner" => "pipeline", "svg" => {} }
          ])
          runner.perform(chain.id)
        end

        chain.reload
        assert_equal "done", chain.state, chain.error.to_s
        assert_equal 3, render_calls, "a gpu_busy refusal is retried before giving up"
      ensure
        cleanup_uploads(before)
      end
    end
  end

  test "a gpu_busy refusal that never clears records a distinct GPU BUSY state" do
    chain = nil
    before = uploads_snapshot
    render_calls = 0

    with_runners do
      begin
        with_swaps(
          [FluxClient, :render] => lambda { |_base, **_opts|
            render_calls += 1
            raise FluxClient::FluxGpuBusy, "flux 503: GPU busy, held by ollama"
          }
        ) do
          chain = create_chain(runner: "fluxbox", steps: [
            { "runner" => "fluxbox", "flux" => { "prompt" => "a phoenix" } }
          ])
          runner.perform(chain.id)
        end

        chain.reload
        assert_equal "error", chain.state
        assert_match(/GPU BUSY:/, chain.error,
                     "a gpu_busy failure is distinguishable from a real generation failure")
        assert_match(/ollama/, chain.error)
        assert_equal RunJob::GPU_BUSY_RETRIES, render_calls,
                     "the retry is bounded, not unbounded"
      ensure
        cleanup_uploads(before)
      end
    end
  end

  test "a single-action flux job with gpu_busy records a distinct state" do
    job = nil
    before = uploads_snapshot
    render_calls = 0

    with_runners do
      begin
        with_swaps(
          [FluxClient, :render] => lambda { |_base, **_opts|
            render_calls += 1
            raise FluxClient::FluxGpuBusy, "flux 503: GPU busy"
          }
        ) do
          job = Job.create!(name: "single-flux", runner: "fluxbox", source_kind: "raster",
                            input_path: "", state: "queued",
                            spec: { "flux" => { "prompt" => "a phoenix" } })
          runner.perform(job.id)
        end

        job.reload
        assert_equal "error", job.state
        assert_match(/\AGPU BUSY:/, job.error)
        assert_equal RunJob::GPU_BUSY_RETRIES, render_calls
      ensure
        cleanup_uploads(before)
      end
    end
  end

  test "a compose layer naming a step that has not run is refused, by index" do
    before = uploads_snapshot
    with_runners do
      begin
        chain = nil
        with_swaps(
          [FluxClient, :render] => ->(_base, **_opts) { flux_rendered },
          [ComposeClient, :compose] => ->(_base, _spec) { flunk "nothing should be composed" }
        ) do
          # Step 1 composes out of step 2, which runs after it: a chain cannot
          # compose what does not exist yet, so it fails naming the step.
          chain = create_chain(runner: "pipeline", steps: [
            { "runner" => "pipeline", "op" => "compose",
              "svg" => { "width" => 10, "height" => 10,
                         "layers" => [{ "name" => "art", "src" => "step:2" }] } },
            { "runner" => "fluxbox", "flux" => { "prompt" => "a phoenix" } }
          ])
          runner.perform(chain.id)
        end

        chain.reload
        assert_equal "error", chain.state
        assert_match(/step 1/, chain.error.to_s)
        assert_match(/names step 2, which does not run before it/, chain.error.to_s)
      ensure
        cleanup_uploads(before)
      end
    end
  end
end
