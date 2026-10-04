require "test_helper"

# `compose` is the whole feature: a template becomes a spec, the form hydrates
# its panels from that spec, and the operator adjusts from there. So the tests
# are about the shape of the document produced and about not destroying one.
#
# The three failures this file was written after, all found by running the
# composer rather than by reading it:
#
#   1. A symbol-keyed `into:` produced a document with `print` TWICE — the
#      symbol key the caller supplied and the string key the lever path wrote.
#      JSON.generate renders that as the key twice and the runner reads one of
#      them, so a template silently dropped `print.dpi`.
#   2. `deep_dup` alone did not fix it: the copy kept the symbols, so the lookup
#      still missed.
#   3. Without the copy at all, `compose` EDITED the caller's hash — a spec held
#      by a controller would be changed by rendering a page.
class PipelineComposeTest < ActiveSupport::TestCase
  test "compose writes each lever at its own spec path" do
    spec = PipelineConf.compose("standard")
    assert_equal 6, spec["max_colors"]
    assert_equal 12, spec.dig("print", "sweep", "max_candidates")
    assert_equal %w[bw poster photo], spec.dig("print", "sweep", "presets")
    assert_equal 1.5, spec.dig("geometry", "min_stroke_width_pt")
  end

  test "a template's override is what lands, not the bound's default" do
    # screenprint overrides three levers; a template that composed the bound's
    # own defaults would produce a spec indistinguishable from `standard`.
    spec = PipelineConf.compose("screenprint")
    assert_equal 4, spec["max_colors"], "the template's 4, not the bound's 6"
    assert_equal 8, spec.dig("print", "sweep", "max_candidates")
    assert_equal 8, spec.dig("print", "prep_colors")
  end

  test "compose never produces a document with one key twice" do
    # The failure this pins: a symbol-keyed `into:` plus a string-keyed lever
    # path produced `"print"` and `:print` in one hash. JSON.generate renders
    # that as a document carrying the key twice, and the runner reads one.
    spec = PipelineConf.compose(
      "standard",
      into: { print: { dpi: 600, sweep: { max_candidates: 3 } } }
    )
    assert_equal 1, spec.keys.count { |k| k.to_s == "print" },
      "one `print` key — a second one is a document the runner half-reads"
    assert spec.keys.all?(String), "every key is a string: #{spec.keys.inspect}"
    assert_equal 1, spec.dig("print", "sweep").keys.count { |k| k.to_s == "max_candidates" }
  end

  test "compose preserves keys no lever owns and clears stale lever residue" do
    # A template is the operator's CHOSEN subset: keys no lever or static
    # fragment points at (a palette, a substrate, print.invert) survive, while
    # a genuine lever the template does not expose (dpi lives on a bound but is
    # not a `standard` lever) is cleared so switching templates cannot pile one
    # subset on top of another.
    spec = PipelineConf.compose(
      "standard",
      into: { "palette" => ["#000000"], "print" => { "dpi" => 600, "invert" => true } }
    )
    assert_equal ["#000000"], spec["palette"], "an unrelated top-level key survives"
    assert spec.dig("print", "invert"), "a sibling no lever points at survives"
    refute spec.dig("print", "dpi"), "a real lever `standard` does not expose is cleared"
    assert_equal 12, spec.dig("print", "sweep", "max_candidates"), "and the lever still lands"
  end

  test "compose does not edit the spec it was given" do
    # The caller holds this hash — a controller instance variable, a spec parsed
    # out of a draft. Rendering a page that composes a template must not change
    # it, or the same page loaded twice composes a different contract.
    original = { "print" => { "dpi" => 600 } }
    snapshot = Marshal.load(Marshal.dump(original))
    PipelineConf.compose("standard", into: original)
    assert_equal snapshot, original, "compose mutated the caller's spec"
  end

  test "a caller's override beats the template's, and a form value beats both" do
    spec = PipelineConf.compose("standard", overrides: { "max_colors" => 8 })
    assert_equal 8, spec["max_colors"]

    # And the operator's own value survives a re-compose of the SAME template,
    # which is what "a hand-edited template result still wins" means in practice.
    edited = PipelineConf.compose("standard", into: spec, overrides: { "max_colors" => 5 })
    assert_equal 5, edited["max_colors"]
    assert_equal spec["max_colors"], 8, "the earlier spec is untouched"
  end

  test "a blank override does not blank the template's own default" do
    # A form's untouched number input posts "". Writing that as the value would
    # replace a sane default with an empty string, and `Number("")` is 0 — the
    # same trap that made a cleared `filter_speckle` post a sweep axis nobody
    # asked for. Blank means "not set", so the template's answer stands.
    spec = PipelineConf.compose("screenprint", overrides: { "max_colors" => "" })
    assert_equal 4, spec["max_colors"], "blank falls back to the template, not to 0 or nil"
  end

  test "a static fragment lands beside the levers and never over one" do
    # `photo` is the only template that relaxes a GATE, which is a fact and not
    # a number — so it cannot be a lever and cannot be swept.
    spec = PipelineConf.compose("photo")
    assert_equal true, spec.dig("geometry", "allow_gradients")
    assert_equal 8, spec["max_colors"], "the lever beside it still composes"
    assert_equal 0.75, spec.dig("geometry", "min_stroke_width_pt"),
      "a lever INSIDE the same object as the fragment is not clobbered by it"

    # generate_only's fragment sets a MODE, and the flux levers land with it.
    gen = PipelineConf.compose("generate_only")
    assert_equal "raster", gen.dig("flux", "mode")
    assert_equal 1, gen.dig("flux", "images")
    assert_equal 1024, gen.dig("flux", "width")
  end

  test "a lever whose default is blank writes no key at all" do
    # A null in the contract is not "the service's default" — it is an explicit
    # statement that there is no value, and the flux panel treats a blank box as
    # "leave it to the model". So a blank-default lever is omitted entirely.
    spec = PipelineConf.compose("generate_only")
    assert spec["flux"].key?("guidance") == false,
      "guidance is blank by default, so it must be ABSENT, not null"
    assert spec["flux"].key?("steps") == false
    assert spec["flux"].key?("width"), "and a lever with a real default IS written"
  end

  test "composing every template produces a document with no duplicate key" do
    # A blanket sweep, because the duplicate-key failure was silent and per
    # template: one clean compose proves nothing about the other seven.
    PipelineConf::TEMPLATES.each_key do |key|
      spec = PipelineConf.compose(key, into: { "print" => { "dpi" => 300 } })
      assert spec.keys.all?(String), "#{key}: symbol keys #{spec.keys.inspect}"
      dupes = spec.keys.group_by(&:itself).select { |_, v| v.size > 1 }.keys
      assert_empty dupes, "#{key}: duplicate top-level keys #{dupes.inspect}"
      rendered = JSON.generate(spec)
      # And the rendered document must parse back to the same shape — the test
      # that would actually have caught the :print/"print" pair, since that is
      # where it becomes visible to the runner.
      reparsed = JSON.parse(rendered)
      next unless reparsed.key?("print")
      assert_equal 1, reparsed.keys.count { |k| k == "print" },
        "#{key}: the rendered document carries print twice: #{rendered}"
    end
  end

  test "composing twice is idempotent" do
    # A page that composes on load and again on submit must produce the same
    # document; a second pass that reorders a list or appends to one would make
    # the contract depend on how many times the page was opened.
    once = PipelineConf.compose("standard")
    twice = PipelineConf.compose("standard", into: once)
    assert_equal once, twice, "composing an already-composed spec changed it"
  end

  test "a composed spec survives the JSON round trip the form does" do
    # The form parses the textarea and posts it; this is that trip. A key type
    # that survives Ruby but not JSON is a value that reaches the runner changed.
    spec = PipelineConf.compose("screenprint")
    assert_equal spec, JSON.parse(JSON.generate(spec)),
      "string keys all the way down, or the posted contract differs from the composed one"
  end

  test "coerce turns a form's strings into the bound's own type" do
    # Every value a <input> carries arrives as a string, and "8" is not 8 to a
    # contract the runner reads with a number check.
    assert_equal 8, PipelineConf.coerce("max_colors", "8")
    assert_equal 8, PipelineConf.coerce("max_colors", " 8 ")
    assert_equal 1.5, PipelineConf.coerce("min_stroke_width_pt", "1.5")
    assert_equal [2, 8, 16], PipelineConf.coerce("filter_speckle", %w[2 8 16])
    assert_equal [2, 8, 16], PipelineConf.coerce("filter_speckle", "2,8,16"),
      "a comma-separated box is what the sweep control actually posts"
    assert_equal %w[bw poster], PipelineConf.coerce("presets", %w[bw poster])
    assert_equal "workbench", PipelineConf.coerce("bp_engine", "workbench")

    # Blank is nil, NOT 0 — the cleared-numeric-list trap in a different place.
    assert_nil PipelineConf.coerce("max_colors", "")
    assert_nil PipelineConf.coerce("max_colors", nil)

    # Junk is refused rather than coerced to a number: `max_colors: "eight"` is
    # a request the runner refuses, and posting it says nothing about why.
    assert_raises(ArgumentError, TypeError) { PipelineConf.coerce("max_colors", "eight") }
  end

  test "a refused override is reported rather than posted as a lie" do
    # The guardrail a batch depends on: out-of-bounds is caught HERE, where an
    # operator can be told, instead of at the runner after the GPU is paid for.
    assert_not PipelineConf.within_bounds?("max_colors", 99)
    assert_equal 12, PipelineConf.clamp("max_colors", 99),
      "and the clamped value is one the service accepts"
    spec = PipelineConf.compose("standard", overrides: { "max_colors" => 99 })
    assert_equal 99, spec["max_colors"],
      "compose does not silently clamp — clamping is the CALLER's explicit " \
      "choice, so a typo is visible rather than quietly corrected"
  end

  test "an unknown template raises rather than composing nothing" do
    assert_raises(ArgumentError) { PipelineConf.compose("no_such_template") }
    assert_raises(ArgumentError) { PipelineConf.compose("standard", overrides: { "nope" => 1 }) }
  end
end