require "test_helper"

# Starting a FLUX job: generate a raster, then either trace it or stop.
#
# No GPU and no service is contacted. FluxClient.render is swapped out (its own
# wire behaviour is covered in test/lib/flux_client_test.rb) so what is asserted
# here is the ORCHESTRATION, which is the part that cannot be tested anywhere
# else: what the studio asks for, what it stores, which runner the job ends up
# filed against, and what it does when the service refuses.
#
# Generation is ASYNC now: the POST enqueues a RunJob and returns immediately
# with the job queued. Tests that need the generation to have happened wrap the
# POST in perform_enqueued_jobs, which runs the queued job inline.
class FluxJobTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  PNG = "\x89PNG\r\n\x1a\nnot really a png but enough for a byte count".b.freeze

  # Runner-ish variables that are read at the same moment as the registry but are
  # not the registry, so they have to be isolated with it.
  EXTRA_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  # Hermetic on purpose: EVERY runner variable is cleared first, so a test sees
  # exactly what it asked for. The box running the suite has real runners
  # configured, and inheriting them would make these assert the deployment
  # instead of the code -- which is a test that passes for the wrong reason and
  # fails on someone else's machine.
  def with_flux_runners
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    EXTRA_RUNNER_ENV.each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_FLUX_URL"] = "http://generator.invalid:8795"
      ENV["CHOPSHOP_RUNNER_FLUX_KIND"] = "flux"
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

  # Replace the service call and/or the runner call for the duration of a block.
  def stubbing(render: nil, create_job: nil)
    swaps = {}
    swaps[FluxClient] = { render: render } if render
    swaps[RunnerClient] = { create_job: create_job } if create_job
    originals = swaps.to_h { |mod, methods| [mod, methods.keys.to_h { |m| [m, mod.method(m)] }] }
    swaps.each do |mod, methods|
      methods.each { |name, block| mod.define_singleton_method(name) { |*a, **k| block.call(*a, **k) } }
    end
    yield
  ensure
    originals.each { |mod, methods| methods.each { |name, m| mod.define_singleton_method(name, m) } }
  end

  def rendered(name: "20260927T183001Z-klein-4b-s1234567-01.png")
    {
      name: name,
      bytes: PNG,
      content_type: "image/png",
      meta: { "model" => "klein-4b", "license" => "Apache-2.0", "commercial_ok" => true,
              "warnings" => [] }.with_indifferent_access,
      entry: { "name" => name, "bytes" => PNG.bytesize, "seed" => 1_234_567,
               "model" => "klein-4b", "width" => 512, "height" => 512,
               "seconds" => 3.4 }.with_indifferent_access
    }
  end

  def login
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def start_flux(spec:, name: "phoenix")
    login
    post jobs_path, params: { job: { name: name, runner: "flux", source_kind: "raster",
                                     spec: JSON.generate(spec) } },
                    headers: { "User-Agent" => MODERN_UA }
  end

  def cleanup_rasters
    Dir[Rails.root.join("storage", "uploads", "flux_*.png")].each { |f| File.delete(f) }
  end

  # --- the hand-off --------------------------------------------------------

  test "a flux job generates, stores the raster, then hands it to the pipeline runner" do
    asked = []
    handed = []
    with_flux_runners do
      cleanup_rasters
      begin
        stubbing(
          render: ->(base, **kwargs) { asked << [base, kwargs]; rendered },
          create_job: ->(job) { handed << job; { "id" => "runner-123" }.with_indifferent_access }
        ) do
          perform_enqueued_jobs do
            start_flux(spec: { "flux" => { "prompt" => "a woodcut phoenix", "width" => 512,
                                           "height" => 512, "model" => "klein-4b" } })
          end
        end

        assert_response :redirect
        job = Job.last
        assert_equal "running", job.state
        assert_equal "runner-123", job.runner_job_id

        # The generation went to the GENERATOR, with the prompt and the size.
        base, kwargs = asked.first
        assert_equal "http://generator.invalid:8795", base
        assert_equal "a woodcut phoenix", kwargs[:prompt]
        assert_equal "512", kwargs[:width]
        assert_equal "klein-4b", kwargs[:model]
        assert_nil kwargs[:reference], "no reference uploaded means a plain generation"

        # The runner call went to the PIPELINE runner, carrying the raster.
        assert_equal 1, handed.size
        submitted = handed.first
        assert_equal "http://pipeline.invalid:8791", submitted.base_url
        assert_match %r{storage/uploads/flux_[0-9a-f]+\.png\z}, submitted.input_path
        assert File.file?(submitted.input_path), "the raster is on disk where the runner can read it"
        assert_equal PNG, File.binread(submitted.input_path)

        # And the job remembers what was generated, because a raster is not
        # reproducible from the prompt alone.
        assert_equal "svg", job.spec.dig("flux", "handoff")
        assert_equal "a woodcut phoenix", job.flux_prompt
        assert_equal 1_234_567, job.spec.dig("flux", "rendered", "seed")
        assert_equal "Apache-2.0", job.spec.dig("flux", "rendered", "license")
      ensure
        cleanup_rasters
      end
    end
  end

  test "keeping the raster stops the job there, with no runner involved" do
    handed = []
    with_flux_runners do
      cleanup_rasters
      begin
        stubbing(
          render: ->(_base, **_kwargs) { rendered },
          create_job: ->(job) { handed << job; { "id" => "should-not-happen" }.with_indifferent_access }
        ) do
          perform_enqueued_jobs do
            start_flux(spec: { "flux" => { "prompt" => "a phoenix", "mode" => "raster" } })
          end
        end

        assert_response :redirect
        job = Job.last
        assert_equal "done", job.state, "the image IS the deliverable, so the job is finished"
        assert_nil job.runner_job_id, "there is no runner job to poll"
        assert_empty handed, "and no runner was asked to trace anything"
        assert_match %r{flux_[0-9a-f]+\.png\z}, job.input_path
        assert File.file?(job.input_path)
      ensure
        cleanup_rasters
      end
    end
  end

  # --- the inverse twin (no runner, so the studio makes it) ----------------

  # A REAL PNG. The PNG constant above is a byte-count stand-in, and only the
  # twin tests need a decodable image: inverting pixels is the whole point.
  def real_png
    image = ChunkyPNG::Image.new(4, 4, ChunkyPNG::Color.rgb(10, 20, 30))
    image[0, 0] = ChunkyPNG::Color.rgb(0, 0, 0)
    image.to_blob
  end

  def cleanup_twins
    Dir[Rails.root.join("storage", "uploads", "flux_inverse_*.png")].each { |f| File.delete(f) }
  end

  test "a raster-only job's inverse twin is inverted from the raster when it lands" do
    with_flux_runners do
      cleanup_rasters
      cleanup_twins
      begin
        stubbing(render: ->(_base, **_k) { rendered.merge(bytes: real_png) }) do
          perform_enqueued_jobs do
            start_flux(spec: { "flux" => { "prompt" => "a phoenix", "mode" => "raster" } })
          end
        end

        assert_response :redirect
        job = Job.last
        assert_equal "done", job.state

        twin = job.flux_inverse_file
        refute_nil twin, "the twin is recorded with the render facts, where the page reads it"
        assert_match(/\Aflux_inverse_[0-9a-f]+\.png\z/, twin)

        path = Rails.root.join("storage", "uploads", twin)
        assert path.file?, "and it is on disk, in uploads, beside the raster"
        source = ChunkyPNG::Image.from_file(job.input_path)
        out = ChunkyPNG::Image.from_file(path.to_s)
        assert_equal source.pixels.map { |px| px ^ 0xFFFFFF00 }, out.pixels,
          "the twin is the generated raster, inverted channel by channel"
      ensure
        cleanup_rasters
        cleanup_twins
      end
    end
  end

  test "a traced job records no local twin: prep draws that one on the runner" do
    with_flux_runners do
      cleanup_rasters
      cleanup_twins
      begin
        stubbing(
          render: ->(_base, **_k) { rendered.merge(bytes: real_png) },
          create_job: ->(_job) { { "id" => "rj-1" }.with_indifferent_access }
        ) do
          perform_enqueued_jobs do
            start_flux(spec: { "flux" => { "prompt" => "a phoenix" } })
          end
        end

        job = Job.last
        assert_equal "running", job.state
        assert_nil job.flux_inverse_file,
          "a trace-mode twin is source.inverse.png on the runner, not a local file"
        assert_empty Dir[Rails.root.join("storage", "uploads", "flux_inverse_*.png")]
      ensure
        cleanup_rasters
        cleanup_twins
      end
    end
  end

  # --- the batch (swatch / triptych) ---------------------------------------

  test "a batched raster job keeps every variation and records each one" do
    with_flux_runners do
      cleanup_rasters
      begin
        entries = 3.times.map do |i|
          { name: "trip-#{i + 1}.png", bytes: PNG, content_type: "image/png",
            entry: { "name" => "trip-#{i + 1}.png", "seed" => 7, "model" => "klein-4b",
                     "width" => 512, "height" => 512, "seconds" => 3.0 }.with_indifferent_access }
        end
        batch = rendered.merge(entries: entries, name: entries.first[:name],
                               entry: entries.first[:entry])
        seen = nil
        stubbing(render: ->(_base, **kwargs) { seen = kwargs; batch }) do
          perform_enqueued_jobs do
            start_flux(spec: { "flux" => { "prompt" => "a triptych", "mode" => "raster",
                                           "images" => 3, "negative_prompt" => "blurry",
                                           "strength" => "0.55" } })
          end
        end

        assert_response :redirect
        job = Job.last
        assert_equal "done", job.state
        assert_equal "3", seen[:images], "the batched count reaches the client"
        assert_equal "blurry", seen[:negative_prompt]
        assert_equal "0.55", seen[:strength],
          "the spec's strength is handed on: the client types it, so it stays a string here"

        variations = job.flux_variations
        assert_equal 3, variations.size, "a triptych is three variations, not the first"
        assert variations.all? { |v| File.extname(v["file"].to_s) == ".png" },
          "every variation is a stored PNG"
        assert variations.all? { |v| v["file"].to_s.start_with?("flux_") },
          "and a stored upload basename, not a runner path"
        paths = variations.map { |v| Rails.root.join("storage", "uploads", v["file"]) }
        assert paths.all?(&:file?), "all three rasters are on disk"
        assert_equal 3, paths.uniq.size, "three distinct files, not one overwritten"
        assert_equal 7, variations.first["seed"], "each variation keeps its seed for reproducibility"
      ensure
        cleanup_rasters
      end
    end
  end

  # --- what the operator is told -------------------------------------------

  test "a missing prompt is refused here rather than by a round trip to the GPU" do
    asked = []
    with_flux_runners do
      stubbing(render: ->(base, **kwargs) { asked << base; rendered }) do
        start_flux(spec: { "flux" => { "prompt" => "   " } })
      end
      assert_response :unprocessable_entity
      assert_empty asked, "nothing was generated"
    end
  end

  test "the service's refusal is recorded on the job, not swallowed" do
    with_flux_runners do
      stubbing(render: ->(_base, **_k) {
        raise FluxClient::FluxError,
              "flux 403: sdxl-turbo is Stability AI Non-Commercial — loading it requires " \
              "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1"
      }) do
        perform_enqueued_jobs do
          start_flux(spec: { "flux" => { "prompt" => "a phoenix", "model" => "sdxl-turbo" } })
        end
      end

      assert_response :redirect
      job = Job.last
      assert_equal "error", job.state
      assert_match(/Non-Commercial/, job.error,
        "the licence refusal is the one message that has to reach the operator")
    end
  end

  # --- the reference image -------------------------------------------------

  test "a reference image in the spec is resolved inside storage/uploads" do
    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    ref = uploads.join("upload_ref_test.png")
    File.binwrite(ref, PNG)
    seen = []
    with_flux_runners do
      cleanup_rasters
      begin
        stubbing(
          render: ->(_base, **kwargs) { seen << kwargs[:reference]; rendered },
          create_job: ->(_job) { { "id" => "r1" }.with_indifferent_access }
        ) do
          perform_enqueued_jobs do
            start_flux(spec: { "flux" => { "prompt" => "flatten it", "image" => ref.basename.to_s } })
          end
        end
        assert_response :redirect
        assert_match(/\Adata:image\/png;base64,/, seen.first.to_s,
          "the service only accepts a data URL")
      ensure
        cleanup_rasters
        File.delete(ref) if File.exist?(ref)
      end
    end
  end

  test "a reference path that tries to leave storage/uploads is refused" do
    asked = []
    with_flux_runners do
      stubbing(render: ->(base, **kwargs) { asked << base; rendered }) do
        start_flux(spec: { "flux" => { "prompt" => "x", "image" => "../../../../etc/passwd" } })
      end
      assert_response :unprocessable_entity
      assert_empty asked, "the spec is editable text, so a path in it is not trusted"
      assert_match(/not a stored upload/, response.body)
    end
  end

  test "a bad reference reaches an agent as a JSON 422, not a 500" do
    asked = []
    with_flux_runners do
      stubbing(render: ->(base, **kwargs) { asked << base; rendered }) do
        login
        post jobs_path,
             params: { job: { name: "bad-ref", runner: "flux", source_kind: "raster",
                              spec: JSON.generate("flux" => { "prompt" => "x",
                                                              "image" => "../../etc/passwd" }) } },
             headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
      end
      assert_response :unprocessable_entity
      assert_empty asked, "nothing was generated"
      body = JSON.parse(response.body)
      assert_match(/not a stored upload/, body["error"],
                   "an agent gets the reason on the wire, not a MissingTemplate 500")
    end
  end

  test "the reference field accepts a scrapbook drop" do
    login
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    body = response.body
    assert_includes body, "application/x-scrapbook+json",
      "the reference tile must read the scrapbook drag payload"
    assert_includes body, "refDrop", "the drop handler must be wired to the reference field"
    assert_includes body, "/reference", "the drop must POST to the scrapbook reference endpoint"
  end

  # --- nothing else changed ------------------------------------------------

  test "a pipeline job is dispatched through the queue to its runner" do
    flux_asked = []
    handed = []
    with_flux_runners do
      stubbing(
        render: ->(base, **_k) { flux_asked << base; rendered },
        create_job: ->(job) { handed << job; { "id" => "svg-1" }.with_indifferent_access }
      ) do
        perform_enqueued_jobs do
          login
          post jobs_path, params: { job: { name: "art", runner: "svg", source_kind: "raster",
                                           input_path: "/tmp/whatever.png",
                                           spec: JSON.generate(print_method: "screen_print") } },
                          headers: { "User-Agent" => MODERN_UA }
        end
      end
      assert_response :redirect
      assert_empty flux_asked, "no generation for a pipeline job"
      assert_equal "http://pipeline.invalid:8791", handed.first.base_url
      assert_equal "running", Job.last.state
    end
  end

  # --- the page ------------------------------------------------------------

  test "the form opens on a pipeline runner, never on the generator" do
    # A generator sorts before the others in the env, so "first non-mock" would
    # land on it and quietly make every new job a generation.
    with_flux_runners do
      stubbing(render: ->(*_a, **_k) { rendered }) do
        login
        get new_job_path, headers: { "User-Agent" => MODERN_UA }
      end
      assert_response :success
      doc = Nokogiri::HTML(response.body)
      selected = doc.at_css("#job_runner option[selected]")
      refute_nil selected, "a runner must be selected"
      assert_equal "svg", selected["data-kind"],
        "the ordinary job is the pipeline; generating a source is the deliberate choice"
      refute_nil doc.at_css("[data-run-fields='flux'][hidden]"),
        "and the flux panel starts hidden, which is what the kind drives"
    end
  end

  test "the form offers the runners with their kind, so it can show the right fields" do
    with_flux_runners do
      stubbing(render: ->(*_a, **_k) { rendered }) do
        login
        get new_job_path, headers: { "User-Agent" => MODERN_UA }
      end
      assert_response :success
      doc = Nokogiri::HTML(response.body)

      options = doc.css("#job_runner option").map { |o| [o["value"], o["data-kind"]] }
      assert_includes options, ["flux", "flux"]
      assert_includes options, ["svg", "svg"]

      # The halves of the form, each tagged with the kind it belongs to: one
      # panel per Run Job target kind, so what the dropdown selects is what is on
      # screen.
      assert_equal %w[flux plot svg], doc.css("[data-run-fields]").map { |e| e["data-run-fields"] }.sort
      assert_includes doc.css("[data-run-fields='flux']").text, "Prompt"
      assert_nil doc.at_css("[data-run-fields='flux'] #inputPathField"),
        "the artwork upload belongs to the pipeline half"

      # And the deeper settings, off the page but in the document.
      popup = doc.at_css("#flux-settings-popup")
      refute_nil popup
      assert_includes popup.text, "NON-COMMERCIAL"
      # The raster passes the pipeline actually reads.
      %w[pe_filters pe_tune pe_nr pe_filters_presets pe_tune_presets sweep_max sweep_speckle].each do |id|
        refute_nil popup.at_css("##{id}"), "#{id} must exist or the pass cannot be switched on"
      end
    end
  end

  test "the form offers the SD-family models and shows a negative prompt and a strength only for a model that has them" do
    with_flux_runners do
      stubbing(render: ->(*_a, **_k) { rendered }) do
        login
        get new_job_path, headers: { "User-Agent" => MODERN_UA }
      end
      assert_response :success
      doc = Nokogiri::HTML(response.body)

      # The form is the registry, in order: the 9B is gone and the two
      # SD-family checkpoints the service registers are offered here.
      models = doc.css("#flux_model option").map { |o| o["value"] }
      assert_equal FluxConf::MODELS.keys, models
      assert_includes models, "sdxl-1.0"
      assert_includes models, "klein-4b"

      # Both fields exist but start hidden (klein is the default, and it has
      # neither a negative prompt nor an img2img strength).
      refute_nil doc.at_css("#fluxNegPromptField[hidden]"),
        "the negative prompt starts hidden on the default klein"
      refute_nil doc.at_css("#fluxStrengthField[hidden]"),
        "the strength starts hidden on the default klein"

      # And only the SD-family options advertise them, so the JS can reveal the
      # fields for those alone. The SD checkpoints are SD-style, which is both
      # flags at once -- hence one option carrying both, and neither on klein.
      %w[sdxl-1.0 sdxl-turbo sd-1.5].each do |key|
        opt = doc.at_css("#flux_model option[value='#{key}']")
        refute_nil opt, "#{key} must be offered by the form"
        assert_equal "1", opt["data-negprompt"], "#{key} takes a negative prompt"
        assert_equal "1", opt["data-img2img"], "#{key} img2img takes a strength"
      end
      assert_nil doc.at_css("#flux_model option[value='klein-4b']")["data-negprompt"]
      assert_nil doc.at_css("#flux_model option[value='klein-4b']")["data-img2img"]
    end
  end

  test "the job page previews a batch and offers each variation to the scrapbook" do
    with_flux_runners do
      login
      job = Job.create!(name: "triptych", state: "done", source_kind: "raster",
                        runner: "flux", input_path: "/tmp/x.png", stem: "triptych",
                        spec: { "flux" => { "mode" => "raster", "prompt" => "triptych",
                                            "rendered" => { "images" => [
                                              { "file" => "flux_a.png", "seed" => 7 },
                                              { "file" => "flux_b.png", "seed" => 7 },
                                              { "file" => "flux_c.png", "seed" => 7 }
                                            ] } } })
      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success

      doc = Nokogiri::HTML(response.body)
      grid = doc.at_css(".variations-grid")
      refute_nil grid, "a batch job must render the variations grid on the proof page"
      assert_equal 3, grid.css(".variation-tile").size,
        "every variation is a tile, not just the first"

      forms = grid.css(".variation-tile form")
      assert_equal 3, forms.size
      assert_equal scrapbook_save_upload_path, forms.first["action"],
        "each variation saves through the local-upload route, not the runner-fetching favourite"
    end
  end
end
