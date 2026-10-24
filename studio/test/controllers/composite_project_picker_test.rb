require "test_helper"

# The composite builder's project picker — the same contract Run Job's form
# carries (ProjectPicker), because a compose run is RECORDED under its
# composite's project (record_compose_job, and #use forwards it), so a
# project-less composite files runs that appear nowhere under the Projects
# workspace. The builder used to post composite.project_id as a hidden field,
# so composing from the bare /composite/new link (about page, jobs/new) silently
# filed invisible runs. This pins the prompt, its two paths, the refusal for a
# browser that submits neither, moving a composite, and the JSON exception.
class CompositeProjectPickerTest < ActionDispatch::IntegrationTest
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

  def layer_svg
    { "kind" => "vector",
      "src" => "/jobs/upload_preview/frame_test.svg",
      "x" => 0, "y" => 0, "w" => 100, "h" => 100 }
  end

  def create_body(**fields)
    { name: "picker-probe", width: "100", height: "100",
      background: "transparent", layers: JSON.generate([layer_svg]) }.merge(fields)
  end

  test "the builder prompts: the operator's projects, plus Create a new project" do
    p = Project.create!(name: "compose-picker-owned", is_test: false)
    doc = get_doc(new_composite_path)

    select = doc.at_css("#composite_project_id")
    refute_nil select, "the picker is a real select, not a hidden field"
    assert select["required"].present?, "with nothing preselected the select is required"
    options = select.css("option").map { |o| [o.text.strip, o["value"]] }
    assert_includes options, ["compose-picker-owned", p.id.to_s], "the operator's own project is listed"
    assert_includes options, ["\u2795 Create a new project\u2026", "__new__"],
      "the new-project path exists"

    name_field = doc.at_css("#composite_project_name")
    refute_nil name_field, "the new-project name input is in the form"
    assert_equal "project_name", name_field["name"], "it posts flat, as the builder's other fields do"
    refute_nil doc.at_css("[data-project-picker-name]"),
      "the reveal script's contract attribute is present (the script hides it on load)"
    refute_nil doc.at_css("aside.scrapbook-sidebar"),
      "the picker rides the shared layout, so the sidebar must still render"
  end

  test "a project-context entry shows as chosen, not required" do
    p = Project.create!(name: "compose-picker-preselected", is_test: false)
    doc = get_doc(new_composite_path(project_id: p.id))
    select = doc.at_css("#composite_project_id")
    assert_equal p.id.to_s, select.at_css("option[selected]")&.[]("value"),
      "the carried project — the projects workspace's Compose links send it — is the selected one"
    assert select["required"].blank?, "nothing to ask when the choice already came in"
    assert doc.at_css("#composite_project_name")["hidden"].present?,
      "the new-project input stays out of the way when a project came preselected"
  end

  test "posting with a project files the composite under it" do
    p = Project.create!(name: "compose-picker-target", is_test: false)
    login
    post create_composite_path, params: create_body(project_id: p.id),
         headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal p.id, Composite.order(:id).last.project_id
  end

  test "posting Create a new project makes the project and files the composite under it" do
    login
    post create_composite_path,
         params: create_body(project_id: "__new__", project_name: "Compose Picker Made"),
         headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    project = Project.find_by(name: "Compose Picker Made")
    refute_nil project, "the project is created from the form"
    assert_equal project.id, Composite.order(:id).last.project_id
  end

  test "a browser post with neither is refused, and the prompt survives the error" do
    login
    assert_no_difference "Composite.count" do
      post create_composite_path, params: create_body(project_id: ""),
           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :unprocessable_entity
    assert_match(/needs a project/, flash[:alert].to_s)
    doc = Nokogiri::HTML(response.body)
    refute_nil doc.at_css("#composite_project_id"),
      "the re-render still carries the picker — the prompt must survive the error"
  end

  test "an agent's JSON post may still omit the project (the API contract)" do
    login
    assert_difference "Composite.count", 1 do
      post create_composite_path, params: create_body, as: :json,
           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :success
    assert_nil Composite.order(:id).last.project_id,
      "JSON posts keep the documented project-optional contract"
  end

  test "saving the builder moves an existing composite to the picked project" do
    from = Project.create!(name: "compose-picker-from", is_test: false)
    to = Project.create!(name: "compose-picker-to", is_test: false)
    c = Composite.create!(name: "mover", width: 100, height: 100,
                          background: "transparent", layers: [], project_id: from.id)
    login
    patch composite_update_path(c),
          params: { name: "mover", width: "100", height: "100",
                    background: "transparent", layers: "[]", project_id: to.id },
          headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal to.id, c.reload.project_id,
      "the picker posts on every save, so choosing a project must move the composite"
  end

  test "the persisted composite's form preselects its own project" do
    p = Project.create!(name: "compose-picker-owned-edit", is_test: false)
    c = Composite.create!(name: "editor", width: 100, height: 100,
                          background: "transparent", layers: [], project_id: p.id)
    doc = get_doc(composite_path(id: c.id))
    select = doc.at_css("#composite_project_id")
    refute_nil select, "the edit form carries the picker too"
    assert_equal p.id.to_s, select.at_css("option[selected]")&.[]("value"),
      "the composite's current project is the selected one"
    assert select["required"].blank?, "its project is known, so the field is not required"
  end
end
