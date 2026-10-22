# The candidate-triage LEARNING SIGNAL: one row per human action the studio
# observes — the operator starred an artifact into the scrapbook, unstarred it,
# picked it to take forward (trace-it, or running a proof), or deleted the job
# it came from. A future learned ranker trains on these rows: which artifact a
# human chose, from which ordered candidate list, at what position, and which
# ranker proposed that order at the time.
#
# Two shapes are inherited from ScrapbookItem on purpose:
#
#   * NO foreign key to jobs. `job_id` is PROVENANCE ONLY, so the training
#     signal survives the job's `destroy` — the whole point of the log.
#   * owner-scoped through Owned, so one operator's actions are never another's
#     training data.
#
# Every write goes through Event.record, which is NON-FATAL by contract:
# logging is a side channel, and a failed log must never break the operator
# action it describes. Call sites that rely on that are tagged
# `#event-log-record`.
class Event < ActiveRecord::Base
  include Owned

  # star   — favourited an artifact into the scrapbook
  # unstar — removed a scrapbook favourite
  # pick   — chose an artifact to take forward (trace-it, or running a proof)
  # delete — deleted the job an artifact came from
  KINDS = %w[star unstar pick delete].freeze

  # The ranker behind the order an operator acted on while no learned model is
  # in play: the studio's own (hard, advisory, id) ranking. Stamped whenever a
  # position is recorded, left NULL otherwise.
  STUDIO_RANKER = "studio".freeze

  validates :event, presence: true, inclusion: { in: KINDS }

  scope :recent,   -> { order(created_at: :desc, id: :desc) }
  scope :of_kind,  ->(kind) { where(event: kind) }
  scope :for_job,  ->(job_id) { where(job_id: job_id) }

  # Append one event and never raise. Returns true when the row landed, false
  # when anything went wrong (a schema slip, a bad payload) — the caller's
  # primary action completes either way. `rank` defaults to the studio ranker
  # whenever a position is supplied, because a position only exists because
  # some ranker produced the order it is a position IN.
  def self.record(event:, job_id: nil, svg_sha: nil, pos: nil, ranker: nil, payload: {})
    create!(event: event, job_id: job_id, svg_sha: svg_sha, pos: pos,
            ranker: ranker || (pos ? STUDIO_RANKER : nil), payload: payload || {})
    true
  rescue StandardError => e
    Rails.logger.warn("event log: dropped #{event.inspect} (#{e.class}: #{e.message})")
    false
  end

  # The 1-based rank of `file` in the SAME (hard, advisory, id) order the
  # candidate table renders — the position an operator's pick was made from,
  # which is the thing a ranker has to learn. nil when the file is not one of
  # the job's candidates (a source, an invert, a proof) or the job is gone
  # (its id survives on the event, the row does not).
  def self.position_of(job, file)
    return nil if job.nil? || file.blank?
    files = job.candidates.order(:hard, :advisory, :id).pluck(:file)
    index = files.index(file.to_s)
    index && index + 1
  end
end
