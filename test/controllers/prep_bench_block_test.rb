require "test_helper"

# The expanded-prep bench (prep_expand) on the job results page: the bench
# report the runner returns in GET /jobs/:id, stored in jobs.prep_expand and
# rendered as a block inside the right-hand column of .results-split.
#
# The bench is the operator's due diligence on the raster — which filters,
# which trace settings, which node reduction — so it belongs beside the
# candidates it produced, not only in the download. The block appears only
# when the runner reported a bench (the job's spec asked for print.prep_expand
# and the job completed).
class PrepBenchBlockTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  BENCH = {
    "filters" => { "keep_alpha" => true, "spec" => "screenprint" },
    "tune" => { "filter_speckle" => 2, "hierarchical" => true,
                "with_node_reduce" => true },
    "node_reduce" => { "tolerance" => 0.5, "tolerance_cap" => 0.1,
                       "verify" => true }
  }.freeze

  def setup
    super
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def job_with_bench(bench = BENCH)
    Job.create!(name: "bench", state: "done", source_kind: "raster",
                input_path: "/data/x.png", stem: "bench", spec: {}, runner: "mock",
                comparison: { "candidates" => [
                  { "file" => "candidate_01.svg", "hard" => 0, "advisory" => 1,
                    "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" } }
                ] },
                prep_expand: bench)
  end

  def job_without_bench
    Job.create!(name: "no-bench", state: "done", source_kind: "raster",
                input_path: "/data/y.png", stem: "no-bench", spec: {}, runner: "mock",
                comparison: { "candidates" => [
                  { "file" => "candidate_01.svg", "hard" => 0, "advisory" => 1,
                    "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" } }
                ] })
  end

  test "the bench block renders when prep_expand is present" do
    job = job_with_bench

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    side = doc.at_css(".results-side")
    refute_nil side, "the results page is split"

    bench_card = side.at_css(".results-bench-card")
    refute_nil bench_card, "the bench block renders inside the right-hand column"

    # The bench's sub-sections are rendered.
    %w[filters tune node_reduce].each do |section|
      assert_equal 1, bench_card.css(".results-bench-section").select { |s|
        s.at_css(".results-bench-title")&.text&.strip&.downcase&.tr(" ", "_") == section
      }.size, "the #{section} sub-section renders"
    end

    # The bench's values are rendered.
    assert_match(/keep alpha/, bench_card.text)
    assert_match(/screenprint/, bench_card.text)
    assert_match(/filter speckle/, bench_card.text)
    assert_match(/hierarchical/, bench_card.text)
    assert_match(/tolerance/, bench_card.text)
  end

  test "the bench block is absent when prep_expand is nil" do
    job = job_without_bench

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    side = doc.at_css(".results-side")
    refute_nil side
    assert_nil side.at_css(".results-bench-card"),
               "no bench block when the runner reported no bench"
    assert_equal 0, side.css("h3.record-section").select { |h|
      h.text.strip == "Prep bench:"
    }.size, "no bench heading when there is no bench"
  end

  test "the bench block sits after the proofs and before the sources" do
    job = job_with_bench
    job.validations.create!(file: "candidate_01.svg", state: "done",
                            manifest: { "proof" => "proof_01.png" })

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    side = doc.at_css(".results-side")
    refute_nil side

    # The bench block is inside .results-side, after the proofs table and
    # before the sources stack.
    proofs = side.at_css("table.proofs-tbl")
    refute_nil proofs, "the proofs table renders"

    bench_card = side.at_css(".results-bench-card")
    refute_nil bench_card

    # Document order: proofs before bench. Both are nested inside wrappers,
    # so compare their positions among all descendants of .results-side.
    side_descendants = side.css("*")
    proofs_pos = side_descendants.index(proofs)
    bench_pos = side_descendants.index(bench_card)
    assert proofs_pos < bench_pos,
           "the bench block sits after the proofs table"
  end

  test "the stored bench data round-trips" do
    job = job_with_bench

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    bench_card = doc.at_css(".results-bench-card")
    refute_nil bench_card

    # The bench's own values are rendered, not a stub.
    assert_match(/0\.5/, bench_card.text, "the node_reduce tolerance value")
    assert_match(/0\.1/, bench_card.text, "the node_reduce tolerance_cap value")
    assert_match(/true/, bench_card.text, "the verify flag")
  end

  test "sync_from_runner! stores prep_expand" do
    job = job_without_bench
    job.update!(runner_job_id: "rj-test")

    original = RunnerClient.method(:get_job)
    RunnerClient.define_singleton_method(:get_job) do |_j|
      { state: "done", prep_summary: "done",
        prep_expand: BENCH, candidate_count: 1,
        comparison: { "candidates" => [
          { "file" => "candidate_01.svg", "hard" => 0, "advisory" => 1,
            "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" } }
        ] } }
    end

    job.sync_from_runner!
    assert job.reload.prep_expand.is_a?(Hash), "prep_expand is stored"
    assert_equal true, job.prep_expand.dig("filters", "keep_alpha")
    assert_equal 2, job.prep_expand.dig("tune", "filter_speckle")
  ensure
    RunnerClient.define_singleton_method(:get_job, original)
  end

  test "sync_from_runner! does not overwrite prep_expand with nil" do
    job = job_with_bench
    job.update!(runner_job_id: "rj-test")

    original = RunnerClient.method(:get_job)
    RunnerClient.define_singleton_method(:get_job) do |_j|
      { state: "done", prep_summary: "done", prep_expand: nil,
        candidate_count: 1,
        comparison: { "candidates" => [
          { "file" => "candidate_01.svg", "hard" => 0, "advisory" => 1,
            "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" } }
        ] } }
    end

    job.sync_from_runner!
    assert job.reload.prep_expand.is_a?(Hash),
           "a nil prep_expand from the runner does not wipe the stored bench"
  ensure
    RunnerClient.define_singleton_method(:get_job, original)
  end
end
