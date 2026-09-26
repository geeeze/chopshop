class Job < ActiveRecord::Base
  has_many :candidates, dependent: :delete_all
  has_many :validations, dependent: :delete_all

  STATES = %w[pending queued running done error cancelled].freeze
  IN_FLIGHT_STATES = %w[pending queued running].freeze
  RUNNERS = {
    "mock" => "http://127.0.0.1:8790",
    "geenet" => "http://127.0.0.1:8787"
  }.freeze

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
