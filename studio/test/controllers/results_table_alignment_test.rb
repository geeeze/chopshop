require "test_helper"

# Two contracts on the results/proofs tables (jobs#show), changed together:
#
# 1. The tables render in JetBrains Mono (--font-mono). The whole table is data
#    — filenames, presets, counts, states — so it reads as metrics, not prose.
# 2. Every column is centred EXCEPT preview, name and the icon-button actions.
#    Centred: Preset, Layer A, Layer B on the candidates table; State on the
#    proofs table. Left: Preview (a thumbnail) and the name column (Proof); the
#    actions column is flex-end'd buttons, not data.
#
# The jobs LIST (index) centring is covered separately by
# jobs_table_alignment_test.rb — this file is the show-page tables and the font.
class ResultsTableAlignmentTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def css
    File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  def sign_in
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" },
                      headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def candidate(file)
    { "file" => file, "hard" => 0, "advisory" => 1, "passed" => true,
      "sweep" => { "preset" => "poster" },
      "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" },
      "fidelity" => { "measured" => true, "mae_art" => 14.5 } }
  end

  def doc
    job = Job.create!(name: "align", state: "done", source_kind: "svg",
                      input_path: "/d/x.svg", stem: "al", spec: {}, runner: "mock")
    job.update!(comparison: { "candidates" => [candidate("candidate_01.svg")] })
    job.validations.create!(file: "candidate_01.svg", state: "done",
                            manifest: { "proof" => "proof_01.png" })
    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def cell_classes(table, header, row: 0)
    ths = table.css("thead th")
    heads = ths.map { |t| t.text.strip }
    i = heads.index(header)
    refute_nil i, "#{header} has a header in the #{table["class"]} table"
    [ths[i]["class"].to_s, table.css("tbody tr")[row].element_children[i]["class"].to_s]
  end

  test "the candidates and proofs tables render in the mono face" do
    assert_match(/table\.candidates \{[^}]*font-family:\s*var\(--font-mono\)/, css,
      "table.candidates carries --font-mono, so the jobs list, candidates and " \
      "proofs tables all render their data in JetBrains Mono")
  end

  test "the candidates table centres Preset, Layer A and Layer B — header and cell" do
    sign_in
    table = doc.at_css("table.candidates:not(.proofs-tbl)")
    %w[Preset Layer\ A Layer\ B].each do |name|
      th, td = cell_classes(table, name)
      assert_includes th, "col-center", "#{name}: the header is marked"
      assert_includes td, "col-center", "#{name}: the cell is marked"
    end
  end

  test "the proofs table centres State — header and cell" do
    sign_in
    table = doc.at_css("table.proofs-tbl")
    th, td = cell_classes(table, "State")
    assert_includes th, "col-center", "State: the header is marked"
    assert_includes td, "col-center", "State: the cell is marked"
  end

  test "the proofs table offers a download button beside the detail icon" do
    sign_in
    table = doc.at_css("table.proofs-tbl")
    actions = table.at_css("tbody tr .cs-row-actions")

    download = actions.at_css("a.cs-job-download")
    refute_nil download, "a finished proof with a render has a download on the row"
    assert_includes download["aria-label"], "Download proof PNG",
      "the download is for the proof PNG, not the SVG"

    detail = actions.at_css("[data-popup^='proof-detail-']")
    refute_nil detail, "the detail icon sits beside the download, not instead of it"
    # download comes first in source order, matching the candidates row.
    assert_operator actions.element_children.index(download), :<,
                    actions.element_children.index(detail),
      "download leads, detail follows — the same order as the candidates row"
  end

  test "preview, name and actions stay out of the centred set" do
    sign_in
    d = doc
    cand = d.at_css("table.candidates:not(.proofs-tbl)")
    th_thumb, td_thumb = cell_classes(cand, "Preview")
    refute_includes th_thumb, "col-center", "Preview (a thumbnail) stays left"
    refute_includes td_thumb, "col-center", "Preview (a thumbnail) stays left"

    proofs = d.at_css("table.proofs-tbl")
    th_proof, td_proof = cell_classes(proofs, "Proof")
    refute_includes th_proof, "col-center", "the name column stays left"
    refute_includes td_proof, "col-center", "the name column stays left"
  end
end
