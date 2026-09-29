require "test_helper"

# MET-Meme's vocabulary is somebody else's schema, and this suite is the PIN on
# the transcription.
#
# The rule it enforces is the one that governs the pipeline's ML constants too
# (see runner_conf_drift_test): a hand-typed copy of an external schema is free
# to lie about it, and the lie is invisible until a reader trusts a label the
# source does not define. `test/fixtures/meme_vocabulary.json` is GENERATED from
# the source's own README by `bin/generate-meme-vocabulary-fixture`; the first
# test compares this module against it field for field. When the source changes,
# re-run the generator and review the diff — never edit the fixture to match the
# code.
class MemeVocabularyTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test", "fixtures", "meme_vocabulary.json")

  def fixture
    @fixture ||= JSON.parse(FIXTURE.read)
  end

  # --- the pin ---------------------------------------------------------------

  test "every field the source defines is transcribed, with the source's own values" do
    pinned = fixture.fetch("fields")
    assert_equal pinned.keys.sort, MemeVocabulary.field_names.sort,
                 "the module and the source disagree about which fields exist"

    pinned.each do |name, spec|
      mine = MemeVocabulary.field(name)
      assert_equal spec["kind"], mine["kind"], "#{name}: kind"

      if spec["kind"] == "phrase"
        assert_equal spec["shape"], mine["shape"], "#{name}: the shape the source constrains it to"
        next
      end

      # The ordinals are the dataset's own coding, so they are compared as
      # strings: JSON keys arrive as strings and the dataset numbers from 0 or 1
      # depending on the field, which is exactly what a loose comparison would
      # paper over.
      assert_equal spec["values"], mine["values"].transform_keys(&:to_s),
                   "#{name}: the values the source defines"
    end
  end

  test "the source's counts are transcribed" do
    assert_equal fixture.dig("source", "pairs"), MemeVocabulary::SOURCE["pairs"]
    assert_equal fixture.dig("source", "images"), MemeVocabulary::SOURCE["images"]
  end

  test "the citation travels with the vocabulary" do
    source = MemeVocabulary::SOURCE
    assert_match(/MET-Meme/, source["dataset"])
    assert_match(%r{github\.com/liaolianfoka/}, source["repo"])
    assert_match(/kaggle\.com/, source["images_url"])
    assert_equal fixture.dig("source", "images_url"), source["images_url"],
                 "the download link is transcribed from the source too"
    assert_match(/SCHEME only/, source["transcribed"],
                 "a reader must be told that the images are NOT here")
  end

  # --- the validator ---------------------------------------------------------

  test "a value is accepted as the source's ordinal, as its word, or in any casing" do
    { "sentiment" => 3, "intention" => "Purely Entertaining",
      "metaphor_occurrence" => "1", "offensiveness" => "VERY OFFENSIVE" }.each do |field, value|
      assert MemeVocabulary.valid?(field, value), "#{field} should accept #{value.inspect}"
    end
  end

  test "a value the source does not define is refused" do
    refute MemeVocabulary.valid?("sentiment", 9)
    refute MemeVocabulary.valid?("sentiment", "bemusement")
    refute MemeVocabulary.valid?("intention", "0"),
           "the source numbers intention from 1, so 0 is not a value of it"
    refute MemeVocabulary.valid?("metaphor_occurrence", 2)
  end

  test "the word for a value is the same whichever form it arrived in" do
    assert_equal "anger", MemeVocabulary.word("sentiment", 3)
    assert_equal "anger", MemeVocabulary.word("sentiment", "3")
    assert_equal "anger", MemeVocabulary.word("sentiment", "Anger")
    assert_nil MemeVocabulary.word("sentiment", 42)
  end

  test "a domain is a phrase, checked by shape rather than by a list" do
    assert MemeVocabulary.valid?("source_domain", "heavy heart")
    assert MemeVocabulary.valid?("target_domain", "crushing weight")
    refute MemeVocabulary.valid?("source_domain", "heart"),
           "one word is not the adj + n / verb + n shape the source constrains it to"
  end

  # --- the check, which reports EVERY refusal ---------------------------------

  test "check re-words what it accepts and names everything it refused" do
    result = MemeVocabulary.check(
      "metaphor_occurrence" => 1,
      "sentiment" => "hate",
      "intention" => "sideways",
      "nonsense_field" => "whatever",
      "offensiveness" => nil
    )

    assert_equal({ "metaphor_occurrence" => "metaphorical meme", "sentiment" => "hate" },
                 result["annotation"])
    assert_equal 2, result["refused"].size,
                 "one refusal per bad label, not just the first"
    assert_includes result["refused"].map { |r| r["field"] }, "intention"
    assert_includes result["refused"].map { |r| r["field"] }, "nonsense_field"
    assert_match(/interactive/, result["refused"].find { |r| r["field"] == "intention" }["why"],
                 "the refusal says what WOULD have been accepted")
    refute result["annotation"].key?("offensiveness"), "a blank label is not an annotation"
  end

  test "the contract the page and the JSON twin both read is the vocabulary itself" do
    contract = MemeVocabulary.to_contract
    assert_equal MemeVocabulary.field_names, contract["fields"].map { |f| f["name"] },
                 "the contract lists the fields in the source's own order"
    assert_equal fixture.dig("source", "pairs"), contract.dig("source", "pairs")

    sentiment = contract["fields"].find { |f| f["name"] == "sentiment" }
    assert_equal 7, sentiment["values"].size
    assert_includes sentiment["values"], { "value" => 3, "label" => "anger" }
  end
end
