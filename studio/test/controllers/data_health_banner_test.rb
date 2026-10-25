require "test_helper"

# The one-line data-layer health banner (#3) -- the kb's `.banner.warn` under
# the header, backported.
#
# The contracts pinned here:
#
#   * PLACEMENT -- the banner is rendered by the LAYOUT, under the header, on
#     every authed page: a partial rendered once in the layout, not per-page
#     markup. The header is the one chrome every page shares, which is why the
#     kb's banner lives there and why the studio's does too;
#   * FED BY THE AUDIT -- `AuditGaps.banner` is a projection of
#     `AuditGaps.report`, the SAME document /audit renders. A unit test pins the
#     two agree, so the banner cannot drift from the page it links to;
#   * ONLY WHEN THERE IS DEBT -- a clean data layer renders no banner at all. A
#     banner that is always there is chrome, not a warning;
#   * THE LINK -- the banner links to /audit, the full picture, and lists the
#     checks compactly by name and count.
class DataHealthBannerTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def sign_in
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  # A CLEAN data layer: one project that has a source, a run and an output, and
  # a settled job whose candidate was proved. Every check in AuditGaps::GAPS
  # must leave it alone, so the banner has nothing to say. (The project needs
  # all three of source/run/output: `projects.no_sources`, `.no_runs` and
  # `.no_outputs` are checks too, and a project missing any of them is debt.)
  def seed_clean
    project = Project.create!(name: "clean-#{rand(1_000_000)}", is_test: false)
    source = Source.create!(name: "src-#{rand(1_000_000)}", source_type: "raster",
                            project_id: project.id)
    job = Job.create!(name: "clean", state: "done", source_kind: "svg",
                      input_path: "/data/clean.svg", stem: "clean",
                      runner: "mock", runner_stem: "clean",
                      finished_at: Time.current, project_id: project.id,
                      source_id: source.id)
    candidate = job.candidates.create!(file: "candidate_01.svg", preset: "poster",
                                       layer_a: "done", layer_b: "done")
    job.validations.create!(file: "candidate_01.svg", state: "done",
                            candidate_id: candidate.id, manifest: { "gates" => [] })
    Output.create!(file_name: "clean-proof-01.png", output_kind: "proof",
                   job_id: job.id, project_id: project.id, sha256: "a" * 64)
    project
  end

  # A THIN job on top of the clean one: settled with no runner stem, no finish
  # stamp and no source -- three gaps the banner must name. Its project is the
  # clean one, so the project-level checks stay satisfied.
  def seed_debt
    project = seed_clean
    Job.create!(name: "thin", state: "done", source_kind: "svg",
                input_path: "/data/thin.svg", stem: "thin", runner: "mock",
                runner_stem: nil, finished_at: nil, project_id: project.id,
                source_id: nil)
    project
  end

  # -- placement ------------------------------------------------------------

  test "the layout renders the banner partial under the header" do
    src = Rails.root.join("app/views/layouts/application.html.erb").read
    assert_includes src, 'render "shared/data_health_banner"',
                    "the banner is layout chrome, not per-page markup"
    # Under the header: the render call comes after the nav the header closes,
    # so the banner is below the header rather than above it.
    assert_operator src.index("</nav>"), :<, src.index('render "shared/data_health_banner"'),
                   "the banner sits under the header, not above it"
  end

  # -- only when there is debt ----------------------------------------------

  test "a clean data layer renders no banner on any authed page" do
    seed_clean
    sign_in
    [root_path, about_path, audit_path].each do |path|
      get path, headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      assert_nil Nokogiri::HTML(response.body).at_css("[data-health-banner]"),
                   "#{path}: a clean data layer renders no banner"
    end
  end

  test "an anonymous visitor is offered no banner" do
    seed_debt
    get login_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_nil Nokogiri::HTML(response.body).at_css("[data-health-banner]"),
                 "the banner is gated on current_user, like the /audit page it links to"
  end

  # -- the debt case ---------------------------------------------------------

  test "debt renders the one-line banner with the checks and the audit link" do
    seed_debt
    sign_in
    get root_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    banner = Nokogiri::HTML(response.body).at_css("[data-health-banner]")
    refute_nil banner, "the seeded debt produced a banner"
    assert_equal "banner warn", banner["class"], "it carries the kb's .banner.warn"

    text = banner.text.gsub(/\s+/, " ")
    assert_includes text, "data debt"
    # The checks the thin job trips, by name and count.
    assert_includes text, "terminal jobs with no runner stem (1)"
    assert_includes text, "terminal jobs with no finished_at (1)"
    assert_includes text, "jobs with no source (1)"
    # The clean job's debt is NOT named -- the banner is the audit, not a guess.
    refute_includes text, "candidates with no proof"

    # One link, and it is the full picture rather than a per-gap list.
    link = banner.at_css("a")
    refute_nil link, "the banner links somewhere"
    assert_equal "/audit", link["href"]
  end

  test "the banner is app-wide, not one page's markup" do
    seed_debt
    sign_in
    [root_path, about_path, audit_path].each do |path|
      get path, headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      assert Nokogiri::HTML(response.body).at_css("[data-health-banner]"),
             "#{path}: the debt shows on every authed page, not only the index"
    end
  end

  # -- fed by the audit ------------------------------------------------------

  test "the banner is a projection of the report /audit renders" do
    seed_debt
    report = AuditGaps.report
    banner = AuditGaps.banner

    refute_empty banner
    # Every named check is a check in the report's own groups, with the SAME
    # count and the SAME order -- a projection of one walk, not a second one.
    expected = report[:groups].flat_map do |group|
      group[:gaps].select { |_key, n| n.positive? }.map do |key, n|
        check = AuditGaps::GAPS.find do |c|
          "#{c[:group]}.#{c[:key]}" == "#{group[:key]}.#{key}"
        end
        [check[:name], n]
      end
    end
    assert_equal expected, banner

    # The banner reads `report`: swap the report and the banner follows. An
    # empty report is an empty banner, so the two cannot come apart. (This is
    # the wiring pin -- the seeded-truth test above pins WHAT the banner says.)
    original = AuditGaps.method(:report)
    AuditGaps.define_singleton_method(:report) { { groups: [] } }
    assert_empty AuditGaps.banner
  ensure
    AuditGaps.define_singleton_method(:report, original)
  end
end
