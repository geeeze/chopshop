# A source is loaded or generated INTO a project. This is the redesign's
# container: the Project owns sources, and a Job is dispatched from one.
# The `project_id` and `source_type` were the missing container.
class Source < ActiveRecord::Base
  include Owned

  belongs_to :project, optional: true
  has_many :jobs, dependent: :nullify # the job's `source_id` points here

  validates :name, presence: true
  validates :source_type, inclusion: { in: %w[raster svg generated compound composite] }

  # A generated source (e.g. from FLUX) is still a source; a composite that
  # carries a vector layer is flattened as a vector by the runner, so its
  # source_type is `compound` and its `kind` records the kind of document.
  scope :generated, -> { where(source_type: "generated") }
  scope :raster, -> { where(source_type: "raster") }
end