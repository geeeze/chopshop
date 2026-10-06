require "test_helper"

# The BP TOURNAMENT template: a simulated single-elimination bracket the studio
# runs ITSELF at filing (jobs#create_tournament_job) — no runner, no queue, no
# dispatch — filed as a done job whose page lists every round step by step and
# links the drawn bracket. This pins: the form contract (template + fieldset),
# both entrant sources, determinism in the seed, the refusals (missing prompt,
# bad source, missing project), the SIMULATED display, and the load-bearing
# rule the whole thing exists under — it decides nothing, exactly as
# /tournament says of the same bracket.
class TournamentJobTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # A bp LABEL must be configured for the job to validate against (runner
  # inclusion), and this test asserts the studio's side only — nothing is ever
  # dispatched. Explicit and hermetic, the same isolation FluxJobTest uses.
  def setup
    @saved_runners = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| @saved_runners[k] = ENV.delete(k) }
    ENV["CHOPSHOP_RUNNER_BP_URL"] = "http://bp.invalid:8793"
    ENV["CHOPSHOP_RUNNER_BP_KIND"] = "bp"
    Job.reset_runners_cache!
  end

  def teardown
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
    @saved_runners.each { |k, v| ENV[k] = v }
    Job.reset_runners_cache!
  end

  def login
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = nil
  end

  def tournament_body(**fields)
    job_fields = fields.delete(:job) || {}
    { job: { name: "bracket-probe", runner: "bp", source_kind: "raster",
             project_id: picker_project.id }.merge(job_fields) }
      .merge(tournament_source: "prompt", tournament_prompt: "a woodcut phoenix")
      .merge(fields)
  end

  # --- the form -------------------------------------------------------------

  test "the Run Job form offers the tournament template and its own fields" do
    login
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    opt = doc.at_css("#job_template option[value='bp_tournament']")
    refute_nil opt, "the BP tournament template is offered"
    assert_equal "bp", opt["data-kind"],
      "kind bp so Apply selects a bp runner — the job lands in the bp family"

    fields = doc.at_css("[data-tournament-fields]")
    refute_nil fields, "the template's own fieldset exists"
    assert fields.has_attribute?("hidden"), "hidden until the template is selected"
    refute_nil doc.at_css("#tournament_source"), "entrant source: prompt or meme seeds"
    refute_nil doc.at_css("#tournament_entrants"), "field size"
    refute_nil doc.at_css("#tournament_prompt"), "the prompt seeds the bracket"
    refute_nil doc.at_css("#tournament_seed"), "an explicit seed may override"
    assert_match(/window\.tournamentOn/, response.body,
      "the submit gate and showKind consult tournament mode")
  end

  # --- filing ---------------------------------------------------------------

  test "a prompt tournament files as a done job, never queued" do
    login
    assert_no_difference -> { Job.unscoped.where(state: "queued").count } do
      assert_difference -> { Job.count }, 1 do
        post jobs_path, params: tournament_body, headers: { "User-Agent" => MODERN_UA }
      end
    end
    assert_response :redirect, flash[:alert].to_s

    job = Job.order(:id).last
    assert_equal "done", job.state, "the sim ran at filing; nothing is dispatched"
    t = job.spec["tournament"]
    assert t["simulated"], "the spec says SIMULATED in its own words"
    assert_equal "prompt", t["source"]
    assert_equal "a woodcut phoenix", t["seed"], "the prompt IS the seed"
    assert_equal "a woodcut phoenix", t["prompt"]
    assert_equal TournamentSim::DEFAULT_ENTRANTS.first(8), t["entrants"],
      "the FIELD is the default entrants, without the meme entrant"
    assert_includes t["outcomes"].map { |o| o["winner"] }.compact.uniq, t["champion"],
      "every road leads to the champion"
    assert_operator t["outcomes"].size, :>, 0, "the step-by-step ledger is populated"
    refute_nil t["champion"]
    assert job.prep_summary.include?("simulated bracket"), "prep_summary says what ran"
    refute_nil job.project_id, "the shared picker rule still applies"
  end

  test "the same prompt runs the same bracket; a different one does not" do
    results = ["a woodcut phoenix", "a woodcut phoenix", "a granite badger"].map do |prompt|
      login
      post jobs_path, params: tournament_body(tournament_prompt: prompt),
           headers: { "User-Agent" => MODERN_UA }
      assert_response :redirect
      Job.order(:id).last.spec["tournament"]
    end
    a, b, c = results
    assert_equal a["outcomes"], b["outcomes"], "deterministic in the seed"
    assert_equal a["champion"], b["champion"]
    refute_equal a["outcomes"], c["outcomes"], "a different seed is a different bracket"
  end

  test "random meme seeds draw unique entrants from the MET-Meme vocabulary" do
    login
    post jobs_path,
         params: tournament_body(tournament_source: "memes", tournament_entrants: "16",
                                 job: { name: "memes", runner: "bp", source_kind: "raster", project_id: picker_project.id }),
         headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect

    t = Job.order(:id).last.spec["tournament"]
    assert_equal "memes", t["source"]
    assert_nil t["prompt"], "no prompt was asked for"
    field = t["entrants"]
    assert_equal 16, field.size, "the requested field size"
    assert_equal field.uniq, field, "names are unique — the sim scores from the NAME"
    pool = MemeVocabulary::FIELDS.filter_map { |_n, s| s["values"] }
                                 .flat_map { |v| v.values.map(&:to_s) }
    field.each { |name| assert_includes pool, name, "every entrant is a vocabulary word" }
    assert_match(/\A[0-9a-f]{16}\z/, t["seed"], "a random seed when none was given")
  end

  # --- refusals -------------------------------------------------------------

  test "a prompt tournament with no prompt is refused with the choice intact" do
    login
    assert_no_difference "Job.count" do
      post jobs_path, params: tournament_body(tournament_prompt: ""),
           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :unprocessable_entity
    assert_match(/needs a prompt/, flash[:alert].to_s)
    refute_nil Nokogiri::HTML(response.body).at_css("[data-tournament-fields]"),
      "the fieldset survives the refusal"
  end

  test "an unknown entrant source is refused" do
    login
    assert_no_difference "Job.count" do
      post jobs_path, params: tournament_body(tournament_source: "vibes"),
           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :unprocessable_entity
    assert_match(/prompt or meme seeds/, flash[:alert].to_s)
  end

  test "the project picker still gates a tournament" do
    login
    assert_no_difference "Job.count" do
      post jobs_path,
           params: { job: { name: "no-project", runner: "bp", source_kind: "raster",
                           project_id: "" },
                     tournament_source: "prompt", tournament_prompt: "x" },
           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :unprocessable_entity
    assert_match(/needs a project/, flash[:alert].to_s)
  end

  # --- the display ----------------------------------------------------------

  test "the job page reads as a step-by-step simulation with a bracket link" do
    login
    post jobs_path, params: tournament_body(tournament_entrants: "8"),
         headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    job = Job.order(:id).last

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    assert doc.at_css(".process-card"), "the round ledger takes the results slot"
    assert_match(/SIMULATED/, response.body)
    t = job.spec["tournament"]
    t["outcomes"].each do |o|
      assert_includes response.body, o["winner"].to_s, "each match's winner is listed"
    end
    link = doc.at_css("a[href*='/tournament?']")
    refute_nil link, "the drawn bracket is one click away"
    assert_includes link["href"], "seed=", "the link carries the seed that ran"
    assert_includes response.body, t["champion"], "the champion is shown, labelled simulated"
  end
end
