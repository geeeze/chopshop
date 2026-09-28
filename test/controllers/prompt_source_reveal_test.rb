require "test_helper"

# Generated art has to be able to say what drew it. A flux tile (every variation
# of a batch, and the single raster-only deliverable) carries the prompt that
# generated it plus, for an img2img edit, the reference image it was made from;
# the preview popup offers both behind its Prompt / Source toggle.
#
# Flux tiles ONLY: a traced candidate has no prompt behind it, so its popup must
# not offer the control at all. That asymmetry is the contract this file pins --
# the toggle is driven by whether data-cs-prompt reached the popup, not by the
# page it opened from.
class PromptSourceRevealTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  PROMPT = "a lighthouse at dusk, screenprint, four inks".freeze
  REFERENCE = "upload_reference.png".freeze

  # Hermetic: every runner variable is cleared first, so the test sees exactly
  # the runners it asked for rather than the deployment's.
  def with_flux_runner
    saved = {}
    (ENV.keys.grep(/\ACHOPSHOP_RUNNER_/) + %w[CHOPSHOP_FLUX_HANDOFF_RUNNER]).each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_FLUX_URL"] = "http://generator.invalid:8795"
      ENV["CHOPSHOP_RUNNER_FLUX_KIND"] = "flux"
      Job.reset_runners_cache!
      yield
    ensure
      (ENV.keys.grep(/\ACHOPSHOP_RUNNER_/) + %w[CHOPSHOP_FLUX_HANDOFF_RUNNER]).each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  setup do
    @original_password = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
  end

  teardown do
    ENV["CHOPSHOP_PASSWORD"] = @original_password
  end

  def sign_in
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def js
    Rails.root.join("app/javascript/aether.js").read(encoding: "UTF-8")
  end

  # A generated variation, as RunJob records it: a stored upload plus the facts
  # the service reported for that image.
  def variation(name:, seed: 7)
    { "file" => name, "seed" => seed, "model" => "klein-4b",
      "width" => 512, "height" => 512, "seconds" => 3.4 }
  end

  def flux_job(mode:, images:, image: nil)
    spec = { "flux" => { "mode" => mode, "prompt" => PROMPT,
                         "rendered" => { "images" => images } } }
    spec["flux"]["image"] = image if image
    Job.create!(name: "generated", state: "done", source_kind: "raster", runner: "flux",
                input_path: "/tmp/generated.png", stem: "generated", spec: spec)
  end

  # --- the flux tiles carry their own provenance ---

  test "every variation tile carries the prompt that generated it" do
    with_flux_runner do
      sign_in
      job = flux_job(mode: "raster", images: [variation(name: "flux_a.png"),
                                              variation(name: "flux_b.png"),
                                              variation(name: "flux_c.png")])
      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      doc = Nokogiri::HTML(response.body)
      tiles = doc.css(".variations-grid .variation-tile a[data-cs-view]")
      assert_equal 3, tiles.size

      tiles.each do |tile|
        assert_equal PROMPT, tile["data-cs-prompt"], "each tile names its generating prompt"
        assert_equal job.id.to_s, tile["data-cs-job"]
        assert_equal "1", tile["data-cs-fav-off"],
          "a generated raster has no runner file: the popup's star would 502"
        assert_includes tile["data-cs-facts"].to_s, "seed 7", "the render facts travel with it"
      end
    end
  end

  test "a raster-only job's single deliverable carries its prompt too" do
    with_flux_runner do
      sign_in
      job = flux_job(mode: "raster", images: [variation(name: "flux_only.png")])
      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      tile = Nokogiri::HTML(response.body).at_css(".variations-grid .variation-tile a[data-cs-prompt]")
      refute_nil tile, "the one deliverable reveals its prompt"
      assert_equal PROMPT, tile["data-cs-prompt"]
    end
  end

  # --- the source image is offered for an edit, never for a plain generation ---

  test "an img2img tile offers the reference image it was edited from" do
    with_flux_runner do
      sign_in
      job = flux_job(mode: "raster", images: [variation(name: "flux_edit.png")], image: REFERENCE)
      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      tile = Nokogiri::HTML(response.body).at_css(".variations-grid .variation-tile a")
      assert_equal upload_preview_jobs_path(name: REFERENCE), tile["data-cs-prompt-source"],
        "the reference travels as a login-gated upload preview, not a raw path"
    end
  end

  test "a text-to-image tile has a prompt but no source" do
    with_flux_runner do
      sign_in
      job = flux_job(mode: "raster", images: [variation(name: "flux_t2i.png")])
      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      tile = Nokogiri::HTML(response.body).at_css(".variations-grid .variation-tile a")
      assert_nil tile["data-cs-prompt-source"],
        "there is no reference to show when nothing was edited"
    end
  end

  # --- and a traced candidate offers neither ---

  test "a traced candidate's popup has no prompt or source reveal" do
    sign_in
    job = Job.create!(name: "traced", state: "done", source_kind: "raster",
                      input_path: "/data/x.png", stem: "traced", spec: {}, runner: "mock",
                      comparison: { "candidates" => [
                        { "file" => "candidate_01.svg", "sweep" => { "preset" => "bw" },
                          "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" },
                          "hard" => 0, "advisory" => 0, "fidelity" => {}, "passed" => true }
                      ] })
    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    doc = Nokogiri::HTML(response.body)
    row = doc.at_css("tr.rowlink[data-cs-view]")
    refute_nil row, "the traced candidate still opens in the preview popup"
    assert_nil row["data-cs-prompt"]
    assert_nil row["data-cs-prompt-source"]
    assert_empty doc.css("[data-cs-prompt]"),
      "no surface of a traced job claims a prompt"
    # The document has no facts to reveal, so the panel the toolbox builds for
    # it can never be opened.
    assert_includes js, "if (prompt) prompt.hidden = !info.prompt;"
  end
end
