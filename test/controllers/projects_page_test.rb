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

  test "the project head stacks Run Job then Compose, with Projects under the blurb on the left and List/Grid under the actions on the right" do
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

    # Projects (back) sits under the blurb on the LEFT; the toggle under the
    # right-column actions. Both on line 3, opposite columns -- never crammed
    # side by side in one wrapper.
    back = head.at_css(".project-back")
    refute_nil back, "the Projects back button is placed on its own line"
    assert_equal "Projects", back.text.strip
    refute_nil head.at_css("> .project-back"), "Projects is a direct grid child, not wrapped"
    toggle = head.at_css("> .view-toggle")
    refute_nil toggle, "the List/Grid toggle is its own grid child"
    refute head.at_css(".project-head-actions"), "no cram-everything-in-one-pair wrapper"
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
