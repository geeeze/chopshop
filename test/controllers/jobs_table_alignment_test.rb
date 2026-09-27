require "test_helper"

# Two things on the Jobs table, both measured in a browser because neither is
# visible from the stylesheet alone.
#
# 1. State / Passed / Queued are centred.
# 2. The 7z download button is a floppy disk and still holds its 32x32 box.
class JobsTableAlignmentTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def view
    File.read(Rails.root.join("app/views/jobs/index.html.erb"))
  end

  def css
    File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  # A row is needed to look at: the table renders no tbody at all when the
  # Jobs list is empty, so a header-only page passes every alignment check
  # without proving anything.
  def seed!
    Job.create!(name: "align", state: "done", source_kind: "svg",
                input_path: "/d/x.svg", stem: "al", spec: {}, runner: "mock",
                comparison: { "candidates" => [] })
  end

  def doc
    seed!
    o = ENV["CHOPSHOP_PASSWORD"]; ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    ENV["CHOPSHOP_PASSWORD"] = o
    get jobs_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  test "State, Passed and Queued are centred -- header and cell" do
    d = doc
    row = d.at_css("table.candidates tbody tr")
    refute_nil row
    ths = d.css("table.candidates thead th")
    %w[State Passed Queued].each do |name|
      th = ths.find { |t| t.text.strip == name }
      refute_nil th, "the #{name} header"
      assert_includes th["class"].to_s, "col-center", "#{name}: the header is marked"
    end

    heads = ths.map { |t| t.text.strip }
    %w[State Passed Queued].each do |name|
      i = heads.index(name)
      refute_nil i, "#{name} has a header"
      cell = row.element_children[i]
      assert_includes cell["class"].to_s, "col-center",
        "#{name}: the cell is marked, or the header centres over left-hung data"
    end

    # Preview and Name stay left: centring a thumbnail or a name would break the
    # alignment with the block above.
    row.element_children[0..1].each do |c|
      refute_includes c["class"].to_s, "col-center", "Preview and Name stay left"
    end
  end

  test "the centring rule is specific enough to win" do
    assert_match(/table\.candidates th\.col-center,\s*\ntable\.candidates td\.col-center \{ text-align: center; \}/, css,
      "(0,2,2) on purpose: `table.candidates th` is already (0,1,1) with " \
      "text-align:left, so a bare .col-center (0,1,1) would TIE and lose on " \
      "source order. This mirrors the .col-narrow rule beside it.")
  end

  test "the download button draws an inline SVG, not a text glyph" do
    # It was U+1F5AB, a TEXT glyph, and Press Start 2P does not contain that
    # codepoint -- so it silently fell back to another font and drew at a
    # different visual size inside an identical 32px box. Twelve rows of that
    # reads as a broken column while every measurement of the button itself
    # reports it as fine. An inline SVG cannot fall back.
    refute_includes view, "\u{1F5AB}", "the glyph that fell back to another font"
    refute_includes view, "\u{1F4BE}", "the colour-presentation floppy, which " \
      "renders as a full-colour emoji inside a 32px monochrome button"
    refute_includes view, 'link_to "⬇"',
      "a down arrow says 'this goes somewhere'"

    # Same 14x14 inline SVG the Proof control it replaced drew.
    assert_match(/link_to download_job_path\(job\)/, view, "link_to with a block")
    assert_match(/<svg width="14" height="14"/, view)
  end

  test "the download button keeps the same size as every other icon button" do
    assert_match(/\.cs-row-actions \.btn-icon \{[^}]*flex: 0 0 auto;[^}]*\}/, css,
      "a flex item defaults to flex-shrink:1, so `width: 2rem` is a request, " \
      "not a size -- this is what collapsed the Proof button to 7.48px")
  end

  test "the button still carries the 7z tooltip and an accessible name" do
    assert_match(/class: "btn btn-icon cs-job-download", title: "Download 7z"/, view)
    assert_match(/"aria-label" => "Download #\{job\.name\}"/, view,
      "the glyph is an icon, so the name has to be spoken")
  end
end
