require "test_helper"

# A flux job's PROVENANCE: what the job page shows as the source, what the
# preview popup reveals, and what the 7z download carries.
#
# A flux job is drawn two ways and finished two ways, and each combination has
# its own truth about "the source":
#
#   text-to-image / raster-only   no runner at all: the source is the generated
#                                 raster in storage/uploads, and its
#                                 colour-inverted twin is made locally when the
#                                 raster lands.
#   img2img                       a reference image was piped in, and it is the
#                                 studio's own upload — no runner ever holds it.
#   trace mode                    the runner holds the raster (source.png) and
#                                 the twin prep drew (source.inverse.png), so
#                                 the pair is proxied exactly as a pipeline
#                                 job's is, and the reference is STILL shown
#                                 beside it.
#
# The download has to carry what the runner's archive cannot: the prompt, the
# config, the reference, every raster and the twin — with the runner's own
# archive riding along, untouched, as pipeline.7z in trace mode.
#
# The tiles themselves live in the page's `.source-stack`, below the candidates
# and the proofs (see JobSourceStackTest). These tests read them out of that
# container, so a tile that drifts back above the results fails here too.
class FluxProvenanceTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  PROMPT = "a lighthouse at dusk, screenprint, four inks".freeze
  REFERENCE = "upload_reference.png".freeze
  RASTER = "flux_raster_aa11.png".freeze
  TWIN = "flux_inverse_bb22.png".freeze
  # Stands in for the runner's own 7z: the bundle must carry it BYTE FOR BYTE.
  PIPELINE_ARCHIVE = "7z\u001c\u0022the runner's own archive\u0022".b.freeze

  EXTRA_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  # Hermetic: every runner variable is cleared first, then a generator and a
  # pipeline are configured explicitly — so a trace-mode job's hand-off goes to
  # the runner this test chose rather than the deployment's.
  def with_flux_runners
    saved = {}
    (ENV.keys.grep(/\ACHOPSHOP_RUNNER_/) + EXTRA_RUNNER_ENV).each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_FLUX_URL"] = "http://generator.invalid:8795"
      ENV["CHOPSHOP_RUNNER_FLUX_KIND"] = "flux"
      ENV["CHOPSHOP_RUNNER_SVG_URL"] = "http://pipeline.invalid:8791"
      Job.reset_runners_cache!
      yield
    ensure
      (ENV.keys.grep(/\ACHOPSHOP_RUNNER_/) + EXTRA_RUNNER_ENV).each { |k| ENV.delete(k) }
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
    cleanup_uploads
  end

  def sign_in
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def uploads
    Rails.root.join("storage", "uploads")
  end

  def cleanup_uploads
    [ RASTER, TWIN, REFERENCE ].each do |name|
      path = uploads.join(name)
      File.delete(path) if path.file?
    end
  end

  # A real 4x4 PNG: the bundle ships real bytes, and a byte-count stand-in
  # would not prove the raster travelled.
  def png_bytes
    image = ChunkyPNG::Image.new(4, 4, ChunkyPNG::Color.rgb(10, 20, 30))
    image[0, 0] = ChunkyPNG::Color.rgb(0, 0, 0)
    image.to_blob
  end

  def write_upload(name, bytes = png_bytes)
    uploads.mkpath
    uploads.join(name).binwrite(bytes)
  end

  # A flux job as the studio stores one after a generation. `rendered` carries
  # the request's settings (which the popup reveals) and the per-image facts
  # (which win over the request's when they differ).
  def flux_job(mode:, runner_job_id: nil, image: nil, inverse: nil, settings: {})
    spec = {
      "flux" => {
        "mode" => mode,
        "prompt" => PROMPT,
        "model" => "sdxl-1.0",
        "width" => 768,
        "height" => 512,
        "steps" => "30",
        "guidance" => "5.0",
        "seed" => 99,
        "images" => 1,
        "rendered" => {
          "images" => [
            { "file" => RASTER, "seed" => 7, "model" => "klein-4b",
              "width" => 512, "height" => 512, "seconds" => 3.4 }
          ]
        }
      }
    }
    spec["flux"]["image"] = image if image
    spec["flux"]["rendered"]["inverse"] = inverse if inverse
    spec["flux"].merge!(settings)

    Job.create!(name: "generated", state: "done", source_kind: "raster", runner: "flux",
                input_path: uploads.join(RASTER).to_s, stem: "generated",
                runner_job_id: runner_job_id, spec: spec)
  end

  def tiles_in(body)
    Nokogiri::HTML(body).css(".source-stack a.pv-tile")
  end

  def tile_named(tiles, name)
    tiles.find { |t| t["data-scrap-name"] == name }
  end

  # --- the source pair, per mode -------------------------------------------

  test "a raster-only job's pair is the generated raster and its locally-made twin" do
    with_flux_runners do
      sign_in
      write_upload(RASTER)
      write_upload(TWIN)
      job = flux_job(mode: "raster", inverse: TWIN)

      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      tiles = tiles_in(response.body)
      assert_equal 2, tiles.size, "a text-to-image raster-only job has the source pair"

      source = tile_named(tiles, RASTER)
      refute_nil source, "the source tile is the generated raster"
      assert_equal upload_preview_jobs_path(name: RASTER), source["href"],
        "served from uploads — a raster-only job has no runner to proxy from"
      assert_equal upload_preview_jobs_path(name: RASTER), source["data-cs-url"]
      assert_equal "src", source.at_css(".pv-label").text

      twin = tile_named(tiles, TWIN)
      refute_nil twin, "the inverse tile is the twin the studio inverted"
      assert_equal upload_preview_jobs_path(name: TWIN), twin["href"]
      assert_equal "inv", twin.at_css(".pv-label").text

      tiles.each do |tile|
        urls = [ tile["href"], tile["data-cs-url"] ].join(" ")
        refute_includes urls, "/file/",
          "a raster-only job must not offer runner URLs: there is no runner behind them"
        assert_equal "1", tile["data-cs-fav-off"],
          "the popup's star POSTs through a runner file proxy that would fail here"
        assert_nil tile["data-cs-reuse-url"], "run-again would ask that runner for source.png"
      end
      assert_equal 0, Nokogiri::HTML(response.body).css(".source-stack [data-scrap-favourite]").size,
        "no runner-fetching favourite button beside a local upload"
    end
  end

  test "a raster-only job with no twin shows the source alone, not a broken tile" do
    with_flux_runners do
      sign_in
      write_upload(RASTER)
      job = flux_job(mode: "raster")

      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      tiles = tiles_in(response.body)
      assert_equal [ RASTER ], tiles.map { |t| t["data-scrap-name"] },
        "the source is still there; the twin tile is simply not claimed"
    end
  end

  test "an img2img job shows the reference that was piped in as its own tile" do
    with_flux_runners do
      sign_in
      write_upload(REFERENCE)
      job = flux_job(mode: "raster", image: REFERENCE, inverse: TWIN)

      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      tiles = tiles_in(response.body)
      assert_equal 3, tiles.size, "reference + generated raster + inverse twin"

      reference = tile_named(tiles, REFERENCE)
      refute_nil reference, "the img2img source is shown as its own tile"
      assert_equal upload_preview_jobs_path(name: REFERENCE), reference["href"],
        "the reference is the studio's upload, behind the login gate"
      assert_equal "ref", reference.at_css(".pv-label").text
    end
  end

  test "a trace-mode job keeps the runner's pair and still shows the reference" do
    with_flux_runners do
      sign_in
      job = flux_job(mode: "trace", runner_job_id: "rj-1", image: REFERENCE)

      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      tiles = tiles_in(response.body)
      assert_equal 3, tiles.size

      source = tile_named(tiles, "source.png")
      refute_nil source, "the runner's raster is what was traced"
      assert_equal file_job_path(job, name: "source.png"), source["href"]
      assert_equal reuse_job_path(job), source["data-cs-reuse-url"]

      twin = tile_named(tiles, "source.inverse.png")
      refute_nil twin, "prep's own twin, proxied as it always was"
      assert_equal file_job_path(job, name: "source.inverse.png"), twin["href"]
      assert_equal use_inverse_job_path(job), twin["data-cs-use-url"]

      reference = tile_named(tiles, REFERENCE)
      refute_nil reference, "the reference is still the studio's to show"
      assert_equal upload_preview_jobs_path(name: REFERENCE), reference["href"]
    end
  end

  test "a pipeline job's pair is still the runner's, unchanged" do
    with_flux_runners do
      sign_in
      job = Job.create!(name: "traced", state: "done", source_kind: "raster", runner: "mock",
                        input_path: "/data/x.png", stem: "traced", spec: {})

      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      tiles = tiles_in(response.body)
      assert_equal %w[source.png source.inverse.png], tiles.map { |t| t["data-scrap-name"] }
      assert_equal file_job_path(job, name: "source.png"), tiles.first["href"]
      assert_equal 2, Nokogiri::HTML(response.body).css(".source-stack [data-scrap-favourite]").size,
        "both tiles keep their runner-fetching star"
    end
  end

  # --- the full config the popup reveals -----------------------------------

  test "a flux tile carries the complete config, with the render's own facts winning" do
    with_flux_runners do
      sign_in
      job = flux_job(mode: "raster", image: REFERENCE, inverse: TWIN,
                     settings: { "negative_prompt" => "blurry", "strength" => "0.55" })

      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      tile = Nokogiri::HTML(response.body).at_css(".source-stack .variations-grid a[data-cs-flux-config]")
      refute_nil tile, "the tile carries the config the popup reveals"

      config = JSON.parse(tile["data-cs-flux-config"])
      # The request's settings...
      assert_equal "30", config["steps"]
      assert_equal "5.0", config["guidance"]
      assert_equal "blurry", config["negative_prompt"]
      assert_equal "0.55", config["strength"]
      assert_equal "raster", config["mode"]
      assert_equal REFERENCE, config["reference"]
      assert_equal 1, config["images"]
      # ...and THIS image's own facts, which describe what was actually drawn.
      assert_equal "klein-4b", config["model"], "the render's model, not the request's"
      assert_equal 512, config["width"]
      assert_equal 512, config["height"]
      assert_equal 7, config["seed"], "the seed that produced this image"
      assert_equal 3.4, config["seconds"]
    end
  end

  test "the source pair carries the same provenance as the variations" do
    with_flux_runners do
      sign_in
      job = flux_job(mode: "raster", image: REFERENCE, inverse: TWIN)

      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      source = tile_named(tiles_in(response.body), RASTER)
      assert_equal PROMPT, source["data-cs-prompt"]
      config = JSON.parse(source["data-cs-flux-config"])
      assert_equal "klein-4b", config["model"]
      assert_equal REFERENCE, config["reference"]

      twin = tile_named(tiles_in(response.body), TWIN)
      assert_equal PROMPT, twin["data-cs-prompt"], "the twin is the same raster, inverted"
      refute_nil twin["data-cs-flux-config"]
    end
  end

  test "a traced candidate's page claims no prompt and no config anywhere" do
    with_flux_runners do
      sign_in
      job = Job.create!(name: "traced", state: "done", source_kind: "raster",
                        input_path: "/data/x.png", stem: "traced", runner: "mock", spec: {},
                        comparison: { "candidates" => [
                          { "file" => "candidate_01.svg", "sweep" => { "preset" => "bw" },
                            "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" },
                            "hard" => 0, "advisory" => 0, "fidelity" => {}, "passed" => true }
                        ] })

      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      doc = Nokogiri::HTML(response.body)
      assert_empty doc.css("[data-cs-flux-config]"),
        "a traced candidate has no generation behind it to reveal"
      assert_empty doc.css("[data-cs-prompt]")
      assert_nil doc.at_css("tr.rowlink[data-cs-view]")["data-cs-flux-config"]
    end
  end

  # --- the download --------------------------------------------------------

  # Minitest 6 dropped minitest/mock, so swap the singleton method and restore.
  # The URLs this job builds are the keys, so a read of the runner's archive and
  # a read of its inverse twin are answered separately.
  def with_runner_files(files)
    original = RunnerClient.method(:get_file)
    RunnerClient.define_singleton_method(:get_file, lambda { |url, **_options|
      if files.key?(url)
        { status: 200, body: files[url], content_type: "application/octet-stream" }
      else
        { status: 404, body: nil, content_type: nil }
      end
    })
    yield
  ensure
    RunnerClient.define_singleton_method(:get_file, original)
  end

  test "a raster-only job downloads a 7z carrying its config, rasters and twin" do
    with_flux_runners do
      sign_in
      write_upload(RASTER, png_bytes)
      write_upload(TWIN, png_bytes)
      write_upload(REFERENCE, png_bytes)
      job = flux_job(mode: "raster", image: REFERENCE, inverse: TWIN)

      get download_job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      assert_equal "application/x-7z-compressed", response.media_type
      assert_includes response.headers["Content-Disposition"].to_s, "generated.7z"

      names, files = unpack_7z(response.body)
      assert_includes names, "flux.json"
      assert_includes names, "generated/#{RASTER}"
      assert_includes names, "inverse.png"
      assert_includes names, "reference.png"
      refute names.any? { |n| n.end_with?("pipeline.7z") },
        "no runner means no runner archive to carry"

      # The bytes really travelled: the bundle's raster is the stored one, to the
      # byte, and the PNG survived the round trip.
      assert_equal png_bytes, files["generated/#{RASTER}"]
      assert_equal "\x89PNG\r\n\x1a\n".b, files["inverse.png"].byteslice(0, 8)
      assert_equal "\x89PNG\r\n\x1a\n".b, files["reference.png"].byteslice(0, 8)

      config = JSON.parse(files["flux.json"])
      assert_equal PROMPT, config.dig("flux", "prompt")
      assert_equal "raster", config.dig("flux", "mode")
      assert_equal REFERENCE, config.dig("flux", "reference")
      assert_equal TWIN, config.dig("flux", "inverse")
      assert_equal "klein-4b", config.dig("flux", "config", "model")
      assert_equal 7, config.dig("flux", "config", "seed")
      assert_equal "sdxl-1.0", config.dig("flux", "request", "model"),
        "the ask as it was stored, beside the facts of what came back"
      assert_equal RASTER, config.dig("flux", "rendered", "images", 0, "file")
      assert_equal job.id, config.dig("job", "id")
      assert_equal "generated", config.dig("job", "stem")
    end
  end

  test "a trace-mode bundle carries the runner's archive inside it" do
    with_flux_runners do
      sign_in
      write_upload(RASTER, png_bytes)
      job = flux_job(mode: "trace", runner_job_id: "rj-1")

      runner_files = {
        job.archive_url => PIPELINE_ARCHIVE,
        job.file_url("source.inverse.png") => png_bytes
      }
      with_runner_files(runner_files) do
        get download_job_path(job), headers: { "User-Agent" => MODERN_UA }
      end
      assert_response :success

      names, files = unpack_7z(response.body)
      assert_includes names, "pipeline.7z"
      assert_equal PIPELINE_ARCHIVE, files["pipeline.7z"],
        "the runner's archive rides along untouched, not re-written by the studio"
      assert_includes names, "generated/#{RASTER}"
      assert_includes names, "inverse.png"
      assert_equal png_bytes, files["inverse.png"], "the runner's own twin is the one bundled"

      config = JSON.parse(files["flux.json"])
      assert_equal "trace", config.dig("flux", "mode")
      assert_nil config.dig("flux", "reference"), "a plain generation has no reference"
    end
  end

  test "a trace-mode bundle without a runner archive is refused, not quietly halved" do
    with_flux_runners do
      sign_in
      job = flux_job(mode: "trace", runner_job_id: "rj-1")

      with_runner_files({}) do
        get download_job_path(job), headers: { "User-Agent" => MODERN_UA }
      end

      assert_response :redirect
      assert_match(/Archive unavailable/, flash[:alert].to_s)
    end
  end

  test "a job that is not finished still cannot be downloaded" do
    with_flux_runners do
      sign_in
      job = flux_job(mode: "raster")
      job.update!(state: "running")

      get download_job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :redirect
      assert_match(/Only completed jobs/, flash[:alert].to_s)
    end
  end
end
