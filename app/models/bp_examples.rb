# A COPY-PASTEABLE JOB SPEC for every operation of the one blend-plot service.
#
# The gap this file fills: /bp documented the SERVICE contract thoroughly --
# element tables, chart lists, defaults, routes, response shapes, the metrics
# registry -- and carried a document example for exactly one operation (the
# blender Checks textarea). It carried NO job spec for ANY operation, so
# everything an operator actually submits to the studio was absent from the page
# that describes the service. The JSON popups emit a *conf* (env + runners +
# operations), which is not a job spec and is refused by
# `Job#bp_job_needs_an_op_and_a_document` if pasted into Run Job.
#
# These specs are NOT written here. Every `doc` is copied from chopshop-bp's own
# `examples/*.json` -- the fixtures its README points at and its validators
# accept. That is the whole reason to trust them enough to show an operator:
# a hand-written plausible-looking spec is exactly what the smoke test tried
# first and the service refused in three separate ways (`generate` needs a
# `canvas` block and coordinate-pair points, `tree` needs `nodes` + `edges` with
# a `kind` on every node, `query` needs a chart plus axes plus a NON-EMPTY
# `runs`).
#
# WHY A MODEL, and the same rule PlotConf and BlenderConf follow: this page does
# not run the service and cannot change its environment. What it can do is show
# a body the service accepts, in the exact shape the STUDIO posts it, so what
# you copy is what runs. A spec that drifts from the service is the same defect
# as a conf that drifts -- it is a page that is confidently wrong.
#
# The `runs` for `query` are the two demo run records from
# `chopshop-bp/examples/runs/`. They are elided here rather than pasted: they
# are ~8 KB and ~4 KB of real candidate data, and inlining them would make this
# file a copy of a fixture that is regenerated. The elision is marked in the
# rendered text so nobody pastes it and gets a refusal.
class BpExamples
  # Where each doc came from, for the page to show. This is provenance, not
  # decoration: an example whose source can be named is one somebody can go and
  # re-verify when the service changes.
  SOURCE = "chopshop-bp examples/".freeze

  # The elision marker for the run records. Deliberately not valid JSON-in-
  # context: it is a comment-shaped string so a reader who pastes the whole
  # block gets a clear parse error rather than a silent empty chart.
  RUNS_ELIDED = "… the two records in chopshop-bp/examples/runs/ (demo-01, " \
                "demo-02), pasted here as JSON …".freeze

  # One entry per operation. `op` is the value of `spec.bp.op`; `doc` is the
  # value of `spec.bp.doc`. `runs` is present for `query` and no other op --
  # the service requires it there and ignores it everywhere else, which is
  # stated rather than left to be discovered.
  ALL = [
    {
      op: "generate",
      half: "plot",
      title: "Geometry source",
      what: "Draws a document from an element list on a canvas — rects, circles, " \
            "polygons, paths, plus a repeating `tiling` block.",
      source: "#{SOURCE}shapes.json",
      doc: {
        "canvas" => { "width" => 600, "height" => 600, "background" => "#ffffff" },
        "elements" => [
          { "type" => "rect", "x" => 30, "y" => 30, "width" => 540, "height" => 540,
            "fill" => "none", "stroke" => "#222222", "stroke_width" => 6, "rx" => 12 },
          { "type" => "circle", "cx" => 300, "cy" => 300, "r" => 180, "fill" => "#f58518" },
          { "type" => "polygon", "points" => [[300, 80], [490, 440], [110, 440]],
            "fill" => "#4c78a8" },
          { "type" => "path", "d" => "M 150 520 L 450 520 L 450 560 L 150 560 Z",
            "fill" => "#54a24b" }
        ],
        "tiling" => {
          "grid" => [6, 1],
          "cell" => [90, 20],
          "origin" => [30, 565],
          "element" => { "type" => "circle", "cx" => 45, "cy" => 10, "r" => 6,
                         "fill" => "#e45756" }
        }
      }
    },
    {
      op: "digest",
      half: "plot",
      title: "Metrics digest",
      what: "Charts a labelled set of numeric series. Two series here so the " \
            "grouping is visible.",
      source: "#{SOURCE}scores.json",
      doc: {
        "chart" => "bar",
        "title" => "Candidate scores (12/12 passing)",
        "size" => { "width" => 800, "height" => 420 },
        "data" => {
          "labels" => %w[c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12],
          "series" => [
            { "name" => "score",
              "values" => [0.92, 0.71, 0.88, 0.44, 0.95, 0.62, 0.8, 0.53, 0.77, 0.9, 0.35, 0.68] },
            { "name" => "ink",
              "values" => [0.6, 0.82, 0.45, 0.71, 0.55, 0.66, 0.39, 0.74, 0.58, 0.48, 0.8, 0.63] }
          ]
        }
      }
    },
    {
      op: "query",
      half: "plot",
      title: "Cross-run query",
      what: "Charts the metric fields of one or more run records. The ONLY " \
            "operation that takes `runs`, and it refuses an EMPTY one — it " \
            "draws across the records it is given, so there is nothing to draw " \
            "without them.",
      source: "#{SOURCE}query_scatter.json (chart) + runs/demo-01, demo-02",
      doc: {
        "chart" => "scatter",
        "x" => "node_count_max",
        "y" => "mae_art",
        "color" => "preset",
        "title" => "Candidates by preset"
      },
      # Shown, not usable: the records are 12 KB of fixture data. The page
      # says where they are; a reader who wants them copies them from the repo.
      runs_note: "paste the JSON objects from chopshop-bp/examples/runs/demo-01.run.json " \
                 "and demo-02.run.json here"
    },
    {
      op: "tree",
      half: "plot",
      title: "Candidate hierarchy",
      what: "Draws a node/edge hierarchy. Every node needs an `id` and a " \
            "`kind`; the studio's own STATUS page asks for this with " \
            "`layout: \"lr\"` so the candidates stack down the page.",
      source: "#{SOURCE}hierarchy.json",
      doc: {
        "title" => "Front half: source -> trace -> gate",
        "layout" => "tb",
        "nodes" => [
          { "id" => "source", "label" => "source.png", "kind" => "root",
            "status" => "ok", "metrics" => { "colors" => 12, "size_kb" => 480 } },
          { "id" => "prep", "label" => "prep", "kind" => "step", "status" => "done",
            "metrics" => { "filter_speckle" => 2 } },
          { "id" => "vtracer", "label" => "VTracer", "kind" => "tool", "status" => "running",
            "metrics" => { "presets" => 3 } },
          { "id" => "gate_a", "label" => "Layer A gate", "kind" => "gate",
            "status" => "passed", "metrics" => { "hard" => 0, "advisory" => 1 } },
          { "id" => "gate_b", "label" => "Layer B gate", "kind" => "gate",
            "status" => "warning", "metrics" => { "hard" => 0, "advisory" => 3 } },
          { "id" => "record", "label" => "run record", "kind" => "data", "status" => "done" },
          { "id" => "report", "label" => "report page", "kind" => "note" }
        ],
        "edges" => [
          { "from" => "source", "to" => "prep" },
          { "from" => "prep", "to" => "vtracer" },
          { "from" => "vtracer", "to" => "gate_a" },
          { "from" => "gate_a", "to" => "gate_b" },
          { "from" => "gate_b", "to" => "record" },
          { "from" => "gate_b", "to" => "report" }
        ]
      }
    },
    {
      op: "log",
      half: "plot",
      title: "Event log",
      what: "Draws one row per recorded event, in the order given — the spec " \
            "order IS the time order. `pos` is a position in the run's own " \
            "candidate ranking, so a position that does not exist is not a log.",
      source: "#{SOURCE}events.json",
      doc: {
        "title" => "Run events (newest last: the spec order is the time order)",
        "size" => { "width" => 720, "height" => 260 },
        "events" => [
          { "t" => "00:00:01", "kind" => "start", "label" => "front_pipeline.sh started", "pos" => 1 },
          { "t" => "00:00:04", "kind" => "gate", "label" => "size gate: skipped (no dimensions block)", "pos" => 2 },
          { "t" => "00:00:09", "kind" => "read", "label" => "source.png -> 12 colours" },
          { "t" => "00:00:31", "kind" => "write", "label" => "3 candidates traced", "pos" => 3 },
          { "t" => "00:00:33", "kind" => "warn", "label" => "colour drift on c3: declared 12, rendered 9", "pos" => 4 },
          { "t" => "00:00:34", "kind" => "gate", "label" => "Layer A: pass (0 hard, 1 advisory)", "pos" => 5 },
          { "t" => "00:00:35", "kind" => "gate", "label" => "Layer B: pass (0 hard, 3 advisory)", "pos" => 6 },
          { "t" => "00:00:36", "kind" => "end", "label" => "run complete", "pos" => 7 }
        ]
      }
    },
    {
      op: "blender",
      half: "blender",
      title: "3D render",
      what: "Renders GEOMETRY in 3D and answers with PNG frame(s) or a frames " \
            "manifest — the only operation that renders rather than draws, and " \
            "the only one that can produce a GLB. `views` above 1 is what makes " \
            "the answer a manifest instead of a single image.",
      source: "#{SOURCE}blender_shapes.json",
      doc: {
        "title" => "tray",
        "elements" => [
          { "type" => "rect", "x" => 0, "y" => 0, "width" => 300, "height" => 200,
            "fill" => "#e04030" },
          { "type" => "circle", "cx" => 430, "cy" => 100, "r" => 90, "fill" => "#3080e0" },
          { "type" => "polyline", "points" => [[0, 260], [200, 340], [400, 260]],
            "stroke" => "#20c060", "stroke_width" => 6 },
          { "type" => "path", "d" => "M 20 380 C 120 460 300 460 400 380 Z",
            "fill" => "#ffcc00" }
        ],
        "tiling" => {
          "grid" => [2, 2],
          "cell" => [560, 480],
          "origin" => [20, 20],
          "element" => { "type" => "polygon", "points" => [[0, 0], [80, 0], [40, 60]],
                         "fill" => "#20c060" }
        },
        "extrude" => { "depth" => 40, "bevel_depth" => 6, "bevel_resolution" => 3 },
        "render" => {
          "size" => { "width" => 1024, "height" => 1024 },
          "views" => 4,
          "background" => "#1a1a24",
          "engine" => "workbench"
        },
        "export" => { "glb" => true }
      }
    }
  ].freeze

  # The plain trace spec, for contrast. Its `spec` IS the top level -- there is
  # no wrapper block for an svg job (Job#step_block returns the spec itself for
  # kind "svg", job.rb:434-438), which is the one thing an operator coming from
  # a bp spec gets wrong.
  TRACE = {
    "print_method" => "screen_print",
    "max_colors" => 6
  }.freeze

  TRACE_NOTE = "An svg job's spec IS the top level — there is no wrapper block, " \
               "unlike a bp job's {\"bp\": …}. It also needs an artwork: " \
               "job[input_path] must be the stored path POST /jobs/upload " \
               "returned, and only uploads are honoured.".freeze

  class << self
    def for_half(half)
      ALL.select { |e| e[:half] == half }
    end

    def for_op(op)
      ALL.find { |e| e[:op] == op.to_s }
    end

    # The whole `spec.bp` block as the STUDIO posts it: the op, the doc, and
    # `runs` for the one operation that takes it. This is the copy target — the
    # outer `job[spec]` value, not a fragment of it.
    def job_spec(op)
      entry = for_op(op)
      return nil unless entry

      spec = { "op" => entry[:op], "doc" => entry[:doc] }
      # The marker, not a placeholder: a reader who pastes this block gets a
      # parse error naming where the records are, rather than a runs array of
      # prose the service would refuse as "not a run record".
      spec["runs"] = [RUNS_ELIDED] if entry[:runs_note]
      spec
    end

    # Pretty-printed, because this is text a human pastes. `JSON.pretty_generate`
    # is one call here precisely because the HASH itself is hand-checked in the
    # tests: the formatting cannot be what is wrong.
    def job_spec_json(op)
      spec = job_spec(op)
      spec && JSON.pretty_generate(spec)
    end
  end
end
