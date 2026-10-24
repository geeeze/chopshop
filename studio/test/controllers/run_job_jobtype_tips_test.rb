require "test_helper"

# The job-type notes on the Run Job page, and the row of buttons that picks the
# job type. Two things have to hold, and neither is visible from the server:
#
#   1. The NOTES have exactly ONE home -- the hint registry (HelpTips,
#      app/lib/help_tips.rb), one `jobtype.<template>` key per template -- and
#      the page's `?` opens that key rather than a bespoke hidden target. The
#      registry-integrity test (test/lib/help_tips_test.rb) covers the key set
#      in both directions; what it cannot see is whether the WORDS are right,
#      so they are pinned here against PipelineConf.
#   2. The ROW is a label-free BLOCK: one button per template, equal-width
#      tracks, nothing but buttons in it. Eleven buttons of very different
#      label lengths used to end in a ragged staircase.
#
# The `?` also has to track the SELECTED template -- one click must always open
# the notes for the job type the row is showing -- so the visibility rule is
# pinned in source as well as in the rendered default.
class RunJobJobtypeTipsTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def form
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    @form ||= Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def css
    @css ||= Rails.root.join("app/assets/stylesheets/application.css").read
  end

  def view
    @view ||= Rails.root.join("app/views/jobs/new.html.erb").read
  end

  # The key set and the template set must BE each other. A template with no key
  # has no notes; a key with no template is text nobody can ever open.
  test "one jobtype key per template, and no others" do
    assert_equal PipelineConf.template_keys.sort,
                 HelpTips.keys.grep(/\Ajobtype\./).map { |k| k.sub("jobtype.", "") }.sort,
      "the jobtype keys must be exactly the templates -- a key built from a " \
      "second list would drift from the model that composes the contract"
  end

  # The row's `?`s must cover the same set, and each must be a help_tip(key)
  # whose button names an existing popup -- a `?` that opens nothing is the
  # silent no-op this page has shipped before.
  test "the row carries one help_tip popup per template key" do
    field = form.at_css(".job-type-field")
    refute_nil field, "the job-type field must exist"

    popups = field.css(".popup").map { |p| p["id"] }
    assert_equal HelpTips.keys.grep(/\Ajobtype\./).map { |k| "help-tip-#{k.tr('.', '-')}" }.sort,
                 popups.sort,
      "one standard popup per jobtype key, and no others"

    field.css("button.help-tip-btn").each do |btn|
      key = btn["data-popup"].sub(/\Ahelp-tip-/, "").tr("-", ".")
      assert HelpTips.key?(key), "#{key}: the `?` names a key the registry does not have"
      popup = field.at_css("##{btn["data-popup"]}")
      assert_equal 1, popup.css("[data-popup-close]").size,
        "#{key}: exactly one close, the app's standard"
      refute_nil popup.at_css(".popup-panel > .popup-head"), "#{key}: the standard head"
      refute_nil popup.at_css(".popup-panel > .popup-body"), "#{key}: the standard body"
    end
  end

  # ONE CLICK. Every `?` is rendered -- so the popup is the registry's own and
  # is never assembled at click time -- but only the SELECTED template's is on
  # screen, so the operator never has to hunt for the one that applies.
  test "exactly the selected template's ? is on screen, and it follows the select" do
    field = form.at_css(".job-type-field")
    tips = field.css(".job-type-tip")
    refute_empty tips, "the row needs its `?`s"

    visible = tips.reject { |t| t.has_attribute?("hidden") }
    assert_equal 1, visible.size, "exactly one `?` is clickable"
    assert_equal PipelineConf::DEFAULT_TEMPLATE, visible.first["data-job-type-tip"],
      "and it is the selected template's -- the one the row opens on"

    # The rule that moves it, in source: the wrapper's `hidden` is set from the
    # SAME select the pressed button is painted from, so the two cannot drift.
    assert_includes view, "wrap.hidden = wrap.getAttribute('data-job-type-tip') !== tplSel.value",
      "the `?` must follow the template select"
    assert_operator view.scan("syncJobTypeTips();").size, :>=, 4,
      "the tip visibility is repainted on init, on select change, on the button " \
      "click and on a refused apply -- not only on init"
  end

  # The ROW is a BLOCK, not a staircase. Eleven buttons of very different label
  # lengths: equal-width tracks and no caption between them.
  test "the template row is a label-free block of equal-width buttons" do
    row = form.at_css(".job-type-row")
    refute_nil row, "the job-type row must exist"

    buttons = row.css(".job-type-btn")
    assert_equal PipelineConf.template_keys.size, buttons.size,
      "one button per template -- the count the row's balance is measured over"
    assert_equal row.element_children.size, buttons.size,
      "the row holds nothing but buttons: no category caption, no separator"

    # Equal-width tracks. `auto-fit` collapses the empty tracks on the last
    # row, so the buttons there stretch to the SAME width as every other row's
    # instead of ending the block wherever the labels happened to run out --
    # which is what made the old flex-wrap read as an accident.
    rule = css[/\.job-type-row,\s*\n\.mode-row\s*\{[^}]*\}/m].to_s
    refute_empty rule, "the job-type row's own rule must be readable"
    assert_match(/display:\s*grid/, rule, "a grid, not a flex-wrap")
    assert_match(/grid-template-columns:\s*repeat\(auto-fit,\s*minmax\(/, rule,
      "a column floor, so the row does not collapse to one narrow column")
    assert_match(/1fr\)/, rule, "equal-width tracks")
    assert_match(/align-items:\s*stretch/, rule,
      "every button on a row is the same height even where a label wraps")
  end
end
