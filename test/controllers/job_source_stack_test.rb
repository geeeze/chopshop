require "test_helper"

# THE SOURCE STACK on the job show page: every preview of what the run was made
# FROM and what it MADE beyond its candidates -- the raster pair (and, for an
# img2img edit, the reference that was piped in), a flux job's generated
# variations, and a plot job's drawn SVG -- in ONE vertical column in the
# right-hand Sources section beside the candidates table (or standalone at the
# foot, for a job with no candidates table).
#
# They used to be a 2x2 dock on the title line (`.preview-grid`, now gone) with
# the variations and plot cards ABOVE the candidates table, so the provenance of
# the run was read before the run. Three things this file pins, and each of them
# is a thing a later edit can quietly undo:
#
#   1. LOCATION. The stack renders INSIDE the results split's right-hand column,
#      under the proofs, labelled Sources: -- not a full-width section below the
#      split, and not back in the page head.
#   2. INTEGRITY. Every data-* attribute the preview popup, the viewer and
#      drag-to-favourite depend on travelled with the tiles unchanged, and each
#      favourite is still the shared partial rendered beside its own tile.
#   3. GEOMETRY. The column is vertical and bottom-aligned in CSS, and the wide
#      previews still span it.
class JobSourceStackTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  PROMPT = "a lighthouse at dusk, screenprint, four inks".freeze
  REFERENCE = "stack_reference.png".freeze
  TWIN = "stack_inverse.png".freeze

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

  # Hermetic: every runner variable is cleared first, so a job filed against
  # "flux" is a flux job here and only here.
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

  # A plot runner, hermetic in the same way: a job filed against "plot" is only a
  # plot job while one is configured.
  def with_plot_runner
    saved = {}
    (ENV.keys.grep(/\ACHOPSHOP_RUNNER_/) + %w[CHOPSHOP_FLUX_HANDOFF_RUNNER]).each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_PLOT_URL"] = "http://plot.invalid:8796"
      ENV["CHOPSHOP_RUNNER_PLOT_KIND"] = "plot"
      ENV["CHOPSHOP_RUNNER_SVG_URL"] = "http://pipeline.invalid:8791"
      Job.reset_runners_cache!
      yield
    ensure
      (ENV.keys.grep(/\ACHOPSHOP_RUNNER_/) + %w[CHOPSHOP_FLUX_HANDOFF_RUNNER]).each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def view(name)
    Rails.root.join("app/views", name).read(encoding: "UTF-8")
  end

  def css_without_comments
    Rails.root.join("app/assets/stylesheets/application.css").read(encoding: "UTF-8")
         .gsub(%r{/\*.*?\*/}m, "")
  end

  def data_attrs(node)
    node.attribute_nodes.map(&:name).select { |n| n.start_with?("data-") }.sort
  end

  # --- fixtures ------------------------------------------------------------

  # A traced job with one candidate and its finished proof: the full results
  # split, so the stack has both the table and the aside to sit under.
  def traced_job
    job = Job.create!(name: "stacked", state: "done", source_kind: "raster",
                      input_path: "/data/x.png", stem: "stacked", spec: {}, runner: "mock",
                      comparison: { "candidates" => [
                        { "file" => "candidate_01.svg", "sweep" => { "preset" => "bw" },
                          "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" },
                          "hard" => 0, "advisory" => 0, "fidelity" => {}, "passed" => true }
                      ] })
    job.validations.create!(file: "candidate_01.svg", state: "done",
                            manifest: { "proof" => "proof_01.png" })
    job
  end

  # A flux job, by mode. `images` are the recorded render facts (a batch); an
  # empty array on a raster-only job leaves it with nothing to show at all.
  def flux_job(mode:, images: [], reference: nil, twin: nil, runner_job_id: "rj-1")
    spec = { "flux" => { "mode" => mode, "prompt" => PROMPT, "model" => "sdxl-1.0",
                         "seed" => 99, "rendered" => { "images" => images } } }
    spec["flux"]["image"] = reference if reference
    spec["flux"]["rendered"]["inverse"] = twin if twin
    Job.create!(name: "generated", state: "done", source_kind: "raster", runner: "flux",
                input_path: "", stem: "generated", runner_job_id: runner_job_id, spec: spec)
  end

  # --- 1. where the stack is ----------------------------------------------

  test "the source stack sits in the right-hand column beside the candidates table" do
    sign_in
    get job_path(traced_job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    stack = doc.at_css(".source-stack")
    refute_nil stack, "the job page renders one source stack"
    # An empty stack would satisfy every placement assertion and tell the
    # operator nothing, so pin that it holds the pair.
    assert_equal %w[source.png source.inverse.png],
                 stack.css("a.pv-tile").map { |t| t["data-scrap-name"] }

    # Document order -- the whole point of the change. The candidates table is
    # the floor of the page (left column); the right column carries the proofs
    # and then the sources, so the stack comes after both.
    order = doc.css(".results-main, .results-side, .source-stack").map do |n|
      klass = n["class"].to_s
      if klass.include?("source-stack") then "stack"
      elsif klass.include?("results-side") then "proofs"
      else "candidates"
      end
    end
    assert_equal %w[candidates proofs stack], order,
      "candidates floor first, then the right column (proofs, then sources)"

    # The sources are a section of the right-hand column, not a full-width
    # section below the split.
    side = stack.ancestors(".results-side").first
    refute_nil side, "the sources live inside the right-hand column"
    assert_equal 1, side.css("h3.results-side-head").select { |h| h.text.strip == "Sources:" }.size,
      "the column section is labelled Sources:"
  end

  test "the page head no longer carries any preview" do
    sign_in
    get job_path(traced_job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    head = doc.at_css(".page-head")
    refute_nil head
    assert_empty head.css(".pv-tile"), "the source pair left the title line"
    assert_empty head.css("[data-cs-view]"), "the head carries no previews of any kind"
    assert_equal 1, doc.css(".source-stack").size, "there is exactly one home for them"
  end

  # --- 2. what travelled with the tiles -----------------------------------

  test "every data-* contract on the source tiles survived the move" do
    with_flux_runner do
      sign_in
      job = flux_job(mode: "trace", reference: REFERENCE, twin: TWIN)
      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      stack = Nokogiri::HTML(response.body).at_css(".source-stack")
      refute_nil stack

      # The img2img reference: a local upload, so no runner-fetching favourite
      # and no run-again -- exactly as before the move.
      reference = stack.at_css("a.pv-tile-reference")
      refute_nil reference, "the reference tile is in the stack"
      assert_equal "svg", reference["data-cs-view"]
      assert_equal upload_preview_jobs_path(name: REFERENCE), reference["data-cs-url"]
      assert_equal upload_preview_jobs_path(name: REFERENCE), reference["href"]
      assert_equal REFERENCE, reference["data-cs-title"]
      assert_equal "true", reference["draggable"]
      assert_equal "1", reference["data-cs-fav-off"]
      assert_equal %w[data-cs-fav-off data-cs-job data-cs-name data-cs-title data-cs-url
                      data-cs-view data-scrap-job data-scrap-name], data_attrs(reference)

      # The runner's raster: the reuse hand-off, and the prompt + full config
      # the preview popup reveals.
      source = stack.at_css('a.pv-tile[data-scrap-name="source.png"]')
      refute_nil source, "the runner's own source.png is in the stack"
      assert_equal file_job_path(job, name: "source.png"), source["data-cs-url"]
      assert_equal reuse_job_path(job), source["data-cs-reuse-url"]
      assert_equal PROMPT, source["data-cs-prompt"]
      refute_nil source["data-cs-flux-config"], "the generation config rides with the tile"
      assert_equal %w[data-cs-flux-config data-cs-job data-cs-name data-cs-prompt
                      data-cs-reuse-url data-cs-title data-cs-url data-cs-view
                      data-scrap-job data-scrap-name], data_attrs(source)

      # prep's colour-inverted twin, which the popup offers as the next job's
      # starting point.
      twin = stack.at_css("a.pv-tile-inverse")
      refute_nil twin, "prep's inverse twin is in the stack"
      assert_equal "source.inverse.png", twin["data-cs-name"]
      assert_equal use_inverse_job_path(job), twin["data-cs-use-url"]
      assert_equal reuse_job_path(job), twin["data-cs-reuse-url"]
      assert_equal %w[data-cs-flux-config data-cs-job data-cs-name data-cs-prompt
                      data-cs-reuse-url data-cs-title data-cs-url data-cs-use-url
                      data-cs-view data-scrap-job data-scrap-name], data_attrs(twin)

      # Both runner-held tiles keep the SHARED favourite partial, rendered in
      # the same wrapper as the tile it belongs to.
      assert_equal 2, stack.css("[data-scrap-favourite]").size,
        "each runner-held tile keeps its star"
      assert_equal 2, stack.css(".pv-tile-wrap > .pv-fav").size
      assert_equal [ "source.inverse.png", "source.png" ],
                   stack.css(".pv-tile-wrap .pv-fav").map { |b| b["data-scrap-name"] }.sort,
        "each star still names its own tile"
    end
  end

  test "a raster-only batch shows its tiles and its variations in the one stack" do
    with_flux_runner do
      sign_in
      job = flux_job(mode: "raster", runner_job_id: nil,
                     images: [ { "file" => "stack_a.png", "seed" => 7 },
                               { "file" => "stack_b.png", "seed" => 8 } ])
      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      doc = Nokogiri::HTML(response.body)

      stack = doc.at_css(".source-stack")
      refute_nil stack
      assert_equal 1, doc.css(".variations-grid").size,
        "the batch renders once, inside the stack"
      grid = stack.at_css(".variations-grid")
      refute_nil grid, "the generated variations are in the stack"
      assert_equal 2, grid.css(".variation-tile").size
      assert_equal 2, grid.css(".variation-tile form").size,
        "each variation still saves through scrapbook/save_upload"
      # ...and the generated raster is the stack's source tile.
      assert_equal [ "stack_a.png" ],
                   stack.css("a.pv-tile").map { |t| t["data-scrap-name"] },
        "a raster-only job's deliverable is the source tile, in the same stack"
    end
  end

  test "a plot job's drawn SVG is the last preview in the stack" do
    with_plot_runner do
      sign_in
      job = Job.create!(name: "chart", state: "done", source_kind: "raster", runner: "plot",
                        input_path: "", stem: "chart", owner: "test",
                        spec: { "plot" => { "op" => "generate", "doc" => {},
                                            "rendered" => { "file" => "stack_plot.svg",
                                                            "op" => "generate" } } })
      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      doc = Nokogiri::HTML(response.body)

      stack = doc.at_css(".source-stack")
      refute_nil stack
      refute_nil stack.at_css("a[href='#{upload_preview_jobs_path(name: 'stack_plot.svg')}']"),
        "the deliverable is in the stack, behind the login-gated preview route"
      assert_includes stack.text, "Plot output"
      assert_equal 1, doc.css(".variations-grid").size,
        "one grid, in the stack -- nothing about the plot is left above the results"
    end
  end

  test "a job with nothing to preview renders no stack at all" do
    with_flux_runner do
      sign_in
      # Raster-only with nothing rendered: no raster, no twin, no reference, no
      # variations, no plot. The container is left out rather than rendered empty.
      job = flux_job(mode: "raster", runner_job_id: nil, images: [])
      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      assert_nil Nokogiri::HTML(response.body).at_css(".source-stack"),
        "an empty source stack is not rendered"
    end
  end

  # --- 3. how it is laid out ----------------------------------------------

  test "the stack is a vertical, bottom-aligned flex column" do
    css = css_without_comments
    rule = css[/\.source-stack \{[^}]*\}/m]
    refute_nil rule, ".source-stack is styled"
    assert_match(/display: flex/, rule)
    assert_match(/flex-direction: column/, rule,
      "VERTICAL: the pair is no longer the 2x2 dock it was in the head")
    assert_match(/align-items: flex-end/, rule,
      "BOTTOM-ALIGNED: every preview hangs off the column's end edge, the right " \
      "edge the dock sat on, rather than drifting to the left margin")
    assert_match(/gap: var\(--space-md\)/, rule)
    # The wide previews (a variations grid, the plot card) still span the column:
    # shrunk to their content width they would wrap against that edge. They are
    # CAPPED at 100% as well — a preview must never set the page's width, which is
    # the other half of "the sources do not outgrow the results".
    assert_match(/\.source-stack \{ width: 100%|max-width: 100%/, css)
    card_rule = css[/\.source-stack > \.card \{[^}]*\}/m]
    refute_nil card_rule
    assert_match(/width: 100%/, card_rule, "the wide previews still span the column")
    assert_match(/max-width: 100%/, card_rule, "and never exceed it")
  end

  test "the old 2x2 preview dock is gone from the sheet and the view" do
    refute_match(/\.preview-grid\b/, css_without_comments,
      "the header dock's rule must go with the dock")
    refute_includes view("jobs/show.html.erb"), "preview-grid",
      "and no markup may still reach for it"
  end
end
