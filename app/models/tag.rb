# Two-tier tags on one table. The settled design from CONTEXT.md: `kind: system`
# (derived at write time, never typable) and `kind: operator` (free text). A
# `kind: system` tag is derived from `spec` (e.g. `max_colors_6`) and is never
# a form field — if an operator can type it by hand, the search index carries
# a lie (`max_colors_3` is a claim about the spec, not about this tag row). A
# `kind: operator` tag is free text (`client-work`, `redo`), typed by a human.
#
# Tags join all four container tables (Project, Source, Job, Output) through a
# polymorphic `taggable` association rather than a bare `job_id` that outlives
# the job by design.
class Tag < ActiveRecord::Base
  include Owned

  belongs_to :taggable, polymorphic: true, optional: true

  validates :name, presence: true
  validates :kind, inclusion: { in: %w[system operator] }
  validates :name, uniqueness: { scope: %i[taggable_type taggable_id kind], message: "a tag with this name already exists for this item" }

  scope :system, -> { where(kind: "system") }
  scope :operator, -> { where(kind: "operator") }
end