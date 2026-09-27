require "test_helper"

# The Jobs LIST: a paper button that opens the proof information, and a
# thumbnail and name that are real links to the proof result page.
#
# The row was already clickable, but only through aether.js's data-href: a plain
# <span> thumbnail and a <strong> name. That is not focusable, not
# middle-clickable, and does nothing at all with JS off. They are now <a>s.
#
# The popup body is shared with the job RESULTS page via
# validations/_proof_detail, so the two cannot drift.
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

  test "the paper button opens the proof popup, and only where there is a proof" do
    job, proof, bare = setup_jobs
    d = page

    btn = d.at_css(".cs-job-proof")
    refute_nil btn, "a paper button on a job that has a proof"
    assert_equal "proof-detail-#{proof.id}", btn["data-popup"]
    assert_includes btn["aria-label"].to_s, job.name,
      "the accessible name must name the job it belongs to"
    assert_equal "Proof information for #{job.name}", btn["title"]
    assert_includes btn.to_html, "<svg", "it is a paper icon, not a glyph"

    # Exactly one: the bare job gets no dead button.
    assert_equal 1, d.css(".cs-job-proof").size
    row = d.css("tr").find { |r| r.text.include?("bare") }
    refute_nil row
    assert_nil row.at_css(".cs-job-proof"), "a job with no proof gets NO button"
  end

  test "the popup is the shared partial, so it carries the same detail" do
    _job, proof, = setup_jobs
    d = page
    popup = d.at_css("#proof-detail-#{proof.id}")
    refute_nil popup, "the popup body must be rendered on the list page too"

    text = popup.text
    # Metrics, findings and the links -- the same content as the results page.
    %w[state hard advisory inks nodes dpi].each do |m|
      assert_includes text, m, "the #{m} metric"
    end
    assert_includes text, "COLOR_COUNT", "and the findings themselves"
    assert_includes text, "7 colours, 6 allowed", "with their detail"
    assert_includes text, "Proof PNG"
    assert_includes text, "Print PDF"
    assert_includes text, "Open proof"
    assert_includes text, "Raw manifest"
    assert_includes popup.at_css("a[href*='/proofs/']")["href"], "/proofs/#{proof.id}"
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
    src = Rails.root.join("app/controllers/jobs_controller.rb").read
    index = src[/def index.*?\n  end/m]
    assert_match(/includes\(:validations\)/, index,
      "50 rows x a lazy has_many is 50 extra queries on every list load")
  end

  test "the results page renders the same shared partial" do
    _job, = setup_jobs
    show = File.read(Rails.root.join("app/views/jobs/show.html.erb"))
    assert_includes show, 'render "validations/proof_detail"'
    refute_includes show, "vm = v.manifest",
      "the seven locals are gone -- they lived in the page and the list " \
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
