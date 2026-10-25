require "test_helper"

# The goal-first intent row on the Run Job form. Three things have to hold, and
# none is visible from the server:
#
#   1. The ROW renders ABOVE the template buttons, as ONE container (revert =
#      hide the row), with one button per PipelineConf::INTENTS entry — and each
#      button names the template it maps to, in the model's own words.
#   2. Clicking an intent SELECTS the template it maps to, through the SAME
#      chooseTemplate path the template buttons use — so the row is a goal-first
#      VIEW of one control, not a second control with its own apply path.
#   3. The template's blurb is NOT duplicated inline: it stays one click away on
#      the `?` (jobtype.<template>), exactly as the template buttons keep it in a
#      hover title.
class RunJobIntentRowTest < ActionDispatch::IntegrationTest
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

  def field
    form.at_css(".job-type-field")
  end

  def row
    field.at_css(".intent-row")
  end

  test "the intent row renders above the template buttons, as one container" do
    refute_nil field, "the job-type field must exist"
    refute_nil row, "the goal-first intent row must exist"

    # ONE container, so reverting the feature is hiding it — not hunting for
    # every button and label it scattered across the field.
    assert_equal 1, field.css(".intent-row").size,
      "the intent row is one container, or the revert is not one edit"

    # ABOVE the template buttons: the goal is chosen before the machinery.
    html = field.to_html
    assert_operator html.index('class="intent-row"'), :<, html.index('class="job-type-row"'),
      "the intent row must sit above the template buttons"
  end

  test "one button per intent, each naming its template and its own label" do
    buttons = row.css("[data-intent]")
    assert_equal PipelineConf::INTENTS.size, buttons.size,
      "one button per intent — an intent with no button is a goal nobody can " \
      "reach, and a button with no intent selects nothing"

    # The intent row is its own control surface, not the template row in
    # disguise: none of its buttons may be a template button.
    assert_empty row.css(".job-type-btn"),
      "the intent row must not reuse the template buttons' class"

    PipelineConf::INTENTS.each do |intent|
      btn = row.at_css("[data-intent='#{intent[:template]}']")
      refute_nil btn, "#{intent[:template]}: the intent's button must exist"
      assert_equal intent[:label], btn.text.strip,
        "#{intent[:template]}: the button must carry the intent's own label"
      assert_equal "false", btn["aria-pressed"],
        "#{intent[:template]}: the row opens on the default template, so no " \
        "intent starts pressed unless it maps to that default"
    end
  end

  # Clicking an intent is the SAME action as clicking the template button it
  # maps to: set the select, fire `change`, apply, repaint BOTH rows. Source
  # asserted because the round trip is client-side — the server has no DOM, which
  # is exactly why a JS-side selection defect survives a green suite.
  test "clicking an intent selects the mapped template through the one apply path" do
    form # issues the request; response.body then holds the whole page
    body = response.body

    # Both rows are wired to the ONE helper, differing only in which attribute
    # names the template.
    assert_includes body, "chooseTemplate(b.getAttribute('data-intent'))",
      "an intent click must go through chooseTemplate, not a second apply path"
    assert_includes body, "chooseTemplate(b.getAttribute('data-job-type'))",
      "and so must a template click, or the two rows can drift"

    fn = body[/function chooseTemplate\(key\) \{(.*?)\n  \}/m, 1]
    refute_nil fn, "chooseTemplate must be defined"
    assert_includes fn, "tplSel.value = key",
      "the intent must set the template select — the one control the form posts"
    assert_includes fn, "tplSel.dispatchEvent(new Event('change', { bubbles: true }))",
      "and fire change, so the group control syncs before Apply composes"
    assert_includes fn, "if (tplApply) tplApply.click();",
      "and apply, so the runner switch and the panel reveal stay in one place"
    assert_includes fn, "syncJobTypeButtons();"
    assert_includes fn, "syncIntentButtons();"

    # The pressed state of the intent row is painted from the SAME select the
    # template row is, so the two cannot disagree about what is selected.
    assert_includes body, "b.getAttribute('data-intent') === tplSel.value",
      "the intent row must be painted from the template select"

    # Repainted on init, on a select change, on a click and on a refused apply —
    # not only on init, or the row goes stale the moment anything else moves.
    assert_operator body.scan("syncIntentButtons();").size, :>=, 4,
      "the intent row's pressed state is repainted on init, on select change, " \
      "on click and on a refused apply"
  end

  # The blurb is one click away on the `?`; repeating it inline is a second copy
  # that can drift from the model that composes the contract.
  test "the intent row does not duplicate the template's blurb inline" do
    PipelineConf::INTENTS.each do |intent|
      btn = row.at_css("[data-intent='#{intent[:template]}']")
      blurb = PipelineConf.template(intent[:template])[:blurb]
      assert_equal blurb, btn["title"],
        "#{intent[:template]}: hover carries the blurb, exactly as the template " \
        "buttons do"
      refute_includes btn.text, blurb,
        "#{intent[:template]}: the blurb must NOT be repeated inline — it is one " \
        "click away on the `?` beside the label"
    end
  end

  # The template row is untouched: one button per template, in the groups' own
  # order. The intent row is a row ABOVE it, not a change to it.
  test "the template row below is unchanged" do
    tpl_row = field.at_css(".job-type-row")
    refute_nil tpl_row
    assert_equal PipelineConf.template_keys.size, tpl_row.css(".job-type-btn").size,
      "one button per template — the intent row must not have absorbed any"
    assert_equal PipelineConf.templates_by_group.flat_map(&:last),
                 tpl_row.css(".job-type-btn").map { |b| b["data-job-type"] },
      "and they must still be in PipelineConf::GROUPS render order"
  end
end
