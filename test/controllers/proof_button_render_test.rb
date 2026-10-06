require "test_helper"

# Renders the real jobs/show page through the full Rails stack (routing, Erubi,
# authenticated layout) so the Proof button's classes are checked as SHIPPED
# rather than through a hand-built view context -- an earlier attempt at that
# failed on url_for needing a request, which says nothing about the view.
class ProofButtonRenderTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def sign_in
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # A done job whose comparison carries two candidates and NO proofs, so the
  # view takes the `else` branch and renders the run-Proof button for both.
  def job_with_unproofed_candidates
    job = Job.create!(name: "ring", state: "done", source_kind: "svg",
                      input_path: "/data/x.svg", stem: "ring", spec: {}, runner: "mock")
    job.update!(comparison: {
      "candidates" => [
        { "file" => "candidate_01.svg", "hard" => 0, "advisory" => 0, "mae_art" => "12.3" },
        { "file" => "candidate_02.svg", "hard" => 1, "advisory" => 2, "mae_art" => "30.1" }
      ]
    })
    job
  end

  test "candidates table Proof buttons carry the damped ring class" do
    sign_in
    job = job_with_unproofed_candidates

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    html = response.body

    assert_includes html, "cs-proof-btn",
      "the Proof button must carry .cs-proof-btn so its ring is damped"

    # CHANGED (scoped to the candidates table, which is what the message below
    # always claimed to check): the scan used to run over the WHOLE page, and
    # the job page's action bands (added after this test, "two action bands
    # under the preview") put a full-strength primary "Run Job" button in the
    # sticky head band -- `btn btn-primary btn-sm job-persist-btn`, correctly
    # undamped: the damping exists because a COLUMN of Proof buttons glowed
    # like beacons (repetition), not because the page may hold no other
    # primary button at all. Read the view first: the only other primary
    # btn-sm on this page are that single head action and the per-proof "Jev"
    # button in the proofs table (not rendered here: this job has no proofs).
    # So the contract is pinned where it lives -- inside the candidates table.
    doc = Nokogiri::HTML(html)
    candidates_table = doc.css("table.candidates").find do |t|
      !t["class"].to_s.split.include?("proofs-tbl")
    end
    refute_nil candidates_table, "the candidates table must render"
    undamped = candidates_table.to_html.scan(/btn btn-primary btn-sm(?! cs-proof-btn)/)
    assert_empty undamped,
      "every btn-primary btn-sm in the candidates table should be damped, " \
      "found #{undamped.size} undamped"
  end

  # The damping is a property of REPETITION, not of the Proof action: the
  # single Proof button in the candidate preview popup keeps the full-strength
  # ring. Pinned here because it is a one-line edit in a JS string that no view
  # test would catch.
  test "the preview popup's single Proof button is NOT damped" do
    src = Rails.root.join("app/javascript/aether.js").read
    proof_line = src.lines.find { |l| l.include?("cs-proof-run") && l.include?("btn-primary") }
    refute_nil proof_line, "expected a cs-proof-run button in aether.js"
    assert_includes proof_line, "cs-proof-run",
      "the popup Proof button must keep its own class"
    refute_includes proof_line, "cs-proof-btn",
      "the popup Proof button must NOT be damped — it is the only one on screen"
  end
end
