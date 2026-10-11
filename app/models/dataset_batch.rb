require "digest"
require "json"
require "securerandom"

# A BATCH DRIVER over the DATASETS library (issue #46): one action produces N
# generation jobs — one per drawn prompt — so mass production does not mean N
# manual filings.
#
# THE PIPELINE CONVENTION this layer follows: it PRODUCES sources and a
# manifest. It does not auto-advance anything to final. A human picks. The
# driver files the jobs; the human reviews and runs them.
#
# DETERMINISM, the fleet contract:
#   * candidate rows are iterated in SORTED id order — never Ruby's hash()
#     (per-process seed), never random.Random (Python's, a different PRNG);
#   * a splitmix64 PRNG (DatasetView::Splitmix64) is seeded from
#     sha256(canonical rule) and picks N DISTINCT rows by deleting from a pool,
#     so no duplicate prompt appears in one batch;
#   * the same seed over an unchanged library yields the identical sequence.
#
# The splitmix64 class lives on DatasetView — it is the fleet's one PRNG — and
# is referenced here as DatasetView::Splitmix64 rather than duplicated.
#
# STORAGE: the manifest is a FILE at storage/batches/<batch_id>/manifest.json.
# No schema change, no BatchRecord table — the manifest is the batch's own
# record and the jobs it filed are queryable through Job. The file is the
# artifact the human reads to triage, and it survives the app's own DB churn.
#
# OWNER: jobs are stamped with Current.user_handle (via Owned). When Current is
# blank — a rake task with no request — the owner is "batch", so the jobs are
# still attributable and the rake-run jobs are distinguishable from interactive
# ones.
class DatasetBatch
  # The manifest's storage root. storage/batches is chosen over
  # storage/datasets (inputs the operator fetches) and storage/uploads (job
  # artifacts with retention policy) because a batch manifest is neither: it is
  # the record of a filing action, not a consumed input or a generated output.
  STORAGE_ROOT = Rails.root.join("storage", "batches").freeze

  # The fixed default seed. Re-running `datasets:batch` without SEED= reproduces
  # the same sequence — the determinism acceptance criterion. An operator
  # passes SEED= to vary the draw.
  DEFAULT_SEED = "batch-default-v1".freeze

  # The owner stamped on jobs filed outside a request (the rake task).
  # Distinguishable from an interactive owner so a reader can tell how a job
  # was filed without inferring from the spec.
  BATCH_OWNER = "batch".freeze

  # The flux job's generation settings. Kept minimal — the model, a size, and
  # the author's own seed/steps/guidance from the dataset row travel via
  # spec["prompt_source"] so the run reproduces the recorded request. Mode is
  # "raster" (the image IS the deliverable for a batch); the operator switches
  # to trace per job if they want candidates.
  FLUX_DEFAULTS = {
    "model" => "klein-4b",
    "width" => 1024,
    "height" => 1024,
    "mode" => "raster"
  }.freeze

  # A batch's identity: the rule + the seed, so two batches that differ in
  # either are different batches. Time is NOT in the id — the same rule and
  # seed produce the same id, which is what makes a re-run recognisable as a
  # re-run rather than a fresh batch.
  def self.batch_id(rule, seed)
    canonical = JSON.generate(rule.sort.to_h)
    hash = Digest::SHA256.hexdigest("#{canonical}|#{seed}")[0, 12]
    "b-#{hash}"
  end

  # The deterministic seed integer: sha256 of the canonical rule + seed
  # string, unpacked to a uint64 — the same construction DatasetView uses.
  def self.seed_int(rule, seed)
    canonical = JSON.generate(rule.sort.to_h)
    Digest::SHA256.digest("#{canonical}|#{seed}").unpack1("Q>")
  end

  # File → Array of PromptSource rows.
  #
  # Takes count/topic/root/seed and an optional view name. Returns a Result
  # with the batch_id, the seed, the rule, the drawn rows, and the manifest
  # path. Does NOT file jobs — the caller decides whether to run (controller)
  # or just report (rake dry-run).
  #
  # View support (?view=NAME): a DatasetView is a named, deterministic filter
  # (issue #48). When given, the candidate pool is the view's built row set and
  # the view's own draw provides the deterministic selection. The view is
  # looked up once and a missing view is a 404-level error — the same contract
  # datasets#draw uses.
  def self.draw(count: 20, topic: nil, root: nil, view: nil, seed: DEFAULT_SEED)
    rule = { "count" => count, "topic" => topic, "root" => root, "view" => view }

    if view.present?
      record = DatasetView.find_by(name: view)
      return Result.error("no view named #{view}") unless record

      # A view carries its own source_ids; the draw is the view's own
      # deterministic one, seeded from the view name + its sorted ids. The
      # batch seed only governs the manifest id and the provenance record —
      # the view is the authority on what it contains.
      rows = record.draw(count)
      id = batch_id(rule, seed)
      return Result.error("the view #{view} has no rows yet — build it first") if rows.empty?

      # Fall through with the view's rows as the pool. The batch seed is
      # recorded in the manifest but does not drive the view's draw.
      return Result.ok(
        batch_id: id,
        seed: seed,
        rule: rule,
        rows: rows,
        path: manifest_path(id)
      )
    end

    scope = PromptSource.all
    scope = scope.where(topic: topic) if topic.present?
    scope = scope.where(phrase_root: root) if root.present?
    candidates = scope.order(:id).to_a

    id = batch_id(rule, seed)

    if candidates.empty?
      # Same three causes as jobs#apply_prompt_source!, and the same rule: name
      # the one that happened. "Ingest the library first" over a loaded library
      # and an over-narrow filter sends the operator to re-ingest 60,000 rows.
      return Result.error("no prompts in the library — ingest it first") if PromptSource.count.zero?
      filters = [ topic.present? ? "topic #{topic.inspect}" : nil,
                  root.present? ? "root #{root.inspect}" : nil ].compact
      return Result.error("no prompts match #{filters.join(' and ')} — clear the filter to walk the whole library")
    end

    # N distinct rows, picked by a splitmix64 seeded from the rule + seed.
    # delete_at guarantees distinctness: a picked row leaves the pool.
    count = [count, candidates.size].min
    rng = DatasetView::Splitmix64.new(seed_int(rule, seed))
    pool = candidates.dup
    rows = []
    count.times do
      idx = (rng.next_float * pool.size).to_i.clamp(0, pool.size - 1)
      rows << pool.delete_at(idx)
    end

    Result.ok(
      batch_id: id,
      seed: seed,
      rule: rule,
      rows: rows,
      path: manifest_path(id)
    )
  end

  # The full run: draw + file one job per row + write the manifest.
  #
  # project_id is required (a job with no project is invisible under the
  # workspace, the same rule jobs#create enforces). owner is Current.user_handle
  # or BATCH_OWNER when there is no request context.
  #
  # Each job carries the same spec shape apply_prompt_source! produces for a
  # "Random from DiffusionDB" filing:
  #
  #   spec["flux"]["prompt"]       — the drawn prompt
  #   spec["prompt_source"]        — { dataset, id, topic, provenance }
  #   spec["batch_id"]             — this batch's id
  #   spec["batch_index"]          — 1-based position in the batch
  #
  # The dataset row's own seed/steps/guidance/sampler travel inside
  # spec["prompt_source"]["settings"] so the run can reproduce the author's
  # recorded request — the same provenance PromiseSource#to_contract makes.
  def self.run(count: 20, topic: nil, root: nil, view: nil, seed: DEFAULT_SEED,
               project_id:, owner: Current.user_handle.presence || BATCH_OWNER)
    drawn = draw(count: count, topic: topic, root: root, view: view, seed: seed)
    return drawn unless drawn.ok?

    project = Project.find_by(id: project_id)
    return Result.error("no project with id #{project_id}") unless project

    # The jobs are filed in a transaction so a failure mid-batch leaves no
    # partial set — the manifest and the jobs it lists must agree. The
    # manifest is written AFTER the commit so a rolled-back batch leaves no
    # manifest behind.
    jobs = []
    begin
      Job.transaction do
        drawn.rows.each_with_index do |row, i|
          index = i + 1
          job = Job.new(
            name: "batch-#{drawn.batch_id}-#{index}",
            runner: first_flux_runner,
            source_kind: "raster",
            input_path: "",
            project_id: project_id,
            owner: owner,
            spec: build_spec(drawn, row, index)
          )
          unless job.save
            # A validation failure aborts the whole batch — a half-filed batch
            # with no manifest is worse than none, because the jobs that WERE
            # filed have no manifest to say so.
            raise BatchJobError, "job #{index} failed: #{job.errors.full_messages.to_sentence}"
          end
          jobs << job
        end
      end
    rescue BatchJobError => e
      return Result.error(e.message)
    end

    write_manifest(drawn, jobs)
    drawn
  end

  # The spec for one filed job. The flux block is the generation request; the
  # prompt_source block is the provenance the controller's apply_prompt_source!
  # writes, plus the batch coordinates and the author's own settings.
  def self.build_spec(drawn, row, index)
    source = {
      "dataset" => row.dataset,
      "id" => row.id,
      "topic" => row.topic,
      "provenance" => row.provenance,
      "settings" => row.generation_settings.except("prompt")
    }
    {
      "flux" => FLUX_DEFAULTS.merge("prompt" => row.prompt),
      "prompt_source" => source,
      "batch_id" => drawn.batch_id,
      "batch_index" => index
    }
  end

  # The manifest: the batch's own record. Written after the jobs commit, so a
  # reader sees a manifest only for a batch that is fully filed.
  def self.manifest_path(batch_id)
    STORAGE_ROOT.join(batch_id, "manifest.json")
  end

  def self.write_manifest(drawn, jobs)
    path = drawn.path
    path.dirname.mkpath
    manifest = {
      "batch_id" => drawn.batch_id,
      "seed" => drawn.seed,
      "rule" => drawn.rule,
      "count" => jobs.size,
      "written_at" => Time.current.utc.iso8601,
      "jobs" => jobs.map do |j|
        row = j.spec && j.spec["prompt_source"] ? j.spec["prompt_source"] : {}
        {
          "prompt" => j.spec.dig("flux", "prompt"),
          "topic" => row["topic"],
          "dataset" => row["dataset"],
          "source_id" => row["id"],
          "job_id" => j.id,
          # The seed is the row's own recorded seed (the author's), not the
          # batch's selection seed — the manifest records what will reproduce
          # THIS image, which is the row's seed, steps and guidance.
          "seed" => row.dig("settings", "seed"),
          "file" => nil
        }
      end
    }
    path.write(JSON.pretty_generate(manifest))
    manifest
  end

  # The first configured flux runner, or nil when none is configured. The
  # controller's create_flux_job resolves per-kind; the batch files against
  # the first one, which is the same default the form uses.
  def self.first_flux_runner
    runners = Job.runner_urls.keys
    runners.find { |label| Job.flux_runner?(label) } || runners.first
  end

  # A batch filing failure: raised inside the transaction to roll back the
  # whole batch when one job fails validation. A custom class (not
  # ActiveRecord::Rollback, which the transaction mechanism swallows before
  # any rescue clause can see it) so the rescue below actually fires and the
  # caller gets a Result.error instead of a half-filed batch.
  class BatchJobError < StandardError; end

  # A Result: ok? → the batch fields; error? → the reason. The controller and
  # the rake task both read it, so the two surfaces cannot disagree about what
  # a failure means.
  class Result
    attr_reader :batch_id, :seed, :rule, :rows, :path, :error

    def self.ok(batch_id:, seed:, rule:, rows:, path:)
      new(ok: true, batch_id: batch_id, seed: seed, rule: rule, rows: rows, path: path)
    end

    def self.error(message)
      new(ok: false, error: message)
    end

    def initialize(ok:, batch_id: nil, seed: nil, rule: nil, rows: nil, path: nil, error: nil)
      @ok = ok
      @batch_id = batch_id
      @seed = seed
      @rule = rule
      @rows = rows
      @path = path
      @error = error
    end

    def ok?
      @ok
    end

    def jobs
      return [] unless ok?
      # Load and filter in Ruby rather than using a JSON operator: the spec is
      # a JSON column and the set is small (one batch's worth of jobs), so a
      # Ruby-side filter is simpler and avoids depending on a specific SQLite
      # JSON operator version.
      @jobs ||= Job.unscoped.to_a.select { |j| j.spec.is_a?(Hash) && j.spec["batch_id"] == batch_id }
                     .sort_by(&:id)
    end
  end
end
