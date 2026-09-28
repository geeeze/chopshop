require "test_helper"

# Every CsModal that shows a single preview image inherits ONE toolbox:
# favourite, run job again (source/inverse only), a reference split view, a
# hue shift, and save-to-scrapbook. These pin the CONTRACT of that toolbox --
# the ids/data attributes the views and the JS agree on, and the canvas export
# -- the same way ScrapbookEditorToolsTest pins the sidebar editor.
class PreviewPopupToolsTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def js
    Rails.root.join("app/javascript/aether.js").read(encoding: "UTF-8")
  end

  def view(name)
    Rails.root.join("app/views", name).read(encoding: "UTF-8")
  end

  def sign_in
    @original_password = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  teardown do
    ENV["CHOPSHOP_PASSWORD"] = @original_password
  end

  # --- the JS contract ---

  test "every image popup is decorated by the one preview toolbox" do
    # The decorator runs from openCsModal(), so a new image popup inherits it.
    assert_includes js, "csBindPreview(options || {})"
    assert_includes js, "function csBindPreview("
    assert_includes js, 'id="csPreviewTools"'
    # Non-image popups are left alone: no main img means no toolbar.
    assert_includes js, "if (!main) return; // not an image popup"
  end

  test "the favourite button speaks the delegated scrapbook handler" do
    assert_includes js, 'data-scrap-favourite data-scrap-job="" data-scrap-name=""'
    assert_includes js, "function csPreviewApplyInfo("
    # The star is an inline SVG like every other icon, not a glyph.
    assert_match(/csPreviewFav[\s\S]*?<svg/, js)
  end

  test "run job again posts the carried file, never auto-runs" do
    assert_includes js, "function csReusePreview("
    assert_includes js, "form.action = info.reuseUrl;"
    assert_includes js, "['name', info.file]"
  end

  test "the reference selector offers none / source / inverse" do
    assert_includes js, '<option value="">none</option>'
    assert_includes js, '<option value="source">source</option>'
    assert_includes js, '<option value="inverse">inverse</option>'
    assert_includes js, "function csShowReference("
    assert_includes js, "stage.classList.add('cs-split')"
    # Selecting a reference the job does not have is disabled, not broken.
    assert_includes js, "o.disabled = !info.refSource;"
  end

  test "the hue slider applies a view-only hue-rotate to the previewed image" do
    assert_includes js, 'id="csPreviewHue"'
    # CSS filter on the <img>, never a file mutation.
    assert_includes js, "hue-rotate(' + csPreview.hue + 'deg)"
    assert_includes js, "csPreview.main.style.filter = filter;"
  end

  test "save composites what is shown, hue and all, and imports the PNG" do
    assert_includes js, "function csSavePreview("
    assert_includes js, "ctx.filter = 'hue-rotate(' + csPreview.hue + 'deg)'"
    assert_includes js, "ref ? [main, ref] : [main]"
    assert_includes js, "out.toBlob("
    assert_includes js, "fetch('/scrapbook/import'"
  end

  # --- the view contract ---

  test "the sources tiles carry a run-again hand-off and the candidate sweep a reference pair" do
    erb = view("jobs/show.html.erb")
    assert_operator erb.scan("data-cs-reuse-url").length, :>=, 2,
                    "both the source and the inverse preview offer run again"
    assert_includes erb, 'data-cs-job="<%= @job.id %>"'
    assert_includes erb, "data-cs-ref-source"
    assert_includes erb, "data-cs-ref-inverse"
  end

  test "the proof render on the proof page opens in the preview popup" do
    erb = view("validations/show.html.erb")
    assert_includes erb, 'data-cs-view="svg"'
    assert_includes erb, "data-cs-ref-source"
    assert_includes erb, "data-cs-ref-inverse"
  end

  # --- the run-again behaviour ---

  def job_with_spec
    Job.create!(name: "reusable", state: "done", source_kind: "raster",
                input_path: "/data/x.png", stem: "reusable", runner: "mock",
                spec: { "print" => { "dpi" => 321 } })
  end

  # Minitest 6 dropped minitest/mock, so swap the singleton method and restore.
  def with_get_file(body:)
    original = RunnerClient.method(:get_file)
    RunnerClient.define_singleton_method(:get_file, ->(*) {
      { status: 200, body: body, content_type: "image/png" }
    })
    yield
  ensure
    RunnerClient.define_singleton_method(:get_file, original)
  end

  test "run again clones the spec and prefills the new-job form without running" do
    sign_in
    job = job_with_spec
    png = "\x89PNG\r\n\x1a\n".b + ("\x00" * 32)

    with_get_file(body: png) do
      post reuse_job_path(job), params: { name: "source.png" },
                                headers: { "User-Agent" => MODERN_UA }
    end

    assert_response :redirect
    assert_match %r{/jobs/new\?.*input_path=}, response.location
    assert_match(/carried_from=/, response.location)
    assert_match(/name=/, response.location)

    # The form is served with the cloned contract, and nothing was dispatched:
    # a re-run would have posted to the runner, which is not stubbed here.
    follow_redirect!
    assert_response :success
    assert_includes response.body, "321", "the cloned spec prefills the contract"
  end

  test "run again rejects a file that is not the source or its inverse" do
    sign_in
    job = job_with_spec

    post reuse_job_path(job), params: { name: "candidate_01.svg" },
                              headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_redirected_to job
  end
end
