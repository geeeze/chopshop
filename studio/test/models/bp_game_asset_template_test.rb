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

  # --- the chain: the two pipelines in one job -------------------------------

  test "generate_trace_render composes a three-step chain of kinds" do
    spec = PipelineConf.compose("generate_trace_render")
    steps = spec["steps"]

    assert_kind_of Array, steps, "the chain IS the spec: steps, not levers"
    assert_equal 3, steps.length
    assert_equal %w[flux svg bp], steps.map { |s| s["kind"] },
                 "each step names a KIND — labels are the deployment's env, and " \
                 "a template may not invent them"

    # The blocks are the same per-kind requests a single-action job posts.
    assert_equal "raster", steps[0]["flux"]["mode"]
    assert_equal 6, steps[1]["svg"]["max_colors"]
    bp = steps[2]["bp"]
    assert_equal "blender", bp["op"], "the last step renders"
    assert_equal [], bp["doc"]["elements"],
                   "empty ON PURPOSE: run_bp_step derives the elements from the " \
                   "traced .svg at run time and merges them in"
    assert_equal "transparent", bp["doc"]["render"]["background"]
  end

  test "the chain is a static fragment, so a second application does not double it" do
    once = PipelineConf.compose("generate_trace_render")
    twice = PipelineConf.compose("generate_trace_render", into: once)
    assert_equal 3, twice["steps"].length,
                 "merging a step list into itself must not append a second copy"
  end

  test "choosing a single-action template clears the chain" do
    # The reverse direction: `steps` is in the static-path set, so remove_decay
    # takes it away when another template is chosen — otherwise a contract would
    # carry a chain nobody picked beside the single action that replaced it.
    spec = PipelineConf.compose("standard",
                                into: PipelineConf.compose("generate_trace_render"))
    refute spec.key?("steps"), "the old chain must not survive the template switch"
    assert spec.key?("max_colors"), "and the new template's levers must arrive"
  end

  test "the chain's option declares the kind the form will resolve" do
    source = File.read(Rails.root.join("app/views/jobs/new.html.erb"))
    assert_match(/PipelineConf\.template_kind\(key\)/, source,
                 "the option's data-kind is derived from the template, not typed")
    assert_equal "flux", PipelineConf.template_kind("generate_trace_render")
    assert_empty PipelineConf.lever_names_for("generate_trace_render"),
                 "a step list has no number to sweep, so it exposes no levers"
  end

  test "the form resolves a composed kind to a runner label and ticks the sequence" do
    source = File.read(Rails.root.join("app/views/jobs/new.html.erb"))
    assert_includes source, "function applyComposedSteps",
                    "the Apply path must resolve kind -> label, or the rows post " \
                    "an empty runner and the model refuses the job"
    assert_includes source, "applyComposedSteps(res.j.spec)",
                    "...and it must actually be called from the Apply handler"
    assert_includes source, "hydrateSeq();", "the rows hydrate from the contract"
    assert_includes source, "seqOnBox.checked = hasSteps",
                    "a chain is a choice: without the tick the next writePanels " \
                    "deletes spec.steps"
    # The refusal must SURVIVE the handler: applyComposedSteps reports a missing
    # runner through the blurb, and the handler's own "— applied." used to
    # overwrite it one line later — a contract that was rolled back, announced
    # as applied. Observed in the browser before this was pinned.
    assert_includes source, "stepsApplied !== false",
                    "the success message must not overwrite a refusal"
    assert_includes source, "delete current.steps",
                    "a refused chain comes back OUT of the contract, not left " \
                    "there for the model to refuse at submit"
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
