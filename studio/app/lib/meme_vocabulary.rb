# MET-Meme's ANNOTATION VOCABULARY, transcribed — and the reason a transcription
# like this is worth having at all.
#
# MET-Meme annotates 10,039 text-image pairs in two languages with metaphor,
# sentiment, intention and offensiveness labels, and its scheme is the useful
# part: it is a meme-label vocabulary somebody else already argued about, so this
# studio does not get to invent one and call it a schema.
#
# WHAT THIS IS FOR, concretely, in this app: a meme artefact can CARRY an
# annotation — which of its parts contributes the meaning, what it is trying to
# do, how offensive it lands — and the labels have to come from somewhere with a
# citation. `validate` is the gate a record passes through, `labels` is what a
# form or a page offers, and `SOURCE` is what a reader is told.
#
# WHAT THIS IS NOT: the dataset's IMAGES. MET-Meme's images live on Kaggle behind
# its own terms, and its per-image labels are about those images, so this module
# transcribes the SCHEME and not the data. A label applied here is applied by
# this studio, using MET-Meme's words, and says so.
#
# PINNED, NOT TRUSTED — the same rule that governs the pipeline's ML constants
# (see Telemetry and runner_conf_drift_test): a hand-typed transcription of
# somebody else's schema is free to lie about it, and the lie is invisible until
# a reader trusts a label the source does not define. `test/fixtures/
# meme_vocabulary.json` is GENERATED FROM THE SOURCE's own README by
# `script/generate_meme_vocabulary_fixture.py`, and the pin test compares this
# transcription against it field for field. Re-run the generator when the source
# changes, never edit the fixture to match the code.
#
# The ML that reads these labels — the paper's multilingual BERT + VGG16/ResNet50
# classifier — deliberately lives NOWHERE here: studio computes no ML, exactly as
# it computes none of the pipeline's ranking. The boundary is stated in
# docs/SYSTEM.md.
module MemeVocabulary
  SOURCE = {
    "dataset" => "MET-Meme: A Multi-modal Meme Dataset Rich in Metaphors",
    "repo" => "https://github.com/liaolianfoka/MET-Meme-A-Multi-modal-Meme-Dataset-Rich-in-Metaphors",
    # `images` is how many images each language contributes; `images_url` is where
    # they live. Two different things with two different keys — sharing one key is
    # what made a page hand a Hash to `link_to`.
    "images" => { "Chinese" => 6_045, "English" => 3_994 },
    "images_url" => "https://www.kaggle.com/datasets/liaolianfoka/met-meme",
    "pairs" => 10_039,
    "transcribed" => "the annotation SCHEME only; the images and their per-image labels stay with the dataset"
  }.freeze

  # Every field the scheme defines, its values, and what the source says each
  # value means. Ordinals are the dataset's own numbering, kept because a
  # consumer of these labels reads numbers, not words.
  #
  #   kind — "choice" (one of a fixed list) or "phrase" (free text the source
  #          constrains by SHAPE rather than by a list: the source/target domains
  #          are "adj + n" or "verb + n", which is a rule, not an enumeration).
  FIELDS = {
    "metaphor_occurrence" => {
      "kind" => "choice",
      "question" => "is the meme literal or metaphorical",
      "values" => { 0 => "literal meme", 1 => "metaphorical meme" }
    },
    "metaphor_category" => {
      "kind" => "choice",
      "question" => "which modality carries the metaphor",
      "values" => { "complementary" => "complementary",
                    "text dominant" => "text dominant",
                    "image dominant" => "image dominant" }
    },
    "source_domain" => {
      "kind" => "phrase",
      "question" => "the domain the metaphor draws FROM",
      "shape" => %("adj + n" or "verb + n")
    },
    "target_domain" => {
      "kind" => "phrase",
      "question" => "the domain the metaphor points AT",
      "shape" => %("adj + n" or "verb + n")
    },
    "source_modality" => {
      "kind" => "choice",
      "question" => "which modality carries the source domain",
      "values" => { "complementary" => "complementary",
                    "text dominant" => "text dominant",
                    "image dominant" => "image dominant" }
    },
    "target_modality" => {
      "kind" => "choice",
      "question" => "which modality carries the target domain",
      "values" => { "complementary" => "complementary",
                    "text dominant" => "text dominant",
                    "image dominant" => "image dominant" }
    },
    "sentiment" => {
      "kind" => "choice",
      "question" => "the feeling the meme carries",
      "values" => { 1 => "happiness", 2 => "love", 3 => "anger", 4 => "sorrow",
                    5 => "fear", 6 => "hate", 7 => "surprise" }
    },
    "intention" => {
      "kind" => "choice",
      "question" => "what the meme is doing",
      "values" => { 1 => "interactive", 2 => "expressive", 3 => "purely entertaining",
                    4 => "offensive", 5 => "other" }
    },
    "offensiveness" => {
      "kind" => "choice",
      "question" => "how offensive it lands",
      "values" => { 0 => "non-offensive", 1 => "slightly offensive",
                    2 => "moderately offensive", 3 => "very offensive" }
    }
  }.freeze

  module_function

  # A RANDOM FIELD of meme entrants — the tournament template's "random seeds"
  # source. Names come from the scheme's own CHOICE words (metaphor, sentiment,
  # intention, modality, offensiveness): MET-Meme's vocabulary shuffled, kept
  # UNIQUE within the field because the sim scores from the NAME, so two
  # entrants sharing one would be a permanent tie. A field larger than the pool
  # cycles it with an ordinal.
  def random_entrants(count)
    pool = FIELDS.filter_map { |_name, spec| spec["values"] }
                .flat_map { |values| values.values.map(&:to_s) }.uniq.shuffle
    count = count.to_i.clamp(2, 32)
    Array.new(count) do |i|
      word = pool[i % pool.size]
      i < pool.size ? word : "#{word} #{(i / pool.size) + 1}"
    end
  end

  # The fields, in the order the source states them.
  def field_names
    FIELDS.keys
  end

  def field(name)
    FIELDS[name.to_s]
  end

  # The values a choice field accepts, in the source's own order — keyed by the
  # ordinal the dataset uses, worded as the source words them.
  def labels(name)
    values = field(name)["values"]
    values ? values.to_a : []
  end

  # The key a value names, whichever form it arrived in: the dataset's ordinal
  # (as a number or as its digits), or its word in any casing. ONE reader, so the
  # validator, the re-wording and the refusal messages cannot disagree about
  # whether "3" and 3 are the same label — which they are, and which is exactly
  # the comparison a hand-written transcription gets wrong.
  def key_for(name, value)
    values = field(name)["values"]
    return nil unless values

    raw = value.to_s.strip
    return value if value.is_a?(Integer) && values.key?(value)
    return raw.to_i if raw.match?(/\A\d+\z/) && values.key?(raw.to_i)
    return raw.downcase if values.key?(raw.downcase)

    values.find { |_key, word| word.to_s.downcase == raw.downcase }&.first
  end

  # Whether one value is one the source defines. A DOMAIN (a phrase field) is
  # checked by its SHAPE — the source constrains those two by form, not by a list
  # — and everything else by the key it names.
  def valid?(name, value)
    spec = field(name)
    return false unless spec

    if spec["kind"] == "phrase"
      value.to_s.strip.match?(/\A[\w'’\- ]+ +[\w'’\- ]+\z/)
    else
      !key_for(name, value).nil?
    end
  end

  # The word for a value, whichever form it arrived in: the dataset's ordinal or
  # its wording. The one place the two are reconciled, so a page and a validator
  # cannot disagree about what "3" means.
  def word(name, value)
    key = key_for(name, value)
    key.nil? ? nil : field(name)["values"][key]
  end

  # An annotation checked against the scheme. Returns the re-worded values plus
  # the fields that were refused, so a caller can report EVERY problem instead of
  # the first — a form that stops at one label per submit is a form an operator
  # fills in three times.
  def check(annotation)
    given = annotation.is_a?(Hash) ? annotation : {}
    accepted = {}
    refused = []

    given.each do |name, value|
      next if value.nil? || value.to_s.strip.empty?

      if field(name).nil?
        refused << { "field" => name.to_s, "value" => value.to_s, "why" => "not a field of this scheme" }
      elsif valid?(name, value)
        accepted[name.to_s] = word(name, value) || value.to_s.strip
      else
        accepted_words = labels(name).map(&:last)
        refused << { "field" => name.to_s, "value" => value.to_s,
                     "why" => "not one of #{accepted_words.join(', ')}" }
      end
    end

    { "annotation" => accepted, "refused" => refused,
      "fields" => given.keys.map(&:to_s) }
  end

  # The scheme as JSON: the source, the fields and their values. This is what the
  # page renders and what `/datasets/meme-labels.json` serves, from one place.
  def to_contract
    {
      "source" => SOURCE,
      "fields" => FIELDS.map do |name, spec|
        {
          "name" => name,
          "kind" => spec["kind"],
          "question" => spec["question"],
          "shape" => spec["shape"],
          "values" => (spec["values"] || {}).map { |key, word| { "value" => key, "label" => word } }
        }
      end
    }
  end
end
