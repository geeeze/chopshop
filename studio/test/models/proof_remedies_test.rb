require "test_helper"

# #44 — the proof page's finding -> "what to change" table.
#
# THE PROBLEM: a finding named a rule and a detail, and nothing said what to
# change. The mapping existed only in svg/docs/HOWTO-print-check.md (prose) and
# jev/scripts/remediation_table.json (keyed by a failure_mode name, which is Jev
# vocabulary and which svg/, being public, must not carry).
#
# ProofRemedies is the studio-side table keyed by RULE ID. These tests are the
# drift pin in the FluxConf discipline: the rule ids come from the pipeline's
# own source, and a rule the pipeline can raise but the table does not carry is
# a finding the operator is left to interpret alone.
class ProofRemediesTest < ActiveSupport::TestCase
  # svg/, being public, must not carry Jev vocabulary. The pipeline sources are
  # the one sanctioned cross-service read (runner_conf_drift_test.rb does the same
  # for flux/bp/svg); chopshop-jev is NOT, and the table is data precisely so
  # nothing at runtime reaches across.
  SVG = Pathname.new(__dir__).join("../../..", "svg")
  VALIDATE = SVG.join("validate_svg.py")
  PREFLIGHT = SVG.join("preflight.py")

  # The ids the pipeline CAN raise, read from the source the way the repo's other
  # drift pins read theirs: a module-level `RULE_X = "NAME"` line. That is the
  # whole inventory — a rule named nowhere in these two files cannot appear in a
  # manifest, and one that appears in one but not the other is a layer mismatch.
  #
  # A PINNED set and not a scan of the tree: `RULE_X = "NAME"` is unambiguous,
  # but a bare "STRING" in an append() call is not a rule, so the scan is by the
  # constant — exactly what validate_svg.py's own header calls its rule names.
  def rule_id_constants(path)
    File.read(path).scan(/^RULE_\w+\s*=\s*"([A-Z_]+)"/).flatten.uniq
  end

  def validate_rule_ids
    rule_id_constants(VALIDATE)
  end

  def preflight_rule_ids
    rule_id_constants(PREFLIGHT)
  end

  # The union, as the acceptance criterion states it: every id EITHER file emits.
  def emitted_rule_ids
    (validate_rule_ids + preflight_rule_ids).uniq.sort
  end

  test "the pipeline's rule ids are exactly the ones enumerated in the issue" do
    # Not an existence check — a COUNT and a NAME check. A rule added to
    # validate_svg.py and not mirrored here is the drift this file exists to
    # catch, and the message names both halves so the fix is obvious.
    #
    # 17 is MEASURED, not the issue's 15+3: the issue's list was illustrative
    # ("verified present in the tree") and omitted COLOR_COUNT_RENDERED's layer-A
    # siblings and miscounted the total. The count is pinned because a scan that
    # only asserts "these names exist" passes while a rule is added and dropped
    # from the table at once.
    assert_equal 17, validate_rule_ids.size,
                 "validate_svg.py's RULE_* constants have moved: #{validate_rule_ids.inspect}"
    assert_equal 9, preflight_rule_ids.size,
                 "preflight.py's RULE_* constants have moved: #{preflight_rule_ids.inspect}"
    assert_equal 26, emitted_rule_ids.size
    assert_includes validate_rule_ids, "COLOR_COUNT"
    assert_includes validate_rule_ids, "GRADIENT_NOT_ALLOWED"
    assert_includes validate_rule_ids, "EFFECT_REFERENCE"
    assert_includes validate_rule_ids, "TRANSLUCENT_PAINT"
    assert_includes validate_rule_ids, "UNCHECKED_DEFINITION"
    assert_includes validate_rule_ids, "STROKE_SCALE_TRANSFORM"
    assert_includes preflight_rule_ids, "COLOR_COUNT_RENDERED"
    assert_includes preflight_rule_ids, "CONTINUOUS_TONE"
  end

  test "every rule id the pipeline emits has an entry or an explicit no-suggestion" do
    # THE ACCEPTANCE CRITERION, verbatim. Covered == an entry in ProofRemedies;
    # deliberately uncounted is an entry carrying the explicit no-suggestion
    # marker (suggestion: nil). Anything else is a rule the page renders with no
    # meaning and no remedy — the bug this issue describes.
    uncovered = emitted_rule_ids.reject { |id| ProofRemedies.covered?(id) }
    assert_empty uncovered,
                 "emitted by validate_svg.py/preflight.py but not in ProofRemedies: " \
                 "#{uncovered.inspect} — add an entry (suggestion: nil is an explicit " \
                 "'no suggestion', not an absence)"
  end

  test "the table holds no rule the pipeline does not emit" do
    # The other direction: an entry for a rule nothing raises is a page that
    # describes a check the pipeline cannot report.
    stale = ProofRemedies::ENTRIES.keys - emitted_rule_ids
    assert_empty stale,
                 "ProofRemedies carries entries for rules the pipeline no longer emits: " \
                 "#{stale.inspect}"
  end

  test "the layer classification agrees with the pipeline's own" do
    # ProofRemedies::LAYER_A is mirrored from preflight.py's LAYER_A_RULES, and
    # the pipeline is the authority: it decides the `layer` field of a finding.
    # Read the frozenset the way the pipeline builds it — through validate_svg's
    # own constants — so a rule reclassified in the pipeline and not here is
    # caught.
    source = File.read(PREFLIGHT)
    block = source[/^LAYER_A_RULES = frozenset\(\{(.*?)\n\}\)/m, 1].to_s
    assert block.present?, "preflight.py's LAYER_A_RULES block could not be read"

    live = block.scan(/validate_svg\.RULE_\w+/).map { |ref| ref.sub("validate_svg.", "") }
                .map { |const| File.read(VALIDATE)[/^#{const}\s*=\s*"([A-Z_]+)"/, 1] }
                .compact
    live += block.scan(/^\s+(RULE_\w+),/).flatten
                .map { |const| source[/^#{const}\s*=\s*"([A-Z_]+)"/, 1] }.compact

    assert_equal live.uniq.sort, ProofRemedies::LAYER_A.sort,
                 "ProofRemedies::LAYER_A has drifted from preflight.py's LAYER_A_RULES"

    # And the derived half: a rule in neither list is a page that guesses.
    (emitted_rule_ids - ProofRemedies::LAYER_A).each do |id|
      assert_equal "render_preflight", ProofRemedies.layer_of(id),
                   "#{id} is not in LAYER_A, so layer_of must call it render_preflight"
    end
  end

  test "severity matches the pipeline's own classifier" do
    # The manifest is authoritative for the severity a finding carries, but the
    # TABLE's severity is what a reading of the rule means in general — and where
    # the two disagree the table must say so, because a hard gate under one spec
    # is an advisory under another (preflight.py classify()).
    #
    # So the check is not "the table is right about every rule" but "the table is
    # right about the ones the pipeline fixes in one direction, and honest about
    # the ones the pipeline makes conditional".
    assert_equal "advisory", ProofRemedies.severity_of("NODE_COUNT"),
                 "preflight.py's _ALWAYS_ADVISORY"
    assert_equal "advisory", ProofRemedies.severity_of("PALETTE")
    assert_equal "advisory", ProofRemedies.severity_of("EFFECT_REFERENCE")
    assert_equal "advisory", ProofRemedies.severity_of("TRANSLUCENT_PAINT")
    assert_equal "advisory", ProofRemedies.severity_of("UNCHECKED_DEFINITION")

    assert_equal "hard", ProofRemedies.severity_of("MIN_STROKE_WIDTH"),
                 "preflight.py's _ALWAYS_HARD"
    assert_equal "hard", ProofRemedies.severity_of("COLOR_COUNT")
    assert_equal "hard", ProofRemedies.severity_of("RASTER_EMBED")

    # The three the pipeline's classify() makes depend on the run's own spec.
    # These are the entries that MUST say "conditional" and name the key — a flat
    # "hard" here is a page that over-claims a gate this run treated as advisory.
    %w[CONTINUOUS_TONE INK_COVERAGE FONT_EMBED].each do |id|
      assert_equal "conditional", ProofRemedies.severity_of(id),
                   "#{id} is conditional in preflight.py classify(); the entry must not " \
                   "claim a flat severity"
      change = ProofRemedies.change_for(id)
      assert_equal :spec_key, change&.dig(:kind),
                   "#{id}'s remedy is the spec key that flips it"
    end
  end

  test "every link fragment names a real section of the print-check doc" do
    # The link is the one part of an entry that can rot SILENTLY: a renamed
    # heading in svg/docs/HOWTO-print-check.md leaves the model's fragment
    # pointing at nothing, and the page still renders a link that lands at the
    # top of the document. So the fragment is checked against the doc's own
    # headings, using GitHub's anchor rule (lowercase, strip punctuation,
    # spaces to hyphens).
    doc = SVG.join("docs", "HOWTO-print-check.md").read
    headings = doc.scan(/^##\s+(.*)$/).flatten
    anchors = headings.map { |h| h.strip.downcase.gsub(/[^\w\s-]/, "").tr(" ", "-") }

    used = ProofRemedies::ENTRIES.values.filter_map { |e| e[:link] }.uniq
    assert used.any?, "the entries carry doc links"
    missing = used - anchors
    assert_empty missing,
                 "ProofRemedies links to sections the print-check doc does not have: " \
                 "#{missing.inspect} (doc has: #{anchors.inspect})"
  end

  test "the mirror is data, not a runtime read of the jev repo" do
    # The FluxConf discipline, as a structural check: the table is a constant in
    # this app, and nothing reaches across to chopshop-jev at runtime. What is
    # forbidden is a READ of the Jev repo -- not its NAME in a comment that
    # explains where the data came from, so the assertion is on code, not prose.
    source = Rails.root.join("app/models/proof_remedies.rb").read
    code = source.split(/^class ProofRemedies/, 2).last.to_s
    refute_match %r{chopshop-jev|remediation_table}, code,
                 "ProofRemedies must not read the jev repo; it mirrors the data"
    assert defined?(ProofRemedies::ENTRIES), "the table is the ENTRIES constant"
  end
end
