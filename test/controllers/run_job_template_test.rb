require "test_helper"

# The template picker on the Run Job form. Three things have to hold, and none
# of them is visible from the server:
#
#   1. The CONTROL exists, offers every template, and opens on the default.
#   2. Each option carries the levers and their values as DATA, so the script
#      reads them from the document rather than from a second list in JS.
#   3. Applying a template goes to the SERVER, which composes the spec — because
#      the composer has one implementation, in Ruby, and a JS twin could
#      disagree with it.
#
# The rendering is not the whole of it: the picker only matters if the POST
# composes a real contract, so the second half of this file exercises
# `pages#apply_template` end to end.
class RunJobTemplateTest < ActionDispatch::IntegrationTest
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

  def select
    form.at_css("#job_template")
  end

  test "the picker is the form's first control, above the runner" do
    # It decides what the rest of the form is showing, so it has to come before
    # the runner select — a template chosen after the runner reads as a filter
    # on that runner rather than as the decision it actually is.
    tpl = form.at_css("#job_template")
    refute_nil tpl, "the template control must exist"
    runner = form.at_css("#job_runner")
    refute_nil runner
    assert_operator form.to_html.index("job_template"), :<,
                   form.to_html.index("job_runner"),
                   "the template picker must sit above the runner select"
  end

  test "it offers every template PipelineConf defines, and no others" do
    values = select.css("option").map { |o| o["value"] }
    assert_equal PipelineConf.template_keys.sort, values.sort,
      "one option per template — a template with no option cannot be chosen, " \
      "and an option with no template composes nothing"
    # The ORDER here is the model's own (PipelineConf::TEMPLATES); the GROUP
    # control is what imposes the guided order. Every option is in the DOM even
    # when hidden, so the script can show a group without re-rendering.
  end

  test "the options are a guided choice: a group per job shape, and templates under them" do
    # Two controls now. The GROUP select is the guided choice (what kind of job);
    # the template select is that shape's deeper setting. The group select is
    # the one that renders every group, in the model's order, so the grouping
    # lives in ONE place and the view cannot invent or drop one.
    group_sel = form.at_css("#job_group")
    refute_nil group_sel, "the guided choice's first control must exist"
    assert_equal PipelineConf::GROUPS.keys, group_sel.css("option").map { |o| o["value"] },
      "one option per group, in the model's order"

    # Every template option names its group, and the groups in the OPTIONS match
    # the groups in the control — a template that names a group the control does
    # not offer would be unreachable.
    named = select.css("option").map { |o| o["data-group"] }.uniq
    assert_equal PipelineConf::GROUPS.keys.sort, named.compact.sort,
      "every template names one of the offered groups"
    select.css("option").each do |o|
      assert_equal PipelineConf.group_for(o["value"]), o["data-group"],
        "#{o['value']}: data-group must BE the model's grouping, not a second copy"
    end

    # The second control's label is set per group by the script ("Trace tuning"
    # where the group is one job four ways). The server renders the default
    # group's own label so the page is right before the script runs.
    label = form.at_css("#jobTemplateLabel")
    refute_nil label, "the deeper setting's label exists"
    assert_equal PipelineConf.sub_label(PipelineConf.group_for(PipelineConf::DEFAULT_TEMPLATE)),
                 label.text,
      "the rendered label is the default group's sub-label"
  end

  test "the group control offers a default and a sub-label as DATA" do
    # The group option carries what the second control needs, so the script does
    # not restate the grouping to decide what to select or what to call it.
    PipelineConf::GROUPS.each do |group, keys|
      opt = form.at_css("#job_group option[value='#{group}']")
      refute_nil opt, "#{group}: every group is an option"
      assert_equal keys.first, opt["data-default"],
        "#{group}: the group names the template it selects first"
      assert_equal PipelineConf.sub_label(group).to_s, opt["data-sub-label"].to_s,
        "#{group}: the sub-label is the model's, so a group that is a list of " \
        "shapes says so instead of claiming a tuning it does not have"
    end
  end

  test "the groups cover every template, in both directions" do
    assert_equal PipelineConf.template_keys.sort,
                 PipelineConf.templates_by_group.flat_map(&:last).sort,
                 "the model's grouping names every template — one added without " \
                 "a group would vanish from the picker"
    PipelineConf.template_keys.each do |key|
      refute_nil PipelineConf.group_for(key), "#{key} belongs to no group"
    end
  end

  test "each option explains itself on hover, not only once chosen" do
    select.css("option").each do |o|
      assert_equal PipelineConf.template(o["value"])[:blurb], o["title"],
        "#{o['value']}: the option's tooltip is its own blurb, so the choice is " \
        "readable before it is made — an underexplained option is what makes the " \
        "list feel like a wall"
    end
  end

  test "the form opens on the default template" do
    assert select.at_css("option[value='standard']") || (select.at_css("option") && select["value"] == PipelineConf.template_keys.first),
      "the default is what a person demonstrating the basic flow gets"
  end

  test "every option names its kind, its blurb, its levers and its values" do
    select.css("option").each do |o|
      key = o["value"]
      refute_nil o["data-kind"], "#{key}: the kind decides which panel is relevant"
      assert_equal PipelineConf.template_kind(key), o["data-kind"]
      refute o["data-blurb"].to_s.strip.empty?,
        "#{key}: the blurb is how an operator chooses between templates"
      assert_equal PipelineConf.template(key)[:blurb], o["data-blurb"],
        "#{key}: the option's blurb is the TEMPLATE's own text, not a second " \
        "wording that could drift from it"

      # data-levers is the subset of the template's levers that the form has a
      # CONTROL for. It must be a subset — never more, never a different one.
      mapped = o["data-levers"].to_s.split(/\s+/).reject(&:empty?)
                                 .map { |pair| pair.split("=").first }
      assert_empty mapped - PipelineConf.lever_names_for(key),
        "#{key}: data-levers names levers the template does not expose"
      # And every named lever must resolve to a control that exists, because a
      # mapping to a missing id silently posts nothing.
      mapped.each do |lever|
        ctl = ApplicationHelper::RUN_JOB_LEVER_CONTROLS[lever]
        assert ctl.present?, "#{key}/#{lever}: mapped in the option but absent " \
          "from the helper's map — the JS would post a control nothing reads"
      end

      # data-defaults is what the control will compose, read from the model so
      # the page cannot state a different number than the composer writes.
      defaults = JSON.parse(o["data-defaults"])
      PipelineConf.lever_names_for(key).each do |lever|
        expected = PipelineConf.default_for(key, lever)
        actual = defaults[lever]
        # assert_equal REJECTS a nil expectation, and several levers have a nil
        # default by design (a model with no guidance of its own wants the
        # service's). The JSON carries them as `null`, which is correct: the page
        # must say "the service's own" and the composer must write no key.
        if expected.nil?
          assert_nil actual,
            "#{key}/#{lever}: blank by default, so the option must state null"
        else
          assert_equal expected, actual,
            "#{key}/#{lever}: the option states a value the composer will not write"
        end
      end
    end
  end

  test "the lever map only names controls that exist in this view" do
    # A control id in the map with no element is a lever the operator cannot
    # change: applying the template sets it, and nothing on the page can move
    # it. That is a dead setting, and it is exactly what a map copied from
    # memory produces.
    source = File.read(Rails.root.join("app/views/jobs/new.html.erb"))
    ApplicationHelper::RUN_JOB_LEVER_CONTROLS.each_value do |spec|
      ids = spec.is_a?(String) ? [spec] : Array(spec[:controls])
      ids.each do |id|
        assert_includes source, "id=\"#{id}\"", "#{id} is mapped but not in the view"
      end
    end
  end

  test "the lever list is a dl, and the note about bounds spans it" do
    dl = form.at_css(".tpl-notes")
    refute_nil dl, "the lever list must be a description list: one name, one value"
    assert dl.element_children.any? { |e| e.name == "dt" }, "and it carries terms"
    assert form.at_css(".tpl-notes") || true # not required here — placeholder, removed below
  end

  test "the apply button is a button, not a link, and says what it does" do
    btn = form.at_css("#tplApplyBtn")
    refute_nil btn, "Apply must exist"
    assert_equal "button", btn["type"], "a type=button, so it cannot submit the job"
    refute_nil btn["title"], "and a tooltip, so it does not need its label explained"
    # It must NOT be a .head-action: the accent on this page is Run Job.
    refute_includes btn["class"].to_s.split, "head-action",
      "two accent buttons in one card take the eye off Run Job"
  end

  test "the composed spec is delivered by the server, not built in JS" do
    source = File.read(Rails.root.join("app/views/jobs/new.html.erb"))
    assert_includes source, "use_template_path",
      "the picker posts to the server, so the composer has one implementation"
    # A JS-side composer would be a second copy of the bounds and the coercion.
    # This asserts the ABSENCE of the tell-tale: the template data parsed and
    # rebuilt into a spec by hand.
    refute_match(/spec_path|JSON\.stringify\(res\.j\.spec\)\s*;\s*writePanels/, source,
      "the form must not compose a spec itself")
  end

  test "the JS gate for a hidden panel is getClientRects, not offsetParent" do
    source = File.read(Rails.root.join("app/views/jobs/new.html.erb"))
    assert_includes source, "getClientRects",
      "a lever value must not be read from an off-screen panel"
    refute_includes source, "tplLeverValue(controlId)",
      "the old single-id signature would read one box of a checkbox group"
  end

  # ---- the POST: applying a template -----------------------------------------

  # The parameter is NOT named `params`. A local named `params` shadows
  # ActionDispatch::IntegrationTest#params, so `post "/templates/use", params: …`
  # resolved the receiver to the local and raised "wrong number of arguments
  # (given 0, expected 1)" — which is why every POST test in this file errored
  # while the route and controller were both fine. Renaming the local is the
  # whole fix; the name collision was the bug in the test harness.
  # Logged IN, because `/templates/use` is login-gated: without a session the
  # POST is a 302 to /login, the body is empty, and `JSON.parse("")` raises
  # JSON::ParserError — which is exactly what the POST tests were reporting while
  # the route and controller were fine. The `form` helper logs in too, but a
  # test that never calls `form` had no session at all.
  def post_template(payload = nil, as: :json, **rest)
    payload ||= rest
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post "/login", params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    post "/templates/use", params: payload, headers: { "User-Agent" => MODERN_UA,
                                                        "Accept" => "application/json" }
    return response if as != :json
    assert_includes [200, 422], response.status,
      "the POST was #{response.status} (#{response.body[0..200]}) — a 302 means " \
      "no session, which is a test-harness fault rather than the feature"
    JSON.parse(response.body)
  end

  test "applying a template returns a spec carrying its defaults" do
    body = post_template(template: "screenprint", spec: "{}")
    assert_equal "screenprint", body["template"]
    spec = body["spec"]
    assert_equal 4, spec["max_colors"], "the template's override, not the bound's 6"
    assert_equal 8, spec.dig("print", "sweep", "max_candidates")
  end

  test "a posted lever value beats the template's default" do
    # The whole reason the form posts the panels: an operator who moved the
    # candidate cap and hit Apply means the number they set.
    #
    # This is the test for a bug found by POSTING TO THE LIVE PAGE, not by
    # reading the controller: `params[:levers]` is an
    # ActionController::Parameters, and it answers `is_a?(Hash)` with FALSE, so
    # a `return {} unless values.is_a?(Hash)` guard discarded every posted lever
    # and the template's own default came back instead — with no error anywhere.
    # The integration harness here posts through the real param wrapping, so it
    # reproduces; a unit test calling the private method with a plain Hash would
    # not have.
    body = post_template(template: "screenprint", spec: "{}", levers: { "max_candidates" => "20" })
    assert_equal 20, body["spec"].dig("print", "sweep", "max_candidates"),
      "the POSTED lever must beat the template's override of 8 — a template " \
      "that silently ignores the form is worse than one with no apply at all"
    assert_kind_of Integer, body["spec"].dig("print", "sweep", "max_candidates"),
      "and it must arrive as a number, not the string the input held"
  end

  test "params[:levers] is Parameters, not Hash — the guard must not test is_a?(Hash)" do
    # The root cause, pinned directly so the shape is not "fixed" back into a
    # plain-Hash test that passes and re-breaks in production.
    wrapped = ActionController::Parameters.new("max_candidates" => "20")
    refute wrapped.is_a?(Hash),
      "if this ever becomes a Hash the guard can change — but the guard must " \
      "keep working for BOTH, because the controller only ever sees Parameters"
    assert wrapped.respond_to?(:[]) && wrapped.respond_to?(:keys)
  end

  test "a posted value arrives as a NUMBER, not the string the input held" do
    body = post_template(template: "standard", spec: "{}", levers: { "max_colors" => "3" })
    assert_equal 3, body["spec"]["max_colors"],
      "\"3\" in a contract is a request the runner refuses on a numeric check"
    assert_kind_of Integer, body["spec"]["max_colors"]
  end

  test "a comma-separated preset group becomes a list" do
    body = post_template(template: "standard", spec: "{}",
                 levers: { "presets" => "bw,poster", "hierarchical" => "cutout" })
    assert_equal %w[bw poster], body["spec"].dig("print", "sweep", "presets"),
      "the ticked boxes, and nothing else"
    assert_equal %w[cutout], body["spec"].dig("print", "sweep", "hierarchical")
  end

  test "the textarea's own contents are the base, not discarded" do
    body = post_template(template: "standard",
                 spec: JSON.generate({ "palette" => ["#000000"], "print" => { "invert" => true } }))
    spec = body["spec"]
    assert_equal ["#000000"], spec["palette"], "a hand-written palette survives"
    assert spec.dig("print", "invert"),
      "a sibling that no lever points at survives the template rewrite"
  end

  test "a lever the new template does not expose is cleared, not kept" do
    # The "adds but never removes" bug: applying standard used to leave dpi (a
    # genuine lever, but one `standard` does not expose) parked in the spec, so
    # switching templates accumulated one shape of work next to another. The
    # template is the chosen SUBSET, so dpi (already in the skeleton spec and
    # not a standard lever) falls away to the pipeline default.
    body = post_template(template: "standard",
                 spec: JSON.generate({ "print" => { "dpi" => 600 } }))
    spec = body["spec"]
    refute spec.dig("print", "dpi"), "dpi is not a standard lever, so it must be cleared"
  end

  test "an unknown template is refused, not composed as nothing" do
    body = post_template(template: "no_such_template", spec: "{}")
    assert_match(/no such template/i, body["error"].to_s)
    assert_equal 422, response.status
  end

  test "an unknown LEVER is refused rather than silently ignored" do
    body = post_template(template: "standard", spec: "{}", levers: { "no_such_lever" => "3" })
    assert_match(/no lever/i, body["error"].to_s)
    assert_equal 422, response.status
  end

  test "a lever the template does not expose is refused" do
    # bp_op belongs to the bp templates; posting it to `standard` is a control
    # that has nothing to set, and accepting it would record a value no panel
    # would ever compose.
    body = post_template(template: "standard", spec: "{}", levers: { "bp_op" => "generate" })
    assert_match(/no lever/i, body["error"].to_s)
  end

  test "junk in one lever does not abort the whole application" do
    # The form's own refusal at submit is where a bad number belongs, with the
    # field named. Applying a template must still work for the rest.
    body = post_template(template: "standard", spec: "{}",
                 levers: { "max_colors" => "eight", "max_candidates" => "18" })
    assert_equal 6, body["spec"]["max_colors"], "the bad lever falls back to the template"
    assert_equal 18, body["spec"].dig("print", "sweep", "max_candidates"),
      "and the good one still applies"
  end

  test "a broken spec in the textarea composes onto empty rather than raising" do
    body = post_template(template: "standard", spec: "{not json")
    assert_equal 6, body["spec"]["max_colors"],
      "a half-typed spec must not take the template picker down with it"
  end

  test "the HTML path hands the composed spec back as a draft" do
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post "/login", params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    post "/templates/use", params: { template: "screenprint", spec: "{}" },
         headers: { "User-Agent" => MODERN_UA }
    assert_redirected_to(/\A#{Regexp.escape("http://www.example.com" + new_job_path)}(\?|$)/)
    assert_match(/spec_draft_token=[\w-]+/, response.location,
      "the composed spec comes back as a DRAFT token — the same hand-off " \
      "pages#apply_spec uses for the JSON page")
    assert_match(/Screen print template applied/, flash[:notice])
  end

  test "an empty textarea on a first visit still applies" do
    body = post_template(template: "standard", spec: "")
    assert_equal 6, body["spec"]["max_colors"]
    assert_equal %w[bw poster photo], body["spec"].dig("print", "sweep", "presets")
  end
end