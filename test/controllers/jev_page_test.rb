require "test_helper"

# The Jev page, which got built backwards twice. The shape it must have:
#
#   BODY   the conf as FORM FIELDS, laid out like the JSON page's builder --
#          a card per question with a label, a control and a hint.
#   ?      reveals that question's EXAMPLE question/response pairs, in the
#          gamer font.
#   CONFIG a terminal-ish popup for viewing/editing the raw conf, exactly like
#          the JSON page's own JSON button.
#
# Getting these the wrong way round is the mistake this file exists to prevent,
# so it asserts the ASSIGNMENT of each element, not merely its presence: the
# ? must carry examples and NOT the conf, and CONFIG must carry the terminal
# and NOT a form.
#
# The dead-? bug also lives here: aether.js is loaded by
# javascript_importmap_tags, which emits a MODULE script. Module scripts are
# deferred, so they run AFTER a classic inline script. Capturing
# `var modal = window.CsModal` at IIFE time bound it to undefined and every ?
# hit `if (!modal) return`, silently. The lookup must happen at CLICK time.
class JevPageTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  SECTIONS = %w[failure_mode print_route tonal_structure evidence_is_actionable].freeze

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
    File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  def src
    File.read(Rails.root.join("app/views/pages/jev.html.erb"))
  end

  def card_for(d, name)
    d.css(".card").find { |c| c.at_css("h3")&.text&.strip == name }
  end

  # ---- the conf is in the BODY, as form fields ----

  test "each question is a card of form fields, in the JSON page's idiom" do
    d = doc
    SECTIONS.each do |name|
      card = card_for(d, name)
      refute_nil card, "#{name} must be a card in the page body, not a popup"

      # The JSON page's idiom: a label, a control, a hint.
      refute_nil card.at_css("select[aria-label='Type for #{name}']"), "a type control"
      refute_nil card.at_css("textarea[aria-label='Instructions for #{name}']"), "the instructions"
      refute_nil card.at_css("label[for='cf-#{name}-instructions']"), "a label for it"
      assert_operator card.css(".field .hint").size, :>=, 2, "fields carry hints"

      # The criteria are editable rows, prefilled from the conf.
      expected = JevConf::DEFAULT["questions"][name]["criteria"]
      want = expected.is_a?(Array) ? expected : expected.keys
      assert_equal want, card.css(".jev-criterion").map { |r| r.at_css(".jev-crit-value")["value"] },
        "#{name}: the card's rows and the conf's criteria must not drift"
    end
  end

  test "the score question's grade labels are read-only, a choice question's are not" do
    d = doc
    card_for(d, "tonal_structure").css(".jev-crit-value").each do |i|
      refute_nil i["readonly"], "tonal grades are fixed labels, not an answer vocabulary"
    end
    card_for(d, "failure_mode").css(".jev-crit-value").each { |i| assert_nil i["readonly"] }
  end

  test "the floor and the metrics are fields on the page too" do
    d = doc
    floor = d.at_css("#cf-floor")
    refute_nil floor, "the confidence floor is a field, not a popup"
    assert_equal "0.6", floor["value"]
    assert_equal JevConf::METRICS, d.at_css("#cf-metrics").text.strip.split("\n")
  end

  test "the conf form on the page is the ONE definition, not a per-popup copy" do
    d = doc
    # Exactly one set of #cf-floor / #cf-metrics. Duplicated ids are invalid HTML
    # and made the old CONFIG form fight the page form over the same node.
    assert_equal 1, d.css("#cf-floor").size
    assert_equal 1, d.css("#cf-metrics").size
    SECTIONS.each do |name|
      assert_equal 1, d.css("textarea#cf-#{name}-instructions").size, name
    end
  end

  # ---- the ? reveals EXAMPLES, not the conf ----

  test "each ? is in a card-head and opens that question's examples" do
    d = doc
    helps = d.css(".help-btn[data-jev-examples]")
    assert_equal 6, helps.size, "four questions, plus metrics and the floor"

    helps.each do |b|
      assert_equal "button", b.name
      assert_includes b.parent["class"].to_s, "card-head"
      refute_nil b.parent.at_css("h3")
      key = b["data-jev-examples"]
      tpl = d.at_css("template#jevExamples-#{key}")
      refute_nil tpl, "#{key} needs an examples template"
      # Examples, NOT a form: this inversion is what was wrong twice.
      assert_operator tpl.css(".jev-card").size, :>=, 2
      assert_nil tpl.at_css("select"), "the ? shows examples, not editable fields"
      assert_nil tpl.at_css("input"), "nor any input"
      assert_nil tpl.at_css(".jev-form"), "and certainly not a conf form"
    end
  end

  test "the examples are a question and a succinct response" do
    d = doc
    JevConf::EXAMPLES.each do |name, rows|
      cards = d.at_css("template#jevExamples-#{name}").css(".jev-card")
      assert_equal rows.size, cards.size, name
      cards.each_with_index do |c, i|
        assert_equal rows[i][0], c.at_css(".q").text.strip, "#{name}[#{i}] question"
        answer = c.at_css(".a")
        refute_nil answer, "#{name}[#{i}] must have a response"
        assert_equal rows[i][1], answer.text.strip, "#{name}[#{i}] response"
        # Succinct: the full criterion wording lives in the form field above, so
        # a response longer than this is a copy rather than a label.
        assert_operator answer.text.strip.split.size, :<=, 9,
          "#{name}[#{i}] response must stay succinct"
      end
    end
  end

  test "the response is the gamer font and the question is larger" do
    a = css[/\.jev-card \.a \{[^}]*\}/]
    assert_match(/font-family:\s*var\(--font-pixel\)/, a, "Press Start 2P, the gamer font")
    assert_operator a[/font-size:\s*([\d.]+)rem/, 1].to_f, :<, 0.8
    q = css[/\.jev-card \.q \{[^}]*\}/]
    assert_operator q[/font-size:\s*([\d.]+)rem/, 1].to_f, :>, 0.9,
      "the question reads at a normal size, not as a caption"
    d = doc
    assert_operator d.css(".jev-examples .jev-card .a").size, :>=, 20,
      "the font is on the examples, which is where it is visible"
  end

  # ---- CONFIG is the terminal, like JSON ----

  test "JSON is plain, under Run Job, and opens the terminal popup" do
    d = doc
    refute_nil d.at_css(".page-head-row--stacked"),
      "the stacked grid puts CONFIG in row 2 col 2"

    btn = d.at_css('[data-popup="jev-conf-popup"]')  # JSON, beside TABLE on row 2
    refute_nil btn, "the CONFIG button"
    assert_equal "JSON", btn.text.strip,
      "the same word the JSON page's own button uses"
    assert_includes btn["aria-label"].to_s, "jev.conf.json",
      "the tooltip names the file, the way the JSON page's button names its contract"
    assert_includes btn["class"], "btn-secondary"
    refute_includes btn["class"], "btn-primary", "plain, like JSON's button"
    # No row slot on the button itself: it shares the pair cell with TABLE.
    refute_includes btn["class"], "head-action--third",
      "there is no third row; JSON sits BESIDE TABLE"
    assert_equal btn.parent["class"].split & ["head-action-pair"], ["head-action-pair"],
      "JSON is inside the pair cell"

    run = d.css(".head-action").first
    assert_equal "Run Job", run.text.strip
    assert_includes run["class"], "head-action--top"
    assert_includes run["class"], "btn-primary"

    # The grid's placement is explicit, not :of-type -- :first-of-type and
    # :last-of-type count siblings of that ELEMENT TYPE, so an <a> beside a
    # <button> makes each both first and last of its own type. Both then matched
    # both rules, the later won, and the two buttons landed in the same cell.
    sheet = css
    refute_match(/head-action:first-of-type/, sheet, "the :of-type scheme is gone")
    assert_match(/\.head-action--top\s*\{\s*grid-row: 1;\s*grid-column: 2;/, sheet)
    assert_match(/\.head-action--below\s*\{\s*grid-row: 2;\s*grid-column: 2;/, sheet)
    refute_match(/head-action--third/, sheet, "no third row is left in the stylesheet")
    assert_match(/\.head-action-pair\s*\{\s*display: flex;/, sheet)
  end

  test "the JSON popup is a terminal for the raw conf, exactly like JSON's" do
    d = doc
    popup = d.at_css("#jev-conf-popup")
    refute_nil popup
    # The JSON page's markup, class for class.
    assert_includes popup.at_css(".popup-panel")["class"], "popup-terminal"
    ta = popup.at_css("textarea#jevConfOutput")
    refute_nil ta, "an editable textarea holding the conf"
    assert_includes ta["class"], "spec-terminal", "the same terminal look as JSON's"
    assert_equal "22", ta["rows"]
    refute_nil popup.at_css("#copyJevConfBtn"), "and the copy button"
    refute_nil popup.at_css("[data-popup-close]"), "and a × close"

    # A terminal, not a form.
    assert_nil popup.at_css("select"), "JSON is the raw JSON, not the form"
    assert_nil popup.at_css(".jev-form")
    assert_includes popup.at_css("h2").text, "jev.conf.json"
  end

  test "the terminal popup is 39vw -- 30% wider than the 30vw it was" do
    rule = css[/\.popup-terminal \{[^}]*\}/]
    refute_nil rule
    assert_match(/width:\s*39vw/, rule,
      "30vw was 384px, where the conf's own nesting was the width rather than " \
      "the content. 30% wider is 39vw. vw not %: .popup carries " \
      "clamp(1rem, 4vw, 3rem) padding and a percentage resolves against that " \
      "content box -- `width: 60%` measured 55.6% of the window.")
    # The same rule serves the JSON page's own spec popup, so both are 39vw.
    assert_match(/min-width:\s*26rem/, rule, "the floor that keeps it usable on a laptop")
  end
  test "the conf JSON is built from the fields, in the annotator's shape" do
    s = src
    assert_match(/JSON\.stringify\(conf\(\), null, 2\)/, s)
    assert_match(/confidence_floor: Number\(document\.getElementById\('cf-floor'\)\.value\)/, s)
    # A score question's criteria stay a LIST; a choice question's stay an OBJECT.
    assert_match(/type === 'score' \? \[\] : \{\}/, s,
      "jev_annotate.py wants a list of grades for a score and a map for a choice")
    assert_match(/if \(name === '__floor' \|\| name === '__metrics'\) return;/, s)
  end

  test "editing a field updates the JSON, and CONFIG refreshes it on open" do
    s = src
    assert_match(/e\.target\.closest\('\.jev-qblock'\)/, s,
      "a field edit re-serialises the conf")
    assert_match(/e\.target\.closest\('\[data-popup="jev-conf-popup"\]'\)/, s,
      "and CONFIG re-serialises on open, so it is never stale")
  end

  # ---- the dead-? regression ----

  test "CsModal is looked up at click time, never captured" do
    handler = src[/function openExamples\(key, title\) \{.*?var tpl =/m]
    refute_nil handler, "openExamples() is the opener"
    assert_match(/var modal = window\.CsModal;/, handler,
      "inside the function, so it is read at click time")
    refute_match(/^\s{2}var modal = window\.CsModal;$/m, src,
      "a capture at IIFE scope binds undefined, because aether.js is a " \
      "deferred module script that runs after this one -- every ? then hit " \
      "`if (!modal) return` and did nothing, with no error")
  end

  test "the page no longer carries the old conf-in-popup machinery" do
    s = src
    refute_includes s, "data-jev-conf", "the ? shows examples, not the conf"
    refute_includes s, "jevConfAll", "CONFIG is one terminal, not an all-questions form"
    refute_includes s, "jevConf-", "and there are no per-question conf templates"
    refute_includes s, "Run default", "the fields are the source of truth and the " \
      "conf is a view of them, so there is nothing to reset"
  end

  # ---- which service answers ----
  #
  # The backend is selected in the RUNNER's environment, so this app cannot
  # report a configured value: the card states the two backends and shows what
  # ACTUALLY answered, read from the stored answers. A card that only restated
  # the env var names would pass a "does it render" test and give the operator
  # nothing checkable, so the second test writes an answer and requires it to
  # appear -- and a second endpoint to appear as its own line, which is what
  # makes a cutover visible after the fact.

  test "the backend card names both backends and the variables that select one" do
    card = card_for(doc, "Which service answers")
    refute_nil card, "the backend card must be on the page"
    text = card.text

    JevConf::BACKENDS.each do |kind, backend|
      assert_match(/#{kind.upcase}/, text)
      assert_match(/#{Regexp.escape(backend["label"])}/, text)
      assert_match(/#{Regexp.escape(backend["certainty"])}/, text)
    end
    JevConf::SELECTION.each_key { |var| assert_match(/#{var}/, text) }
    assert_match(/nothing yet/, text,
      "with no stored answers the provenance line must say so, not invent one")
  end

  test "the backend card reports the endpoint and model that actually answered" do
    job = Job.create!(name: "backend-provenance", state: "done", source_kind: "svg",
                      input_path: "/data/x.svg", stem: "backend-provenance", spec: {},
                      runner: "mock", comparison: { "candidates" => [] })
    stored = lambda do |file, endpoint, model|
      job.validations.create!(file: file, state: "done", manifest: {},
                              jev_answers: { "failure_mode" => { "type" => "choice" } },
                              jev_meta: { "model" => model, "endpoint" => endpoint,
                                          "latency_ms" => 40_000, "verdict" => {} })
    end
    stored.call("candidate_01.svg", "https://api.typesafe.ai/v1/systemone", "jev-1.13.0")
    stored.call("candidate_02.svg", "http://100.64.0.0:8797/v1/systemone", "laya-rl-agent")

    text = card_for(doc, "Which service answers").text
    assert_match(%r{https://api\.typesafe\.ai/v1/systemone}, text)
    assert_match(/jev-1\.13\.0/, text)
    assert_match(%r{http://100\.64\.0\.0:8797/v1/systemone}, text,
      "a locally served endpoint is a different backend and gets its own line")
    assert_match(/laya-rl-agent/, text,
      "the reported model is what tells the two apart in practice")
    assert_match(/×1/, text)
    refute_match(/nothing yet/, text)
  end
end
