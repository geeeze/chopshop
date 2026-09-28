require "test_helper"

# The runner registry's KIND: what a runner does, as opposed to where it is.
#
# The kind is the whole hinge of a FLUX job. It decides which fields the form
# shows, which client the controller uses, and -- because a generator has no job
# state to poll -- which runner the job's files actually live on.
#
# Every case here injects env and calls reset_runners_cache!, which is the
# documented way to add a runner at runtime. That only works because the runner
# list is read through Job.runners rather than a constant snapshotted at load.
class JobRunnerKindTest < ActiveSupport::TestCase
  # Runner variables that are not the studio's runner registry but are read at
  # the same moment, so they have to be isolated with it.
  OTHER_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  # Run a block against EXACTLY the runners it names, and no others.
  #
  # Everything is cleared first, deliberately. The box running this suite has
  # real runners configured, so a test that inherited them would be asserting
  # the deployment rather than the code -- passing here and failing on a
  # machine configured differently. "mock" is the model's own default and is
  # always present, so an empty block still has one runner.
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

  def a_pipeline_and_a_generator
    with_runners(
      urls: { "CHOPSHOP_RUNNER_SVG_URL" => "http://10.0.0.18:8791",
              "CHOPSHOP_RUNNER_FLUX_URL" => "http://10.0.0.18:8795" },
      kinds: { "CHOPSHOP_RUNNER_FLUX_KIND" => "flux" }
    ) { yield }
  end

  # --- the default ---------------------------------------------------------

  test "a runner with no declared kind is a pipeline runner" do
    with_runners(urls: { "CHOPSHOP_RUNNER_STUDIO_A_URL" => "http://127.0.0.1:9000" }) do
      assert_equal "svg", Job.runner_kind("studio_a"),
        "the default has to be svg or every existing deployment changes meaning"
      assert_equal "svg", Job.runner_kind("mock")
      refute Job.flux_runner?("studio_a")
      assert_empty Job.flux_runners
      assert_includes Job.pipeline_runners, "studio_a"
    end
  end

  test "an unknown label is a pipeline runner, not a crash" do
    assert_equal "svg", Job.runner_kind("never-heard-of-it")
  end

  test "the kind is read case- and whitespace-insensitively" do
    with_runners(
      urls: { "CHOPSHOP_RUNNER_FLUX_URL" => "http://127.0.0.1:8795" },
      kinds: { "CHOPSHOP_RUNNER_FLUX_KIND" => "  FLUX  " }
    ) do
      assert_equal "flux", Job.runner_kind("flux")
    end
  end

  # --- hand-off ------------------------------------------------------------

  test "hand-off prefers a real pipeline runner over the local simulation" do
    a_pipeline_and_a_generator do
      assert_equal "svg", Job.handoff_runner,
        "mock is a simulation; a configured pipeline runner is the real one"
    end
  end

  test "hand-off falls back to mock when that is all there is" do
    with_runners do
      assert_equal "mock", Job.handoff_runner,
        "with no pipeline runner configured, the simulation is what is left"
    end
  end

  test "an explicit hand-off runner wins" do
    with_runners(
      urls: { "CHOPSHOP_RUNNER_SVG_URL" => "http://127.0.0.1:8791",
              "CHOPSHOP_RUNNER_SVG2_URL" => "http://127.0.0.1:8792" },
      kinds: {}
    ) do
      begin
        ENV["CHOPSHOP_FLUX_HANDOFF_RUNNER"] = "svg2"
        Job.reset_runners_cache!
        assert_equal "svg2", Job.handoff_runner
      ensure
        ENV.delete("CHOPSHOP_FLUX_HANDOFF_RUNNER")
        Job.reset_runners_cache!
      end
    end
  end

  test "a hand-off naming a generator is ignored, since a generator cannot trace" do
    a_pipeline_and_a_generator do
      begin
        ENV["CHOPSHOP_FLUX_HANDOFF_RUNNER"] = "flux"
        Job.reset_runners_cache!
        assert_equal "svg", Job.handoff_runner
      ensure
        ENV.delete("CHOPSHOP_FLUX_HANDOFF_RUNNER")
        Job.reset_runners_cache!
      end
    end
  end

  # --- a flux job's URLs ---------------------------------------------------

  test "a flux job polls the hand-off runner, not the generator" do
    a_pipeline_and_a_generator do
      job = Job.new(name: "phoenix", runner: "flux", source_kind: "raster",
                    spec: { "flux" => { "prompt" => "a phoenix" } })
      assert job.flux?
      assert_equal "svg", job.execution_runner
      assert_equal "http://10.0.0.18:8791", job.base_url,
        "the generator has no job state, no candidates and no archive -- every " \
        "URL this job builds belongs to the runner that traced the raster"
      assert_equal "http://10.0.0.18:8795", job.generator_base_url,
        "and generation still goes to the generator"
    end
  end

  test "a recorded hand-off is used once it is in the spec" do
    a_pipeline_and_a_generator do
      job = Job.new(name: "phoenix", runner: "flux", source_kind: "raster",
                    spec: { "flux" => { "prompt" => "a phoenix", "handoff" => "mock" } })
      assert_equal "mock", job.execution_runner,
        "the job remembers which runner it was actually handed to, so a later " \
        "change of the default does not move an existing job's files"
    end
  end

  test "a pipeline job is untouched by all of this" do
    a_pipeline_and_a_generator do
      job = Job.new(name: "art", runner: "svg", source_kind: "raster", spec: {})
      refute job.flux?
      assert_equal "svg", job.execution_runner
      assert_equal "http://10.0.0.18:8791", job.base_url
    end
  end

  # --- the flux block ------------------------------------------------------

  test "flux_config is the spec's block, and empty when there is none" do
    assert_equal({}, Job.new(spec: {}).flux_config)
    assert_equal({}, Job.new(spec: { "flux" => "not a hash" }).flux_config)
    assert_equal({ "prompt" => "x" }, Job.new(spec: { "flux" => { "prompt" => "x" } }).flux_config)
  end

  test "the mode is trace unless it says otherwise" do
    assert_equal "trace", Job.new(spec: { "flux" => {} }).flux_mode
    assert_equal "trace", Job.new(spec: { "flux" => { "mode" => "nonsense" } }).flux_mode,
      "an unrecognised mode is not a third behaviour"
    assert_equal "raster", Job.new(spec: { "flux" => { "mode" => "raster" } }).flux_mode
  end

  test "raster_only? needs both a flux runner and the raster mode" do
    raster = { "flux" => { "prompt" => "x", "mode" => "raster" } }
    a_pipeline_and_a_generator do
      assert Job.new(runner: "flux", spec: raster).raster_only?
      refute Job.new(runner: "flux", spec: { "flux" => { "prompt" => "x" } }).raster_only?
      refute Job.new(runner: "svg", spec: raster).raster_only?,
        "a stray flux block on a pipeline job must not change how it runs"
    end
  end

  # --- the plot kind -------------------------------------------------------

  test "a plot runner is neither a pipeline runner nor a job runner" do
    with_runners(
      urls: { "CHOPSHOP_RUNNER_SVG_URL" => "http://127.0.0.1:8791",
              "CHOPSHOP_RUNNER_PLOT_URL" => "http://127.0.0.1:8796" },
      kinds: { "CHOPSHOP_RUNNER_PLOT_KIND" => "plot" }
    ) do
      assert_equal "plot", Job.runner_kind("plot")
      assert Job.plot_runner?("plot")
      assert_equal ["plot"], Job.plot_runners
      # It speaks chopshop-plot's own serve API and holds no job state, so it is
      # not a pipeline runner: `reject { flux_runner? }` would have admitted it.
      assert_equal %w[mock svg], Job.pipeline_runners
      assert_equal %w[mock svg], Job.job_runners
      assert_equal "svg", Job.handoff_runner,
        "a plot runner cannot trace, so it must never be a hand-off target"
      assert_equal "plot", Job.plot_runners.first
      refute Job.flux_runner?("plot"), "a plot runner is not a generator"
      refute_includes Job.job_runners, "plot",
        "Run Job switches its fields on the kind, so a plot option would be a " \
        "form with no fields for it"
    end
  end

  test "a plot runner is a first-class label: it is in the map, with a URL" do
    with_runners(
      urls: { "CHOPSHOP_RUNNER_PLOT_URL" => "http://127.0.0.1:8796" },
      kinds: { "CHOPSHOP_RUNNER_PLOT_KIND" => "plot" }
    ) do
      assert_includes Job.runners.keys, "plot"
      assert_equal "http://127.0.0.1:8796", Job.runners["plot"]
      assert_includes Job::RUNNER_KINDS, "plot"
    end
  end

  test "the kind is read case- and whitespace-insensitively for plot too" do
    with_runners(
      urls: { "CHOPSHOP_RUNNER_PLOT_URL" => "http://127.0.0.1:8796" },
      kinds: { "CHOPSHOP_RUNNER_PLOT_KIND" => "  PLOT  " }
    ) do
      assert_equal "plot", Job.runner_kind("plot")
    end
  end

  test "a hand-off naming a plot runner is ignored, since it cannot trace" do
    with_runners(
      urls: { "CHOPSHOP_RUNNER_SVG_URL" => "http://127.0.0.1:8791",
              "CHOPSHOP_RUNNER_PLOT_URL" => "http://127.0.0.1:8796" },
      kinds: { "CHOPSHOP_RUNNER_PLOT_KIND" => "plot" }
    ) do
      begin
        ENV["CHOPSHOP_FLUX_HANDOFF_RUNNER"] = "plot"
        Job.reset_runners_cache!
        assert_equal "svg", Job.handoff_runner
      ensure
        ENV.delete("CHOPSHOP_FLUX_HANDOFF_RUNNER")
        Job.reset_runners_cache!
      end
    end
  end

  test "every declared kind is one the model knows" do
    # A kind in the registry that nothing branches on is a label that reads as
    # supported and is not -- the whole point of listing them.
    assert_equal %w[svg flux plot], Job::RUNNER_KINDS
    assert_equal Job::RUNNER_KINDS.sort, Job::RUNNER_KINDS.uniq.sort
  end

  # --- validation ----------------------------------------------------------

  test "a flux job needs a prompt before it is worth a round trip to the GPU" do
    a_pipeline_and_a_generator do
      job = Job.new(name: "phoenix", runner: "flux", source_kind: "raster",
                    spec: { "flux" => { "prompt" => "" } })
      refute job.valid?
      assert_includes job.errors.full_messages, "a FLUX job needs a prompt"

      job.spec = { "flux" => { "prompt" => "  a phoenix  " } }
      assert job.valid?, job.errors.full_messages.inspect
      assert_equal "a phoenix", job.flux_prompt, "and it is trimmed"
    end
  end

  test "a pipeline job is not asked for a prompt" do
    job = Job.new(name: "art", runner: "mock", source_kind: "raster", spec: {})
    assert job.valid?, job.errors.full_messages.inspect
  end

  test "the runner list is validated against the live env, not a load-time snapshot" do
    with_runners(urls: { "CHOPSHOP_RUNNER_LATE_URL" => "http://127.0.0.1:9100" }) do
      assert Job.new(name: "x", runner: "late", spec: {}).valid?,
        "a runner added after boot is a runner; the inclusion check has to ask " \
        "the same question the form does"
    end
  end
end
