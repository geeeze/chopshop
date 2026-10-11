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
    assert_includes html, "max_colors",
      "the default contract must be rendered into the textarea"
    assert_includes html, "min_stroke_width_pt",
      "the default contract must be rendered into the textarea"
    refute_includes html, "print_method",
      "the default must not seed a key no template owns: it survives every " \
      "template switch, which is the residue this fixes"
  end

  # ONE authoritative sweep cap. trace_sweep.py prefers the namespaced
  # print.sweep.max_candidates and only falls back to the legacy
  # print.sweep_max_candidates when the namespaced key is absent — so a default
  # that wrote the legacy key while the panel wrote the modern one carried two
  # caps in one contract, and the panel could not even show the legacy number.
  test "the default contract carries the ONE sweep cap key the panel writes" do
    # The textarea's content is HTML-escaped, so it is read as TEXT (Nokogiri
    # decodes the entities) and parsed as the JSON the page would post.
    doc = Nokogiri::HTML(page)
    field = doc.at_css("textarea[name='job[spec]']")
    refute_nil field, "the contract textarea must exist"
    spec = JSON.parse(field.text)

    assert_equal 12, spec.dig("print", "sweep", "max_candidates"),
      "the default must write print.sweep.max_candidates, the nested key the tracer reads"
    refute spec["print"].key?("sweep_max_candidates"),
      "the legacy key must be gone from the default: two caps in one contract is what this fixes"
    refute_includes page, "sweep_max_candidates",
      "and it must not survive anywhere else in the shipped page either"
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
  test "the contract is a dialog and the form takes the full width" do
    css = Rails.root.join("app/assets/stylesheets/application.css").read

    assert_match(/\.run-grid--job \{\s*grid-template-columns: minmax\(0, 1fr\);/m, css,
      "Run Job must collapse the grid to one column")
    assert_includes page, "run-grid--job",
      "and the page must carry the modifier that does it"

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

  test "the settings panels lay out in two columns" do
    css = Rails.root.join("app/assets/stylesheets/application.css").read

    assert_match(/\.run-grid--job \.run-form-col \[data-run-fields\]:not\(\[hidden\]\) \{\s*display: grid;\s*grid-template-columns: repeat\(2, minmax\(0, 1fr\)\);/m, css,
      "a visible panel must be a two-column grid")
    assert_match(/\.run-grid--job \.run-form-col \[data-run-fields\]:not\(\[hidden\]\) > \.actions-row/m, css,
      "a row of actions must span, not sit in one cell")
    # The whole mechanism is the `hidden` ATTRIBUTE, so the grid rule must never
    # apply to a hidden panel -- otherwise every kind's fields are on screen at
    # once and the panel switcher silently stops being one.
    refute_match(/\.run-form-col \[data-run-fields\] \{\s*display: grid/m, css,
      "the grid must be scoped to :not([hidden]) or it defeats showKind()")
    assert_includes css, "[hidden] { display: none !important; }",
      "the global !important rule the panels depend on must stay"
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
end
