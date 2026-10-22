require "test_helper"

# GET /audit -- the studio's data debt, counted (#95, facelift 3/4).
#
# The contracts pinned here:
#
#   * the GATE -- an anonymous caller is bounced to /login, and the controller
#     declares the gate at the source level (so a route cannot be shadowed);
#   * the SHAPE -- the JSON document's keys are the documented ones, so the
#     "diff over time" promise holds: a consumer written against this shape
#     keeps reading it;
#   * the COUNTS -- asserted against SEEDED rows, never against a hardcoded
#     total (totals drift as the studio's data does). Each count is the number
#     of rows the seed produced for that check, read back from the endpoint;
#   * the INVARIANT -- a group's `unresolved_ids` can never outnumber the sum
#     of its gap counts (it is the UNION of the checks behind them), and every
#     count is the exact relation the check defines;
#   * the FILTER -- `?gap=` and `?project=` render the id list a count links to.
#
# The fixtures are built so that each of the issue's four named debts is
# present: a job that left nothing behind, a candidate with no proof, a project
# with no runs, and an errored validation -- plus a state with zero members, an
# orphaned row, and a per-project attribution.
class AuditTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def sign_in
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def audit_json
    get "/audit.json", headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_equal "application/json", response.media_type
    JSON.parse(response.body)
  end

  def group(body, key)
    body["groups"].find { |g| g["key"] == key }
  end

  # The fixture: three projects, four jobs, four candidates, four validations
  # and three composites, arranged so EVERY check in AuditGaps::GAPS has a known
  # number of rows. Nothing here is a total -- each assertion below names the
  # rows it expects.
  #
  # Orphans are seeded only where the schema allows one: `jobs.project_id` and
  # `jobs.source_id` have no foreign key, while `composites.project_id` does
  # (so a project-less composite is reachable and an orphan composite is not).
  def seed_debt
    debt = Project.create!(name: "debt-#{rand(1_000_000)}", is_test: false)
    clean = Project.create!(name: "clean-#{rand(1_000_000)}", is_test: false)
    empty = Project.create!(name: "empty-#{rand(1_000_000)}", is_test: false)

    source = Source.create!(name: "clean-source-#{rand(1_000_000)}",
                            source_type: "raster", project_id: clean.id)

    # A CLEAN job: settled, with the stem and the finish stamp, in a project,
    # from a source. Its candidate has a preset, both layer gates and a proof
    # that finished with a manifest. Every check must leave it alone.
    clean_job = Job.create!(name: "clean", state: "done", source_kind: "svg",
                            input_path: "/data/clean.svg", stem: "clean",
                            runner: "mock", runner_stem: "clean",
                            finished_at: Time.current, project_id: clean.id,
                            source_id: source.id)
    clean_cand = clean_job.candidates.create!(file: "candidate_02.svg",
                                              preset: "poster",
                                              layer_a: "done", layer_b: "done")
    clean_job.validations.create!(file: "candidate_02.svg", state: "done",
                                  candidate_id: clean_cand.id,
                                  manifest: { "gates" => [] })

    # The JOB that left nothing behind: settled with no runner stem, no finish
    # stamp, no source. Its two candidates were never proved, and one has no
    # preset while the other never recorded its layer-A gate.
    thin_job = Job.create!(name: "thin", state: "done", source_kind: "svg",
                           input_path: "/data/thin.svg", stem: "thin",
                           runner: "mock", runner_stem: nil, finished_at: nil,
                           project_id: debt.id, source_id: nil)
    thin_job.candidates.create!(file: "candidate_01.svg", preset: nil,
                                layer_a: "done", layer_b: "done")
    thin_job.candidates.create!(file: "candidate_04.svg", preset: "bw",
                                layer_a: nil, layer_b: "done")

    # The ERRORED job: terminal with no message, and its proof errored without
    # ever naming the candidate it was for.
    error_job = Job.create!(name: "errored", state: "error", source_kind: "svg",
                            input_path: "/data/errored.svg", stem: "errored",
                            runner: "mock", runner_stem: "errored",
                            finished_at: Time.current, error: nil,
                            project_id: debt.id, source_id: nil)
    error_job.validations.create!(file: "candidate_03.svg", state: "error",
                                  candidate_id: nil)

    # The ORPHANED job: it names a project and a source that do not exist. Both
    # columns are FK-less, which is exactly where an orphan survives.
    orphan_job = Job.create!(name: "orphaned", state: "done", source_kind: "svg",
                             input_path: "/data/orphaned.svg", stem: "orphaned",
                             runner: "mock", runner_stem: "orphaned",
                             finished_at: Time.current,
                             project_id: 9_999_999, source_id: 9_999_999)

    # A validation whose job is gone (FK-less column) and one whose candidate is
    # gone, plus a proof that was created and never dispatched to a runner.
    Validation.new(file: "candidate_98.svg", job_id: 9_999_999, state: "done")
              .save(validate: false)
    thin_job.validations.create!(file: "candidate_05.svg", state: "pending",
                                 candidate_id: 9_999_999)
    Candidate.new(job_id: 9_999_999, file: "orphan_candidate.svg")
            .save(validate: false)

    Composite.create!(name: "debt-comp-#{rand(1_000_000)}", width: 100, height: 100,
                      project_id: debt.id,
                      layers: [{ "key" => "a", "name" => "a", "x" => 0, "y" => 0,
                                 "w" => 10, "h" => 10 }])
    Composite.create!(name: "noproject-comp-#{rand(1_000_000)}", width: 100, height: 100,
                      project_id: nil,
                      layers: [{ "key" => "a", "name" => "a", "x" => 0, "y" => 0,
                                 "w" => 10, "h" => 10 }])
    Composite.create!(name: "empty-comp-#{rand(1_000_000)}", width: 100, height: 100,
                      project_id: debt.id, layers: [])

    { debt: debt, clean: clean, empty: empty, thin_job: thin_job,
      error_job: error_job, clean_job: clean_job, orphan_job: orphan_job }
  end

  # -- the gate ------------------------------------------------------------

  test "an anonymous caller is bounced to login on both shapes" do
    get "/audit", headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path

    get "/audit.json", headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path
  end

  test "the controller declares the login gate at the source level" do
    src = Rails.root.join("app/controllers/audit_controller.rb").read
    assert_match(/before_action :require_login/, src)
  end

  # -- the route -----------------------------------------------------------

  test "GET /audit is one route serving HTML and JSON" do
    route = Rails.application.routes.routes.find do |r|
      r.defaults[:controller] == "audit" && r.defaults[:action] == "show"
    end
    refute_nil route, "GET /audit must be routed"
    assert_equal "GET", route.verb
    assert_equal "/audit(.:format)", route.path.spec.to_s
    assert_nil route.defaults[:format],
               "HTML is the default shape, so the format is not baked into the route"

    sign_in
    get "/audit", headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_includes response.media_type, "text/html"
    assert_equal "/audit", audit_path
  end

  # -- the shape -----------------------------------------------------------

  test "the JSON document carries the documented keys" do
    sign_in
    body = audit_json

    assert_equal %w[by_project generated_at groups needs_attention owner total].sort,
                 body.keys.sort
    assert_equal "test", body["owner"], "the payload says which owner it is scoped to"
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, body["generated_at"])

    assert_equal AuditGaps::GROUPS.keys.map(&:to_s).sort,
                 body["groups"].map { |g| g["key"] }.sort,
                 "one group per audited class, no more and no fewer"

    body["groups"].each do |g|
      expected = %w[gaps key label model n unresolved_ids]
      expected += %w[empty_state_names states] if g["states"]
      assert_equal expected.sort, g.keys.sort,
                   "#{g['key']}: the group's keys are the documented ones"
      assert_operator g["n"], :>=, 0
      assert_operator g["unresolved_ids"].size, :<=, g["gaps"].values.sum,
                      "#{g['key']}: unresolved_ids is the UNION of the checks, so it " \
                      "can never outnumber their sum"
    end

    # `total` is every row looked at; `needs_attention` is every row found
    # unresolved. Both are derived from the groups, never stated twice.
    assert_equal body["groups"].sum { |g| g["n"] }, body["total"]
    assert_equal body["groups"].sum { |g| g["unresolved_ids"].size },
                 body["needs_attention"]

    assert body["by_project"].is_a?(Array)
    body["by_project"].each do |p|
      assert_equal %w[candidates composites gaps id jobs name projects unresolved
                       unresolved_ids validations].sort,
                   p.keys.sort
    end
  end

  # -- the counts, against seeded rows -------------------------------------

  test "a seeded fixture's gaps are counted, not assumed" do
    seed = seed_debt
    sign_in
    body = audit_json

    jobs = group(body, "jobs")
    assert_equal Job.count, jobs["n"]
    # thin: no runner stem, no finish stamp, no source. errored: no source and
    # no message. orphaned: a project and a source that do not exist.
    assert_equal 1, jobs["gaps"]["missing_runner_stem"], "only thin settled with no stem"
    assert_equal 1, jobs["gaps"]["missing_finished_at"], "only thin settled with no stamp"
    assert_equal 2, jobs["gaps"]["missing_source"], "thin and errored have no source"
    assert_equal 1, jobs["gaps"]["error_without_message"], "the errored job says nothing"
    assert_equal 0, jobs["gaps"]["missing_project"], "every seeded job names a project"
    assert_equal 1, jobs["gaps"]["orphan_project"], "the orphaned job names a project that is gone"
    assert_equal 1, jobs["gaps"]["orphan_source"], "and a source that is gone"
    assert_equal 0, jobs["gaps"]["stranded_running"], "no job is stuck running"

    cands = group(body, "candidates")
    assert_equal Candidate.where(job_id: Job.select(:id)).count, cands["n"]
    assert_equal 1, cands["gaps"]["missing_preset"], "only candidate_01 has no preset"
    assert_equal 1, cands["gaps"]["missing_layer_status"], "only candidate_04 never recorded layer A"
    assert_equal 2, cands["gaps"]["no_proof"], "candidate_01 and candidate_04 were never proved"
    refute_includes cands["gaps"].keys, "orphan_job",
                    "a job-less candidate is UNATTRIBUTABLE (no owner column) and is deliberately not audited -- see AuditGaps"

    vals = group(body, "validations")
    assert_equal 1, vals["gaps"]["errored"], "one errored validation"
    assert_equal 2, vals["gaps"]["missing_candidate"],
                 "the errored proof and the job-less proof never named a candidate"
    assert_equal 1, vals["gaps"]["missing_manifest"], "the job-less proof carries no manifest"
    assert_equal 1, vals["gaps"]["orphan_job"], "one validation outlived its job"
    assert_equal 1, vals["gaps"]["orphan_candidate"], "one outlived its candidate"
    assert_equal 1, vals["gaps"]["pending_without_runner"], "one proof was never dispatched"

    projects = group(body, "projects")
    assert_equal 1, projects["gaps"]["no_runs"], "the empty project never ran"
    assert_equal 2, projects["gaps"]["no_sources"], "debt and empty loaded nothing"
    assert_equal 3, projects["gaps"]["no_outputs"], "nothing has returned to a project yet"

    composites = group(body, "composites")
    assert_equal 1, composites["gaps"]["missing_project"], "one composite has no project"
    # composites.project_id carries a FOREIGN KEY, so an orphan composite cannot
    # exist in a schema-built database. The check stays (the FK is a schema
    # detail, not a guarantee) and the recompute test below pins it at zero.
    assert_equal 0, composites["gaps"]["orphan_project"]
    assert_equal 1, composites["gaps"]["empty_layers"], "one composite has nothing in it"

    # The id list behind a count is the exact rows the check names -- the
    # invariant the kb's broken join could not hold. Both directions, against
    # the SEEDED truth (a one-sided operator could hide an over-count): the
    # union is EXACTLY the three seeded rows, and the sum counts the seven
    # seeded gaps (thin 3 + errored 2 + orphaned 2).
    assert_equal [seed[:thin_job].id, seed[:error_job].id, seed[:orphan_job].id].sort,
                 jobs["unresolved_ids"], "the union counts ROWS"
    assert_equal 7, jobs["gaps"].values.sum, "the sum counts GAPS"
  end

  test "a state with zero members is reported, and named" do
    seed_debt
    sign_in
    jobs = group(audit_json, "jobs")

    assert_equal Job::STATES.sort, jobs["states"].keys.sort,
                 "the whole vocabulary is reported, not only the populated states"
    assert_equal 0, jobs["states"]["pending"]
    assert_equal 0, jobs["states"]["cancelled"]
    assert_equal 3, jobs["states"]["done"], "clean, thin and orphaned"
    assert_equal 1, jobs["states"]["error"]
    assert_equal %w[cancelled pending queued running], jobs["empty_state_names"].sort
    # `empty_state_names` is NOT inside `gaps`: a state with no members has no
    # ROWS, so it cannot back an id list, and every count in `gaps` stays the
    # exact relation behind it.
    refute_includes jobs["gaps"].keys, "empty_states"
  end

  test "the endpoint's counts are wired to the checks' own relations" do
    # A WIRING pin, honestly named: this recomputes through AuditGaps' own
    # lambdas, so it proves the controller reads the checks (and cannot disagree
    # with them) but CANNOT catch a wrong predicate inside one -- a mutated
    # scope passes here. What pins correctness is the seeded-truth test above.
    seed_debt
    sign_in
    body = audit_json

    AuditGaps::GAPS.each do |check|
      rel = check[:rows].call(AuditGaps.base_for(check[:group]))
      assert_equal rel.count, group(body, check[:group].to_s)["gaps"][check[:key]],
                   "#{check[:group]}.#{check[:key]}: the count is the relation's own size"
    end
  end

  test "per-project breakdowns attribute the debt" do
    seed = seed_debt
    sign_in
    body = audit_json

    debt = body["by_project"].find { |p| p["id"] == seed[:debt].id }
    refute_nil debt, "the debt project is in the breakdown"
    assert_equal 2, debt["jobs"], "thin and errored"
    assert_equal 2, debt["candidates"], "both of thin's candidates"
    assert_equal 2, debt["validations"], "the errored proof and the undispatched one"
    assert_equal 2, debt["composites"], "the debt composite and the empty one"
    # thin, errored, candidate_01, candidate_04, the errored proof, the
    # undispatched proof, the empty composite -- and the PROJECT ITSELF, which
    # has no sources and no outputs. Eight rows, not the six the gaps suggest.
    assert_equal 8, debt["unresolved"]
    assert_equal 2, debt["gaps"]["jobs.missing_source"]
    assert_equal 1, debt["gaps"]["jobs.error_without_message"]
    assert_equal 2, debt["gaps"]["candidates.no_proof"]
    assert_equal 1, debt["gaps"]["composites.empty_layers"]

    clean = body["by_project"].find { |p| p["id"] == seed[:clean].id }
    # Its job, candidate and proof are COMPLETE -- the only gap left is that
    # nothing has returned to the project yet, which is true of every project
    # in this fixture and is not this project's fault.
    assert_equal 1, clean["unresolved"]
    assert_equal ["projects.no_outputs"], clean["gaps"].keys,
                 "no missing field, no orphan, no empty state"

    # The project with no runs is itself a gap, and it belongs to the project.
    empty = body["by_project"].find { |p| p["id"] == seed[:empty].id }
    assert_equal 1, empty["unresolved"], "no_runs"
    assert_equal 1, empty["gaps"]["projects.no_runs"]
    assert_equal 1, empty["gaps"]["projects.no_outputs"],
                 "and nothing has returned to it either"

    # Rows that name no project -- or name one that is GONE -- land in a named
    # bucket rather than vanishing under a phantom project id.
    none = body["by_project"].find { |p| p["id"].nil? }
    refute_nil none, "a project-less row is attributable to 'no project', not dropped"
    assert_equal "no project", none["name"]
    assert_equal 1, none["jobs"], "the orphaned job"
    assert_equal 1, none["gaps"]["jobs.orphan_project"],
                 "its project is gone, so it is filed here"
    assert_equal 1, none["gaps"]["jobs.orphan_source"]
    assert_equal 1, none["gaps"]["composites.missing_project"], "the project-less composite"
    # `orphan_job` is a check in TWO classes; each is counted separately rather
    # than one overwriting another. (candidates.orphan_job is deliberately not a
    # check at all -- unattributable rows, see AuditGaps.)
    assert_equal 1, none["gaps"]["validations.orphan_job"], "the job-less proof"
  end

  test "another operator's rows stay invisible" do
    seed_debt
    sign_in
    before = audit_json

    User.create!(handle: "other", password: "other-password")
    Job.new(name: "theirs", state: "done", source_kind: "svg",
            input_path: "/data/theirs.svg", stem: "theirs", spec: {},
            runner: "mock", runner_stem: nil, finished_at: nil,
            project_id: nil, source_id: nil, owner: "other").save!
    ScrapbookItem.create!(name: "theirs.svg", kind: "source",
                          file: "theirs_fav.svg", owner: "other")
    # The sharpest shape of the same rule: an ORPHAN candidate (no owner column
    # at all -- ownership rides on the job it outlived). Before the
    # candidates.orphan_job check was dropped, exactly this row leaked its id
    # into THIS document and inflated needs_attention (measured in review).
    Candidate.new(job_id: 9_999_998, file: "their_orphan.svg").save(validate: false)

    after_ = audit_json

    # The whole document is unchanged: another operator's rows are not this
    # owner's debt, whatever shape they arrive in. A per-count assertion could
    # pass while a NEW gap silently appeared; this cannot.
    assert_equal before["groups"], after_["groups"]
    assert_equal before["by_project"], after_["by_project"]
    assert_equal before["needs_attention"], after_["needs_attention"]
    refute_includes group(after_, "jobs")["unresolved_ids"], Job.unscoped.find_by(owner: "other").id
    refute_includes group(after_, "candidates")["gaps"].keys, "orphan_job",
                    "an unattributable orphan is not audited at all, so it cannot leak"
  end

  # -- the HTML page and its filters ---------------------------------------

  test "the HTML page counts every gap and links each count to its list" do
    seed_debt
    sign_in
    get "/audit", headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    doc = Nokogiri::HTML(response.body)
    assert_equal "Audit", doc.at_css("h1.section-title .gradient-text")&.text&.strip
    assert doc.at_css(".page-head-blurb"), "the page head carries its blurb"
    assert_equal "JSON", doc.at_css("a.head-action")&.text&.strip
    assert_equal "/audit.json", doc.at_css("a.head-action")&.[]("href")

    # Every positive count is a LINK to the filtered list behind it.
    doc.css("table.candidates a.audit-count").each do |link|
      assert_match %r{\A/audit\?(gap=[a-z_]+\.[a-z_]+|project=(\d+|none))\z}, link["href"],
                   "a count links to the list behind it -- its gap, or its project"
      assert_operator link.text.to_i, :>, 0, "a zero is not a link -- there is nothing to open"
    end
    assert doc.css("a.audit-count").any?, "the seeded debt produced linked counts"
    assert doc.css('a.audit-count[href^="/audit?gap="]').any?,
           "and the GAP counts link to their own id lists"

    # The per-project breakdown is on the page, and its unresolved count links
    # to that project's list.
    assert_match %r{/audit\?project=\d+}, response.body
  end

  test "the audit pill is signed-in only" do
    # The footer's audit pill is operator chrome (like the engine light): the
    # bar renders on every page, /login included, and the page it leads to
    # reports the signed-in owner's own debt. Anonymous: no pill to click.
    # (/login is the page an anonymous visitor can actually reach -- `/` is
    # gated, so it renders the bar for nobody.)
    get "/login", headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    refute_includes response.body, 'href="/audit"',
                    "an anonymous visitor is offered no audit pill"
  end

  test "the page head is the house mechanism, not a new one" do
    src = Rails.root.join("app/views/audit/show.html.erb").read
    assert_includes src, "page-head-row--stacked", "the stacked grid, so the blurb has a cell"
    assert_includes src, "page-head-blurb", "and the blurb inside the row"
    assert_match(/h1 class="section-title"/, src)
  end

  test "?gap= renders the id list behind one count" do
    seed = seed_debt
    sign_in
    get "/audit?gap=jobs.missing_source", headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    assert_includes response.body, "jobs.missing_source"
    assert_includes response.body, "href=\"/jobs/#{seed[:thin_job].id}\"",
                 "the thin job is in the list"
    assert_includes response.body, "href=\"/jobs/#{seed[:error_job].id}\""
    refute_includes response.body, "href=\"/jobs/#{seed[:clean_job].id}\"",
                    "the clean job is not unresolved for this check"
  end

  test "?project= renders the unresolved rows in one project" do
    seed = seed_debt
    sign_in
    get "/audit?project=#{seed[:debt].id}", headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    assert_includes response.body, seed[:debt].name
    assert_includes response.body, "href=\"/jobs/#{seed[:thin_job].id}\""
    assert_includes response.body, "href=\"/jobs/#{seed[:error_job].id}\""
    refute_includes response.body, "href=\"/jobs/#{seed[:clean_job].id}\"",
                    "another project's rows are not in this project's list"
    # ONE row per RECORD: the thin job fails three checks and must be listed
    # once, carrying all three gap keys -- a list as long as the gaps would be
    # longer than the debt it claims to show. (A candidate's link is the job it
    # came from, so the href alone is not a row count -- count the ROWS.)
    doc = Nokogiri::HTML(response.body)
    # ...and the row must be the JOB's (its chips are `jobs.*`), because a
    # candidate whose id is also 1 renders the same `#1` in its own row.
    thin_rows = doc.css("table.candidates tbody tr").select do |tr|
      tr.at_css("td")&.text&.strip == "##{seed[:thin_job].id}" &&
        tr.css(".chip.mono").any? { |chip| chip.text.start_with?("jobs.") }
    end
    assert_equal 1, thin_rows.size, "a record with three gaps is one row, not three"
    assert_equal 3, thin_rows.first.css(".chip.mono").size,
                 "and that one row carries the three gap keys"
  end

  test "an unknown filter names itself rather than rendering an empty page" do
    sign_in
    get "/audit?gap=jobs.nope", headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_includes response.body, "No such gap"
  end

  # -- the constant --------------------------------------------------------

  test "gap definitions live in one constant, one line per check" do
    gaps = AuditGaps::GAPS
    assert_operator gaps.size, :>=, 20, "the seeded debt exercises most of them"

    # One shape, so a #107 epistemic-flag check slots in as a single entry and
    # nothing else in the file changes.
    gaps.each do |check|
      assert_equal %i[group key name rows], check.keys, "#{check.inspect}: one shape per check"
      assert_kind_of Symbol, check[:group]
      assert_match(/\A[a-z_]+\z/, check[:key].to_s)
      assert check[:name].present?
      assert_respond_to check[:rows], :call
    end

    keys = gaps.map { |c| "#{c[:group]}.#{c[:key]}" }
    assert_equal keys.uniq, keys, "every check has a distinct group.key"
    assert_equal AuditGaps::GROUPS.keys.sort,
                 gaps.map { |c| c[:group] }.uniq.sort,
                 "every check belongs to a declared group"
  end

  test "the document is stable enough to diff: no timestamp inside a count" do
    seed_debt
    sign_in
    first = audit_json
    second = audit_json

    assert_equal first["groups"], second["groups"],
                 "the counts and id lists are identical across two reads"
    assert_equal first["by_project"], second["by_project"]
    # The stamp moves between reads (one second apart), and it is the ONLY key
    # that does -- so a diff over time reads as "the numbers changed", not as
    # "the document changed shape". Compared as RAW TEXT with the stamp masked:
    # parsed-Hash equality cannot see JSON KEY-ORDER drift, and key order is
    # exactly what a textual diff is sensitive to (review finding, #95).
    travel 1.second
    third = audit_json
    refute_equal first["generated_at"], third["generated_at"],
                 "only the generated_at stamp moves between reads"
    assert_equal first["groups"], third["groups"]

    masked = ->(raw) { raw.gsub(/"generated_at":"[^"]*"/, '"generated_at":"<t>"') }
    assert_equal masked.call(first.to_json), masked.call(third.to_json),
                 "byte-for-byte shape, key order included -- only the stamp differs"
  end
end
