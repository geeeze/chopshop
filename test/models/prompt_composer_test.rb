require "test_helper"

# The structured prompt composer (issue #50): N dynamic slots mixed from free
# text, boilerplate and dataset prompts, composed into ONE prompt at job time.
# Deterministic — no network, no LLM. Dataset slots stub PromptSource so the
# test never touches the 60k-row library.
class PromptComposerTest < ActiveSupport::TestCase
  # --- compose: N slots -> ONE prompt string -------------------------------

  test "composes free-text slots joined by comma" do
    slots = [{ "text" => "a phoenix" }, { "text" => "at dawn" }]
    assert_equal "a phoenix, at dawn", PromptComposer.compose(slots)
  end

  test "a single non-blank slot composes to its own text with no leading comma" do
    assert_equal "a phoenix", PromptComposer.compose([{ "text" => "a phoenix" }])
  end

  test "blank slots are dropped" do
    slots = [{ "text" => "a phoenix" }, { "text" => "  " }, {}, { "text" => "at dawn" }]
    assert_equal "a phoenix, at dawn", PromptComposer.compose(slots)
  end

  test "boilerplate slot contributes its vocabulary suffix" do
    assert_equal ", woodcut print, bold black outlines, high contrast, two inks",
                 PromptComposer.compose([{ "boilerplate" => "woodcut" }])
  end

  test "dataset slot contributes its resolved prompt" do
    assert_equal "a drawn phoenix",
                 PromptComposer.compose([{ "dataset_id" => 1, "prompt" => "a drawn phoenix" }])
  end

  test "mixed slot kinds compose in order" do
    slots = [{ "text" => "a phoenix" }, { "boilerplate" => "sticker" }]
    assert_equal "a phoenix, , die-cut sticker, thick outline, white background",
                 PromptComposer.compose(slots)
  end

  test "no slots compose to empty string" do
    assert_equal "", PromptComposer.compose([])
    assert_equal "", PromptComposer.compose(nil)
  end

  # --- normalize: POSTed slots -> clean hashes -----------------------------

  test "normalize keeps a free-text slot, stripped" do
    assert_equal [{ "text" => "a phoenix" }],
                 PromptComposer.normalize([{ "text" => "  a phoenix  " }])
  end

  test "normalize keeps a known boilerplate key" do
    assert_equal [{ "boilerplate" => "woodcut" }],
                 PromptComposer.normalize([{ "boilerplate" => "woodcut" }])
  end

  test "normalize drops an unknown boilerplate key" do
    assert_equal [], PromptComposer.normalize([{ "boilerplate" => "nope" }])
  end

  test "normalize drops a non-hash slot" do
    assert_equal [], PromptComposer.normalize(["a string", 42, nil])
  end

  test "normalize resolves a dataset_id to its drawn prompt" do
    source = PromptSource.create!(dataset: "diffusiondb", prompt: "a drawn phoenix")
    assert_equal [{ "dataset_id" => source.id, "prompt" => source.normalized_prompt }],
                 PromptComposer.normalize([{ "dataset_id" => source.id }])
  end

  test "normalize drops a dataset_id with no matching source" do
    assert_equal [], PromptComposer.normalize([{ "dataset_id" => 999_999 }])
  end

  # --- vocabularies (the only source of dropdown truth) --------------------

  test "boilerplate_options is [key, humanized] over the frozen vocabulary" do
    opts = PromptComposer.boilerplate_options
    assert_equal PromptComposer::BOILERPLATE.keys, opts.map(&:first)
    assert_equal "Woodcut", opts.assoc("woodcut").last
  end

  test "dataset_options comes from PromptSource::DATASETS, not a re-typed list" do
    assert_equal PromptSource::DATASETS.keys, PromptComposer.dataset_options.map(&:first)
  end

  test "default slots are the thing/location/style starting layout" do
    assert_equal %w[thing location style], PromptComposer::DEFAULT_SLOTS.map { |s| s["label"] }
  end

  test "the boilerplate vocabulary is frozen (pinned, one source of truth)" do
    assert_predicate PromptComposer::BOILERPLATE, :frozen?
  end
end
