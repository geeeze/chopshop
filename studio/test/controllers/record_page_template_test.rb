require "test_helper"

# ONE record-page template for jobs, projects and candidates -- facelift 2/4
# (issue #94).
#
# What this file pins, and why it is a DOM walk rather than a source read:
#
#   Every claim in the issue is about what the OPERATOR SEES on a record page --
#   a breadcrumb, a gradient heading, a badge/meta row, an alias line, and
#   uppercase section headings in one order. Those are properties of the RENDERED
#   document, and the three views now also carry their PREVIOUS head behind a
#   switch (story 5), so a source read cannot tell the live head from the kept
#   one. Each record view is therefore rendered OFFLINE -- no route, no session,
#   no HTTP -- with the exact assigns its controller sets, and the DOM is walked
#   (the same seam `PagesController.render(template: "pages/jev")` and
#   `ApplicationController.render(partial: ...)` already use in this suite).
#
#   BOTH branches are asserted. The switch ON is the shipped state; the switch
#   OFF is what "a regression is one deletion to undo" actually means, and a
#   fallback nobody ever renders is a fallback nobody knows is broken.
class RecordPageTemplateTest < ActiveSupport::TestCase
  # filename -> [label, the logical template name `ApplicationController.render`
  # wants]. The `.html.erb` form is a FILE name; the renderer resolves the
  # logical one, which is also what the controllers render.
  RECORD_VIEWS = {
    "jobs/show.html.erb" => ["job", "jobs/show"],
    "projects/show.html.erb" => ["project", "projects/show"],
    "validations/show.html.erb" => ["candidate (proof)", "validations/show"]
  }.freeze

  # --- fixtures ------------------------------------------------------------
  #
  # The smallest records that render each view through every branch it has.

  def project
    @project ||= Project.create!(name: "record-template-probe", is_test: false)
  end

  def job
    @job ||= begin
      j = Job.create!(name: "record-template-job", state: "done", source_kind: "svg",
                      input_path: "/data/record-template.svg", stem: "record-template-job",
                      spec: {}, runner: "mock", project_id: project.id)
      j.update!(comparison: {
        "candidates" => [{ "file" => "candidate_01.svg", "hard" => 0, "advisory" => 0,
                           "swept" => { "preset" => "bw" },
                           "layer_a" => { "status" => "pass" },
                           "layer_b" => { "status" => "pass" } }]
      })
      j
    end
  end

  def validation
    @validation ||= job.validations.create!(
      file: "candidate_01.svg", state: "done",
      manifest: { "proof" => "proof_01.png", "print_pdf" => "proof_01.pdf",
                  "summary" => { "hard" => 0, "advisory" => 1 },
                  "stats" => { "dpi" => 300, "rendered_ink_colors" => 3,
                               "static" => { "path_nodes_total" => 812 } },
                  # A training set, so the page's THIRD section renders too.
                  "dataset" => { "dir" => "candidate_01.dataset",
                                 "manifest" => "candidate_01.dataset.json",
                                 "sheet" => "candidate_01.dataset-contact-sheet.png",
                                 "count" => 6, "transforms" => %w[flip-h flip-v],
                                 "package" => "candidate_01.dataset.7z" },
                  "findings" => [] }
    )
  end

  # The assigns each controller sets, and nothing invented: jobs#show sets @job,
  # @candidates and @validations; projects#show sets @project, @jobs,
  # @composites, @outputs and @sources; validations#show sets @validation and
  # @job.
  def render_record(view)
    template = RECORD_VIEWS.fetch(view).last
    case template
    when "jobs/show"
      ApplicationController.render(template: template, assigns: {
        job: job, candidates: job.candidates, validations: job.validations
      })
    when "projects/show"
      # The run list's filter assigns (#10) are the controller's too: the select
      # renders `@state_counts` and the census reads `@jobs_total`/`@jobs_count`,
      # so a render without them would be a page the app cannot produce.
      ApplicationController.render(template: template, assigns: {
        project: project, jobs: project.jobs, composites: project.composites,
        outputs: project.outputs, sources: project.sources,
        state: nil, state_counts: project.jobs.group(:state).count,
        jobs_total: project.jobs.count, jobs_count: project.jobs.count
      })
    when "validations/show"
      ApplicationController.render(template: template, assigns: { validation: validation, job: job })
    else
      raise ArgumentError, "no assigns known for #{view}"
    end
  end

  def doc_for(view)
    Nokogiri::HTML(render_record(view))
  end

  # Flip the ONE switch for the duration of a block. The views read the constant
  # at render time, so this is the whole revert: no markup moves.
  def with_record_template_v2(value)
    previous = Object.const_get(:RECORD_TEMPLATE_V2)
    Object.send(:remove_const, :RECORD_TEMPLATE_V2)
    Object.const_set(:RECORD_TEMPLATE_V2, value)
    yield
  ensure
    Object.send(:remove_const, :RECORD_TEMPLATE_V2)
    Object.const_set(:RECORD_TEMPLATE_V2, previous)
  end

  def css_without_comments
    @css_without_comments ||=
      Rails.root.join("app/assets/stylesheets/application.css").read
           .gsub(%r{/\*.*?\*/}m, "")
  end

  # --- the switch itself ---------------------------------------------------

  test "there is ONE switch, and it is on" do
    assert defined?(RECORD_TEMPLATE_V2),
      "the record template needs its single switch (config/initializers/record_template.rb)"
    assert_equal true, RECORD_TEMPLATE_V2,
      "the skeleton is the shipped layout; the previous head is the fallback"
  end

  test "each record view reads that switch, and none of them re-decides the order" do
    RECORD_VIEWS.each do |view, (label, _template)|
      src = Rails.root.join("app/views", view).read
      assert_includes src, "RECORD_TEMPLATE_V2",
        "#{label}: the view must render the skeleton behind the shared switch"
      assert_includes src, 'render "application/record_header"',
        "#{label}: the head must come from the ONE shared partial"
    end
  end

  # --- the page-head handover ----------------------------------------------

  test "the mechanism-A blurb is DEAD when on and ALIVE when off" do
    # page_head_uniformity_test is a SOURCE read: it sees the kept fallback and
    # cannot tell rendered markup from dead markup (review finding, #94). The
    # rendered contract for the handover lives HERE instead.
    %w[projects/show.html.erb validations/show.html.erb].each do |view|
      label = RECORD_VIEWS.fetch(view).first

      doc = doc_for(view)
      refute_nil doc.at_css("header.record-head .record-alias"),
        "#{label}: the sub-title renders as the skeleton's alias line"
      assert_nil doc.at_css(".page-head .page-head-blurb"),
        "#{label}: no mechanism-A blurb renders anywhere on the shipped page"

      with_record_template_v2(false) do
        old = doc_for(view)
        refute_nil old.at_css(".page-head-row .page-head-blurb"),
          "#{label}: with the switch off, the old blurb renders back inside the row"
      end
    end
  end

  test "the alias line renders BEFORE the controls, so it stays above them" do
    # responsive_head_test's invariant: the sub-title must not drop below the
    # action row on a narrow screen. On record pages the sub-title is
    # .record-alias and document order is what the media queries inherit.
    RECORD_VIEWS.each do |view, (label, _template)|
      html = render_record(view)
      alias_pos = html.index("record-alias")
      head_pos = html.index('class="page-head')
      refute_nil alias_pos, "#{label}: the alias line renders"
      refute_nil head_pos, "#{label}: the controls band renders"
      assert_operator alias_pos, :<, head_pos,
        "#{label}: .record-alias renders before .page-head, so it stays above the controls"
    end
  end

  # --- the skeleton, on every record view ---------------------------------

  test "every record page starts with breadcrumb -> heading -> badge/meta row -> alias" do
    RECORD_VIEWS.each do |view, (label, _template)|
      doc = doc_for(view)
      head = doc.at_css("header.record-head")
      refute_nil head, "#{label}: no record skeleton rendered"

      crumb = head.at_css(".crumb")
      refute_nil crumb, "#{label}: the skeleton starts with a breadcrumb"
      assert crumb.css("a").any?, "#{label}: the crumb must link back up the trail"
      refute_nil crumb.at_css(".id"),
        "#{label}: the crumb's terminal node is the record's own id, in mono"

      h1 = head.at_css("h1")
      refute_nil h1, "#{label}: the skeleton owns the heading"
      assert_includes h1["class"].split, "record-title"
      refute_nil h1.at_css(".gradient-text"),
        "#{label}: the heading is the gradient word on every record page"

      meta = head.at_css(".record-meta")
      refute_nil meta, "#{label}: the badge/meta row follows the heading"
      assert meta.css(".badge").any?,
        "#{label}: the meta row leads with the record's state badge (phase-1 vocabulary)"
      refute_nil meta.at_css(".id"),
        "#{label}: the machine values sit beside the badge, in mono"

      assert head.at_css(".record-alias"),
        "#{label}: the alias/muted line closes the skeleton"

      # The ORDER is the skeleton's, not the page's. Nokogiri's document order is
      # the DOM order, so one comparison of each part's position proves it.
      order = [".crumb", "h1", ".record-meta", ".record-alias"].map do |sel|
        head.to_html.index(head.at_css(sel).to_html)
      end
      assert_equal order.sort, order,
        "#{label}: the skeleton's order is crumb -> heading -> meta -> alias"
    end
  end

  test "the meta row's machine values are mono and tertiary, never prose" do
    rule = css_without_comments[/\.crumb \.id,\s*\.record-meta \.id,\s*\.record-alias \.id \{[^}]*\}/m]
    refute_nil rule, "the mono/tertiary value rule must exist"
    assert_includes rule, "font-family: var(--font-mono)"
    assert_includes rule, "color: var(--text-tertiary)",
      "a machine value is tertiary; the badge above it carries the meaning's colour"

    # And the badges really are the phase-1 semantic classes, not a page-local pill.
    assert_equal "done", doc_for("jobs/show.html.erb").at_css(".record-meta .badge")["class"].split.last
    assert_equal "done", doc_for("projects/show.html.erb").at_css(".record-meta .badge")["class"].split.last
    assert_equal "done", doc_for("validations/show.html.erb").at_css(".record-meta .badge")["class"].split.last
  end

  test "a record with nothing to say in a part still renders the part, as an em-dash" do
    # The PARTIAL, rendered on its own: a record with no badge, no machine value
    # and no second name must still show all three slots, or the skeleton's
    # rhythm moves the moment a record is thin (the kb's own convention).
    html = ApplicationController.render(
      partial: "application/record_header",
      locals: { crumbs: [], crumb_id: "record 7", title: "Thin record",
                badges: nil, meta: nil, alias_line: nil }
    )
    doc = Nokogiri::HTML(html)
    assert_equal "—", doc.at_css(".record-meta .id").text.strip,
      "an absent machine value renders the dash, in the mono slot"
    assert_equal "—", doc.at_css(".record-alias").text.strip,
      "an absent alias line renders the dash"
    refute_nil doc.at_css(".record-meta .chip.miss"),
      "an absent badge is the studio's `absent, and that is intentional` chip (#93)"
    assert_equal "record 7", doc.at_css(".crumb .id").text.strip,
      "with no trail above it the crumb is still the record's own id"
  end

  # --- the section heading -------------------------------------------------

  test "one helper renders every section heading, styled identically" do
    # The helper is the ONLY way a record page writes one: none of the three
    # views carries the page-local heading styles this replaced.
    RECORD_VIEWS.each do |view, (label, _template)|
      src = Rails.root.join("app/views", view).read
      refute_includes src, "results-side-head", "#{label}: the page-local heading style is gone"
      refute_includes src, "composites-heading", "#{label}: the page-local heading style is gone"
      assert_includes src, "record_section(", "#{label}: sections render through the helper"
    end

    rule = css_without_comments[/\nh3\.record-section \{[^}]*\}/m]
    refute_nil rule, "h3.record-section must exist: it is what makes the sections identical"
    assert_includes rule, "text-transform: uppercase",
      "the micro-heading is uppercase, like the kb's"
    assert_includes rule, "letter-spacing: 1.5px"
    assert_includes rule, "color: var(--text-tertiary)"
  end

  test "the section rule beats .card h3 on source order, because it TIES on specificity" do
    # `.card h3` is (0,1,1) and so is `h3.record-section`; a tie goes to the later
    # rule. A bare `.record-section` at (0,1,0) would LOSE, and the proof page's
    # "Proof render" / "Findings" / "Training set" would keep the card's 1.25rem
    # title size while the job page's sections rendered as micro-headings -- the
    # exact drift this phase exists to remove.
    card = css_without_comments.index(".card h3 {")
    section = css_without_comments.index("h3.record-section {")
    refute_nil card
    refute_nil section
    assert_operator section, :>, card,
      "h3.record-section must be declared after .card h3, or the tie loses"
    assert_match(/h3\.record-section/, css_without_comments,
      "the TAG is part of the selector: a bare class cannot tie with .card h3")
  end

  test "the record sections render on each page, in the page's own order" do
    job_doc = doc_for("jobs/show.html.erb")
    labels = job_doc.css("h3.record-section").map { |h| h.text.strip }
    # #46 put the stepper's own section FIRST: where the job is in the pipeline
    # leads the page, because it is what an operator opens the page to find.
    assert_equal ["Where this job is", "Candidates", "Proofs", "Sources:"], labels,
      "the job's sections, in the order the page reads them"

    assert_equal ["Composites"], doc_for("projects/show.html.erb").css("h3.record-section").map { |h| h.text.strip }

    assert_equal ["Proof render", "Findings", "Training set"],
                 doc_for("validations/show.html.erb").css("h3.record-section").map { |h| h.text.strip },
      "the proof's sections, in the order the page reads them"
  end

  test "the skeleton introduces no colour literals" do
    # THE SKELETON'S OWN SECTION, delimited by its section comment and the next
    # one -- not "everything from `.record-head` to the end of the sheet". That
    # anchor silently assumed the skeleton was the LAST section in the file; the
    # graph section (#96) already broke that assumption, and the #9 epistemic
    # chips appended after it tripped it, because their rules keep the old
    # literal as the #93 token's fallback (the sheet's standing invariant). A
    # false specification: the skeleton itself did not change.
    block = skeleton_section
    refute_nil block, "the record-skeleton section must be present in the sheet"
    refute_match(/#[0-9a-fA-F]{3,8}\b/, block,
      "every value is a phase-1 token (#93) or a variable the sheet already defines")
    refute_match(/rgba?\(/, block, "no hand-written colour function either")
  end

  # The skeleton's section, comments stripped. Read from the RAW sheet so the
  # section's own comment can delimit it: `css_without_comments` strips every
  # comment, and without them the section has no boundary of its own.
  #
  # Anchored on `"record skeleton\n"` -- the header line, where the phrase is the
  # LAST word -- not on the bare phrase, which also appears in prose elsewhere
  # in the sheet ("the record skeleton's `h3.record-section`") and would start
  # the slice far too early.
  def skeleton_section
    raw = Rails.root.join("app/assets/stylesheets/application.css").read
    start = raw.index("record skeleton\n")
    return nil unless start

    rest = raw[start..]
    stop = rest.index(/\n\/\* =+/)
    (stop ? rest[0...stop] : rest).gsub(%r{/\*.*?\*/}m, "")
  end

  # --- story 5: the previous layout is kept, and is NOT double-rendered -----

  test "exactly one heading renders per record page" do
    RECORD_VIEWS.each do |view, (label, _template)|
      doc = doc_for(view)
      assert_equal 1, doc.css("h1").size,
        "#{label}: two heads in one response is the double-render this switch exists to prevent"
    end
  end

  test "the previous per-page head is not in the shipped response" do
    job_doc = doc_for("jobs/show.html.erb")
    assert_nil job_doc.at_css(".page-head-line"),
      "the job's old title line (with the state riding it as the gradient word) must be off"
    assert_nil job_doc.at_css(".gradient-text.job-state"),
      "the state is a badge now, not the heading's gradient word"

    %w[projects/show.html.erb validations/show.html.erb].each do |view|
      head = doc_for(view).at_css(".page-head")
      refute_nil head, "#{view}: the page's own controls keep their .page-head wrapper"
      assert_nil head.at_css(".page-head-blurb"),
        "#{view}: the blurb is the skeleton's alias line now; rendering both would show it twice"
      assert_nil head.at_css("h1"),
        "#{view}: the heading belongs to the skeleton"
    end
  end

  test "flipping the switch brings the previous per-page head back" do
    with_record_template_v2(false) do
      RECORD_VIEWS.each do |view, (label, _template)|
        doc = doc_for(view)
        assert_nil doc.at_css(".record-head"),
          "#{label}: with the skeleton off, nothing of it may render"
        assert_equal 1, doc.css("h1").size,
          "#{label}: the old head still carries exactly one heading"
      end

      job_doc = doc_for("jobs/show.html.erb")
      refute_nil job_doc.at_css(".page-head-line .section-title"),
        "the job's old title line is back"
      refute_nil job_doc.at_css(".gradient-text.job-state"),
        "and the state rides the title as the gradient word again"

      assert job_doc.at_css(".page-head .page-sub"),
        "the page's own controls were never part of the switch, so they render in both"

      %w[projects/show.html.erb validations/show.html.erb].each do |view|
        head = doc_for(view).at_css(".page-head")
        refute_nil head.at_css(".page-head-row--stacked"),
          "#{view}: the old stacked head row is back"
        refute_nil head.at_css(".page-head-blurb"),
          "#{view}: the old sub-title is back inside the head row"
      end
    end
  end

  test "the record pages' controls keep their measured boxes in both branches" do
    # The skeleton replaced the TITLE and the SUB-TITLE only. The controls and
    # their grid slots are the same markup in both branches, which is why the
    # head-action geometry tests still hold -- assert it here too, so a future
    # edit that "tidies" the actions into the skeleton is caught.
    [true, false].each do |on|
      with_record_template_v2(on) do
        project_head = doc_for("projects/show.html.erb").at_css(".page-head-row--stacked.project-head")
        refute_nil project_head, "switch=#{on}: the project's action grid"
        assert_equal "Run Job", project_head.at_css(".head-action--top").text.strip,
                     "switch=#{on}: Run Job is the top action"
        assert_equal "Compose", project_head.at_css(".head-action--below").text.strip,
                     "switch=#{on}: Compose sits under it"
        assert_equal "Projects", project_head.at_css(".project-back").text.strip,
                     "switch=#{on}: the back button keeps its own grid slot"

        proof_head = doc_for("validations/show.html.erb").at_css(".page-head-row--stacked")
        refute_nil proof_head, "switch=#{on}: the proof's action grid"
        assert proof_head.at_css(".head-action--top"), "switch=#{on}: Ask Jev keeps row 1"
        assert proof_head.at_css(".head-action--below"), "switch=#{on}: the manifest keeps row 2"
      end
    end
  end
end
