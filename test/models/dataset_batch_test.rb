require "test_helper"

# The batch driver (issue #46): one action files N jobs, one per drawn
# prompt, deterministically, with a manifest. No network; the library is
# built in-process.
#
# The acceptance criteria:
#   * determinism — same seed → same sequence
#   * distinctness — no duplicate prompt in one batch
#   * manifest completeness — every job listed with provenance
#   * filter application — TOPIC=art only draws art rows
class DatasetBatchTest < ActiveSupport::TestCase
  setup do
    PromptSource.delete_all
    Job.delete_all
    # A small deterministic library: known topics, known ids.
    @rows = []
    %w[art art art portrait portrait landscape].each_with_index do |topic, i|
      @rows << PromptSource.create!(
        dataset: "diffusiondb", topic: topic, phrase_root: "root-#{i}",
        prompt: "prompt number #{i} about #{topic}", x: i.to_f, y: i.to_f
      )
    end
    @project = Project.create!(name: "batch-test", is_test: false)
    # The runner registry must contain a flux label for the job to validate
    # as a flux job. Same isolation the controller test uses.
    @saved_env = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| @saved_env[k] = ENV.delete(k) }
    ENV["CHOPSHOP_RUNNER_FLUX_URL"] = "http://generator.invalid:8795"
    ENV["CHOPSHOP_RUNNER_FLUX_KIND"] = "flux"
    Job.reset_runners_cache!
  end

  teardown do
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
    @saved_env.each { |k, v| ENV[k] = v }
    Job.reset_runners_cache!
  end

  # --- determinism --------------------------------------------------------

  test "the same seed over an unchanged library produces the same sequence" do
    first = DatasetBatch.draw(count: 3, seed: "test-seed")
    second = DatasetBatch.draw(count: 3, seed: "test-seed")
    assert_equal first.rows.map(&:id), second.rows.map(&:id),
      "a re-run with the same seed must reproduce the same sequence"
  end

  test "a different seed produces a different sequence" do
    first = DatasetBatch.draw(count: 3, seed: "seed-a")
    second = DatasetBatch.draw(count: 3, seed: "seed-b")
    refute_equal first.rows.map(&:id), second.rows.map(&:id),
      "a different seed must produce a different sequence"
  end

  test "the batch id is deterministic for the same rule and seed" do
    first = DatasetBatch.draw(count: 3, seed: "test-seed")
    second = DatasetBatch.draw(count: 3, seed: "test-seed")
    assert_equal first.batch_id, second.batch_id
  end

  # --- distinctness -------------------------------------------------------

  test "no duplicate prompt appears in one batch" do
    result = DatasetBatch.draw(count: 6)
    assert result.ok?
    prompts = result.rows.map(&:prompt)
    assert_equal prompts.size, prompts.uniq.size,
      "a batch must not contain duplicate prompts"
  end

  test "count is clamped to the candidate pool size" do
    result = DatasetBatch.draw(count: 99)
    assert result.ok?
    assert_equal 6, result.rows.size,
      "a batch cannot draw more rows than the library holds"
  end

  # --- filter application -------------------------------------------------

  test "TOPIC=art only draws art rows" do
    result = DatasetBatch.draw(count: 3, topic: "art")
    assert result.ok?
    assert(result.rows.all? { |r| r.topic == "art" },
           "every drawn row must match the topic filter")
  end

  test "ROOT= filters by phrase_root" do
    result = DatasetBatch.draw(count: 2, root: "root-0")
    assert result.ok?
    assert_equal 1, result.rows.size
    assert_equal "root-0", result.rows.first.phrase_root
  end

  test "a filter that matches nothing is refused" do
    result = DatasetBatch.draw(count: 3, topic: "no-such-topic")
    refute result.ok?
    assert_includes result.error, "no prompts match"
  end

  # --- view support -------------------------------------------------------

  test "a view name draws from the view's slice" do
    view = DatasetView.create!(name: "art-view", rule: { "topic" => "art" })
    view.build!
    result = DatasetBatch.draw(count: 2, view: "art-view")
    assert result.ok?
    assert(result.rows.all? { |r| r.topic == "art" },
           "a view-filtered batch must draw only from the view's rows")
  end

  test "an unknown view is refused" do
    result = DatasetBatch.draw(count: 2, view: "no-such-view")
    refute result.ok?
    assert_includes result.error, "no view named"
  end

  # --- job filing ---------------------------------------------------------

  test "run files one job per drawn prompt with provenance" do
    result = DatasetBatch.run(count: 3, seed: "test-seed", project_id: @project.id)
    assert result.ok?
    assert_equal 3, result.rows.size
    assert_equal 3, Job.count

    jobs = Job.order(:id).to_a
    jobs.each_with_index do |job, i|
      row = result.rows[i]
      assert_equal row.prompt, job.spec.dig("flux", "prompt"),
        "the job's prompt must be the drawn prompt"
      assert_equal row.id, job.spec.dig("prompt_source", "id"),
        "the job must record which row it drew"
      assert_equal row.dataset, job.spec.dig("prompt_source", "dataset")
      assert_equal result.batch_id, job.spec["batch_id"],
        "the job must record which batch it belongs to"
      assert_equal i + 1, job.spec["batch_index"],
        "the job must record its position in the batch"
    end
  end

  test "the manifest lists every job with its provenance" do
    result = DatasetBatch.run(count: 3, seed: "test-seed", project_id: @project.id)
    assert result.ok?

    manifest = JSON.parse(result.path.read)
    assert_equal result.batch_id, manifest["batch_id"]
    assert_equal 3, manifest["count"]
    assert_equal 3, manifest["jobs"].size

    manifest["jobs"].each_with_index do |entry, i|
      row = result.rows[i]
      assert_equal row.prompt, entry["prompt"]
      assert_equal row.id, entry["source_id"]
      assert_equal row.topic, entry["topic"]
      assert_equal row.dataset, entry["dataset"]
      assert entry["job_id"].present?, "every manifest entry names its job"
    end
  end

  test "run refuses a missing project" do
    result = DatasetBatch.run(count: 3, project_id: 99999)
    refute result.ok?
    assert_includes result.error, "no project"
  end

  test "run is atomic — a validation failure leaves no partial batch" do
    # Force a failure on the second job by stubbing Job.new to raise a
    # BatchJobError on the second call. The transaction must roll back all
    # jobs and the caller must get a Result.error.
    call_count = 0
    original_new = Job.method(:new)
    Job.define_singleton_method(:new) do |**kwargs|
      call_count += 1
      if call_count == 2
        raise DatasetBatch::BatchJobError, "simulated failure"
      end
      original_new.call(**kwargs)
    end

    result = DatasetBatch.run(count: 3, seed: "test-seed", project_id: @project.id)
    refute result.ok?
    assert_includes result.error, "simulated failure"
    assert_equal 0, Job.count, "a rolled-back batch must leave no jobs behind"
  ensure
    Job.define_singleton_method(:new, original_new)
  end

  # --- manifest location --------------------------------------------------

  test "the manifest is written under storage/batches/<batch_id>/" do
    result = DatasetBatch.run(count: 2, seed: "test-seed", project_id: @project.id)
    assert result.ok?
    expected = DatasetBatch::STORAGE_ROOT.join(result.batch_id, "manifest.json")
    assert_equal expected, result.path
    assert result.path.exist?, "the manifest file must exist after a successful run"
  end
end
