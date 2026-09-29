require "test_helper"

# The step list: one job, several runner actions, in order.
#
# What is pinned here is the CONTRACT the model owns — the shape of the step
# list, that a spec WITHOUT one behaves exactly as it did before step lists
# existed, that each step is validated by the same per-kind rules a whole job is
# (with the step named), and that a hand-off the studio cannot derive is refused
# by index instead of posted blind.
#
# Every case injects the runner registry it needs and clears the rest, the same
# way job_runner_kind_test.rb does: the box running this suite has real runners
# configured, and inheriting them would make these assert the deployment.
class JobStepsTest < ActiveSupport::TestCase
  OTHER_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  def with_runners(urls: {}, kinds: {})
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| saved[key] = ENV.delete(key) }
    OTHER_RUNNER_ENV.each { |key| saved[key] = ENV.delete(key) }
    begin
      urls.each { |key, value| ENV[key] = value }
      kinds.each { |key, value| ENV[key] = value }
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| ENV.delete(key) }
      OTHER_RUNNER_ENV.each { |key| ENV.delete(key) }
      saved.each { |key, value| ENV[key] = value }
      Job.reset_runners_cache!
    end
  end

  # A box with one runner of each kind, which is what a chain needs to be
  # expressible at all.
  def with_every_kind
    with_runners(
      urls: { "CHOPSHOP_RUNNER_PIPELINE_URL" => "http://pipeline.invalid:8791",
              "CHOPSHOP_RUNNER_FLUXBOX_URL" => "http://flux.invalid:8795",
              "CHOPSHOP_RUNNER_DOCS_URL" => "http://docs.invalid:8796",
              "CHOPSHOP_RUNNER_BP_URL" => "http://bp.invalid:8796" },
      kinds: { "CHOPSHOP_RUNNER_FLUXBOX_KIND" => "flux",
               "CHOPSHOP_RUNNER_DOCS_KIND" => "plot",
               "CHOPSHOP_RUNNER_BP_KIND" => "blender" }
    ) { yield }
  end

  def blank_job(runner: "pipeline", spec: {}, input_path: "/uploads/art.png")
    Job.new(name: "chain", runner: runner, source_kind: "raster",
            input_path: input_path, spec: spec)
  end

  def messages(job)
    job.valid?
    job.errors.full_messages
  end

  # --- back-compat: a spec with no step list -------------------------------

  test "a spec with no steps behaves exactly as today" do
    with_every_kind do
      job = blank_job(runner: "pipeline", spec: { "sweep" => { "preset" => "bw" } })
      refute job.sequenced?, "no step list, no chain"
      assert_equal 1, job.steps.size, "a single-action job is the one-element case"

      step = job.steps.first
      assert_equal "pipeline", step["runner"]
      assert_equal({ "sweep" => { "preset" => "bw" } }, step["svg"],
                   "a pipeline job's block is its whole spec: the runner contract takes one document")
      refute step.key?("input"), "and it makes no hand-off declaration"
    end
  end

  test "an implicit step of a document job reports its own kind's block" do
    with_every_kind do
      plot = Job.new(name: "chart", runner: "docs", spec: { "plot" => { "op" => "generate", "doc" => { "a" => 1 } } })
      assert_equal({ "runner" => "docs", "plot" => { "op" => "generate", "doc" => { "a" => 1 } } }, plot.steps.first)

      blender = Job.new(name: "scene", runner: "bp", spec: { "blender" => { "doc" => { "elements" => [] } } })
      assert_equal({ "runner" => "bp", "blender" => { "doc" => { "elements" => [] } } }, blender.steps.first)
    end
  end

  test "the per-kind validators still fire for a job with no step list" do
    with_every_kind do
      assert_includes messages(blank_job(runner: "fluxbox", spec: {})), "a FLUX job needs a prompt"
      assert_includes messages(blank_job(runner: "docs", spec: {})), "a PLOT job needs an operation: one of generate, digest, query"
      assert_includes messages(blank_job(runner: "bp", spec: {})), "a BLENDER job needs a document to render"

      # And the same jobs, with what they ask for, are valid as they always were.
      assert blank_job(runner: "fluxbox", spec: { "flux" => { "prompt" => "a phoenix" } }).valid?
      assert blank_job(runner: "docs",
                       spec: { "plot" => { "op" => "generate", "doc" => { "a" => 1 } } }).valid?
      assert blank_job(runner: "bp",
                       spec: { "blender" => { "doc" => { "elements" => [] } } }).valid?
    end
  end

  # --- the step list itself ------------------------------------------------

  test "a two-step spec validates and normalises" do
    with_every_kind do
      job = blank_job(runner: "fluxbox", input_path: "", spec: {
        "steps" => [
          { "runner" => "fluxbox", "flux" => { "prompt" => "  a phoenix  ", "mode" => "raster" } },
          { "runner" => "PIPELINE", "svg" => { "sweep" => { "preset" => "bw" } } }
        ]
      })

      assert job.valid?, job.errors.full_messages.inspect
      assert job.sequenced?
      assert_equal %w[fluxbox pipeline], job.step_runners, "labels are recorded as the registry spells them"
      assert_equal %w[fluxbox pipeline], job.steps.map { |s| s["runner"] }
      assert_equal %w[flux svg], job.steps.map { |s| Job.runner_kind(s["runner"]) }
      assert_equal "pipeline", job.step(2)["runner"], "Job#step is 1-based"
      assert_nil job.step(3), "and past the end it is nil rather than a crash"
      assert_equal({ "sweep" => { "preset" => "bw" } }, job.step(2)["svg"])
    end
  end

  test "a three-step spec validates, including a blend step handed the traced SVG" do
    with_every_kind do
      job = blank_job(runner: "fluxbox", input_path: "", spec: {
        "steps" => [
          { "runner" => "fluxbox", "flux" => { "prompt" => "a phoenix" } },
          { "runner" => "pipeline", "svg" => { "sweep" => { "preset" => "bw" } } },
          { "runner" => "bp", "input" => "previous",
            "blender" => { "doc" => { "extrude" => { "depth" => 40 } } } }
        ]
      })

      assert job.valid?, job.errors.full_messages.inspect
      assert_equal 3, job.steps.size
      # The middle step is a pipeline step that needs a source and gets it from
      # step 1 -- no artwork was declared at all, and none was needed.
      assert_equal "previous", job.steps.last["input"]
    end
  end

  test "a step that asks for the step before it when there is none is refused, by index" do
    with_every_kind do
      job = blank_job(runner: "bp", input_path: "", spec: {
        "steps" => [{ "runner" => "bp", "input" => "previous",
                      "blender" => { "doc" => { "elements" => [] } } }]
      })
      assert_includes messages(job), "step 1: there is no step before it to hand a file from"
    end
  end

  test "the hand-off declaration goes beside the runner, and is refused inside the block" do
    with_every_kind do
      job = blank_job(runner: "bp", input_path: "", spec: {
        "steps" => [{ "runner" => "fluxbox",
                      "flux" => { "prompt" => "x", "input" => "previous" } }]
      })
      assert_includes messages(job),
                      "step 1: the input declaration goes beside the runner label, not inside the flux block"
    end
  end

  test "an invalid step names its index" do
    with_every_kind do
      job = blank_job(runner: "fluxbox", input_path: "", spec: {
        "steps" => [
          { "runner" => "fluxbox", "flux" => { "prompt" => "a phoenix" } },
          { "runner" => "fluxbox", "flux" => { "prompt" => "" } },
          { "runner" => "docs", "plot" => { "op" => "generate" } }
        ]
      })

      errors = messages(job)
      assert_includes errors, "step 2: a FLUX job needs a prompt"
      assert_includes errors, "step 3: a PLOT job needs a document to draw",
                      "the SAME validator a whole job runs, with the step named"
      refute_includes errors, "a FLUX job needs a prompt",
                      "and never the bare message: a chain has to say where it stopped"
    end
  end

  test "a step naming an unknown runner label is refused" do
    with_every_kind do
      job = blank_job(runner: "pipeline", spec: {
        "steps" => [
          { "runner" => "pipeline", "svg" => {} },
          { "runner" => "never-heard-of-it", "svg" => {} }
        ]
      })
      error = messages(job).find { |m| m.start_with?("step 2: unknown runner") }
      refute_nil error, messages(job).inspect
      assert_match(/"never-heard-of-it"/, error)
      assert_match(/pipeline/, error, "the message says which labels there are")
    end
  end

  test "a step with no runner label, and a step list that is not a list, are refused" do
    with_every_kind do
      assert_includes messages(blank_job(spec: { "steps" => [{ "svg" => {} }] })),
                      "step 1: a step needs a runner label"
      assert_includes messages(blank_job(spec: { "steps" => ["pipeline"] })),
                      "step 1: a step must be a JSON object"
      assert_includes messages(blank_job(spec: { "steps" => {} })),
                      "a step list (steps) must be a JSON array of steps"
      assert_includes messages(blank_job(spec: { "steps" => [] })),
                      "a step list needs at least one step"
      assert_includes messages(blank_job(spec: { "steps" => [{ "runner" => "pipeline", "input" => "sideways" }] })),
                      "step 1: input must be \"job\" or \"previous\""
    end
  end

  test "an empty step list is not a chain, and a spec carrying the key is untouched" do
    with_every_kind do
      job = blank_job(runner: "fluxbox", spec: { "steps" => [], "flux" => { "prompt" => "a phoenix" } })
      refute job.sequenced?
      assert_equal 1, job.steps.size
      assert_includes messages(job), "a step list needs at least one step",
                      "while it is still refused rather than silently ignored"
    end
  end

  # --- the hand-off table --------------------------------------------------

  test "a step that needs a source and has none is refused, by index" do
    with_every_kind do
      job = blank_job(runner: "pipeline", input_path: "", spec: {
        "steps" => [{ "runner" => "pipeline", "svg" => {} }]
      })
      assert_includes messages(job),
                      "step 1: a SVG step needs an artwork source, and this job has none " \
                      "(no artwork, and no earlier step that produces one)"
    end
  end

  test "a step that needs a source takes the job's own artwork when nothing precedes it" do
    with_every_kind do
      job = blank_job(runner: "pipeline", input_path: "/uploads/art.png", spec: {
        "steps" => [{ "runner" => "pipeline", "svg" => {} }]
      })
      assert job.valid?, job.errors.full_messages.inspect
    end
  end

  test "a document runner cannot be handed a file" do
    with_every_kind do
      job = blank_job(runner: "docs", input_path: "", spec: {
        "steps" => [
          { "runner" => "fluxbox", "flux" => { "prompt" => "a phoenix" } },
          { "runner" => "docs", "input" => "previous",
            "plot" => { "op" => "generate", "doc" => { "a" => 1 } } }
        ]
      })
      error = messages(job).find { |m| m.start_with?("step 2") }
      assert_match(/takes a document, not a file/, error.to_s)
      assert_match(/step 1's output cannot be handed/, error.to_s)
    end
  end

  test "the kind handed the file decides which extensions it will take" do
    with_every_kind do
      # A flux step takes a RASTER: a plot step produces an SVG, so that is refused.
      flux_after_plot = blank_job(runner: "fluxbox", input_path: "", spec: {
        "steps" => [
          { "runner" => "docs", "plot" => { "op" => "generate", "doc" => { "a" => 1 } } },
          { "runner" => "fluxbox", "input" => "previous", "flux" => { "prompt" => "x" } }
        ]
      })
      assert_match(/step 2: a FLUX step takes \.png from step 1, which produces \.svg/,
                   messages(flux_after_plot).join(" | "))

      # And a blend step takes an SVG (it is converted into geometry), never a raster.
      blend_after_flux = blank_job(runner: "bp", input_path: "", spec: {
        "steps" => [
          { "runner" => "fluxbox", "flux" => { "prompt" => "x" } },
          { "runner" => "bp", "input" => "previous", "blender" => { "doc" => { "elements" => [] } } }
        ]
      })
      assert_match(/step 2: a BLENDER step takes \.svg from step 1, which produces \.png/,
                   messages(blend_after_flux).join(" | "))

      # The pairings that DO work.
      assert blank_job(runner: "bp", input_path: "/uploads/art.png", spec: {
        "steps" => [
          { "runner" => "pipeline", "svg" => {} },
          { "runner" => "bp", "input" => "previous", "blender" => { "doc" => { "elements" => [] } } }
        ]
      }).valid?
      assert blank_job(runner: "pipeline", input_path: "", spec: {
        "steps" => [
          { "runner" => "bp", "blender" => { "doc" => { "elements" => [] } } },
          { "runner" => "pipeline", "input" => "previous", "svg" => {} }
        ]
      }).valid?, "a render's frame is a raster, and a pipeline step traces rasters"
    end
  end

  test "a flux step in a chain generates a raster and may not ask to be traced" do
    with_every_kind do
      job = blank_job(runner: "fluxbox", input_path: "", spec: {
        "steps" => [
          { "runner" => "fluxbox", "flux" => { "prompt" => "a phoenix", "mode" => "trace" } },
          { "runner" => "pipeline", "svg" => {} }
        ]
      })
      assert_match(/step 1: a FLUX step in a step list generates a raster and stops/,
                   messages(job).join(" | "))
    end
  end

  # --- a document runner's block, pasted as a string ------------------------

  test "a step's document pasted as a JSON string is parsed once, like a job's" do
    with_every_kind do
      job = blank_job(runner: "docs", input_path: "", spec: {
        "steps" => [{ "runner" => "docs",
                      "plot" => { "op" => "generate", "doc" => '{"a":1}' } }]
      })
      assert job.valid?, job.errors.full_messages.inspect
      assert_equal({ "a" => 1 }, job.steps.first["plot"]["doc"])

      blender = blank_job(runner: "bp", input_path: "", spec: {
        "steps" => [{ "runner" => "bp", "blender" => { "doc" => '{"elements":[]}' } }]
      })
      assert blender.valid?, blender.errors.full_messages.inspect
      assert_equal [], blender.steps.first["blender"]["doc"]["elements"]
    end
  end

  # --- a step list filed against a document label ---------------------------

  test "a step list is the request, so the job is not also asked for a top-level document" do
    with_every_kind do
      job = blank_job(runner: "bp", input_path: "", spec: {
        "steps" => [
          { "runner" => "fluxbox", "flux" => { "prompt" => "a phoenix" } },
          { "runner" => "pipeline", "svg" => {} },
          { "runner" => "bp", "blender" => { "doc" => { "elements" => [] } } }
        ]
      })
      assert job.valid?, job.errors.full_messages.inspect
      refute_includes messages(job), "a BLENDER job needs a document to render",
                      "the job's own label is not the request: the step list is"
    end
  end

  # --- progress readers ----------------------------------------------------

  test "the progress ledger is readable, and a job without one reports nothing" do
    job = Job.new(name: "chain", runner: "mock", spec: {})
    assert_equal({}, job.steps_progress)
    assert_equal [], job.steps_recorded
    assert_nil job.current_step_index
    assert_nil job.current_step

    chained = Job.new(name: "chain", runner: "mock", input_path: "/uploads/art.png",
                      spec: { "steps" => [{ "runner" => "mock", "svg" => {} },
                                          { "runner" => "mock", "svg" => {} },
                                          { "runner" => "mock", "svg" => {} }] })
    chained.steps_state = {
      "current" => 2, "total" => 3, "state" => "running",
      "steps" => [{ "index" => 1, "runner" => "fluxbox", "state" => "done" },
                  { "index" => 2, "runner" => "pipeline", "state" => "running",
                    "runner_job_id" => "runner-7" }]
    }
    assert_equal 2, chained.current_step_index
    assert_equal "mock", chained.current_step["runner"], "the RUNNING step, from the list, by index"
    assert_equal "pipeline", chained.pipeline_step_runner
  end

  test "a chain's runner-facing identity is the runner its pipeline step ran on" do
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_TRACEBOX_URL"] = "http://trace.invalid:8791"
      ENV["CHOPSHOP_RUNNER_UNUSED_URL"] = "http://unused.invalid:8792"
      Job.reset_runners_cache!

      job = Job.new(name: "chain", runner: "unused", runner_job_id: "runner-9", spec: {
        "steps" => [{ "runner" => "unused", "svg" => {} },
                    { "runner" => "tracebox", "svg" => {} }]
      })
      job.steps_state = { "steps" => [{ "index" => 2, "runner" => "tracebox", "runner_job_id" => "runner-9" }] }

      assert_equal "tracebox", job.execution_runner,
                   "the candidates and the archive live on the runner that traced the chain"
      assert_equal "http://trace.invalid:8791", job.base_url
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end
end
