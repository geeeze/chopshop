require "test_helper"

# The candidate-triage LEARNING SIGNAL: every human action on the studio's
# triage surfaces is appended to the event log, and the log OUTLIVES the jobs it
# came from (job_id is provenance, not a foreign key). Pins the four events the
# current surfaces emit, the owner scoping that keeps one operator's signal
# private, and the checksum recorded at scrapbook creation.
class EventLogTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def sign_in
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def done_job(name: "signal")
    Job.create!(name: name, state: "done", source_kind: "svg",
                input_path: "/data/#{name}.svg", stem: name, spec: {},
                runner: "mock")
  end

  def job_with_candidate
    job = done_job
    [job, job.candidates.create!(file: "candidate_01.svg")]
  end

  # Minitest 6 dropped minitest/mock, so swap the singleton methods and restore.
  def with_get_file(status: 200, body: "<svg/>")
    original = RunnerClient.method(:get_file)
    RunnerClient.define_singleton_method(:get_file, ->(*) {
      { status: status, body: body, content_type: "image/svg+xml" }
    })
    yield
  ensure
    RunnerClient.define_singleton_method(:get_file, original)
  end

  def with_create_validation(replacement)
    original = RunnerClient.method(:create_validation)
    RunnerClient.define_singleton_method(:create_validation, replacement)
    yield
  ensure
    RunnerClient.define_singleton_method(:create_validation, original)
  end

  # `Event.unscoped` on purpose: a request resets Current, and these assertions
  # are about the ROW existing, not about what the scope would show.
  def events_of(kind)
    Event.unscoped.where(event: kind)
  end

  test "favouriting records a star event" do
    sign_in
    job, candidate = job_with_candidate
    with_get_file(body: "<svg>bytes</svg>") do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :created

    event = events_of("star").order(:id).last
    refute_nil event, "favouriting must append a star event"
    assert_equal job.id, event.job_id
    assert_equal "test", event.owner, "the event carries the operator's handle"
    assert_equal 1, event.pos, "the single candidate is rank 1"
    assert_equal Event::STUDIO_RANKER, event.ranker
    assert_equal "candidate_01.svg", event.payload["name"]
  end

  test "unfavouriting records an unstar event" do
    sign_in
    job, candidate = job_with_candidate
    with_get_file do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
    end
    item = ScrapbookItem.order(:id).last

    delete scrapbook_item_path(item), headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    event = events_of("unstar").order(:id).last
    refute_nil event, "unfavouriting must append an unstar event"
    assert_equal job.id, event.job_id
    assert_equal "candidate_01.svg", event.payload["name"]
  end

  test "trace-it records a pick event" do
    sign_in
    job, candidate = job_with_candidate
    with_get_file do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
    end
    item = ScrapbookItem.order(:id).last

    post use_scrapbook_item_path(item), headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect

    event = events_of("pick").order(:id).last
    refute_nil event, "trace-it must append a pick event"
    assert_equal job.id, event.job_id
    assert_equal 1, event.pos
    assert_equal "scrapbook", event.payload["via"]
  end

  test "running a proof records a pick event" do
    sign_in
    job, candidate = job_with_candidate
    with_create_validation(->(*) { { id: "v-1" } }) do
      post validations_path, params: { job_id: job.id, candidate_file: candidate.file },
                             headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :redirect

    event = events_of("pick").order(:id).last
    refute_nil event, "starting a proof must append a pick event"
    assert_equal job.id, event.job_id
    assert_equal 1, event.pos
    assert_equal "proof", event.payload["via"]
  end

  test "deleting a job records a delete event that survives the deletion" do
    sign_in
    job = done_job(name: "goner")
    job_id = job.id

    delete job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect

    refute Job.unscoped.exists?(id: job_id), "the job itself is gone"
    event = Event.unscoped.find_by(event: "delete", job_id: job_id)
    refute_nil event, "the delete event must OUTLIVE the job it describes"
    assert_equal "goner", event.payload["name"]
    assert_equal "test", event.owner
  end

  test "the event index is login-gated" do
    get events_path
    assert_redirected_to login_path
  end

  test "events are owner-scoped: one operator never sees another's" do
    User.create!(handle: "other", password: "other-password")
    mine = Event.create!(event: "pick", owner: "test", job_id: 1)
    theirs = Event.create!(event: "pick", owner: "other", job_id: 2)

    sign_in
    get events_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    ids = JSON.parse(response.body).map { |e| e["id"] }
    assert_includes ids, mine.id
    refute_includes ids, theirs.id
  end

  test "a failed event write never breaks the primary action" do
    sign_in
    job, candidate = job_with_candidate
    original = Event.method(:create!)
    Event.define_singleton_method(:create!) { |*| raise "log exploded" }
    begin
      with_get_file(body: "<svg>bytes</svg>") do
        post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                             headers: { "User-Agent" => MODERN_UA }
      end
    ensure
      Event.define_singleton_method(:create!, original)
    end

    assert_response :created, "a broken event log must not break favouriting"
    assert ScrapbookItem.order(:id).last.present?, "the favourite itself must still land"
  end

  test "a sha256 is recorded at scrapbook creation" do
    sign_in
    job, candidate = job_with_candidate
    bytes = "<svg>checksum me</svg>"
    with_get_file(body: bytes) do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
    end

    item = ScrapbookItem.order(:id).last
    assert_equal Digest::SHA256.hexdigest(bytes), item.sha256,
                 "the scrapbook row must carry the digest of the bytes it stored"
    # ... and the star event carries the same checksum, so the signal can be
    # keyed by content rather than by a name that dies with the job.
    assert_equal item.sha256, events_of("star").order(:id).last.svg_sha
  end
end
