require "test_helper"

# Pins the studio's runner calls against docs/runner-contract.md (v1). The doc is
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
    "GET /jobs/:id/dataset"       => :dataset_package,
    "POST /jobs/:id/cancel"       => :cancel_job,
    "DELETE /jobs/:id"            => :delete_job,
    "GET /files/:job_id/:name"    => :file_url,
    "GET /files/:job_id/<stem>.dataset/<name>" => :dataset_file,
    "POST /validations"           => :create_validation,
    "GET /validations/:id"        => :get_validation,
    "POST /validations/:id/jev"   => :ask_jev,
    "POST /recolour"              => :unused,
    "POST /recolour/colours"      => :unused,
    "POST /compose"               => :compose,
    "GET /health"                 => :health
  }.freeze

  # GET /jobs/:id/candidates is documented but the studio reads the candidate
  # list out of GET /jobs/:id's "comparison" instead, so nothing calls it. Kept
  # explicit here so its absence is a decision, not an accident. The recolour
  # pair is the seam for the colour-cycling control, which has no studio call
  # site yet -- documented in the contract, marked unused until it does.
  #
  # /compose is NOT in that list even though it is not a RunnerClient method:
  # it is called by ComposeClient (CompositesController#flatten's vector path),
  # which is a real call site, so the route is covered here rather than omitted.
  # A route the app really posts to must not fall outside this map: omitting it
  # is exactly how the studio's own contract doc drifted from its calls.
  UNUSED = [ "GET /jobs/:id/candidates",
             "POST /recolour", "POST /recolour/colours" ].freeze

  JobStub = Struct.new(:base_url, :name, :source_kind, :input_path, :spec,
                       :runner_job_id, keyword_init: true)
  ValidationStub = Struct.new(:job, :runner_validation_id, :file,
                              keyword_init: true)

  BASE = "http://127.0.0.1:8790".freeze

  # --- doc parsing ---------------------------------------------------------

  def contract
    @contract ||= begin
      lines = Rails.root.join("docs", "runner-contract.md").read.lines
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
      if seg.start_with?(":")
        "[^/]+"
      else
        # `<name>`/`<stem>.dataset` are placeholders too: the contract writes the
        # four-segment dataset route that way (it is how the runner's own doc
        # names it), and a literal `<name>` would match no real path. Escaped
        # FIRST, so only the angle-bracket placeholder becomes a wildcard.
        Regexp.escape(seg).gsub(/<[^<>]+>/, "[^/]+")
      end
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
                 "docs/runner-contract.md changed; update ENDPOINTS (and the studio) to match"
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

  # --- the dataset routes (the proof-variants opt-in) -----------------------

  test "dataset_package is GET /jobs/:id/dataset with the candidate as a query param" do
    with_captured_transport do |calls|
      RunnerClient.dataset_package(runner_job, "candidate_01.svg")
      call = calls.last
      assert_matches_contract(call, "GET /jobs/:id/dataset")
      # The candidate identifies WHICH dataset; it rides as a query param, not a
      # path segment, so the contract's path template has no slot for it.
      assert_equal [ [ "candidate", "candidate_01.svg" ] ],
                   URI.decode_www_form(URI(call[:url]).query.to_s)
    end
  end

  test "a dataset file is the FOUR-segment /files route, keyed on the candidate stem" do
    url = RunnerClient.dataset_file(runner_job, "02_traced/candidate_01.svg",
                                    "candidate_01.dataset.json")
    call = { transport: :get_file, url: url, body: nil }
    assert_matches_contract(call, "GET /files/:job_id/<stem>.dataset/<name>")
    assert_equal "/files/rj1/candidate_01.dataset/candidate_01.dataset.json",
                 URI(url).path, "the stem, not the candidate file name, names the dataset"
  end

  # --- the compose route (called by ComposeClient, not RunnerClient) --------

  # The vector-preserving flatten is the ONE route in this contract the app
  # reaches through a second client, so it gets its own transport stub: the
  # envelope (`{op, spec}`) and the path are what the runner's contract pins.
  test "compose is POST /compose with the contract's params" do
    calls = []
    original = ComposeClient.method(:post)
    ComposeClient.define_singleton_method(:post) do |url, body, **_kw|
      calls << { transport: :post, url: url, body: body }
      { bytes: "<svg/>", content_type: "image/svg+xml", name: "compose-probe.svg" }
    end

    ComposeClient.compose(BASE, { "width" => 10, "height" => 10, "layers" => [] })

    endpoint = assert_matches_contract(calls.last, "POST /compose")
    assert_body(calls.last, endpoint, %w[op spec])
    assert_equal "compose", calls.last[:body][:op],
                 "the runner refuses a document sent as the wrong operation"
  ensure
    ComposeClient.define_singleton_method(:post, original)
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
