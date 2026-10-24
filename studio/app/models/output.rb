# One row per artefact a job produces. The redesign's container for outputs:
# a Project holds outputs, a Job's outputs return to the project that asked.
# The `project_id` links back; `job_id` is the producing job; `kind` is the
# output kind (candidate / proof / manifest / dataset / file / drawing).
class Output < ActiveRecord::Base
  include Owned

  belongs_to :project, optional: true
  belongs_to :job, optional: true

  validates :file_name, presence: true
  validates :output_kind, inclusion: { in: %w[candidate proof manifest dataset file drawing archive image frame] }
  validates :sha256, presence: true, length: { is: 64 }, allow_blank: false

  # The `sha256` is the identity: a flattened composite that once carried `nil`
  # and no hash cannot be found again. The output record fixes that.
  scope :proofs, -> { where(output_kind: "proof") }
  scope :candidates, -> { where(output_kind: "candidate") }
  scope :manifests, -> { where(output_kind: "manifest") }

  # The published filename naming convention (from CONTEXT.md):
  # `<name>-candidate-01.svg`, `<name>-proof-01.png/.pdf/.manifest.json`.
  def published_name(stem: nil, index: 1)
    s = stem || (job ? job.name : "")
    case output_kind
    when "candidate" then "#{s}-candidate-#{index.to_s.rjust(2, '0')}.svg"
    when "proof"     then "#{s}-proof-01"
    else file_name
    end
  end
end