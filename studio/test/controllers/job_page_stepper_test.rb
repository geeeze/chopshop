require "test_helper"

# WHERE THIS JOB IS (#46): the stepper on the job page.
#
# The pipeline the About page tells as prose — prep -> sweep -> compare -> you
# pick -> validate — as one strip on the page of the job that is somewhere in
# it, with a state per step, a `you are here` mark, and a help tip per stage.
#
# What is pinned here is the DERIVATION, because that is the part that can
# quietly become a lie: every state below is read from a field the job already
# records (its own state, the comparison, a Validation row, a chain's
# steps_state ledger), and each of the four states the strip shows has a test.
#
# Two shapes matter as much as the states:
#   * a chain lists ITS OWN steps, with the hand-off on the connector between
#     them — not the five pipeline stages;
#   * a flux/bp single-action job is ONE step, because a five-stage strip would
#     describe a process it never enters.
class JobPageStepperTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # The same candidate shape the candidates table and the popup read.
  CANDIDATES = [
    { "file" => "candidate_01.svg", "hard" => 0, "advisory" => 1,
      "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" } },
    { "file" => "candidate_02.svg", "hard" => 2, "advisory" => 0,
      "layer_a" => { "status" => "fail" }, "layer_b" => { "status" => "warn" } }
  ].freeze

  # A pipeline (svg-kind) job, in whatever state the test is about. "mock"
  # resolves to kind svg when no CHOPSHOP_RUNNER_*_KIND overrides it, which is
  # the ordinary pipeline job.
  def pipeline_job(state:, comparison: nil, error: nil)
    Job.create!(name: "stepper-#{state}", state: state, source_kind: "raster",
                input_path: "/uploads/art.png", stem: "stepper",
                runner: "mock", spec: {}, comparison: comparison, error: error)
  end

  def done_pipeline_job
    pipeline_job(state: "done", comparison: { "candidates" => CANDIDATES })
  end

  # Every runner variable is cleared first: the box running this suite has real
  # runners configured, so a test that only ADDS one inherits the deployment.
  def with_runners(vars)
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    begin
      vars.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def with_chain_runners
    with_runners("CHOPSHOP_RUNNER_PIPELINE_URL" => "http://pipeline.invalid:8791",
                 "CHOPSHOP_RUNNER_FLUXBOX_URL" => "http://flux.invalid:8795",
                 "CHOPSHOP_RUNNER_FLUXBOX_KIND" => "flux") { yield }
  end

  def with_flux_runner
    with_runners("CHOPSHOP_RUNNER_FLUXBOX_URL" => "http://flux.invalid:8795",
                 "CHOPSHOP_RUNNER_FLUXBOX_KIND" => "flux") { yield }
  end

  def with_bp_runner
    with_runners("CHOPSHOP_RUNNER_BPBOX_URL" => "http://bp.invalid:8796",
                 "CHOPSHOP_RUNNER_BPBOX_KIND" => "bp") { yield }
  end

  def login!
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def page_for(job)
    login!
    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def strip(doc)
    doc.at_css(".job-stepper")
  end

  def steps(doc)
    strip(doc).css(".step")
  end

  def states(doc)
    steps(doc).to_h { |step| [step["data-stage"], step["data-state"]] }
  end

  def current_stage(doc)
    step = strip(doc).at_css(".step-current")
    step && step["data-stage"]
  end

  def caption(doc)
    strip(doc).at_css(".process-count").text.strip
  end

  # ---------------------------------------------------------------- pending

  test "a queued pipeline job is five pending stages with no mark" do
    doc = page_for(pipeline_job(state: "queued"))
    assert_equal "pipeline", strip(doc)["data-stepper"]

    assert_equal %w[prep sweep compare pick validate], steps(doc).map { |s| s["data-stage"] },
                 "the five stages of the pipeline the About page tells as prose, in order"
    assert_equal %w[pending pending pending pending pending], steps(doc).map { |s| s["data-state"] }
    assert_nil current_stage(doc), "a queued job is nowhere yet, so nothing is marked"
    assert_empty strip(doc).css(".step-here"), "and it does not claim to be anywhere"
    assert_equal "not started", caption(doc)
  end

  # ---------------------------------------------------------------- running

  test "a running pipeline job marks prep and shares the run's state across the three" do
    job = pipeline_job(state: "running")
    doc = page_for(job)

    # The runner reports ONE running state for prep+sweep+compare, so the strip
    # says exactly that rather than inventing a ladder inside the call.
    assert_equal({ "prep" => "running", "sweep" => "running", "compare" => "running",
                   "pick" => "pending", "validate" => "pending" }, states(doc))

    assert_equal "prep", current_stage(doc), "exactly one stage carries the mark"
    assert_equal 1, strip(doc).css(".step-current").size
    assert_equal 1, strip(doc).css(".step-here").size
    assert_equal "you are here", strip(doc).at_css(".step-here").text.strip
    assert_equal "you are here: prep", caption(doc)
  end

  # ------------------------------------------------------------------- done

  test "a finished run with no pick is done through compare and marks the pick" do
    doc = page_for(done_pipeline_job)

    assert_equal({ "prep" => "done", "sweep" => "done", "compare" => "done",
                   "pick" => "running", "validate" => "pending" }, states(doc))
    assert_equal "pick", current_stage(doc),
                 "a finished run waiting on the operator is AT the pick"
    assert_equal "you are here: pick", caption(doc)
  end

  test "a pick whose proof is in flight is done, and the proof is the current stage" do
    job = done_pipeline_job
    job.validations.create!(file: "candidate_01.svg", state: "running")

    doc = page_for(job)
    assert_equal({ "prep" => "done", "sweep" => "done", "compare" => "done",
                   "pick" => "done", "validate" => "running" }, states(doc))
    assert_equal "validate", current_stage(doc)
  end

  test "a finished proof reads done across all five, with no mark left" do
    job = done_pipeline_job
    job.validations.create!(file: "candidate_01.svg", state: "done",
                            manifest: { "proof" => "proof.png" })

    doc = page_for(job)
    assert_equal %w[done done done done done], steps(doc).map { |s| s["data-state"] }
    assert_nil current_stage(doc)
    assert_equal "done", caption(doc)
  end

  # ----------------------------------------------------------------- failed

  test "a failed run reads failed across the three it never finished" do
    doc = page_for(pipeline_job(state: "error", error: "runner died mid-sweep"))

    assert_equal({ "prep" => "failed", "sweep" => "failed", "compare" => "failed",
                   "pick" => "pending", "validate" => "pending" }, states(doc))
    assert_nil current_stage(doc), "a failed stage is not where the job is going"
    assert_equal "failed", caption(doc)
    assert_match(/runner died mid-sweep/, doc.at_css(".flash.alert").text,
                 "the strip does not replace the reason, which is the page's own alert")
  end

  test "a proof that errored reads failed on validate, and the run stays done" do
    job = done_pipeline_job
    job.validations.create!(file: "candidate_01.svg", state: "error", error: "gates refused")

    doc = page_for(job)
    assert_equal({ "prep" => "done", "sweep" => "done", "compare" => "done",
                   "pick" => "done", "validate" => "failed" }, states(doc))
    assert_equal "failed", caption(doc)
  end

  # ----------------------------------------------------------------- chain

  test "a chain lists its own steps, in order, with the hand-off on the connector" do
    with_chain_runners do
      job = Job.create!(name: "chain-stepper", state: "running", source_kind: "raster",
                        runner: "fluxbox", input_path: "/uploads/art.png",
                        spec: { "steps" => [
                          { "runner" => "fluxbox",
                            "flux" => { "prompt" => "a phoenix", "mode" => "raster" } },
                          { "runner" => "pipeline", "input" => "previous",
                            "svg" => { "sweep" => { "preset" => "bw" } } }
                        ] },
                        steps_state: {
                          "current" => 2, "total" => 2, "state" => "running",
                          "steps" => [{ "index" => 1, "runner" => "fluxbox", "state" => "done",
                                        "file" => "step_01.png", "runner_job_id" => "r1" }]
                        })
      doc = page_for(job)

      assert_equal "chain", strip(doc)["data-stepper"]
      assert_equal %w[step-1 step-2], steps(doc).map { |s| s["data-stage"] },
                   "a chain's strip is its declared steps, not the five stages"
      assert_equal %w[flux svg], steps(doc).map { |s| s.at_css(".step-label").text.strip },
                   "each step is named by the operation it runs"
      assert_equal %w[done running], steps(doc).map { |s| s["data-state"] },
                   "each step's state is its own ledger entry"
      assert_equal "step-2", current_stage(doc)

      links = strip(doc).css(".step-link")
      assert_equal 1, links.size, "one connector between two steps"
      assert_equal "previous", links.first["data-handoff"],
                   "the hand-off is on the connector that carries it"
      assert_includes links.first["class"].split, "step-link-handoff"
      assert_match(/handed the file/, links.first["title"])

      # The chain's table is still there: the strip leads, it does not replace.
      refute_nil doc.at_css(".process-card"), "the chain's process table still renders"
    end
  end

  # ---------------------------------------------------------- single action

  test "a flux job is one step, not five" do
    with_flux_runner do
      job = Job.create!(name: "flux-stepper", state: "done", source_kind: "raster",
                        runner: "fluxbox", input_path: "/uploads/art.png",
                        spec: { "flux" => { "prompt" => "a phoenix", "mode" => "raster" } })
      doc = page_for(job)

      assert_equal "single", strip(doc)["data-stepper"]
      assert_equal 1, steps(doc).size, "one action is one step"
      assert_equal "generate", steps(doc).first.at_css(".step-label").text.strip,
                   "named for what it does, not for a stage of a pipeline"
      assert_equal "done", steps(doc).first["data-state"]
      assert_equal %w[prep sweep compare pick validate], ApplicationHelper::PIPELINE_STAGES,
                   "the five stages exist, and this job is not one of them"
      refute_includes steps(doc).map { |s| s["data-stage"] }, "prep"
    end
  end

  test "a bp job is one step, named for the operation it records" do
    with_bp_runner do
      job = Job.create!(name: "bp-stepper", state: "error", error: "bp refused the document",
                        source_kind: "svg", runner: "bpbox", input_path: "/uploads/art.svg",
                        spec: { "bp" => { "op" => "generate",
                                          "doc" => { "elements" => [{ "type" => "rect" }] } } })
      doc = page_for(job)

      assert_equal 1, steps(doc).size
      assert_equal "generate", steps(doc).first.at_css(".step-label").text.strip
      assert_equal "failed", steps(doc).first["data-state"],
                   "a single action's state IS the job's state"
    end
  end

  # -------------------------------------------------------------- help tips

  test "each pipeline stage carries its own help tip, on the app's standard popup" do
    doc = page_for(done_pipeline_job)
    strip = strip(doc)

    buttons = strip.css("button.help-tip-btn")
    assert_equal 5, buttons.size, "one `?` per stage, and only on the stages"

    ids = buttons.map { |b| b["data-popup"] }
    assert_equal ids.uniq, ids, "five distinct popups -- a duplicate id is invalid HTML"

    buttons.each do |button|
      popup = doc.at_css("##{button['data-popup']}")
      refute_nil popup, "#{button['data-popup']} exists"
      assert_includes popup["class"].split, "popup"
      assert_equal 1, popup.css("[data-popup-close]").size,
                   "exactly one close, the app's standard"
      assert_equal 1, popup.css(".popup-head [data-popup-close]").size,
                   "the x lives in the popup's head"
      assert popup.at_css(".popup-body .help-tip-detail").text.present?,
             "the tip says something"
    end

    # And the five keys are the registry's, not invented in the view.
    keys = buttons.map { |b| b["data-popup"].sub(/\Ahelp-tip-/, "").tr("-", ".") }
    assert_equal %w[jobstep.prep jobstep.sweep jobstep.compare jobstep.pick jobstep.validate],
                 keys, "the stage names ARE the registry keys"
  end

  test "a chain and a single action carry one tip for the strip, not one per step" do
    with_flux_runner do
      job = Job.create!(name: "flux-tip", state: "queued", source_kind: "raster",
                        runner: "fluxbox", input_path: "/uploads/art.png",
                        spec: { "flux" => { "prompt" => "a phoenix", "mode" => "raster" } })
      doc = page_for(job)
      buttons = strip(doc).css("button.help-tip-btn")
      assert_equal 1, buttons.size
      assert_equal "help-tip-jobstep-single", buttons.first["data-popup"]
    end
  end

  # ------------------------------------------------------- the one-line rule

  test "the strip is one row at every width, and labelled dots on a phone" do
    css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))

    strip_rule = css[/\n\.stepper \{(.*?)\n\}/m, 1]
    refute_nil strip_rule, "the strip has its own rule"
    assert_match(/flex-wrap:\s*nowrap/, strip_rule,
                 "nowrap at every width -- it must never become two rows")
    assert_match(/\.step \{[^}]*min-width:\s*0/m, css,
                 "min-width:0 on a step, so a long label shrinks instead of pushing the row wide")

    phone = css.scan(/@media \(max-width: 860px\) \{(.*?)\n\}/m).flatten.join("\n")
    assert_match(/\.stepper \.step-state,\s*\n\s*\.stepper \.step-here \{ display: none; \}/,
                 phone, "on a phone the state word and the caption drop out, leaving the dots")
  end

  # A template that leaks its own syntax still returns 200 and still parses; the
  # only place it shows is the rendered text.
  test "the strip renders no template scaffolding" do
    doc = page_for(done_pipeline_job)
    text = strip(doc).text
    refute_match(/<%|%>/, text)
    refute_match(/jobstep\./, text, "the registry keys stay in data attributes, not on screen")
  end
end
