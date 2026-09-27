require "test_helper"

# The Jev page: gamer-font responses, bigger questions, examples behind "?",
# and the conf preview.
#
# FONT. The example response is the GAMER FONT -- `--font-pixel`, which is
# Press Start 2P, already loaded for `.job-stat .value`. It is set to 0.62rem,
# well under the 1rem the old monospace answer used, because a pixel face is
# roughly half the x-height of a proportional one at the same size. The
# question above it went the other way, 0.72rem -> 0.95rem: at 0.72rem it read as
# a caption above the answer rather than as the thing you read first.
#
# EXAMPLES. The twenty-two example cards used to be inline, which made the page a
# wall. Each is now a popup behind its own section's "?", in the same card-head
# slot and the same `.help-btn` the JSON page uses.
#
# CONF. JevConf mirrors chopshop-jev's QUESTIONS + CONFIDENCE_FLOOR. The
# annotator has NO conf input -- QUESTIONS is a module constant that
# build_envelope() deep-copies, and the CLI exposes no --questions flag -- so the
# editor validates and previews and does not change what is asked. That is
# asserted here so nobody ships it as if it did.
class JevPageTest < ActionDispatch::IntegrationTest
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

  def css
    Rails.root.join("app/assets/stylesheets/application.css").read
  end

  SECTIONS = %w[failure_mode print_route tonal_structure evidence_is_actionable].freeze

  test "the response is the gamer font, at a size a pixel face can be read at" do
    assert_match(/--font-pixel:\s*'Press Start 2P'/, css,
      "the gamer font must be the pixel face already loaded, not a new download")

    a = css[/\.jev-card \.a \{[^}]*\}/m]
    refute_nil a
    assert_match(/font-family: var\(--font-pixel\)/, a)
    # A pixel face at the old 1rem was illegible; the size has to DROP even though
    # the user asked for the font change, not a size change.
    size = a[/font-size: ([\d.]+)rem/, 1].to_f
    assert_operator size, :<, 0.8, "measured 0.62rem"
    assert_match(/line-height: 1\.9/, a, "a pixel face needs the leading opened up")
    assert_match(/overflow-wrap: anywhere/, a,
      "long option names like render_or_tool_failure have nothing to break on")
  end

  test "the example question got bigger" do
    q = css[/\.jev-card \.q \{[^}]*\}/m]
    size = q[/font-size: ([\d.]+)rem/, 1].to_f
    assert_operator size, :>, 0.9, "0.72rem -> 0.95rem"
    assert_operator size, :>, 0.72, "it was 0.72rem before"
  end

  test "every section has a ? in its card-head, and the name contains the title" do
    d = doc
    SECTIONS.each do |key|
      card = d.css(".jev-section").find { |c| c.at_css("h3")&.text.to_s.include?(key) }
      refute_nil card, "a card for #{key} must exist"
      btn = card.at_css(".card-head .help-btn")
      refute_nil btn, "#{key}'s ? must sit in the card-head, beside the title"
      assert_equal "button", btn.name
      assert_includes btn["aria-label"].to_s, key,
        "the accessible name must contain the visible label (WCAG 2.5.3)"
      assert_equal "?", btn.text.strip, "and the visible glyph is still ?"
    end
  end

  test "the ? icons are the only place the examples live" do
    d = doc
    # No example card inline: the page is six short cards, not 22.
    assert_equal 0, d.css(".jev-section .jev-card").size,
      "the examples belong in popups, not in the page body"
    # Every ? points at a template that exists and carries cards.
    buttons = d.css(".help-btn[data-jev-examples]")
    assert_operator buttons.size, :>=, 6
    buttons.each do |b|
      key = b["data-jev-examples"]
      tpl = d.at_css("template#jevExamples-#{key}")
      refute_nil tpl, "the ? for #{key} has no template to open"
      assert_operator tpl.css(".jev-card").size, :>=, 2, "#{key} has examples"
    end
  end

  test "the answers are succinct" do
    d = doc
    SECTIONS.each do |key|
      tpl = d.at_css("template#jevExamples-#{key}")
      tpl.css(".jev-card .a").each do |a|
        words = a.text.strip.split(/\s+/).size
        assert_operator words, :<=, 8,
          "#{key}: #{a.text.strip.inspect} is #{words} words -- these are labels, not prose"
      end
    end
  end

  test "the conf button sits under Run Job, like the JSON page's" do
    d = doc
    row = d.at_css(".page-head-row--stacked")
    refute_nil row, "the head is the stacked grid, so Jev conf lands in row 2 col 2"
    assert_includes row["class"].split, "page-head-row--stacked"

    btn = d.at_css("#jevConfBtn")
    refute_nil btn
    assert_includes btn["class"], "head-action", "so it is the same box as every other head action"
    assert_equal "Jev conf", btn.text.strip
    # The JSON page's accessibility rule, applied here too.
    assert_equal "Jev conf", btn["aria-label"]
  end

  test "the conf preview is editable, validated, and has a Run default" do
    d = doc
    tpl = d.at_css("template#jevConfTemplate")
    refute_nil tpl

    ta = tpl.at_css("textarea#jevConfText")
    refute_nil ta, "the conf is EDITABLE, like the JSON page's spec popup"
    assert_equal "Jev configuration", ta["aria-label"]
    # ERB `h()` escapes the JSON on the way out, but Nokogiri has already decoded
    # the entities by the time we read .text -- so this compares against the RAW
    # default. (Comparing to the literal string "JevConf.default_json" was my own
    # bug: it can never match. Escaping it here instead is also wrong.)
    assert_equal JevConf.default_json.strip, ta.text.strip,
      "it opens showing the REAL default, not a placeholder"
    assert_includes ta.text, '"failure_mode"'
    assert_includes ta.text, '"confidence_floor": 0.6' 

    refute_nil tpl.at_css("#jevConfReset"), "Run default restores it"
    refute_nil tpl.at_css("#jevConfApply"), "and it can be validated"
    refute_nil tpl.at_css("#jevConfStatus[role=status]"), "the result is announced"
    assert_operator tpl.css(".jev-conf-metric-list li").size, :>=, 5,
      "the metrics each mode is measured against are listed, not hidden"
  end

  test "the preview says plainly that it does not yet change what is asked" do
    warn_text = doc.at_css("template#jevConfTemplate .jev-conf-warn").text
    assert_match(/preview only/i, warn_text)
    assert_match(/QUESTIONS/, warn_text)
    assert_match(/--questions/, warn_text,
      "the missing flag is named, so the gap is actionable rather than mysterious")
  end

  test "the conf mirror matches the annotator's four questions and floor" do
    assert_equal 0.6, JevConf::DEFAULT["confidence_floor"],
      "CONFIDENCE_FLOOR in jev_annotate.py"
    assert_equal SECTIONS.sort, JevConf::DEFAULT["questions"].keys.sort
    JevConf::DEFAULT["questions"].each do |name, q|
      assert_includes %w[choice score noul], q["type"], "#{name}'s type"
      refute_nil q["instructions"], "#{name} has instructions in the annotator"
      refute_empty q["criteria"], "#{name} has criteria in the annotator"
    end
    # tonal_structure is the one scored question, so its criteria are a list.
    assert_kind_of Array, JevConf::DEFAULT["questions"]["tonal_structure"]["criteria"]
  end

  test "JevConf.parse refuses what would make a useless or broken run" do
    ok, err = JevConf.parse(JevConf.default_json)
    refute_nil ok
    assert_nil err

    _, err = JevConf.parse("{oops")
    assert_match(/invalid JSON/, err)

    _, err = JevConf.parse("[]")
    assert_match(/must be a JSON object/, err)

    _, err = JevConf.parse('{"confidence_floor":0.6}')
    assert_match(/needs a "questions" object/, err)

    _, err = JevConf.parse('{"questions":{}}')
    assert_match(/cannot be empty/, err, "Jev would be asked nothing")
  end
end
