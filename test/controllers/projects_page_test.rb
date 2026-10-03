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
end
