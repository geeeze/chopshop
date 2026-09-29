require "test_helper"

# The combined BP action: ONE Run Job target for the whole blend-plot service,
# whose op selector covers all six of its operations.
#
# Nothing is contacted. The two clients are swapped out (their wire behaviour is
# covered in test/lib) so what is asserted here is the DISPATCH and the STORING:
# that the operation decides which half answered, that the answer is stored and
# recorded under `spec["bp"]`, that the failure carries one BP name rather than
# the half's, and that the legacy plot/blender kinds still run unchanged — which
# is the whole back-compat requirement of the merge.
class RunBpTest < ActiveSupport::TestCase
  PNG = ("\x89PNG\r\n\x1a\n".b + "one-frame").freeze
  SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 10 10">' \
        '<path d="M0 0 L10 0 L10 10 Z" fill="#e04030"/></svg>'.freeze

  OTHER_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  # A deployment with ONE bp runner (kind bp) plus the legacy pair, because the
  # merge has to hold for a box that still carries the old labels.
  def with_runners
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    OTHER_RUNNER_ENV.each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_BP_URL"] = "http://bp.invalid:8796"
      ENV["CHOPSHOP_RUNNER_BP_KIND"] = "bp"
      ENV["CHOPSHOP_RUNNER_LEGACYPLOT_URL"] = "http://docs.invalid:8796"
      ENV["CHOPSHOP_RUNNER_LEGACYPLOT_KIND"] = "plot"
      ENV["CHOPSHOP_RUNNER_LEGACYBLEND_URL"] = "http://blend.invalid:8796"
      ENV["CHOPSHOP_RUNNER_LEGACYBLEND_KIND"] = "blender"
      ENV["CHOPSHOP_RUNNER_PIPELINE_URL"] = "http://pipeline.invalid:8791"
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      OTHER_RUNNER_ENV.each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def with_swaps(swaps)
    originals = swaps.keys.to_h { |mod, name| [[mod, name], mod.method(name)] }
    swaps.each do |(mod, name), replacement|
      mod.define_singleton_method(name) { |*a, **k| replacement.call(*a, **k) }
    end
    yield
  ensure
    originals.each { |(mod, name), method| mod.define_singleton_method(name, method) }
  end

  def runner
    RunJob.new.tap { |r| r.define_singleton_method(:sleep) { |*| nil } }
  end

  def uploads_snapshot
    Dir[Rails.root.join("storage", "uploads", "*")].to_h { |p| [p, true] }
  end

  def cleanup_uploads(before)
    Dir[Rails.root.join("storage", "uploads", "*")].each do |path|
      next if before[path]
      next unless File.basename(path).match?(/\A(plot_|blender_|bp_|bp_step_)/)
      File.delete(path)
    end
  end

  def plot_rendered(op: "generate")
    { name: "bp-#{SecureRandom.hex(4)}.svg", bytes: SVG, content_type: "image/svg+xml",
      op: op, spec: {} }
  end

  def blender_rendered
    { name: "bp-#{SecureRandom.hex(4)}.png", bytes: PNG, content_type: "image/png",
      views: 1, frames: nil, glb: nil, entries: nil, spec: {} }
  end

  # Built, and only saved when asked: a VALIDATION test builds a job it EXPECTS to
  # be invalid, so `create!` there would raise instead of letting the test assert
  # on the errors -- which is the assertion that matters.
  def bp_job(op:, doc:, runs: nil, runner_label: "bp", state: "queued", save: true)
    block = { "op" => op, "doc" => doc }
    block["runs"] = runs if runs
    job = Job.new(name: "bp-#{op}", runner: runner_label, source_kind: "raster",
                  input_path: "", state: state, spec: { "bp" => block })
    job.save! if save
    job
  end

  # --- validation -----------------------------------------------------------

  test "a bp job needs one of the six operations" do
    with_runners do
      assert_equal %w[generate digest query tree log blender], Job::BP_OPS

      job = bp_job(op: "render", doc: { "elements" => [] }, save: false)
      refute job.valid?
      assert_includes job.errors.full_messages.join(" "),
                      "a BP job needs an operation: one of generate, digest, query, tree, log, blender"
    end
  end

  test "each operation's own requirement is refused, in the one validator" do
    with_runners do
      no_doc = Job.new(name: "x", runner: "bp", source_kind: "raster", input_path: "",
                       spec: { "bp" => { "op" => "generate" } })
      refute no_doc.valid?
      assert_includes no_doc.errors.full_messages.join(" "), "a BP job needs a document"

      # blender reads GEOMETRY, so its document must carry an elements list --
      # the rule the old blender validator owned, now owned here.
      bad_blend = bp_job(op: "blender", doc: { "extrude" => { "depth" => 4 } }, save: false)
      refute bad_blend.valid?
      assert_includes bad_blend.errors.full_messages.join(" "),
                      "a BP blender document needs an elements list"

      # query draws ACROSS runs, so the records are part of the request.
      no_runs = bp_job(op: "query", doc: { "chart" => "scatter" }, save: false)
      refute no_runs.valid?
      assert_includes no_runs.errors.full_messages.join(" "), "a BP query needs run records"

      assert bp_job(op: "blender", doc: { "elements" => [] }).valid?
      assert bp_job(op: "query", doc: { "chart" => "scatter" }, runs: [{ "stem" => "a" }]).valid?
      assert bp_job(op: "tree", doc: { "nodes" => [] }).valid?
    end
  end

  # --- the operation decides which half answers ------------------------------

  test "a drawing operation goes to the drawing half and stores an SVG" do
    before = uploads_snapshot
    seen = nil
    with_runners do
      with_swaps(
        [BpClient, :render] => lambda { |base, op, doc, runs: nil|
          seen = { base: base, op: op, doc: doc, runs: runs }
          plot_rendered(op: op)
        }
      ) do
        job = bp_job(op: "generate", doc: { "canvas" => 1 })
        runner.perform(job.id)
        job.reload

        assert_equal "done", job.state, job.error.to_s
        assert_equal "http://bp.invalid:8796", seen[:base]
        assert_equal "generate", seen[:op]
        # A drawing operation must NOT be sent the query transport field.
        assert_nil seen[:runs], "only query carries runs"

        assert_equal "image/svg+xml", job.bp_config.dig("rendered", "content_type")
        assert job.bp_output_file.present?
        assert_equal [], job.bp_frames, "a drawing stores one file, not a frame set"
        assert job.preview_from_upload?, "the answer is an upload, so the preview is too"
      end
    end
  ensure
    cleanup_uploads(before) if before
  end

  test "the blender operation goes to the rendering half and stores frames" do
    before = uploads_snapshot
    seen = nil
    with_runners do
      with_swaps(
        [BpClient, :render] => lambda { |base, op, doc, runs: nil|
          seen = { op: op, doc: doc }
          blender_rendered
        }
      ) do
        job = bp_job(op: "blender", doc: { "elements" => [{ "type" => "rect" }],
                                           "render" => { "views" => 1, "engine" => "eevee" } })
        runner.perform(job.id)
        job.reload

        assert_equal "done", job.state, job.error.to_s
        assert_equal "blender", seen[:op]
        assert_equal "eevee", job.bp_config.dig("rendered", "engine"),
          "the render facts are recorded from the document that asked for them"
        # Assert the stored file is a PNG by its own name and bytes, not by a
        # literal compared to itself (a check that cannot fail is worse than none).
        assert job.bp_output_file.present?
        assert_match(/\Ablender_.*\.png\z/, job.bp_output_file)
        stored = Rails.root.join("storage", "uploads", job.bp_output_file)
        assert stored.file?, "#{job.bp_output_file} must be on disk"
        assert_equal PNG, File.binread(stored), "and hold the frame the service returned"
        assert_equal job.bp_output_file, job.preview_file,
                     "the preview is the rendered frame itself"
        assert_equal 1, job.bp_frames.size
      end
    end
  ensure
    cleanup_uploads(before) if before
  end

  test "a query sends the run records and a drawing op does not" do
    seen = nil
    with_runners do
      with_swaps(
        [BpClient, :render] => lambda { |base, op, doc, runs: nil|
          seen = { op: op, runs: runs }
          plot_rendered(op: op)
        }
      ) do
        job = bp_job(op: "query", doc: { "chart" => "pareto" },
                     runs: [{ "stem" => "run-a" }, { "stem" => "run-b" }])
        runner.perform(job.id)
        assert_equal "done", job.reload.state
        assert_equal "query", seen[:op]
        assert_equal %w[run-a run-b], seen[:runs].map { |r| r["stem"] }
      end
    end
  end

  # --- the failure carries ONE name ----------------------------------------

  test "a failure is reported as BP, not as the half that answered" do
    with_runners do
      with_swaps(
        [BpClient, :render] => lambda { |_base, _op, _doc, runs: nil|
          raise PlotClient::PlotError, "the service refused: bad canvas"
        }
      ) do
        job = bp_job(op: "generate", doc: { "canvas" => 1 })
        runner.perform(job.id)
        job.reload

        assert_equal "error", job.state, "fail_job's terminal state"
        assert_match(/\ABP: /, job.error.to_s,
                     "one name for a BP job, since plot is no longer a surface offered")
        assert_includes job.error.to_s, "bad canvas",
                        "and the half's own reason survives in the message"
      end
    end
  end

  # --- back-compat: the legacy kinds still run ------------------------------

  test "a legacy plot job still resolves its URL and runs" do
    with_runners do
      with_swaps(
        [PlotClient, :generate] => lambda { |base, doc|
          assert_equal "http://docs.invalid:8796", base,
                       "the legacy label still resolves through the runner map"
          plot_rendered(op: "generate")
        }
      ) do
        job = Job.create!(name: "legacy-plot", runner: "legacyplot", source_kind: "raster",
                          input_path: "", state: "queued",
                          spec: { "plot" => { "op" => "generate", "doc" => { "canvas" => 1 } } })
        assert job.plot?, "the legacy kind is still a plot job"
        refute job.bp?, "and not a bp one"
        runner.perform(job.id)
        assert_equal "done", job.reload.state
      end
    end
  end

  test "the legacy kinds are still fileable but no longer offered" do
    with_runners do
      refute_includes Job.form_runners, "legacyplot",
                      "the plot label is superseded on the form by the one BP action"
      refute_includes Job.form_runners, "legacyblend", "and so is the blender one"
      assert_includes Job.form_runners, "bp"
      # ...and they are still REAL kinds, or their rows become unrunnable (the
      # "unknown runner" failure that made an operator's jobs undeletable).
      assert_includes Job.job_runners, "legacyplot"
      assert_includes Job.job_runners, "legacyblend"
      assert Job.new(name: "a", runner: "legacyplot", source_kind: "raster",
                     spec: { "plot" => { "op" => "generate", "doc" => { "canvas" => 1 } } }).valid?
    end
  end

  # --- the step extension ---------------------------------------------------

  test "a bp step's produced extension follows its operation" do
    with_runners do
      job = Job.new(name: "x", runner: "bp", source_kind: "raster", input_path: "", spec: {})
      draws = { "runner" => "bp", "bp" => { "op" => "generate", "doc" => {} } }
      renders = { "runner" => "bp", "bp" => { "op" => "blender", "doc" => {} } }

      assert_equal ".svg", job.send(:produced_extension, draws),
                   "the drawing operations leave a document"
      assert_equal ".png", job.send(:produced_extension, renders),
                   "and the render leaves a frame -- read off the OP, not the kind"
      # A following svg step accepts a RASTER and NOT a drawing. This used to
      # assert `.svg` was accepted, on the reasoning that "a chain through bp is
      # derivable at all" — and that is exactly what was wrong with it: the trace
      # stage preps a raster with PIL, so a chain bp generate -> svg trace was
      # derivable and UNRUNNABLE, dying inside the runner as
      # UnidentifiedImageError. A drawing has to be rendered to PNG first.
      refute_includes Job::STEP_FILE_RULES["svg"][:accepts], ".svg",
                      "the trace stage cannot read an SVG, so a trace step must not accept one"
      assert_includes Job::STEP_FILE_RULES["svg"][:accepts], ".png"
      assert_includes Job::STEP_FILE_RULES["bp"][:accepts], ".svg",
                      "a bp step asked for blender can be handed an SVG to convert"
    end
  end

  test "a bp blender step converts the SVG the step before it produced into elements" do
    # A REAL chain, because a lone blender step with no elements and no hand-off
    # is genuinely invalid -- the validator refuses it (see the assertion at the
    # end of this test), and that is correct: geometry has to come from somewhere.
    # So the shape under test is the one an operator would build: bp draws a
    # document, then bp renders it in 3D.
    before = uploads_snapshot
    seen = []
    with_runners do
      with_swaps(
        [BpClient, :render] => lambda { |_base, op, doc, runs: nil|
          seen << { op: op, elements: doc && doc["elements"] }
          op == "blender" ? blender_rendered : plot_rendered(op: op)
        }
      ) do
        job = Job.create!(name: "bp-chain", runner: "bp", source_kind: "raster",
                          input_path: "", state: "queued",
                          spec: { "steps" => [
                            { "runner" => "bp",
                              "bp" => { "op" => "generate", "doc" => { "canvas" => 1 } } },
                            { "runner" => "bp", "input" => "previous",
                              "bp" => { "op" => "blender",
                                        "doc" => { "render" => { "views" => 1 } } } }
                          ] })
        assert job.valid?, job.errors.full_messages.inspect

        runner.perform(job.id)
        job.reload
        assert_equal "done", job.state, job.error.to_s

        assert_equal %w[generate blender], seen.map { |f| f[:op] },
                     "the drawing operation ran first, then the render"
        assert_operator seen.last[:elements].to_a.size, :>, 0,
                        "the SVG the first step produced became blend elements " \
                        "rather than being dropped"
      end
    end
  ensure
    cleanup_uploads(before) if before
  end

  test "a first step cannot be handed the step before it" do
    with_runners do
      lone = Job.new(name: "lone", runner: "bp", source_kind: "raster", input_path: "",
                     spec: { "steps" => [
                       { "runner" => "bp", "input" => "previous",
                         "bp" => { "op" => "blender",
                                   "doc" => { "render" => { "views" => 1 } } } }
                     ] })
      refute lone.valid?, "there is no step before the first one"
      assert_includes lone.errors.full_messages.join(" "),
                      "step 1: there is no step before it to hand a file from"
    end
  end
end
