// Aether sketch: snapping, COUPLING and layout metrics for the composite canvas.
//
// WHERE THIS COMES FROM
//
// Ivan Sutherland's Sketchpad (MIT, 1963) drew two things apart that every
// editor since has tended to fuse, and this module keeps them apart for the
// same reason:
//
//   * a "strong condition" was the drafting aid — the T-square and triangle
//     mode, where a line *ended up* parallel to another without any permanent
//     record that it was meant to be. That is SNAPPING here;
//   * a CONSTRAINT was a subroutine yielding a scalar that should be zero,
//     solved by the one-pass method and, where that failed, by relaxation.
//     That is COUPLING here.
//
// The difference is the whole point: a snap is a gift that the next drag takes
// away, a constraint is a promise the canvas keeps. Sutherland's own account of
// the first version is the reason to state it plainly — "lines could be drawn
// parallel or perpendicular to existing lines but carried no permanent trace of
// the relationship other than the accident of their position", which he wrote
// up as a deficiency, not a feature.
//
// WHAT IS AND IS NOT PORTED, AND WHY
//
// Sketchpad's Appendix A lists seventeen atomic constraints over points, lines
// and circles. This canvas holds AXIS-ALIGNED RECTANGLES with no rotation, so
// the ones that survive translation are the coincidences (align/centre), the
// equalities (same-size), equal SPACING, the frame attachments (margin/centred)
// and symmetry — and each of those is a constraint in the original sense: a
// scalar error, plus the projection that drives it to zero. The rest are NOT
// ported, on purpose, and named here so nobody re-litigates them:
//
//   * perpendicular / parallel — a rectangle's edges are already perpendicular
//     and its sides parallel, so both are true of every layer and constrain
//     nothing. (Sketchpad needed them because it drew arbitrary line segments.)
//   * point-on-line / point-on-circle — there are no points, lines or circles
//     in this model; a layer is a box. The nearest useful meaning, "a layer's
//     edge sits on another's", is `touch-x` / `touch-y` below.
//   * upright — likewise guaranteed: an image layer has no rotation to take.
//
// The metrics at the bottom are the same numbers the Ruby side computes
// (`CompositeLayout.metrics`) so the builder's readout and the agent-facing
// endpoint cannot disagree. The names, the weights and the tolerance are the
// contract between them; `composite_layout_test.rb` pins that they match.

export default (function () {
  'use strict';

  // A constraint is satisfied when its scalar is within this, in COMPOSITE
  // pixels — the same unit the layer geometry is in, so the tolerance does not
  // change meaning when the stage is scaled down on a tablet.
  var EPS = 0.5;
  // How far a drag will reach for a guide, in composite pixels. The caller
  // scales it: on a canvas displayed at half size, 12 composite px is 6 screen
  // px of hand travel, which is the difference between "it snapped" and "it
  // fought me".
  var TOL = 12;
  // Relaxation is Sketchpad's FALLBACK for a constraint graph the one-pass
  // method cannot order (a cycle: A right of B, B left of C, C left of A). It
  // is a Gauss-Seidel sweep over the same error functions, so it converges on
  // the same fixed point the one-pass method reaches in one go — slowly. The
  // cap and the convergence test are what keep a locked cycle from spinning.
  var RELAX_MAX = 40;
  var RELAX_EPS = 0.01;

  var DEFAULT_MARGIN = 0.05;   // 5% of the short side, when the caller names none
  var DEFAULT_GAP = 0.02;      // 2% — the gap a spacing constraint locks to

  // ------------------------------------------------------------------ context

  // The frame a constraint may attach to. `width`/`height` are the composite's
  // own pixels; `margin` and `gap` are the two distances the templates and the
  // frame constraints share, so a gap the operator sees snapped is the same gap
  // the solver enforces later.
  function frame(width, height, opts) {
    opts = opts || {};
    var short = Math.min(width, height) || 1;
    return {
      width: width,
      height: height,
      margin: opts.margin != null ? opts.margin : Math.round(short * DEFAULT_MARGIN),
      gap: opts.gap != null ? opts.gap : Math.round(short * DEFAULT_GAP)
    };
  }

  // ------------------------------------------------------------------ registry

  // #sketch-constraint-registry
  //
  // Every entry is { axis, error, resolve, doc }. `axis` is the field the
  // constraint WRITES, and knowing it is what makes the dependency graph
  // buildable instead of discovered: a layer can only be moved by a constraint
  // whose axis it owns, so "who depends on whom" is a lookup, not a search.
  //
  // `error` returns the scalar that should be zero (Sketchpad's definition,
  // verbatim). `resolve` zeroes it by moving THIS layer — never the other one —
  // which is what makes one-pass propagation terminate: the driver is the layer
  // the operator is holding, and everyone downstream yields to it.
  var CONSTRAINTS = {
    'align-left': {
      axis: 'x',
      doc: 'two left edges share an x',
      error: function (l, o) { return l.x - o.x; },
      resolve: function (l, o) { l.x = o.x; }
    },
    'align-right': {
      axis: 'x',
      doc: 'two right edges share an x',
      error: function (l, o) { return (l.x + l.w) - (o.x + o.w); },
      resolve: function (l, o) { l.x = o.x + o.w - l.w; }
    },
    'align-center-x': {
      axis: 'x',
      doc: 'two vertical centres share an x',
      error: function (l, o) { return (l.x + l.w / 2) - (o.x + o.w / 2); },
      resolve: function (l, o) { l.x = o.x + o.w / 2 - l.w / 2; }
    },
    'align-top': {
      axis: 'y',
      doc: 'two top edges share a y',
      error: function (l, o) { return l.y - o.y; },
      resolve: function (l, o) { l.y = o.y; }
    },
    'align-bottom': {
      axis: 'y',
      doc: 'two bottom edges share a y',
      error: function (l, o) { return (l.y + l.h) - (o.y + o.h); },
      resolve: function (l, o) { l.y = o.y + o.h - l.h; }
    },
    'align-center-y': {
      axis: 'y',
      doc: 'two horizontal centres share a y',
      error: function (l, o) { return (l.y + l.h / 2) - (o.y + o.h / 2); },
      resolve: function (l, o) { l.y = o.y + o.h / 2 - l.h / 2; }
    },
    'same-width': {
      axis: 'w',
      doc: 'two layers are the same width',
      error: function (l, o) { return l.w - o.w; },
      resolve: function (l, o) { l.w = o.w; }
    },
    'same-height': {
      axis: 'h',
      doc: 'two layers are the same height',
      error: function (l, o) { return l.h - o.h; },
      resolve: function (l, o) { l.h = o.h; }
    },
    // "Equal size" in Sketchpad's list; here it is both dimensions at once, so
    // it writes x and w (or y and h) and therefore RESIZES where it sits. That
    // is the honest behaviour of a two-axis constraint and the reason `axes`
    // is a list rather than the single `axis` most entries carry.
    'same-size': {
      axis: 'w', axes: ['w', 'h'],
      doc: 'two layers are the same width and height',
      error: function (l, o) { return l.w - o.w + (l.h - o.h); },
      resolve: function (l, o) { l.w = o.w; l.h = o.h; }
    },
    // Equal spacing, as a constraint rather than a one-off nudge: the gap
    // between the two is a NUMBER the composite keeps. This is what makes a row
    // of four pieces stay evenly spread while one of them is resized.
    'space-x': {
      axis: 'x',
      doc: 'a fixed horizontal gap follows the other layer',
      error: function (l, o, ctx) { return (l.x - (o.x + o.w)) - ctx.gap; },
      resolve: function (l, o, ctx) { l.x = o.x + o.w + ctx.gap; }
    },
    'space-y': {
      axis: 'y',
      doc: 'a fixed vertical gap follows the other layer',
      error: function (l, o, ctx) { return (l.y - (o.y + o.h)) - ctx.gap; },
      resolve: function (l, o, ctx) { l.y = o.y + o.h + ctx.gap; }
    },
    // Edge-to-edge with NO gap: the "point on line" of a box world.
    'touch-x': {
      axis: 'x',
      doc: 'this left edge sits on the other right edge',
      error: function (l, o) { return l.x - (o.x + o.w); },
      resolve: function (l, o) { l.x = o.x + o.w; }
    },
    'touch-y': {
      axis: 'y',
      doc: 'this top edge sits on the other bottom edge',
      error: function (l, o) { return l.y - (o.y + o.h); },
      resolve: function (l, o) { l.y = o.y + o.h; }
    },
    // Frame attachments. `to` is the literal "canvas" for these — the frame is
    // a constraint target like any other, which is how a margin survives a
    // canvas resize instead of being a number that was true once.
    'margin-left': {
      axis: 'x',
      doc: 'held off the left frame edge',
      error: function (l, o, ctx) { return l.x - ctx.margin; },
      resolve: function (l, o, ctx) { l.x = ctx.margin; }
    },
    'margin-top': {
      axis: 'y',
      doc: 'held off the top frame edge',
      error: function (l, o, ctx) { return l.y - ctx.margin; },
      resolve: function (l, o, ctx) { l.y = ctx.margin; }
    },
    'margin-right': {
      axis: 'x',
      doc: 'held off the right frame edge',
      error: function (l, o, ctx) { return (ctx.width - (l.x + l.w)) - ctx.margin; },
      resolve: function (l, o, ctx) { l.x = ctx.width - ctx.margin - l.w; }
    },
    'margin-bottom': {
      axis: 'y',
      doc: 'held off the bottom frame edge',
      error: function (l, o, ctx) { return (ctx.height - (l.y + l.h)) - ctx.margin; },
      resolve: function (l, o, ctx) { l.y = ctx.height - ctx.margin - l.h; }
    },
    'centred-x': {
      axis: 'x',
      doc: 'centred on the vertical axis of the frame',
      error: function (l, o, ctx) { return (l.x + l.w / 2) - ctx.width / 2; },
      resolve: function (l, o, ctx) { l.x = ctx.width / 2 - l.w / 2; }
    },
    'centred-y': {
      axis: 'y',
      doc: 'centred on the horizontal axis of the frame',
      error: function (l, o, ctx) { return (l.y + l.h / 2) - ctx.height / 2; },
      resolve: function (l, o, ctx) { l.y = ctx.height / 2 - l.h / 2; }
    },
    // Symmetry, which Sketchpad demonstrated on bridges and artistic drawings:
    // the mirrored pair keeps one relation, so moving one side moves the other.
    'mirror-x': {
      axis: 'x',
      doc: 'mirrored about the vertical centre of the frame',
      error: function (l, o, ctx) {
        return (l.x + l.w / 2) - (ctx.width - (o.x + o.w / 2));
      },
      resolve: function (l, o, ctx) { l.x = ctx.width - (o.x + o.w / 2) - l.w / 2; }
    },
    'mirror-y': {
      axis: 'y',
      doc: 'mirrored about the horizontal centre of the frame',
      error: function (l, o, ctx) {
        return (l.y + l.h / 2) - (ctx.height - (o.y + o.h / 2));
      },
      resolve: function (l, o, ctx) { l.y = ctx.height - (o.y + o.h / 2) - l.h / 2; }
    }
  };

  var NAMES = Object.keys(CONSTRAINTS);

  function constraint(name) { return CONSTRAINTS[name] || null; }

  // A layer's links, normalised. Stored ON the layer because that is what
  // Sketchpad did with constraints ("constraints refer only to variables") and
  // because it needs no schema change: the JSON a composite already posts
  // carries them.
  function linksOf(layer) {
    var raw = (layer && layer.links) || [];
    return raw.filter(function (k) { return k && CONSTRAINTS[k.how]; });
  }

  function hasLink(layer, how, to) {
    return linksOf(layer).some(function (k) {
      return k.how === how && (to == null || k.to === to);
    });
  }

  // Couple, or re-couple: one relation per (how, to) pair, because stacking the
  // same constraint twice changes nothing and makes the residual report lie.
  function couple(layer, how, to) {
    if (!CONSTRAINTS[how]) return false;
    if (hasLink(layer, how, to)) return false;
    layer.links = linksOf(layer).concat([{ how: how, to: to || 'canvas' }]);
    return true;
  }

  function decouple(layer, how, to) {
    layer.links = linksOf(layer).filter(function (k) {
      return !(k.how === how && (to == null || k.to === to));
    });
  }

  // ------------------------------------------------------------------ snapping

  // #sketch-snap-candidates
  //
  // Every way the dragged layer could line up RIGHT NOW, scored. This is the
  // T-square: it proposes, it never persists. The caller decides whether a
  // proposal becomes a constraint (see `couple`), which is the distinction the
  // module opens with.
  //
  // Scored rather than first-match: an edge coincidence beats a centre
  // coincidence at the same distance, because that is what the eye reads as
  // "aligned", and a smaller correction beats a bigger one. The weights are
  // here, in one table, so the ordering is arguable rather than accidental.
  var SNAP_WEIGHTS = {
    'align-left': 1.0, 'align-right': 1.0, 'align-top': 1.0, 'align-bottom': 1.0,
    'touch-x': 0.95, 'touch-y': 0.95,
    'align-center-x': 0.8, 'align-center-y': 0.8,
    'same-width': 0.6, 'same-height': 0.6,
    'space-x': 0.7, 'space-y': 0.7,
    'margin-left': 0.9, 'margin-right': 0.9, 'margin-top': 0.9, 'margin-bottom': 0.9,
    'centred-x': 0.85, 'centred-y': 0.85,
    'mirror-x': 0.55, 'mirror-y': 0.55
  };

  // The candidate set for one axis. `axis` is 'x' or 'y'; the caller asks for
  // both, which is what lets a drag snap on each independently (a layer can
  // align left to one neighbour and top to another — exactly what Sketchpad's
  // per-variable constraints allowed).
  function candidates(layer, others, ctx, axis, tol) {
    var out = [];
    var x0 = axis === 'x' ? layer.x : layer.y;
    var size = axis === 'x' ? layer.w : layer.h;
    var span = axis === 'x' ? ctx.width : ctx.height;
    var margin = ctx.margin;

    function offer(kind, delta, target) {
      if (Math.abs(delta) > tol) return;
      out.push({
        how: kind, axis: axis, to: target || 'canvas',
        delta: Math.round(delta * 100) / 100,
        distance: Math.abs(delta),
        weight: SNAP_WEIGHTS[kind] || 0.5,
        // Closer first, then the more meaningful relation.
        score: (SNAP_WEIGHTS[kind] || 0.5) - Math.abs(delta) / (tol * 4)
      });
    }

    // Against every other layer: edges, centres, equal size and equal gap.
    others.forEach(function (o) {
      if (o.visible === false) return;
      var o0 = axis === 'x' ? o.x : o.y;
      var osize = axis === 'x' ? o.w : o.h;
      var tail = axis === 'x' ? 'left' : 'top';
      var head = axis === 'x' ? 'right' : 'bottom';
      var centre = axis === 'x' ? 'center-x' : 'center-y';
      offer('align-' + tail, o0 - x0, o.key);
      offer('align-' + head, (o0 + osize) - (x0 + size), o.key);
      offer('align-' + centre, (o0 + osize / 2) - (x0 + size / 2), o.key);
      offer('touch-' + axis, (o0 + osize) - x0, o.key);
      offer('touch-' + axis, o0 - (x0 + size), o.key);
      offer('space-' + axis, (o0 + osize + ctx.gap) - x0, o.key);
      offer('space-' + axis, o0 - (x0 + size + ctx.gap), o.key);
      if (axis === 'x') offer('same-width', o.w - layer.w, o.key);
      else offer('same-height', o.h - layer.h, o.key);
      offer('mirror-' + axis, (span - (o0 + osize / 2) - size / 2) - x0, o.key);
    });

    // Against the frame: the two margins and the centre line. The frame is a
    // target everywhere a layer is, which is what keeps a composition's edge
    // rhythm a property of the composition.
    offer('margin-' + (axis === 'x' ? 'left' : 'top'), margin - x0);
    offer('margin-' + (axis === 'x' ? 'right' : 'bottom'), (span - margin - size) - x0);
    offer('centred-' + axis, (span / 2 - size / 2) - x0);

    out.sort(function (a, b) { return b.score - a.score || a.distance - b.distance; });
    return out;
  }

  // #sketch-snap
  //
  // The full proposal for a drag: the best candidate per axis (or none), the
  // corrected position, and the two guide lines to draw. `tol` is in composite
  // pixels; the caller scales it from the stage.
  function snap(layer, layers, ctx, tol) {
    var t = tol == null ? TOL : tol;
    var others = (layers || []).filter(function (o) { return o !== layer && o.key !== layer.key; });
    var cx = candidates(layer, others, ctx, 'x', t);
    var cy = candidates(layer, others, ctx, 'y', t);
    var bestX = cx[0] || null;
    var bestY = cy[0] || null;
    return {
      dx: bestX ? Math.round(bestX.delta) : 0,
      dy: bestY ? Math.round(bestY.delta) : 0,
      x: bestX,
      y: bestY,
      candidates: cx.concat(cy),
      guides: guidesFor(layer, bestX, bestY, ctx)
    };
  }

  // The lines the overlay draws. Guides are named by the relation that produced
  // them so the operator can see WHY it stopped there, which is the difference
  // between a snap that teaches and a snap that just tugs.
  function guidesFor(layer, bestX, bestY, ctx) {
    var out = [];
    if (bestX) {
      var x = bestX.how.indexOf('align-left') === 0 ? layer.x + bestX.delta
        : bestX.how.indexOf('align-right') === 0 ? layer.x + bestX.delta + layer.w
        : bestX.how.indexOf('align-center-x') === 0 ? layer.x + bestX.delta + layer.w / 2
        : bestX.how.indexOf('margin-left') === 0 ? ctx.margin
        : bestX.how.indexOf('margin-right') === 0 ? ctx.width - ctx.margin
        : layer.x + bestX.delta;
      out.push({ axis: 'x', at: x, how: bestX.how, to: bestX.to });
    }
    if (bestY) {
      var y = bestY.how.indexOf('align-top') === 0 ? layer.y + bestY.delta
        : bestY.how.indexOf('align-bottom') === 0 ? layer.y + bestY.delta + layer.h
        : bestY.how.indexOf('align-center-y') === 0 ? layer.y + bestY.delta + layer.h / 2
        : bestY.how.indexOf('margin-top') === 0 ? ctx.margin
        : bestY.how.indexOf('margin-bottom') === 0 ? ctx.height - ctx.margin
        : layer.y + bestY.delta;
      out.push({ axis: 'y', at: y, how: bestY.how, to: bestY.to });
    }
    return out;
  }

  // ------------------------------------------------------------------ solving

  // #sketch-one-pass
  //
  // Sketchpad's one-pass method: "recursively locate free variables that are
  // easily satisfied; re-evaluate in reverse order". For a box graph the
  // equivalent is a forward sweep from the layer the operator is holding:
  // everyone coupled to the driver yields to it, then their dependents yield to
  // them, and because a tree has no cycle, one pass is exact rather than
  // approximate.
  //
  // TWO THINGS ARE LOAD-BEARING AND BOTH COME FROM THE ORIGINAL:
  //
  //   * the DRIVER IS FIXED. It is the independent variable — the hand is on
  //     it — so its OWN links are not resolved during its own drag. Otherwise
  //     a layer coupled to another would be yanked back to that other the
  //     moment you touched it, which is the behaviour that makes constraint
  //     editing feel broken rather than helpful. The relation is still stored;
  //     it is enforced when something ELSE is the driver.
  //   * the sweep runs along the DEPENDENCY direction (who yields to whom), not
  //     along the links. Following the links walks away from the driver and
  //     resolves nothing.
  //
  // A layer reached twice is a cycle, and that is what hands the graph to
  // relaxation.
  function solve(layers, driverKey, ctx) {
    var byKey = {};
    var dependents = {};
    layers.forEach(function (l) { byKey[l.key] = l; });
    layers.forEach(function (l) {
      linksOf(l).forEach(function (k) {
        if (!k.to || k.to === "canvas") return;
        (dependents[k.to] = dependents[k.to] || []).push(l);
      });
    });

    var order = [];
    var seen = {};
    var queue = [driverKey];
    var cyclic = false;
    seen[driverKey] = true;
    while (queue.length) {
      var key = queue.shift();
      if (!byKey[key]) continue;
      (dependents[key] || []).forEach(function (child) {
        if (seen[child.key]) { cyclic = true; return; }
        seen[child.key] = true;
        order.push(child);
        queue.push(child.key);
      });
    }

    var report = { mode: "one-pass", steps: 0, residual: 0, moved: 0, relaxed: false };

    if (cyclic) {
      report.relaxed = true;
      report.mode = "relaxed";
      report.steps = relax(layers, ctx, driverKey);
      report.residual = residualOf(layers, ctx);
      return { layers: layers, report: report };
    }

    order.forEach(function (layer) {
      linksOf(layer).forEach(function (k) {
        var o = k.to === "canvas" ? null : byKey[k.to];
        if (k.to !== "canvas" && !o) return;
        var c = CONSTRAINTS[k.how];
        if (!c) return;
        var before = layer[c.axis];
        c.resolve(layer, o, ctx);
        if (layer[c.axis] !== before) report.moved++;
        report.steps++;
      });
    });

    report.residual = residualOf(layers, ctx);
    return { layers: layers, report: report };
  }

  // #sketch-relax
  //
  // The fallback, kept because Sketchpad kept one: a Gauss-Seidel sweep over
  // every error function, repeated until the worst residual is inside EPS or
  // the cap is hit. It exists for cycles — three layers each constrained to the
  // right of the next have no valid one-pass order — and it converges on the
  // same fixed point, slowly. The cap matters: an unsatisfiable cycle (a layer
  // both left of and inside its neighbour) must stop, not spin.
  //
  // The driver is held out here too: relaxing it would move the thing the hand
  // is on, which no fallback is allowed to do.
  function relax(layers, ctx, driverKey) {
    var steps = 0;
    for (var pass = 0; pass < RELAX_MAX; pass++) {
      var moved = 0;
      layers.forEach(function (layer) {
        if (layer.key === driverKey) return;
        linksOf(layer).forEach(function (k) {
          var c = CONSTRAINTS[k.how];
          if (!c) return;
          var o = null;
          if (k.to && k.to !== "canvas") {
            for (var i = 0; i < layers.length; i++) if (layers[i].key === k.to) o = layers[i];
            if (!o) return;
          }
          var before = layer[c.axis];
          c.resolve(layer, o, ctx);
          if (layer[c.axis] !== before) moved++;
          steps++;
        });
      });
      if (residualOf(layers, ctx) <= EPS) break;
      if (moved === 0) break;
    }
    return steps;
  }

  // The worst unsatisfied scalar in the graph — Sketchpad's "errors indicated by
  // the various computation subroutines", reported rather than hidden, because a
  // composite that CANNOT satisfy its constraints should say so instead of
  // quietly settling somewhere.
  function residualOf(layers, ctx) {
    var worst = 0;
    var byKey = {};
    layers.forEach(function (l) { byKey[l.key] = l; });
    layers.forEach(function (layer) {
      linksOf(layer).forEach(function (k) {
        var c = CONSTRAINTS[k.how];
        if (!c) return;
        var o = null;
        if (k.to && k.to !== 'canvas') o = byKey[k.to];
        if (k.to !== 'canvas' && !o) return;
        var e = Math.abs(c.error(layer, o, ctx));
        if (e > worst) worst = e;
      });
    });
    return Math.round(worst * 100) / 100;
  }

  // ------------------------------------------------------------------ metrics

  // #sketch-metrics
  //
  // The numbers the ML/heuristic side reads. They are deliberately about the
  // ARRANGEMENT and not about the art: the pipeline's rule is that nothing here
  // judges which candidate is better, and the same rule applies to a
  // composition — these describe how the pieces sit, they do not rank the
  // picture. The weights are a single table so the blend is arguable.
  var WEIGHTS = {
    alignment: 0.30,   // do edges and centres agree
    spacing: 0.20,     // are the gaps even
    frame: 0.15,       // is the composition inside its margins
    balance: 0.15,     // is the mass centred
    coupling: 0.20     // is the arrangement DECLARED (constraints) or accidental
  };

  function visibleLayers(layers) {
    return (layers || []).filter(function (l) { return l.visible !== false; });
  }

  function rect(l) { return { x: l.x, y: l.y, w: l.w, h: l.h }; }

  function overlapArea(a, b) {
    var w = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
    var h = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
    return w > 0 && h > 0 ? w * h : 0;
  }

  // Do any two layers share an x or a y inside EPS? Counted as a share of the
  // possible pairs, so one tidy pair in a hundred is not "aligned".
  function alignmentScore(list) {
    if (list.length < 2) return 1;
    var pairs = 0;
    var agreeing = 0;
    for (var i = 0; i < list.length; i++) {
      for (var j = i + 1; j < list.length; j++) {
        pairs++;
        var a = list[i], b = list[j];
        var xAgree = Math.abs(a.x - b.x) <= EPS ||
                     Math.abs((a.x + a.w) - (b.x + b.w)) <= EPS ||
                     Math.abs((a.x + a.w / 2) - (b.x + b.w / 2)) <= EPS;
        var yAgree = Math.abs(a.y - b.y) <= EPS ||
                     Math.abs((a.y + a.h) - (b.y + b.h)) <= EPS ||
                     Math.abs((a.y + a.h / 2) - (b.y + b.h / 2)) <= EPS;
        if (xAgree || yAgree) agreeing++;
      }
    }
    return pairs ? agreeing / pairs : 1;
  }

  // Even gaps: the coefficient of variation of the gaps along an axis, inverted.
  //
  // CENTRES ARE COLLAPSED FIRST, and that is the whole subtlety. Two layers in
  // the same column share an x-centre, so a 2x2 grid sorted by centre reads as
  // [c1, c1, c2, c2] — gaps 0, w, 0 — and scoring those says a perfectly
  // regular grid is ragged. Collapsing equal centres (inside EPS) measures the
  // gaps between DISTINCT positions, which is what "evenly spaced" means: a
  // grid scores 1, and one layer knocked out of line still scores below it.
  function spacingScore(list, axis) {
    if (list.length < 3) return 1;
    var sorted = list.slice().sort(function (a, b) {
      return (axis === "x" ? a.x + a.w / 2 : a.y + a.h / 2) - (axis === "x" ? b.x + b.w / 2 : b.y + b.h / 2);
    });
    var gaps = [];
    for (var i = 1; i < sorted.length; i++) {
      var prev = axis === "x" ? sorted[i - 1].x + sorted[i - 1].w : sorted[i - 1].y + sorted[i - 1].h;
      var next = axis === "x" ? sorted[i].x : sorted[i].y;
      var centreGap = axis === "x"
        ? (sorted[i].x + sorted[i].w / 2) - (sorted[i - 1].x + sorted[i - 1].w / 2)
        : (sorted[i].y + sorted[i].h / 2) - (sorted[i - 1].y + sorted[i - 1].h / 2);
      if (Math.abs(centreGap) <= EPS) continue;   // same line: not a gap at all
      gaps.push(Math.max(0, next - prev));
    }
    if (gaps.length < 2) return 1;
    var mean = gaps.reduce(function (s, g) { return s + g; }, 0) / gaps.length;
    if (mean <= 0) return 1;
    var variance = gaps.reduce(function (s, g) { return s + (g - mean) * (g - mean); }, 0) / gaps.length;
    return Math.max(0, Math.min(1, 1 - Math.sqrt(variance) / mean));
  }

  // Inside the frame: 1 when the tightest edge sits on the margin, 0 when a
  // layer leaves the canvas. A layer that bleeds off the edge is not "nearly
  // there" — the print is what it is, so it scores zero.
  function frameScore(list, ctx) {
    if (!list.length) return 1;
    var tightest = Infinity;
    var outside = false;
    list.forEach(function (l) {
      var edges = [l.x, l.y, ctx.width - (l.x + l.w), ctx.height - (l.y + l.h)];
      edges.forEach(function (d) { if (d < tightest) tightest = d; });
      if (l.x < 0 || l.y < 0 || l.x + l.w > ctx.width || l.y + l.h > ctx.height) outside = true;
    });
    if (outside) return 0;
    if (tightest >= ctx.margin) return 1;
    return Math.max(0, tightest / ctx.margin);
  }

  // Area-weighted centre of mass against the frame's centre, as 1 - offset.
  function balanceScore(list, ctx) {
    var area = 0, cx = 0, cy = 0;
    list.forEach(function (l) {
      var a = Math.max(0, l.w * l.h);
      area += a;
      cx += (l.x + l.w / 2) * a;
      cy += (l.y + l.h / 2) * a;
    });
    if (area <= 0) return 1;
    cx /= area; cy /= area;
    var dx = (cx - ctx.width / 2) / (ctx.width / 2);
    var dy = (cy - ctx.height / 2) / (ctx.height / 2);
    return Math.max(0, Math.min(1, 1 - Math.sqrt(dx * dx + dy * dy) / Math.SQRT2));
  }

  // DECLARED, not accidental: the share of visible layers that carry at least
  // one constraint. This is the metric that makes the rest meaningful — a
  // composition can be aligned by luck and lose it on the next drag.
  function couplingScore(list) {
    if (!list.length) return 0;
    var coupled = list.filter(function (l) { return linksOf(l).length > 0; }).length;
    return coupled / list.length;
  }

  function metrics(layers, ctx) {
    var list = visibleLayers(layers);
    var links = list.reduce(function (n, l) { return n + linksOf(l).length; }, 0);
    var m = {
      layers: list.length,
      links: links,
      alignment: round3(alignmentScore(list)),
      spacing_x: round3(spacingScore(list, 'x')),
      spacing_y: round3(spacingScore(list, 'y')),
      frame: round3(frameScore(list, ctx)),
      balance: round3(balanceScore(list, ctx)),
      coupling: round3(couplingScore(list)),
      coverage: round3(coverage(list, ctx)),
      overlap: round3(meanOverlap(list))
    };
    m.spacing = round3((m.spacing_x + m.spacing_y) / 2);
    m.score = round3(
      WEIGHTS.alignment * m.alignment +
      WEIGHTS.spacing * m.spacing +
      WEIGHTS.frame * m.frame +
      WEIGHTS.balance * m.balance +
      WEIGHTS.coupling * m.coupling
    );
    return m;
  }

  function coverage(list, ctx) {
    var area = ctx.width * ctx.height;
    if (area <= 0) return 0;
    var sum = list.reduce(function (s, l) { return s + Math.max(0, l.w * l.h); }, 0);
    return Math.min(1, sum / area);
  }

  // Overlap is REPORTED, never scored: a collage overlaps on purpose, and a
  // heuristic that punished it would be telling the operator what to make.
  function meanOverlap(list) {
    if (list.length < 2) return 0;
    var pairs = 0, sum = 0;
    for (var i = 0; i < list.length; i++) {
      for (var j = i + 1; j < list.length; j++) {
        pairs++;
        var a = rect(list[i]), b = rect(list[j]);
        var small = Math.min(a.w * a.h, b.w * b.h) || 1;
        sum += overlapArea(a, b) / small;
      }
    }
    return pairs ? Math.min(1, sum / pairs) : 0;
  }

  function round3(n) { return Math.round(n * 1000) / 1000; }

  var api = {
    EPS: EPS, TOL: TOL, DEFAULT_MARGIN: DEFAULT_MARGIN, DEFAULT_GAP: DEFAULT_GAP,
    frame: frame,
    names: NAMES,
    constraints: CONSTRAINTS,
    constraint: constraint,
    linksOf: linksOf, hasLink: hasLink, couple: couple, decouple: decouple,
    candidates: candidates, snap: snap, guidesFor: guidesFor,
    solve: solve, residualOf: residualOf,
    metrics: metrics, weights: WEIGHTS
  };

  // The same namespace the other Aether modules publish into. The composite
  // page is a classic inline script and the modules are deferred, so it reads
  // window.Aether.sketch at INTERACTION time — the pattern the entropy module
  // documents, and for the same reason.
  window.Aether = window.Aether || {};
  window.Aether.sketch = api;

  return api;
})();
