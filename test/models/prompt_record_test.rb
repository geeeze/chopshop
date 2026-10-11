require "test_helper"

# The prompt recall list: what an operator has filed before.
class PromptRecordTest < ActiveSupport::TestCase
  test "a filed prompt is remembered with its origin" do
    record = PromptRecord.remember!("a woodcut phoenix emblem", source: "typed", job_id: 42)

    refute_nil record
    assert_equal "a woodcut phoenix emblem", record.prompt
    assert_equal "typed", record.source
    assert_equal 1, record.uses_count
    assert_equal 42, record.job_id
    refute_nil record.last_used_at
  end

  test "the same prompt is counted, not duplicated" do
    first = PromptRecord.remember!("a woodcut phoenix emblem")
    second = PromptRecord.remember!("a woodcut phoenix emblem")

    assert_equal first.id, second.id, "refiling one prompt must update its row, not add a twin"
    assert_equal 1, PromptRecord.count
    assert_equal 2, second.reload.uses_count
  end

  # Whitespace around a prompt is an accident of pasting, not a different prompt.
  test "a re-paste with different spacing is the same prompt" do
    PromptRecord.remember!("a woodcut phoenix emblem")
    PromptRecord.remember!("  a woodcut phoenix emblem\n")

    assert_equal 1, PromptRecord.count
  end

  test "a blank prompt is ignored rather than stored or raised" do
    assert_nil PromptRecord.remember!("")
    assert_nil PromptRecord.remember!("   \n  ")
    assert_nil PromptRecord.remember!(nil)
    assert_equal 0, PromptRecord.count
  end

  # The dedupe is keyed on a digest, so a prompt longer than a string column is
  # still one row -- and still the whole prompt, not a truncated one.
  test "a long prompt is kept whole and still deduped" do
    long = "a " + ("very detailed rendering of a phoenix emblem, " * 40)
    assert long.length > 255, "this test is only meaningful past a string column"

    first = PromptRecord.remember!(long)
    second = PromptRecord.remember!(long)

    assert_equal first.id, second.id
    assert_equal long.strip, first.reload.prompt,
      "the prompt must be recalled at full length (only the enclosing whitespace is trimmed)"
  end

  test "the list is most-recently-used first" do
    stale = PromptRecord.remember!("an old prompt")
    fresh = PromptRecord.remember!("a new prompt")
    stale.update_columns(last_used_at: 2.days.ago)

    assert_equal [ fresh.id, stale.id ], PromptRecord.recent.map(&:id)
  end
end
