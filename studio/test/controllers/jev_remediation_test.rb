require "test_helper"

# The Jev page's remediation-table popup and the three-button head.
class JevRemediationTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get jev_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def view
    File.read(Rails.root.join("app/views/pages/jev.html.erb"))
  end

  def css
    File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  # ---- the head ----

  test "the head is Run Job, TABLE, JSON" do
    d = doc
    acts = d.css(".page-head .head-action")
    assert_equal ["Run Job", "TABLE", "JSON"], acts.map { |a| a.text.strip },
      "the remediation table is what a failure_mode becomes, so it is the one " \
      "you reach for when an answer looks wrong; the conf is what you edit"

    # TABLE and JSON share ONE grid cell and flex inside it. Stacking them made
    # the head three lines tall for two buttons that open the same kind of
    # thing, so the cell is the pair, not either button.
    pair = d.at_css(".page-head .head-action-pair")
    assert pair, "the pair wrapper is gone; the two buttons are back to stacked rows"
    assert_includes pair["class"].split, "head-action--below", "the pair is the row-2 cell"
    assert_equal ["TABLE", "JSON"], pair.css("button").map { |b| b.text.strip },
      "TABLE is on the left, JSON on the right"
    acts[1..2].each do |b|
      refute_includes b["class"].split, "head-action--below",
        "the grid places the pair, not either button"
      refute_includes b["class"].split, "head-action--third",
        "there is no third row any more"
    end
    assert_match(/\.head-action-pair \{ display: flex; gap: var\(--space-sm\); align-items: stretch; \}/, css)
    refute_match(/head-action--third/, css, "the third row is gone from the stylesheet too")
  end

  test "the pair keeps its place on a narrow screen" do
    media = css[/@media \(max-width: 860px\) \{(.*?)\n\}/m, 1]
    # The pair is the --below cell, so the existing narrow rule moves it whole.
    assert_match(/\.page-head-row--stacked > \.head-action--below \{ grid-row: 4; grid-column: 1; \}/, media)
  end

  test "all three are secondary except Run Job" do
    d = doc
    acts = d.css(".page-head .head-action")
    assert_includes acts[0]["class"], "btn-primary"
    assert_includes acts[1]["class"], "btn-secondary"
    assert_includes acts[2]["class"], "btn-secondary"
  end

  # ---- the links ----

  test "both mentions of remediation_table.json open the popup" do
    d = doc
    links = d.css('a.jev-file-link[data-popup="jev-remediation-popup"]')
    assert_equal 2, links.size,
      "the Metrics card hint, and the mention inside the metrics ? template"
    links.each { |a| assert_includes a.text, "remediation_table.json" }

    # One of the two lives in the metrics ? TEMPLATE, whose content is inert
    # until the popup renders it -- so in a browser only ONE is live at load,
    # and the other appears when the ? is opened. Nokogiri's HTML4 parser does
    # not implement template inertness, so it counts both here; the browser
    # probe is what pins the live count.
    tpl = d.at_css("template#jevExamples-__metrics")
    refute_nil tpl
    assert_operator tpl.css('a.jev-file-link').size, :>=, 1
  end

  test "each link names the file for a screen reader" do
    d = doc
    d.css('a.jev-file-link').each do |a|
      assert_includes a["aria-label"].to_s, "remediation_table.json"
      assert_includes a["title"].to_s, "remediation_table.json"
    end
  end

  # ---- the popup ----

  test "the popup is 67% of the viewport" do
    assert_match(/\.popup-remediation \{ width: 67vw; min-width: 30rem; max-height: 92vh; \}/, css,
      "vw not %: .popup carries clamp(1rem, 4vw, 3rem) padding and a percentage " \
      "resolves against that content box")
  end

  test "the conf popup is still 39vw" do
    assert_match(/\.popup-terminal \{[^}]*width: 39vw;/m, css,
      "adding TABLE must not have widened the conf editor")
  end

  test "the popup holds the real file and it is valid" do
    ta = doc.at_css("#jevRemediationOutput")
    refute_nil ta
    parsed = JSON.parse(ta.text)
    assert_equal 10, parsed["remedies"].size
    assert_equal %w[failure_mode loopable needs_tracer grounds_in metrics remedy _why],
      parsed["remedies"].first.keys
  end

  test "the help is the file's OWN notes, not a paraphrase" do
    data = JSON.parse(JevConf.remediation_json)
    help = doc.at_css("#jev-remediation-popup .jev-help").text
    # Transcribed verbatim from the table's note keys, so it cannot drift from
    # the file it explains.
    assert_includes help, data["_grounding_note"]
    assert_includes help, data["_metrics_note"]
    assert_includes help, "grounds_in"
    assert_includes help, "rule_findings"
  end

  test "the popup says plainly that this page cannot write the file" do
    body = doc.at_css("#jev-remediation-popup .popup-body").text
    assert_match(/cannot write/i, body,
      "remediation_table.json lives in the Jev repo and jev_remediate.py reads " \
      "it from there. Editing it in a web page would be a fiction.")
    assert_match(/copy it out/i, body)
  end

  test "the file path resolves outside the Rails app, and degrades if missing" do
    path = JevConf.remediation_path
    refute path.to_s.start_with?(Rails.root.to_s),
      "it is a file in the Jev repo, not something this app owns"
    assert path.basename.to_s == "remediation_table.json"
    # A missing file must not 500 the page.
    assert_nil JevConf.remediation if !path.exist?
    assert JevConf.remediation_help.is_a?(Array)
  end

  test "the popup is a dialog and can be closed" do
    pop = doc.at_css("#jev-remediation-popup")
    assert_equal "dialog", pop["role"]
    assert_equal "true", pop["aria-modal"]
    assert_equal "jev-remediation-popup-title", pop["aria-labelledby"]
    refute_nil doc.at_css("#jev-remediation-popup [data-popup-close]")
    refute_nil doc.at_css("#copyJevRemediationBtn")
  end
end
