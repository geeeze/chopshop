require "test_helper"

# The Jev "?" popups used to hold example Q/A pairs and nothing else, which made
# the four question cards read as four unrelated opinions. They now carry the
# account of how an answer is reached at all.
#
# Every claim in that account is transcribed from the annotator, so this file
# checks it against jev_annotate.py rather than against itself. A help page that
# drifts from the code it describes is worse than no help page.
class JevHelpTest < ActiveSupport::TestCase
  ANNOTATOR = Rails.root.parent.join("chopshop-jev/scripts/jev_annotate.py")

  def annotator
    @annotator ||= ANNOTATOR.read
  end

  def conf
    JevConf
  end

  def view
    File.read(Rails.root.join("app/views/pages/jev.html.erb"))
  end

  def css
    File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  test "the annotator is where the help is transcribed from" do
    assert ANNOTATOR.exist?, "jev_annotate.py not found at #{ANNOTATOR}"
    # If this fails, the source of truth moved and the help needs re-reading.
    assert_match(/def project_manifest/, annotator)
    assert_match(/def compose_verdict/, annotator)
    assert_match(/def _answer_confidence/, annotator)
    assert_match(/def _compact_stats/, annotator)
  end

  # ---- what it reads ----

  test "the help names the six keys project_manifest actually returns" do
    keys = conf::HELP["reads"].map(&:first)
    assert_equal %w[passed input summary findings stats notes], keys
    # compose_verdict builds exactly this set, in this order.
    body = annotator[/def project_manifest.*?return \{(.*?)\n    \}/m, 1]
    keys.each { |k| assert_match(/"#{k}"/, body, "#{k} is not in the returned state") }
  end

  test "every field a question claims to read exists in the annotator" do
    conf::READS.each do |q, fields|
      fields.each do |f|
        # "stats.rendered_ink_colors" -> "stats"; "findings[].rule" -> "findings".
        base = f.split(/[.\[]/).first
        assert annotator.include?(base),
          "#{q} claims to read #{f}, but #{base} appears nowhere in jev_annotate.py"
      end
    end
  end

  test "the claims about what is withheld are true of the annotator" do
    assert_match(/never sends the full manifest/, annotator,
      "the docstring says the full manifest is not sent, and the help says so")
    # Colour lists really are reduced to counts.
    assert_match(/pdf_images.*count/m, annotator)
    assert_match(/"pdf_fonts"\] = \{\s*"count"/m, annotator)
    assert_match(/_compact_top_inks/, annotator)
    # Paths really are shortened and text really is scrubbed.
    assert_match(/def _short_path/, annotator)
    assert_match(/def _scrub/, annotator)
  end

  test "the scalars named in the help are the ones _compact_stats keeps" do
    body = annotator[/def _compact_stats.*?scalars = \[(.*?)\]/m, 1]
    # Spot-check the ones the help singles out as the decision-relevant ones.
    %w[dpi proof_pixels rendered_distinct_colors rendered_ink_colors
       rendered_screens rendered_continuous_tone rendered_largest_ramp_percent
       rendered_diffuse_area_percent ink_tac_max_percent pdf_color_spaces
       render_error pdf_error].each do |k|
      assert_match(/"#{k}"/, body, "#{k} is not among the kept scalars")
    end
  end

  # ---- what comes back ----

  test "the return keys are the ones compose_verdict writes" do
    body = annotator[/def compose_verdict.*?\n    return verdict/m]
    %w[headline print_route low_confidence confidence_floor].each do |k|
      assert_match(/"#{k}"/, body, "#{k} is not in the verdict")
    end
    assert_match(/evidence_actionable/, body)
    assert_match(/tonal/, body)
  end

  test "the type-aware confidence claim matches _answer_confidence" do
    body = annotator[/def _answer_confidence.*?(?=\ndef )/m]
    # A 0.0 confidence must be treated as ABSENT, not as below the floor --
    # otherwise every score answer would be flagged.
    assert_match(/confidence > 0/, body,
      "a zero confidence is not read as a confidence at all")
    assert_match(/max\(probabilities\.values\(\)\)/, body,
      "so a score falls THROUGH to the top of its distribution -- the floor is " \
      "applied, not skipped")
    assert_match(/2 \* abs\(noul - 0\.5\)/, body,
      "and a noul is gated on its distance from a coin-flip")
    conf::RETURN_TYPE["score"].tap do |r|
      assert_includes r, "0.0"
      assert_includes r, "probabilities"
      refute_includes r, "does not apply",
        "the floor DOES apply to a score, via the distribution"
    end
  end

  test "the floor is described as a warning, and it is one" do
    body = annotator[/def compose_verdict.*?\n    return verdict/m]
    assert_match(/verdict\["low_confidence"\]\.append\(key\)/, body,
      "a below-floor answer is listed")
    refute_match(/low_confidence.*\bpop\b|low_confidence.*del /, body,
      "and nothing drops it")
    assert_includes conf::HELP["limit"].join(" "), "not a filter"
    assert_includes conf::HELP["limit"].join(" "), "never overrides a deterministic gate"
  end

  # ---- the page wiring ----

  test "a ? opens the account first and the examples after" do
    s = view
    handler = s[/function openExamples\(key, title\) \{.*?\n  \}/m]
    refute_nil handler
    assert_match(/jevHelp-/, handler, "the shared help sections")
    assert_match(/jevReads-/, handler, "and the per-question fields")
    assert_match(/jevExamples-/, handler, "and then the examples")
    # Order matters: the account explains the examples.
    assert_operator handler.index("jevHelp-"), :<, handler.index("jevExamples-")
    assert_operator handler.index("jevReads-"), :<, handler.index("jevExamples-")
  end

  test "the shared sections are split, so no popup is the whole pipeline" do
    s = view
    assert_match(/key === '__floor' \|\| key === '__metrics'\s*\?\s*\['returns', 'limit'\]\s*:\s*\['reads', 'never_sends'\]/m, s,
      "the four questions get the state and what is withheld from it; the floor " \
      "and the metrics get what comes back and what may not be concluded")
  end

  test "every question and the floor have a reads template" do
    %w[failure_mode print_route tonal_structure evidence_is_actionable __floor __metrics].each do |k|
      assert_includes view, "JevConf::READS.each"
      assert conf::READS.key?(k), "#{k} has no READS entry, so its ? cannot say what it reads"
    end
  end

  test "the help is styled as a ledger, and the fields as copyable chips" do
    assert_match(/\.jev-help-row \{[^}]*grid-template-columns:/, css)
    assert_match(/\.jev-help-fields code \{[^}]*font-family: var\(--font-mono\)/m, css,
      "the field names are identifiers to copy into a manifest, not prose")
    # The examples are still the gamer font, as asked.
    assert_match(/\.jev-card \.a \{[^}]*font-family:\s*var\(--font-pixel\)/m, css)
  end

  test "the claim that the floor reads answer_confidence is true of the annotator" do
    # RETURN_TYPE["choice"] and BACKENDS["local"]["certainty"] both say the floor
    # reads answer_confidence where a service reports it. That is a claim about
    # _answer_confidence, so it is checked there and not in the prose: a second
    # backend reports the probability mass under that name, and a floor applied
    # to its entropy-style confidence instead would gate a different set of
    # answers while looking identical on the page.
    assert conf::RETURN_TYPE["choice"].include?("answer_confidence")
    assert conf::BACKENDS["local"]["certainty"].include?("answer_confidence")
    assert_match(/answer\.get\("answer_confidence"\)/, annotator,
      "the help says the floor reads the mass, so the annotator has to read it")
    # The hosted shape is unchanged: no second certainty field to read.
    assert conf::BACKENDS["hosted"]["certainty"].include?("confidence")
  end

  test "the backend card does not claim this app can select the backend" do
    # The selection lives in the runner's environment. The page must state the
    # variables rather than offer a control, or the operator edits a form that
    # cannot change what the annotator posts to.
    assert conf::SELECTION.key?("JEV_ENDPOINT")
    assert conf::SELECTION.key?("JEV_API_KEY")
    refute_includes view, "jev-backend-select" # no such control exists
  end
end
