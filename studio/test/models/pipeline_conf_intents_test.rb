require "test_helper"

# The goal-first intent row's registry: PipelineConf::INTENTS. An intent is a
# GOAL an operator states in their own words ("trace art for a screen print"),
# mapped to the ONE template that serves it. The row is only honest if the
# mapping is total and single-valued:
#
#   * every intent names a template that EXISTS — a typo would render a button
#     that selects nothing, the silent no-op this page has shipped before;
#   * every intent names EXACTLY ONE template — a goal that could mean two
#     ("draw a chart or a 3D view from data" is both `draw_document` and
#     `render_3d`) gets NO button, because a goal-first row that guesses is
#     worse than one that is smaller;
#   * the template's KIND is one this app knows, because the runner the apply
#     path switches to is IMPLIED by that kind — the registry stores no runner;
#   * no two intents share a label — two buttons saying the same thing is a
#     choice the operator cannot make.
class PipelineConfIntentsTest < ActiveSupport::TestCase
  def intents
    PipelineConf::INTENTS
  end

  test "the registry is non-empty and every entry is well-formed" do
    refute_empty intents, "the intent row needs at least one goal to be worth a row"
    intents.each do |intent|
      assert intent[:label].present?, "an intent needs a :label"
      assert intent.key?(:template), "an intent needs a :template"
    end
  end

  test "every intent names a template that exists" do
    intents.each do |intent|
      key = intent[:template]
      assert PipelineConf.template_keys.include?(key),
        "#{key.inspect}: an intent names a template PipelineConf does not define — " \
        "the button would select nothing"
    end
  end

  test "every intent maps to exactly one template" do
    intents.each do |intent|
      assert intent[:template].is_a?(String),
        "#{intent[:label].inspect}: the template must be ONE key, not a list — " \
        "an intent that could mean two templates gets no button"
      assert_equal 1, intent[:template].to_s.strip.split(/\s+/).size,
        "#{intent[:label].inspect}: a space-separated list is still more than one"
    end
  end

  test "every intent's template has a kind this app knows" do
    kinds = PipelineConf::BOUNDS.values.map { |b| b[:kind] }.uniq
    intents.each do |intent|
      assert_includes kinds, PipelineConf.template_kind(intent[:template]),
        "#{intent[:template]}: the runner is implied by the template's kind, so " \
        "that kind must be one the app has a panel for"
    end
  end

  # The SET of shipped intents is a deliberate operator surface: removing one
  # quietly shrinks what a new operator can reach in one click, with a green
  # suite. Pin the labels; a deliberate change updates this list consciously
  # (review round: deleting one intent stayed green -- a registry test only
  # catches an EMPTY registry).
  test "the shipped intent set is pinned" do
    assert_equal [
      "Trace art for a screen print",
      "Trace a photo",
      "Generate, then choose what to trace",
      "Generate an image only",
      "Draw a flat drawing",
      "Render a drawing in 3D",
      "Cut a sprite out",
      "Turn a prop around",
      "Deep sweep, when the ordinary sweep found nothing",
    ], intents.map { |i| i[:label] }
  end

  test "intent labels are unique" do
    labels = intents.map { |i| i[:label] }
    assert_equal labels.size, labels.uniq.size,
      "two intents sharing a label is a choice the operator cannot make"
  end

  test "every intent's template explains itself, so the hover is worth reading" do
    intents.each do |intent|
      assert PipelineConf.template(intent[:template])[:blurb].present?,
        "#{intent[:template]}: an intent button carries the template's blurb on " \
        "hover, so that blurb must exist"
    end
  end
end
