# Every prompt an operator has filed, so the Run Job form can offer it back.
#
# This is the RECALL side of the prompt. The PROVENANCE side already exists and
# is a different thing: `spec["prompt_source"]` on a job records WHICH library
# row a draw used, attached to that one run. This table is the operator's own
# list -- "what have I asked for before" -- and it is deliberately not scoped to
# a project, a dataset or a job: a prompt that worked is worth reusing wherever
# the next run happens to live.
class PromptRecord < ApplicationRecord
  # Trim to something a textarea can hold without the list becoming a memory
  # problem. Well past any real prompt; a composed one runs to a few hundred.
  MAX_LENGTH = 4000
  RECENT = 40
  SOURCES = %w[typed dataset mashup composer].freeze

  validates :prompt, presence: true
  validates :fingerprint, presence: true

  scope :recent, ->(limit = RECENT) { order(last_used_at: :desc, id: :desc).limit(limit) }

  # Remember a prompt, or count another use of one already known.
  #
  # Upsert by digest so refining one prompt twenty times leaves ONE row with a
  # use count, not twenty near-twins burying the rest of the list. Returns nil
  # for a blank prompt rather than raising: a run filed without a prompt (a
  # trace job, a plot job) is normal and must not fail the create.
  def self.remember!(prompt, source: nil, job_id: nil)
    text = prompt.to_s.strip[0, MAX_LENGTH]
    return nil if text.blank?

    digest = Digest::SHA256.hexdigest(text)
    now = Time.current
    record = find_by(fingerprint: digest)

    if record
      record.update_columns(
        uses_count: record.uses_count + 1,
        last_used_at: now,
        updated_at: now,
        source: source.presence || record.source,
        job_id: job_id || record.job_id
      )
    else
      record = create!(prompt: text, fingerprint: digest, source: source.presence,
                       job_id: job_id, uses_count: 1, last_used_at: now)
    end

    record
  rescue ActiveRecord::RecordNotUnique
    # Two filings of the same prompt, racing between the find and the insert.
    # The other one won; take its row.
    retry
  end
end
