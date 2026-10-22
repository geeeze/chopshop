# A CURATED VIEW over the DATASETS library (issue #48): a named, persisted rule
# set that regenerates deterministically from the current PromptSource library.
#
# The dmpool honesty model is the contract here: a view ORDERS and NARROWS, it
# never picks a winner and never hides a record silently. Every row the rule
# excluded is listed in the manifest with the reason it was excluded, so a
# reader can always see what the view left out and why. A view is a defined
# subset with recorded selection rules, not a black box.
#
# DETERMINISM is a fleet contract: the build iterates in sorted order and, when
# a size cap forces a sample, seeds a splitmix64 PRNG from the rule's own bytes
# (never Ruby's hash(), whose seed is per-process). So the same rule over an
# unchanged library yields the identical set on every rebuild and every box.
#
# The rule (stored as JSON data, not code):
#   {
#     "dataset"   => "diffusiondb",        # optional; omit = all datasets
#     "topic"     => "portrait",           # optional filter
#     "phrase_root" => "a woman",          # optional filter
#     "include_ids" => [1, 2, 3],          # optional explicit includes
#     "exclude_ids" => [9],                # optional explicit excludes
#     "cap"       => 500                   # optional size cap
#   }
class DatasetView < ApplicationRecord
  # A splitmix64 PRNG. Deterministic across processes and platforms from an
  # integer seed — the fleet's determinism contract (sorted iteration +
  # sha256+splitmix64, never hash()). Used only when a cap forces a sample.
  class Splitmix64
    MASK = (1 << 64) - 1

    def initialize(seed)
      @state = seed & MASK
    end

    def next_u64
      @state = (@state + 0x9E3779B97F4A7C15) & MASK
      z = @state
      z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
      z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
      z ^ (z >> 31)
    end

    # A float in [0, 1) from the top 53 bits, for a uniform sample pick.
    def next_float
      (next_u64 >> 11) / 2**53.0
    end
  end

  validates :name, presence: true, uniqueness: true

  # --- building ------------------------------------------------------------

  # Regenerate this view's row set from the current library, deterministically.
  # Records the manifest (count, rule, omitted-with-reason) and the resolved
  # source ids in sorted order. Returns self.
  #
  # The build is honest: it never drops a row silently. Rows removed by an
  # explicit exclude, and rows trimmed by the size cap, are both recorded in
  # the manifest's omitted list with the reason.
  def build!
    scope = base_scope
    included = scope.order(:id).pluck(:id)

    omitted = []
    included, cap_omitted = apply_cap(included)
    omitted.concat(cap_omitted)

    manifest = {
      "built_at" => Time.current.utc.iso8601,
      "rule" => rule,
      "count" => included.size,
      "omitted" => omitted
    }

    update!(source_ids: included, manifest: manifest, built_at: Time.current)
    self
  end

  # The scope the rule's filters select, before the cap. Excludes named in the
  # rule are removed here; includes are unioned in. Deterministic ordering is
  # applied by the caller.
  def base_scope
    scope = PromptSource.all
    scope = scope.where(dataset: rule["dataset"]) if rule["dataset"].present?
    scope = scope.where(topic: rule["topic"]) if rule["topic"].present?
    scope = scope.where(phrase_root: rule["phrase_root"]) if rule["phrase_root"].present?

    exclude_ids = Array(rule["exclude_ids"]).map(&:to_i)
    scope = scope.where.not(id: exclude_ids) if exclude_ids.any?

    include_ids = Array(rule["include_ids"]).map(&:to_i)
    scope = scope.or(PromptSource.where(id: include_ids)) if include_ids.any?
    scope
  end

  # Apply the optional size cap. When the rule caps the set below the matched
  # count, a deterministic sample is taken (splitmix64 seeded from the rule's
  # own canonical bytes) and every trimmed row is recorded as omitted with the
  # reason. Without a cap the set is returned whole, in sorted order.
  def apply_cap(sorted_ids)
    cap = rule["cap"].to_i
    return [ sorted_ids, [] ] unless cap.positive? && sorted_ids.size > cap

    seed = Digest::SHA256.digest(canonical_rule).unpack1("Q>")
    rng = Splitmix64.new(seed)
    # Fisher-Yates over the sorted ids with the deterministic PRNG: a uniform
    # sample that depends only on the rule and the matched set, never on row
    # iteration order or process hash seed.
    ids = sorted_ids.dup
    (ids.size - 1).downto(cap) do |i|
      j = rng.next_float * (i + 1)
      j = j.to_i.clamp(0, i)
      ids[i], ids[j] = ids[j], ids[i]
    end
    kept = ids.first(cap).sort
    dropped = (sorted_ids - kept).sort
    omitted = dropped.map do |id|
      { "id" => id, "reason" => "trimmed by size cap #{cap} (deterministic sample)" }
    end
    [ kept, omitted ]
  end

  # The rule as canonical bytes, for seeding. Sorted keys so two rules that
  # differ only in key order seed identically — the rule's MEANING is the seed.
  def canonical_rule
    JSON.generate(rule.sort.to_h)
  end

  # --- reading -------------------------------------------------------------

  # The rows this view resolved to, in deterministic (sorted id) order. Empty
  # until built.
  def sources
    return PromptSource.none if source_ids.blank?

    PromptSource.where(id: source_ids).order(:id)
  end

  # Draw `count` prompts from this view deterministically (splitmix64 seeded
  # from the view's name + its sorted ids), so a draw is repeatable. Falls back
  # to the whole set when count exceeds it.
  def draw(count = 1)
    rows = sources.to_a
    return [] if rows.empty?

    count = count.clamp(1, rows.size)
    seed = Digest::SHA256.digest("#{name}|#{source_ids.join(',')}").unpack1("Q>")
    rng = Splitmix64.new(seed)
    picked = []
    pool = rows.dup
    count.times do
      idx = (rng.next_float * pool.size).to_i.clamp(0, pool.size - 1)
      picked << pool.delete_at(idx)
    end
    picked
  end

  # The manifest's omitted-with-reason list — what the view left out and why.
  def omitted
    manifest["omitted"] || []
  end

  # Whether a rebuild over an unchanged library would yield the same set: true
  # when the stored source_ids equal what a fresh build now produces. A cheap
  # staleness check for re-ingest.
  def stale?
    fresh = base_scope.order(:id).pluck(:id)
    fresh, = apply_cap(fresh)
    fresh.sort != source_ids.sort
  end
end
