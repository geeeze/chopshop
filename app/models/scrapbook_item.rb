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
  # `svg` is a VECTOR artefact: a composite the studio composed as vectors (never
  # rasterised and re-traced). See #vector?.
  KINDS = %w[source invert candidate proof upload flux svg].freeze

  # `sha256` is the CHECKSUM AT CREATION: the digest of the exact bytes this row
  # stored. It travels onto the event log so a ranker can key an artifact by its
  # content rather than its (job-scoped, and so deletable) name.
  validates :name, :kind, :file, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  # An SVG item is a VECTOR: the compose operation can place it as vectors
  # instead of pixels, which is what keeps a traced source a trace. The stored
  # file's extension is the tell — the artifact kind says where an item came from
  # (`candidate`, `proof`, `upload`), and a candidate IS an SVG while a proof is
  # not, so the kind alone cannot answer this.
  def vector?
    kind == "svg" || File.extname(file.to_s).downcase == ".svg"
  end

  def stored_path
    Rails.root.join("storage", "scrapbook", file)
  end
end
