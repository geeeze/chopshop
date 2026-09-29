require "test_helper"

# The Run Job form's COMBINED BP action: one runner target whose operation
# selector covers all six of the blend-plot service's operations.
#
# The form-side half of the merge. What is asserted here is what the operator
# SEES and what the browser composes: the dropdown offers BP (and not the two
# superseded labels), the panel carries the six operations and their document and
# run-record boxes, and the intro says what the panel takes. The BEHAVIOUR behind
# it -- which half answers, what is stored, how a failure is named -- is covered
# in test/jobs/run_bp_test.rb, and the kinds themselves in
# test/models/job_runner_kind_test.rb.
class BpJobFormTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  EXTRA_RUNNER_ENV = %w[CHOPSHOP_FLUX_HANDOFF_RUNNER].freeze

  # Hermetic: every runner variable is cleared first, so the form shows exactly
  # what this test configured rather than this box's real deployment.
  def with_runners(bp: true, legacy: true)
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    EXTRA_RUNNER_ENV.each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_SVG_URL"] = "http://pipeline.invalid:8791"
      if bp
        ENV["CHOPSHOP_RUNNER_BP_URL"] = "http://bp.invalid:8796"
        ENV["CHOPSHOP_RUNNER_BP_KIND"] = "bp"
      end
      if legacy
        ENV["CHOPSHOP_RUNNER_PLOT_URL"] = "http://docs.invalid:8796"
        ENV["CHOPSHOP_RUNNER_PLOT_KIND"] = "plot"
        ENV["CHOPSHOP_RUNNER_BLENDER_URL"] = "http://blend.invalid:8796"
        ENV["CHOPSHOP_RUNNER_BLENDER_KIND"] = "blender"
      end
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      EXTRA_RUNNER_ENV.each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def login
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" },
                      headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def form
    login
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  # --- the dropdown ---------------------------------------------------------

  test "the form offers the combined BP action and not the pair it replaces" do
    with_runners do
      doc = form
      options = doc.css("#job_runner option").map { |o| [o["value"], o["data-kind"]] }

      assert_includes options, ["bp", "bp"],
        "the combined action is a job target, so it must be offered"
      refute_includes options.map(&:first), "plot",
        "the superseded label is not offered: BP carries generate/digest/query"
      refute_includes options.map(&:first), "blender",
        "nor the render: BP carries it as its sixth operation"
    end
  end

  test "a box with a BP runner and no legacy pair still offers it" do
    with_runners(legacy: false) do
      options = form.css("#job_runner option").map { |o| o["value"] }
      assert_includes options, "bp"
      assert_includes options, "svg", "the pipeline runner is unaffected by the merge"
    end
  end

  # --- the panel ------------------------------------------------------------

  test "the panel carries all six operations, in the service's own order" do
    with_runners do
      panel = form.at_css("[data-run-fields='bp']")
      refute_nil panel, "the bp kind must have a panel, or the option is a dead end"
      assert panel["hidden"], "and it starts hidden, like the panels it replaces"

      ops = panel.css("#bp_op option").map { |o| o["value"] }
      assert_equal %w[generate digest query tree log blender], ops,
        "every operation the service serves, in the model's own order"
      assert_equal Job::BP_OPS, ops,
        "and it is the MODEL's list rather than a second copy in the view"
      assert_equal "generate", panel.css("#bp_op option[selected]").first["value"],
        "the list opens on the operation an operator reaches for first"
    end
  end

  test "the panel carries a document box, a run-records box and a summary" do
    with_runners do
      panel = form.at_css("[data-run-fields='bp']")
      refute_nil panel.at_css("#bp_doc"), "the document textarea"
      refute_nil panel.at_css("#bp_runs"), "the run-records textarea"
      refute_nil panel.at_css("#bpSummary"), "and the state line"

      runs_row = panel.at_css("#bpRunsField")
      refute_nil runs_row, "the run-records ROW is what gets gated, not the textarea"
      assert runs_row["hidden"],
        "and it starts hidden: only a query draws across runs"
    end
  end

  test "the intro says what the panel takes, and names both halves" do
    with_runners do
      intro = form.css("[data-run-intro='bp']").text.squeeze(" ")
      assert_includes intro, "Paste", "it must say what the panel takes"
      assert_match(/renders it in 3D/i, intro, "the blend half is named")
      assert_match(/draws it|metrics chart|timeline/i, intro, "and the plot half")
    end
  end

  # --- the six operations are the model's, not the view's -------------------

  test "the op list cannot drift from the service contract the model holds" do
    # A second copy of a rule is a second thing to get wrong. The panel renders
    # Job::BP_OPS, and the service serves the same six -- so the page and the
    # model and the worker all read one list.
    with_runners do
      panel = form.at_css("[data-run-fields='bp']")
      assert_equal Job::BP_OPS.sort, panel.css("#bp_op option").map { |o| o["value"] }.sort

      # And the ops the model accepts ARE the ones the service advertises, which
      # the service itself reports at /health. The five drawing ones plus blender
      # is the whole surface, so a seventh added to the model without the service
      # (or the reverse) is caught here.
      assert_equal %w[blender digest generate log query tree], Job::BP_OPS.sort
    end
  end
end
