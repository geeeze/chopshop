require "test_helper"

# The Run Job page: the job contract used to be a COLLAPSED accordion
# (display:none) inside a card capped at max-width:760px — the one thing that
# configures the run, hidden behind a toggle. It is now a permanent half-width
# column beside the form.
class RunJobLayoutTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # The artwork field and the FLUX panel are swapped by toggling `hidden`, and
  # the row they live on is `.actions-row { display: flex }`. The attribute only
  # hides through the UA stylesheet, so an author `display` rule outranks it and
  # the row stayed on screen: the form showed the artwork box AND the prompt at
  # once. Every server-side assertion passed while it did -- the markup was
  # right. Only a browser could see it, so the guarantee is pinned here.
  test "the hidden attribute actually hides, even on a flex row" do
    css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))
    guard = css[/^\[hidden\]\s*\{([^}]*)\}/m, 1]

    refute_nil guard,
      "`hidden` needs a rule of its own: the UA stylesheet's is outranked by any author display rule"
    assert_match(/display:\s*none/, guard)
    assert_match(/!important/, guard,
      "without !important a `display` rule wins again, which is what broke this page")
  end

  def page
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    response.body
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  test "the form and the job contract are two columns" do
    html = page

    assert_includes html, "run-grid", "the two columns must share one grid"
    assert_includes html, "run-form-col", "the form column must exist"
    assert_includes html, "run-contract-col", "the contract column must exist"
    assert html.index("run-form-col") < html.index("run-contract-col"),
      "the form is the left column, the contract the right"
  end

  test "the contract is visible, not collapsed behind the accordion" do
    html = page

    refute_includes html, "specToggle",
      "the accordion toggle is gone — the contract is not hidden any more"
    refute_includes html, "spec-section",
      "the collapsed spec section is gone"
    # The old markup hid the body with an inline display:none.
    refute_match(/id="specBody"[^>]*display:\s*none/, html,
      "the contract must not ship hidden")
  end

  test "the contract textarea is INSIDE the form, so it posts with the job" do
    html = page

    form = html[/<form[^>]*id="new-job-form".*?<\/form>/m]
    refute_nil form, "the job form must exist"
    assert_includes form, 'name="job[spec]"',
      "the contract must post as job[spec] -- if it sits outside the <form> " \
      "it is silently dropped on submit"
    assert_includes form, "run-contract",
      "the contract textarea must be inside the form element"
  end

  test "the contract ships with the default template's own composed JSON" do
    html = page

    # The form opens on compose(DEFAULT_TEMPLATE), not a hand-written literal —
    # so the assertions are the keys the default template actually OWNS. It used
    # to ship `print_method: "screen_print"` and a 6-ink palette: keys no lever
    # and no template fragment owns, which PipelineConf#remove_decay therefore
    # could never clear. Switching template left that residue in the contract.
    #
    # The DEFAULT is the General group's job now (the job-type row opens on
    # General), so the owned keys are read from that template rather than named
    # here -- the point is that the contract is the default's own compose, and
    # naming one of its keys would pin the choice of default instead.
    spec = JSON.parse(Nokogiri::HTML(html).at_css("textarea[name='job[spec]']").text)
    expected = JSON.parse(JSON.pretty_generate(PipelineConf.compose(PipelineConf::DEFAULT_TEMPLATE, into: {})))
    assert_equal expected, spec,
      "the textarea must open on compose(DEFAULT_TEMPLATE), not a literal"
    refute_includes html, "print_method",
      "the default must not seed a key no template owns: it survives every " \
      "template switch, which is the residue this fixes"
  end

  # ONE authoritative sweep cap. trace_sweep.py prefers the namespaced
  # print.sweep.max_candidates and only falls back to the legacy
  # print.sweep_max_candidates when the namespaced key is absent — so a default
  # that wrote the legacy key while the panel wrote the modern one carried two
  # caps in one contract, and the panel could not even show the legacy number.
  #
  # Asserted over the PRINT templates rather than the default: the cap lives in
  # the trace contract, and the form's default is a General job with no print
  # block at all -- reading it off the default would have made this test pass by
  # having nothing to measure.
  test "a print template's composed contract carries the ONE sweep cap key the panel writes" do
    PipelineConf::GROUPS["Print production"].each do |key|
      spec = PipelineConf.compose(key, into: {})
      # The VALUE is the template's own default and differs per preset (8 / 12 /
      # 12 / 24) -- asserting one number here would pin the presets apart rather
      # than pin the rule. What must hold for all of them is the KEY SHAPE.
      refute_nil spec.dig("print", "sweep", "max_candidates"),
        "#{key} must write print.sweep.max_candidates, the nested key the tracer reads"
      refute spec["print"].key?("sweep_max_candidates"),
        "#{key}: the legacy key must be gone -- two caps in one contract is what this fixes"
      assert_equal PipelineConf.default_for(key, "max_candidates"),
                   spec.dig("print", "sweep", "max_candidates"),
        "#{key}: the composed cap must be this template's own default"
    end
  end

  test "the default contract is the default template's, and that template is General's" do
    html = page
    spec = JSON.parse(Nokogiri::HTML(html).at_css("textarea[name='job[spec]']").text)

    assert_equal PipelineConf::GROUPS["General"].first, PipelineConf::DEFAULT_TEMPLATE,
      "the default template must be the one the General job-type button applies"
    assert_equal JSON.parse(JSON.pretty_generate(PipelineConf.compose(PipelineConf::DEFAULT_TEMPLATE, into: {}))), spec,
      "the contract must open on the same template the pressed button names, " \
      "or the page states two different jobs before anything is clicked"
  end


  test "the form columns are half width and stack on narrow screens" do
    css = Rails.root.join("app/assets/stylesheets/application.css").read

    # `.run-grid` is SHARED with the composite builder and the New Project form,
    # so its base layout is still the 50/50 pair. Run Job is the exception and
    # carries its own modifier -- see the next test.
    assert_match(/\.run-grid \{\s*display: grid;\s*grid-template-columns: 1fr 1fr;/m, css,
      "the shared grid's two columns must stay 50/50")
    assert_match(/@media \(max-width: 900px\) \{\s*\.run-grid \{ grid-template-columns: 1fr; \}/m, css,
      "the columns must stack below 900px")
    assert_match(/\.run-contract \{[^}]*white-space: pre-wrap;/m, css,
      "the contract must soft-wrap so a long value folds instead of scrolling")
  end

  # The contract is a DIALOG now, not the grid's second column. Two things have
  # to hold for that to be true, and both are the kind that look fine while
  # being wrong: the form must have the whole width, and the textarea must still
  # be inside the <form> (it is a real job[spec] field -- a popup rendered
  # outside the form would still LOOK right and post nothing).
  # The page is two CARDS side by side, like every other page in the app whose
  # top level is a `.grid-2`/`.run-grid` pair. An earlier attempt put a grid
  # INSIDE the single form card and left that card full width, which is not two
  # columns however the inner grid measures.
  test "the form is two cards side by side in the page's own grid" do
    doc = Nokogiri::HTML(page)
    grid = doc.at_css("form#new-job-form > .run-grid")
    refute_nil grid, "the form's top level must be the .run-grid"

    cards = grid.css("> .card")
    assert_equal 2, cards.size,
      "two cards, not one -- the page is two columns because there are two tracks"
    assert_includes cards[0]["class"], "run-form-col",
      "the first card holds the job's own fields"
    assert_includes cards[1]["class"], "run-kind-col",
      "and the second holds the fields the job-type row swaps"

    # The kind panels are in the SECOND card, which is what makes switching the
    # job type swap the right-hand column.
    panels = cards[1].css("[data-run-fields]")
    assert_operator panels.size, :>=, 4,
      "every kind's panel belongs to the job-type card"
    assert_empty cards[0].css("[data-run-fields]"),
      "and none of them may sit in the left card"

    css = Rails.root.join("app/assets/stylesheets/application.css").read
    # The two columns are the site's own grid: `.run-grid` declares `1fr 1fr`.
    assert_match(/\.run-grid \{\s*display: grid;\s*grid-template-columns: 1fr 1fr;/m, css,
      "the two columns must be .run-grid's own 1fr 1fr")
    # ...and nothing may collapse it back to one for the job page.
    refute_match(/\.run-grid--job\s*\{\s*grid-template-columns/, css,
      "no modifier may override the job page's two columns")
    assert_match(/@media \(max-width: 900px\) \{\s*\.run-grid \{ grid-template-columns: 1fr; \}/m, css,
      "and it must stack below 900px")
  end

  test "the contract is a dialog and the form takes the full width" do
    doc = Nokogiri::HTML(page)
    popup = doc.at_css("#job-json-popup")
    refute_nil popup, "the contract must be a popup"
    assert popup.has_attribute?("hidden"),
      "it must start hidden, not open the way the old column was always visible"
    refute_nil popup.at_css("textarea[name='job[spec]']"),
      "the contract textarea still has to be there"
    refute_nil popup.at_css("[data-popup-close]"), "and it must be closeable"
    refute_nil doc.at_css("[data-popup='job-json-popup']"),
      "the head needs the JSON button that opens it"

    # The textarea is inside the popup; the popup must be inside the form, or
    # the spec never posts.
    form = doc.at_css("form#new-job-form")
    refute_nil form, "the form must exist"
    assert_includes form.to_html, "job-json-popup",
      "the contract popup must live INSIDE the form -- outside it, the spec would never be posted"
  end


  test "the dead accordion handler is gone" do
    html = page

    refute_includes html, "specToggle",
      "the accordion JS would throw: toggle would be null"
    assert_includes html, "copySpecBtn",
      "the contract column's Copy button must be wired"
  end

  # The scissor orb belongs on the SAME LINE as the artwork tile, at the
  # right edge. It wasn't: the hint was a child of the button row, wrapped to
  # three lines, and `align-items: flex-end` then bottom-aligned the buttons
  # against the HINT instead of the tile — measured tile.top=625, buttons.top=680.
  test "the upload hint is NOT inside the button row" do
    html = page
    doc = Nokogiri::HTML(html)

    row = doc.at_css(".upload-actions")
    refute_nil row, "the upload-actions row must exist"
    # Nokogiri, not a regex: a greedy /<\/div>\s*<\/div>/ pattern runs straight
    # past the row's closing tag and picks up the sibling hint, which made this
    # assertion fail against markup that was already correct.
    refute row.at_css("#uploadHint"),
      "the hint must be a SIBLING of the button row, not a child of it"

    hint = doc.at_css("#uploadHint")
    refute_nil hint, "the hint must still exist"
    assert_equal "upload-hint", hint["class"].split.last,
      "the hint carries .upload-hint so it can sit below the row"
    assert hint.parent != row,
      "the hint's parent must not be the button row"
  end

  test "the hidden input_path field survived the markup move" do
    html = page

    # It was a child of the picker block and was briefly lost in the move; the
    # form would then submit without the uploaded artwork path.
    assert_includes html, 'id="inputPathField"',
      "the hidden input_path field must still be in the form"
    form = html[/<form[^>]*id="new-job-form".*?<\/form>/m]
    assert_includes form, "inputPathField",
      "the hidden field must be inside the form element"
  end

  # The artwork picker is the page's primary input and was smaller (180x72) than
  # the text fields above it, with 48px buttons beside it. All three scaled up
  # together, and the two columns now take each other's height.
  # Comments are stripped first: an explanatory comment sits between a rule's
  # selector and its declarations, so a /\{.*?width:/ pattern cannot cross it
  # and silently matched nothing.
  def css_without_comments
    Rails.root.join("app/assets/stylesheets/application.css").read
         .gsub(%r{/\*.*?\*/}m, "")
  end

  test "the artwork picker and its buttons are scaled up together" do
    css = css_without_comments

    tile = css[/\.upload-tile \{.*?width: (\d+)px;\s*height: (\d+)px;/m]
    refute_nil tile, "the upload tile must declare an explicit size"
    w, h = tile.scan(/(\d+)px/).flatten.map(&:to_i)
    assert w >= 280, "the tile should be at least 280px wide, got #{w}"
    assert h >= 112, "the tile should be at least 112px tall, got #{h}"

    # The preview must match the tile it replaces, or swapping tile -> preview
    # changes the row height and nudges the buttons.
    # Not a fixed square any more: the preview hugs its art at a fixed HEIGHT.
    # A square assertion was really asserting the old 96x96 box, which is what
    # made the raster the smallest thing on the line.
    img_rule = css[/\.upload-thumb img \{.*?\}/m]
    refute_nil img_rule, "the preview image must be sized"
    th = img_rule[/height: (\d+)px;/, 1].to_i
    assert_operator th, :>, 80, "the preview should be enlarged too, got #{th}"
    assert_includes img_rule, "width: auto",
      "auto width + a fixed height is what lets it hug any aspect"
    refute_includes img_rule, "width: 96px", "the fixed square is gone"
  end

  # The run action moved out of the artwork tile's line and into the page head,
  # top right, in the same slot and size as the Jobs list's own button. It was
  # down on the tile's line where it read as a third control on that row.
  test "the run action is the page-head button, matching the Jobs list" do
    html = page
    doc = Nokogiri::HTML(html)

    btn = doc.at_css("#runJobBtn")
    refute_nil btn, "the run action must exist"
    assert_equal "Run Job", btn.text.strip,
      "the button reads as the bare words 'Run Job' -- no glyph, no plus"
    assert_no_match(/✂|＋/, btn.text, "no icon and no leading plus")
    assert_equal "Run Job", btn["aria-label"],
      "the accessible name must match the visible label"
    assert_includes btn["title"], "Run",
      "the tooltip must describe the action"

    # Same slot on the page: inside the split page-head row, beside the title.
    refute_nil doc.at_css(".page-head-row--split #runJobBtn"),
      "the button must sit in the page head's split row"
    refute_nil doc.at_css(".page-head-row--split .section-title"),
      "the title must share that row with it"

    # A plain .btn.btn-primary is what the Jobs list uses; the old tile-line
    # pill styling must be gone, not merely unused.
    assert_includes btn["class"].split, "btn"
    assert_includes btn["class"].split, "btn-primary"
    refute_includes btn["class"], "btn-scissor",
      "the 72px scissor-pill sizing belongs to a button that no longer exists"

    # The Jobs list lost its own page in the Projects redesign; the PROJECT
    # WORKSPACE (projects/show) is where a project's runs are listed now, and
    # its Run Job head action carries the same .head-action class this button
    # mirrors. The substring stops short of the closing quote on purpose: the
    # workspace button also carries head-action--top, and the contract here is
    # the shared .head-action, not the absence of a modifier.
    jobs = File.read(Rails.root.join("app/views/projects/show.html.erb"))
    assert_includes jobs, 'btn btn-primary head-action',
      "the list button this one mirrors must carry the same .head-action, " \
      "which is the only reason all three heads measure the same box"
  end

  # It is type="button" and OUTSIDE the <form> on purpose: it has to be able to
  # ask first and only then submit.
  test "the run action asks for confirmation before running" do
    html = page
    doc = Nokogiri::HTML(html)

    btn = doc.at_css("#runJobBtn")
    assert_equal "button", btn["type"],
      "a submit button would post the form before any confirmation could be asked for"
    assert_nil doc.at_css("form#new-job-form #runJobBtn"),
      "the button must be outside the form so it can gate the submit"

    assert_includes html, "runJobOk",
      "the confirm dialog must have a Run Job confirm button"
    assert_includes html, "Confirm?",
      "the dialog must be titled Confirm?"
    assert_includes html, 'data-cs-close="1">Cancel',
      "the dialog must offer Cancel"
    assert_includes html, "reallyRun",
      "the confirm handler must be wired to the submit path"
    assert_includes html, "requestSubmit",
      "requestSubmit (not submit) keeps the existing upload guard firing -- " \
      "form.submit() fires no submit event, so a form with no artwork would post"
  end

  test "nothing is left on the artwork tile's line" do
    html = page
    doc = Nokogiri::HTML(html)

    assert_nil doc.at_css(".upload-actions .actions-row-buttons"),
      "the button row went with the button; the wrapper must be gone too"
    refute_includes html, "submitBtn",
      "the old id must be gone, not merely unreferenced"
  end

  # The uploaded preview fills the section's width without growing its height.
  test "the uploaded preview fills the width, at a fixed height" do
    css = css_without_comments

    thumb = css[/\.upload-thumb \{.*?\}/m]
    assert_includes thumb, "flex: 1 1 auto",
      "the preview must take the column's width once artwork is loaded"
    assert_includes thumb, "min-width: 0",
      "without it the meta text forces the box wider than its column"

    # The field is the preview. The caption is context, so it is capped --
    # the old `max-width: none` is what let the filename and size take the
    # whole rest of the row and leave the raster at 96x96.
    meta = css[/\.upload-thumb-meta \{.*?\}/m]
    assert_includes meta, "flex: 0 0 auto", "the caption must stop growing"
    assert_match(/max-width: \d/, meta, "and be capped")
    refute_includes meta, "max-width: none"

    img = css[/\.upload-thumb img \{.*?height: (\d+)px;.*?\}/m]
    assert_match(/\.upload-thumb img \{.*?height: (\d+)px;/m, css)
    height = img.scan(/height: (\d+)px/).flatten.first.to_i
    assert_operator height, :<=, 96,
      "the preview height is fixed so loading artwork does not resize the section"
  end

  test "the two columns stretch to each other's height" do
    css = css_without_comments

    grid = css[/\.run-grid \{.*?\}/m]
    assert_includes grid, "align-items: stretch",
      "the grid must stretch, or the shorter column ends in a ragged card"
    assert_includes css, ".run-contract-col .run-contract { flex: 1; }",
      "the contract textarea must take the leftover height, not stop at min-height"
    assert_match(/\.run-form-col,\s*\.run-contract-col \{\s*display: flex;\s*flex-direction: column;/m, css,
      "both cards must be flex columns so their contents can hug the top")
  end

  # The job-type section leaked literal `}` characters into the rendered
  # page: four ERB comments were closed `%>}` instead of `%>`, and the
  # brace after the comment's close is plain text output. The leaks sat
  # between the PROJECT picker and the JOB TYPE label, right after the
  # button row, inside the hidden template selects, and inside the JSON
  # popup's contract card — the whole job-type surface, so the check is
  # the entire rendered document, not the one spot first seen. A text
  # node that is a lone brace is never legitimate page text: the
  # contract JSON rides in ONE textarea text node (newlines inside it),
  # so a lone-brace node outside textarea/pre can only be a leak.
  test "no stray template braces leak into any rendered page text" do
    html = page
    doc = Nokogiri::HTML(html)

    leaked = []
    doc.traverse do |node|
      next unless node.text?
      stripped = node.text.strip
      next unless stripped == "}" || stripped == "{"
      leaked << node.parent.name unless %w[textarea pre].include?(node.parent.name)
    end
    assert_empty leaked,
      "stray template braces leaked into rendered text under: " \
      "#{leaked.uniq.join(', ')} — an ERB comment closed `%>}` " \
      "prints the brace as page text"
  end

  # The job-type section's place in the two-column card design: the row
  # of template buttons lives in the form column's card, and every
  # per-kind panel lives in the second card beside it — one grid, two
  # cards, nothing full-width in between.
  test "the job-type row and every kind panel sit in the two-column card design" do
    html = page
    doc = Nokogiri::HTML(response.body)

    grid = doc.at_css("form#new-job-form > .run-grid")
    refute_nil grid, "the form's top level must be the .run-grid"
    form_col = grid.at_css(".run-form-col")
    kind_col = grid.at_css(".run-kind-col")
    refute_nil form_col, "the form column card must exist"
    refute_nil kind_col, "the kind panels column card must exist"

    row = form_col.at_css(".job-type-field .job-type-row")
    refute_nil row, "the job-type row lives in the form column's card"
    assert_operator row.css(".job-type-btn").size, :>=, 10,
      "one button per template, all in the row"
    # The category captions are GONE. They were five uppercase labels inside a
    # row of buttons -- chrome the buttons already carry in their titles -- and
    # the operator asked for them out. PipelineConf::GROUPS still decides the
    # ORDER (pinned in run_job_template_test.rb).
    assert_equal 0, row.css(".job-type-group").size,
      "no category text labels inside the button row"

    panels = doc.css("[data-run-fields]")
    refute_empty panels, "the job-type panels must render"
    assert_equal panels.size, kind_col.css("[data-run-fields]").size,
      "every job-type panel lives in the kind column card — the " \
      "two-column card design, not a full-width stack"
  end

  # The scroll lock (#78), now owned by the shared core (aether-core.js) so the
  # popups and the glass modal hold ONE lock rather than two copies. Locking
  # scroll through `body { overflow: hidden }` is propagated to the viewport,
  # which REMOVES the viewport scrollbar and widens the viewport by the
  # scrollbar's width — so every `1fr` track on the page grows by a share of it.
  # Measured in a browser at 1280px: the Run Job page's two 557px `.run-grid`
  # columns became 564px the moment any popup opened, and moved back on close —
  # the "dropdowns resize the page columns" report, and the popup open/close is
  # the interaction that did it, on every page, because the lock is the shared
  # component. The lock must therefore MEASURE the scrollbar and reserve its
  # width with padding-right (the body's content box then measures the same
  # locked or not), and must hold the lock while ANY overlay is open.
  test "the shared scroll lock reserves the scrollbar width so columns cannot resize" do
    js = Rails.root.join("app/javascript/aether-core.js").read

    assert js.match?(/function lockScroll\(/), "the lock must be its own function"
    assert_match(/window\.innerWidth - document\.documentElement\.clientWidth/, js,
      "the scrollbar width must be MEASURED, not a constant — " \
      "scrollbars differ by platform and zoom")
    assert_match(/document\.body\.style\.paddingRight = scrollbar \+ 'px'/, js,
      "the lock must reserve the scrollbar's width with padding-right, " \
      "or the viewport widens and every 1fr track grows when a popup opens")
    assert_match(/document\.body\.style\.overflow = 'hidden'/, js,
      "the lock itself must still lock scroll")

    assert js.match?(/function unlockScroll\(/), "the unlock must be its own function"
    assert_match(/document\.querySelector\('\.popup:not\(\[hidden\]\)'\)/, js,
      "the unlock must keep the lock while any popup is still open")
    assert_match(/document\.body\.style\.paddingRight = ''/, js,
      "the unlock must release the reserved width")
  end

  # portalPopups() moves every popup onto <body>, which is right for the
  # stacking context and WRONG for a popup carrying form fields: a control
  # outside its <form> is not submitted, silently. That is how the Run Job page
  # lost its whole contract -- every POST /jobs carried no `job[spec]`, and the
  # model answered "a FLUX job needs a prompt" while the operator's prompt sat
  # in the box. #88.
  #
  # This is a SOURCE TRIPWIRE, not the proof: the real verification is a
  # browser submitting the form and reading back FormData (measured: with the
  # attribute, job[spec] is present at 137 chars; without it, absent). Ruby has
  # no JS runtime here, so the suite can only pin that the association happens
  # BEFORE the move -- which is the one ordering that cannot be expressed any
  # other way.
  test "portalPopups re-associates a form control before lifting its popup" do
    js = Rails.root.join("app/javascript/aether.js").read

    fn = js[/function portalPopups\(\) \{(.*?)\n  \}/m, 1]
    refute_nil fn, "portalPopups must exist"

    i_assoc = fn.index("reassociateFormControls(popups[i], owner)")
    i_move  = fn.index("document.body.appendChild(popups[i])")
    refute_nil i_assoc,
      "the popup's controls must be re-pointed at their form before it is lifted"
    refute_nil i_move, "and the popup must still be lifted"
    assert_operator i_assoc, :<, i_move,
      "AFTER the move is too late: el.form already resolves to nothing"

    assert_includes fn, 'popups[i].closest("form")',
      "the form it belongs to has to be read BEFORE the control is moved"
    assert_includes js, 'el.setAttribute("form", form.id)',
      "the `form=` attribute is the mechanism that survives a DOM move"
    assert_includes js, "el.form === form",
      "only a control that really descends from this form may be re-pointed"
    assert_includes js, "if (!form || !form.id) return;",
      "no id means nothing to point at -- and no guessing"
  end

  # The job-type notes are a HELP POPUP now, not inline small print, and the
  # popup is the ONE hint registry's (HelpTips, app/lib/help_tips.rb): one
  # `jobtype.<template>` key per template, opened by a help_tip(key) `?` beside
  # the Job type label. Eleven templates each restating a blurb and a lever list
  # made that block the tallest thing on the page and the least read, and a
  # bespoke hidden target was a second mechanism this page had to maintain.
  # What matters is that the words MOVED rather than disappeared.
  test "the job-type notes are registry help popups, and the words moved" do
    doc = Nokogiri::HTML(page)
    field = doc.at_css(".job-type-field")
    refute_nil field, "the job-type field must exist"

    # Nothing left inline: the blurb, the lever list and the bounds note all
    # belong in the popups. A copy left outside them is the clutter this change
    # exists to remove.
    assert_empty field.element_children.select { |el|
      (el["class"].to_s.split & %w[tpl-blurb tpl-notes tpl-notes-head help-notes
                                   jobtype-set jobtype-set-row jobtype-prose]).any?
    }, "the notes must not sit inline under the button row"

    # ONE `?` PER TEMPLATE, every one but the selected template's hidden, so a
    # single click always opens the notes for the job type the row is showing --
    # and the registry-integrity test is what keeps the key list and the
    # template list from drifting apart.
    tips = field.css(".job-type-tip")
    assert_equal PipelineConf.template_keys.sort,
                 tips.map { |t| t["data-job-type-tip"] }.sort,
      "one `?` per template -- a template with no `?` has no notes"
    visible = tips.reject { |t| t.has_attribute?("hidden") }
    assert_equal [PipelineConf::DEFAULT_TEMPLATE],
                 visible.map { |t| t["data-job-type-tip"] },
      "exactly the selected template's `?` is on screen"

    # Each `?` is a help_tip(key): the registry's own standard popup, not a
    # second mechanism.
    visible.each do |tip|
      btn = tip.at_css("button.help-tip-btn")
      refute_nil btn, "#{tip["data-job-type-tip"]}: the `?` must be a help_tip button"
      popup = doc.at_css("##{btn["data-popup"]}")
      refute_nil popup,
        "#{tip["data-job-type-tip"]}: the button must name an existing popup"
      assert_includes popup["class"].split, "popup",
        "the popup is the app's standard shape"
    end

    # The words themselves, not just the containers.
    detail = HelpTips.fetch("jobtype.#{PipelineConf::DEFAULT_TEMPLATE}")[:detail]
    assert_includes detail, PipelineConf.template(PipelineConf::DEFAULT_TEMPLATE)[:blurb],
      "the blurb must arrive with the popup"
    assert_includes detail, "A template never restates a range",
      "the bounds note is kept word for word"
    assert_includes detail, "trace_sweep.py"
  end

  # The template's blurb used to double as Apply's error line, inside the job-type
  # popup: a refusal written there is a message nobody can see, which is the same
  # as no message. The status has a visible line of its own -- and now that the
  # blurb is the registry's, nothing in this page may write to one at all.
  test "Apply reports refusals where the operator can see them" do
    body = page
    doc = Nokogiri::HTML(body)

    status = doc.at_css("#tplStatus")
    refute_nil status, "Apply needs a feedback line OUTSIDE the popup"
    assert status.has_attribute?("hidden"), "silent until it has something to say"

    # Every reporting site.
    assert_includes body, "setTplStatus(res.j.error"
    assert_includes body, "setTplStatus('Could not apply that template — network error.'"
    assert_includes body, "setTplStatus('This deployment offers no runner of kind "
    # And no blurb element left to write to: the notes are the registry's.
    refute_includes body, "tplBlurb", "the blurb element is gone -- it is the registry's"
    refute_includes body, "renderTemplateNotes",
      "the note renderer is gone -- the popup is rendered from the registry"
    refute_includes body, "jobTypeNotes",
      "the bespoke hidden target is gone -- the popup is help_tip's"
  end

  # Runner / Source kind / Prompt source: toggle buttons over a HIDDEN select.
  # The select stays because it is what posts and what every listener is bound
  # to; the buttons are a second VIEW of one control, not a second control.
  test "runner, source kind and prompt source are toggle rows over hidden selects" do
    body = page
    doc = Nokogiri::HTML(body)

    [ ["job_runner", Job.form_runners.size],
      ["job_source_kind", 2],
      ["prompt_source", 2] ].each do |id, count|
      sel = doc.at_css("##{id}")
      refute_nil sel, "#{id} must still be in the document -- it is what posts"
      assert sel.has_attribute?("hidden"),
        "#{id} is hidden behind its toggle row, never removed"

      row = doc.at_css("[data-mode-row='#{id}']")
      refute_nil row, "#{id} needs its toggle row"
      btns = row.css(".mode-btn")
      assert_equal count, btns.size, "#{id}: one button per option"

      # A button naming a value the select does not carry sets the select to
      # nothing and the form posts an empty field -- the one way this pattern
      # fails silently.
      assert_equal sel.css("option").map { |o| o["value"] }.sort,
                   btns.map { |b| b["data-mode-value"] }.sort,
        "#{id}: the buttons must cover exactly the select's own options"
      assert_equal 1, btns.count { |b| b["aria-pressed"] == "true" },
        "#{id}: exactly one option reads as chosen"
    end

    # The click path, in source: assign the select, then fire a REAL change --
    # the listeners are on the select, and assigning .value fires nothing.
    assert_includes body, "sel.dispatchEvent(new Event('change'"
    assert_includes body, "window.syncModeToggles = syncModeToggles",
      "the template Apply sets the runner programmatically and must repaint " \
      "these rows itself"
  end
end
