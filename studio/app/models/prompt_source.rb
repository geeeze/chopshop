require "digest"

# A prompt from a public dataset, kept with the provenance and the coordinates
# that make it usable rather than decorative.
#
# THREE READERS, one row, and that is the reason this is a record and not a file:
#
#   * the LIBRARY page browses and filters it (by dataset, topic, phrase root,
#     and a text search), and draws its MAP from `x`/`y`;
#   * the RUN JOB form can take one and generate from it FOR REAL — the author's
#     own seed/step/guidance/sampler travel with it, so what the box generates is
#     the same request the dataset recorded;
#   * the JSON twin (`/library.json`) serves the same rows to an agent.
#
# The licence and the attribution are COLUMNS because a prompt is somebody's
# work: a row that cannot say where it came from cannot be used, and DiffusionDB
# is CC0 while its prompts are still other people's sentences.
class PromptSource < ActiveRecord::Base
  # The one place the dataset's identity is spelled. A second dataset would add
  # its name here and its own licence/attribution, which is what the columns are
  # for.
  DATASETS = {
    "diffusiondb" => {
      "licence" => "CC0-1.0",
      "attribution" => "DiffusionDB (poloclub), CC0-1.0 — prompts by Stable Diffusion users"
    }
  }.freeze

  validates :dataset, :prompt, presence: true
  validates :dataset, inclusion: { in: DATASETS.keys }

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :mapped, -> { where.not(x: nil).where.not(y: nil) }
  scope :for_dataset, ->(name) { where(dataset: name.to_s) }

  # A row's identity under cleaning: the prompt's own bytes. Taken at creation
  # like every other checksum here, so the same sentence ingested twice is
  # findable as one thing.
  before_validation :stamp_prompt_sha

  # The prompt is stored as the sentence it is: outer whitespace stripped, runs
  # of newlines and spaces collapsed to one space. A dataset's prompt arrives
  # with line breaks and trailing spaces (its authors typed them), and a prompt
  # that goes to the generator with a trailing newline is a different request than
  # the one that was recorded — so the NORMALISED text is what is stored, hashed
  # and handed over.
  before_validation :normalize_prompt

  # DiffusionDB stores `sampler` as a NUMERIC CODE, and its own loader maps that
  # code to a name before anyone sees it (`_SAMPLER_DICT` in the dataset's
  # `scripts/diffusiondb.py`). The studio keeps the CODE, because that is what the
  # dataset recorded, and resolves it to the name the generator needs.
  #
  # PINNED, NOT TRUSTED — the same rule the MET-Meme vocabulary and the pipeline's
  # ML constants follow. `test/fixtures/diffusiondb_samplers.json` is GENERATED
  # from the source by `bin/generate-sampler-fixture`, and the pin test compares
  # this transcription against it. A name typed here by hand would be free to lie
  # about what the dataset's code 8 means.
  SAMPLER_CODES = {
    "1" => "ddim",
    "2" => "plms",
    "3" => "k_euler",
    "4" => "k_euler_ancestral",
    "5" => "ddik_heunm",
    "6" => "k_dpm_2",
    "7" => "k_dpm_2_ancestral",
    "8" => "k_lms",
    "9" => "others"
  }.freeze

  # The sampler's NAME. Answers nil for a code the source does not define, so a
  # caller decides what to do rather than being handed a guess — and answers the
  # value unchanged when it is already a name (a row an operator made by hand).
  def sampler_name
    raw = sampler.to_s.strip
    return nil if raw.empty?

    SAMPLER_CODES[raw] || (SAMPLER_CODES.value?(raw) ? raw : nil)
  end

  # The prompt as it is stored, hashed and handed over: one line, outer space
  # gone. ONE reader for the rule, so a record that has not been saved yet hands
  # over the same text a saved one does — an unsaved row still goes to the
  # generator.
  def normalized_prompt
    prompt.to_s.gsub(/\s+/, " ").strip
  end

  # The prompt as a generation request: the author's hyperparameters under the
  # keys the flux service's contract takes, with nothing invented. A field the
  # dataset did not record is simply absent rather than defaulted here — the
  # service's own defaults are the ones that should apply.
  #
  # The sampler travels as its NAME (the service takes a name) and the code stays
  # in the row, so the request is usable and the provenance is intact.
  def generation_settings
    {
      "prompt" => normalized_prompt,
      "seed" => seed,
      "steps" => steps,
      "guidance" => guidance,
      "sampler" => sampler_name,
      "width" => width,
      "height" => height
    }.reject { |_key, value| value.nil? }
  end

  # What a reader is told about where this came from, in one sentence.
  def provenance
    bits = [DATASETS.dig(dataset, "attribution") || dataset]
    bits << part if part.present?
    bits.compact.join(" · ")
  end

  # The one-line preview a table cell shows: the prompt, flattened and cut. Cut
  # on a WORD so the ellipsis never lands inside one.
  def summary(limit = 150)
    text = prompt.to_s.gsub(/\s+/, " ").strip
    return text if text.length <= limit

    "#{text[0, limit].sub(/\s+\S*\z/, "")}…"
  end

  # The row as the JSON twin serves it: the provenance, the prompt, the
  # hyperparameters, and the placement. `as_json` is left alone so a caller can
  # ask for the record's own columns; this is the CONTRACT shape.
  def to_contract
    {
      "id" => id,
      "dataset" => dataset,
      "licence" => licence,
      "part" => part,
      "image_name" => image_name,
      "prompt" => prompt,
      "prompt_sha" => prompt_sha,
      "settings" => generation_settings.except("prompt"),
      "topic" => topic,
      "phrase_root" => phrase_root,
      "x" => x,
      "y" => y
    }
  end

  # A BULK write that still obeys this model's own rules.
  #
  # `insert_all` runs no callbacks, so the fast path would store rows with no
  # checksum and unnormalised text — the two things this model exists to
  # guarantee. So the rules are applied HERE, once, and a caller with 60,000 rows
  # uses this rather than reaching for `insert_all` itself.
  #
  # Every row gets every key the batch uses: `insert_all` builds ONE statement,
  # so a row missing a key is a row the insert refuses outright ("all objects
  # being inserted must have the same keys") rather than a null — which is how a
  # half-enriched ingest fails at the last step instead of the first.
  def self.ingest(rows, slice: 500)
    stamped = Array(rows).map do |row|
      text = row[:prompt].to_s.gsub(/\s+/, " ").strip
      # The checksum is of the NORMALISED text, exactly as the model's own
      # callback takes it — one rule, whether the row goes in one at a time or
      # sixty thousand at a time.
      row.merge(prompt: text, prompt_sha: Digest::SHA256.hexdigest(text),
                created_at: Time.current, updated_at: Time.current)
    end
    keys = stamped.flat_map(&:keys).uniq
    written = 0

    stamped.each_slice(slice) do |batch|
      insert_all(batch.map { |row| keys.to_h { |key| [key, row.key?(key) ? row[key] : nil] } })
      written += batch.size
    end
    written
  end

  # --- the three questions the library is asked -----------------------------
  # One prompt, drawn at random, optionally restricted. `random` rather than
  # `sample` because the row is chosen by the DATABASE, so it is uniform over a
  # table far larger than anything that should be loaded to pick one row.
  def self.draw(dataset: nil, topic: nil, phrase_root: nil)
    scope = dataset.present? ? for_dataset(dataset) : all
    scope = scope.where(topic: topic) if topic.present?
    scope = scope.where(phrase_root: phrase_root) if phrase_root.present?
    scope.order(Arel.sql("RANDOM()")).first
  end

  # The counts a reader needs to trust that the library is populated: how many
  # rows, over how many datasets and parts, mapped and unmapped.
  def self.census
    {
      "total" => count,
      "datasets" => group(:dataset).count,
      "parts" => distinct.count(:part),
      "mapped" => mapped.count,
      "topics" => where.not(topic: nil).distinct.count(:topic),
      "roots" => where.not(phrase_root: nil).distinct.count(:phrase_root),
      "licences" => distinct.pluck(:licence).compact.sort
    }
  end

  # The MAP: the dataset's own 2-D projection, one series per topic, each series
  # a list of {x, y} points. Shaped here rather than in the view because the
  # drawing service takes exactly this and a second shaping would drift.
  #
  # TWO caps, and both are load-bearing:
  #
  #   * `per_topic` — points per SERIES, not per library. A series that drew fewer
  #     points than its neighbours would read as a sparser region rather than as a
  #     sample.
  #   * `top` — how many topics get a series of their OWN. The library's topic
  #     labels are descriptive slugs, not a tidy taxonomy: 60,000 prompts carry
  #     NINE THOUSAND of them, and a legend with 9,632 entries is not a map. The
  #     most populous topics are named and the remainder is folded into ONE
  #     "other topics" series, so the drawing stays readable and the count it
  #     stands for is stated rather than hidden.
  def self.map_series(per_topic: 400, top: 12)
    groups = mapped.group(:topic).count.sort_by { |_topic, n| -n }
    named = groups.first(top)
    rest = groups.drop(top)

    series = named.filter_map { |topic, _count| series_for(topic, per_topic) }
    if rest.any?
      others = mapped.where(topic: rest.map(&:first))
                     .order(Arel.sql("RANDOM()"))
                     .limit(per_topic)
                     .pluck(:x, :y)
      unless others.empty?
        series << { "name" => "other topics (#{rest.size})",
                    "points" => others.map { |x, y| { "x" => x.to_f.round(3), "y" => y.to_f.round(3) } } }
      end
    end
    series
  end

  # One topic's sample, or nil when it has no points to draw.
  def self.series_for(topic, per_topic)
    points = mapped.where(topic: topic)
                   .order(Arel.sql("RANDOM()"))
                   .limit(per_topic)
                   .pluck(:x, :y)
    return nil if points.empty?

    { "name" => topic.to_s.presence || "unlabelled",
      "points" => points.map { |x, y| { "x" => x.to_f.round(3), "y" => y.to_f.round(3) } } }
  end

  private

  def normalize_prompt
    return if prompt.nil?

    self.prompt = normalized_prompt
  end

  def stamp_prompt_sha
    return if normalized_prompt.empty?

    # The checksum is of the NORMALISED text — the same reader the stored value
    # and the generation request use. Hashing the raw text instead gave one
    # sentence two identities depending on the whitespace it arrived with, which
    # defeats the point of a checksum: "the same prompt twice" has to be one row.
    self.prompt_sha ||= Digest::SHA256.hexdigest(normalized_prompt)
  end
end
