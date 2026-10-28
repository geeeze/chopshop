require "test_helper"

# The `iconography` template: a flat source in, an icon out.
#
# What is asserted is the COMPOSED SPEC — what actually reaches the runner —
# because that is the contract: a template whose override never lands, or lands
# at the wrong path, produces a run the operator did not ask for while the form
# looks correct the whole time. The picker and option markup are already held by
# run_job_template_test (which sweeps every template in PipelineConf); this file
# holds what iconography composes, what it deliberately does NOT write, and that
# a switch into and out of it leaves no residue either way.
class IconographyTemplateTest < ActiveSupport::TestCase
  # --- the shape: a trace template in the print-production group ------------

  test "iconography is a trace template under Print production" do
    assert_equal "svg", PipelineConf.template_kind("iconography"),
      "the icon comes from the trace pipeline, so it is an svg job"
    assert_equal "Print production", PipelineConf.group_for("iconography"),
      "it is a preset of trace tuning, not a shape of its own"
    assert_equal %w[max_colors max_candidates presets min_stroke_width_pt prep_colors],
                 PipelineConf.lever_names_for("iconography"),
      "the subset is screenprint's plus the preset axis, in BOUNDS order"
  end

  test "iconography composes four inks, a short sweep and a hard stroke floor" do
    spec = PipelineConf.compose("iconography")

    assert_equal 4, spec["max_colors"], "an icon carries four inks at 16px, not six"
    assert_equal 8, spec.dig("print", "sweep", "max_candidates"),
      "the palette is the interesting axis, so the sweep is short"
    assert_equal %w[bw poster photo], spec.dig("print", "sweep", "presets"),
      "all three presets are compared — the issue names the full list"
    assert_equal 1.5, spec.dig("geometry", "min_stroke_width_pt"),
      "the hard floor: a hairline does not survive being scaled down"
    assert_equal 8, spec.dig("print", "prep_colors"),
      "quantise to 8 before tracing — four inks out of sixteen is a mush"
  end

  test "the stroke floor is the template's OWN value, not the bound's default" do
    # The issue calls this override HARD. What that can mean in this design is
    # that the template ASSERTS the number: it states 1.5 itself, so it does not
    # float with the service's default and a change to BOUNDS' default cannot
    # move an icon template's floor. (A template carries no ranges — the
    # operator can still move the lever; what it cannot do is inherit.)
    overrides = PipelineConf.template("iconography")[:overrides]
    assert overrides.key?("min_stroke_width_pt"),
      "the floor must be the template's own override, or it is the bound's default by accident"
    assert_equal 1.5, overrides["min_stroke_width_pt"]
    assert_equal 1.5, PipelineConf.default_for("iconography", "min_stroke_width_pt")
    assert PipelineConf.within_bounds?("min_stroke_width_pt", 1.5),
      "and the hard floor is inside the bound the service enforces"
  end

  # --- the fragment: closed paths, and nothing invented ---------------------

  test "iconography closes every path — a hard-edged icon has no free ends" do
    spec = PipelineConf.compose("iconography")

    assert_equal false, spec.dig("geometry", "allow_open_paths"),
      "allow_open_paths is a real spec key and a HARD gate: a path with a free " \
      "end must fail the print check rather than ship as a stroke"
    assert_equal({ "geometry" => { "allow_open_paths" => false } },
                 PipelineConf.static_spec("iconography"),
      "the closed-path gate is the template's ONLY static fact")
  end

  test "the fragment invents no key the trace contract cannot read" do
    # Two things the icon shape would LIKE and this template does not write,
    # because neither is a lever the runner reads:
    #
    #   * `dimensions` — a REAL spec key, but the PRINT SIZE in mm, and it arms
    #     the hard DIMENSIONS gate. Pinning 512x512 there would fail every icon
    #     whose source raster is not exactly that size, and the contract defines
    #     no px -> mm conversion to pin it with. The pixel size is the SOURCE's:
    #     the blurb says to draw it square at 512px.
    #   * an alpha/transparent flag — prep flattens alpha onto
    #     print.background_hex and the substrate is front_pipeline.sh's own
    #     business, so a key for it here would be configuration for a stage that
    #     never reads it.
    #
    # This test is the guard on that judgement: adding either one has to come
    # with a contract key that reads it, not just with an intention.
    spec = PipelineConf.compose("iconography")

    refute spec.key?("dimensions"),
      "a fixed print size arms the hard DIMENSIONS gate for every icon"
    refute spec.key?("palette"), "a palette is not a lever and not this template's"
    refute spec.key?("print_method"), "print_method is not a lever — seeding one is the " \
                                      "residue bug this form was fixed for"

    # Every key it DOES write is one the template owns: a lever's root, or the
    # fragment's namespace. Anything else is a key remove_decay could never
    # clear, so it would survive every later template switch.
    owned = PipelineConf.lever_names_for("iconography")
                          .map { |name| PipelineConf.bound(name)[:spec_path].first } +
            PipelineConf.static_spec("iconography").keys
    spec.each_key do |key|
      assert_includes owned, key,
        "#{key.inspect} is not owned by iconography — remove_decay cannot clear " \
        "it, so it would leak into whatever template is chosen next"
    end
  end

  # --- the cleanup contract, both directions --------------------------------

  test "screenprint -> iconography adds the closed-path gate and the preset axis" do
    screen = PipelineConf.compose("screenprint")
    icon = PipelineConf.compose("iconography", into: screen)

    assert_equal false, icon.dig("geometry", "allow_open_paths"),
      "the gate arrives from the template, not from the contract it was applied to"
    assert_equal %w[bw poster photo], icon.dig("print", "sweep", "presets"),
      "and so does the preset list — screenprint does not expose that lever"
    assert_equal 4, icon["max_colors"], "the ink budget is re-asserted, not inherited"
    refute icon.key?("hierarchical"), "a lever iconography does not expose stays out"
  end

  test "photo -> iconography clears photo's gradient gate" do
    # The static fragments are per-template facts, so switching to a template
    # that does not own one must take it away — otherwise an icon job would run
    # with gradients allowed because a photo job was chosen before it.
    icon = PipelineConf.compose("iconography", into: PipelineConf.compose("photo"))
    refute icon.dig("geometry", "allow_gradients"),
      "photo's allow_gradients must not survive into an icon contract"
    assert_equal false, icon.dig("geometry", "allow_open_paths")
  end

  test "iconography -> photo clears the closed-path gate" do
    photo = PipelineConf.compose("photo", into: PipelineConf.compose("iconography"))
    refute photo.dig("geometry", "allow_open_paths"),
      "photo does not own allow_open_paths, so remove_decay takes it out"
    assert_equal true, photo.dig("geometry", "allow_gradients"),
      "and photo's own gate is what lands"
  end

  test "applying iconography to the form's opening contract leaves no other shape" do
    # The operator-visible path: the form opens on compose(DEFAULT_TEMPLATE) —
    # a General job, a flux block — and picking Iconography must describe an
    # icon job only. This is the residue the issue's root-cause note is about.
    base = PipelineConf.compose(PipelineConf::DEFAULT_TEMPLATE, into: {})
    out = PipelineConf.compose("iconography", into: base)

    refute out.key?("flux"), "the default's flux block must go"
    refute out.key?("steps"), "and no chain"
    assert_equal 4, out["max_colors"]
    assert_equal false, out.dig("geometry", "allow_open_paths")
  end

  # --- the ordinary composer rules, on this template ------------------------

  test "an operator override beats the template and a blank one falls through" do
    spec = PipelineConf.compose("iconography", overrides: { "max_colors" => 2 })
    assert_equal 2, spec["max_colors"], "a form value is the most recent fact"

    blank = PipelineConf.compose("iconography", overrides: { "min_stroke_width_pt" => "" })
    assert_equal 1.5, blank.dig("geometry", "min_stroke_width_pt"),
      "an untouched input must not clear the hard floor to 0"
  end

  test "composing iconography twice is the same document, and it survives JSON" do
    once = PipelineConf.compose("iconography")
    assert_equal once, PipelineConf.compose("iconography", into: once),
      "a page that composes on load and again on submit must not drift"
    assert_equal once, JSON.parse(JSON.generate(once)),
      "string keys all the way down, or the posted contract differs from the composed one"
  end

  test "an override naming a lever iconography does not expose raises" do
    assert_raises(ArgumentError) do
      PipelineConf.compose("iconography", overrides: { "ink_limit_percent" => 400 })
    end
  end
end
