require "test_helper"

# The epistemic flags (#9): a proof's FINDINGS and its JEV ANSWERS are the
# studio's claim layer, and they were accept-as-stated -- an unchecked claim and
# a verified one rendered identically, and nothing counted them.
#
# The contracts pinned here:
#
#   * THE FLAG IS DATA on the proof ROW. It is a column of its own, not a key
#     written into `manifest` or `jev_answers`: those are the runner's and the
#     annotator's records, and stamping an opinion into a finding's hash would
#     forge the source's file;
#   * THE CHIP renders on BOTH surfaces the flag covers -- a Jev answer card and
#     a proof findings row -- and renders NOTHING for an accepted proof. A chip
#     that is always there is chrome, not a flag;
#   * THE AUDIT counts the unverified proofs (ONE gap: both words are the same
#     debt, and the count is every row carrying EITHER flag), and the id list
#     behind the count is exactly those rows;
#   * THE CHIP REUSES the #93 band vocabulary -- needs_factcheck is the warn
#     amber, disputed the fail red -- rather than inventing a colour, and each
#     rule keeps its literal as the token's fallback.
#
# The reference app's own review found its counts unreproducible, so the
# MECHANISM is taken (flag + chip + one count + the id list) and its numbers are
# not: every count here is the size of the relation its list is read off.
class EpistemicFlagsTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  ANSWERS = {
    "dominant_issue" => { "type" => "choice", "choice" => "screen_explosion",
                          "confidence" => 0.82 },
    "next_action" => { "type" => "noul", "noul" => 0.71 }
  }.freeze

  FINDINGS = [{ "rule" => "min_stroke_width_pt", "severity" => "hard", "layer" => "A",
                "detail" => "Stroke 1.2pt is below the 1.5pt floor" }].freeze

  def sign_in
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def job_with_proof(**flags)
    job = Job.create!(name: "epistemic", state: "done", source_kind: "svg",
                      input_path: "/data/x.svg", stem: "epistemic", spec: {},
                      runner: "mock",
                      comparison: { "candidates" => [
                        { "file" => "candidate_01.svg", "hard" => 1, "advisory" => 0,
                          "layer_a" => { "status" => "pass" },
                          "layer_b" => { "status" => "pass" } } ] })
    validation = job.validations.create!(file: "candidate_01.svg", state: "done",
                                         manifest: { "proof" => "proof_01.png",
                                                     "findings" => FINDINGS },
                                         jev_answers: ANSWERS,
                                         jev_meta: { "model" => "test-model" })
    # The flags are set AFTER create so the test cannot pass by reading back a
    # default: it names the flag it is about, and the row starts without it.
    validation.update!(flags) if flags.any?
    [job, validation]
  end

  def audit_json
    get "/audit.json", headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    JSON.parse(response.body)
  end

  def group(body, key)
    body["groups"].find { |g| g["key"] == key }
  end

  # -- the flag is data ------------------------------------------------------

  test "the flag is data on the proof row, and only the flag that was set" do
    _job, clean = job_with_proof
    assert_equal [], clean.epistemic_flags, "an accepted proof carries no flag"
    refute clean.flagged?, "and is not counted as unverified"
    assert_not clean.needs_factcheck
    assert_not clean.disputed

    _job, flagged = job_with_proof(needs_factcheck: true)
    assert_equal [:needs_factcheck], flagged.epistemic_flags,
                 "only the flag that was set is reported"
    assert flagged.flagged?

    # BOTH words, in the vocabulary's own order -- the chip renders in this
    # order, so a proof that is both reads the same order everywhere.
    _job, both = job_with_proof(needs_factcheck: true, disputed: true)
    assert_equal %i[needs_factcheck disputed], both.epistemic_flags

    # The label the chip renders is keyed here, so the view cannot restate it
    # and drift.
    assert_equal "needs factcheck", Validation::EPISTEMIC_FLAGS[:needs_factcheck]
    assert_equal "disputed", Validation::EPISTEMIC_FLAGS[:disputed]
  end

  # -- the chip: accepted proofs carry none ----------------------------------

  test "an accepted proof renders no chip on either surface" do
    job, validation = job_with_proof
    sign_in

    get validation_path(validation), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_empty Nokogiri::HTML(response.body).css(".proof-finding .chip"),
                 "the findings row carries no chip for an accepted proof"

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_empty Nokogiri::HTML(response.body).css(".jev-card .chip"),
                 "the Jev answer card carries no chip for an accepted proof"
  end

  # -- the chip: both surfaces ----------------------------------------------

  test "a needs_factcheck proof renders the chip on the Jev answer cards" do
    job, validation = job_with_proof(needs_factcheck: true)
    sign_in

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    chips = doc.css("#jev-popup-#{validation.id} .jev-card .chip.needs_factcheck")
    assert_equal 2, chips.size,
                 "one chip per answer card: the flag belongs to the proof, so the " \
                 "answer being read is the one that has to say so"
    assert_match(/needs factcheck/, chips.first.text)
    # And nothing else: a proof that is only unchecked is not also disputed.
    assert_empty doc.css("#jev-popup-#{validation.id} .chip.disputed")
  end

  test "a disputed proof renders the chip on the proof findings rows" do
    _job, validation = job_with_proof(disputed: true)
    sign_in

    get validation_path(validation), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    chips = doc.css(".proof-finding .chip.disputed")
    assert_equal FINDINGS.size, chips.size, "one chip per finding row"
    assert_match(/disputed/, chips.first.text)
    assert_empty doc.css(".proof-finding .chip.needs_factcheck"),
                 "a disputed proof is not also reported as unchecked"
  end

  # -- the audit -------------------------------------------------------------

  test "the audit counts the unverified proofs and lists exactly their ids" do
    _job, flagged = job_with_proof(needs_factcheck: true)
    _job, disputed = job_with_proof(disputed: true)
    _job, clean = job_with_proof
    sign_in
    body = audit_json

    validations = group(body, "validations")
    # ONE gap, and it counts every row carrying EITHER flag -- both words are
    # the same debt ("not accepted as stated"), which is what the issue's
    # `needs_factcheck: N` names.
    assert_equal 2, validations["gaps"]["needs_factcheck"],
                 "the unchecked proof and the disputed proof are both unverified"

    # The count is the exact relation behind its own list: the filtered page
    # lists exactly the rows the count names, and no more.
    listed = AuditGaps.rows_for("validations.needs_factcheck").map(&:first)
    assert_equal [flagged.id, disputed.id].sort, listed.sort,
                 "the id list is exactly the flagged proofs"
    assert_equal validations["gaps"]["needs_factcheck"], listed.size,
                 "the count and the list behind it agree"
    refute_includes listed, clean.id, "the accepted proof is in neither"

    # The gap is one row in the group's UNION, not three: both flagged proofs
    # are unresolved ROWS, and the accepted one is unresolved only for the
    # unrelated checks it fails (it was never given a candidate).
    assert_equal [flagged.id, disputed.id].sort,
                 (validations["unresolved_ids"] & [flagged.id, disputed.id]).sort
  end

  test "the filtered audit page renders the flagged proofs" do
    _job, flagged = job_with_proof(needs_factcheck: true)
    sign_in
    get "/audit?gap=validations.needs_factcheck", headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    doc = Nokogiri::HTML(response.body)
    assert_equal 1, doc.css(".chip.mono").size,
                 "the filtered page lists exactly the flagged proof"
    assert_match(/unverified finding or Jev answer/,
                 doc.at_css(".card-head h3")&.text.to_s,
                 "the gap's own name heads the list")
  end

  test "the banner names the debt, because it is a projection of the report" do
    job_with_proof(needs_factcheck: true)
    assert_includes AuditGaps.banner.map(&:first),
                    "proofs with an unverified finding or Jev answer (needs_factcheck / disputed)"
  end

  # -- the vocabulary -------------------------------------------------------

  test "the chip reuses the #93 band vocabulary, with the literal as fallback" do
    css = Rails.root.join("app/assets/stylesheets/application.css").read

    # APPENDED at the end of the sheet, under its own section: the #93 semantic
    # layer and everything above it are untouched, so this is an addition a
    # reader can delete without unpicking the file.
    assert_operator css.index("EPISTEMIC FLAGS (issue #9)"), :>, css.index(".chip.miss"),
                    "the section sits after the #93 layer it builds on"

    # The two meanings, and no invented colour: each re-points a #93 band token
    # and keeps the studio's own literal as the fallback, the sheet's standing
    # invariant.
    assert_match(/\.chip\.needs_factcheck,\s*\n\.badge\.needs_factcheck \{[^}]*var\(--band-warn-bg, rgba\(245, 158, 11, 0\.15\)\)/m,
                 css, "needs_factcheck is the warn amber, fallback intact")
    assert_match(/\.chip\.disputed,\s*\n\.badge\.disputed \{[^}]*var\(--band-fail-bg, rgba\(239, 68, 68, 0\.15\)\)/m,
                 css, "disputed is the fail red, fallback intact")
  end
end
