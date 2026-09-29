# Sketch: the arrangement half of the composite builder.
#
# WHERE THIS COMES FROM
#
# Ivan Sutherland's Sketchpad (MIT, 1963) is the ancestor of every editor that
# snaps and every CAD tool that solves constraints, and its own write-up draws
# the line this file is built on: an early version let lines be drawn parallel
# or perpendicular to existing lines "but carried no permanent trace of the
# relationship other than the accident of their position". He treated that as a
# deficiency. So there are two halves, and they are different things:
#
#   * SNAPPING is the strong condition — the T-square. It helps while you drag
#     and leaves nothing behind. That half is in `aether-sketch.js`, in the
#     browser, because it has to answer inside a pointer drag.
#   * A CONSTRAINT is "a subroutine yielding a scalar that should be zero",
#     solved by the one-pass method and, where the graph has a cycle, by
#     relaxation. Applying one is COUPLING: the relation outlives the drag.
#
# This class is the Ruby face of both: the arrangement TEMPLATES (a composition
# built without dragging anything, so an agent can lay one out) and the METRICS
# (the numbers the ML/heuristic side reads). It exists as a Ruby mirror of the
# JS registry rather than a second definition of it — the NAMES, the weights and
# the tolerance are a contract between the two, pinned by
# `test/models/composite_layout_test.rb`. Change one side alone and that test
# fails, which is the point: a browser that snaps to a margin the server does
# not know about is a composite whose score disagrees with its picture.
#
# WHAT IS NOT PORTED, and why (the same list the JS module carries):
# perpendicular/parallel are automatically true of an axis-aligned box, so they
# constrain nothing; point-on-line and point-on-circle have no points, lines or
# circles to attach to (their box equivalent is `touch-x`/`touch-y`); and
# `upright` is guaranteed because a layer has no rotation to take.
class CompositeLayout
  EPS = 0.5                 # composite px: a scalar inside this is satisfied
  RELAX_MAX = 40            # the cycle fallback's pass cap
  DEFAULT_MARGIN = 0.05
  DEFAULT_GAP = 0.02

  CONSTRAINT_DOCS = {
    "align-left" => "two left edges share an x",
    "align-right" => "two right edges share an x",
    "align-center-x" => "two vertical centres share an x",
    "align-top" => "two top edges share a y",
    "align-bottom" => "two bottom edges share a y",
    "align-center-y" => "two horizontal centres share a y",
    "same-width" => "two layers are the same width",
    "same-height" => "two layers are the same height",
    "same-size" => "two layers are the same width and height",
    "space-x" => "a fixed horizontal gap follows the other layer",
    "space-y" => "a fixed vertical gap follows the other layer",
    "touch-x" => "this left edge sits on the other right edge",
    "touch-y" => "this top edge sits on the other bottom edge",
    "margin-left" => "held off the left frame edge",
    "margin-top" => "held off the top frame edge",
    "margin-right" => "held off the right frame edge",
    "margin-bottom" => "held off the bottom frame edge",
    "centred-x" => "centred on the vertical axis of the frame",
    "centred-y" => "centred on the horizontal axis of the frame",
    "mirror-x" => "mirrored about the vertical centre of the frame",
    "mirror-y" => "mirrored about the horizontal centre of the frame"
  }.freeze

  # The fields a constraint writes. The one-pass solve needs this to know which
  # layer yields to which — the same reason the JS registry carries `axis`.
  CONSTRAINT_AXES = {
    "align-left" => "x", "align-right" => "x", "align-center-x" => "x",
    "align-top" => "y", "align-bottom" => "y", "align-center-y" => "y",
    "same-width" => "w", "same-height" => "h", "same-size" => "w",
    "space-x" => "x", "space-y" => "y",
    "touch-x" => "x", "touch-y" => "y",
    "margin-left" => "x", "margin-right" => "x",
    "margin-top" => "y", "margin-bottom" => "y",
    "centred-x" => "x", "centred-y" => "y",
    "mirror-x" => "x", "mirror-y" => "y"
  }.freeze

  NAMES = CONSTRAINT_DOCS.keys.freeze

  # The metric blend, as one table. Identical to `WEIGHTS` in aether-sketch.js —
  # see the class comment for why that is pinned rather than trusted.
  WEIGHTS = {
    "alignment" => 0.30,
    "spacing" => 0.20,
    "frame" => 0.15,
    "balance" => 0.15,
    "coupling" => 0.20
  }.freeze

  # ------------------------------------------------------------------ the frame

  # The frame a constraint may attach to, shared by the templates and the
  # metrics so a template's margin IS the margin a later drag snaps to.
  def self.frame(width:, height:, margin: nil, gap: nil)
    width = width.to_f
    height = height.to_f
    # The SHORT SIDE, floored at 1 so a degenerate frame cannot divide by zero.
    # Written as a max-of-min rather than folding 1.0 into the min list, which
    # would make the short side 1.0 for every real frame and collapse the
    # default margin and gap to zero — a silent, universal zero.
    short = [[width, height].min, 1.0].max
    # Rounded to whole composite pixels, because that is the unit the builder
    # stores and the geometry is integer everywhere. A margin of 12.5 kept as a
    # float would make every constraint derived from it report a half-pixel
    # residual for ever — noise that reads as a broken constraint.
    {
      "width" => width,
      "height" => height,
      "margin" => (margin ? margin.to_f.round : (short * DEFAULT_MARGIN).round).to_f,
      "gap" => (gap ? gap.to_f.round : (short * DEFAULT_GAP).round).to_f
    }
  end

  # ------------------------------------------------------------------ metrics

  # #composite-layout-metrics
  #
  # The numbers an agent (or the ML side) reads about an ARRANGEMENT. They
  # describe how the pieces sit and deliberately do not rank the picture: the
  # pipeline's rule is that nothing picks a winner, and that rule does not stop
  # applying because the pieces are rectangles.
  def self.metrics(layers:, width:, height:, margin: nil, gap: nil)
    ctx = frame(width: width, height: height, margin: margin, gap: gap)
    list = visible(layers)
    links = list.sum { |l| links(l).length }

    spacing_x = spacing_score(list, "x")
    spacing_y = spacing_score(list, "y")
    m = {
      "layers" => list.length,
      "links" => links,
      "alignment" => round3(alignment_score(list)),
      "spacing_x" => round3(spacing_x),
      "spacing_y" => round3(spacing_y),
      "frame" => round3(frame_score(list, ctx)),
      "balance" => round3(balance_score(list, ctx)),
      "coupling" => round3(coupling_score(list)),
      "coverage" => round3(coverage(list, ctx)),
      "overlap" => round3(mean_overlap(list))
    }
    m["spacing"] = round3((m["spacing_x"] + m["spacing_y"]) / 2.0)
    m["score"] = round3(WEIGHTS.sum { |k, w| w * m[k] })
    m
  end

  # A constraint that cannot be satisfied should say so, not settle quietly.
  # Reported for the stored layers, which is what makes "this composite is
  # over-constrained" a number rather than an opinion.
  def self.residual(layers:, width:, height:, margin: nil, gap: nil)
    ctx = frame(width: width, height: height, margin: margin, gap: gap)
    by_key = index(layers)
    worst = 0.0
    layers.each do |l|
      links(l).each do |k|
        next unless NAMES.include?(k["how"])
        other = k["to"].to_s == "canvas" ? nil : by_key[k["to"]]
        next if k["to"].to_s != "canvas" && other.nil?
        e = error(k["how"], l, other, ctx).abs
        worst = e if e > worst
      end
    end
    round3(worst)
  end

  # ------------------------------------------------------------------ templates

  # #composite-layout-templates
  #
  # "If not manually, then through templating": each template states an
  # arrangement as a named pattern and emits it WITH ITS CONSTRAINTS, so the
  # result is coupled rather than merely nudged into place. That distinction is
  # the same one the class opens with — a template that only wrote coordinates
  # would be a very large snap, and the first drag would destroy it.
  #
  # `grid` is Sketchpad's repetitive structure (its array/instance example);
  # `mirror` is its symmetry example, kept as symmetry rather than as two
  # independently placed halves; `thirds` is the compositional one, and the
  # reason it exists is that "equal cells" and "a pleasing asymmetry" are
  # different intentions.
  TEMPLATES = %w[grid stack row hero thirds mirror].freeze

  def self.place(layers:, template:, width:, height:, margin: nil, gap: nil)
    name = template.to_s
    return { "error" => "unknown template", "templates" => TEMPLATES } unless TEMPLATES.include?(name)

    ctx = frame(width: width, height: height, margin: margin, gap: gap)
    list = visible(layers)
    return { "template" => name, "layers" => layers, "placed" => 0,
             "note" => "no visible layers to arrange" } if list.empty?

    plan = send("plan_#{name}", list, ctx)
    arranged = apply_plan(layers, plan, list)
    { "template" => name,
      "layers" => arranged,
      "placed" => plan.length,
      "frame" => ctx,
      "metrics" => metrics(layers: arranged, width: ctx["width"], height: ctx["height"],
                           margin: ctx["margin"], gap: ctx["gap"]) }
  end

  # Equal cells, filled left to right. row-major order is the operator's own z
  # order, so a template never reshuffles what they already stacked.
  def self.plan_grid(list, ctx)
    cols = Math.sqrt(list.length).ceil
    cols = 1 if cols < 1
    rows = (list.length.to_f / cols).ceil
    usable_w = ctx["width"] - 2 * ctx["margin"]
    usable_h = ctx["height"] - 2 * ctx["margin"]
    # The CELL is rounded once, then every position is derived from the rounded
    # value. Rounding each position independently instead would leave the
    # accumulated drift between them, so a six-column grid would report a
    # couple of pixels of unsatisfied gap — a constraint that looks broken while
    # the picture looks right, which is the worst of both.
    cell_w = ((usable_w - (cols - 1) * ctx["gap"]) / cols).round
    cell_h = ((usable_h - (rows - 1) * ctx["gap"]) / rows).round

    list.each_with_index.map do |layer, i|
      col = i % cols
      row = i / cols
      placement = {
        "key" => layer["key"],
        "x" => (ctx["margin"] + col * (cell_w + ctx["gap"])).round,
        "y" => (ctx["margin"] + row * (cell_h + ctx["gap"])).round,
        "w" => cell_w,
        "h" => cell_h,
        "links" => []
      }
      # The chain that makes it a grid rather than a set of rectangles: every
      # column hangs off the first row and every row off the first column, with
      # the gap itself locked.
      placement["links"] << { "how" => "space-x", "to" => list[i - 1]["key"] } if col.positive?
      placement["links"] << { "how" => "space-y", "to" => list[i - cols]["key"] } if row.positive?
      placement["links"] << { "how" => "align-top", "to" => list[row * cols]["key"] } if col.positive?
      placement["links"] << { "how" => "align-left", "to" => list[col]["key"] } if row.positive? && col < list.length
      if i.zero?
        placement["links"] << { "how" => "margin-left", "to" => "canvas" }
        placement["links"] << { "how" => "margin-top", "to" => "canvas" }
      end
      placement
    end
  end

  # One column, full width, equal bands.
  def self.plan_stack(list, ctx)
    n = list.length
    usable_h = ctx["height"] - 2 * ctx["margin"]
    usable_w = ctx["width"] - 2 * ctx["margin"]
    band = ((usable_h - (n - 1) * ctx["gap"]) / n).round
    list.each_with_index.map do |layer, i|
      {
        "key" => layer["key"],
        "x" => ctx["margin"].round,
        "y" => (ctx["margin"] + i * (band + ctx["gap"])).round,
        "w" => usable_w.round,
        "h" => band.round,
        "links" => stack_links(list, i, "space-y", i.zero?)
      }
    end
  end

  # One row, equal bands across.
  def self.plan_row(list, ctx)
    n = list.length
    usable_w = ctx["width"] - 2 * ctx["margin"]
    usable_h = ctx["height"] - 2 * ctx["margin"]
    band = ((usable_w - (n - 1) * ctx["gap"]) / n).round
    list.each_with_index.map do |layer, i|
      {
        "key" => layer["key"],
        "x" => (ctx["margin"] + i * (band + ctx["gap"])).round,
        "y" => ctx["margin"].round,
        "w" => band,
        "h" => usable_h.round,
        "links" => stack_links(list, i, "space-x", i.zero?)
      }
    end
  end

  # A dominant piece above a supporting row: the composition shape the print
  # work keeps reaching for, and the one a grid cannot express.
  def self.plan_hero(list, ctx)
    hero = list.first
    rest = list[1..] || []
    usable_w = ctx["width"] - 2 * ctx["margin"]
    usable_h = ctx["height"] - 2 * ctx["margin"]
    hero_h = (usable_h * 0.6).round
    row_h = (usable_h - hero_h - ctx["gap"]).round
    band = rest.empty? ? 0 : ((usable_w - (rest.length - 1) * ctx["gap"]) / rest.length).round

    placements = [{
      "key" => hero["key"],
      "x" => ctx["margin"].round,
      "y" => ctx["margin"].round,
      "w" => usable_w.round,
      "h" => hero_h,
      # The hero OWNS the frame: its left and top are the margins everything
      # else is measured from.
      "links" => [{ "how" => "margin-left", "to" => "canvas" },
                  { "how" => "margin-top", "to" => "canvas" }]
    }]
    rest.each_with_index do |layer, i|
      links = [{ "how" => "space-y", "to" => hero["key"] }]
      # Never a link to ITSELF: a self-link is a cycle, and the solver would drop
      # a one-pass graph into relaxation over a relation that says nothing.
      links << { "how" => "same-height", "to" => rest.first["key"] } if i.positive?
      links << { "how" => "space-x", "to" => rest[i - 1]["key"] } if i.positive?
      links << { "how" => "margin-left", "to" => "canvas" } if i.zero?
      links << { "how" => "margin-right", "to" => "canvas" } if i == rest.length - 1
      placements << {
        "key" => layer["key"],
        "x" => (ctx["margin"] + i * (band + ctx["gap"])).round,
        "y" => (ctx["margin"] + hero_h + ctx["gap"]).round,
        "w" => band,
        "h" => row_h,
        "links" => links
      }
    end
    placements
  end

  # Left third, centre, right third — the compositional placement, and the one
  # that shows why templates are not all "equal cells". Layer four onward stacks
  # down from the centre line.
  def self.plan_thirds(list, ctx)
    usable_w = ctx["width"] - 2 * ctx["margin"]
    usable_h = ctx["height"] - 2 * ctx["margin"]
    cell_w = ((usable_w - 2 * ctx["gap"]) / 3.0).round
    cell_h = (usable_h * 0.45).round
    anchors = ["margin-left", "centred-x", "margin-right"]

    list.each_with_index.map do |layer, i|
      slot = i % 3
      row = i / 3
      x = case slot
          when 0 then ctx["margin"]
          when 1 then (ctx["width"] / 2 - cell_w / 2).round
          else ctx["margin"] + usable_w - cell_w
          end
      links = [{ "how" => anchors[slot], "to" => "canvas" }]
      links << { "how" => "space-y", "to" => list[i - 3]["key"] } if row.positive?
      links << { "how" => "same-width", "to" => list[slot]["key"] } if i >= 3
      # NO align-top to the first row here: in a column-major placement the row is
      # defined by the space-y chain, and aligning row two to row one would drag
      # every layer below the first back up to the top of the canvas (measured:
      # 850px of unsatisfied constraint, which is what a template this wrong
      # looks like from the outside).
      {
        "key" => layer["key"],
        "x" => x.round,
        "y" => (ctx["margin"] + row * (cell_h + ctx["gap"])).round,
        "w" => cell_w,
        "h" => cell_h,
        "links" => links
      }
    end
  end

  # Symmetry about the vertical centre. Sketchpad's artistic-drawing example:
  # the pair keeps ONE relation, so moving the left half moves the right.
  def self.plan_mirror(list, ctx)
    usable_w = ctx["width"] - 2 * ctx["margin"]
    usable_h = ctx["height"] - 2 * ctx["margin"]
    half = (list.length / 2.0).ceil
    cell_w = ((usable_w - ctx["gap"]) / 2.0).round
    cell_h = ((usable_h - (half - 1) * ctx["gap"]) / half).round

    list.each_with_index.map do |layer, i|
      if i < half
        {
          "key" => layer["key"],
          "x" => ctx["margin"].round,
          "y" => (ctx["margin"] + i * (cell_h + ctx["gap"])).round,
          "w" => cell_w,
          "h" => cell_h,
          "links" => [{ "how" => "margin-left", "to" => "canvas" }] +
                     (i.positive? ? [{ "how" => "space-y", "to" => list[i - 1]["key"] }] : [])
        }
      else
        partner = list[i - half]
        {
          "key" => layer["key"],
          # Placed where the mirror puts it, and then HELD there: the coordinate
          # is the template's, the relation is the composite's.
          #
          # The partner's PLACED x is used, never its incoming one: the left half
          # has already been arranged by the branch above, so reading the value
          # the operator happened to have is what would put the reflected half
          # somewhere the reflection does not reach.
          "x" => (ctx["width"] - ctx["margin"] - cell_w).round,
          # Same reasoning for y: the reflection is BESIDE its partner, which is
          # the row the left half was just placed in, not the row it arrived in.
          "y" => (ctx["margin"] + (i - half) * (cell_h + ctx["gap"])).round,
          "w" => cell_w,
          "h" => cell_h,
          "links" => [{ "how" => "mirror-x", "to" => partner["key"] },
                      { "how" => "align-top", "to" => partner["key"] },
                      { "how" => "same-size", "to" => partner["key"] }]
        }
      end
    end
  end

  # A single layer's own chain: centred on the cross axis, gapped from the one
  # before it, and anchored to the frame at the start.
  def self.stack_links(list, i, gap_kind, first)
    links = [{ "how" => gap_kind == "space-y" ? "centred-x" : "centred-y", "to" => "canvas" }]
    if i.positive?
      links << { "how" => gap_kind, "to" => list[i - 1]["key"] }
    else
      links << { "how" => gap_kind == "space-y" ? "margin-top" : "margin-left", "to" => "canvas" }
    end
    links
  end

  # Write a plan onto the layer hashes. Only the keys the plan names are
  # touched, so a layer attribute added later (a src, a kind) survives a
  # template — a template arranges, it does not rebuild.
  def self.apply_plan(layers, plan, list)
    by_key = plan.to_h { |p| [p["key"], p] }
    arranged = layers.map do |l|
      p = by_key[l["key"]]
      next l if p.nil?
      merged = l.dup
      %w[x y w h].each { |k| merged[k] = p[k] if p.key?(k) }
      merged["links"] = p["links"] || []
      merged
    end
    # A hidden layer is not arranged — it is not in the picture, and a template
    # that moved it would be arranging something the operator cannot see.
    hidden = layers.reject { |l| list.any? { |v| v["key"] == l["key"] } }
    arranged + hidden.map { |l| l.dup }
  end

  # ------------------------------------------------------------------ internals

  def self.visible(layers)
    (layers || []).reject { |l| l["visible"] == false }
  end

  def self.links(layer)
    raw = layer.is_a?(Hash) ? (layer["links"] || []) : []
    return [] unless raw.is_a?(Array)

    raw.select { |k| k.is_a?(Hash) && NAMES.include?(k["how"]) }
  end

  def self.index(layers)
    (layers || []).to_h { |l| [l["key"], l] }
  end

  # "a subroutine yielding a scalar that should be zero" — literally, per
  # constraint type, in composite pixels.
  def self.error(how, l, other, ctx)
    case how
    when "align-left" then l["x"] - other["x"]
    when "align-right" then (l["x"] + l["w"]) - (other["x"] + other["w"])
    when "align-center-x" then (l["x"] + l["w"] / 2.0) - (other["x"] + other["w"] / 2.0)
    when "align-top" then l["y"] - other["y"]
    when "align-bottom" then (l["y"] + l["h"]) - (other["y"] + other["h"])
    when "align-center-y" then (l["y"] + l["h"] / 2.0) - (other["y"] + other["h"] / 2.0)
    when "same-width" then l["w"] - other["w"]
    when "same-height" then l["h"] - other["h"]
    when "same-size" then (l["w"] - other["w"]) + (l["h"] - other["h"])
    when "space-x" then (l["x"] - (other["x"] + other["w"])) - ctx["gap"]
    when "space-y" then (l["y"] - (other["y"] + other["h"])) - ctx["gap"]
    when "touch-x" then l["x"] - (other["x"] + other["w"])
    when "touch-y" then l["y"] - (other["y"] + other["h"])
    when "margin-left" then l["x"] - ctx["margin"]
    when "margin-top" then l["y"] - ctx["margin"]
    when "margin-right" then (ctx["width"] - (l["x"] + l["w"])) - ctx["margin"]
    when "margin-bottom" then (ctx["height"] - (l["y"] + l["h"])) - ctx["margin"]
    when "centred-x" then (l["x"] + l["w"] / 2.0) - ctx["width"] / 2.0
    when "centred-y" then (l["y"] + l["h"] / 2.0) - ctx["height"] / 2.0
    when "mirror-x" then (l["x"] + l["w"] / 2.0) - (ctx["width"] - (other["x"] + other["w"] / 2.0))
    when "mirror-y" then (l["y"] + l["h"] / 2.0) - (ctx["height"] - (other["y"] + other["h"] / 2.0))
    else 0.0
    end
  end

  def self.alignment_score(list)
    return 1.0 if list.length < 2

    pairs = 0
    agreeing = 0
    list.combination(2) do |a, b|
      pairs += 1
      x_agree = (a["x"] - b["x"]).abs <= EPS ||
                ((a["x"] + a["w"]) - (b["x"] + b["w"])).abs <= EPS ||
                ((a["x"] + a["w"] / 2.0) - (b["x"] + b["w"] / 2.0)).abs <= EPS
      y_agree = (a["y"] - b["y"]).abs <= EPS ||
                ((a["y"] + a["h"]) - (b["y"] + b["h"])).abs <= EPS ||
                ((a["y"] + a["h"] / 2.0) - (b["y"] + b["h"] / 2.0)).abs <= EPS
      agreeing += 1 if x_agree || y_agree
    end
    pairs.zero? ? 1.0 : agreeing.to_f / pairs
  end

  # Evenness of the gaps along one axis.
  #
  # Collapse equal CENTRES first. Two layers in one column share an x-centre, so
  # a 2x2 grid sorted by centre reads [c1, c1, c2, c2] — gaps 0, w, 0 — and
  # scoring those would call a perfectly regular grid ragged. Measuring between
  # DISTINCT positions is what "evenly spaced" means, and one layer knocked out
  # of line still scores below a tidy one. The JS engine does the same thing in
  # the same order; CompositeLayoutTest pins the shared numbers.
  def self.spacing_score(list, axis)
    return 1.0 if list.length < 3

    sorted = list.sort_by { |l| axis == "x" ? l["x"] + l["w"] / 2.0 : l["y"] + l["h"] / 2.0 }
    gaps = []
    sorted.each_cons(2) do |prev, nxt|
      centre_gap = if axis == "x"
                     (nxt["x"] + nxt["w"] / 2.0) - (prev["x"] + prev["w"] / 2.0)
                   else
                     (nxt["y"] + nxt["h"] / 2.0) - (prev["y"] + prev["h"] / 2.0)
                   end
      next if centre_gap.abs <= EPS   # same line: not a gap at all

      tail = axis == "x" ? prev["x"] + prev["w"] : prev["y"] + prev["h"]
      head = axis == "x" ? nxt["x"] : nxt["y"]
      gaps << [0, head - tail].max
    end
    return 1.0 if gaps.length < 2

    mean = gaps.sum.to_f / gaps.length
    return 1.0 if mean <= 0

    variance = gaps.sum { |g| (g - mean)**2 } / gaps.length
    [[1 - Math.sqrt(variance) / mean, 0].max, 1].min
  end

  def self.frame_score(list, ctx)
    return 1.0 if list.empty?

    tightest = Float::INFINITY
    outside = false
    list.each do |l|
      [l["x"], l["y"], ctx["width"] - (l["x"] + l["w"]), ctx["height"] - (l["y"] + l["h"])].each do |d|
        tightest = d if d < tightest
      end
      outside ||= l["x"] < 0 || l["y"] < 0 ||
                  l["x"] + l["w"] > ctx["width"] || l["y"] + l["h"] > ctx["height"]
    end
    return 0.0 if outside
    return 1.0 if tightest >= ctx["margin"]

    [[tightest.to_f / ctx["margin"], 0].max, 1].min
  end

  def self.balance_score(list, ctx)
    area = 0.0
    cx = 0.0
    cy = 0.0
    list.each do |l|
      a = [0, l["w"] * l["h"]].max
      area += a
      cx += (l["x"] + l["w"] / 2.0) * a
      cy += (l["y"] + l["h"] / 2.0) * a
    end
    return 1.0 if area <= 0

    cx /= area
    cy /= area
    dx = (cx - ctx["width"] / 2.0) / (ctx["width"] / 2.0)
    dy = (cy - ctx["height"] / 2.0) / (ctx["height"] / 2.0)
    [[1 - Math.sqrt(dx * dx + dy * dy) / Math.sqrt(2), 0].max, 1].min
  end

  def self.coupling_score(list)
    return 0.0 if list.empty?

    list.count { |l| links(l).any? }.to_f / list.length
  end

  def self.coverage(list, ctx)
    area = ctx["width"] * ctx["height"]
    return 0.0 if area <= 0

    sum = list.sum { |l| [0, l["w"] * l["h"]].max }
    [sum / area, 1].min
  end

  def self.mean_overlap(list)
    return 0.0 if list.length < 2

    pairs = 0
    sum = 0.0
    list.combination(2) do |a, b|
      pairs += 1
      small = [a["w"] * a["h"], b["w"] * b["h"]].min
      next if small <= 0

      # `.to_f` IS LOAD-BEARING: both sides are whole pixels, so an integer
      # division reports an overlap of 0 for every pair that does not overlap
      # COMPLETELY — the metric reads 0.0 on a canvas full of stacked layers.
      sum += overlap_area(a, b).to_f / small
    end
    pairs.zero? ? 0.0 : [sum / pairs, 1].min
  end

  def self.overlap_area(a, b)
    w = [[a["x"] + a["w"], b["x"] + b["w"]].min - [a["x"], b["x"]].max, 0].max
    h = [[a["y"] + a["h"], b["y"] + b["h"]].min - [a["y"], b["y"]].max, 0].max
    w * h
  end

  def self.round3(n)
    (n * 1000).round / 1000.0
  end
end
