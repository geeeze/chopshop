require "test_helper"

# The prompt RECALL list -- the other half of the prompt story. The provenance
# half already existed (`spec["prompt_source"]` says which library row a draw
# used, on that one run); this is the operator's own list of what they have
# asked for, offered back on the form.
class JobPromptRecallTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  PNG = "\x89PNG\r\n\x1a\nnot really a png but enough for a byte count".b.freeze

  def login
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = nil
  end

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

  def flux_body(prompt:, **job)
    { job: { name: "recall-probe", runner: "flux", source_kind: "raster",
             project_id: picker_project.id,
             spec: JSON.generate("flux" => { "prompt" => prompt, "width" => 512,
                                             "height" => 512, "model" => "klein-4b",
                                             "mode" => "raster" }) }.merge(job) }
  end

  def file_a_run(prompt:, **extra)
    login
    with_stubbed_runners do
      stubbing(render: ->(_base, **_k) { rendered },
               create_job: ->(_job) { { "id" => "runner-1" }.with_indifferent_access }) do
        perform_enqueued_jobs do
          post jobs_path, params: flux_body(prompt: prompt).merge(extra),
               headers: { "User-Agent" => MODERN_UA }
        end
      end
    end
  ensure
    cleanup_test_uploads(/\Aflux_/)
  end

  # --- recording ------------------------------------------------------------

  test "filing a run remembers its prompt" do
    assert_difference "PromptRecord.count", 1 do
      file_a_run(prompt: "a woodcut phoenix emblem, two inks")
    end

    record = PromptRecord.last
    assert_equal "a woodcut phoenix emblem, two inks", record.prompt
    assert_equal "typed", record.source
    refute_nil record.job_id, "the record says which run used it"
  end

  test "filing the same prompt twice counts it rather than duplicating" do
    file_a_run(prompt: "a lighthouse at dawn")
    assert_difference "PromptRecord.count", 0 do
      file_a_run(prompt: "a lighthouse at dawn")
    end

    assert_equal 2, PromptRecord.last.uses_count
  end

  test "a DRAWN prompt is remembered as a library draw, not as typed" do
    PromptSource.create!(dataset: "diffusiondb", prompt: "a woodcut phoenix emblem")
    file_a_run(prompt: "", prompt_source: "random")

    record = PromptRecord.last
    refute_nil record
    assert_equal "a woodcut phoenix emblem", record.prompt,
      "the prompt remembered must be the one that was DRAWN, not the empty field"
    assert_equal "dataset", record.source
  end

  # The recall list is for prompts that WORKED. A filing the studio refused
  # never reached the service, so offering its prompt back would be offering
  # something that has never once produced anything.
  test "a refused filing remembers nothing" do
    PromptSource.delete_all
    assert_no_difference "PromptRecord.count" do
      file_a_run(prompt: "a woodcut phoenix emblem", prompt_source: "random")
    end
  end

  # --- the popup ------------------------------------------------------------

  test "the form offers the recall popup with the remembered prompts in it" do
    PromptRecord.remember!("a woodcut phoenix emblem, two inks", source: "typed")
    login
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    popup = doc.at_css("#prompts-popup")
    refute_nil popup, "the recall popup must exist"
    assert popup.has_attribute?("hidden"), "and start closed"

    button = doc.at_css("[data-popup='prompts-popup']")
    refute_nil button, "the head needs the button that opens it"

    row = popup.at_css("[data-recall-prompt]")
    refute_nil row, "the remembered prompt must be listed"
    assert_equal "a woodcut phoenix emblem, two inks", row["data-recall-prompt"],
      "the whole prompt is carried, so recalling it fills the field with it"
    assert_match(/woodcut phoenix/, popup.text)
  end

  test "an empty library says so instead of rendering an empty list" do
    login
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    doc = Nokogiri::HTML(response.body)

    refute_nil doc.at_css("#promptsEmpty")
    assert_nil doc.at_css("[data-recall-prompt]")
  end

  # The mashup and the draw had NO door: POST /mashup and POST /datasets/draw
  # were reachable only by hand. Both live behind this popup.
  test "the form ships the mashup popup and its controls" do
    login
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    popup = doc.at_css("#mashup-popup")
    refute_nil popup, "the mashup popup must exist"
    assert popup.has_attribute?("hidden")

    refute_nil doc.at_css("[data-popup='mashup-popup']"), "with a head button"
    %w[mashupSources mashupGoBtn mashupAgainBtn mashupRevertBtn mashupDrawBtn
       mashupPrompt mashupUseBtn].each do |id|
      refute_nil popup.at_css("##{id}"), "##{id} must be wired"
    end
  end

  # The popup posts the prompt into the FLUX panel's field, so the page has to
  # ship it -- a popup whose target is missing fills nothing and looks fine.
  test "the popup's target field is on the page" do
    login
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    doc = Nokogiri::HTML(response.body)

    refute_nil doc.at_css("#flux_prompt"),
      "the recall buttons write #flux_prompt"
  end

  # --- the two things the BROWSER caught that markup assertions could not -----
  #
  # Both of these shipped green through the markup tests above and only failed
  # when the popup was actually driven in a real browser: "the button exists" is
  # not "clicking the button works". The lesson is in the assertions, so they
  # pin the REQUEST SHAPE rather than the presence of a control.

  # `get "datasets/draw"` -- posting to it 404s, and the popup showed exactly
  # that ("Not Found") in the browser.
  test "the draw route is a GET, and the popup's JS calls it that way" do
    assert_nothing_raised do
      route = Rails.application.routes.recognize_path("/datasets/draw", method: :get)
      assert_equal "datasets", route[:controller]
      assert_equal "draw", route[:action]
    end

    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/datasets/draw", method: :post)
    end

    login
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    body = response.body
    assert body.include?("getJson('#{draw_datasets_path}'"),
      "the draw must be fetched with GET -- a POST here is a 404 at runtime"
    refute body.include?("post('#{draw_datasets_path}'"),
      "and it must not be posted: that is the bug this pins"
  end

  # The prompt field lives in the FLUX panel, which showKind() switches. Inside
  # the page's IIFE that function is private, so a popup's call to
  # `window.showKind()` is a silent no-op -- a recalled prompt then fills a field
  # nobody can see, and nothing reports a problem.
  test "showKind is exposed to window so the popups can reveal the flux panel" do
    login
    get new_job_path, headers: { "User-Agent" => MODERN_UA }

    # Anchored to the START of a line, so a COMMENTED-OUT assignment does not
    # satisfy it: `// window.showKind = showKind;` still contains the substring,
    # and a plain include? assertion passed on exactly that when the line was
    # commented out to prove this test could fail.
    assert_match(/^\s*window\.showKind = showKind;/, response.body,
      "the popups need showKind on window, or revealing the flux panel silently does nothing")
  end

  private

  # The runner registry must contain a flux label for the create to validate, and
  # the network must never be reached -- the same isolation FluxJobTest uses.
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
