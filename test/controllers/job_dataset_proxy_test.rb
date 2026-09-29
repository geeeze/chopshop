require "test_helper"
require "uri"

# THE DATASET PROXY: the runner builds a proof's training-set 7z on demand and
# this streams it. Modelled on the archive proxy next door, and asserted on the
# same three things — the success path, the failure surface, and the shape of the
# URL the studio builds — plus the one case the archive proxy does not have to
# answer: a job with no runner at all.
class JobDatasetProxyTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  CANDIDATE = "candidate_01.svg".freeze
  SEVEN_Z = "7z\xBC\xAF\x27\x1C not really an archive".b.freeze

  # The URL assertions pin the MOCK runner's loopback default, so the test must
  # be hermetic against a deployment's own runner env (the box running the suite
  # sets CHOPSHOP_RUNNER_MOCK_URL to a container-visible host, which would make
  # "mock" resolve elsewhere and every URL assert drift). Clear the runner slice
  # and reset the memoised registry, restoring both in teardown.
  def setup
    @saved_runner_env = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| @saved_runner_env[key] = ENV.delete(key) }
    Job.reset_runners_cache!
  end

  def teardown
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| ENV.delete(key) }
    @saved_runner_env.each { |key, value| ENV[key] = value }
    Job.reset_runners_cache!
    super
  end

  def sign_in
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def runner_job(runner_job_id: "rj-9")
    Job.create!(name: "traced-art", state: "done", source_kind: "raster",
                runner: "mock", input_path: "/tmp/x.png", stem: "traced-art",
                runner_job_id: runner_job_id)
  end

  def raster_only_job
    Job.create!(name: "just-a-picture", state: "done", source_kind: "raster",
                runner: "mock", input_path: "/tmp/x.png", stem: "just-a-picture",
                runner_job_id: nil)
  end

  # Minitest 6 dropped minitest/mock, so swap the singleton and put it back.
  def with_dataset_package(result)
    seen = []
    original = RunnerClient.method(:dataset_package)
    RunnerClient.define_singleton_method(:dataset_package) do |job, candidate|
      seen << [job, candidate]
      result.is_a?(Proc) ? result.call(job, candidate) : result
    end
    yield seen
  ensure
    RunnerClient.define_singleton_method(:dataset_package, original)
  end

  # --- the URL the studio builds (the runner contract's shape) -------------

  test "the dataset file helper builds the FOUR-segment /files/ path, keyed on the candidate stem" do
    job = runner_job
    url = RunnerClient.dataset_file(job, CANDIDATE, "candidate_01.dataset.json")
    assert_equal "http://127.0.0.1:8790/files/rj-9/candidate_01.dataset/candidate_01.dataset.json", url,
                 "three segments is every other /files/ call; this one is four"

    # The stem is what the manifest names the artifacts after, so the extension
    # comes off — and a path in the candidate cannot escape the directory.
    assert_equal "candidate_01", RunnerClient.dataset_stem("candidate_01.svg")
    assert_equal "candidate_01", RunnerClient.dataset_stem("../../etc/candidate_01.svg")
    assert_equal "candidate_01.dataset",
                 RunnerClient.dataset_stem("candidate_01.dataset.json").then { |s| s.sub(/\.json\z/, "") }
  end

  test "the package helper asks the runner's on-demand route, with the candidate as a query parameter" do
    job = runner_job
    seen = nil
    original = RunnerClient.method(:get_file)
    RunnerClient.define_singleton_method(:get_file) do |url, **_options|
      seen = url
      { status: 200, body: SEVEN_Z, content_type: "application/x-7z-compressed" }
    end
    begin
      RunnerClient.dataset_package(job, CANDIDATE)
    ensure
      RunnerClient.define_singleton_method(:get_file, original)
    end

    parsed = URI(seen)
    assert_equal "/jobs/rj-9/dataset", parsed.path
    assert_equal({ "candidate" => CANDIDATE }, Rack::Utils.parse_nested_query(parsed.query))
  end

  test "the package call takes the long archive timeout, because the runner BUILDS it while we wait" do
    assert_equal RunnerClient::ARCHIVE_READ_TIMEOUT, RunnerClient::DATASET_READ_TIMEOUT,
                 "the dataset is an on-demand build like the archive, so the two must not drift"
    assert_operator RunnerClient::DATASET_READ_TIMEOUT, :>, RunnerClient::TIMEOUT

    job = runner_job
    options = nil
    original = RunnerClient.method(:get_file)
    RunnerClient.define_singleton_method(:get_file) do |_url, **opts|
      options = opts
      { status: 200, body: SEVEN_Z, content_type: "application/x-7z-compressed" }
    end
    begin
      RunnerClient.dataset_package(job, CANDIDATE)
    ensure
      RunnerClient.define_singleton_method(:get_file, original)
    end
    assert_equal RunnerClient::DATASET_READ_TIMEOUT, options[:read_timeout]
  end

  # --- the proxy -----------------------------------------------------------

  test "a running job's dataset streams as an attachment named after the candidate stem" do
    sign_in
    job = runner_job
    with_dataset_package({ status: 200, body: SEVEN_Z, content_type: "application/x-7z-compressed" }) do |seen|
      get dataset_job_path(job, candidate: CANDIDATE), headers: { "User-Agent" => MODERN_UA }
      assert_equal [[job, CANDIDATE]], seen.map { |j, c| [j, c] },
                   "the candidate the operator asked for is the candidate the runner is asked for"
    end

    assert_response :success
    assert_equal "application/x-7z-compressed", response.media_type
    assert_includes response.headers["Content-Disposition"].to_s, "attachment"
    assert_includes response.headers["Content-Disposition"].to_s, "candidate_01.dataset.7z"
    assert_equal SEVEN_Z, response.body.b
  end

  test "a job with no runner 404s with a sentence instead of building a URL out of a nil id" do
    sign_in
    job = raster_only_job
    assert_nil job.runner_job_id

    with_dataset_package(->(_j, _c) { flunk "a job with no runner must not reach the runner at all" }) do
      get dataset_job_path(job, candidate: CANDIDATE), headers: { "User-Agent" => MODERN_UA }
    end

    assert_response :not_found, "a raster-only flux job has no proof, so it has no dataset"
    assert_match(/no dataset/i, flash[:alert].to_s)
    assert_match(/never ran on a runner/i, flash[:alert].to_s)
  end

  test "a runner that refuses the build is reported, not swallowed" do
    sign_in
    job = runner_job
    with_dataset_package({ status: 404, body: nil, content_type: nil }) do
      get dataset_job_path(job, candidate: CANDIDATE), headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :redirect
    assert_match(/Dataset unavailable \(runner 404\)/, flash[:alert].to_s)
  end

  test "an unreachable runner surfaces as the runner's own error, like the archive proxy" do
    sign_in
    job = runner_job
    with_dataset_package(->(_j, _c) { raise RunnerClient::RunnerError, "runner connection failed: dead" }) do
      get dataset_job_path(job, candidate: CANDIDATE), headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :redirect
    assert_match(/Dataset failed: runner connection failed/, flash[:alert].to_s)
  end

  test "a candidate name that is not a plain filename is refused before anything is called" do
    sign_in
    job = runner_job
    with_dataset_package(->(_j, _c) { flunk "an unusable candidate must not reach the runner" }) do
      get dataset_job_path(job, candidate: "../../../etc/passwd"), headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :bad_request
  end

  test "the file proxy reads a dataset file when a candidate is given, and the plain file when it is not" do
    sign_in
    job = runner_job
    seen = []
    original = RunnerClient.method(:get_file)
    RunnerClient.define_singleton_method(:get_file) do |url, **_options|
      seen << url
      { status: 200, body: "PNG", content_type: "image/png" }
    end
    begin
      get file_job_path(job, name: "candidate_01.dataset-contact-sheet.png",
                            candidate: CANDIDATE), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      get file_job_path(job, name: "proof_01.png"), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
    ensure
      RunnerClient.define_singleton_method(:get_file, original)
    end

    assert_equal "http://127.0.0.1:8790/files/rj-9/candidate_01.dataset/candidate_01.dataset-contact-sheet.png",
                 seen[0]
    assert_equal "http://127.0.0.1:8790/files/rj-9/proof_01.png", seen[1],
                 "without a candidate the route is exactly the three-segment one it always was"
  end
end
