class Job < ActiveRecord::Base
  has_many :candidates, dependent: :delete_all
  has_many :validations, dependent: :delete_all

  STATES = %w[pending queued running done error cancelled].freeze
  IN_FLIGHT_STATES = %w[pending queued running].freeze

  # Runner name -> base URL. The KEYS are the labels the studio shows; they are
  # deliberately generic ("mock" plus whatever a deployment adds) because they
  # are data, not identifiers of a particular machine. Values default to loopback
  # so a fresh checkout runs with no configuration.
  #
  # Add a runner with CHOPSHOP_RUNNER_<LABEL>_URL rather than editing this file:
  # a literal here would tie the repo to one host's topology, and the live URL
  # changes whenever that host moves. The label is the env var name with the
  # prefix/suffix stripped and lower-cased, so underscores stay underscores:
  # CHOPSHOP_RUNNER_STUDIO_A_URL gives the label "studio_a".
  RUNNER_DEFAULTS = {
    "mock" => "http://127.0.0.1:8790",
  }.freeze

  RUNNER_URL_RE = /\ACHOPSHOP_RUNNER_[A-Z0-9_]+_URL\z/.freeze

  # Memoised because RUNNERS is read on every job page render. Keyed on the
  # relevant env slice, so it recomputes when a runner is added but still
  # short-circuits on every render. Call .reset_runners_cache! after mutating
  # ENV in a console or a test.
  def self.runner_urls
    snapshot = runner_env_snapshot
    if !defined?(@runner_urls) || @runner_urls_env != snapshot
      from_env = snapshot.map do |key, url|
        [key.sub(/\ACHOPSHOP_RUNNER_/, "").sub(/_URL\z/, "").downcase, url]
      end
      @runner_urls = RUNNER_DEFAULTS.merge(from_env.to_h).freeze
      @runner_urls_env = snapshot
    end
    @runner_urls
  end

  def self.runner_env_snapshot
    ENV.keys.grep(RUNNER_URL_RE).map { |k| [k, ENV[k]] }.sort
  end

  def self.reset_runners_cache!
    remove_instance_variable(:@runner_urls) if defined?(@runner_urls)
    remove_instance_variable(:@runner_urls_env) if defined?(@runner_urls_env)
  end

  def self.runners
    runner_urls
  end

  RUNNERS = runner_urls

  validates :name, presence: true
  validates :runner, inclusion: { in: RUNNERS.keys }

  before_create :set_defaults

  scope :recent, -> { order(created_at: :desc) }

  def in_flight?
    IN_FLIGHT_STATES.include?(state)
  end

  def base_url
    RUNNERS.fetch(runner) { raise "unknown runner #{runner}" }
  end

  def sync_from_runner!
    return unless runner_job_id
    data = RunnerClient.get_job(self)
    self.state = data[:state] if data[:state]
    self.prep_summary = data[:prep_summary] if data[:prep_summary]
    self.candidate_count = data[:candidate_count].to_i
    self.comparison = data[:comparison] if data[:comparison]
    self.error = data[:error] if data.key?(:error)
    save!

    # sync candidates when the comparison arrives
    if comparison.is_a?(Hash) && (list = comparison["candidates"])
      existing = candidates.index_by(&:file)
      list.each do |c|
        rec = existing[c["file"]] || candidates.build
        rec.file = c["file"]
        rec.preset = c.dig("sweep", "preset")
        rec.hierarchical = c.dig("sweep", "hierarchical")
        rec.filter_speckle = c.dig("sweep", "filter_speckle")
        rec.use_palette = c.dig("sweep", "use_palette")
        rec.sweep = c["sweep"]
        rec.layer_a = c.dig("layer_a", "status")
        rec.layer_b = c.dig("layer_b", "status")
        rec.hard = c["hard"].to_i
        rec.advisory = c["advisory"].to_i
        rec.fidelity = c["fidelity"]
        rec.passed = c["passed"]
        rec.save!
      end
    end
    self
  end

  def passed_count
    return 0 unless comparison.is_a?(Hash)
    Array(comparison["candidates"]).count { |c| c["passed"] }
  end

  # The runner's comparison entries never carry a "fidelity_verdict" -- the
  # keys are file, sweep, layer_a, layer_b, hard, advisory, fidelity, passed --
  # so the verdict shown in the candidates table AND in the findings popup has
  # to be derived from the fidelity numbers themselves. Done here, once, so both
  # surfaces agree. An explicit verdict, if a runner ever sends one, still wins.
  def self.fidelity_verdict(entry)
    # A runner-supplied verdict is trusted verbatim, but it has to be a String:
    # the view calls fv.tr("_", " "), which would raise NoMethodError on a
    # number. Coerced here, once.
    explicit = entry.is_a?(Hash) ? entry["fidelity_verdict"] : nil
    return explicit.to_s if explicit.present?

    f = entry.is_a?(Hash) ? entry["fidelity"] : nil
    return "unmeasured" unless f.is_a?(Hash) && f["measured"]
    mae = f["mae_art"]
    return "unmeasured" if mae.nil?

    mae = mae.to_f
    return "faithful" if mae <= 25
    return "drift" if mae <= 60
    "lost"
  end

  # The pill class behind a verdict; the table cell and the popup pill share it.
  def self.fidelity_status(verdict)
    case verdict
    when "faithful" then "pass"
    when "drift"    then "warn"
    when "lost"     then "fail"
    else                 "pending"
    end
  end

  # Decorate each comparison candidate with the derived verdict AT READ TIME.
  # The findings popup is fed the raw comparison entry by the JSON endpoint and
  # the model cannot reach into that response from the controller, so the
  # derivation has to ride on the entry itself for the popup and the table to
  # share one implementation rather than growing a second copy in the view's JS.
  def comparison
    raw = read_attribute(:comparison)
    return raw unless raw.is_a?(Hash) && raw["candidates"].is_a?(Array)
    raw.merge(
      "candidates" => raw["candidates"].map do |c|
        next c unless c.is_a?(Hash)
        verdict = self.class.fidelity_verdict(c)
        c.merge(
          "fidelity_verdict" => verdict,
          "fidelity_status" => self.class.fidelity_status(verdict)
        )
      end
    )
  end

  def file_url(name)
    "#{base_url}/files/#{runner_job_id}/#{name}"
  end

  def archive_url
    "#{base_url}/jobs/#{runner_job_id}/archive"
  end

  private

  def set_defaults
    self.stem ||= begin
      s = name.to_s.downcase.gsub(/[^a-z0-9]+/, "-")
      s = s.split("-").reject(&:blank?).join("-")
      s.presence || "artwork"
    end
    self.spec ||= {}
  end
end
