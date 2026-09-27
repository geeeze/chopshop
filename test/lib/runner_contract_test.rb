require "test_helper"

# Pins the studio's runner calls against doc/runner-contract.md (v1). The doc is
# the source of truth for the HTTP shape, so this test READS it and asserts the
# RunnerClient and Job URL builders agree -- if the doc gains, loses or renames
# an endpoint, or a call site changes its verb/path/body keys, this fails.
#
# No runner is contacted: the transport (post/get/get_file/delete) is swapped out
# and the arguments it receives are what we assert on.
class RunnerContractTest < ActiveSupport::TestCase
  ENDPOINTS = {
    "POST /jobs"                  => :create_job,
    "GET /jobs/:id"               => :get_job,
    "GET /jobs/:id/candidates"    => :unused,
    "GET /jobs/:id/archive"       => :archive_url,
    "POST /jobs/:id/cancel"       => :cancel_job,
    "DELETE /jobs/:id"            => :delete_job,
    "GET /files/:job_id/:name"    => :file_url,
    "POST /validations"           => :create_validation,
    "GET /validations/:id"        => :get_validation,
    "POST /validations/:id/jev"   => :ask_jev,
    "GET /health"                 => :health
  }.freeze

  # GET /jobs/:id/candidates is documented but the studio reads the candidate
  # list out of GET /jobs/:id's "comparison" instead, so nothing calls it. Kept
  # explicit here so its absence is a decision, not an accident.
  UNUSED = [ "GET /jobs/:id/candidates" ].freeze

  JobStub = Struct.new(:base_url, :name, :source_kind, :input_path, :spec,
                       :runner_job_id, keyword_init: true)
  ValidationStub = Struct.new(:job, :runner_validation_id, :file,
                              keyword_init: true)

  BASE = "http://127.0.0.1:8790".freeze

  # --- doc parsing ---------------------------------------------------------

  def contract
    @contract ||= begin
      lines = Rails.root.join("doc", "runner-contract.md").read.lines
      lines.each_with_index.with_object({}) do |(line, i), found|
        next unless line =~ /\A#\s+(GET|POST|DELETE)\s+(\/\S+)(?:\s+\(.*\))?\s*\z/
        method, path = $1, $2
        found["#{method} #{path}"] = { method: method, path: path,
                                       params: params_after(lines, i) }
      end
    end
  end

  # The contract writes a body contract as `params: { a, b (note), c }` on the
  # comment line(s) directly under the verb heading.
  def params_after(lines, heading)
    j = heading + 1
    while j < lines.size && lines[j].start_with?("#")
      if lines[j] =~ /params:\s*\{([^}]*)\}/
        return $1.split(",").map { |s| s.strip.split(/\s+/).first }
      end
      break if lines[j] =~ /->/
      j += 1
    end
    nil
  end

  def path_matcher(template)
    body = template.split("/").map do |seg|
      seg.start_with?(":") ? "[^/]+" : Regexp.escape(seg)
    end.join("/")
    Regexp.new("\\A#{body}\\z")
  end

  # --- capture -------------------------------------------------------------

  # Replace the RunnerClient transport for the block; collect what each call
  # site passes. `args.first` is the body for post; for get/delete there is none.
  def with_captured_transport
    calls = []
    originals = {}
    %i[post get get_file delete].each { |m| originals[m] = RunnerClient.method(m) }
    %i[post get get_file delete].each do |m|
      RunnerClient.define_singleton_method(m) do |url, *args, **_kw|
        calls << { transport: m, url: url,
                   body: (args.first if args.first.is_a?(Hash)) }
        {}
      end
    end
    yield calls
  ensure
    originals.each { |m, orig| RunnerClient.define_singleton_method(m, orig) }
  end

  # --- assertions ----------------------------------------------------------

  VERB = { post: "POST", get: "GET", get_file: "GET", delete: "DELETE" }.freeze

  def assert_matches_contract(call, key)
    endpoint = contract.fetch(key)
    assert_equal endpoint[:method], VERB.fetch(call[:transport]),
                 "#{key}: wrong HTTP verb"
    assert_match path_matcher(endpoint[:path]), URI(call[:url]).path,
                 "#{key}: wrong path for #{call[:url]}"
    endpoint
  end

  def assert_body(call, endpoint, expected_keys)
    if endpoint[:params]
      assert_equal endpoint[:params].sort, call[:body].keys.map(&:to_s).sort,
                   "body keys must match the contract's params"
    else
      assert_equal expected_keys.sort, call[:body].keys.map(&:to_s).sort
    end
  end

  def runner_job
    JobStub.new(base_url: BASE, name: "artwork", source_kind: "raster",
                input_path: "/data/a.png", spec: { "print" => {} },
                runner_job_id: "rj1")
  end

  def runner_validation
    ValidationStub.new(job: runner_job, runner_validation_id: "rv1",
                       file: "candidate_01.svg")
  end

  # --- the doc and the map cannot drift ------------------------------------

  test "every documented endpoint is accounted for in the studio" do
    assert_equal ENDPOINTS.keys.sort, contract.keys.sort,
                 "doc/runner-contract.md changed; update ENDPOINTS (and the studio) to match"
  end

  test "the only contract endpoint the studio does not call is declared unused" do
    uncalled = ENDPOINTS.select { |_k, v| v == :unused }.keys.sort
    assert_equal UNUSED.sort, uncalled
  end

  # --- call sites ----------------------------------------------------------

  test "create_job is POST /jobs with the contract's params" do
    with_captured_transport do |calls|
      RunnerClient.create_job(runner_job)
      endpoint = assert_matches_contract(calls.last, "POST /jobs")
      assert_body(calls.last, endpoint, %w[name source_kind input_path spec])
    end
  end

  test "get_job is GET /jobs/:id" do
    with_captured_transport do |calls|
      RunnerClient.get_job(runner_job)
      assert_matches_contract(calls.last, "GET /jobs/:id")
    end
  end

  test "cancel_job is POST /jobs/:id/cancel" do
    with_captured_transport do |calls|
      RunnerClient.cancel_job(runner_job)
      assert_matches_contract(calls.last, "POST /jobs/:id/cancel")
    end
  end

  test "delete_job is DELETE /jobs/:id" do
    with_captured_transport do |calls|
      RunnerClient.delete_job(runner_job)
      assert_matches_contract(calls.last, "DELETE /jobs/:id")
    end
  end

  test "create_validation is POST /validations with job_id and candidate_file" do
    with_captured_transport do |calls|
      RunnerClient.create_validation(job: runner_job, candidate_file: "candidate_01.svg")
      endpoint = assert_matches_contract(calls.last, "POST /validations")
      assert_body(calls.last, endpoint, %w[job_id candidate_file])
    end
  end

  test "get_validation is GET /validations/:id" do
    with_captured_transport do |calls|
      RunnerClient.get_validation(runner_validation)
      assert_matches_contract(calls.last, "GET /validations/:id")
    end
  end

  test "ask_jev is POST /validations/:id/jev carrying the job and candidate" do
    with_captured_transport do |calls|
      RunnerClient.ask_jev(runner_validation)
      endpoint = assert_matches_contract(calls.last, "POST /validations/:id/jev")
      assert_body(calls.last, endpoint, %w[job_id candidate_file])
    end
  end

  test "health is GET /health" do
    with_captured_transport do |calls|
      RunnerClient.health(BASE)
      assert_matches_contract(calls.last, "GET /health")
    end
  end

  # --- URL builders on Job -------------------------------------------------

  test "Job#file_url and #archive_url match the documented file endpoints" do
    job = Job.new(runner: "mock", name: "probe")
    job.runner_job_id = "rj1"

    file_call = { transport: :get_file,
                  url: job.file_url("candidate_01.svg"), body: nil }
    assert_matches_contract(file_call, "GET /files/:job_id/:name")

    archive_call = { transport: :get_file, url: job.archive_url, body: nil }
    assert_matches_contract(archive_call, "GET /jobs/:id/archive")
  end
end
