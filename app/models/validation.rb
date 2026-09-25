class Validation < ActiveRecord::Base
  belongs_to :job
  belongs_to :candidate, optional: true

  STATES = %w[pending running done error].freeze

  def sync_from_runner!
    return unless runner_validation_id
    data = RunnerClient.get_validation(self)
    self.state = data[:state] if data[:state]
    self.manifest = data[:manifest] if data[:manifest]
    self.error = data[:error] if data.key?(:error)
    self.finished_at = Time.current if state == "done"
    save!
    self
  end
end
