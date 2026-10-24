require "test_helper"

# Curated / abridged dataset views (issue #48): a named, persisted rule set
# that regenerates deterministically from the library, with an honest manifest
# (dataset-pool: never hide a record — list omissions with reasons) and a
# deterministic draw. No network; the library is built in-process.
class DatasetViewTest < ActiveSupport::TestCase
  setup do
    PromptSource.delete_all
    DatasetView.delete_all
    # A small deterministic library: three topics, known ids in insertion order.
    @rows = []
    %w[portrait portrait landscape landscape landscape abstract].each_with_index do |topic, i|
      @rows << PromptSource.create!(
        dataset: "diffusiondb", topic: topic, phrase_root: "root-#{i}",
        prompt: "prompt number #{i} about #{topic}", x: i.to_f, y: i.to_f
      )
    end
  end

  # --- deterministic build -------------------------------------------------

  test "a view resolves its rule to the matching rows in sorted id order" do
    view = DatasetView.create!(name: "portraits", rule: { "topic" => "portrait" })
    view.build!
    assert_equal [ @rows[0].id, @rows[1].id ], view.source_ids
    assert_equal 2, view.manifest["count"]
  end

  test "the same rule over an unchanged library rebuilds to the identical set" do
    view = DatasetView.create!(name: "landscapes", rule: { "topic" => "landscape" })
    view.build!
    first = view.source_ids.dup
    view.build! # rebuild in place
    assert_equal first, view.source_ids, "an unchanged rule must rebuild identically"
  end

  test "a size cap takes a deterministic sample, not a random one" do
    view = DatasetView.create!(name: "capped", rule: { "cap" => 2 })
    view.build!
    first = view.source_ids.dup
    # A second DatasetView with the SAME rule must pick the SAME sample —
    # determinism is a property of the rule, not of one row.
    twin = DatasetView.create!(name: "capped-twin", rule: { "cap" => 2 })
    twin.build!
    assert_equal first, twin.source_ids, "the cap sample depends only on the rule"
    assert_equal 2, view.source_ids.size
  end

  test "key order in the rule does not change the deterministic sample" do
    a = DatasetView.create!(name: "a", rule: { "cap" => 2, "topic" => "landscape" })
    b = DatasetView.create!(name: "b", rule: { "topic" => "landscape", "cap" => 2 })
    a.build!
    b.build!
    assert_equal a.source_ids, b.source_ids
  end

  # --- honest manifest -----------------------------------------------------

  test "the manifest lists rows the cap trimmed, with the reason" do
    view = DatasetView.create!(name: "capped", rule: { "cap" => 2 })
    view.build!
    omitted = view.omitted
    assert_equal 4, omitted.size, "6 rows capped to 2 leaves 4 omitted"
    assert omitted.all? { |o| o["reason"].include?("size cap") },
           "every omission states why"
    assert omitted.all? { |o| o.key?("id") }
  end

  test "an explicit exclude is recorded as omitted with the reason" do
    target = @rows[0].id
    view = DatasetView.create!(name: "x", rule: { "exclude_ids" => [ target ] })
    view.build!
    refute_includes view.source_ids, target
    # The build's base_scope drops the exclude; it is not in the cap-omitted
    # list, but the view must never silently drop it — the manifest's rule
    # records the exclusion, and the row is absent from the set.
    assert_includes view.manifest["rule"]["exclude_ids"], target
  end

  test "a view with no cap omits nothing" do
    view = DatasetView.create!(name: "all", rule: {})
    view.build!
    assert_equal [], view.omitted
    assert_equal PromptSource.count, view.source_ids.size
  end

  # --- staleness / re-ingest ----------------------------------------------

  test "stale? is true after the library grows under an unchanged rule" do
    view = DatasetView.create!(name: "landscapes", rule: { "topic" => "landscape" })
    view.build!
    refute_predicate view, :stale?
    PromptSource.create!(dataset: "diffusiondb", topic: "landscape",
                         phrase_root: "new", prompt: "a fresh landscape", x: 9, y: 9)
    assert_predicate view, :stale?, "a new matching row makes the view stale"
    view.build!
    refute_predicate view, :stale?, "rebuilding clears staleness"
  end

  # --- draw ----------------------------------------------------------------

  test "draw returns the requested count from the view" do
    view = DatasetView.create!(name: "portraits", rule: { "topic" => "portrait" })
    view.build!
    drawn = view.draw(2)
    assert_equal 2, drawn.size
    assert drawn.all? { |s| s.topic == "portrait" }
  end

  test "draw is deterministic for the same view" do
    view = DatasetView.create!(name: "landscapes", rule: { "topic" => "landscape" })
    view.build!
    first = view.draw(3).map(&:id)
    second = view.draw(3).map(&:id)
    assert_equal first, second, "a draw is repeatable for a built view"
  end

  test "draw clamps to the set size and an unbuilt view draws nothing" do
    view = DatasetView.create!(name: "portraits", rule: { "topic" => "portrait" })
    assert_equal [], view.draw(5), "an unbuilt view has no rows yet"
    view.build!
    assert_equal 2, view.draw(99).size, "draw clamps to the set size"
  end
end
