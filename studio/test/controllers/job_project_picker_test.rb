require "test_helper"

# Every Run Job entry lands on the same form, and the form ASKS which project
# the run belongs to. A project-less job is listed NOWHERE under the Projects
# workspace (the redesign's one jobs surface is the per-project page), so the
# head buttons on /json, /flux, /jev and /bp — plain `new_job_path` links, and
# /json via its json/use spec hand-off — could silently file invisible jobs.
# This pins the prompt, its two paths (pick an existing project / create a new
# one), the server-side refusal for a browser that submits neither, and the
# agent-API exception (JSON posts may still omit the project).
class JobProjectPickerTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def login
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = nil
  end

  def get_doc(path)
    login
    get path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def run_body(**job)
    { job: { name: "picker-probe", source_kind: "raster", runner: "mock",
             input_path: "/data/x.png", spec: "{}" }.merge(job) }
  end

  test "the FLUX, JEV and BP head buttons lead at the Run Job form" do
    %w[/flux /jev /bp].each do |path|
      doc = get_doc(path)
      link = doc.at_css(".head-action--top")
      refute_nil link, "#{path} keeps its head Run Job button"
      assert_equal new_job_path, link["href"],
        "#{path}'s Run Job button must land on the form that prompts for a project"
    end
  end

  test "the JSON page's runs hand off to the same form" do
    # The page's own Run Job button POSTs the spec to json/use, and apply_spec
    # stores a draft and redirects to the form — where the picker lives.
    login
    post use_json_path, params: { spec: '{"print": {"sweep_max": 4}}' },
         headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_match %r{\A/jobs/new}, URI.parse(response.location).path,
      "json/use must hand its draft to the Run Job form, not file a job itself"
  end

  test "the form prompts: the operator's projects, plus Create a new project" do
    p = Project.create!(name: "picker-owned", is_test: false)
    doc = get_doc(new_job_path)

    select = doc.at_css("#job_project_id")
    refute_nil select, "the picker is a real select, not a hidden field"
    assert select["required"].present?, "with nothing preselected the select is required"
    options = select.css("option").map { |o| [o.text.strip, o["value"]] }
    assert_includes options, ["picker-owned", p.id.to_s], "the operator's own project is listed"
    assert_includes options, ["\u2795 Create a new project\u2026", "__new__"],
      "the new-project path exists"

    name_field = doc.at_css("#job_project_name")
    refute_nil name_field, "the new-project name input is in the form"
    assert_equal "job[project_name]", name_field["name"], "it posts as job[project_name]"
    refute_nil doc.at_css("[data-project-picker-name]"),
      "the reveal script's contract attribute is present (the script hides it on load)"
  end

  test "a workspace preselection shows as chosen, not required" do
    p = Project.create!(name: "picker-preselected", is_test: false)
    doc = get_doc(new_job_path(project_id: p.id))
    select = doc.at_css("#job_project_id")
    assert_equal p.id.to_s, select.at_css("option[selected]")&.[]("value"),
      "the carried project is the selected one"
    assert select["required"].blank?, "nothing to ask when the choice already came in"
    assert doc.at_css("#job_project_name")["hidden"].present?,
      "the new-project input stays out of the way when a project came preselected"
  end

  test "posting with a project files the run under it" do
    p = Project.create!(name: "picker-target", is_test: false)
    login
    post jobs_path, params: run_body(project_id: p.id), headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    job = Job.order(:id).last
    assert_equal p.id, job.project_id
  end

  test "posting Create a new project makes the project and files the run under it" do
    login
    post jobs_path,
         params: run_body(project_id: "__new__", project_name: "Picker Made"),
         headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    project = Project.find_by(name: "Picker Made")
    refute_nil project, "the project is created from the form"
    job = Job.order(:id).last
    assert_equal project.id, job.project_id, "the run is filed under the new project"
  end

  test "a browser post with neither is refused, and the prompt survives the error" do
    login
    assert_no_difference "Job.count" do
      post jobs_path, params: run_body(project_id: ""), headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :unprocessable_entity
    assert_match(/needs a project/, flash[:alert].to_s)
    doc = Nokogiri::HTML(response.body)
    refute_nil doc.at_css("#job_project_id"),
      "the re-render still carries the picker — the prompt must survive the error"
  end

  test "an agent's JSON post may still omit the project (the API contract)" do
    login
    post jobs_path, params: run_body.except(:project_id).merge(format: :json),
         as: :json, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    job = Job.order(:id).last
    assert_nil job.project_id, "JSON posts keep the documented project-optional contract"
  end
end
