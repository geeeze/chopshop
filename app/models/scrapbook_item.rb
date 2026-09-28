# A favourited artifact kept in the operator's scrapbook (the left sidebar).
#
# The scrapbook is its OWN store of data, deliberately separate from jobs: its
# files live under storage/scrapbook/ (not a job directory), and the bytes are
# COPIED in at favourite time rather than referenced. That is the whole point of
# the feature — deleting the job a source/invert/candidate/proof came from must
# not take the scrapbook copy with it. `job_id` is provenance only, not a
# foreign key and not a dependency: the row and its file survive the job's
# `destroy`.
#
# `owner` is the signed-in user's handle, stamped at creation and used to scope
# every read (see Owned). Set automatically; never assigned by hand.
class ScrapbookItem < ActiveRecord::Base
  include Owned

  # `flux` is a generated raster (a batch variation), saved from the job page's
  # variations grid via the local-upload route — it has no runner file behind it.
  KINDS = %w[source invert candidate proof upload flux].freeze

  validates :name, :kind, :file, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  def stored_path
    Rails.root.join("storage", "scrapbook", file)
  end
end
