require "test_helper"

# The two game-asset templates and the render controls that edit them.
#
# What is asserted is the COMPOSED SPEC — what actually reaches the service —
# because that is the contract: a template whose override never lands, or lands
# at the wrong path, produces a render the operator did not ask for and the form
# looks correct the whole time. The lever->control map and the option markup are
# already held by `run_job_template_test`; this file holds what they compose.
class BpGameAssetTemplateTest < ActionDispatch::IntegrationTest
  # --- sprite_alpha: the RGBA frame a game engine composites -----------------

  test "sprite_alpha composes an alpha sprite at a power-of-two size" do
    spec = PipelineConf.compose("sprite_alpha")
    assert_equal "bp", PipelineConf.template_kind("sprite_alpha")

    bp = spec["bp"]
    assert_equal "blender", bp["op"], "the sprite is a render, not a drawing"
    doc = bp["doc"]
    assert_equal "transparent", doc["render"]["background"],
                 "the whole point: an RGBA frame with the world omitted"
    assert_equal "ortho", doc["render"]["projection"]
    assert_equal 0.0, doc["render"]["elevation"],
                 "front-on: 0 degrees above the horizon"
    assert_equal 1, doc["render"]["views"], "a sprite is one frame"
    assert_equal({ "width" => 512, "height" => 512 }, doc["render"]["size"],
                 "power of two, for a texture")
    assert_equal "workbench", doc["render"]["engine"]
    refute doc.key?("export"), "a sprite asks for frames, not a mesh"
  end

  test "sprite_alpha leaves the trace levers behind rather than carrying them" do
    # The chosen template's subset is the feature: applying it to a contract
    # that already holds a trace job must not leave trace settings beside a
    # render, which is one shape of work next to another.
    spec = PipelineConf.compose("sprite_alpha",
                                into: { "max_colors" => 6,
                                        "print" => { "sweep" => { "max_candidates" => 12 } } })
    refute spec.key?("max_colors"), "a lever this template does not expose must go"
    refute spec.key?("print"), "and so must its block"
    assert_equal "transparent", spec["bp"]["doc"]["render"]["background"]
  end

  # --- prop_turntable: four frames and the mesh ------------------------------

  test "prop_turntable composes four views around from the front, with a GLB" do
    spec = PipelineConf.compose("prop_turntable")
    doc = spec["bp"]["doc"]

    assert_equal "blender", spec["bp"]["op"]
    assert_equal 4, doc["render"]["views"],
                 "four angles walk evenly around from the azimuth"
    assert_equal 25.0, doc["render"]["elevation"], "a three-quarter view, not a plan"
    assert_equal "ortho", doc["render"]["projection"]
    assert_equal({ "glb" => true }, doc["export"],
                 "the mesh comes from the template's static fragment: BOUNDS has " \
                 "no boolean type, and a checkbox would post the string \"true\"")
    assert_equal({ "width" => 512, "height" => 512 }, doc["render"]["size"])
  end

  test "an operator override still beats the template's own value" do
    spec = PipelineConf.compose("prop_turntable", overrides: { "bp_views" => 8 })
    assert_equal 8, spec["bp"]["doc"]["render"]["views"]
    # and the static fragment survives an override — it is not a lever, so the
    # override pass never touches it.
    assert_equal({ "glb" => true }, spec["bp"]["doc"]["export"])
  end

  test "a blank override falls through to the template's own answer" do
    spec = PipelineConf.compose("sprite_alpha", overrides: { "bp_elevation" => "" })
    assert_equal 0.0, spec["bp"]["doc"]["render"]["elevation"],
                 "an untouched number input must not clear the template's value"
  end

  # --- the render controls, on the form --------------------------------------

  test "every render lever maps to a control that exists in the view" do
    source = File.read(Rails.root.join("app/views/jobs/new.html.erb"))
    %w[bp_render_width bp_render_height bp_background bp_projection
       bp_elevation bp_azimuth].each do |lever|
      id = ApplicationHelper::RUN_JOB_LEVER_CONTROLS.fetch(lever) {
        flunk "#{lever} has no entry in RUN_JOB_LEVER_CONTROLS — the template " \
              "would compose it and nothing on the page could move it"
      }
      assert_includes source, "id=\"#{id}\"", "#{lever} is mapped to #{id}, " \
                                              "which is not in the view"
    end
  end

  test "the render controls live in the gated group, not loose in the panel" do
    source = File.read(Rails.root.join("app/views/jobs/new.html.erb"))
    group = source[/<div id="bpRenderFields".*?<\/div>\s*\n\s*<div class="actions-row">/m]
    refute_nil group, "the render controls must sit in #bpRenderFields so the " \
                      "operation gate can show and hide them as one block"
    assert_match(/\A<div id="bpRenderFields" hidden>/, group,
                 "hidden by default: the panel opens on `generate`, which has " \
                 "no render block to edit")
    %w[bp_render_width bp_background bp_projection bp_elevation].each do |id|
      assert_includes group, "id=\"#{id}\"", "#{id} must be inside the gated group"
    end
  end

  test "the helper map carries the render levers the templates expose" do
    map = ApplicationHelper::RUN_JOB_LEVER_CONTROLS
    PipelineConf.lever_names_for("sprite_alpha").each do |lever|
      assert map.key?(lever), "#{lever} is exposed by sprite_alpha but the form " \
                              "has no control mapping for it"
    end
  end
end
