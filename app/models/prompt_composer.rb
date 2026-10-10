# The STRUCTURED PROMPT COMPOSER (issue #50) — a generation prompt built from
# N DYNAMIC SLOTS, each mixing free user input with dropdown-selected
# boilerplate and optional dataset prompts, combined into ONE prompt at job
# time.
#
# THE DEFAULT LAYOUT is thing / location / style — three free-text slots — but
# that is only a STARTING POINT. Slots are dynamic: adding and removing them
# is a UI action, not a migration. The composer never assumes a fixed count.
#
# THREE SLOT KINDS, one slot hash each:
#
#   * FREE TEXT   — { text: "a woodcut phoenix emblem" }
#   * BOILERPLATE — { boilerplate: "woodcut" }  (resolved from BOILERPLATE)
#   * DATASET     — { dataset_id: 123 }        (resolved from PromptSource)
#
# At job time the controller normalizes the posted slots (resolving boilerplate
# keys and dataset ids) and composes them into ONE prompt string. The slot
# structure is recorded in spec["prompt_slots"] so the form can hydrate it
# back — a hand-edited contract still wins, but the slots are the source of
# truth for the form.
#
# The BOILERPLATE vocabulary follows the MemeVocabulary / FluxConf pattern: a
# frozen hash, one source of truth, never re-typed in the view. The dataset
# handoff follows the datasets#use / SessionDraft pattern: a drawn prompt is
# stored as a draft and the form reads it by token.
class PromptComposer
  # The controlled BOILERPLATE vocabulary — the '+' dropdown options. Each
  # value is a prompt SUFFIX (the styles.json pattern: a comma-led fragment
  # that extends a subject with a style or technique). Keys are stable slugs;
  # values are the text a selection contributes to the composed prompt.
  #
  # PINNED, like every other vocabulary in this app: a name here that drifts
  # from what the operator expects is worse than no name at all. The keys are
  # the dataset's own words where one exists (the trace presets bw / poster /
  # photo are the pipeline's), and descriptive slugs otherwise.
  BOILERPLATE = {
    "woodcut" => ", woodcut print, bold black outlines, high contrast, two inks",
    "screenprint" => ", screenprint, flat color, limited palette, poster",
    "sticker" => ", die-cut sticker, thick outline, white background",
    "pixel-art" => ", 8-bit pixel art, crisp pixels, limited palette",
    "line-art" => ", clean line art, single-weight outline, no shading",
    "photo" => ", photographic, soft gradients, detailed",
    "logo" => ", minimal logo mark, flat fill, hard edges",
    "colour-palette" => ", colouring book page, black outline, unfilled",
  }.freeze

  # The DEFAULT slot layout: thing / location / style. Three free-text slots,
  # each a labelled starting point. This is the form's initial state, not a
  # fixed structure — the operator adds and removes slots freely.
  DEFAULT_SLOTS = [
    { "label" => "thing", "placeholder" => "a woodcut phoenix emblem" },
    { "label" => "location", "placeholder" => "on a cliff at dawn" },
    { "label" => "style", "placeholder" => "two inks, high contrast" },
  ].freeze

  # Compose N slots into ONE prompt string. Blank slots are dropped. The
  # join is ", " so the parts read as one sentence. A single non-blank slot
  # composes to its own text with no leading comma.
  #
  # Each slot is a hash with one of:
  #   { "text" => "free input" }
  #   { "boilerplate" => "woodcut" }
  #   { "dataset_id" => 123, "prompt" => "the drawn prompt" }
  #
  # The "prompt" key on a dataset slot is the ALREADY-RESOLVED text (looked
  # up by normalize); compose does not touch the database.
  def self.compose(slots)
    Array(slots).filter_map { |slot| slot_text(slot) }.join(", ").strip
  end

  # Normalize a POSTed slots array into clean slot hashes. Each posted slot
  # is a hash with one of text / boilerplate / dataset_id; anything malformed
  # (not a hash, an unknown boilerplate key, a missing dataset) is DROPPED
  # rather than guessed at — a slot that cannot resolve is not a slot.
  #
  # Boilerplate keys are validated against the BOILERPLATE vocabulary; dataset
  # ids are looked up from PromptSource and the resolved prompt is embedded
  # under "prompt" so compose never touches the database.
  def self.normalize(raw_slots)
    Array(raw_slots).map do |raw|
      next nil unless raw.is_a?(Hash)

      if raw["text"].present?
        { "text" => raw["text"].to_s.strip }
      elsif raw["boilerplate"].present?
        key = raw["boilerplate"].to_s
        BOILERPLATE.key?(key) ? { "boilerplate" => key } : nil
      elsif raw["dataset_id"].present?
        source = PromptSource.find_by(id: raw["dataset_id"])
        source ? { "dataset_id" => source.id, "prompt" => source.normalized_prompt } : nil
      end
    end.compact
  end

  # The text a single slot contributes to the composed prompt. Returns nil for
  # a blank or unresolvable slot so compose drops it.
  def self.slot_text(slot)
    return nil unless slot.is_a?(Hash)

    if slot["text"].present?
      slot["text"].to_s.strip
    elsif slot["boilerplate"].present?
      BOILERPLATE[slot["boilerplate"]].to_s.strip
    elsif slot["dataset_id"].present?
      slot["prompt"].to_s.strip
    end
  end

  # The boilerplate options as [key, label] pairs for a select or dropdown.
  # The label is the key humanized, so the vocabulary is the only source of
  # both the value and what the operator sees.
  def self.boilerplate_options
    BOILERPLATE.keys.map { |key| [key, key.humanize] }
  end

  # The DATASETS a slot may draw from, as [name, label] pairs — the library's
  # own dataset keys (PromptSource::DATASETS), never a re-typed list. The
  # 'dataset-in' option reveals the chosen dataset and the prompt drawn from
  # it; this is the dataset half of that reveal.
  def self.dataset_options
    PromptSource::DATASETS.keys.map { |key| [key, key.humanize] }
  end
end
