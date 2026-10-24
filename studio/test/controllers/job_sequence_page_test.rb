require "test_helper"

# A chained job's page must render. The Jobs-page removal (76c80dd) deleted
# app/views/jobs/_process.html.erb while jobs/show still renders it for a
# sequenced job (`<% if @job.sequenced? %> render "process"`), so every
# step-list job 500'd with ActionView::MissingTemplate — the exact feature
# docs/step-lists.md and README advertise. The partial is restored (see #32);
# this pins both directions: chains render the process card, single-action
# jobs do not.
class JobSequencePageTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze
  HANDOFF_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  def login_and_get(path)
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get path, headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # One runner of each of the two kinds a chain needs — the same shape the
  # model tests validate against (flux produces the artwork the svg step
  # takes, so the chain validator is satisfied for real, not stubbed).
  def with_chain_runners
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    HANDOFF_ENV.each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_PIPELINE_URL"] = "http://pipeline.invalid:8791"
      ENV["CHOPSHOP_RUNNER_FLUXBOX_URL"] = "http://flux.invalid:8795"
      ENV["CHOPSHOP_RUNNER_FLUXBOX_KIND"] = "flux"
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      HANDOFF_ENV.each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  test "a sequenced job's page renders the process card, one row per step" do
    with_chain_runners do
      job = Job.create!(name: "chain-probe", state: "queued", source_kind: "raster",
                        runner: "fluxbox", input_path: "/uploads/art.png",
                        spec: { "steps" => [
                          { "runner" => "fluxbox",
                            "flux" => { "prompt" => "a phoenix", "mode" => "raster" } },
                          { "runner" => "pipeline",
                            "svg" => { "sweep" => { "preset" => "bw" } } }
                        ] })
      assert job.sequenced?, "the fixture must be a chain"

      login_and_get(job_path(job))
      assert_response :success

      doc = Nokogiri::HTML(response.body)
      card = doc.at_css(".process-card")
      refute_nil card, "the process card renders (the restored _process partial)"

      rows = card.css("tr[data-step]")
      assert_equal 2, rows.size, "one table row per declared step"
      assert_match(/flux/, rows[0].text,
        "a step with no op reads the runner's own operation (fluxbox -> flux)")
      assert_match(/svg/, rows[1].text,
        "a step with no op reads the runner's own operation (pipeline -> svg)")
      assert_match(/of 2/, card.text.gsub(/\s+/, " "), "the step counter counts the chain")
    end
  end

  test "a single-action job's page does not render the process card" do
    job = Job.create!(name: "single-probe", state: "queued", source_kind: "raster",
                      runner: "mock", input_path: "", spec: {})
    refute job.sequenced?, "no steps, no chain"

    login_and_get(job_path(job))
    assert_response :success
    refute Nokogiri::HTML(response.body).at_css(".process-card"),
      "the card belongs to chains only"
  end
end
