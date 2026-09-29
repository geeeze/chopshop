require "test_helper"

# The Jobs LIST (/jobs) LINKS to the proof page. It carries no proof button and
# no proof popups: the proof, its information and its Jev button all live on
# /proofs/:id. A second copy of that content here is the thing that drifts, so
# these assertions exist to stop it coming back.
#
# What the list DOES have: the thumbnail and the name as real links to the proof
# result page. The row was clickable only through aether.js's data-href, which
# is not focusable, not middle-clickable, and does nothing with JS off.
#
# The popup body still lives in validations/_proof_detail, used by the job
# RESULTS page where the proof actually is.
class JobsListProofTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # proof_detail / job_proof_path are view helpers. An integration test has no
  # `helpers`, so reach them the same way a view would.
  include ApplicationHelper

  def setup_jobs
    job = Job.create!(name: "listed", state: "done", source_kind: "svg",
                      input_path: "/d/x.svg", stem: "l", spec: {}, runner: "mock",
                      comparison: { "candidates" => [] })
    proof = job.validations.create!(file: "candidate_01.svg", state: "done",
      manifest: { "proof" => "proof_01.png", "print_pdf" => "proof_01.pdf",
                  "summary" => { "hard" => 0, "advisory" => 1 },
                  "stats" => { "dpi" => 300, "rendered_ink_colors" => 4,
                               "static" => { "path_nodes_total" => 812 } },
                  "findings" => [{ "rule" => "COLOR_COUNT", "severity" => "hard",
                                   "layer" => 1, "detail" => "7 colours, 6 allowed" }] })
    # A job with no proof at all: the button must be absent, not dead.
    bare = Job.create!(name: "bare", state: "queued", source_kind: "svg",
                       input_path: "/d/y.svg", stem: "b", spec: {}, runner: "mock",
                       comparison: { "candidates" => [] })
    [job, proof, bare]
  end

  def page
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get jobs_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  test "no proof button, no proof popups and no Jev button on the Jobs list" do
    _job, proof, = setup_jobs
    d = page

    assert_empty d.css(".cs-job-proof"),
      "the proof button does not belong here -- the proof page has the proof"
    assert_nil d.at_css("#proof-detail-#{proof.id}"),
      "and neither does a copy of the proof popup"
    # No proof CONTENT either: a second copy of findings and metrics on the
    # list is exactly what drifts out of step with the proof page.
    refute_includes d.text, "COLOR_COUNT"
    assert_empty d.css(".cs-finding"), "no findings block"
    assert_empty d.css(".cs-metric"), "no metrics block"
    # Nor a Jev affordance -- Ask Jev belongs to the proof, not to a job row.
    assert_empty d.css(".jev-btn"), "the Jev button lives on the proof page"
    assert_empty d.css("[data-jev-url]"), "and no Jev request wiring here either"
  end

  test "the view and stylesheet carry no proof-popup code" do
    # BOTH templates: the index AND the row partial it renders, because the row
    # moved into a partial when the infinite scroll arrived (so the appended pages
    # are the same markup as the first). A destination bug can hide in either.
    view = %w[index.html.erb _row.html.erb]
             .map { |f| File.read(Rails.root.join("app/views/jobs", f)) }.join("\n")
    refute_includes view, "proof_detail", "no popup partial rendered"
    refute_includes view, "cs-job-proof", "no paper button"
    # It said "the links stay" and asserted job_proof_path appears here. Those
    # links were the bug: the name and the thumbnail pointed at the proof, so
    # clicking a job's name opened the proof. The row now opens the job, and the
    # proof is reached from inside the job. Asserted as an absence, because this
    # line is what pinned the wrong destination in the first place.
    refute_includes view, "job_proof_path",
      "no proof link on the list: the name and thumbnail open the job"
    assert_includes view, "job_path(job)",
      "and the row, the name and the thumbnail all agree on that one destination"

    css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))
    # The list's own buttons are `.cs-job-download` (7z) and `.cs-job-action`
    # (delete). A `.cs-job-proof` rule is the CANDIDATES table's proof download
    # (see ProofButtonSizeTest), on the job page -- the list must not style one.
    # A SELECTOR, not the string: the comment above .cs-job-proof-download in
    # application.css names the class, and a plain grep matches that.
    # `\b` is NOT enough here: it matches the boundary in `.cs-job-proof-
    # download`, which is the job page's download control, a different class.
    refute_match(/\.cs-job-proof(?![-\w])/, css,
      "and no styling for a proof button on this page")
  end

  test "the Jobs table has no Candidates column, and the Runner column is back" do
    setup_jobs
    d = page
    heads = d.css("thead th").map { |th| th.text.strip }
    refute_includes heads, "Candidates"
    assert_includes heads, "Passed", "Passed was already standalone, so it stays"
    assert_equal 6, heads.size, "Preview, Name, State, Passed, Runner, Actions"
    assert_includes heads, "Runner", "the runner label now says something: svg, flux or plot"
    refute_includes heads, "Queued", "Queued is gone -- the Runner column replaced it"
  end

  test "the thumbnail and the name open the JOB, not the proof" do
    # Was: both linked to /proofs/:id, and the thumbnail's own tooltip said
    # "open the proof result". So clicking the job's name -- the thing that
    # looks like the job, and the thing you aim at -- took you to the proof.
    # The row's data-href already went to the job, so the two disagreed: the
    # row said job, the name and thumb said proof.
    job, _proof, = setup_jobs
    d = page
    row = d.css("tr").find { |r| r.text.include?(job.name) }
    refute_nil row

    # Every clickable part of the row agrees on the destination.
    assert_equal job_path(job), row["data-href"]

    thumb = row.at_css("a.job-thumb")
    refute_nil thumb, "the thumbnail must be an <a>, not a bare span -- the row's " \
                       "data-href is JS-only: not focusable, not middle-clickable"
    assert_equal job_path(job), thumb["href"]
    assert_includes thumb["aria-label"].to_s + thumb["title"].to_s, job.name

    name = row.at_css("a.cs-job-name")
    refute_nil name, "and so is the name"
    assert_equal job_path(job), name["href"]
    assert_includes name.text, job.name
    assert_includes name.to_html, "<strong>", "keeping the existing markup"

    # Nothing on the row may quietly point at a proof.
    row.css("a[href]").each do |a|
      refute_match(%r{/proofs/}, a["href"],
        "#{a["class"]} still links to a proof: #{a["href"]}")
    end
  end

  test "the tooltip no longer promises the proof" do
    # It said "open the proof result" while linking to the job. WCAG 2.5.3: a
    # tooltip that describes a different target than the link is worse than none.
    job, = setup_jobs
    d = page
    row = d.css("tr").find { |r| r.text.include?(job.name) }
    label = row.at_css("a.job-thumb")["title"].to_s + row.at_css("a.job-thumb")["aria-label"].to_s
    refute_match(/proof/i, label, "the thumbnail's label must not mention the proof")
  end

  test "the 7z download control stays" do
    # Removed it once by mistake, on a report about the row's LINKS. The 7z
    # download in the actions cell is a different control and was never part of
    # that complaint -- so its presence is pinned, to stop a future
    # "while I'm tidying this table" from taking it out again.
    job, = setup_jobs
    d = page
    row = d.css("tr").find { |r| r.text.include?(job.name) }
    dl = row.at_css("a.cs-job-download")
    refute_nil dl, "the 7z download must be in the actions cell"
    assert_equal download_job_path(job), dl["href"]
    assert_includes dl["aria-label"].to_s, job.name
  end

  test "a job with no proof still links somewhere, never to a dead cell" do
    _job, = setup_jobs
    bare = Job.find_by(name: "bare")
    assert_equal jobs_path + "/" + bare.id.to_s, job_proof_path(bare).sub(/\?.*/, ""),
      "with no proof the link falls back to the job itself"
  end

  test "the list preloads validations rather than querying per row" do
    setup_jobs
    src = File.read(Rails.root.join("app/controllers/jobs_controller.rb"))
    index = src[/def index.*?\n  end/m]
    assert_match(/includes\(:validations\)/, index,
      "job_proof_path reads each job's proofs, so without this a 50-row page " \
      "is 50 extra queries")
  end

  test "the proof body is shared, on the results page where the proof is" do
    _job, = setup_jobs
    show = File.read(Rails.root.join("app/views/jobs/show.html.erb"))
    assert_includes show, 'render "validations/proof_detail"',
      "one partial, used where the proof actually is"
    refute_includes show, "vm = v.manifest",
      "the seven locals are gone -- they lived in the page and a partial " \
      "cannot reach them"
    partial = File.read(Rails.root.join("app/views/validations/_proof_detail.html.erb"))
    assert_includes partial, "cs-findings"
    assert_includes partial, "Open proof"
  end

  test "proof_detail assembles the popup's data in one place" do
    job, proof, = setup_jobs
    d = proof_detail(proof)
    assert_equal proof, d[:validation]
    assert_equal 0, d[:summary]["hard"]
    assert_equal 1, d[:summary]["advisory"]
    assert_equal 300, d[:stats]["dpi"]
    assert_equal 812, d[:statics]["path_nodes_total"]
    assert_equal "proof_01.png", d[:png]
    assert_equal "proof_01.pdf", d[:pdf]
    assert_equal 1, d[:findings].size
    # A hard finding means nothing is "cleared" -- the clearances are only
    # meaningful on a clean pass.
    assert_empty d[:cleared][:cleared]

    # Tolerates a junk manifest rather than blowing up the whole list page.
    job.validations.create!(file: "candidate_02.svg", state: "running", manifest: "not a hash")
    junk = proof_detail(job.validations.order(:id).last)
    assert_empty junk[:findings]
    assert_nil junk[:png]
  end

  # The cleared checklist must keep up with the gates: a proof that cleared a
  # gate that no longer exists (or is described the old way) reads as evidence
  # of a check that never ran.
  #
  # Spelled against the rule IDs the pipeline emits, so a rename on the svg side
  # breaks this rather than silently emptying the checklist.
  def clean_manifest(findings: [])
    # No `color_count` on purpose: the Colour budget entry pluralises, and
    # pluralize is an ActionView helper this test class does not carry. Every
    # entry under test here is reached without it.
    { "proof" => "proof_03.png", "print_pdf" => "proof_03.pdf",
      "summary" => { "hard" => 0, "advisory" => findings.size },
      "stats" => { "static" => { "paths" => 4,
                                 "paths_over_node_limit" => 0,
                                 "palette_conformance" => "all colours on palette" } },
      "findings" => findings }
  end

  test "the checklist states the gradient gate cleared when its rule did not fire" do
    m = clean_manifest
    labels = cleared_checks(m)[:cleared].map { |c| c[:label] }
    assert_includes labels, "Gradients",
      "GRADIENT_NOT_ALLOWED is a hard Layer A gate now, so a clean proof must " \
      "say so -- silence reads as 'not checked'"

    # Suppressed the moment it fires, like every other entry here: a gate that
    # failed is never reported as cleared.
    fired = clean_manifest(findings: [{ "rule" => "GRADIENT_NOT_ALLOWED",
                                        "severity" => "hard", "layer" => 1,
                                        "detail" => "declares a linearGradient" }])
    refute_includes cleared_checks(fired)[:cleared].map { |c| c[:label] }, "Gradients"
  end

  test "the raster-embed clearance describes the broader RASTER_EMBED check" do
    detail = cleared_checks(clean_manifest)[:cleared]
             .find { |c| c[:label] == "Raster embeds" }[:detail]
    assert_match(/feImage/, detail,
      "the gate covers <feImage>, <foreignObject>, a reference to another " \
      "document and a raster paint server, not just <image>")
  end

  test "the effect reference is reported as NOT cleared, never as a pass" do
    # EFFECT_REFERENCE is advisory: Layer A cannot measure what a filter, mask
    # or clip-path does to the ink. That is a gate that did not run, so it
    # belongs in the skipped list -- the list whose whole point is that an
    # unmeasured gate is never read as a cleared one.
    #
    # The pipeline writes advisories into the manifest's `notes` as
    # "RULE_ID: detail" and never into `findings` (so they cannot fail a job),
    # so the note form is the one that actually ships.
    m = clean_manifest(findings: [{ "rule" => "EFFECT_REFERENCE",
                                    "severity" => "advisory", "layer" => 1,
                                    "detail" => "uses a filter" }])
    checked = cleared_checks(m)
    assert_match(/EFFECT_REFERENCE/, checked[:skipped].to_sentence,
      "an advisory must not be silent")
    refute_includes checked[:cleared].map { |c| c[:detail] }.join(" "), "EFFECT_REFERENCE",
      "an advisory is not a clearance"

    # And the shipped vector: a note, not a finding.
    noted = clean_manifest
    noted["notes"] = ["EFFECT_REFERENCE: 2 elements reference a filter, 1 a " \
                      "mask; layer A cannot measure the ink they produce"]
    assert_match(/EFFECT_REFERENCE/, cleared_checks(noted)[:skipped].to_sentence,
      "advisories arrive in `notes`, so reading only `findings` would drop them")

    # Nothing raises it, nothing is said about it.
    assert_empty cleared_checks(clean_manifest)[:skipped].grep(/effect/i)
  end

  # The other two advisory tags the svg side pins. They are the same kind of
  # statement as EFFECT_REFERENCE -- a check Layer A could not finish -- so they
  # take the same route. Both were read out of validate_svg.py, not invented: a
  # tag the pipeline never emits can never appear on the page.
  test "the other pinned advisories are reported as not cleared too" do
    { "UNCHECKED_DEFINITION" => /UNCHECKED_DEFINITION/,
      "TRANSLUCENT_PAINT" => /TRANSLUCENT_PAINT/ }.each do |rule, pattern|
      m = clean_manifest
      m["notes"] = ["#{rule}: 3 elements; layer A could not check them"]
      assert_match pattern, cleared_checks(m)[:skipped].to_sentence,
        "#{rule} says part of the checks did not run, so it cannot read as cleared"
      assert_empty cleared_checks(m)[:cleared].map { |c| c[:detail] }.grep(pattern)
    end
  end
end
