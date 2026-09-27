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
    view = File.read(Rails.root.join("app/views/jobs/index.html.erb"))
    refute_includes view, "proof_detail", "no popup partial rendered"
    refute_includes view, "cs-job-proof", "no paper button"
    assert_includes view, "job_proof_path", "but the links stay"

    css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))
    refute_includes css, ".cs-job-proof", "and no styling for a button that is gone"
  end

  test "the Jobs table no longer has a Candidates column" do
    setup_jobs
    d = page
    heads = d.css("thead th").map { |th| th.text.strip }
    refute_includes heads, "Candidates"
    assert_includes heads, "Passed", "Passed was already standalone, so it stays"
    assert_equal 6, heads.size, "Preview, Name, State, Passed, Queued, Actions"
    refute_includes heads, "Runner", "the runner column is gone -- the pipeline " \
      "writes source.png, so the name says nothing a user can act on"
  end

  test "the thumbnail and the name are real links to the proof result page" do
    job, proof, = setup_jobs
    d = page
    row = d.css("tr").find { |r| r.text.include?(job.name) }
    refute_nil row

    thumb = row.at_css("a.job-thumb")
    refute_nil thumb, "the thumbnail must be an <a>, not a bare span -- the row's " \
                       "data-href is JS-only: not focusable, not middle-clickable"
    assert_equal "/proofs/#{proof.id}", thumb["href"]
    assert_includes thumb["aria-label"].to_s + thumb["title"].to_s, job.name

    name = row.at_css("a.cs-job-name")
    refute_nil name, "and so is the name"
    assert_equal "/proofs/#{proof.id}", name["href"]
    assert_includes name.text, job.name
    assert_includes name.to_html, "<strong>", "keeping the existing markup"
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
end
