require "test_helper"

# Every CsModal that shows a single preview image inherits ONE toolbox:
# favourite, prompt/source (flux generations only), run job again (source/
# inverse only), a reference split view, a hue shift overlaid on the art, and
# save-to-scrapbook. These pin the CONTRACT of that toolbox -- the ids/data
# attributes the views and the JS agree on, and the canvas export -- the same
# way ScrapbookEditorToolsTest pins the sidebar editor.
class PreviewPopupToolsTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def js
    Rails.root.join("app/javascript/aether.js").read(encoding: "UTF-8")
  end

  def core_js
    Rails.root.join("app/javascript/aether-core.js").read(encoding: "UTF-8")
  end

  def view(name)
    Rails.root.join("app/views", name).read(encoding: "UTF-8")
  end

  def css
    Rails.root.join("app/assets/stylesheets/application.css").read(encoding: "UTF-8")
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
    # The decorator runs from openCsModal() in core through a hook; the site
    # module wires csBindPreview into that hook, so a new image popup inherits it.
    assert_includes core_js, "if (previewBinder) previewBinder(options || {})"
    assert_includes js, "core.setPreviewBinder(csBindPreview)"
    assert_includes js, "function csBindPreview("
    assert_includes js, 'id="csPreviewTools"'
    # Non-image popups are left alone: no main img means no toolbar.
    assert_includes js, "if (!main) return; // not an image popup"
  end

  # The favourite is ONE component everywhere: the partial. The popup clones it
  # out of the template the layout renders, so there is no second copy of the
  # star or of its data-* contract to drift from the rows and the tiles.
  test "the popup's favourite is a clone of the one shared partial" do
    fav = view("scrapbook/_fav_button.html.erb")
    assert_equal 1, fav.scan("data-scrap-favourite").size, "the partial is the one definition"
    assert_match(/data-scrap-favourite[\s\S]*?<svg/, fav, "the star is an inline SVG, not a glyph")

    layout = view("layouts/application.html.erb")
    assert_includes layout, 'id="csFavTemplate"'
    assert_match(/id="csFavTemplate"[\s\S]*?render "scrapbook\/fav_button"/, layout,
      "the layout renders the SAME partial for the popup to clone")

    # ... and the JS clones it rather than re-writing the button.
    assert_includes js, "function csFavButtonNode("
    assert_includes js, "tpl.content || tpl"
    assert_includes js, "scope.querySelector('[data-scrap-favourite]')"
    assert_includes js, "btn.id = 'csPreviewFav'"
    assert_includes js, "tools.insertBefore(fav, tools.firstChild)"
    # The star polygon lives in the partial only -- a copy in the JS is exactly
    # the duplication this replaced.
    refute_includes js, "15.09 8.26",
      "the star SVG is defined once, in the partial"

    # One handler: the document-level delegation scrapFavourite() rides.
    assert_equal 1, js.scan("closest('[data-scrap-favourite]')").size
    assert_includes js, "scrapFavourite(btn)"
    assert_includes js, "fav.setAttribute('data-scrap-job', info.job)"
  end

  test "the viewer and the drawer share the one escaper" do
    # The drawer's scrapEsc was a byte-identical copy of the viewer's csEsc --
    # the same drift risk as the duplicated favourite. One function now.
    assert_equal 1, js.scan("function csEsc(").size
    refute_includes js, "function scrapEsc("
    assert_includes js, "csEsc(JSON.stringify(it))", "the drawer renders through it"
  end

  test "a tile with no runner file behind it hides the favourite" do
    # A generated raster is saved through scrapbook/save_upload; the
    # runner-fetching star would 502, so the tile opts it out.
    assert_includes js, "var canFav = !!(info.job && info.file) && !info.favOff;"
    assert_includes js, "favOff: options.favOff || ''"
    assert_includes view("jobs/_source_stack.html.erb"), 'data-cs-fav-off="1"'
  end

  # --- the prompt / source reveal (flux generations only) ---

  test "a flux tile's popup offers its prompt and, for img2img, its source" do
    assert_includes js, 'id="csPromptToggle"'
    assert_includes js, 'aria-controls="csPromptPane"'
    assert_includes js, "function csPromptPaneHtml("
    assert_includes js, "function csTogglePrompt("
    assert_includes js, "prompt: el.dataset.csPrompt"
    assert_includes js, "promptSource: el.dataset.csPromptSource"
    # The prompt is inserted as TEXT, never as markup.
    assert_includes js, "csEsc(info.prompt)"
    # A popup opened without a prompt never shows the control: a traced
    # candidate has no prompt behind it.
    assert_includes js, "if (prompt) prompt.hidden = !info.prompt;"
    # The pane is a sibling of the art, so the hue filter and the reference
    # split cannot touch it.
    assert_includes js, "body.insertAdjacentHTML('beforeend', csPromptPaneHtml());"
  end

  test "the prompt pane is hidden markup until the toggle opens it" do
    assert_includes js, 'id="csPromptPane" hidden'
    assert_includes css, ".cs-prompt-pane[hidden] { display: none; }"
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

  # --- the hue slider ---

  test "the hue slider applies a view-only hue-rotate to the previewed image" do
    assert_includes js, 'id="csPreviewHue"'
    # CSS filter on the <img>, never a file mutation.
    assert_includes js, "hue-rotate(' + csPreview.hue + 'deg)"
    assert_includes js, "csPreview.main.style.filter = filter;"
  end

  test "the hue slider is overlaid on the art, with a reset" do
    assert_includes js, "function csHueOverlayHtml("
    assert_includes js, 'id="csHueOverlay"'
    assert_includes js, 'id="csPreviewHueReset"'
    assert_includes js, "function csResetHue("
    # The overlay rides ON the art frame (absolute), not in the toolbar row.
    assert_includes js, "stage.insertAdjacentHTML('beforeend', csHueOverlayHtml());"
    refute_includes js, 'id="csPreviewHueWrap"',
      "the hue control left the toolbar row for the art it transforms"
    assert_includes css, ".cs-modal-art { position: relative; }"
    overlay = css[/\n\.cs-hue-overlay\s*\{(.*?)\n\}/m, 1]
    refute_nil overlay, "the overlay is styled"
    assert_includes overlay, "position: absolute"
    assert_includes overlay, "bottom:"
    # Reset goes through the one writer, so the readout and the filter agree.
    assert_match(/function csResetHue\(\)[\s\S]*?csSetHue\(0\);/, js)
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
    # The source tiles live in their own partial now; the candidate sweep stays
    # inline in show.
    source = view("jobs/_source_stack.html.erb")
    assert_operator source.scan("data-cs-reuse-url").length, :>=, 2,
                    "both the source and the inverse preview offer run again"
    assert_includes source, 'data-cs-job="<%= @job.id %>"'
    erb = view("jobs/show.html.erb")
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
