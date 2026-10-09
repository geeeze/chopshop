require "test_helper"

# The Run Job form's PROMPT SOURCE: "Random from DiffusionDB" draws the run's
# prompt FROM THE DATASETS LIBRARY AT FILING (jobs#apply_prompt_source!) — the
# bridge the library was missing (datasets#use was a one-shot prefill, so the
# corpus only helped someone who visited it first). It rides the flux panel as
# a control (the Draw from dataset TEMPLATE was removed — a draw is a property
# of the generation, not a separate kind of job), and the row actually used is
# recorded in spec["prompt_source"] so a filed run says which prompt it got.
# The draw is server-side and refused with its own reason when the library is
# empty or the run has no generation to draw for.
class JobPromptSourceTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  PNG = "\x89PNG\r\n\x1a\nnot really a png but enough for a byte count".b.freeze

  def login
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = nil
  end

  # Same shape as FluxJobTest's: swap the service + runner calls for the
  # duration, so the draw (the thing under test) is asserted against a create
  # that never touches a network.
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

  def rendered
    name = "20261006T000000Z-klein-4b-s1-01.png"
    { name: name, bytes: PNG, content_type: "image/png",
      meta: { "model" => "klein-4b", "license" => "Apache-2.0", "commercial_ok" => true,
              "warnings" => [] }.with_indifferent_access,
      entry: { "name" => name, "bytes" => PNG.bytesize, "seed" => 1,
               "model" => "klein-4b", "width" => 512, "height" => 512,
               "seconds" => 3.4 }.with_indifferent_access }
  end

  def flux_body(prompt: "", **job)
    { job: { name: "draw-probe", runner: "flux", source_kind: "raster",
             project_id: picker_project.id,
             spec: JSON.generate("flux" => { "prompt" => prompt, "width" => 512,
                                             "height" => 512, "model" => "klein-4b",
                                             "mode" => "raster" }) }.merge(job) }
  end

  # --- the form contract ----------------------------------------------------

  test "the flux panel carries the source control and the template pre-sets it" do
    p = PromptSource.create!(dataset: "diffusiondb", prompt: "a woodcut phoenix emblem")
    login
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    select = doc.at_css("#prompt_source")
    refute_nil select, "the source control exists (generation only: it rides the flux panel)"
    options = select.css("option").map { |o| [o.text.strip, o["value"]] }
    assert_includes options, ["Type a prompt", "literal"]
    assert_includes options, ["Random from DiffusionDB", "random"]

    topic = doc.at_css("#prompt_topic")
    refute_nil topic, "the topic filter is offered with the draw"
    assert topic["hidden"].present?, "hidden until the source says random"
    assert_equal "true", topic["data-prompt-source-topic"],
      "the reveal script's contract attribute"

    dd = doc.at_css("#job_template option[value='dataset_draw']")
    assert_nil dd, "the Draw from dataset template is GONE — the draw is a " \
      "control on the flux panel now, not a template of its own"
    refute_nil p
  end

  # --- the draw -------------------------------------------------------------

  test "filing with the source on random draws the prompt and records provenance" do
    PromptSource.delete_all
    drawn = PromptSource.create!(dataset: "diffusiondb",
                                 prompt: "a very specific drawn prompt",
                                 topic: "dragons")

    login
    cleanup_test_uploads(/\Aflux_/)
    begin
      with_stubbed_runners do
        stubbing(render: ->(_base, **_k) { rendered },
                 create_job: ->(_job) { { "id" => "runner-1" }.with_indifferent_access }) do
          perform_enqueued_jobs do
            post jobs_path,
                 params: flux_body.merge(prompt_source: "random"),
                 headers: { "User-Agent" => MODERN_UA }
          end
        end
      end
      assert_response :redirect
      job = Job.order(:id).last
      assert_equal "a very specific drawn prompt", job.spec.dig("flux", "prompt"),
        "the DRAWN prompt is what the run generates from — the typed one is ignored"
      src = job.spec["prompt_source"]
      refute_nil src, "the run records which row it drew"
      assert_equal drawn.id, src["id"]
      assert_equal "diffusiondb", src["dataset"]
      assert_equal "dragons", src["topic"]
    end
  ensure
    cleanup_test_uploads(/\Aflux_/)
  end

  test "the topic filter is honored" do
    PromptSource.create!(dataset: "diffusiondb", prompt: "a castle in space",
                         topic: "architecture")
    want = PromptSource.create!(dataset: "diffusiondb", prompt: "a worm on the moon",
                                topic: "worms")

    login
    cleanup_test_uploads(/\Aflux_/)
    begin
      with_stubbed_runners do
        stubbing(render: ->(_base, **_k) { rendered },
                 create_job: ->(_job) { { "id" => "runner-1" }.with_indifferent_access }) do
          perform_enqueued_jobs do
            post jobs_path,
                 params: flux_body.merge(prompt_source: "random", prompt_topic: "worms"),
                 headers: { "User-Agent" => MODERN_UA }
          end
        end
      end
      assert_response :redirect
      assert_equal want.id, Job.order(:id).last.spec.dig("prompt_source", "id")
    end
  ensure
    cleanup_test_uploads(/\Aflux_/)
  end

  test "an empty library is refused with its own reason" do
    PromptSource.delete_all
    login
    assert_no_difference "Job.count" do
      post jobs_path, params: flux_body.merge(prompt_source: "random"),
           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :unprocessable_entity
    assert_match(/library is empty/, flash[:alert].to_s)
    refute_nil Nokogiri::HTML(response.body).at_css("#prompt_source"),
      "the source control survives the refusal"
  end

  test "a random source on a run with no generation is refused, not silently dropped" do
    PromptSource.create!(dataset: "diffusiondb", prompt: "a prompt with nowhere to go")
    login
    assert_no_difference "Job.count" do
      post jobs_path,
           params: { job: { name: "no-flux", runner: "mock", source_kind: "raster",
                           input_path: "/data/x.png", project_id: picker_project.id,
                           spec: "{}" },
                     prompt_source: "random" },
           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :unprocessable_entity
    assert_match(/no generation/, flash[:alert].to_s)
  end

  test "the default source changes nothing: typed prompts file as they always did" do
    PromptSource.create!(dataset: "diffusiondb", prompt: "never drawn")
    login
    cleanup_test_uploads(/\Aflux_/)
    begin
      with_stubbed_runners do
        stubbing(render: ->(_base, **_k) { rendered },
                 create_job: ->(_job) { { "id" => "runner-1" }.with_indifferent_access }) do
          perform_enqueued_jobs do
            post jobs_path, params: flux_body(prompt: "typed by hand"),
                 headers: { "User-Agent" => MODERN_UA }
          end
        end
      end
      assert_response :redirect
      job = Job.order(:id).last
      assert_equal "typed by hand", job.spec.dig("flux", "prompt")
      assert_nil job.spec["prompt_source"], "no draw happened, so no provenance is claimed"
    end
  ensure
    cleanup_test_uploads(/\Aflux_/)
  end

  private

  # The runner registry must contain a flux label for the create to validate,
  # and the network must never be reached — same isolation FluxJobTest uses.
  def with_stubbed_runners
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_FLUX_URL"] = "http://generator.invalid:8795"
      ENV["CHOPSHOP_RUNNER_FLUX_KIND"] = "flux"
      ENV["CHOPSHOP_RUNNER_SVG_URL"] = "http://pipeline.invalid:8791"
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end
end
