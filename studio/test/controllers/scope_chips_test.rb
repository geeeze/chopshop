require "test_helper"

# Scope chips and the "what this page does" banner (#42).
#
# THE PROBLEM, in the operator's words: FLUX, BP and JEV mix three kinds of
# setting and nothing said which was which. Someone tuning the JEV confidence
# floor could not tell it did nothing -- the caveat lived in a long blurb's popup
# and in a model comment, not where the field was.
#
# WHAT THIS PINS:
#   * each config page carries a 3-line banner, one line per scope, and the
#     three lines are the three words the chips use;
#   * every control group on the page carries a scope chip, and the chip's
#     class is the semantic band for its meaning (pass = per job, warn =
#     service, fail = read-only);
#   * JEV's questions, criteria and floor render read-only, with the copy
#     control intact.
#
# The rule under test is the issue's own acceptance: "each config page has the
# banner; each control group has exactly one chip."
class ScopeChipsTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # The three scopes, and the chip class that carries each meaning. ONE list,
  # so a scope the partial would render but the banner could not name is a
  # failure here rather than a word on a page nobody can look up.
  SCOPES = {
    "per job" => "pass",
    "service · restart" => "warn",
    "code · read-only" => "fail"
  }.freeze

  def doc(route)
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get public_send(route), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def scope_word(node)
    node["data-scope"].to_s
  end

  # The banner's lines, as [chip word, line text].
  def banner_lines(d)
    banner = d.at_css("[data-scope-banner]")
    return [] unless banner

    banner.css(".scope-banner-line").map do |line|
      [scope_word(line.at_css(".scope-chip")), line.at_css(".scope-banner-text").text]
    end
  end

  # -- the banner: three lines, the three scopes, in order ------------------

  test "every config page carries the banner with its three lines" do
    { flux: :flux_path, bp: :bp_path, jev: :jev_path }.each do |page, route|
      d = doc(route)
      lines = banner_lines(d)
      assert_equal 3, lines.size, "#{page}: the banner is three lines, got #{lines.size}"

      words = lines.map(&:first)
      assert_equal SCOPES.keys, words,
                   "#{page}: the banner names the three scopes in order, got #{words.inspect}"

      # Each line says something. A banner of three chips and no sentences is
      # the same non-answer the blurb was.
      lines.each do |word, text|
        assert_operator text.gsub(/\s+/, " ").strip.length, :>, 20,
                        "#{page}: the #{word.inspect} line carries a sentence, not a label"
      end

      # And the sentences are MARKUP, not escaped text. The lines carry the
      # page's own <span class="mono"> identifiers, and a banner that rendered
      # them as &lt;span&gt; would be the copy failing at the one place it
      # matters.
      banner = d.at_css("[data-scope-banner]")
      assert_operator banner.css(".scope-banner-text span.mono, .scope-banner-text strong").size, :>=, 1,
                      "#{page}: the banner's lines carry real markup, not escaped text"
    end
  end

  test "the banner's chip class is the semantic band for its scope" do
    { flux: :flux_path, bp: :bp_path, jev: :jev_path }.each do |page, route|
      d = doc(route)
      banner_lines(d).each do |word, _text|
        chip = d.at_css("[data-scope-banner] .scope-chip[data-scope='#{word}']")
        refute_nil chip, "#{page}: the banner's #{word.inspect} chip is on the page"
        assert_includes chip["class"].split, "badge",
                        "#{page}: #{word.inspect} carries the semantic badge token, not a bare pill"
        assert_includes chip["class"].split, SCOPES.fetch(word),
                        "#{page}: #{word.inspect} is the #{SCOPES.fetch(word)} band"
      end
    end
  end

  # The JEV banner is the one the issue was filed about, so its three lines are
  # asserted for CONTENT and not only for presence: the "not wired" line is the
  # whole point of the page.
  test "the JEV banner says where the questions and the floor are changed" do
    lines = banner_lines(doc(:jev_path))
    wired = lines.map(&:last).join(" ")

    assert_match(/QUESTIONS/, wired,
      "the annotator's QUESTIONS is named, because that is the file to edit")
    assert_match(/remediation_table\.json/, wired,
      "and remediation_table.json, the table the remediation loop reads")
    assert_match(/jev_annotate\.py/, wired, "the file that holds them")
    assert_match(/out of scope/i, wired,
      "adding the conf flag is out of scope and the page says so rather than " \
      "implying the form will do it")

    # The per-job line must not claim a job setting that does not exist: JEV is
    # asked by the runner against a proof, so the honest line says there is none.
    per_job = lines.find { |w, _| w == "per job" }.last
    assert_match(/nothing|no job|not a Run Job kind/i, per_job,
      "the per-job line says plainly that nothing here is per job")
  end

  # -- every control group carries exactly one chip --------------------------

  # A control group is a card, or a per-field scope on FLUX where a card mixes
  # scopes (Model: env vars AND request parameters). Selected by the container
  # that holds the controls, so the assertion cannot pass on a card that lost
  # its chip while a stray one survived elsewhere.
  def control_groups(d, page)
    case page
    when :flux
      d.css(".card[data-flux-card]").map { |c| [c, c.at_css(".card-head")] } +
        d.css("[data-flux-gpu]").map { |c| [c, c.at_css(".card-head")] }
    when :bp
      d.css(".card[data-plot-card], .card[data-blender-card]").map { |c| [c, c.at_css(".card-head")] }
    when :jev
      # The JEV cards that CONFIGURE something: the four questions, the floor,
      # the metrics and the backend. "The verdict" is a rendered example with no
      # control group at all, so it is not in this list -- and putting a chip on
      # it would be the "a chip per group" rule applied to a card that has no
      # group.
      d.css(".card").select { |c| c.at_css("h3") && c.at_css("h3").text.strip != "The verdict" }
         .map { |c| [c, c.at_css(".card-head") || c.at_css(".jev-qblock-head")] }
    end
  end

  test "every control group carries a scope chip with a known token" do
    { flux: :flux_path, bp: :bp_path, jev: :jev_path }.each do |page, route|
      d = doc(route)
      groups = control_groups(d, page)
      assert_operator groups.size, :>=, 4, "#{page}: found #{groups.size} control groups"

      groups.each do |card, head|
        label = card["data-flux-card"] || card["data-plot-card"] ||
                card["data-blender-card"] || card["data-flux-gpu"] ||
                card.at_css("h3")&.text&.strip
        # The chip lives in the group's own head: the card-head, or the question
        # block's head for the four JEV question cards (whose controls are the
        # read-only fields, so that is where the word has to be).
        chips = (head ? head.css(".scope-chip") : []) +
                card.css(".jev-qblock-head .scope-chip")
        # The rule is "at least one", because one group on FLUX is genuinely a
        # mix and carries both. The count is pinned per page below so a group
        # that LOST its chip is still caught here.
        assert_operator chips.size, :>=, 1,
                        "#{page}: #{label.inspect} carries a scope chip, got none"
        chips.each do |chip|
          word = scope_word(chip)
          assert_includes SCOPES.keys, word,
                          "#{page}: #{label.inspect} carries #{word.inspect}, which is not one of the three scopes"
          assert_includes chip["class"].split, SCOPES.fetch(word),
                          "#{page}: #{label.inspect}'s #{word.inspect} chip is the #{SCOPES.fetch(word)} band"
        end
      end
    end
  end

  # The exact count, per page, so "at least one" above cannot hide a group that
  # gained a chip it should not have, or one that lost the one it had.
  #
  # FLUX: 7 -- Service, Model (TWO: it is genuinely a mix), Resolution, Hand-off
  # (two, for the same reason) and the GPU card. BP: 8 -- four cards per half.
  # JEV: 7 -- four questions (chip on the question block's head), the confidence
  # floor (the card-head chip and the block-head chip are the one group), the
  # metrics, and the backend.
  test "the chip count is the one the page's own cards define" do
    expected = { flux_path: 7, bp_path: 8, jev_path: 7 }
    expected.each do |route, count|
      d = doc(route)
      chips = d.css(".card .card-head .scope-chip").size +
              d.css(".card .jev-qblock-head .scope-chip").size
      assert_equal count, chips,
                   "#{route}: #{count} control groups carry a chip"
    end
  end

  # FLUX's Model card is the one group that is genuinely a MIX, and the page
  # must say so rather than flatten it to one word.
  test "FLUX's Model card carries both scopes, and each field its own" do
    d = doc(:flux_path)
    card = d.at_css(".card[data-flux-card='Model']")
    refute_nil card
    words = card.css(".card-head .scope-chip").map { |c| scope_word(c) }
    assert_equal ["service · restart", "per job"], words,
                 "the Model card is both: env vars the service reads, and request parameters"

    # And each field names its own scope, read from the field's `env` key, so a
    # field cannot be labelled service while it rides with the request.
    fields = FluxConf::CARDS.find { |c| c[:title] == "Model" }[:fields]
    card.css(".field").each_with_index do |field, i|
      f = fields[i]
      label = field.at_css("label").text.strip
      assert_equal f[:label], label, "the rendered fields are the card's own, in order"
      chip = field.at_css(".scope-chip")
      refute_nil chip, "#{label}: the field carries its own scope chip"
      expected = f[:env] ? "service · restart" : "per job"
      assert_equal expected, scope_word(chip),
                   "#{label}: #{f[:env] ? "it is #{f[:env]}" : "it rides with the request"}"
    end
  end

  # The chips are the studio's OWN tokens, not a second hand-tuned pill. The
  # partial re-points .chip / .tech-tag and .badge; a private class would be the
  # drift the shared-token rule exists to prevent.
  test "the chips reuse the studio's chip and badge tokens" do
    d = doc(:jev_path)
    chip = d.at_css(".card .scope-chip")
    refute_nil chip
    classes = chip["class"].split
    assert_includes classes, "chip", "the studio's chip token (the kb's .chip name)"
    assert_includes classes, "scope-chip", "the scope partial's own modifier"
    assert_includes classes, "badge", "the semantic badge base (#93)"
    assert_includes classes, "fail", "and the band suffix the scope means"
    assert_equal "code · read-only", scope_word(chip), "the first JEV card's scope"
  end

  # -- JEV: read-only, with the copy control intact -------------------------

  test "JEV's questions, criteria and floor render read-only" do
    d = doc(:jev_path)

    # The four question cards, and the floor.
    JevConf::DEFAULT["questions"].each_key do |name|
      block = d.at_css(".jev-qblock[data-question='#{name}']")
      refute_nil block, "#{name}: the block is on the page"
      # DISABLED, not readonly: a <select> ignores readonly, so the attribute
      # alone would leave a control that still opens and still feeds conf() its
      # new value -- exactly the "editable control that changes nothing" the
      # acceptance removes.
      refute_nil block.at_css("select##{"cf-#{name}-type"}[disabled]"),
                   "#{name}: the type control refuses the edit"
      refute_nil block.at_css("textarea[readonly]"),
                   "#{name}: the instructions are read-only"
      block.css(".jev-criterion input").each do |input|
        refute_nil input["readonly"], "#{name}: every criterion input is read-only"
      end
    end

    floor = d.at_css("#cf-floor")
    refute_nil floor, "the floor is still on the page"
    refute_nil floor["readonly"], "the confidence floor is read-only"
    assert_equal JevConf::DEFAULT["confidence_floor"].to_s, floor["value"]
  end

  # The acceptance in one line: "JEV has no editable control that changes
  # nothing." Enumerating each control by kind (above) passes if a NEW control
  # were added without the treatment; this walks every control in a question
  # card and refuses to find one that accepts input.
  test "no control in a JEV question card accepts input" do
    d = doc(:jev_path)
    d.css(".jev-qblock[data-question]").each do |block|
      name = block["data-question"]
      next if name == "__floor" || name == "__metrics"

      block.css("select, input, textarea").each do |c|
        refuses = c["readonly"] || c["disabled"]
        refute_nil refuses,
                    "#{name}: <#{c.name}##{c["id"]}> accepts input, and nothing " \
                    "this page changes reaches the annotator (#42)"
      end
    end
  end

  # The composed JSON must still be what the fields say, so a read-only field
  # cannot have silently become a value the script does not carry.
  test "the JEV conf script still composes from the fields it reads" do
    s = File.read(Rails.root.join("app/views/pages/jev.html.erb"))
    assert_match(/JSON\.stringify\(conf\(\), null, 2\)/, s)
    assert_match(/confidence_floor: Number\(document\.getElementById\('cf-floor'\)\.value\)/, s)
    assert_match(/name === '__metrics'\) return;/, s)
  end

  # #85's pin, preserved: the metrics box is read-only and the conf has no
  # metrics key. #42 makes the questions read-only too, but it must not undo the
  # metrics honesty.
  test "the JEV metrics stay a read-only reference with no conf key" do
    d = doc(:jev_path)
    ta = d.at_css("#cf-metrics")
    refute_nil ta["readonly"]
    assert_equal JevConf::METRICS.join("\n"), ta.text.strip
    assert_includes ta.parent.at_css("label[for='cf-metrics']").text, "read-only"
  end

  # THE ONE PRE-EXISTING ASSERTION #42 INVALIDATES, recorded here rather than
  # edited out of jev_page_test.rb (a sibling agent owns that file).
  #
  #   test "the score question's grade labels are read-only, a choice question's
  #         are not" -- jev_page_test.rb
  #
  # Its second half asserts that failure_mode's criterion inputs have NO readonly
  # attribute. That was true because tonal_structure is a score question and its
  # grades are fixed labels, while a choice question's criteria are editable.
  # #42 makes EVERY JEV control read-only, so that assertion is now false by
  # design: the whole point of the change is that no JEV control edits anything,
  # so the choice question's criteria refuse edits exactly like the score's.
  #
  # It is left in place there and the failure is expected; this test is what
  # pins the new behaviour that replaced it.
  test "a choice question's criteria are read-only too, not only the score's" do
    d = doc(:jev_path)
    block = d.at_css(".jev-qblock[data-question='failure_mode']")
    refute_nil block
    assert_operator block.css(".jev-criterion input[readonly]").size, :>=, 1,
                    "failure_mode's criteria are read-only like every JEV control"
    # And the whole set: every criterion input on the page refuses edits.
    assert_operator d.css(".jev-criterion input").size, :>=, 20
    assert_equal d.css(".jev-criterion input").size,
                 d.css(".jev-criterion input[readonly]").size,
                 "every criterion input on the page is read-only"
  end

  # The copy control is the ONE thing on this page that still works, so it must
  # survive the read-only change.
  test "JEV's copy controls are intact" do
    d = doc(:jev_path)
    refute_nil d.at_css("#copyJevConfBtn"), "the conf copy button"
    refute_nil d.at_css("#copyJevRemediationBtn"), "the remediation copy button"
    refute_nil d.at_css("#jevConfOutput"), "and the terminal they copy from"
  end

  # -- the page's own rules survive the change ------------------------------

  test "no ERB scaffolding leaked into a scoped page as text" do
    { flux: :flux_path, bp: :bp_path, jev: :jev_path }.each do |page, route|
      body = doc(route).text
      ["<%#", "%>", "scope_banner", "scope_chip", "render partial"].each do |token|
        refute_includes body, token, "#{page}: #{token} is ERB scaffolding, not page text"
      end
    end
  end

  test "the #41 hint registry is untouched: every help_tip still renders" do
    { jev: :jev_path, flux: :flux_path }.each do |page, route|
      d = doc(route)
      keys = HelpTips.keys.select { |k| k.start_with?("#{page}.") }
      refute_empty keys
      keys.each do |key|
        assert d.at_css("button.help-tip-btn[data-popup='help-tip-#{key.tr('.', '-')}']"),
               "#{page}: the ? for #{key} still renders beside its scope chip"
      end
    end
  end

  # -- the partial refuses a scope that is not one of the three --------------

  test "the scope chip partial rejects a fourth scope" do
    # The three are the only words. A page that typed "sometimes" would render a
    # chip with no colour and no meaning, so the partial raises instead.
    err = assert_raises(ActionView::Template::Error) do
      ApplicationController.render(
        partial: "shared/scope_chip",
        locals: { scope: "whenever", label: "test" }
      )
    end
    assert_match(/unknown scope/, err.message)
  end

  test "the banner omits a nil line rather than rendering an empty chip" do
    html = ApplicationController.render(
      partial: "shared/scope_chip",
      locals: { lines: [["per job", "applies to the next job"], ["code · read-only", nil]] }
    )
    assert_equal 1, Nokogiri::HTML(html).css(".scope-banner-line").size,
                 "a nil line is omitted, not rendered as a bare chip"
  end

  # The chip and the banner are ONE partial, so the word on a control group and
  # the word in the banner cannot drift apart.
  test "the chip and the banner are the same partial" do
    assert File.exist?(Rails.root.join("app/views/shared/_scope_chip.html.erb"))
    refute File.exist?(Rails.root.join("app/views/shared/_scope_banner.html.erb")),
           "one partial, one definition: a second banner partial is the drift this prevents"
    src = File.read(Rails.root.join("app/views/shared/_scope_chip.html.erb"))
    assert_match(/scope-banner/, src, "it renders the banner")
    assert_match(/scope-chip/, src, "and the lone chip")
  end
end
