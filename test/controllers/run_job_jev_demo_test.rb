require "test_helper"

# Run Job's TEMPLATE OPTIONS, demonstrated against the question set that
# guides loop/batch decisions over generative creative work.
#
# The claim under test, in one sentence: a contract composed from a Run Job
# template — through the SAME server-side compose path the form's Apply button
# uses — carries the facts the jev side's artifact projector consumes, so a
# batch filed from one template stays adjudicable at n=N and not only at n=1.
#
# The projector is `project_artifact` in chopshop-jev/scripts/jev_annotate.py:
# it reads a generation artifact (top-level `prompt`, plus `settings`,
# `generation`, `measurements`, `image`) and folds the annotator's answers over
# it. Its required input is a non-empty top-level `prompt`; everything else it
# keeps is absent-rather-than-null. The studio's side of that contract is a
# job's spec, and the mapping between the two is pinned in
# test/fixtures/jev_generation_artifact.json — a ONE-WAY transcription of the
# jev source, read and never imported, exactly as meme_vocabulary.json is.
#
# Four legs, one per template the issue names:
#
#   1. generate_only         — the raster IS the deliverable. The composed
#                              contract carries prompt, model, seed, variation
#                              count and both image dimensions: every fact the
#                              projector's `settings` block keeps.
#   2. generate_and_trace    — the same generative half, with the trace levers
#                              beside it; the flux facts survive the trace
#                              levers rather than being cleared by them.
#   3. generate_trace_render — the chain case: the composed contract
#                              carries the step skeleton AND the operator's
#                              first-row facts. merge_deep! merges a row
#                              list element-wise by index (the skeleton row
#                              is the base, the operator's row wins), so
#                              the prompt the projector requires travels
#                              through the compose path in the first row —
#                              the same per-kind block a single-action job
#                              posts, so a chain is adjudicable at Apply.
#   4. bp_tournament         — FINDING, not a fix: the filed spec carries the
#                              bracket's prompt and seed as real facts, but
#                              under `tournament.*`, not the artifact shape's
#                              top-level `prompt` / `settings.*`. A simulated
#                              bracket is not a generative run, and saying so
#                              is the honest demonstration.
#
# Plus the batch case: N filings from ONE template with the levers varied (the
# sweep an automated loop runs), each a distinct composed contract that still
# carries the question-set-relevant fields.
#
# HERMETIC: no service is contacted. Flux filings validate and enqueue against
# the :test queue adapter (RunJob is never performed), and the tournament sim
# runs in-process at filing. Every runner variable is cleared first so the
# suite asserts the code, not this box's deployment.
class RunJobJevDemoTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  FIXTURE_PATH = Rails.root.join("test", "fixtures", "jev_generation_artifact.json")
  JEV_REPO = Rails.root.parent.join("chopshop-jev")
  ANNOTATOR = JEV_REPO.join("scripts", "jev_annotate.py")
  LOOP_DEMO = JEV_REPO.join("tests", "test_loop_demo.py")
  SLOP_CANNON = JEV_REPO.join("scripts", "slop_cannon.py")

  PROMPT = "a flat vector poster of four colour blocks".freeze
  MODEL = "klein-4b".freeze

  # The four templates the issue names. Three are generative; the fourth is
  # the Demo/test group's simulated bracket, demonstrated for what it is.
  GENERATIVE = %w[generate_only generate_and_trace generate_trace_render].freeze

  # The projector-consumed facts a raster contract must carry for the artifact
  # to be projectable at all: the prompt the projector REQUIRES, the model and
  # seed the run is reproducible from, the variation count, and — for a raster
  # output — both image dimensions. `steps`, `guidance` and `sampler` are
  # deliberately NOT here: absent means "the service's own", which the
  # projector keeps as absent rather than null.
  REQUIRED_FACTS = %w[prompt model seed images width height].freeze

  def fixture
    @fixture ||= JSON.parse(FIXTURE_PATH.read)
  end

  # The artifact fact -> studio spec path mapping, from the fixture. This is
  # the mapping under test: it is the only place the two contracts meet.
  def paths
    fixture["studio_contract_paths"]
  end

  def login
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # The compose path the FORM uses: POST /templates/use, which is
  # pages#apply_template -> PipelineConf.compose. Not PipelineConf.compose
  # called directly — the round trip through the controller is what the
  # operator's Apply button actually drives, and the spec the textarea shows
  # is what the panels hydrate from.
  def use_template(template, base: {}, levers: {})
    login
    post "/templates/use",
         params: { template: template, spec: JSON.generate(base), levers: levers },
         headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
    assert_includes [200, 422], response.status,
                    "the compose POST was #{response.status} (#{response.body[0, 200]})"
    body = JSON.parse(response.body)
    refute body["error"], "the compose path refused: #{body['error']}"
    body["spec"]
  end

  # What the operator's panels have typed by the time Apply is hit: the prompt,
  # the model and an explicit seed. writePanels() composes exactly these into
  # the spec, and the compose path preserves them because none of them is a
  # lever path.
  def operator_spec(seed: 4242, prompt: PROMPT, model: MODEL)
    { "flux" => { "prompt" => prompt, "model" => model, "seed" => seed } }
  end

  # Every runner variable cleared, then the two this file needs. Inheriting
  # the box's runners would make these assertions measure the deployment.
  def with_runners(*kinds)
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    kinds.each do |kind|
      ENV["CHOPSHOP_RUNNER_#{kind.upcase}_URL"] = "http://#{kind}.invalid:8795"
      ENV["CHOPSHOP_RUNNER_#{kind.upcase}_KIND"] = kind
    end
    Job.reset_runners_cache!
    yield
  ensure
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
    Job.reset_runners_cache!
  end

  # ---- the fixture is the jev projector's contract, pinned one-way ---------

  def annotator
    @annotator ||= ANNOTATOR.read
  end

  def loop_demo
    @loop_demo ||= LOOP_DEMO.read
  end

  def slop_cannon
    @slop_cannon ||= SLOP_CANNON.read
  end

  # The projector's body, up to the next def. Read, never imported: parsing
  # the text keeps the pin honest about drift and free of the annotator's
  # dependencies, the same rule test/controllers/jeu_help_test.rb follows.
  def project_artifact_body
    annotator[/def project_artifact.*?(?=\ndef )/m] or
      flunk("project_artifact is not where jev_annotate.py is expected to define it")
  end

  test "the fixture is the jev projector's artifact contract, pinned to the jev source" do
    assert ANNOTATOR.exist?, "jeu_annotate.py not found at #{ANNOTATOR}"
    assert LOOP_DEMO.exist?, "test_loop_demo.py not found at #{LOOP_DEMO}"
    assert SLOP_CANNON.exist?, "slop_cannon.py not found at #{SLOP_CANNON}"

    body = project_artifact_body

    # The settings keys the projector keeps, straight out of its own
    # comprehension — a key dropped there is a key the studio can no longer
    # carry, and the fixture has to say so.
    tuples = body.scan(/for key in \(([^)]*)\)/).flatten
                 .map { |t| t.scan(/"([^"]+)"/).flatten }
    assert_operator tuples.size, :>=, 2, "the projector's two key tuples are where the fixture expects"
    assert_equal fixture["settings_keys"], tuples[0],
                 "the settings keys the projector keeps have drifted from the fixture"
    assert_equal fixture["generation_keys"], tuples[1],
                 "the generation keys the projector keeps have drifted from the fixture"

    # The prompt is REQUIRED, not optional: without one the projector raises
    # rather than projecting. The fixture records that as its `required` block.
    assert_match(/'prompt' string/, body,
                 "the projector still refuses an artifact with no prompt")
    assert_equal fixture["required"].keys, %w[prompt]

    # The artifact's top-level shape, as the jev side's own loop demo asserts
    # it — the file that walks this exact shape through the annotator.
    demo_keys = loop_demo[/assert set\(artifact\) == \{([^}]*)\}/, 1]
                   &.scan(/"([^"]+)"/)&.flatten
    assert_equal fixture["top_level_keys"], demo_keys,
                 "the artifact's top-level keys have drifted from the loop demo's own assertion"

    # The measurements: the shipped metric names, from the shipped code. The
    # projector keeps them as a flat dict of scalars, and a run that measured
    # nothing projects an artifact with no measurements rather than a lie.
    measurement_body = slop_cannon[/def measure_raster.*?\n    return \{(.*?)\n    \}/m, 1]
    measured = measurement_body&.scan(/"(slop_[a-z_]+)"/)&.flatten&.uniq
    assert_equal fixture["measurement_keys"], measured,
                 "the measurement key names have drifted from measure_raster's own return"

    # And the profile's declared inputs, so a caller can check a profile
    # against an input without running it.
    declared = annotator[/"artifact": \(([^)]*)\),/, 1]&.scan(/"([^"]+)"/)&.flatten
    assert_equal fixture["profile_inputs_artifact"], declared
  end

  # ---- leg 1: generate_only ------------------------------------------------

  test "generate_only composes a contract carrying every projector-consumed fact" do
    spec = use_template("generate_only", base: operator_spec)

    # The raster IS the deliverable, so the compose path writes the mode that
    # stops the job at the image — the projector is asked about that image.
    assert_equal "raster", spec.dig("flux", "mode")

    assert_projectable(spec, variations: 1)
  end

  # ---- leg 2: generate_and_trace -------------------------------------------

  test "generate_and_trace composes a contract carrying every projector-consumed fact" do
    spec = use_template("generate_and_trace", base: operator_spec)

    # The generative half is unchanged, and the trace levers ride BESIDE it
    # rather than through it: the template's own override (four variations,
    # because the point is choosing which one to trace) survives next to the
    # sweep block the trace half owns.
    assert_projectable(spec, variations: 4)
    assert_equal 6, spec["max_colors"], "the trace half's colour budget"
    assert_equal %w[bw poster photo], spec.dig("print", "sweep", "presets")
  end

  # ---- leg 3: generate_trace_render ----------------------------------------

  test "generate_trace_render's composed chain carries the operator's first-row facts" do
    # What the operator has by the time Apply is hit: a first step row with
    # the generative facts typed into it, exactly as the form's steps UI
    # composes them at submit — every projector-consumed fact legs 1 and 2
    # carry, because a chain's first row is the same per-kind block a
    # single-action job posts.
    base = {
      "steps" => [
        { "kind" => "flux",
          "flux" => { "prompt" => PROMPT, "model" => MODEL, "seed" => 7,
                      "images" => 1, "width" => 512, "height" => 512 } }
      ]
    }
    spec = use_template("generate_trace_render", base: base)

    # The skeleton composes: three steps, in run order, each the per-kind
    # block a single-action job posts.
    assert_equal %w[flux svg bp], spec["steps"].map { |s| s["kind"] }
    assert_equal "raster", spec.dig("steps", 0, "flux", "mode")

    # THE FIX (issue #76): merge_deep! merges a row list element-wise by
    # index — the skeleton row is the base, the operator's row wins — so the
    # compose path ALONE carries every fact the operator typed into the first
    # row. The skeleton fills the fields the row does not name (`mode`,
    # above); the row's own values survive it.
    row = spec.dig("steps", 0, "flux")
    assert_equal PROMPT, row["prompt"],
                 "the projector's required prompt, from the operator's first row"
    assert_equal MODEL, row["model"]
    assert_equal 7, row["seed"]
    assert_equal 1, row["images"]
    assert_equal 512, row["width"]
    assert_equal 512, row["height"]

    # The composed contract is the CHAIN shape, never the artifact shape:
    # compose writes no top-level `prompt` for ANY template (the artifact's
    # top-level prompt is what the flux step writes from this row when the
    # chain runs), and no projector-consumed fact sits at the artifact shape's
    # top-level flux.* paths — for a chain they live in the first step's row,
    # which is what the assertions above read.
    refute spec.key?("prompt"),
           "compose writes the chain shape, never the artifact shape's " \
           "top-level prompt"
    assert_empty paths.each_value.map { |path| spec.dig(*path) }.compact,
                 "a chain's facts live in the first step's row, not at the " \
                 "artifact shape's top-level paths"
  end

  # ---- the row-merge DIRECTION pin -----------------------------------------
  #
  # Review of 278956b found leg 3's skeleton and operator rows name DISJOINT
  # key sets, so the suite could not observe which side wins an overlap —
  # flipping merge_rows to skeleton-wins stayed green. `flux.mode` is the one
  # key both sides name (the skeleton fills it `raster`), so naming it in the
  # operator's row makes the approved direction — the operator's row wins —
  # testable: a flip must fail this test.
  test "the row merge direction is operator-wins at overlapping keys" do
    base = {
      "steps" => [
        { "kind" => "flux",
          "flux" => { "prompt" => PROMPT, "mode" => "img2img", "seed" => 7 } }
      ]
    }
    spec = use_template("generate_trace_render", base: base)
    row = spec.dig("steps", 0, "flux")
    assert_equal "img2img", row["mode"],
                 "the operator's row wins over the skeleton at overlapping keys"
    assert_equal PROMPT, row["prompt"],
                 "the operator's other facts survive the merge"
    assert_equal 6, spec.dig("steps", 1, "svg", "max_colors"),
                 "the skeleton still fills the rows the operator never names"
  end

  # ---- leg 4: bp_tournament (finding) --------------------------------------

  test "bp_tournament files prompt and seed as real facts, outside the projector's artifact shape (finding)" do
    # The compose path: the template's own fragment, and no levers — there is
    # no document to compose and no runner contract to vary.
    composed = use_template("bp_tournament")
    assert_equal({ "simulated" => true }, composed["tournament"])

    with_runners("bp") do
      login
      post jobs_path,
           params: { job: { name: "bracket-demo", runner: "bp", source_kind: "raster",
                            project_id: picker_project.id },
                     tournament_source: "prompt", tournament_prompt: PROMPT },
           headers: { "User-Agent" => MODERN_UA }
      assert_redirected_to job_path(Job.order(:id).last)

      job = Job.order(:id).last
      assert_equal "done", job.state, "the sim ran at filing; nothing was dispatched"

      # The bracket carries its prompt and seed as REAL facts — the prompt IS
      # the seed, so two filings of one prompt are the same bracket.
      t = job.spec["tournament"]
      assert_equal PROMPT, t["prompt"]
      assert_equal PROMPT, t["seed"]
      refute_nil t["champion"]

      # FINDING, pinned rather than fixed: those facts live under
      # `tournament.*`, and the projector reads a TOP-LEVEL `prompt` plus a
      # `settings.*` block. A simulated bracket is not a generative run — it
      # produces no raster and no measurements — so there is nothing here for
      # the artifact projector to project, and the fixture's required top-level
      # prompt is absent by design rather than by accident.
      refute job.spec.key?("prompt"),
             "FINDING: the bracket's prompt is under tournament.prompt, not the " \
             "artifact shape's top-level prompt"
      refute job.spec.key?("settings"),
             "FINDING: the bracket's seed is under tournament.seed, not settings.seed"
    end
  end

  # ---- the batch case ------------------------------------------------------

  test "a batch filed from one template with levers varied stays adjudicable at batch scale" do
    # The sweep an automated loop runs: one template, the levers varied per
    # filing — the variation count, and the size the raster is drawn at. Each
    # filing is a distinct composed contract, and each must still carry the
    # facts the projector consumes, or the batch is n=1 good and n=N broken.
    width_axis = [512, 768, 1024]
    specs = (0...6).map do |i|
      use_template(
        "generate_only",
        base: operator_spec(seed: 4242 + i, prompt: "#{PROMPT} #{i}"),
        levers: { "flux_variations" => (i % 8) + 1,
                  "flux_width" => width_axis[i % 3],
                  "flux_height" => width_axis[i % 3] }
      )
    end

    # N DISTINCT contracts: the sweep varied something real in each.
    assert_equal 6, specs.uniq { |s| JSON.generate(s) }.size,
                 "six filings with varied levers produced six distinct contracts"

    # Every one of them is projectable: the facts travel with the sweep
    # rather than being overwritten by it.
    specs.each_with_index do |spec, i|
      assert_projectable(spec, variations: (i % 8) + 1, width: width_axis[i % 3])
    end

    # And they FILE: the same contracts, through jobs#create, each stored as
    # the composed contract was — complete, distinct, and queued for the
    # generation the projector will later be asked about. Each filing is
    # retired to done so the per-user queue cap is not what is under test.
    with_runners("flux") do
      specs.each_with_index do |spec, i|
        login
        post jobs_path,
             params: { job: { name: "batch-#{i}", runner: "flux", source_kind: "raster",
                              project_id: picker_project.id, spec: JSON.generate(spec) } },
             headers: { "User-Agent" => MODERN_UA }
        assert_redirected_to job_path(Job.order(:id).last),
                             "filing #{i} was refused: #{flash[:alert]}"
        job = Job.order(:id).last
        assert_projectable(job.spec, variations: (i % 8) + 1, width: width_axis[i % 3])
        job.update!(state: "done")
      end
    end
  end

  # ---- the shared assertion ------------------------------------------------

  # Every projector-consumed fact, at the path the fixture says the studio
  # carries it. The message names the artifact side and the studio side of the
  # same fact, so a failure says which half drifted.
  def assert_projectable(spec, variations:, width: 1024)
    p = paths
    scalars = {
      "model" => MODEL,
      "images" => variations,
      "width" => width,
      "height" => width
    }
    scalars.each do |fact, expected|
      actual = spec.dig(*p[fact])
      assert_equal expected, actual,
                   "#{fact}: the projector reads #{fact} from the artifact; the studio " \
                   "carries it at spec.#{p[fact].join('.')} and it is #{actual.inspect}"
    end

    # The seed is compared as a NUMBER without pinning WHICH number: the batch
    # varies it per filing, and what matters is that a seed is carried at all —
    # the projector's settings block keeps it so a run is reproducible.
    assert_kind_of Integer, spec.dig(*p["seed"]),
                    "seed: the projector keeps it in settings; the studio carries it at " \
                    "spec.#{p['seed'].join('.')} and it is #{spec.dig(*p['seed']).inspect}"

    # The prompt is the projector's ONE required input: a non-empty string at
    # the artifact's top level, which the studio carries in the flux block.
    prompt = spec.dig(*p["prompt"])
    assert_kind_of String, prompt,
                    "prompt: the projector raises without one; the studio carries it at " \
                    "spec.#{p['prompt'].join('.')} and it is #{prompt.inspect}"
    refute prompt.strip.empty?, "prompt must be non-empty for the projector to project at all"

    # The levers the projector treats as "the service's own" stay ABSENT rather
    # than null — the projector keeps an absent key absent, and a null would
    # post an explicit "no value" where the runner wants the key missing.
    %w[steps guidance].each do |blank|
      assert_nil spec.dig(*p[blank]),
                 "#{blank}: blank by default, so the contract must not carry it"
    end
  end
end
