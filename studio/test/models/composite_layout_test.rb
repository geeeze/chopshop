require "test_helper"

# Sketch: the arrangement half of the composite builder — the constraint
# vocabulary, the templates, and the layout metrics.
#
# WHY THIS FILE IS MOSTLY ABOUT AGREEMENT
#
# The builder snaps in the browser (aether-sketch.js) and arranges, scores and
# reports in Ruby (CompositeLayout). Two implementations of one idea is exactly
# the shape this repo keeps getting bitten by, so the split is deliberate and
# the seam is pinned:
#
#   * the NAMES, the WEIGHTS, EPS and the defaults are one contract, asserted
#     here against the JS source, because a browser that snaps to a margin the
#     server does not know about produces a composite whose reported score
#     contradicts its own picture;
#   * a template's output must SATISFY its own constraints — a plan that emits
#     relations its own numbers violate is worse than no plan, because it reads
#     as working until something moves;
#   * the metrics describe ARRANGEMENT and rank nothing. The pipeline's rule is
#     that no machine picks a winner, and a heuristic over rectangles is still a
#     machine with an opinion — so these say "evenly spaced", never "best".
class CompositeLayoutTest < ActiveSupport::TestCase
  JS = Rails.root.join("app/javascript/aether-sketch.js").read
  FRAME_W = 3000
  FRAME_H = 2000

  # Prose is allowed to name what it replaced, so every assertion about the code
  # strips the comments first — otherwise a comment mentioning a token the test
  # hunts for makes the check pass (or fail) for the wrong reason.
  def code(src)
    src.gsub(%r{//[^\n]*}, "")
  end

  def layer(key, x, y, w, h, links: nil)
    l = { "key" => key, "name" => key, "x" => x, "y" => y, "w" => w, "h" => h,
          "z" => 0, "visible" => true }
    l["links"] = links if links
    l
  end

  def metrics(layers, margin: nil, gap: nil)
    CompositeLayout.metrics(layers: layers, width: FRAME_W, height: FRAME_H,
                            margin: margin, gap: gap)
  end

  def residual(layers, gap: nil)
    CompositeLayout.residual(layers: layers, width: FRAME_W, height: FRAME_H, gap: gap)
  end

  # ---------------------------------------------------------------- agreement

  test "the browser engine and Ruby speak the same constraint vocabulary" do
    body = code(JS)[/var CONSTRAINTS = \{(.*?)\n  \};/m, 1]
    refute_nil body, "the JS registry is gone: the two sides have no shared vocabulary"
    js_names = body.scan(/^    '([a-z-]+)':\s*\{/).flatten.sort
    assert_equal CompositeLayout::NAMES.sort, js_names,
      "a constraint one side knows and the other does not is a relation that " \
      "works in the builder and vanishes from the metrics (or the reverse)"
  end

  test "the axes, the weights and the tolerances are the same numbers" do
    js_weights = code(JS)[/var WEIGHTS = \{(.*?)\n  \};/m, 1]
      .scan(/(\w+):\s*([\d.]+)/)
      .to_h { |k, v| [k, v.to_f] }
    assert_equal CompositeLayout::WEIGHTS.sort.to_h, js_weights.sort.to_h,
      "the blend must match, or the page's score and the API's disagree"

    js_axes = code(JS)[/var CONSTRAINTS = \{(.*?)\n  \};/m, 1].scan(/^    '([a-z-]+)':\s*\{[^}]*?axis: "([xywh])"/m)
    js_axes.each do |name, axis|
      assert_equal CompositeLayout::CONSTRAINT_AXES[name], axis,
        "#{name} writes #{CompositeLayout::CONSTRAINT_AXES[name]} in Ruby and #{axis} in JS"
    end

    assert_match(/var EPS = #{CompositeLayout::EPS};/, code(JS), "one epsilon, or one side calls it satisfied")
    assert_match(/var RELAX_MAX = #{CompositeLayout::RELAX_MAX};/, code(JS),
      "the relaxation cap is what stops an unsatisfiable cycle spinning")
    assert_match(/var DEFAULT_MARGIN = #{CompositeLayout::DEFAULT_MARGIN};/, code(JS))
    assert_match(/var DEFAULT_GAP = #{CompositeLayout::DEFAULT_GAP};/, code(JS))
  end

  test "every constraint can report an error, and the error is zero when it holds" do
    ctx = CompositeLayout.frame(width: FRAME_W, height: FRAME_H)
    a = layer("a", 200, 150, 800, 600)
    b = layer("b", 200, 900, 800, 600)
    CompositeLayout::NAMES.each do |how|
      e = CompositeLayout.error(how, a, b, ctx)
      assert_kind_of Numeric, e, "#{how} yields no scalar: not a constraint"
      assert e.finite?, "#{how} yields #{e}"
    end

    # The coincidences, each satisfied exactly, report zero — the definition of
    # a constraint in the original is a scalar that SHOULD be zero, so the test
    # is that it is.
    twin = layer("twin", 200, 150, 800, 600)
    %w[align-left align-right align-center-x align-top align-bottom align-center-y
       same-width same-height same-size touch-x touch-y].each do |how|
      # touch-x/touch-y are edge-to-edge relations, so they hold at a different
      # offset; the coincidences hold at an identical rectangle.
      next if how.start_with?("touch")

      assert_equal 0.0, CompositeLayout.error(how, twin, a, ctx), "#{how} should hold"
    end
    assert_equal(-800.0, CompositeLayout.error("touch-x", twin, a, ctx))
  end

  test "the residual reports the worst unsatisfied scalar, and a dangling link is not a residual" do
    margin = CompositeLayout.frame(width: FRAME_W, height: FRAME_H)["margin"]
    good = [layer("a", margin, 400, 400, 300, links: [{ "how" => "margin-left", "to" => "canvas" }])]
    assert_equal 0.0, residual(good, gap: 0), "a layer ON the margin satisfies its own constraint"

    off = [layer("a", margin + 140, 400, 400, 300, links: [{ "how" => "margin-left", "to" => "canvas" }])]
    assert_equal 140.0, residual(off), "the scalar IS the distance still to travel"

    dangling = [layer("a", 900, 400, 400, 300, links: [{ "how" => "align-left", "to" => "gone" }])]
    assert_equal 0.0, residual(dangling),
      "a relation to a layer that no longer exists cannot be satisfied and is " \
      "not a number: reporting it would make a deleted layer look like a " \
      "broken composite for ever"
  end

  # ------------------------------------------------------------------ metrics

  test "alignment counts agreeing edges and centres across pairs" do
    tidy = [layer("a", 500, 400, 400, 300), layer("b", 500, 900, 400, 300)]
    assert_equal 1.0, metrics(tidy)["alignment"], "two layers sharing both x and y agree"

    ragged = [layer("a", 500, 400, 400, 300), layer("b", 573, 861, 380, 290)]
    assert_equal 0.0, metrics(ragged)["alignment"], "nothing coincides"

    single = [layer("a", 500, 400, 400, 300)]
    assert_equal 1.0, metrics(single)["alignment"],
      "one layer has no pairs to disagree with: answering 0 would punish an " \
      "empty composition for something it cannot control"
  end

  test "spacing scores even gaps and how ragged gaps score worse" do
    even = [layer("a", 0, 0, 100, 100), layer("b", 150, 0, 100, 100), layer("c", 300, 0, 100, 100)]
    assert_equal 1.0, metrics(even, gap: 50)["spacing_x"]

    ragged = [layer("a", 0, 0, 100, 100), layer("b", 120, 0, 100, 100), layer("c", 700, 0, 100, 100)]
    assert_operator metrics(ragged)["spacing_x"], :<, 0.75, "a 220px hole is not an even row"

    two = [layer("a", 0, 0, 100, 100), layer("b", 150, 0, 100, 100)]
    assert_equal 1.0, metrics(two)["spacing_x"],
      "two layers are one gap: a single interval has no regularity to score"
  end

  test "a grid is evenly spaced, not ragged: two layers in one column are not a gap" do
    # A 2x2 layout: x-centres are 250, 250, 650, 650. Sorted by centre that reads
    # as gaps 0, 400, 0 — which would score a perfectly regular grid as ragged,
    # and did until the shared centres were collapsed.
    grid = [layer("a", 100, 100, 300, 300), layer("b", 500, 100, 300, 300),
            layer("c", 100, 500, 300, 300), layer("d", 500, 500, 300, 300)]
    m = metrics(grid, gap: 100)
    assert_equal 1.0, m["spacing_x"]
    assert_equal 1.0, m["spacing_y"]

    # And a genuine irregularity still shows up: four in a row with the last one
    # pushed away.
    line = [layer("a", 0, 0, 100, 100), layer("b", 150, 0, 100, 100),
            layer("c", 300, 0, 100, 100), layer("d", 560, 0, 100, 100)]
    assert_operator metrics(line)["spacing_x"], :<, 0.9,
      "four distinct positions with one gap out of line is not even"
  end

  test "a layer off the canvas scores the frame at zero rather than nearly there" do
    inside = [layer("a", 150, 150, 500, 400)]
    assert_equal 1.0, metrics(inside, margin: 150)["frame"]

    bleeding = [layer("a", -40, 150, 500, 400)]
    assert_equal 0.0, metrics(bleeding, margin: 150)["frame"],
      "the print is what it is: a layer hanging off the edge is not 90% right"
  end

  test "coupling is the share of layers that DECLARE a relation" do
    loose = [layer("a", 0, 0, 100, 100), layer("b", 200, 0, 100, 100)]
    assert_equal 0.0, metrics(loose)["coupling"]

    coupled = [layer("a", 0, 0, 100, 100, links: [{ "how" => "margin-left", "to" => "canvas" }]),
               layer("b", 200, 0, 100, 100, links: [{ "how" => "space-x", "to" => "a" }])]
    m = metrics(coupled)
    assert_equal 1.0, m["coupling"]
    assert_equal 2, m["links"]
  end

  test "the score is the weighted blend of the five, in one table" do
    layers = [layer("a", 0, 0, 100, 100, links: [{ "how" => "margin-left", "to" => "canvas" }]),
              layer("b", 150, 0, 100, 100, links: [{ "how" => "space-x", "to" => "a" }]),
              layer("c", 300, 0, 100, 100, links: [{ "how" => "space-x", "to" => "b" }])]
    m = metrics(layers, gap: 50)
    expected = CompositeLayout::WEIGHTS.sum do |key, weight|
      weight * m[key]
    end
    assert_in_delta expected.round(3), m["score"], 0.001
    assert_in_delta 1.0, CompositeLayout::WEIGHTS.values.sum, 0.0001,
      "the weights are a blend, so they have to sum to one"
  end

  test "overlap is reported and is deliberately not part of the score" do
    stacked = [layer("a", 100, 100, 400, 400), layer("b", 200, 200, 400, 400)]
    moved = [layer("a", 100, 100, 400, 400), layer("b", 900, 900, 400, 400)]
    assert_operator metrics(stacked)["overlap"], :>, 0.0, "the overlap is measured"
    assert_equal 0.0, metrics(moved)["overlap"]
    refute CompositeLayout::WEIGHTS.key?("overlap"),
      "a collage overlaps on purpose: scoring it would be the heuristic telling " \
      "the operator what to make, which is the rule this whole system holds to"
  end

  # ---------------------------------------------------------------- templates

  test "every template arranges and the arrangement satisfies its own constraints" do
    CompositeLayout::TEMPLATES.each do |template|
      layers = (1..5).map { |i| layer("l#{i}", i * 7, i * 11, 300 + i, 200 + i) }
      result = CompositeLayout.place(layers: layers, template: template,
                                     width: FRAME_W, height: FRAME_H)
      placed = result["layers"]
      assert_equal 5, placed.length, "#{template} lost or invented a layer"
      assert_equal 5, result["placed"], "#{template} did not place every visible layer"

      # The relations a template emits must HOLD on the numbers it just wrote,
      # or the first drag pops the arrangement apart in front of the operator.
      # A whole pixel of slack is allowed: the plans round to composite pixels.
      r = CompositeLayout.residual(layers: placed, width: FRAME_W, height: FRAME_H)
      assert_operator r, :<=, 1.0,
        "#{template} violates its own constraints by #{r}px: #{placed.map { |l| l["links"] }.inspect}"
      assert placed.all? { |l| l["links"].is_a?(Array) && l["links"].any? },
        "#{template} left a layer uncoupled: nothing would move it again"
    end
  end

  test "no template links a layer to itself and none references a missing layer" do
    CompositeLayout::TEMPLATES.each do |template|
      layers = (1..6).map { |i| layer("l#{i}", 0, 0, 300, 200) }
      placed = CompositeLayout.place(layers: layers, template: template,
                                     width: FRAME_W, height: FRAME_H)["layers"]
      keys = placed.map { |l| l["key"] }
      placed.each do |l|
        l["links"].each do |k|
          refute_equal l["key"], k["to"], "#{template}: #{l["key"]} constrains itself"
          next if k["to"] == "canvas"

          assert_includes keys, k["to"], "#{template}: #{l["key"]} points at a layer that is not there"
        end
      end
    end
  end

  test "a hidden layer is not arranged, and keeps its own geometry" do
    layers = [layer("a", 10, 20, 300, 200),
              layer("b", 40, 50, 300, 200).merge("visible" => false),
              layer("c", 70, 80, 300, 200)]
    placed = CompositeLayout.place(layers: layers, template: "grid",
                                   width: FRAME_W, height: FRAME_H)["layers"]
    by_key = placed.to_h { |l| [l["key"], l] }
    hidden = by_key["b"]
    assert_equal [40, 50], [hidden["x"], hidden["y"]],
      "a template arranges what is in the picture; moving a hidden layer would " \
      "be arranging something the operator cannot see"
    assert_nil hidden["links"], "and it is not coupled either"
    refute_equal [10, 20], [by_key["a"]["x"], by_key["a"]["y"]],
      "the visible layers did move — the hidden one is the exception, not the rule"
    refute_equal [70, 80], [by_key["c"]["x"], by_key["c"]["y"]]
  end

  test "an unknown template is refused with the names, not applied as nothing" do
    result = CompositeLayout.place(layers: [layer("a", 0, 0, 100, 100)], template: "spiral",
                                   width: FRAME_W, height: FRAME_H)
    assert_equal "unknown template", result["error"]
    assert_equal CompositeLayout::TEMPLATES.sort, result["templates"].sort
  end

  test "the grid templates the arrangement the recipe keeps asking for: equal cells, even gaps" do
    layers = (1..4).map { |i| layer("l#{i}", 0, 0, 100, 100) }
    ctx = CompositeLayout.frame(width: 2000, height: 2000, margin: 100, gap: 50)
    placed = CompositeLayout.place(layers: layers, template: "grid",
                                   width: 2000, height: 2000, margin: 100, gap: 50)["layers"]

    widths = placed.map { |l| l["w"] }.uniq
    heights = placed.map { |l| l["h"] }.uniq
    assert_equal 1, widths.length, "every cell is the same width"
    assert_equal 1, heights.length, "every cell is the same height"
    # 2x2 in a 2000px frame, 100px margins, 50px gap: (2000-200-50)/2 = 875.
    assert_equal 875, widths.first
    xs = placed.map { |l| l["x"] }.sort
    assert_equal [100, 1025], xs.uniq
    assert_equal 50, xs.last - (xs.first + widths.first), "the gap is the gap we asked for"
    assert_equal 0.0, CompositeLayout.residual(layers: placed, width: 2000, height: 2000,
                                               margin: 100, gap: 50)
    assert ctx["margin"] == 100 && ctx["gap"] == 50
  end

  test "the mirror template keeps one relation rather than two placements" do
    layers = [layer("left", 0, 0, 100, 100), layer("right", 0, 0, 100, 100)]
    placed = CompositeLayout.place(layers: layers, template: "mirror",
                                   width: 1000, height: 1000, margin: 50, gap: 20)["layers"]
    by_key = placed.to_h { |l| [l["key"], l] }
    right = by_key["right"]
    assert_includes right["links"].map { |k| k["how"] }, "mirror-x",
      "the pair is held by symmetry, not by two coordinates that happen to agree"
    assert_equal 1000 - by_key["left"]["x"] - right["w"], right["x"]
    assert_equal 0.0, CompositeLayout.residual(layers: placed, width: 1000, height: 1000)
  end

  test "the thirds template is compositional, not equal cells" do
    layers = (1..3).map { |i| layer("l#{i}", 0, 0, 100, 100) }
    placed = CompositeLayout.place(layers: layers, template: "thirds",
                                   width: 3000, height: 2000, margin: 150, gap: 60)["layers"]
    by_key = placed.to_h { |l| [l["key"], l] }
    assert_includes by_key["l1"]["links"].map { |k| k["how"] }, "margin-left"
    assert_includes by_key["l2"]["links"].map { |k| k["how"] }, "centred-x"
    assert_includes by_key["l3"]["links"].map { |k| k["how"] }, "margin-right"
    assert_equal 1500 - by_key["l2"]["w"] / 2, by_key["l2"]["x"], "the centre is the centre"
  end

  test "a layer list with no keys gets them, so a template's references resolve" do
    # The builder mints keys in the browser, so a composite an agent assembled
    # has none — and a plan over such a list emitted links with a null target,
    # which reported as a satisfied arrangement because a dangling link is not a
    # residual. Measured on the live fleet: 32 keyless layers, 32 null links.
    keyless = (1..3).map do |i|
      { "name" => "layer #{i}", "x" => i * 10, "y" => i * 10, "w" => 300, "h" => 200,
        "z" => i, "visible" => true }
    end
    result = CompositeLayout.place(layers: keyless, template: "row",
                                   width: FRAME_W, height: FRAME_H)
    placed = result["layers"]
    keys = placed.map { |l| l["key"] }
    assert_equal keys.compact.length, keys.length, "every layer got a key"
    assert_equal keys.uniq.length, keys.length, "and no two share one"
    placed.each do |l|
      l["links"].each do |k|
        next if k["to"] == "canvas"

        assert_includes keys, k["to"], "the link points at a layer that exists"
      end
    end
    assert_equal 0.0, CompositeLayout.residual(layers: placed, width: FRAME_W, height: FRAME_H)

    # An existing key is left exactly as it is.
    kept = CompositeLayout.place(layers: [layer("mine", 0, 0, 100, 100),
                                          { "name" => "anon", "x" => 0, "y" => 0, "w" => 100, "h" => 100,
                                            "z" => 1, "visible" => true }],
                                 template: "row", width: FRAME_W, height: FRAME_H)["layers"]
    assert_equal "mine", kept.first["key"]
  end

  # ------------------------------------------------------- the model + the seam

  test "a composite reports the same metrics its layers were scored with" do
    centre = FRAME_W / 2 - 200
    c = Composite.new(name: "seam", width: FRAME_W, height: FRAME_H,
                      background: "transparent",
                      layers: [layer("a", centre, 400, 400, 300, links: [{ "how" => "centred-x", "to" => "canvas" }]),
                               layer("b", centre, 900, 400, 300, links: [{ "how" => "align-left", "to" => "a" }])])
    assert_equal CompositeLayout.metrics(layers: c.layers, width: FRAME_W, height: FRAME_H),
                 c.layout_metrics
    assert_equal 2, c.layout_links.length
    assert_equal "centred-x", c.layout_links.first["how"]
    assert c.layout_links.first["doc"].present?, "every reported relation explains itself"
    assert_equal 0.0, c.layout_residual, "both relations hold"
  end

  test "engine metrics report the arrangement signal alongside the counts" do
    signal = EngineMetrics.composite_signal
    assert signal.key?(:count)
    assert signal.key?(:mean_score)
    assert signal.key?(:coupled_share)
    assert_operator signal[:coupled_share], :>=, 0.0
    assert_operator signal[:coupled_share], :<=, 1.0
    # It is the same scoring the API serves, aggregated — not a second opinion.
    assert_equal EngineMetrics.metrics[:composites][:count], signal[:count]
  end

  # The bucket that carries a null mean_score is its own case: rounding nil
  # raises, and an empty fleet is the state a fresh box is in.
  test "journaling: the aggregate survives a fleet with no composites" do
    assert_equal 0, EngineMetrics.composite_signal[:count]
    assert_nil EngineMetrics.composite_signal[:mean_score]
    assert_equal 0.0, EngineMetrics.composite_signal[:coupled_share]
  end
end
