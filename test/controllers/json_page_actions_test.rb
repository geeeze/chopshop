require "test_helper"

# The JSON page's title row carries two stacked actions: Run Job (which runs the
# job, asking first) and JSON (which opens the editable contract in a wide
# terminal-styled panel). Both replaced a pair of glyph-only buttons wedged into
# the title line.
class JsonPageActionsTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def page
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get json_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    response.body
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def css_without_comments
    Rails.root.join("app/assets/stylesheets/application.css").read
         .gsub(%r{/\*.*?\*/}m, "")
  end

  test "the head carries Run Job above JSON, both labelled" do
    html = page
    doc = Nokogiri::HTML(html)

    head = doc.at_css(".page-head-row--split")
    refute_nil head, "the head must be a split row so the actions sit right"
    refute_nil head.at_css(".section-title"), "the title shares that row"

    kids = head.element_children.select { |el| %w[a button].include?(el.name) }
    assert_equal 2, kids.size, "Run Job and JSON, and nothing else"

    run, json = kids
    assert_equal "useSpecBtn", run["id"]
    assert_equal "Run Job", run.text.strip
    assert_no_match(/✂|＋/, run.text, "no glyph and no leading plus on Run Job")

    assert_equal "JSON", json.text.strip, "the viewer is labelled JSON, not an icon"
    assert_nil json.at_css("svg"), "the old SVG document icon is gone, not just hidden"
    assert_equal "spec-popup", json["data-popup"]

    # JSON sits on the line BELOW Run Job: after it in source order, and in
    # grid row 2 (the head is a grid now, not a flex row with a button column).
    assert_operator head.element_children.index(json), :>,
                    head.element_children.index(run)
    assert_includes run["class"].split, "head-action"
    assert_includes json["class"].split, "head-action"
    stacked = css_without_comments[/\.page-head-row--stacked \{.*?\}/m]
    assert_includes stacked, "display: grid", "the two actions stack in a grid"
    assert_match(/\.page-head-row--stacked > \.head-action--top\s*\{\s*grid-row: 1/, css_without_comments)
    assert_match(/\.page-head-row--stacked > \.head-action--below\s*\{\s*grid-row: 2/, css_without_comments)
  end

  test "Run Job asks Confirm? | Cancel | Run Job before running" do
    html = page
    doc = Nokogiri::HTML(html)

    run = doc.at_css("#useSpecBtn")
    assert_equal "button", run["type"], "it must be able to ask before doing anything"

    assert_includes html, "Confirm?",
      "the dialog is titled Confirm?, matching the Run Job page"
    refute_includes html, "Use JSON?",
      "the old 'Use JSON?' title is gone"
    assert_includes html, "useSpecOk",
      "the confirm dialog must have a Run Job confirm button"
    assert_includes html, 'data-cs-close="1">Cancel'
    assert_match(/id="useSpecOk"[^>]*>Run Job</, html,
      "the confirm button is labelled Run Job, not a scissor glyph")
    assert_includes html, "submitSpec",
      "confirming must still reach the real submit"
  end

  test "the contract panel is a wide editable terminal" do
    html = page
    doc = Nokogiri::HTML(html)

    panel = doc.at_css("#spec-popup .popup-panel")
    refute_nil panel, "the popup panel must exist"
    assert_includes panel["class"], "popup-terminal"
    refute_includes panel["class"], "popup-narrow-tall",
      "the old 34rem column is replaced, not merely overridden"

    css = css_without_comments
    term = css[/\.popup-terminal \{[^}]*\}/m]
    # 60vw, NOT 60%: a percentage resolves against the parent's content box and
    # .popup is padded, so `width: 60%` measured 55.6% of the window.
    assert_match(/width: 39vw/, term,
      "the panel is 30% of the VIEWPORT -- half of the 60vw it was")
    assert_includes term, "min-width",
      "60% alone collapses to nothing on a narrow window"
    narrow = css_without_comments[/@media \(max-width: 900px\) \{\s*\.popup-terminal \{[^}]*\}/m]
    refute_nil narrow, "below 900px the panel must go full width, or it overflows"
    assert_includes narrow, "width: 100%"

    # Dark terminal styling, not a form field.
    assert_match(/\.spec-terminal \{[^}]*background: #0b0d10;/m, css)
    assert_match(/\.spec-terminal \{[^}]*color: #7ee787;/m, css)
    assert_match(/\.spec-terminal \{[^}]*font-family|var\(--font-mono\)/m, css)

    ta = doc.at_css("#specOutput")
    refute_nil ta, "the contract textarea must exist"
    assert_equal "textarea", ta.name, "it must be EDITABLE, not a <pre>"
    refute ta.key?("readonly"), "editing must not be blocked"
  end

  test "the panel closes with a Close word, not a times glyph" do
    html = page
    doc = Nokogiri::HTML(html)

    head = doc.at_css("#spec-popup .popup-head")
    refute_nil head, "the panel head must exist"

    close = head.at_css("[data-popup-close]")
    refute_nil close, "a close control must exist"
    assert_equal "Close", close.text.strip,
      "the dismiss control is the word Close, not an &times; glyph"
    refute_match(/&times;|×/, close.to_s, "the old times glyph must be gone")
    refute_includes close["class"].split, "popup-close",
      "the round icon-button styling goes with the glyph"
    assert_includes css_without_comments, ".popup-close-text",
      "the word button carries its own rule"
  end

  test "the popup is still reachable and the builder still writes into it" do
    html = page

    # The JSON button opens it via the shared data-popup mechanism.
    assert_includes html, 'data-popup="spec-popup"'
    assert_includes html, 'id="spec-popup"'
    # The builder JS writes the contract into #specOutput; that wiring is the
    # whole point of the panel being editable.
    assert_includes html, "specOutput"
    assert_includes html, "copySpecBtn"
  end
end
