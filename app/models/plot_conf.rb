# The chopshop-bp conf, mirrored from the repo that defines it.
#
# A faithful copy of the constants in chopshop-bp's `chopshop_bp/config.py`
# (the serve surface), the validation in `chopshop_bp/spec.py` and
# `chopshop_bp/query.py`, and the field registry in `chopshop_bp/metrics.py`
# — which is what the service actually reads. It is shown on the PLOT page so the
# settings, the chart types and the schema are visible instead of implied.
#
# IMPORTANT, and the reason this is a model and not a settings table: this page
# does not run the service and cannot change its environment. It shows what the
# service would be started with, validates a spec the way the service does, and
# hands you the env block and the JSON to copy. FluxConf carries the same
# honesty about the generation service; see its comment for the longer version.
#
# Anything here that drifts from config.py / spec.py / metric.py is a bug in THIS
# file. The values are transcribed, not paraphrased: a metric field name that is
# not the field name is worse than no field name, because the chart drawn
# against it would be drawn against nothing.
# blend-plot: PlotConf is the DOCUMENT half of one service — plot draws documents, BlenderConf renders 3D (blend), and both halves live in the single repo chopshop-bp.
class PlotConf
  SERVICE = "chopshop-bp".freeze

  # chopshop_bp/config.py, verbatim.
  DEFAULT_BIND = "127.0.0.1".freeze
  DEFAULT_PORT = 8796
  MAX_BODY_BYTES = 8 * 1024 * 1024

  # The service's HTTP surface, as seen from here. Listed because the contract is
  # language-agnostic: these routes are how ANY client drives a conforming
  # backend, not something shaped around this studio. chopshop_bp/server.py
  # builds its route table from its OPERATIONS tuple and adds FILE_ROUTE and
  # /health, and docs/contract.md tabulates the same eight — six operations, the
  # file route and the health route. A route the service answers and this list
  # omits is this file drifting.
  API = {
    routes: "POST /generate, POST /digest, POST /query, POST /tree, POST /log, " \
            "POST /blender, GET /files/<name>, GET /health",
    success: "image/svg+xml — the SVG the operation drew (POST /blender answers " \
             "image/png for one view, or a JSON frames manifest plus a GLB export)",
    refusal: "application/json — {\"error\": …, \"kind\": …}"
  }.freeze

  # The runner label the studio files this service under, and the env vars that
  # place it. The studio's runner map is env-driven (Job.runner_urls): nothing
  # here names a host.
  RUNNER_LABEL = "plot".freeze
  RUNNER_URL_ENV = "CHOPSHOP_RUNNER_PLOT_URL".freeze
  RUNNER_KIND_ENV = "CHOPSHOP_RUNNER_PLOT_KIND".freeze

  # chopshop_bp/metrics.py, verbatim: the flat, versioned schema every chart is
  # drawn from. Bump-versioned, so a reader refuses a version it does not know.
  METRICS_VERSION = 1

  NUMERIC_FIELDS = {
    "hard" => "hard gates failed (both layers)",
    "advisory" => "advisories (both layers)",
    "layer_a_hard" => "Layer A (source validation) hard gates",
    "layer_a_advisory" => "Layer A advisories",
    "layer_b_hard" => "Layer B (render preflight) hard gates",
    "layer_b_advisory" => "Layer B advisories",
    "declared_colors" => "colours declared in the spec/SVG",
    "rendered_ink_colors" => "distinct inks in the rendered output",
    "rendered_distinct_colors" => "distinct colours in the render (manifest)",
    "node_count_total" => "total path nodes",
    "node_count_max" => "max path nodes on one path",
    "file_size" => "SVG file size in bytes",
    "mae" => "mean absolute error, all pixels",
    "mae_art" => "mean absolute error, artwork pixels only",
    "p95" => "95th-percentile pixel error",
    "within10" => "fraction of pixels within 10 units",
    "tac_exact" => "thread-alike colour (TAC) match flag",
    "rendered_continuous_tone" => "continuous tone detected",
    "hard_findings" => "manifest hard findings",
    "advisory_findings" => "manifest advisory findings",
    "color_count" => "static colour count (manifest)"
  }.freeze

  CATEGORICAL_FIELDS = {
    "preset" => "trace preset name",
    "variant" => "sweep variant (source/inverse/pitch/…)",
    "passed" => "both layers passed (bool)",
    "fidelity_verdict" => "faithful|drift|colour_dropped|artwork_lost",
    "label" => "human decision label",
    "selected" => "human decision selected (bool)"
  }.freeze

  # Runs are keyed by source hash + recipe hash, which is what makes "recipe A vs
  # recipe B on one source" and "one recipe across sources" comparable at all.
  IDENTITY_FIELDS = %w[candidate_id run_stem source_sha256 recipe_hash].freeze
  IDENTITY_GLOSS = {
    "candidate_id" => "the candidate's own id within its run",
    "run_stem" => "the run record the row came from",
    "source_sha256" => "the source the candidates were traced from",
    "recipe_hash" => "the sweep recipe (preset, filter_speckle, hierarchical, use_palette), hashed stably"
  }.freeze

  # chopshop_bp/spec.py — the geometry element types and the fields each one is
  # REQUIRED to carry. A circle without its centre is an invalid spec (exit 3),
  # never a circle at the origin.
  ELEMENTS = {
    "rect" => %w[x y width height],
    "circle" => %w[cx cy r],
    "ellipse" => %w[cx cy rx ry],
    "polygon" => %w[points],
    "polyline" => %w[points],
    "line" => %w[x1 y1 x2 y2],
    "path" => %w[d]
  }.freeze

  CANVAS_FIELDS = %w[width height].freeze
  TILING_FIELDS = %w[grid cell origin element].freeze

  # docs/contract.md — the chart types, per operation, and the size the digest
  # operation defaults to when the spec does not set one.
  DIGEST_CHARTS = %w[bar line scatter].freeze
  QUERY_CHARTS = %w[scatter pareto diff].freeze
  # The query charts that take two axes. `diff` is a query chart that takes two
  # SELECTORS instead, which is why the axis rule does not apply to it — and why
  # this is a second list rather than a `chart != "diff"` test scattered about.
  QUERY_AXIS_CHARTS = (QUERY_CHARTS - %w[diff]).freeze
  # The operations that take chart axes at all: `generate` takes a geometry spec.
  AXIS_OPS = %w[digest query].freeze
  DEFAULT_SIZE = { "width" => 800, "height" => 400 }.freeze

  # The SIX operations the service exposes, with the shape of what each one
  # takes. chopshop_bp/server.py defines OPERATIONS = ("generate", "digest",
  # "query", "tree", "log", "blender") as the route table AND the engine's method
  # names, and docs/contract.md tabulates all six — so this list is the service's,
  # and holding only the first three was this file drifting from it.
  #
  # The studio's own Run Job form sends the first three only (Job::PLOT_OPS):
  # tree, log and blender are on this page because this page documents the
  # CONTRACT, not what this app's client happens to implement yet. The envelope
  # is `{"op": <name>, "spec": {…}}`; a bare spec is accepted too, but an
  # envelope whose `op` disagrees with the route asked for is refused rather
  # than best-effort drawn.
  OPERATIONS = [
    { "name" => "generate", "op" => "generate", "takes" => "a geometry spec",
      "draws" => "shapes, tiling and patterns — a programmatic SOURCE for the front half" },
    { "name" => "digest", "op" => "digest", "takes" => "a metrics spec",
      "draws" => "one run's numbers as a bar, line or scatter chart" },
    { "name" => "query", "op" => "query",
      "takes" => "run records + a chart spec (`{\"runs\": …, \"spec\": …}`)",
      "draws" => "cross-run scatter, a Pareto trade-off frontier, or a two-way diff" },
    { "name" => "tree", "op" => "tree", "takes" => "a hierarchy spec (nodes + edges)",
      "draws" => "a layered diagram — roots, depth, one slot per leaf, in id order" },
    { "name" => "log", "op" => "log", "takes" => "an event spec (a list of events)",
      "draws" => "one row per event, in the order given — the spec order IS the time order" },
    { "name" => "blender", "op" => "blender",
      "takes" => "a geometry spec, rendered in 3D",
      "draws" => "rendered FILES, not a document — one view as `image/png`, or a " \
                 "frames manifest plus a GLB export name" }
  ].freeze

  # ---------------------------------------------------------------------------
  # The page's cards. Same arrangement as the FLUX page: four settings cards in a
  # 2x2 grid, each documenting its own fields through the same array that renders
  # them, so the <dt> list and the <label>s cannot drift.
  #
  # `env` is the variable the service (or the studio's runner map) actually
  # reads. A field with `env: nil` is a request parameter or a contract fact, not
  # environment. The reference cards are `type: :static`: they report what the
  # contract accepts rather than offering an input that would do nothing.
  # ---------------------------------------------------------------------------
  CARDS = [
    {
      title: "Service",
      help: "help-plot-service",
      blurb: "How the studio reaches the service. All of it is environment: the " \
             "service reads its three variables at call time and the studio " \
             "reads its runner map the same way, so neither repo names a host.",
      fields: [
        { label: "bind", env: "CHOPSHOP_BP_BIND", type: :text, default: DEFAULT_BIND,
          hint: "Loopback by default, deliberately.",
          help: "The address the service listens on. Loopback rather than " \
                "0.0.0.0: a service that renders SVGs from specs has no business " \
                "on every interface. chopshop-svg's runner.py ships 0.0.0.0 and " \
                "its own contract doc calls that a footgun. Reaching this from " \
                "another machine is an explicit act — set it to the private " \
                "address, and set the token with it." },
        { label: "port", env: "CHOPSHOP_BP_PORT", type: :number, default: DEFAULT_PORT,
          min: 1, max: 65_535,
          hint: "8796: clear of the mock runner (8790), the SVG runner (8791) and FLUX (8795).",
          help: "8796 keeps it in the shop's range but off every port already " \
                "taken: the studio's mock runner owns 8790, chopshop-svg's runner " \
                "owns 8791 and the FLUX service owns 8795. A collision here would " \
                "look like the wrong service answering." },
        { label: "token", env: "CHOPSHOP_BP_TOKEN", type: :text, default: "",
          hint: "Blank means every route is open.",
          help: "A bearer token, enforced on every route except /health when it " \
                "is set. /health is exempt on purpose: a health check that " \
                "requires the secret cannot be used to decide whether to send the " \
                "secret. Blank means open, which is why the bind default is " \
                "loopback." },
        { label: "runner url", env: RUNNER_URL_ENV, type: :text,
          default: "http://#{DEFAULT_BIND}:#{DEFAULT_PORT}",
          hint: "Where the studio calls it. This is the whole seam.",
          help: "The studio half of the same pair. A runner is a URL and a kind " \
                "(Job.runner_urls / Job.runner_kinds), so the studio does not " \
                "know which machine the service is on and the service does not " \
                "know which machine the studio is on — moving either end is an " \
                "edit to one environment variable." },
        { label: "runner kind", env: RUNNER_KIND_ENV, type: :text, default: RUNNER_LABEL,
          hint: "The kind is what makes it a plot runner rather than a pipeline one.",
          help: "What the runner DOES, not where it is. \"plot\" is one of the Run " \
                "Job KINDS beside svg, flux and blender (Job::JOB_KINDS): the label " \
                "speaks chopshop-bp's serve API rather than the runner contract, " \
                "holds no job state and traces nothing — which is exactly why it " \
                "can never be a hand-off target. A plot job is a real Run Job " \
                "target all the same: it draws its document and is DONE when the " \
                "answer lands, with nothing dispatched to a pipeline." }
      ]
    },
    {
      title: "Operations",
      help: "help-plot-operations",
      blurb: "Six operations, one JSON contract: five answer with one SVG document " \
             "and `blender` answers with rendered files — and a JSON refusal " \
             "instead of a partial document when the spec is invalid.",
      fields: OPERATIONS.map do |op|
        { label: op["name"], env: nil, type: :static, default: op["takes"],
          hint: op["draws"],
          help: "`#{op['name']}` takes #{op['takes']} and draws #{op['draws']}. " \
                "An invalid spec is refused — SpecError on every operation but " \
                "`query`, which raises QueryError — and never silently drawn as " \
                "something else." }
      end
    },
    {
      title: "Charts",
      help: "help-plot-charts",
      blurb: "The chart types the contract defines. The axis is always the " \
             "user's choice: no chart hardcodes a field.",
      fields: [
        { label: "digest charts", env: nil, type: :static,
          default: DIGEST_CHARTS.join(", "),
          hint: "One run's numbers. Auto-scaled so a chart is never clipped.",
          help: "`bar` and `line` read `labels` plus `series` (or a bare " \
                "`values` array); `scatter` reads `points`. The value axis is " \
                "auto-scaled to fit the data and an axis line is always drawn, " \
                "so a chart is readable with no metadata beyond the spec." },
        { label: "query charts", env: nil, type: :static,
          default: QUERY_CHARTS.join(", "),
          hint: "Across runs, over the record set.",
          help: "`scatter` plots every candidate across every run on the two " \
                "numeric fields you name; `pareto` highlights the non-dominated " \
                "frontier (non-domination is computed on DATA values, never on " \
                "screen pixels, where y is inverted); `diff` puts two candidates " \
                "or two recipes side by side and reports what moved." },
        { label: "default size", env: nil, type: :static,
          default: "#{DEFAULT_SIZE['width']} x #{DEFAULT_SIZE['height']}",
          hint: "When a digest spec sets no `size`.",
          help: "A digest spec's optional `size` overrides it; a generate spec " \
                "sizes itself from its `canvas`. Coordinates are SVG user units " \
                "(CSS pixels), y growing downward." }
      ]
    },
    {
      title: "Geometry",
      help: "help-plot-geometry",
      blurb: "What a generate spec may draw. Every positional field in the table " \
             "is required — a circle without its centre is refused.",
      fields: [
        { label: "elements", env: nil, type: :static, default: ELEMENTS.keys.join(", "),
          hint: "Seven types; the FIELDS popup lists what each one must carry.",
          help: "The element types a generate spec may use. Unknown types and " \
                "unknown fields on a known type are both refused, so a typo is a " \
                "SpecError rather than an element that silently never draws." },
        { label: "canvas", env: nil, type: :static, default: CANVAS_FIELDS.join(", "),
          hint: "Required, positive numbers.",
          help: "The canvas is what the emitted SVG's root carries: `width`, " \
                "`height` and a matching `viewBox`. That is what lets the " \
                "pipeline consume a generated SVG as a normal vector candidate." },
        { label: "tiling", env: nil, type: :static, default: TILING_FIELDS.join(", "),
          hint: "Optional: repeats `element` across a `grid` of cells.",
          help: "An optional block that repeats one element across a `grid` of " \
                "cells of size `cell`, starting at `origin`; the element's own " \
                "coordinates are offsets within its cell. Tiling and `elements` " \
                "compose, and tiled elements draw first." }
      ]
    }
  ].freeze

  # The live check, which runs the contract's own rules in the browser: pick an
  # operation, a chart and two axes, and see whether the service would accept it.
  CHECKS = {
    title: "Checks",
    help: "help-plot-checks",
    blurb: "What the contract does with the combination above, in its own order. " \
           "This page does not run the service; it runs the same rules, so a " \
           "spec the service would reject is rejectable before anything is drawn. " \
           "Nothing here ranks or recommends — an axis choice is yours, and this " \
           "only says whether the contract can draw it.",
    fields: [
      { label: "op", env: nil, type: :select, default: "query",
        options: OPERATIONS.map { |o| o["name"] },
        hint: "Which operation you are composing for.",
        help: "The operation the combination is checked against. Only " \
              "`#{AXIS_OPS.join('` and `')}` take chart axes at all — `generate` " \
              "takes a geometry spec, `tree` a hierarchy, `log` an event list and " \
              "`blender` a geometry spec it renders in 3D — so the axis rules below " \
              "apply to digest and query only, which is exactly what the service " \
              "enforces." },
      { label: "chart", env: nil, type: :select, default: "scatter",
        options: QUERY_CHARTS + DIGEST_CHARTS,
        hint: "scatter / pareto / diff draw over runs; bar / line / scatter over one run.",
        help: "The chart type. `scatter`, `pareto` and `diff` belong to the " \
              "query operation and read `.run.json` records; `bar`, `line` and " \
              "`scatter` belong to digest and read a single `data` block. The two " \
              "operations do not share chart names: query's scatter is not " \
              "digest's." },
      { label: "x", env: nil, type: :select, default: "node_count_max", options: NUMERIC_FIELDS.keys,
        hint: "Any numeric metric field. The choice is the user's.",
        help: "The x axis, for scatter and pareto. It must be a NUMERIC metric " \
              "field: a categorical one is rejected, not approximated, because " \
              "plotting a label's ordinal position is inventing a number." },
      { label: "y", env: nil, type: :select, default: "mae_art", options: NUMERIC_FIELDS.keys,
        hint: "Minimise it with x on pareto — the frontier, never a winner.",
        help: "The y axis, under the same rule as x. On `pareto` both axes are " \
              "minimised, and the frontier is highlighted rather than collapsed " \
              "to a single number: the engine ranks and visualises, and never " \
              "chooses." },
      { label: "color", env: nil, type: :select, default: "",
        options: [""] + CATEGORICAL_FIELDS.keys,
        hint: "Optional. A categorical field.",
        help: "Optional colouring by a categorical field (preset, verdict, " \
              "pass/fail, label). Numeric fields are refused here for the same " \
              "reason: a colour key with 400 distinct values is not a key." }
    ]
  }.freeze

  # The schema card: the foundation the whole engine reads. It answers rather
  # than configures, which is why it is its own full-width card like the FLUX
  # page's Checks card.
  SCHEMA = {
    title: "Metrics schema",
    help: "help-plot-schema",
    blurb: "One flat, versioned row per candidate is what every chart reads, so no " \
           "chart hardcodes a field and a chart written against this version keeps " \
           "working until it bumps. Missing data is a STATE, not a zero — a skipped " \
           "gate renders as absent, never as 0.",
    entries: [
      ["metrics_version", "The schema version, currently #{METRICS_VERSION}. A reader " \
                          "refuses a version it does not know. Bump it when a field is " \
                          "renamed, added or removed."],
      ["flat and boring", "Field names are `node_count_max`, never " \
                          "`static.path_nodes_max`, so the numeric fields ARE the " \
                          "selectable axes and the categorical ones are for " \
                          "colouring, filtering and grouping."],
      ["missing is not zero", "A gate that was skipped renders as absent (`None`), " \
                              "never as `0`. A chart that plots 0 for a missing " \
                              "measurement is lying."],
      ["keyed by hash", "Runs are indexed by `source_sha256` + `recipe_hash`, the " \
                        "recipe hash being the sweep parameters (preset, " \
                        "filter_speckle, hierarchical, use_palette) hashed " \
                        "stably. That is what makes two recipes comparable on one " \
                        "source, and one recipe comparable across sources."]
    ]
  }.freeze

  # The two ways this is deployed. The same code either way: the only difference
  # is two environment variables, one on each side — and one of them is a token,
  # because a shared network is not a private one.
  PLACEMENT = {
    title: "Where it runs",
    help: "help-plot-placement",
    blurb: "This page configures a SERVICE. The service and this studio are two " \
           "programs talking over HTTP, joined by a URL — so the same pair runs on " \
           "one box or on two, and nothing here names a host.",
    shapes: [
      ["one box", "The service and this studio on the same machine. The service " \
                  "listens on #{DEFAULT_BIND} — loopback, so nothing on the " \
                  "network can reach it — and the studio's runner URL is a " \
                  "loopback address too. Nothing to expose, nothing to " \
                  "authenticate. This is the shape a single workstation wants.",
       [[RUNNER_KIND_ENV, "where the studio learns what it is talking to"],
        ["CHOPSHOP_BP_BIND=#{DEFAULT_BIND}", "where the service listens — loopback"],
        ["#{RUNNER_URL_ENV}=http://127.0.0.1:#{DEFAULT_PORT}", "where the studio calls"]]],
      ["split", "The studio on one machine, the rendering host on another. Over a " \
                "private network (a tailnet, a LAN, a tunnel) that host sets the " \
                "bind to the address the studio can reach it on AND sets a token; " \
                "the studio sets its runner URL to that same address. Both are " \
                "required together: an endpoint on a shared network with no token " \
                "is somebody else's renderer.",
       [[RUNNER_KIND_ENV, "unchanged: the kind never encodes the topology"],
        ["CHOPSHOP_BP_BIND=<the private address>", "on that host: where it listens"],
        ["CHOPSHOP_BP_TOKEN=<shared secret>", "on that host: who may call it"],
        ["#{RUNNER_URL_ENV}=http://<that address>:#{DEFAULT_PORT}",
         "on the studio box: where the service is"]]]
    ],
    entries: [
      ["one box / split", "The two deployments this supports. They differ only in " \
                          "the URLs and whether a token is set — not in code, not " \
                          "in a build, not in a config file in either repo."],
      ["the URL is the whole seam", "A runner is a URL and a kind. Neither repo is " \
                                    "allowed to record a host, so moving either end " \
                                    "is an edit to one environment variable."],
      ["other applications", "The service is a plain HTTP API — #{API[:routes]} — " \
                             "and this studio is one client of it, not its reason " \
                             "for existing. Anything that can send a POST can ask " \
                             "for an SVG without knowing this studio exists."],
      ["turning it off", "The service is a program you start and stop, so stopping " \
                         "it is a normal state, not a fault: the nav's runner pill " \
                         "shows it down, and a caller gets the connection error " \
                         "rather than a hang. Start it again and nothing needs " \
                         "reconfiguring."],
      ["the answer comes back in the response", "The SVG the operation drew IS the " \
                                              "response body, so a 2D geometry or a " \
                                              "chart is one round trip rather than " \
                                              "two. `blender` is the one exception, " \
                                              "and the service documents it as one: " \
                                              "its rendered frames and GLB come back " \
                                              "by name from `GET /files/<name>`, the " \
                                              "same flat-basename route — with the " \
                                              "same containment check — that " \
                                              "chopshop-flux serves its rasters from."]
    ]
  }.freeze

  class << self
    def numeric_field?(name)
      NUMERIC_FIELDS.key?(name.to_s)
    end

    def categorical_field?(name)
      CATEGORICAL_FIELDS.key?(name.to_s)
    end

    def known_field?(name)
      numeric_field?(name) || categorical_field?(name) || IDENTITY_FIELDS.include?(name.to_s)
    end

    # Everything the page needs to check a combination, handed to the browser as
    # one JSON blob so the rules are NOT restated in JavaScript. A second copy of
    # a rule is a second thing to get wrong.
    def facts
      {
        "service" => SERVICE,
        "operations" => OPERATIONS.map { |o| o["name"] },
        # What each operation takes and draws, so the browser's note for a
        # non-axis operation is the service's own description rather than a
        # sentence written twice.
        "opSpecs" => OPERATIONS.to_h do |o|
          [o["name"], { "takes" => o["takes"], "draws" => o["draws"] }]
        end,
        "axisOps" => AXIS_OPS,
        "digestCharts" => DIGEST_CHARTS,
        "queryCharts" => QUERY_CHARTS,
        "queryAxisCharts" => QUERY_AXIS_CHARTS,
        "numericFields" => NUMERIC_FIELDS.keys,
        "categoricalFields" => CATEGORICAL_FIELDS.keys,
        "metricsVersion" => METRICS_VERSION,
        "defaultBind" => DEFAULT_BIND,
        "defaultPort" => DEFAULT_PORT
      }
    end

    # Validate a combination exactly as the service does, in the service's own
    # sentences. Returns the problems (a violation the service would refuse) and
    # the notes (something true about the choice that is not a refusal) — the
    # same two-channel shape FluxConf.validate uses, because "refused" and
    # "worth knowing" are different answers.
    def validate(op:, chart:, x: nil, y: nil, color: nil)
      problems = []
      notes = []

      if chart.to_s.empty?
        problems << "chart is required: #{DIGEST_CHARTS.join(', ')} for digest, " \
                    "#{QUERY_CHARTS.join(', ')} for query"
        return { problems: problems, notes: notes }
      end

      unless DIGEST_CHARTS.include?(chart.to_s) || QUERY_CHARTS.include?(chart.to_s)
        problems << "'chart' must be one of #{DIGEST_CHARTS.join(', ')} for digest " \
                    "or #{QUERY_CHARTS.join(', ')} for query, got #{chart.inspect}"
        return { problems: problems, notes: notes }
      end

      case op.to_s
      when "generate", "tree", "log", "blender"
        # The operations that take a document of their OWN rather than a chart, so
        # there are no axes to check. generate keeps its own sentence because the
        # geometry vocabulary it accepts is worth naming; the rest are described
        # from OPERATIONS, which is the same array the Operations card renders, so
        # an operation added there cannot go undescribed here.
        if op.to_s == "generate"
          notes << "generate takes no chart: it takes a geometry spec (" \
                   "#{ELEMENTS.keys.join(', ')} on a canvas) and draws the SVG directly."
        else
          entry = OPERATIONS.find { |o| o["name"] == op.to_s }
          notes << "#{op} takes no chart: it takes #{entry['takes']} and draws " \
                   "#{entry['draws']}."
        end
        return { problems: problems, notes: notes }
      when "digest"
        # Membership, not exclusion: `scatter` is a chart in BOTH operations, so
        # "is it digest's" and "is it not query's" are different questions.
        unless DIGEST_CHARTS.include?(chart.to_s)
          problems << "#{chart} is a query chart: the digest operation reads one " \
                      "run's numbers and knows #{DIGEST_CHARTS.join(', ')} only."
        end
      when "query"
        if QUERY_CHARTS.include?(chart.to_s)
          if QUERY_AXIS_CHARTS.include?(chart.to_s)
            # The axis rule, in the contract's own terms: a categorical field on
            # an axis is refused, never approximated by its ordinal position.
            { "x" => x, "y" => y }.each do |axis, field|
              if field.to_s.empty?
                problems << "#{chart}: #{axis} is required"
              elsif !numeric_field?(field)
                problems << "#{chart}: axis '#{field}' is not a numeric metric field"
              end
            end
            if color.present? && !categorical_field?(color)
              problems << "#{chart}: 'color' must be a categorical field"
            end
          end
        else
          problems << "#{chart} is a digest chart: the query operation reads run " \
                      "records and knows #{QUERY_CHARTS.join(', ')} only."
        end
      else
        problems << "'op' must be one of #{OPERATIONS.map { |o| o['name'] }.join(', ')}, " \
                    "got #{op.inspect}"
      end

      notes << "the axis is the user's choice — nothing here ranks the fields or " \
               "recommends one" unless problems.any?
      { problems: problems, notes: notes }
    end
  end
end
