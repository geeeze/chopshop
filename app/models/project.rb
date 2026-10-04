# The container: a Project owns sources, sequences jobs, and receives outputs.
#
# A job's output has nowhere to go back to today. CONTEXT.md (settled 2026-10-01)
# records the incoherence: `Job` is a row, `runner_job_id` is the runner's row,
# `active_job_id` is a third thing — no container for the work. Provenance is
# four unrelated mechanisms with real holes: candidates/validations have real
# FKs, but scrapbook_items and events carry bare integers that outlive the job
# by design. Both composite flatten paths create their `ScrapbookItem` with
# `job_id: nil`, and the raster path writes no `sha256`. The runner derives
# its own `stem`; the studio derives a different one, and nothing records that.
#
# The fix: a stored Project table (not a tag view) that owns sources, sequences
# jobs, and holds outputs. Tags join all four tables through one `tags` table
# with a `kind` column (system / operator) so derived tags never become
# typable, and the operator tags stay free text (`client-work`, `redo`).
#
# The sequence counter lives on the project row (not MAX(sequence)+1) to avoid
# a read-then-write race. Incremented under the row lock at dispatch.
class Project < ActiveRecord::Base
  include Owned

  validates :name, presence: true, uniqueness: { scope: :owner }
  validates :is_test, inclusion: { in: [true, false] }, on: :create

  has_many :sources, dependent: :destroy
  has_many :jobs, -> { order(sequence: :asc) }, dependent: :destroy, inverse_of: :project
  has_many :composites, dependent: :destroy
  has_many :outputs, dependent: :destroy

  # System tags are derived at write; operator tags are free text.
  # The two-tier design (system / operator) is pinned in CONTEXT.md.
  has_many :tags, as: :taggable, dependent: :destroy

  # Unique per operator: each user sees only their own workspace.
  # Scoped reads via `Owned`'s `default_scope`; writes via `before_validation`.

  # The sequence number assigned at dispatch. The counter lives on this row,
  # incremented under the row lock at dispatch time — not a `MAX` over all jobs,
  # which is a race.
  def next_sequence!
    with_lock do
      num = (self.next_sequence || 0) + 1
      self.next_sequence = num
      save!
      num
    end
  end

  # A project with `is_test` set to true carries `name` that is real rather than
  # a prefix convention, because CONTEXT.md settled that `name LIKE 'smoke-%'`
  # is a lie the moment anyone names a real project `smoke-test-hero`.
  def test_project?
    is_test
  end

  # The owned workspace: a user sees only the projects stamped `owner:` their
  # handle. No cross-operator read, no foreign-key leak.
  scope :for_owner, ->(handle) { where(owner: handle) }

  # The tag vocabulary: two kinds on a single table. System tags are never
  # typable; operator tags are free text.
  #
  # This is the design from CONTEXT.md (
  # "Tags are two tiers, one table, a `kind` column. System tags are derived
  # from the spec at write time and are never typable...").
  # Not implemented in this pass: the tags are added when the user directs
  # the vocabulary to be built.
end
