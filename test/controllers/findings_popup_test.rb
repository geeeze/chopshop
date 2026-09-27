require "test_helper"

# The Findings & detail popup (jobs#show, opened via data-cs-detail and drawn by
# detailHtml() in the page's inline script) must show FINDINGS and FIDELITY
# properly. The candidates TABLE must stop carrying the fidelity detail that
# belongs in the popup.
#
# These assertions pin both halves, and the bug behind the complaint: the
# comparison entries never carry "fidelity_verdict" (the keys are file, sweep,
# layer_a, layer_b, hard, advisory, fidelity, passed), so the table used to say
# "faithful" for every candidate whatever the MAE -- a candidate with mae_art
# 91.2 read exactly like one with 14.51. The verdict is now DERIVED from the
# fidelity numbers, once, in Job (Job.fidelity_verdict / .fidelity_status), and
# both the table cell and the popup read the same derived value.
class FindingsPopupTest < ActionDispatch::IntegrationTest
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

  # Four candidates spanning every band, plus an unmeasured one. None carries
  # "fidelity_verdict": the real runner never sends it.
  def job_with_candidates
    job = Job.create!(name: "findings", state: "done", source_kind: "svg",
                      input_path: "/data/x.svg", stem: "fp", spec: {}, runner: "mock")
    job.update!(comparison: {
      "candidates" => [
        candidate("candidate_01.svg", mae_art: 14.51), # <= 25 -> faithful
        candidate("candidate_02.svg", mae_art: 40.0),  # <= 60 -> drift
        candidate("candidate_03.svg", mae_art: 91.2),  # else  -> lost
        candidate("candidate_04.svg", measured: false) # unmeasured
      ]
    })
    job
  end

  def candidate(file, measured: true, mae_art: nil)
    {
      "file" => file, "hard" => 0, "advisory" => 1, "passed" => true,
      "sweep" => { "preset" => "poster", "hierarchical" => "stacked",
                   "filter_speckle" => 8 },
      "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" },
      "fidelity" => { "measured" => measured, "mae" => 26.99, "mae_art" => mae_art,
                      "p95" => 87.9, "within_10" => 0.767 }
    }
  end

  def page(job)
    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def fidelity_cells(doc)
    table = doc.at_css("table.candidates")
    idx = table.css("thead th").map { |t| t.text.strip }.index("Fidelity")
    refute_nil idx, "the Fidelity column stays"
    table.css("tbody tr").map { |tr| tr.css("td")[idx] }
  end

  def popup_script(doc)
    node = doc.css("script").find { |s| s.text.include?("function detailHtml") }
    refute_nil node, "the inline detail popup script"
    node.text
  end

  test "the table derives the verdict from the numbers, not a key that never exists" do
    sign_in
    doc = page(job_with_candidates)

    cells = fidelity_cells(doc)
    verdicts = cells.map { |td| td.at_css(".status-pill").text.strip }
    assert_equal %w[faithful drift lost unmeasured], verdicts,
                 "mae_art 14.51 / 40 / 91.2 / unmeasured must not all read 'faithful'"

    classes = cells.map { |td| td.at_css(".status-pill")["class"] }
    assert_match(/status-pass/, classes[0])
    assert_match(/status-warn/, classes[1])
    assert_match(/status-fail/, classes[2])
    assert_match(/status-pending/, classes[3], "an unmeasured verdict is not a failure")
  end

  test "the Fidelity cell holds one pill and nothing else" do
    sign_in
    doc = page(job_with_candidates)

    fidelity_cells(doc).each do |td|
      assert_equal 1, td.css(".status-pill").size, "one pill per cell: #{td.text.strip}"
      assert_equal 1, td.element_children.size,
                   "the pill is the whole cell -- the MAE moved to the popup"
    end
    assert_empty doc.css(".fid-mae"), "the MAE under the pill is what bloated the cell"
  end

  test "the popup's JSON carries the derived verdict for the candidate" do
    sign_in
    job = job_with_candidates

    get job_path(job, format: :json, candidate: "candidate_03.svg"),
        headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
    assert_response :success
    sweep = JSON.parse(response.body).fetch("sweep")
    assert_equal "lost", sweep["fidelity_verdict"]
    assert_equal "fail", sweep["fidelity_status"],
                 "the popup pill uses the same status class as the table"
    assert_equal 91.2, sweep.dig("fidelity", "mae_art")

    get job_path(job, format: :json, candidate: "candidate_04.svg"),
        headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
    unmeasured = JSON.parse(response.body).fetch("sweep")
    assert_equal "unmeasured", unmeasured["fidelity_verdict"]
    assert_equal "pending", unmeasured["fidelity_status"]
  end

  test "the popup opens with a Fidelity section holding the verdict and the four numbers" do
    sign_in
    script = popup_script(page(job_with_candidates))

    assert_includes script, ">Fidelity</h4>"
    assert_includes script, "cs-fidelity"
    assert_operator script.index(">Fidelity</h4>"), :<, script.index(">Findings</h4>"),
                    "fidelity comes first: it exists even with no proof"
    assert_match(/fh\.fidelity_status/, script)
    assert_match(/fh\.fidelity_verdict/, script)
    %w[MAE\ all MAE\ art P95 within\ 10].each do |label|
      assert_includes script, "'#{label}'",
                      "#{label} belongs to the Fidelity section"
    end
  end

  test "the general Metrics grid no longer repeats the four fidelity numbers" do
    sign_in
    script = popup_script(page(job_with_candidates))

    rows = script[/var rows = \[(.*?)\];/m, 1]
    refute_nil rows, "the Metrics grid rows list"
    %w[MAE\ all MAE\ art P95 within\ 10].each do |label|
      refute_includes rows, label, "#{label} moved, not duplicated"
    end
    %w[preset speckle hierarchical variant palette nodes size inks].each do |k|
      assert_includes rows, k, "the rest of the metrics stay"
    end
  end

  test "with no proof the popup keeps 'No proof yet' and still shows fidelity" do
    sign_in
    script = popup_script(page(job_with_candidates))

    assert_includes script, "No proof yet"
    assert_includes script, ">Fidelity</h4>",
                    "the fidelity numbers come from the sweep entry, not the proof"
    assert_includes script, ">Findings</h4>"
    assert_match(/bh && bh\.findings/, script, "findings still read from the proof")
  end

  test "the popup still receives a proof's findings when one exists" do
    sign_in
    job = job_with_candidates
    job.validations.create!(file: "candidate_01.svg", state: "done",
      manifest: { "proof" => "proof_01.png",
                  "findings" => [{ "rule" => "min_stroke_width_pt",
                                   "severity" => "hard", "layer" => "A",
                                   "detail" => "Stroke 1.2pt is below the 1.5pt floor" }] })

    get job_path(job, format: :json, candidate: "candidate_01.svg"),
        headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
    assert_response :success
    data = JSON.parse(response.body)
    assert_equal "min_stroke_width_pt", data.dig("proof", "findings", 0, "rule")
    assert_equal "faithful", data.dig("sweep", "fidelity_verdict"),
                 "the fidelity verdict rides along with the proof"
  end
end
