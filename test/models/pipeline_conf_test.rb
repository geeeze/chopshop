require "test_helper"

# The lever BOUNDS and the TEMPLATES are two different kinds of fact, and the
# design only works if they stay apart:
#
#   BOUNDS    — what each service will accept, transcribed from it.
#   TEMPLATES — a name and a CHOSEN SUBSET of those bounds, with sane defaults.
#
# So the tests here are about the RELATIONSHIP, not about the numbers:
#
#   * every lever a template names is a real bound (a typo would otherwise
#     render as a control that does nothing),
#   * every bound is well-formed against its own declared type,
#   * no template restates a RANGE (that is what would make it a second source
#     of truth for every default and every limit — the drift trap already paid
#     for between FluxConf and config.py, which costs a cross-repo parity test),
#   * the numbers that ARE transcribed match the constants they claim to come
#     from, so a service changing its default fails HERE rather than at a GPU.
class PipelineConfTest < ActiveSupport::TestCase
  # A bound must be able to describe itself, or a page that renders one has
  # nothing to render. This is the list a new lever has to satisfy.
  #
  # :min/:max are required for a NUMERIC bound and meaningless for a closed
  # list: bp's `render.views` is 1/2/4/8 and has no floor and no ceiling, so
  # demanding a :min there would push a maker to invent a number the contract
  # never had. A list bound says what it will accept in `:values` instead.
  REQUIRED_BOUND_KEYS = %i[kind label spec_path type default note bound_source].freeze
  LIST_TYPES = %i[enum enum_list].freeze

  test "every bound carries everything a page needs to render it" do
    PipelineConf::BOUNDS.each do |name, b|
      REQUIRED_BOUND_KEYS.each do |key|
        assert b.key?(key), "#{name}: a bound needs :#{key} — a page renders it, and " \
                           "a missing key is a blank space where the control should be"
      end
      assert_includes PipelineConf::BOUNDS.values.map { |x| x[:kind] }.uniq,
                      b[:kind].to_s, "#{name}: the kind must be one this app knows"
      assert_kind_of Array, b[:spec_path], "#{name}: spec_path is a path into the contract"
      assert b[:spec_path].any?, "#{name}: an empty path addresses nothing"
      assert b[:bound_source].present?,
        "#{name}: a bound must SAY where it came from — an invented bound is a " \
        "request the service will refuse, found at the runner rather than here"

      if LIST_TYPES.include?(b[:type])
        assert b[:values].present?,
          "#{name}: a closed-list bound must carry the values it closes over — " \
          "otherwise it accepts nothing and cannot be rendered as a control"
        refute b.key?(:min) && b.key?(:max),
          "#{name}: a list has no floor or ceiling; give :values, not a range"
      else
        assert b.key?(:min) && b.key?(:max),
          "#{name}: a numeric bound needs :min and :max, or it is not a bound"
        assert_operator b[:min], :<=, b[:max], "#{name}: an inverted bound admits nothing"
      end
    end
  end

  test "every lever a template names is a bound that exists" do
    PipelineConf::TEMPLATES.each do |key, tpl|
      # A template must COMPOSE something: a lever, or a static fragment of its
      # own. `generate_trace_render` carries its content as a step list — there
      # is no number to sweep in a chain — so an empty lever list alone would
      # make it a label, but an empty list beside a fragment does not.
      assert tpl[:levers].any? || tpl[:spec].present?,
        "#{key}: a template with no levers and no fragment is a label"
      tpl[:levers].each do |lever|
        assert PipelineConf::BOUNDS.key?(lever),
          "#{key} names lever #{lever.inspect}, which BOUNDS does not define. A " \
          "missing lever renders as a control that quietly does nothing."
      end
      # And an override can only speak about a lever the template exposes —
      # otherwise the override is a dead value that reads like configuration.
      tpl.fetch(:overrides, {}).each_key do |lever|
        assert_includes tpl[:levers], lever,
          "#{key} overrides #{lever} but does not expose it: the value can never " \
          "reach the contract"
      end
    end
  end

  test "no template restates a range — the bounds are the single copy" do
    PipelineConf::TEMPLATES.each do |key, tpl|
      tpl.fetch(:overrides, {}).each_value do |value|
        refute_kind_of Range, value,
          "#{key}: an override may be a value or a list, never a range. A range " \
          "here would be a second copy of the bound, and the two would drift."
      end
      # The whole point of a template is that the RANGES live in BOUNDS, so a
      # template must not carry :min/:max keys of its own under any guise.
      refute tpl.key?(:bounds),
        "#{key}: :bounds on a template is the second source of truth this design " \
        "exists to avoid. Bounds belong to the pipeline (BOUNDS), not the template."
      refute tpl.key?(:range), "#{key}: see :bounds"
    end
  end

  test "a template's default for a lever is its override or the bound's own" do
    PipelineConf::TEMPLATES.each do |key, tpl|
      tpl.fetch(:levers, []).each do |lever|
        bound = PipelineConf.bound(lever)
        # Blank is a REAL default for several levers — a model with no guidance
        # of its own wants the service's — so nil is compared with assert_nil
        # rather than through assert_equal, which rejects a nil expectation.
        if tpl.fetch(:overrides, {}).key?(lever)
          assert_equal tpl[:overrides][lever], PipelineConf.default_for(key, lever),
            "#{key}/#{lever}: the override wins"
        elsif bound[:default].nil?
          assert_nil PipelineConf.default_for(key, lever),
            "#{key}/#{lever}: blank means the service's own default, and blank is " \
            "the answer — it must not become 0"
        else
          assert_equal bound[:default], PipelineConf.default_for(key, lever),
            "#{key}/#{lever}: with no override the bound's own default is the answer"
        end
      end
    end
  end

  test "every default is inside its own bound" do
    PipelineConf::BOUNDS.each do |name, b|
      # A numeric bound's own sanity first, and it does not touch :default — a
      # lever whose default is BLANK (the service's own) still needs its floor
      # and ceiling to be a real range.
      unless LIST_TYPES.include?(b[:type])
        assert_operator b[:min], :<=, b[:max],
          "#{name}: an inverted bound admits nothing, whatever its default"
      end
      next if b[:default].nil?
      assert PipelineConf.within_bounds?(name, b[:default]),
        "#{name}: the default #{b[:default].inspect} is OUTSIDE its bound, so the " \
        "sane starting point is a request the service refuses"
    end
  end

  test "a lever's numbers are transcribed from the constants they name" do
    # These are the ones that would be a silent lie if they drifted: each is a
    # value this repo already mirrors elsewhere, or a service default quoted
    # verbatim. Compare against the SOURCE constant, not a restatement.
    assert_equal 12, PipelineConf.bound("max_candidates")[:default],
      "trace_sweep.py DEFAULT_SWEEP[\"max_candidates\"] is 12"
    assert_equal [2, 8, 16], PipelineConf.bound("filter_speckle")[:default],
      "trace_sweep.py DEFAULT_SWEEP[\"filter_speckle\"] is [2, 8, 16]"
    assert_equal %w[bw poster photo], PipelineConf.bound("presets")[:values],
      "trace_sweep.py PRESETS is a CLOSED three-name list"
    assert_equal %w[cutout stacked], PipelineConf.bound("hierarchical")[:values]
    assert_equal 6, PipelineConf.bound("max_colors")[:default],
      "spec.example.json ships max_colors 6, and the form's own default was 6"
    assert_equal 300, PipelineConf.bound("dpi")[:default],
      "front_common.py DEFAULT_DPI is 300"
    assert_equal 16, PipelineConf.bound("prep_colors")[:default],
      "front_common.py PRINT_DEFAULTS[\"prep_colors\"] is 16"
    assert_equal 1.5, PipelineConf.bound("min_stroke_width_pt")[:default],
      "spec.example.json geometry.min_stroke_width_pt is 1.5"
    assert_equal 500, PipelineConf.bound("max_nodes_per_path")[:default]

    # chopshop-bp: the studio ALREADY mirrors these in BlenderConf, so the
    # bound must not become a second transcription of them.
    assert_equal BlenderConf::EXTRUDE_DEFAULTS["depth"], PipelineConf.bound("bp_depth")[:default]
    assert_equal BlenderConf::EXTRUDE_DEFAULTS["bevel_depth"], PipelineConf.bound("bp_bevel_depth")[:default]
    assert_equal BlenderConf::VIEW_CHOICES, PipelineConf.bound("bp_views")[:values],
      "views is a CLOSED list in the contract, so the bound is the list and not a range"
    assert_equal BlenderConf::ENGINES, PipelineConf.bound("bp_engine")[:values],
      "the SERVICE's two words — Blender's internal names are not in the contract"
    assert_equal Job::BP_OPS, PipelineConf.bound("bp_op")[:values]

    # chopshop-flux: the dimension floor and the posterize floor.
    assert_equal 64, PipelineConf.bound("flux_width")[:min],
      "config.py MIN_DIMENSION is 64"
    assert_equal 64, PipelineConf.bound("flux_height")[:min]
    # POSTERIZE_MIN_COLORS (8) is a floor on the posterize MODE's argument, not
    # on ink_cap itself — ink_cap is readable on its own, so a :min of 8 would
    # refuse a value the service accepts. The constant is quoted in the copy
    # instead, where it cannot be mistaken for a limit the form enforces.
    assert_equal 1, PipelineConf.bound("flux_ink_cap")[:min],
      "the floor is NOT POSTERIZE_MIN_COLORS — that guards the posterize mode"
    assert_includes PipelineConf.bound("flux_ink_cap")[:note], "8",
      "the service's 8 must still be stated, as copy about the mode"
    assert_includes PipelineConf.bound("flux_ink_cap")[:bound_source], "POSTERIZE_MIN_COLORS"
  end

  test "a closed list is compared by name, so a form's string is accepted" do
    # bp's views are INTEGERS and its operations/engines are STRINGS. A form
    # posts JSON, where every value arrives as a string, so comparing types
    # strictly refuses numbers the service accepts.
    assert PipelineConf.within_bounds?("bp_views", 4)
    assert PipelineConf.within_bounds?("bp_views", "4"),
      "the same value as the string a <select> posts"
    refute PipelineConf.within_bounds?("bp_views", 3),
      "3 is not in VIEW_CHOICES — the list is closed, and a range would have let it through"
    assert PipelineConf.within_bounds?("bp_views", [1, 4])
    refute PipelineConf.within_bounds?("bp_views", [1, 3])

    assert PipelineConf.within_bounds?("bp_engine", "workbench")
    assert PipelineConf.within_bounds?("bp_op", "tree")
    refute PipelineConf.within_bounds?("bp_engine", "BLENDER_WORKBENCH"),
      "Blender's internal name is NOT the contract's word — the service maps them itself"
    refute PipelineConf.within_bounds?("bp_op", "composite")

    assert PipelineConf.within_bounds?("presets", %w[bw poster])
    refute PipelineConf.within_bounds?("presets", %w[bw photo3]),
      "an unknown preset name is what the trace stage refuses on"
  end

  test "numeric bounds reject a value outside them and accept the edges" do
    assert PipelineConf.within_bounds?("max_colors", 2)
    assert PipelineConf.within_bounds?("max_colors", 12)
    refute PipelineConf.within_bounds?("max_colors", 1)
    refute PipelineConf.within_bounds?("max_colors", 13)
    refute PipelineConf.within_bounds?("max_colors", "6"),
      "a numeric bound is not satisfied by a string — the form coerces before asking"
    assert PipelineConf.within_bounds?("max_candidates", 1)
    refute PipelineConf.within_bounds?("filter_speckle", [2, 999])
    refute PipelineConf.within_bounds?("nope", 1), "an unknown lever is not within anything"
  end

  test "clamping pulls a sampled value back inside the bound" do
    # The point of a template being a parameter SPACE: a batch samples a range
    # and gets an answer the service will accept, rather than a refusal.
    assert_equal 12, PipelineConf.clamp("max_colors", 99)
    assert_equal 2, PipelineConf.clamp("max_colors", -5)
    assert_equal 6, PipelineConf.clamp("max_colors", 6)
    assert_equal 600, PipelineConf.clamp("dpi", 10_000),
      "clamped to the CEILING, not to the default — 300 is what an untouched form shows"
    assert_equal 6.0, PipelineConf.clamp("min_stroke_width_pt", 99.0),
      "to the CEILING — 1.5 is the default an untouched form shows, not the limit"
    assert_equal 6, PipelineConf.clamp("max_colors", 6.4),
      "an integer bound rounds rather than passing a float through"
    assert_equal 0.3, PipelineConf.clamp("min_stroke_width_pt", 0.3),
      "a value already inside is returned UNCHANGED — a float bound keeps its " \
      "precision and does not snap to the 0.25 step, because a value off-step " \
      "is still a real value the contract accepts"
    assert_equal 0.25, PipelineConf.clamp("min_stroke_width_pt", 0.01),
      "and only an out-of-range value moves, to the floor"
    assert_equal "nonsense", PipelineConf.clamp("min_stroke_width_pt", "nonsense"),
      "a non-numeric value passes through rather than being clamped to the " \
      "floor: coercing junk to the minimum would invent a value nobody asked for"
    # A closed list is not a range, so clamping has nothing to do and the value
    # passes through untouched rather than being snapped to a neighbour that
    # does not exist.
    assert_equal 3, PipelineConf.clamp("bp_views", 3)
  end

  test "levers come back in BOUNDS order, not in the order the template lists them" do
    names = PipelineConf.lever_names_for("screenprint")
    assert_equal %w[max_colors max_candidates min_stroke_width_pt prep_colors], names
    # Every template's levers are a SUBSEQUENCE of BOUNDS' own order — that is
    # what "in BOUNDS order" means, and it is what makes two templates showing
    # overlapping levers render identically.
    order = PipelineConf::BOUNDS.keys.each_with_index.to_h
    PipelineConf::TEMPLATES.each_key do |key|
      indices = PipelineConf.lever_names_for(key).map { |n| order.fetch(n) }
      assert_equal indices.sort, indices, "#{key}: levers must come back in BOUNDS order"
    end
  end

  test "a template names a RUNNER KIND, and svg is the default kind" do
    assert_equal "svg", PipelineConf.template_kind("standard")
    assert_equal "svg", PipelineConf.template_kind("screenprint")
    assert_equal "flux", PipelineConf.template_kind("generate_only")
    assert_equal "bp", PipelineConf.template_kind("render_3d")
  end

  test "a template's levers belong to its own kind, except the two-stage one" do
    # The kind decides which form PANEL renders a lever, so a lever whose kind
    # disagrees with its template renders a control no panel composes. One
    # template is the deliberate exception: `generate_and_trace` is the
    # generate-then-trace case, so it exposes BOTH halves' levers and both
    # panels have to be on screen. It is named rather than permitted generally,
    # because "one lever of another kind" is otherwise a silent bug.
    SPANNING = %w[generate_and_trace].freeze
    PipelineConf::TEMPLATES.each do |key, tpl|
      kind = PipelineConf.template_kind(key)
      foreign = tpl[:levers].reject { |lever| PipelineConf.bound(lever)[:kind] == kind }
      if SPANNING.include?(key)
        assert foreign.any?, "#{key} is declared as spanning, so it must expose a " \
          "lever of another kind — otherwise the exemption is pointless"
        next
      end
      assert_empty foreign.map { |l| "#{l} (#{PipelineConf.bound(l)[:kind]})" },
        "#{key} is a #{kind} template and must not expose another kind's lever: " \
        "the panel that renders it will never compose it"
    end
  end

  test "the form opens on the General job, not on the ceiling" do
    assert_equal PipelineConf::GROUPS["General"].first, PipelineConf::DEFAULT_TEMPLATE,
      "the default template must be the one the General job-type button applies"
    assert PipelineConf::TEMPLATES.key?(PipelineConf::DEFAULT_TEMPLATE)
    # A person demonstrating basic functionality must never have to know the
    # settings exist. The General job is the smallest shape to be right: no
    # colour budget, no sweep, no gates -- its levers are the GENERATION ones,
    # which is what "generate only" means. Asserting the list rather than
    # "empty": assuming a lever-less default is what made the first version of
    # this test wrong.
    assert_equal %w[flux_variations flux_guidance flux_steps flux_width flux_height],
                 PipelineConf.lever_names_for(PipelineConf::DEFAULT_TEMPLATE),
                 "the General default's levers are the generation ones, in BOUNDS order"
    assert_equal "flux", PipelineConf.template_kind(PipelineConf::DEFAULT_TEMPLATE),
      "and the default is a generation job, which is what the General group's " \
      "first template is"
    # The trace shape this used to open on is still one click away, and it is
    # still the smallest TRACE surface -- assert it where it now lives.
    assert_equal %w[max_colors max_candidates filter_speckle presets hierarchical
                    min_stroke_width_pt],
                 PipelineConf.lever_names_for("standard"),
                 "in BOUNDS order — which is the order the form renders them in"
    PipelineConf::TEMPLATES.each do |key, tpl|
      assert tpl[:label].present?, "#{key}: a template with no label cannot be chosen"
      assert tpl[:blurb].present?,
        "#{key}: the blurb is how an operator picks between templates, so it is " \
        "not decoration — a picker with no copy is a list of words"
    end
  end

  test "static spec fragments are levers' own business and never override one" do
    # `photo` is the one template that relaxes a GATE, and that is a static
    # fact, not a number — so it cannot be a lever and cannot be swept.
    assert_equal({ "geometry" => { "allow_gradients" => true } },
                 PipelineConf.static_spec("photo"))
    assert_empty PipelineConf.static_spec("standard"),
      "a template with no static fragment must say so with an empty hash, not nil"
    # A deep copy: a caller merging the fragment must not be able to write back
    # into the constant, or one request would reconfigure every later one.
    frag = PipelineConf.static_spec("photo")
    frag["geometry"]["allow_gradients"] = false
    assert_equal true, PipelineConf.static_spec("photo")["geometry"]["allow_gradients"],
      "static_spec must hand back a deep copy — the constant is shared state"
    # A fragment MAY sit in a lever's namespace — `generate_only` sets
    # `flux.mode`, which is not a lever at all but a mode the panel already
    # owns. What it may not do is write a path a LEVER also writes, because
    # then the static value silently outranks the number the operator moved.
    # So the rule is against the levers' own paths, not against namespaces.
    lever_paths = PipelineConf::BOUNDS.values.map { |b| b[:spec_path] }
    PipelineConf::TEMPLATES.each do |key, tpl|
      next unless tpl[:spec]
      tpl[:spec].each do |namespace, block|
        # A STEP LIST is a list, not a namespace->leaf map, so the lever-path
        # check below (which is defined on [namespace, leaf] pairs) does not
        # apply to it — and no lever's path is `steps`, so there is nothing for
        # it to shadow either. Everything else must still be an object.
        next if block.is_a?(Array)
        assert_kind_of Hash, block, "#{key}: a fragment's namespace holds an object"
        Array(block.to_h.flat_map { |k, v| [k, v].reject { |x| x.nil? } }).each do |leaf|
          path = [namespace, leaf.to_s]
          assert_not_includes lever_paths, path,
            "#{key}: the fragment writes #{path.inspect}, which is also a LEVER's " \
            "path — the static value would outrank the number the operator set"
        end
      end
    end
  end

  test "an unknown template or lever raises rather than returning nothing" do
    # A silent nil here is a form that renders an empty picker and posts an
    # empty contract, which reads as "the settings do nothing".
    assert_raises(ArgumentError) { PipelineConf.template("no_such_template") }
    assert_raises(ArgumentError) { PipelineConf.bound("no_such_lever") }
    assert_raises(ArgumentError) { PipelineConf.levers_for("no_such_template") }
  end

  test "every kind of lever this app knows is a real runner kind" do
    kinds = PipelineConf::BOUNDS.values.map { |b| b[:kind] }.uniq.sort
    assert_equal %w[bp flux svg], kinds,
      "a bound's kind must be a runner kind Job knows, or no panel will ever render it"
    Job::RUNNER_KINDS.each do |kind|
      next if %w[plot blender].include?(kind) # legacy labels, folded into bp
      assert_includes kinds, kind,
        "#{kind} is a live runner kind with no lever bound — the form cannot " \
        "configure it at all"
    end
  end

  test "the default template's own compose carries no key nothing owns" do
    # The residue bug: the Run Job form seeded its contract from a hand-written
    # literal carrying print_method, a 6-ink palette and geometry.allow_open_paths
    # -- none of which is a lever or a template's static fragment, so
    # remove_decay could never clear them and they survived EVERY switch ("still
    # have screenprint shit here"). The form now opens on this compose, so this
    # is the assertion that keeps the residue out: every top-level key must be
    # one the default template actually owns.
    spec = PipelineConf.compose(PipelineConf::DEFAULT_TEMPLATE, into: {})
    owned = PipelineConf::BOUNDS.values.map { |b| b[:spec_path].first }.uniq +
            PipelineConf.static_spec(PipelineConf::DEFAULT_TEMPLATE).keys
    spec.each_key do |key|
      assert_includes owned, key,
        "#{key.inspect} is not owned by #{PipelineConf::DEFAULT_TEMPLATE}: " \
        "remove_decay cannot clear it, so it would survive every template switch"
    end
    refute spec.key?("print_method"),
      "print_method is not a lever and not a template fragment — it must not be seeded"
    refute spec.key?("palette"),
      "a palette is not a lever — a seeded one leaks into every later template"
  end

  test "every template composes cleanly over the default, with no residue" do
    # The operator-visible shape of the bug: pick any template from the form's
    # opening state and the contract must describe THAT template only.
    base = PipelineConf.compose(PipelineConf::DEFAULT_TEMPLATE, into: {})
    unowned = %w[print_method palette]
    PipelineConf.template_keys.each do |key|
      out = PipelineConf.compose(key, into: base)
      unowned.each do |stray|
        refute out.key?(stray),
          "#{key} composed over the default still carries #{stray}, which no " \
          "template owns — that is the residue the operator reported"
      end
    end
  end

  test "compose clears the levers a NEW template does not expose" do
    # The "adds but never removes" bug: switching standard -> generate_only kept
    # max_colors and print.sweep.* (both trace levers) next to the new flux
    # block, so one contract carried two shapes of work. Applying a template is
    # choosing a SUBSET; the residue of the subset it replaces is cleared.
    standard = PipelineConf.compose("standard", into: {})
    assert standard.key?("max_colors"), "standard exposes max_colors"
    assert standard.dig("print", "sweep", "max_candidates")

    generated = PipelineConf.compose("generate_only", into: standard)
    refute generated.key?("max_colors"), "generate_only does not expose max_colors"
    refute generated.key?("print"), "the whole trace print block is gone"
    refute generated.key?("geometry"), "no trace geometry residue either"
    assert generated.dig("flux", "mode") == "raster", "generate_only's own mode is composed"
    assert_equal 1024, generated.dig("flux", "width")
  end

  test "compose clears another template's static fragment when it no longer owns it" do
    photo = PipelineConf.compose("photo", into: {})
    assert_equal true, photo.dig("geometry", "allow_gradients"), "photo turns gradients on"
    screen = PipelineConf.compose("screenprint", into: photo)
    refute screen.dig("geometry", "allow_gradients"),
      "screenprint owns no allow_gradients, so photo's static fragment is cleared"
  end

  test "compose preserves keys no lever or static fragment points at" do
    base = { "palette" => ["#111111"], "print_method" => "dtg", "print" => { "invert" => true } }
    out = PipelineConf.compose("standard", into: base)
    assert_equal ["#111111"], out["palette"], "a palette is not a lever and survives"
    assert_equal "dtg", out["print_method"]
    assert out.dig("print", "invert"), "a non-lever print sibling survives"
  end
end