require "test_helper"

# WHAT A JOB WILL ACCEPT AS ITS SOURCE.
#
# A trace job's input is opened by the pipeline's prep stage with PIL, which reads
# raster formats only. So an SVG artwork is not "a job with a problem" — it is a
# job that cannot run, and the failure used to surface from inside the runner as
#   UnidentifiedImageError: cannot identify image file '.../upload_x.svg'
# a PIL error naming a library the operator never chose.
#
# THREE live jobs failed that way, reached three different routes. Two are covered
# elsewhere and are named here so the set is visible in one place:
#
#   * a step list chaining `bp generate` into a trace step — JobStepsTest
#   * a composite whose VECTOR flatten produced an SVG, handed to Run Job — here
#   * a direct POST naming an uploads/*.svg as the artwork — here
#
# The check lives on the create path because that is the one door every real job
# comes through, and it is asked of the KIND and the FILE, never `source_kind`:
# every one of the failed jobs carried "raster" while pointing at an SVG.
class JobSourceTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def sign_in
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def with_runners
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_PIPELINE_URL"] = "http://pipeline.invalid:8791"
      ENV["CHOPSHOP_RUNNER_FLUXBOX_URL"] = "http://flux.invalid:8795"
      ENV["CHOPSHOP_RUNNER_FLUXBOX_KIND"] = "flux"
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def post_job(runner:, input_path:, spec: "{}")
    post jobs_path, params: { job: { name: "src probe", runner: runner,
                                     source_kind: "raster", input_path: input_path,
                                     project_id: picker_project.id,
                                     spec: spec } },
                    headers: { "User-Agent" => MODERN_UA }
  end

  # --- the refusal ---------------------------------------------------------

  test "a trace job refuses an SVG source, naming the way out" do
    with_runners do
      sign_in
      post_job(runner: "pipeline",
               input_path: Rails.root.join("storage", "uploads", "upload_abc.svg").to_s)

      refute_equal 302, response.status,
        "the job must not be queued: it cannot run on the runner it names"
      message = response.body
      assert_match(/must be a \.png \/ \.jpg \/ \.jpeg/, message)
      assert_match(/cannot open an SVG/, message, "it says WHY, not just which types")
      assert_match(/render the drawing to PNG first/, message,
        "and it names the remedy — tracing a drawing is a reasonable intent with " \
        "a real answer, so a bare type mismatch is a dead end")
      assert_match(/flatten the composite as pixels/, message,
        "including the composite route, which is how two of the three failures arose")
    end
  end

  test "a raster source is still accepted" do
    with_runners do
      sign_in
      runner = RunJob
      # Queuing is stubbed out: this asserts the SOURCE GATE, not the run.
      original = runner.method(:perform_later)
      runner.define_singleton_method(:perform_later) { |_id| Struct.new(:job_id).new("stub") }
      begin
        post_job(runner: "pipeline",
                 input_path: Rails.root.join("storage", "uploads", "upload_abc.png").to_s)
        assert_response :redirect,
          "a PNG is what the trace stage reads, so it must still be accepted"
        assert_equal ".png", File.extname(Job.order(:id).last.input_path)
      ensure
        runner.define_singleton_method(:perform_later, original)
      end
    end
  end

  test "the rule is about the KIND, so a generator is unaffected" do
    with_runners do
      sign_in
      # A flux job's own input_path is blank by design (its source is generated),
      # and a blank path is left to the existing "needs a source" rules rather
      # than reported as a bad extension.
      assert_equal false, JobsController.new.send(:trace_source_refused?,
                                                  Job.new(runner: "fluxbox", input_path: ""))
      assert_equal false, JobsController.new.send(:trace_source_refused?,
                                                  Job.new(runner: "fluxbox", input_path: "x.svg")),
        "the check is asked of a TRACE job: a generator does not prep a raster"
    end
  end

  # --- and the vocabulary is shared ----------------------------------------

  test "the refusal is worded in exactly one place" do
    # Both the create path and the scrapbook drop route must refuse in the same
    # words, or an operator meets two different explanations for one rule.
    assert_equal Job.trace_source_refusal("dir/thing.svg"),
                 Job.trace_source_refusal("/other/thing.svg").sub("/other/thing.svg", "dir/thing.svg"),
                 "the wording depends on the extension, not the path"

    assert_includes Job.trace_source_refusal("thing.svg"), ".svg"
    assert_includes Job.trace_source_refusal("thing.pdf"), ".pdf"
    assert_includes Job.trace_source_refusal("noext"),
                    "not a file type the trace stage reads"

    assert Job.raster_source?("x.png")
    assert Job.raster_source?("x.JPG"), "the extension is compared case-insensitively"
    refute Job.raster_source?("x.svg")
    refute Job.raster_source?("x.pdf")
    refute Job.raster_source?("")
  end
end
