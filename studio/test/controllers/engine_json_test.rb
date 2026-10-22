require "test_helper"

# GET /engine.json -- the machine-readable twin of the footer's check-engine
# light (EngineLightTest pins the human view). An agent cannot read a coloured
# dot, so this endpoint must carry the same facts as data: which runners are
# configured and whether each answers, how much recorded signal THIS owner has
# (per kind, not one total), and what the ranker the pipeline trains is shipped
# configured with.
#
# Four contracts are pinned here:
#
#   * the gate -- runner health and event volume are facts about a private
#     deployment, so the endpoint is login-gated like every other authed route;
#   * the counts -- every number is the signed-in owner's, and the totals are
#     EngineMetrics.metrics (the SAME method the footer and the STATUS page read,
#     so the three cannot disagree);
#   * the runner rows -- one per configured label, with a dead box reported as
#     data (`healthy: false` plus the reason) rather than taking the aggregate
#     down;
#   * the ranker summary -- the constants come from Telemetry's own tables, so
#     the JSON cannot re-word a number the STATUS page reports verbatim.
class EngineJsonTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def sign_in
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  # The parsed aggregate, from the route an agent actually calls.
  def engine
    get "/engine.json", headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_equal "application/json", response.media_type
    JSON.parse(response.body)
  end

  def runner(label)
    engine["runners"].find { |row| row["label"] == label }
  end

  # Replace RunnerClient.health for the duration of the block, restoring it
  # afterwards. Same hand-rolled technique as the other controller tests, since
  # Minitest 6 dropped minitest/mock.
  def with_stubbed_health(&block)
    original = RunnerClient.method(:health)
    RunnerClient.define_singleton_method(:health) do |base|
      if base.to_s.include?("unreachable")
        { error: "runner connection failed: Connection refused" }
      else
        { ok: true, host: "probe", mode: "real", tools: { inkscape: true, gs: true, jev: false } }
      end
    end
    block.call
  ensure
    RunnerClient.define_singleton_method(:health, original)
  end

  # The three rows every count assertion builds from: one job with candidates, a
  # scrapbook favourite, and this owner's events.
  def seed_owner_signal
    job = Job.create!(name: "signal", state: "done", source_kind: "svg",
                      input_path: "/data/signal.svg", stem: "signal", spec: {},
                      runner: "mock")
    job.candidates.create!(file: "candidate_01.svg")
    job.candidates.create!(file: "candidate_02.svg")
    ScrapbookItem.create!(name: "candidate_01.svg", kind: "candidate",
                          file: "fav_01.svg", job_id: job.id)
    Event.create!(event: "star", owner: "test", job_id: job.id)
    Event.create!(event: "star", owner: "test", job_id: job.id)
    Event.create!(event: "pick", owner: "test", job_id: job.id)
    job
  end

  # -- the gate ------------------------------------------------------------

  test "an anonymous caller is bounced to login" do
    get "/engine.json", headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path
  end

  test "the controller declares the login gate at the source level" do
    src = Rails.root.join("app/controllers/engine_controller.rb").read
    assert_match(/before_action :require_login/, src)
  end

  # -- the document --------------------------------------------------------

  test "the endpoint answers /engine and /engine.json with one JSON document" do
    sign_in
    get engine_path, headers: { "User-Agent" => MODERN_UA, "Accept" => "text/html" }
    assert_response :success
    assert_equal "application/json", response.media_type,
                 "the aggregate has only one shape, whatever the Accept header says"

    body = engine
    # `layout` is the arrangement half of the signal (alignment, even gaps,
    # frame, balance, coupling over the composites) — the same aggregate
    # /composite/:id/metrics serves per composite, so it is part of the
    # document rather than a second endpoint's business.
    assert_equal %w[cold counts events generated_at host layout ok owner ranker runners use].sort,
                 body.keys.sort
    assert_equal %w[count coupled coupled_share layers links mean_score scores].sort,
                 body["layout"].keys.sort
    assert_equal true, body["ok"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, body["generated_at"])
    assert_equal "test", body["owner"],
                 "the payload says which owner it is scoped to"
  end

  # -- the counts ----------------------------------------------------------

  test "event counts are this owner's, per kind, straight from EngineMetrics" do
    seed_owner_signal
    sign_in
    body = engine

    assert_equal 3, body["events"]["total"], "two stars and one pick"
    assert_equal Event::KINDS.sort, body["events"]["by_kind"].keys.sort,
                 "every kind the log can hold is reported, even at zero"
    assert_equal 2, body["events"]["by_kind"]["star"]
    assert_equal 1, body["events"]["by_kind"]["pick"]
    assert_equal 0, body["events"]["by_kind"]["unstar"]
    assert_equal 0, body["events"]["by_kind"]["delete"]

    assert_equal 1, body["counts"]["jobs"]
    assert_equal 2, body["counts"]["candidates"]
    assert_equal 1, body["counts"]["scrapbook"]
  end

  test "another owner's rows stay invisible, and a bare payload is cold" do
    sign_in
    cold = engine
    assert_equal true, cold["cold"], "no signal yet: the hand order stands"
    assert_equal 0, cold["events"]["total"]
    assert_equal "cold", cold["ranker"]["state"]

    User.create!(handle: "other", password: "other-password")
    theirs = Job.new(name: "theirs", state: "done", source_kind: "svg",
                     input_path: "/data/theirs.svg", stem: "theirs", spec: {},
                     runner: "mock", owner: "other")
    theirs.save!
    theirs.candidates.create!(file: "candidate_01.svg")
    ScrapbookItem.create!(name: "theirs.svg", kind: "source",
                          file: "theirs_fav.svg", owner: "other", job_id: theirs.id)
    Event.create!(event: "pick", owner: "other", job_id: theirs.id)

    body = engine
    assert_equal 0, body["events"]["total"]
    assert_equal 0, body["counts"]["jobs"]
    assert_equal 0, body["counts"]["candidates"]
    assert_equal 0, body["counts"]["scrapbook"]
    assert_equal true, body["cold"], "another operator's signal is not this one's"
  end

  test "the counts are the same numbers the footer's light reads" do
    seed_owner_signal
    sign_in
    get root_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    metrics = EngineMetrics.metrics
    body = engine
    assert_equal metrics[:events], body["events"]["total"]
    assert_equal metrics[:jobs], body["counts"]["jobs"]
    assert_equal metrics[:candidates], body["counts"]["candidates"]
    assert_equal metrics[:scrapbook], body["counts"]["scrapbook"]
    assert_equal EngineMetrics.cold?, body["cold"]
  end

  # -- the two panels the STATUS page gained --------------------------------

  test "the produced tally is EngineMetrics.use, not a second count of the same rows" do
    seed_owner_signal
    sign_in
    body = engine

    assert_equal EngineMetrics.use.stringify_keys, body["use"],
                 "the page's bars and this payload read one method"
    assert_equal %w[composited generated jobs proofs scrapbooked traced], body["use"].keys.sort
    assert_equal 1, body["use"]["jobs"]
    assert_equal 2, body["use"]["traced"]
    assert_equal 1, body["use"]["scrapbooked"]
    assert_equal 0, body["use"]["proofs"], "no proof has been run"
    assert_equal 0, body["use"]["generated"], "no generation job on this fixture"
  end

  test "the host summary reports the newest reading, its timestamp and whether the sampler runs" do
    sign_in
    empty = engine["host"]
    assert_equal false, empty["sampled"], "nothing has ever been sampled"
    assert_equal true, empty["stale"], "and an unsampled box is stale by definition"
    assert_nil empty["values"]

    HostSample.create!(captured_at: Time.current, cpu_pct: 12.0, mem_pct: 41.0,
                       mem_total_mb: 3777, mem_used_mb: 1550, load1: 0.4,
                       swap_total_mb: 1953, swap_used_mb: 350, swap_pct: 17.9)

    host = engine["host"]
    assert_equal true, host["sampled"]
    assert_equal false, host["stale"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, host["sampled_at"])
    assert_equal 12.0, host["values"]["cpu_pct"]
    assert_in_delta 0.4, host["values"]["load1"]
    assert_equal %w[cpu mem swap], host["window"]["series"]
    assert_equal HostSample::WINDOW_SECONDS, host["window"]["window_seconds"]
    assert_equal HostSample::BUCKET_SECONDS, host["window"]["bucket_seconds"]
  end

  test "an unmeasured reading is null in the payload, never a zero" do
    HostSample.create!(captured_at: Time.current, cpu_pct: nil, mem_pct: 30.0,
                       mem_total_mb: 3777, mem_used_mb: 1100, swap_total_mb: 0,
                       swap_pct: nil, load1: nil)
    sign_in
    host = engine["host"]

    assert_nil host["values"]["cpu_pct"], "the first sample has no predecessor to difference"
    assert_nil host["values"]["swap_pct"], "no swap configured: absent, not 0%"
    assert_equal %w[cpu mem], host["window"]["series"], "and so there is no swap series"
  end

  # -- the runners ---------------------------------------------------------

  test "every configured runner is reported with its kind and a health verdict" do
    sign_in
    with_stubbed_health do
      body = engine
      assert_equal Job.runners.keys.sort, body["runners"].map { |r| r["label"] }.sort,
                   "one row per configured runner label"

      body["runners"].each do |row|
        assert_equal %w[error health healthy kind label url].sort, row.keys.sort
        assert_includes Job::RUNNER_KINDS, row["kind"],
                        "#{row['label']} reports the kind the studio dispatches on"
        assert_equal Job.runners[row["label"]], row["url"]
        assert_equal true, row["healthy"], "#{row['label']} answered"
        assert_equal "real", row["health"]["mode"]
        assert_nil row["error"]
      end
    end
  end

  test "a dead runner is data in the payload, not a failure of the payload" do
    original = ENV["CHOPSHOP_RUNNER_DEADPROBE_URL"]
    ENV["CHOPSHOP_RUNNER_DEADPROBE_URL"] = "http://unreachable.invalid:1"
    Job.reset_runners_cache!

    sign_in
    with_stubbed_health do
      body = engine
      assert_equal true, body["ok"], "the aggregate still answers with a runner down"

      dead = body["runners"].find { |row| row["label"] == "deadprobe" }
      refute_nil dead, "the env-added runner appears without a code change"
      assert_equal false, dead["healthy"]
      assert_nil dead["health"]
      assert_match(/Connection refused/, dead["error"])

      alive = body["runners"].reject { |row| row["label"] == "deadprobe" }
      assert alive.all? { |row| row["healthy"] }, "one dead box does not mark the rest dead"
    end
  ensure
    ENV["CHOPSHOP_RUNNER_DEADPROBE_URL"] = original
    Job.reset_runners_cache!
  end

  # -- the ranker ----------------------------------------------------------

  test "the ranker summary reports this owner's progress against the shipped gates" do
    seed_owner_signal
    sign_in
    ranker = engine["ranker"]

    assert_equal "live", ranker["state"], "one recorded event is no longer cold"
    assert_equal 3, ranker["recorded_events"]
    assert_equal 1, ranker["picks"]
    assert_equal 1, ranker["jobs_with_picks"], "one pick, from one job"

    assert_equal 30, ranker["thresholds"]["min_picks"]
    assert_equal 2, ranker["thresholds"]["min_jobs"]
    assert_equal %w[learned_buckets.json learned_ranker.json].sort,
                 ranker["learned_files"].sort
    assert_equal "PIPELINE_LEARNING_DIR", ranker["learning_dir_env"]
  end

  test "a pick that names no job is not counted as a job with a pick" do
    Event.create!(event: "pick", owner: "test")
    Event.create!(event: "pick", owner: "test", job_id: 4242)

    sign_in
    ranker = engine["ranker"]
    assert_equal 2, ranker["picks"],
                 "both picks are counted -- the log is the signal"
    assert_equal 1, ranker["jobs_with_picks"],
                 "only the pick that names a job counts towards the job gate"
  end

  test "the shipped constants come from Telemetry, never a second copy" do
    sign_in
    ranker = engine["ranker"]

    assert_equal Telemetry::CONFIG.map { |g| g[:title] },
                 ranker["shipped"].map { |g| g["title"] },
                 "the groups, in the order the STATUS page shows them"
    assert_equal Telemetry::CONFIG.map { |g| g[:note] },
                 ranker["shipped"].map { |g| g["note"] }

    flat = ranker["shipped"].flat_map { |g| g["entries"] }
    assert_equal Telemetry::CONFIG.sum { |g| g[:entries].size }, flat.size
    refute_includes flat.map { |e| e["body"] }.join, "<",
                    "JSON carries the text, not the page's <mono> markup"
    assert(flat.any? { |e| e["body"].include?("learn_min_picks=30") },
           "the cold-start gate is reported with its shipped value")
    assert(flat.any? { |e| e["body"].include?("never picks a winner") },
           "and the rule the whole ranking stack rests on")

    # The two numbers the aggregate publishes as thresholds are the ones the
    # panel writes in the ranker's own words -- the JSON cannot quietly re-word
    # a constant the page reports verbatim.
    text = Telemetry::RANKER.map { |e| e[:body] }.join(" ")
    assert_includes text, "learn_min_picks=#{ranker['thresholds']['min_picks']}"
    assert_includes text, "learn_min_jobs=#{ranker['thresholds']['min_jobs']}"
  end

  # -- discoverability -----------------------------------------------------

  test "the endpoint is routed and named for the agent that calls it" do
    route = Rails.application.routes.routes.find do |r|
      r.defaults[:controller] == "engine" && r.defaults[:action] == "show"
    end
    refute_nil route, "GET /engine must be routed"
    assert_equal "GET", route.verb
    assert_equal "/engine(.:format)", route.path.spec.to_s
    assert_equal :json, route.defaults[:format],
                 "the aggregate's only shape is JSON"
    # Rails omits a format segment that equals the route's own default, so the
    # generated helper is /engine. The /engine.json address an agent reads in
    # the docs resolves to the same action -- pinned by the two requests below.
    assert_equal "/engine", engine_path
    assert_equal "/engine", engine_path(format: :json),
                 "json IS the route's default, so it is not appended"

    sign_in
    %w[/engine /engine.json].each do |path|
      get path, headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      assert_equal "application/json", response.media_type
      assert_equal 30, JSON.parse(response.body)["ranker"]["thresholds"]["min_picks"],
                   "#{path} carries the ranker summary"
    end

    src = Rails.root.join("app/controllers/engine_controller.rb").read
    assert_includes src, "EngineMetrics.metrics",
                    "the counts come from the footer's own source"
    assert_includes src, "RunnerClient.health",
                    "and liveness is a real probe, not an assumption"
  end
end
