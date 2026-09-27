require "test_helper"

# The Jev page: the ? reveals a configuration FORM, and CONFIG opens all of them.
#
# The ? used to reveal read-only example cards, which was the wrong shape --
# the examples ARE the conf's criteria (the annotator's QUESTIONS.<q>.criteria),
# so they are editable rows now, laid out like the JSON page's builder.
#
# CONFIG sits under Run Job, plain, in the same grid cell as the JSON page's own
# "JSON" button.
#
# The bug this file exists to prevent: aether.js is loaded by
# javascript_importmap_tags, which emits a MODULE script. Module scripts are
# deferred, so they run AFTER a classic inline script. Capturing
# `var modal = window.CsModal` at IIFE time bound it to undefined, and every "?"
# then hit `if (!modal) return` and did nothing -- silently, with no error. The
# lookup must happen at CLICK time. A Rails test cannot see module load order at
# all, so the browser check for that lives in the probe.
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
    Rails.root.join("app/assets/stylesheets/application.css").read
  end

  def src
    File.read(Rails.root.join("app/views/pages/jev.html.erb"))
  end

  def crit_pairs(criteria)
    criteria.is_a?(Array) ? criteria.map { |c| c.split(": ", 2) } : criteria.to_a
  end

  test "CONFIG is plain, under Run Job, in the JSON page's slot" do
    d = doc
    row = d.at_css(".page-head-row--stacked")
    refute_nil row, "the head must be the stacked grid, so CONFIG lands in row 2 col 2"

    btn = d.at_css("#jevConfBtn")
    refute_nil btn, "the CONFIG button must exist"
    assert_equal "CONFIG", btn.text.strip
    assert_equal "CONFIG", btn["aria-label"],
      "the accessible name must be exactly the visible label"
    # Plain, like JSON's button -- secondary, not primary. Run Job keeps the
    # primary treatment above it.
    assert_includes btn["class"], "btn-secondary"
    refute_includes btn["class"], "btn-primary"
    assert_includes btn["class"], "head-action", "so it is the same box as every head action"

    run = d.css(".head-action").first
    assert_equal "Run Job", run.text.strip, "Run Job is still the first head action"
    assert_includes run["class"], "btn-primary", "and keeps the primary effect"

    sheet = Rails.root.join("app/assets/stylesheets/application.css").read
    refute_match(/head-action:first-of-type/, sheet,
      "the :of-type scheme is gone: it cannot tell an <a> from a <button>")
    # Explicit grid slots, not :of-type. :first-of-type/:last-of-type count
    # siblings of that ELEMENT TYPE, so an <a> beside a <button> makes each of
    # them both first and last of its own type. Both then matched both rules,
    # the later one won, and the two buttons landed in the same cell -- measured
    # at row 2 col 2, both with top 355px, stacked on top of each other.
    assert_includes run["class"], "head-action--top"
    assert_includes btn["class"], "head-action--below"
    assert_match(/\.head-action--top\s*\{\s*grid-row: 1;\s*grid-column: 2;/, sheet)
    assert_match(/\.head-action--below\s*\{\s*grid-row: 2;\s*grid-column: 2;/, sheet)
  end

  test "every ? sits in a card-head, and its name contains the visible title" do
    d = doc
    helps = d.css(".help-btn[data-jev-conf]")
    assert_equal 6, helps.size, "four questions, plus metrics and the confidence floor"

    helps.each do |b|
      assert_equal "button", b.name
      head = b.parent
      assert_includes head["class"].to_s, "card-head", "each ? sits in its card's head"
      refute_nil head.at_css("h3"), "beside the title"
      title = head.at_css("h3").text.strip.split(" ").first
      assert_includes b["aria-label"].to_s, title,
        "the accessible name must CONTAIN the visible label (WCAG 2.5.3)"
    end
  end

  test "each ? opens a FORM for its own section, not a list of examples" do
    d = doc
    SECTIONS.each do |key|
      tpl = d.at_css("template#jevConf-#{key}")
      refute_nil tpl, "the ? for #{key} must have a template"

      form = tpl.at_css(".jev-form")
      refute_nil form, "#{key}: a form, not a list"
      # The JSON page's idiom: label + control + hint.
      refute_nil form.at_css("select[aria-label='Type for #{key}']"), "a type control"
      refute_nil form.at_css("textarea[aria-label='Instructions for #{key}']"), "the instructions"
      refute_nil form.at_css("label[for='cf-#{key}-instructions']"), "a label for it"
      form.css(".jev-criterion").each do |row|
        refute_nil row.at_css(".jev-crit-value"), "an editable value"
        refute_nil row.at_css(".jev-crit-desc"), "an editable description"
      end
      assert_operator form.css(".jev-criterion").size, :>=, 2
      assert_operator form.css(".hint").size, :>=, 2, "the JSON page's fields all carry a .hint"
    end
  end

  test "the criteria shown are the conf's criteria, and they are editable" do
    d = doc
    SECTIONS.each do |key|
      tpl = d.at_css("template#jevConf-#{key}")
      values = tpl.css(".jev-crit-value").map { |i| i["value"] }
      expected = crit_pairs(JevConf::DEFAULT["questions"][key]["criteria"]).map(&:first)
      assert_equal expected, values, "#{key}: the card and the form must not drift"
      tpl.css(".jev-crit-desc").each do |i|
        refute_nil i["value"], "the default wording must be prefilled"
      end
    end
  end

  test "the score question's labels are read-only; the rest are not" do
    d = doc
    d.at_css("template#jevConf-tonal_structure").css(".jev-crit-value").each do |i|
      refute_nil i["readonly"], "tonal grades are fixed labels, not an answer vocabulary"
    end
    d.at_css("template#jevConf-failure_mode").css(".jev-crit-value").each do |i|
      assert_nil i["readonly"]
    end
  end

  test "CONFIG opens every question at once, plus metrics and the floor" do
    d = doc
    tpl = d.at_css("template#jevConfAll")
    refute_nil tpl, "the CONFIG button needs a form"

    keys = tpl.css(".jev-qblock").map { |b| b["data-question"] }
    assert_equal (SECTIONS + %w[__floor __metrics]), keys,
      "all four questions, then the floor and the metrics"

    floor = tpl.at_css("input#cf-floor")
    refute_nil floor
    assert_equal "0.6", floor["value"], "CONFIDENCE_FLOOR in jev_annotate.py"
    metrics = tpl.at_css("textarea#cf-metrics").text.strip.split("\n")
    assert_equal JevConf::METRICS, metrics
  end

  test "every form says plainly that it does not yet change what is asked" do
    d = doc
    sels = ["template#jevConfAll"] +
           SECTIONS.map { |k| "template#jevConf-#{k}" } +
           %w[__floor __metrics].map { |k| "template#jevConf-#{k}" }
    sels.each do |sel|
      block = d.at_css("#{sel} .jev-conf-warn")
      refute_nil block, "#{sel} must carry the warning"
      t = block.text
      assert_match(/preview only/i, t, sel)
    end

    # The forms that edit QUESTIONS must name the missing --questions flag, so the
    # gap is actionable. The metrics form edits a FILE on disk instead, and says
    # so -- a test that demanded --questions there would be asserting a lie.
    (SECTIONS + %w[__floor __all]).each do |key|
      sel = key == "__all" ? "template#jevConfAll" : "template#jevConf-#{key}"
      assert_match(/--questions/, d.at_css("#{sel} .jev-conf-warn").text,
                   "#{sel}: the missing flag is named")
    end
    metrics = d.at_css("template#jevConf-__metrics .jev-conf-warn").text
    assert_match(/remediation_table\.json/, metrics,
      "the metrics form edits a file on disk, and says which")
  end

  test "CsModal is looked up at click time, not captured" do
    # The bug: aether.js is a deferred module script, so it runs AFTER this
    # classic inline script and window.CsModal is undefined at IIFE time.
    assert_match(/var modal = window\.CsModal;/, src,
      "it must be looked up inside the handler")
    handler = src[/function openConf\(key, title\) \{.*?var tpl =/m]
    refute_nil handler, "openConf() is the shared opener"
    assert_match(/var modal = window\.CsModal;/, handler,
      "inside openConf, so it is read at click time")
    # A capture at IIFE scope is the exact regression.
    iife = src[/\(function \(\) \{.*?\n {4}var DEFAULTS/m]
    assert_match(/function openConf/, src)
    refute_match(/^\s{4}var modal = window\.CsModal;$/, iife.to_s,
      "a capture at IIFE scope binds undefined and every ? silently does nothing")
  end

  test "validation and Run default are scoped per question block" do
    # The CONFIG form holds several .jev-qblock at once, so a bare
    # root.querySelector('select') would only ever reach the first.
    assert_match(/root\.querySelectorAll\('\.jev-qblock'\)/, src)
    assert_match(/function runDefaultBlock\(block\)/, src)
    refute_match(/var select = root\.querySelector\('select'\);/, src)
    refute_match(/var ta = root\.querySelector\('textarea'\);/, src)
  end

  test "the gamer font and the bigger question are still in place" do
    a = css[/\.jev-card \.a \{[^}]*\}/m]
    assert_match(/font-family: var\(--font-pixel\)/, a, "Press Start 2P, the gamer font")
    assert_operator a[/font-size: ([\d.]+)rem/, 1].to_f, :<, 0.8
    q = css[/\.jev-card \.q \{[^}]*\}/m]
    assert_operator q[/font-size: ([\d.]+)rem/, 1].to_f, :>, 0.9
    # Still used somewhere the user can actually see it.
    d = doc
    assert_operator d.css(".jev-derived .jev-card .a").size, :>=, 3,
      "the derived-certainty cards in the floor popup carry the font"
  end
end
