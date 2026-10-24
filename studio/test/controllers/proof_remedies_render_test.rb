require "test_helper"

# #44 — the proof page says what to CHANGE, not just what went wrong.
#
# Three things are pinned here, and each is a claim a helper test cannot make:
#
#   1. A finding whose rule is in ProofRemedies renders its plain-language
#      meaning AND its suggested change, next to the rule name.
#   2. Hard and advisory findings are VISUALLY SEPARATED, the way the manifest
#      already separates them (preflight.py classify_findings) — not two runs of
#      one loop.
#   3. A rule with NO table entry renders EXACTLY as it did before this existed:
#      rule pill, layer, detail, and no empty meaning/remedy column. That is the
#      "revert = remove the suggestion column" acceptance criterion, pinned from
#      the negative side so an entry that renders nothing does not read as
#      "unchanged".
class ProofRemediesRenderTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # A rule NAME that is not in the table — the negative case. The drift pin
  # proves every rule the pipeline emits HAS an entry, so there is no real
  # un-tabled emitted rule to use; an arbitrary name pins "a rule with no entry
  # renders exactly as it did before the suggestion column existed".
  ORPHAN_RULE = "NOT_A_REAL_RULE"

  def sign_in
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  # A done proof carrying one HARD finding with a table entry, one ADVISORY
  # finding with a table entry, and one finding whose rule has no entry.
  #
  # CALLED AFTER sign_in, and that ordering is not incidental: every per-user
  # model carries Owned's default_scope, which reads Current.user_handle for the
  # lifetime of a request. A row created before the login is stamped with a blank
  # owner, and the GET that follows cannot see it — the page renders 200 with no
  # findings at all, which reads as "the feature does nothing" rather than as the
  # test setup it is.
  def job_with_findings(name)
    job = Job.create!(name: name, state: "done", source_kind: "svg",
                      input_path: "/data/#{name}.svg", stem: name,
                      spec: {}, runner: "mock")
    job.candidates.create!(file: "candidate_01.svg", passed: false, hard: 1, advisory: 1)
    manifest = {
      "proof" => "proof_01.png", "print_pdf" => "proof_01.pdf",
      "summary" => { "hard" => 2, "advisory" => 1 },
      "stats" => { "dpi" => 300, "rendered_ink_colors" => 6, "static" => { "paths" => 3 } },
      "findings" => [
        { "layer" => "source_validation", "rule" => "MIN_STROKE_WIDTH",
          "detail" => "path 7 has a 0.85pt stroke", "severity" => "hard" },
        { "layer" => "source_validation", "rule" => "NODE_COUNT",
          "detail" => "path 2 has 4,200 nodes", "severity" => "advisory" },
        { "layer" => "source_validation", "rule" => ORPHAN_RULE,
          "detail" => "path 4 encloses no area", "severity" => "hard" }
      ]
    }
    [job, job.validations.create!(file: "candidate_01.svg", state: "done", manifest: manifest)]
  end

  test "a finding with a table entry renders its meaning and its suggested change" do
    sign_in
    _job, proof = job_with_findings("remedies")
    get validation_path(proof), headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    row = doc.css(".proof-finding").find { |el| el.text.include?("MIN_STROKE_WIDTH") }
    refute_nil row, "the finding renders as a proof-finding row"
    assert_includes row.css(".proof-finding-rule").text, "MIN_STROKE_WIDTH"

    # The meaning — plain language, and it is THIS rule's, not a generic line.
    meaning = row.css(".proof-finding-meaning").text
    assert_includes meaning, "stroke thinner than the contract's minimum"

    # The suggested change — stated as a spec key, the contract vocabulary.
    change = row.css(".proof-finding-change").text
    assert_includes change, "geometry.min_stroke_width_pt"

    # And it stays with the finding: the rule pill and the remedy are in the row.
    assert_includes row.text, "0.85pt stroke", "the pipeline's own detail is not dropped"
  end

  test "the suggested change carries the section of the print-check doc it is grounded in" do
    sign_in
    _job, proof = job_with_findings("link")
    get validation_path(proof), headers: { "User-Agent" => MODERN_UA }

    row = doc.css(".proof-finding").find { |el| el.text.include?("MIN_STROKE_WIDTH") }
    assert_includes row.css(".proof-finding-change a").map { |a| a["href"] }.join,
                 "#hard-gates",
                 "every entry links to the HOWTO section it is grounded in"
  end

  test "hard and advisory findings render in separate groups, as the manifest separates them" do
    sign_in
    _job, proof = job_with_findings("separated")
    get validation_path(proof), headers: { "User-Agent" => MODERN_UA }

    hard = doc.at_css(".proof-findings--hard")
    advisory = doc.at_css(".proof-findings--advisory")
    refute_nil hard, "hard findings get their own group"
    refute_nil advisory, "advisory findings get their own group"
    refute_empty hard.css(".proof-finding"), "the hard group is not empty"
    refute_empty advisory.css(".proof-finding"), "the advisory group is not empty"

    assert_includes hard.css(".proof-finding-rule").map(&:text).join, "MIN_STROKE_WIDTH"
    assert_includes advisory.css(".proof-finding-rule").map(&:text).join, "NODE_COUNT"
    refute_includes hard.css(".proof-finding-rule").map(&:text).join, "NODE_COUNT",
                   "an advisory finding must not be grouped with the hard ones"
    refute_includes advisory.css(".proof-finding-rule").map(&:text).join, "MIN_STROKE_WIDTH"
  end

  test "a rule with no table entry renders exactly as it did, with no suggestion" do
    sign_in
    _job, proof = job_with_findings("orphan")
    get validation_path(proof), headers: { "User-Agent" => MODERN_UA }

    row = doc.css(".proof-finding").find { |el| el.text.include?(ORPHAN_RULE) }
    refute_nil row, "the un-tabled finding still renders"
    assert_equal "", row.css(".proof-finding-meaning").text.strip,
                 "no meaning block is invented for a rule the table does not carry"
    assert_equal "", row.css(".proof-finding-change").text.strip,
                 "no suggested change is invented either"
    # What it DOES keep: the rule pill, the layer, and the pipeline's own detail.
    assert_includes row.css(".proof-finding-rule").text, ORPHAN_RULE
    assert_includes row.text, "layer source_validation"
    assert_includes row.text, "path 4 encloses no area"
  end

  test "the page names the two gates in the popup, Layer A reading and Layer B rendering" do
    sign_in
    _job, proof = job_with_findings("gates")
    get validation_path(proof), headers: { "User-Agent" => MODERN_UA }

    popup = doc.at_css("#proof-gates-popup")
    refute_nil popup, "the two-gates popup renders"
    assert_includes popup.text, "Layer A"
    assert_includes popup.text, "Layer B"
    assert_includes popup.text, "Reads the file"
    assert_includes popup.text, "Renders the file"
    # The disagreement is stated as informative, which is the point of the popup.
    assert_match(/disagree is informative/, popup.text)
    # And it is reached through the app's ONE popup trigger, not a second mechanism.
    trigger = doc.at_css('[data-popup="proof-gates-popup"]')
    refute_nil trigger, "the page head carries the trigger"
  end
end
