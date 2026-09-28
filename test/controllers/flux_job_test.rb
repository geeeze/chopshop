require "test_helper"

# Starting a FLUX job: generate a raster, then either trace it or stop.
#
# No GPU and no service is contacted. FluxClient.render is swapped out (its own
# wire behaviour is covered in test/lib/flux_client_test.rb) so what is asserted
# here is the ORCHESTRATION, which is the part that cannot be tested anywhere
# else: what the studio asks for, what it stores, which runner the job ends up
# filed against, and what it does when the service refuses.
class FluxJobTest < ActionDispatch::IntegrationTest
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
          start_flux(spec: { "flux" => { "prompt" => "a woodcut phoenix", "width" => 512,
                                         "height" => 512, "model" => "klein-4b" } })
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
          start_flux(spec: { "flux" => { "prompt" => "a phoenix", "mode" => "raster" } })
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

  test "the service's refusal is shown, not swallowed" do
    with_flux_runners do
      stubbing(render: ->(_base, **_k) {
        raise FluxClient::FluxError,
              "flux 403: klein-9b is FLUX Non-Commercial — loading it requires " \
              "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1"
      }) do
        start_flux(spec: { "flux" => { "prompt" => "a phoenix", "model" => "klein-9b" } })
      end

      assert_response :unprocessable_entity
      assert_match(/Non-Commercial/, response.body,
        "the licence refusal is the one message that has to reach the operator")
      job = Job.last
      assert_equal "error", job.state
      assert_match(/Non-Commercial/, job.error)
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
          start_flux(spec: { "flux" => { "prompt" => "flatten it", "image" => ref.basename.to_s } })
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

  # --- nothing else changed ------------------------------------------------

  test "a pipeline job still goes straight to its runner" do
    flux_asked = []
    handed = []
    with_flux_runners do
      stubbing(
        render: ->(base, **_k) { flux_asked << base; rendered },
        create_job: ->(job) { handed << job; { "id" => "svg-1" }.with_indifferent_access }
      ) do
        login
        post jobs_path, params: { job: { name: "art", runner: "svg", source_kind: "raster",
                                         input_path: "/tmp/whatever.png",
                                         spec: JSON.generate(print_method: "screen_print") } },
                        headers: { "User-Agent" => MODERN_UA }
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

      # The two halves of the form, each tagged with the kind it belongs to.
      assert_equal %w[flux svg], doc.css("[data-run-fields]").map { |e| e["data-run-fields"] }.sort
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
end
