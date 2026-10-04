require "test_helper"

# The Projects container — a stored table (not a tag view) that owns the
# sources, sequences the jobs, and holds outputs back. Minimal verification
# of the head contract and the list, plus an owner-scoped read.
class ProjectsPageTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def login
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
  end

  def fetch(path)
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    login
    get path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = nil
  end

  test "the Projects page carries the standard stacked head" do
    doc = fetch(projects_path)
    head = doc.at_css(".page-head-row--stacked")
    refute_nil head, "the head row must use the stacked grid"
    assert_includes doc.at_css(".section-title").text.strip, "Projects",
      "the heading is the container's name"
  end

  test "a new project creates with a real is_test column and is owner-scoped" do
    p = Project.create!(name: "test-project-verify", is_test: false)
    assert_equal "test-project-verify", p.name
    assert p.id.present?
    # Owned scope: the same handle as the session's Current user.
    assert Project.for_owner(p.owner).where(name: "test-project-verify").exists?
  end

  test "the project head stacks Run Job then Compose, with Projects + List/Grid on the blurb line" do
    p = Project.create!(name: "head-layout-probe", is_test: true)
    doc = fetch(project_path(p))
    head = doc.at_css(".page-head-row--stacked.project-head")
    refute_nil head, "the project head must use the stacked grid with the .project-head scope"

    run = head.at_css(".head-action--top")
    compose = head.at_css(".head-action--below")
    refute_nil run, "Run Job is the top action"
    refute_nil compose, "Compose is the action under Run Job"
    assert_equal "Run Job", run.text.strip
    assert_equal "Compose", compose.text.strip

    # Projects (back) and the List/Grid toggle share the blurb's line, right edge.
    pair = head.at_css(".project-head-actions")
    refute_nil pair, "Projects + List/Grid live in the .project-head-actions pair"
    assert_includes pair.text, "Projects"
    refute_nil pair.at_css(".view-toggle"), "the List/Grid toggle is in the pair"
    refute_nil head.at_css(".page-head-blurb"), "the blurb is still in the head row"
  end

  test "the project page lists the project's composites" do
    p = Project.create!(name: "composites-probe", is_test: true)
    Composite.create!(name: "probe-composite", width: 100, height: 100,
                      background: "transparent", layers: [], project_id: p.id)
    doc = fetch(project_path(p))
    section = doc.at_css(".composites-section")
    refute_nil section, "a composites section must render"
    assert_includes section.text, "probe-composite"
    assert_includes section.at_css("a[href]")["href"], "composite"
  end
end
