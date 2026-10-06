require "test_helper"

# The jobs list has TWO views of the same list: the table (unchanged) and a
# THUMBNAIL grid, switched by a small List/Grid toggle in the page head.
#
# RE-POINTED (2026-10 Projects redesign): GET /jobs was deleted -- jobs now
# live only inside projects, so the same #jobs-list / #jobs-grid pair renders
# on the project workspace (GET /projects/:id, projects/show) and that is the
# page every `index_doc` below reads. Job belongs_to :project is optional, and
# a job with no project is listed NOWHERE, so every job this file seeds is
# owned by the workspace it is read back from (see `workspace`).
#
# What this file pins, and why each one is a contract rather than a style:
#
#   * BOTH views are in the page. The table is inside #jobs-list and the grid
#     inside #jobs-grid[hidden], so the list shows with JS off and the toggle
#     only ever swaps a pair of wrappers -- it does not fetch or re-render.
#   * A grid card is a CARD (.job-card, framed like the About page's blocks)
#     whose thumbnail is a real <a> to the JOB -- the same one destination the
#     table's thumb and name already agree on.
#   * The card is LOW information on purpose: name, status pill, passed count.
#     No runner column and no headers, because that is what the table is for.
#   * The action icons are GATED per state, not rendered and hidden: download
#     only when done, send-to-Run-Job only on a done NON-flux job (flux has no
#     runner source.png to reuse), the scrapbook star only when done and with
#     the route that can actually reach the bytes (the one fav partial for a
#     runner file, scrapbook/save_upload for a generated raster), and cancel
#     INSTEAD of delete while the job is in flight.
#   * The preview icon carries the popup viewer's data-cs-view/data-cs-url/
#     data-cs-title contract (aether.js), which is what opens the existing
#     viewer from this page.
class JobsGridTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  TOP = "candidate_01.svg".freeze
  RASTER = "flux_raster_aa11.png".freeze
  SOURCE = "source.png".freeze

  # Hermetic runner config, exactly as JobsIndexPreviewTest does it: every
  # runner variable is cleared and the non-pipeline kinds are configured, so a
  # deployment's real runners can never make these assertions true for the wrong
  # reason. `mock` is always registered (Job::RUNNER_DEFAULTS).
  def with_runners
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_FLUX_URL"] = "http://generator.invalid:8795"
      ENV["CHOPSHOP_RUNNER_FLUX_KIND"] = "flux"
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def candidates(*files)
    files.map do |file|
      { "file" => file, "sweep" => { "preset" => "bw" },
        "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" },
        "hard" => 0, "advisory" => 0, "fidelity" => {}, "passed" => true }
    end
  end

  # The workspace these tests read the jobs list back from. One project per
  # test (each test gets a fresh instance), created before login exactly as
  # test/controllers/projects_page_test.rb does: the owner defaults to the
  # signed-in test user, so ProjectsController#show finds it.
  def workspace
    @workspace ||= Project.create!(name: "grid-test-workspace", is_test: true)
  end

  # A done pipeline job: its files live on the runner, so its preview is the
  # runner's COLOUR SOURCE (source.png -- the raster the sweep was fed, whether
  # or not the sweep landed) and it goes through the file proxy. A finished
  # proof would replace it; none of these jobs carries one.
  def pipeline_job(name, files: [])
    Job.create!(name: name, state: "done", source_kind: "raster", runner: "mock",
                input_path: "/data/x.png", stem: name, spec: {}, project: workspace,
                comparison: { "candidates" => candidates(*files) })
  end

  # A done flux job that stopped at the raster (raster mode): its output is a
  # LOCAL upload, so it is the one kind whose scrapbook star cannot go through
  # the runner-fetching favourite.
  def flux_job(name)
    spec = { "flux" => { "mode" => "raster", "prompt" => "a lighthouse at dusk",
                         "images" => 1, "rendered" => { "images" => [ { "file" => RASTER } ] } } }
    Job.create!(name: name, state: "done", source_kind: "raster", runner: "flux",
                input_path: "storage/uploads/#{RASTER}", stem: name, spec: spec,
                project: workspace, comparison: { "candidates" => [] })
  end

  # An in-flight job with no runner_job_id, so the workspace's refresh pass does not
  # reach for a runner. Cancel replaces delete on exactly this kind of row.
  def running_job(name)
    Job.create!(name: name, state: "running", source_kind: "raster", runner: "mock",
                input_path: "/data/y.png", stem: name, spec: {}, project: workspace,
                comparison: { "candidates" => [] })
  end

  # RE-POINTED: was `get jobs_path` (the deleted GET /jobs index). The same
  # table + grid pair now renders on the project workspace, so read it there.
  def index_doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get project_path(workspace), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # The card for one job, found by the name it shows -- so no assertion can pass
  # on some other card. Exact, not a substring: a seed pair like "starred" and
  # "raster-starred" would otherwise both match the first one in document order.
  def card_for(doc, job)
    card = doc.css("#jobs-grid .job-card").find do |c|
      link = c.at_css("a.cs-job-name")
      link && link.text.strip == job.name
    end
    refute_nil card, "#{job.name}: no grid card rendered"
    card
  end

  def preview_path(job)
    job.preview_from_upload? ? upload_preview_jobs_path(name: job.preview_file)
                             : file_job_path(job, name: job.preview_file)
  end

  # ---- the two views ----

  test "both views are in the page, and the list is what shows without JS" do
    with_runners do
      job = pipeline_job("both", files: [ TOP ])
      d = index_doc

      list = d.at_css("#jobs-list")
      grid = d.at_css("#jobs-grid")
      refute_nil list, "the existing table needs a wrapper for the toggle to hide"
      refute_nil grid, "and the grid is rendered beside it, not instead of it"

      assert list.at_css("table.candidates"),
        "the table stays exactly where it was, inside #jobs-list"
      assert_equal 1, list.css("table.candidates").size, "one table, not two"

      # Hidden IN THE MARKUP: with JS off this is what keeps the default 'list'
      # true, and [hidden] is the display:none !important guard the toggle flips.
      refute_nil grid["hidden"], "#jobs-grid must ship hidden"
      assert_nil list["hidden"], "and the list must not"

      assert grid.at_css(".job-grid .job-card"),
        "with jobs present the grid carries cards"

      # The same run is in both views -- one row, one card.
      row = list.css("tr").find { |r| r.text.include?(job.name) }
      refute_nil row
      assert_equal 1, grid.css(".job-card").size
    end
  end

  test "the toggle control exists and names its two states" do
    pipeline_job("toggled", files: [ TOP ])
    d = index_doc

    head = d.at_css(".page-head")
    refute_nil head, "the toggle belongs in the page head, beside Run Job"
    toggle = head.at_css(".view-toggle")
    refute_nil toggle, "the head carries the toggle"

    views = toggle.css("button[data-view-toggle]").map { |b| b["data-view-toggle"] }
    assert_equal %w[list grid], views,
      "two states, list first: 'list' is the default the markup renders"

    # Plain buttons in a group -- a display mode must not navigate or reload.
    toggle.css("[data-view-toggle]").each do |btn|
      assert_equal "button", btn.name, "a link would navigate instead of switching"
      assert_includes btn["class"].split, "btn"
      assert_includes btn["class"].split, "btn-secondary"
      refute_includes btn["class"].split, "head-action",
        "it is a small display switch, not another 2.75rem head action"
      assert_includes %w[true false], btn["aria-pressed"],
        "the pressed state has to be speakable, not only coloured"
    end

    # The grid is the off state, so 'list' is the one that reads as pressed.
    list = toggle.at_css("button[data-view-toggle='list']")
    assert_equal "true", list["aria-pressed"]
  end

  test "the toggle script keeps its own contract: one key, two values, body class" do
    # The script cannot be executed here, so what it AGREES with the markup and
    # the CSS on is pinned: the two ids, the body class, the storage key and its
    # two values, and the fact that it never writes markup back into the page.
    #
    # RE-POINTED: the script used to be read out of app/views/jobs/index.html.erb,
    # which the Projects redesign DELETED along with GET /jobs. The jobs list's
    # copy of the script now ships with the project workspace view; the
    # projects index carries its own twin (ids #projects-list/#projects-grid),
    # so this still pins the JOBS one, on the page where the jobs list lives.
    view = File.read(Rails.root.join("app/views/projects/show.html.erb"))
    assert_includes view, "getElementById('jobs-list')"
    assert_includes view, "getElementById('jobs-grid')"
    assert_includes view, "'chopshop.jobsView'"
    assert_match(/=== 'grid' \? 'grid' : 'list'/, view,
      "anything that is not 'grid' is 'list': the default must survive a junk value")
    assert_includes view, "classList.toggle('jobs-view-grid', grid)"
    assert_includes view, ".hidden = grid"
    assert_includes view, ".hidden = !grid",
      "the two wrappers are always swapped together"

    # localStorage throws in a private-mode browser; both sides are guarded so
    # the page still switches, it just forgets.
    assert_equal 2, view.scan(/localStorage\.(getItem|setItem)/).size
    assert_equal 2, view.scan(/try \{/).size, "both localStorage calls are guarded"
  end

  test "the grid CSS is the card frame, a square thumb and the checkerboard" do
    css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))

    grid = css[/\.job-grid \{[^}]*\}/m]
    refute_nil grid
    assert_match(/display: grid/, grid)
    assert_match(/grid-template-columns: repeat\(auto-fill, minmax\(\d+px, 1fr\)\)/, grid,
      "auto-fill with a column floor: cards stay a readable size instead of stretching")

    card = css[/\.job-card \{[^}]*\}/m]
    refute_nil card
    assert_match(/background: var\(--panel-bg\)/, card, "the .card fill")
    assert_match(/border: 1px solid var\(--border\)/, card, "the .card border")
    assert_match(/border-radius: var\(--radius-xl\)/, card, "the .card radius")
    assert_match(/backdrop-filter: blur/, card, "and the .card frost")
    assert_match(/\.job-card:hover \{ border-color: rgba\(99, 102, 241, 0\.3\); \}/, css,
      "the .card hover, so the frame behaves like the About page's blocks")

    thumb = css[/\.job-card-thumb \{[^}]*\}/m]
    refute_nil thumb
    assert_match(/aspect-ratio: 1 \/ 1/, thumb, "the large square thumbnail")
    img = css[/\.job-card-thumb img \{[^}]*\}/m]
    refute_nil img
    assert_match(/object-fit: contain/, img)
    assert_match(/repeating-conic-gradient/, img,
      "the same checkerboard the table's .thumb img paints")
    assert_match(/content: '✂'/, css, "the matte-grey scissors placeholder")
    assert_match(/color: var\(--thumb-placeholder\)/, css)

    assert_match(/\.job-card-actions \.btn-icon \{[^}]*flex: 0 0 auto;[^}]*\}/, css,
      "the icon boxes must not shrink, per .cs-row-actions")
    assert_match(/\.view-toggle \.view-toggle-btn\.is-active/, css,
      "the selected mode is the one the script marks")
    assert_match(/\.view-toggle \{ display: inline-flex; gap: 0; \}/, css,
      "the grouped mode buttons are a segmented control: they touch, no margin between them")

    # The class the script puts on <body> has to be USED, not merely set: two up
    # on a phone is what it buys.
    assert_match(/body\.jobs-view-grid \.job-grid \{ grid-template-columns: repeat/, css,
      "body.jobs-view-grid must be consumed by a rule, or it is an inert class")
    # And the hiding is still the attribute's job, not a second mechanism.
    assert_match(/^\[hidden\] \{ display: none !important; \}$/, css,
      "the toggle relies on the existing [hidden] guard; the grid must not " \
      "invent a second way to hide itself")
    refute_match(/\.job-grid\[hidden\]|#jobs-grid\[hidden\]/, css,
      "and must not fight it either")
  end

  # ---- the card ----

  test "a card is a frame with a thumbnail link to the job, the name and the pill" do
    with_runners do
      job = pipeline_job("framed", files: [ TOP ])
      d = index_doc
      card = card_for(d, job)

      assert_includes card["class"].split, "job-card", "the card frame"

      thumb = card.at_css("a.job-card-thumb")
      refute_nil thumb, "the thumbnail must be a real <a>, not just a JS target"
      assert_equal job_path(job), thumb["href"], "one destination: the job"
      assert_includes thumb["title"].to_s, job.name

      img = thumb.at_css("img")
      refute_nil img
      assert_equal file_job_path(job, name: SOURCE), img["src"],
        "the same Job#preview_file decision the table's cell makes: the colour " \
        "source is a runner file, so it goes through the file proxy -- never " \
        "upload_preview, whose route only 404s on a runner filename"
      assert_equal preview_path(job), img["src"]
      assert_includes img["alt"].to_s, job.name

      name = card.at_css("a.cs-job-name")
      refute_nil name
      assert_equal job_path(job), name["href"]
      assert_includes name.text, job.name

      pill = card.at_css(".status-pill")
      refute_nil pill
      assert_includes pill["class"].split, "status-#{job.state}"
      assert_equal job.state, pill.text.strip

      passed = card.at_css(".job-card-passed")
      refute_nil passed
      assert_equal job.passed_count.to_s, passed.text.strip
      assert_includes passed["class"].split, "mono", "the table's passed count is mono"
      assert_equal 1, job.passed_count, "the seed has one passed candidate"
    end
  end

  test "a generated raster's card previews through uploads, not the file proxy" do
    # The one combination where the model's two decisions disagree: a flux job's
    # output is a local upload, so the grid has to read preview_from_upload?
    # exactly as the table does (see JobsIndexPreviewTest).
    with_runners do
      job = flux_job("raster-card")
      d = index_doc
      card = card_for(d, job)

      img = card.at_css("a.job-card-thumb img")
      refute_nil img
      assert_equal upload_preview_jobs_path(name: RASTER), img["src"]
      refute_equal file_job_path(job, name: RASTER), img["src"],
        "a generated raster has no runner file behind it"

      eye = card.at_css("[data-cs-view]")
      assert_equal upload_preview_jobs_path(name: RASTER), eye["data-cs-url"]
    end
  end

  test "a card is LOW information: no runner column, no headers, no table" do
    with_runners do
      job = pipeline_job("lean", files: [ TOP ])
      d = index_doc
      card = card_for(d, job)

      assert_empty card.css("table"), "the grid is not a table"
      assert_empty card.css("th, thead"), "and it carries no headers"
      refute_includes card.text, job.runner,
        "the runner label belongs to the table; the card is the low-info view"
    end
  end

  test "a card with nothing to preview yet shows the scissors, never a broken image" do
    with_runners do
      # A queued raster-only flux job: no variations rendered, so preview_file
      # is nil. The card must still exist, with a placeholder thumb.
      job = Job.create!(name: "nothing-yet", state: "queued", source_kind: "raster",
                        runner: "flux", input_path: "", stem: "nothing-yet",
                        project: workspace,
                        spec: { "flux" => { "mode" => "raster", "prompt" => "x" } })
      assert_nil job.preview_file
      d = index_doc
      card = card_for(d, job)

      thumb = card.at_css("a.job-card-thumb")
      refute_nil thumb
      assert thumb.key?("data-missing"),
        "the placeholder is the missing marker the CSS draws the scissors for"
      assert_nil thumb.at_css("img"), "no img means no broken-image icon"

      # The preview control stays (every card is the same shape) but is not
      # wired to a URL that cannot resolve.
      eye = card.at_css("button.cs-job-preview")
      refute_nil eye
      assert_nil eye["data-cs-view"], "nothing to open, so no viewer wiring"
      assert eye.key?("disabled")
    end
  end

  # ---- the action icons ----

  test "the preview icon carries the popup viewer contract" do
    with_runners do
      job = pipeline_job("peek", files: [ TOP ])
      d = index_doc
      eye = card_for(d, job).at_css("[data-cs-view]")

      refute_nil eye, "the eye is the only way into the popup from this page"
      assert_equal "svg", eye["data-cs-view"]
      assert_equal preview_path(job), eye["data-cs-url"]
      assert_equal job.name, eye["data-cs-title"]
      assert_includes eye["class"].split, "btn-icon"
    end
  end

  test "download is gated to a done job" do
    with_runners do
      done = pipeline_job("dl-done", files: [ TOP ])
      running = running_job("dl-running")
      d = index_doc

      link = card_for(d, done).at_css("a.cs-job-download")
      refute_nil link, "a finished run has an archive to fetch"
      assert_equal download_job_path(done), link["href"]
      assert_includes link["aria-label"].to_s, done.name

      assert_nil card_for(d, running).at_css("a.cs-job-download"),
        "the runner's download route refuses an unfinished job, so the control is absent"
    end
  end

  test "send to Run Job is on a done non-flux job only, and posts the source back" do
    with_runners do
      pipeline = pipeline_job("reusable", files: [ TOP ])
      flux = flux_job("generated")
      running = running_job("still-going")
      d = index_doc

      # A pipeline job: the raster it was traced from can be run again, and the
      # POST is what does it (reuse fetches from the runner and files a new job).
      form = card_for(d, pipeline).at_css(".job-card-actions form")
      refute_nil form, "the hand-off is a real form: reuse is a POST, not a link"
      assert_equal reuse_job_path(pipeline, name: SOURCE), form["action"]
      assert_equal "post", form["method"]
      btn = form.at_css("button")
      refute_nil btn
      assert_equal "Send to Run Job", btn["title"]
      assert_includes btn["aria-label"].to_s, pipeline.name

      # A flux job has no runner source.png: the raster was generated, and reuse
      # only accepts a runner's source.png / source.inverse.png.
      assert flux.flux?
      assert_nil card_for(d, flux).at_css("form[action*='reuse']"),
        "flux jobs have no source.png to hand back"
      refute_includes card_for(d, flux).to_html, "Send to Run Job"
      assert_nil card_for(d, running).at_css("form[action*='reuse']"),
        "and an unfinished job has not produced a source to send"
    end
  end

  test "the scrapbook star is gated to a done job and uses the route that can reach the bytes" do
    with_runners do
      pipeline = pipeline_job("starred", files: [ TOP ])
      flux = flux_job("raster-starred")
      running = running_job("unstarred")
      d = index_doc

      # A runner file: the ONE fav partial, which fetches through the runner.
      fav = card_for(d, pipeline).at_css("button[data-scrap-favourite]")
      refute_nil fav, "a runner-backed preview is saved by the shared favourite partial"
      assert_equal pipeline.id.to_s, fav["data-scrap-job"]
      assert_equal SOURCE, fav["data-scrap-name"],
        "the star favourites the file the card PREVIEWS -- the colour source"
      assert_includes fav["title"], "preview"
      assert_equal 1, card_for(d, pipeline).css("button[data-scrap-favourite]").size,
        "one star, not a second implementation beside it"

      # A generated raster: the partial's handler would fetch a runner file that
      # does not exist, so this one posts to save_upload instead.
      flux_card = card_for(d, flux)
      assert_empty flux_card.css("button[data-scrap-favourite]"),
        "a local upload cannot be saved through the runner-fetching favourite"
      save = flux_card.at_css("form[action='#{scrapbook_save_upload_path}']")
      refute_nil save, "the generated raster has its own route"
      assert_equal RASTER, save.at_css("input[name='name']")["value"]
      assert_equal flux.id.to_s, save.at_css("input[name='job_id']")["value"]
      assert_equal 1, save.css("svg").size, "still a star, and inline SVG -- no text glyph"

      assert_nil card_for(d, running).at_css("button[data-scrap-favourite]")
      assert_nil card_for(d, running).at_css("form[action='#{scrapbook_save_upload_path}']"),
        "an unfinished job has nothing to keep yet"
    end
  end

  test "cancel replaces delete while a job is in flight, and delete replaces cancel once it is done" do
    with_runners do
      running = running_job("cancellable")
      done = pipeline_job("deletable", files: [ TOP ])
      d = index_doc

      cancel = card_for(d, running).at_css("button[data-cs-job-action='cancel']")
      refute_nil cancel
      assert_equal cancel_job_path(running), cancel["data-url"]
      assert_equal running.name, cancel["data-name"]
      assert_includes cancel["aria-label"].to_s, running.name
      assert_nil card_for(d, running).at_css("button[data-cs-job-action='delete']"),
        "a running job is stopped, never deleted"

      delete = card_for(d, done).at_css("button[data-cs-job-action='delete']")
      refute_nil delete
      assert_equal job_path(done), delete["data-url"]
      assert_equal done.name, delete["data-name"]
      assert_includes delete["aria-label"].to_s, done.name
      assert_nil card_for(d, done).at_css("button[data-cs-job-action='cancel']"),
        "and a finished job has nothing left to stop"
    end
  end

  test "the two views cover the same runs, one row and one card each" do
    with_runners do
      pipeline_job("one", files: [ TOP ])
      flux_job("two")
      running_job("three")
      d = index_doc

      names = d.css("#jobs-grid .job-card a.cs-job-name").map { |a| a.text.strip }.sort
      assert_equal %w[one three two], names
      assert_equal names.size, d.css("#jobs-list tbody tr").size,
        "a run that has a row must have a card: neither view may hide one"
    end
  end
end
