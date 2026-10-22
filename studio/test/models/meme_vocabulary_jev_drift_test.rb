require "test_helper"

# THE CROSS-VOCABULARY PIN: MET-Meme's annotation scheme is transcribed TWICE
# in this system — once in `app/lib/meme_vocabulary.rb` (the studio's labels,
# ordinals and validate gate, itself pinned against the source README via
# test/fixtures/meme_vocabulary.json) and once in chopshop-jev's
# `scripts/jev_annotate.py` MEME_QUESTIONS (the 'dataset-translation' profile's
# question set). Two renderings of one vocabulary are free to drift apart
# silently: neither repo's own tests look across, and a criterion the annotator
# asks about a label the studio does not define (or the reverse) reads as
# perfectly normal on both sides until somebody trusts it.
#
# The annotator is READ, never imported — the same one-way convention
# jev_help_test follows, and for the same reason: the studio's suite must not
# depend on the sibling's Python stack, and a text read keeps the pin honest
# about drift. The annotator's own header says the two sides are one
# vocabulary; this file is what makes that true.
#
# The two sides render the SAME words differently, and the mapping is pinned
# here rather than papered over:
#
#   studio  MemeVocabulary.labels(field) -> [[0, "literal meme"], ...]
#           ordinals are the dataset's own numbering; the word is the label.
#   jev     MEME_QUESTIONS[field]["criteria"] -> {"literal_meme" => "..."}
#           the identifier is the SAME WORD, lowercased with spaces and
#           hyphens underscored — "non-offensive" -> "non_offensive",
#           "purely entertaining" -> "purely_entertaining". The criteria VALUES
#           are the annotator's own explanations of what a label means and are
#           deliberately NOT compared: they are prose about the label, not the
#           label.
#
# And the two sides intentionally DIFFER, which is pinned below rather than
# excused: the annotator does not ask the two phrase fields (its service has no
# free-text type, documented against UNSUPPORTED_QUESTION_TYPES), and it asks
# one question of its own that is not MET-Meme's vocabulary at all. A field
# appearing on either side outside these pinned sets is drift, and the failure
# names which side it came from.
class MemeVocabularyJevDriftTest < ActiveSupport::TestCase
  ANNOTATOR = Rails.root.parent.join("chopshop-jev/scripts/jev_annotate.py")

  # Fields the studio transcribes that the annotator deliberately does NOT ask,
  # each with the measured reason for its absence (the annotator's own comment
  # over MEME_QUESTIONS, checked live below). Their absence is pinned: a
  # transcript field that quietly stops being asked, or one that starts being
  # asked without becoming a choice field, is drift this map would otherwise
  # absorb silently.
  STUDIO_ONLY = {
    "source_domain" => "a phrase field — the annotator's service answers choice/score/noul only, so a free-text answer is not a type it has",
    "target_domain" => "the same measured limit: shape-constrained free text, not an enumeration"
  }.freeze

  # Questions the annotator asks that are NOT MET-Meme's vocabulary: they are
  # the annotator's own, about its own state, and must never be counted as
  # dimensions of the dataset's scheme. `evidence_is_actionable` asks whether a
  # label is possible at all given what evidence the state has — a noul, and a
  # question MET-Meme never posed.
  JEV_ONLY = {
    "evidence_is_actionable" => "the annotator's own noul question about whether a label can be given at all — not a dimension of MET-Meme's scheme"
  }.freeze

  def annotator
    @annotator ||= ANNOTATOR.read
  end

  def meme_questions_body
    annotator[/^MEME_QUESTIONS: dict\[str, dict\[str, Any\]\] = \{\n(.*?)^\}\n/m, 1]
  end

  def annotator_question_block(key)
    body = meme_questions_body or return nil
    body[/^    "#{key}": \{\n(.*?)^    \},?\n/m, 1]
  end

  # The field keys of MEME_QUESTIONS, in the order the annotator asks them.
  def annotator_meme_keys
    body = meme_questions_body or return []
    body.scan(/^    "([a-z_]+)": \{\n/).flatten
  end

  def annotator_type(key)
    (annotator_question_block(key) || "")[/"type":\s*"([^"]+)"/, 1]
  end

  # The criteria KEYS of one question, in the order they are written. The
  # VALUES are the annotator's own prose about each label and are not part of
  # the shared vocabulary.
  def annotator_criteria_keys(key)
    block = annotator_question_block(key) or return nil
    hash_body = block[/"criteria": \{\n(.*?)^        \},/m, 1] or return nil
    hash_body.scan(/^\s*"([a-z_]+)":\s*"/).flatten
  end

  # The one mapping the two renderings share: MET-Meme's label word, lowercased
  # with spaces and hyphens underscored. The mapping is the TEST's — neither
  # side claims it — which is exactly why it is written down and exercised
  # rather than discovered at runtime.
  def annotator_key_for(word)
    word.to_s.downcase.gsub(/[\s\-]/, "_")
  end

  # The fields both sides render: MET-Meme's choice dimensions, each asked by
  # the annotator and transcribed by the studio.
  def shared_fields
    MemeVocabulary.field_names - STUDIO_ONLY.keys
  end

  test "the annotator is where the cross-vocabulary pin is read from, and names this module as its other rendering" do
    assert ANNOTATOR.exist?, "jev_annotate.py not found at #{ANNOTATOR}"
    assert_not_nil meme_questions_body,
      "MEME_QUESTIONS is not where jev_annotate.py is expected to define it"

    # The annotator's own header claims app/lib/meme_vocabulary.rb is the other
    # rendering of this vocabulary. That claim is what this file pins; if the
    # sibling stops naming the studio module, the pin's premise moved.
    header = annotator[/^# MET-Meme's annotation scheme.*?(?=^MEME_QUESTIONS)/m]
    assert_match(/meme_vocabulary\.rb/, header,
      "the annotator no longer names the studio module as the other rendering of this vocabulary")
  end

  # ---- studio -> jev: a field the studio transcribes must be asked --------

  test "every MET-Meme field the studio transcribes is asked by the annotator, except the two pinned phrase fields" do
    asked = annotator_meme_keys
    (MemeVocabulary.field_names - STUDIO_ONLY.keys).each do |field|
      assert_includes asked, field,
        "STUDIO SIDE DRIFT: MemeVocabulary transcribes #{field.inspect} (a MET-Meme " \
        "dimension) but jev's MEME_QUESTIONS no longer asks it — the annotator and the " \
        "studio now render two different vocabularies. If its absence is now intentional, " \
        "record the reason in STUDIO_ONLY; otherwise restore the question in the annotator."
    end
  end

  # ---- jev -> studio: a question must name a field the studio defines -----

  test "the annotator asks no MET-Meme field the studio does not transcribe, except the pinned question of its own" do
    (annotator_meme_keys - JEV_ONLY.keys).each do |key|
      assert_not_nil MemeVocabulary.field(key),
        "JEV SIDE DRIFT: jev's MEME_QUESTIONS asks #{key.inspect} about a field " \
        "app/lib/meme_vocabulary.rb does not transcribe — the annotator would label an " \
        "artifact against a dimension the studio has no labels for. If it is a MET-Meme " \
        "dimension, transcribe it in MemeVocabulary; if it is the annotator's own, record " \
        "it in JEV_ONLY."
    end
  end

  # ---- key for key: the criteria are the studio's own labels --------------

  test "each shared field's criteria keys are the studio's label words, in the dataset's own order" do
    shared_fields.each do |field|
      spec = MemeVocabulary.field(field)
      assert_equal "choice", spec["kind"],
        "#{field}: a shared field is a choice field on the studio side; a phrase field " \
        "belongs in STUDIO_ONLY, not in the shared set"
      assert_equal "choice", annotator_type(field),
        "#{field}: the studio transcribes it as a choice field but the annotator asks it " \
        "as #{annotator_type(field).inspect} — one vocabulary, two kinds"

      expected = MemeVocabulary.labels(field).map { |_ordinal, word| annotator_key_for(word) }
      actual = annotator_criteria_keys(field)
      assert_equal expected, actual,
        "#{field}: the annotator's criteria keys are not MET-Meme's label words in the " \
        "dataset's order — expected #{expected.inspect} (the studio's labels " \
        "#{MemeVocabulary.labels(field).map(&:last).inspect}), the annotator asks " \
        "#{actual.inspect}. One vocabulary, two renderings: a criterion with no label is a " \
        "label the annotator would return that the studio cannot validate."
    end
  end

  # ---- the intentional differences, pinned rather than excused ------------

  test "the two studio-only fields are phrase fields, and the annotator says so" do
    STUDIO_ONLY.each_key do |field|
      assert_equal "phrase", MemeVocabulary.field(field)["kind"],
        "#{field}: only a phrase field may be absent from the annotator by this pin; a " \
        "choice field absent from it is drift"
      assert_nil annotator_question_block(field),
        "#{field}: the annotator asks it after all — remove it from STUDIO_ONLY or it is no longer pinned"
    end

    # The reason is measured, not assumed: the annotator documents the limit
    # against UNSUPPORTED_QUESTION_TYPES. If that measurement disappears, the
    # absence stops being a documented gap and becomes an oversight.
    assert_match(/UNSUPPORTED_QUESTION_TYPES/, annotator,
      "the annotator no longer documents why it cannot ask the phrase fields")
    absent_note = annotator[/^    # MET-Meme's `source_domain`.*?(?=    "source_modality")/m]
    assert_match(/source_domain/, absent_note.to_s,
      "the annotator no longer says which fields of the scheme it cannot ask for")
  end

  test "the annotator's own question is a noul and not MET-Meme's vocabulary" do
    JEV_ONLY.each do |key, reason|
      block = annotator_question_block(key)
      assert_not_nil block, "#{key}: the annotator no longer asks #{key.inspect} — #{reason}"
      assert_equal "noul", annotator_type(key),
        "#{key}: the annotator's own question is asked as #{annotator_type(key).inspect}, " \
        "not the noul this pin recorded"
      assert_nil MemeVocabulary.field(key),
        "#{key}: this question is the annotator's own, not MET-Meme's — it must not become " \
        "a field of the studio's transcription of the dataset's scheme"
    end
  end
end
