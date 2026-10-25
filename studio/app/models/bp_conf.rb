# The chopshop-bp conf, mirrored from the repo that defines it.
#
# A faithful copy of the constants in chopshop-bp's `chopshop_bp/config.py`
# (the serve surface), the validation in `chopshop_bp/spec.py` and
# `chopshop_bp/query.py`, the blender operation in `chopshop_bp/blender.py`
# and the field registry in `chopshop_bp/metrics.py` — which is what the
# service actually reads. It is shown on the BP page so the settings, the
# chart types and the schema are visible instead of implied.
#
# IMPORTANT, and the reason this is a model and not a settings table: this
# page does not run the service and cannot change its environment. It shows
# what the service would be started with, validates a spec the way the
# service does, and hands you the env block and the JSON to copy. FluxConf
# carries the same honesty about the generation service; see its comment for
# the longer version.
#
# Anything here that drifts from config.py / spec.py / blender.py /
# metrics.py is a bug in THIS file. The values are transcribed, not
# paraphrased: a metric field name that is not the field name is worse than
# no field name, because the chart drawn against it would be drawn against
# nothing.
#
# ONE module, TWO halves, because there is ONE service: the plot half
# (BpConf::Plot) draws documents and the blender half (BpConf::Blender)
# renders 3D, and both live in the single repo chopshop-bp. The constants
# the halves share — the service-wide config.py constants and the element
# vocabulary spec.py defines for BOTH operations — are stated ONCE, at
# BpConf's own level, so neither half can hold a second copy of them.
# blend-plot: BpConf is both halves of ONE service in the repo chopshop-bp —
# BpConf::Plot draws documents (plot), BpConf::Blender renders 3D (blend),
# and neither half is a server of its own.
module BpConf
  # chopshop_bp/config.py, verbatim: the service-wide constants. One
  # service, so one bind, one port, one body cap — the blender operation
  # is a ROUTE on this service, not a second server, which is why the
  # blender half carries no port of its own.
  SERVICE = "chopshop-bp".freeze
  DEFAULT_BIND = "127.0.0.1".freeze
  DEFAULT_PORT = 8796
  MAX_BODY_BYTES = 8 * 1024 * 1024

  # chopshop_bp/spec.py, verbatim: the geometry element types and the
  # fields each one is REQUIRED to carry. This is the SHARED vocabulary —
  # spec.py's check_element is public precisely because the blender
  # operation validates the SAME element vocabulary as generate ("one
  # implementation, so a spec that one operation accepts cannot be
  # silently a different shape on the other"). A circle without its centre
  # is an invalid spec (exit 3), never a circle at the origin.
  #
  # `text` is in the vocabulary: spec.py validates it and contract.md
  # documents it. The blender operation REFUSES it by name (a label has
  # no 3D reading — see the Blender half's Scene card), but the table is
  # the vocabulary both halves build from, so it is stated here once.
  ELEMENTS = {
    "rect" => %w[x y width height],
    "circle" => %w[cx cy r],
    "ellipse" => %w[cx cy rx ry],
    "polygon" => %w[points],
    "polyline" => %w[points],
    "line" => %w[x1 y1 x2 y2],
    "path" => %w[d],
    "text" => %w[x y content]
  }.freeze

  # spec.py's check_tiling, also shared: "a tiling block means the same
  # thing wherever it appears". One block, one field list, stated once.
  TILING_FIELDS = %w[grid cell origin element].freeze

  # =========================================================================
  # The PLOT half — the document-drawing operations (generate, digest,
  # query, tree, log). Everything below is the plot half's own: its
  # metrics schema, its chart lists, its six-operation contract.
  # =========================================================================
  module Plot
    # The runner label the studio files this service under, and the env vars
    # that place it. The studio's runner map is env-driven (Job.runner_urls):
    # nothing here names a host.
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

    CANVAS_FIELDS = %w[width height].freeze

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
        # A display-only `select_label` for the Run Job dropdown: `takes` below is
        # the CONTRACT's wording and embeds an example payload, which reads as JSON
        # noise clipped inside a <select>. The dropdown shows this instead; the /bp
        # Operations card keeps rendering `takes`. Studio-owned, like FluxConf's own
        # display fields: not part of the sibling parity comparison.
        "select_label" => "every candidate across every run",
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
    # reads. A field with `env: nil` is a request parameter or a contract fact,
    # not environment. The reference cards are `type: :static`: they report what
    # the contract accepts rather than offering an input that would do nothing.
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
            hint: "8796: clear of the mock runner (8790), the SVG runner (8787) and FLUX (8795).",
            help: "8796 keeps it in the shop's range but off every port already " \
                  "taken: the studio's mock runner owns 8790, chopshop-svg's runner " \
                  "owns 8787 and the FLUX service owns 8795. A collision here would " \
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
            hint: "Eight types; the FIELDS popup lists what each one must carry.",
            help: "The element types a generate spec may use — the vocabulary " \
                  "chopshop_bp/spec.py validates, shared with the blender " \
                  "operation. Unknown types and unknown fields on a known type are " \
                  "both refused, so a typo is a SpecError rather than an element " \
                  "that silently never draws." },
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
      # same two-channel shape BpConf::Blender.validate uses, because "refused" and
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

  # =========================================================================
  # The BLENDER half — the one operation that renders 3D. Everything below is
  # the blender half's own: its document vocabulary's optional blocks, its
  # render defaults, its two response shapes.
  # =========================================================================
  module Blender
    # The operation and the route it is served on. Named once: an envelope whose
    # `op` disagrees with the route asked for is refused by the service rather
    # than best-effort rendered.
    OP = "blender".freeze
    ROUTE = "/blender".freeze

    # The two success shapes and the one refusal that is a STATE rather than a
    # fault. Every caller branches on these, which is why they are named here
    # rather than described in prose on the page only.
    SUCCESS_FRAME = "image/png".freeze
    SUCCESS_MANIFEST = "application/json".freeze
    UNAVAILABLE = 503

    # The service's HTTP surface, as seen from here.
    API = {
      routes: "POST /blender, GET /files/<name>, GET /health",
      success: "#{SUCCESS_FRAME} (one view, no GLB export) or #{SUCCESS_MANIFEST} " \
               "(several views, or an export: {frames: [names], glb: name-or-null})",
      refusal: "application/json — {\"error\": …, \"kind\": …}; #{UNAVAILABLE} when Blender is absent"
    }.freeze

    # The runner label the studio files this operation under, and the env vars
    # that place it. The studio's runner map is env-driven (Job.runner_urls):
    # nothing here names a host.
    RUNNER_LABEL = "blender".freeze
    RUNNER_URL_ENV = "CHOPSHOP_RUNNER_BLENDER_URL".freeze
    RUNNER_KIND_ENV = "CHOPSHOP_RUNNER_BLENDER_KIND".freeze

    # A document is an `elements` list (optionally tiled and extruded). The
    # service has no other document shape — a document that carries no elements
    # list is the refusal the Job validation moves to the form.
    DOC_KEYS = %w[elements].freeze

    # The blocks that decorate an ELEMENTS document. Each is optional, so each key
    # below is the contract's and each default is the CONTRACT'S default (chopshop-
    # plot's chopshop_bp/blender.py DEFAULT_DEPTH/DEFAULT_BEVEL_DEPTH/
    # DEFAULT_BEVEL_RESOLUTION), not a studio invention — a render the operator
    # runs without an extrude block must record the same numbers the service
    # actually extruded with, or the page lies about what was rendered.
    EXTRUDE_FIELDS = %w[depth bevel_depth bevel_resolution].freeze
    EXTRUDE_DEFAULTS = { "depth" => 0.5, "bevel_depth" => 0.02,
                         "bevel_resolution" => 2 }.freeze

    RENDER_FIELDS = %w[size views background engine].freeze
    SIZE_FIELDS = %w[width height].freeze
    DEFAULT_SIZE = { "width" => 1024, "height" => 1024 }.freeze
    # 1 is the frame the studio stores as the deliverable; anything higher asks
    # the service for a frames MANIFEST instead, which the client then fetches
    # from /files/<name> one frame at a time. The choices the Checks card offers
    # for its own control: a UI list, but named here rather than typed into the
    # view, so the page cannot drift from the count the manifest rule is about.
    DEFAULT_VIEWS = 1
    VIEW_CHOICES = [1, 2, 4, 8].freeze
    DEFAULT_BACKGROUND = "#1a1a24".freeze
    # The SPEC vocabulary for render.engine, the two words the contract accepts
    # (chopshop-bp maps them to Blender's internal identifiers — 'eevee' ->
    # BLENDER_EEVEE_NEXT, 'workbench' -> BLENDER_WORKBENCH — so the operator never
    # spells a Blender internal name). A spec carrying a name outside this pair is
    # a 400 refusal by the service, which is why the exact strings matter here.
    ENGINES = %w[workbench eevee].freeze
    DEFAULT_ENGINE = "workbench".freeze

    EXPORT_FIELDS = %w[glb].freeze
    # Off unless a document asks: an export writes a second file on the runner and
    # names it in the manifest's `glb`, so it is never something to do by default.
    DEFAULT_GLB = false

    # An EXAMPLE document for the Checks card and the JSON popup, composed from
    # this page's own vocabulary (the element types above, the render block below)
    # rather than quoted from the service's tests: it is here to be edited, and it
    # claims nothing about what the service ships as a sample.
    DEFAULT_DOCUMENT = {
      "elements" => [
        { "type" => "rect", "x" => 0, "y" => 0, "width" => 200, "height" => 120 },
        { "type" => "circle", "cx" => 300, "cy" => 60, "r" => 40 }
      ],
      "extrude" => { "depth" => EXTRUDE_DEFAULTS["depth"] },
      "render" => { "size" => DEFAULT_SIZE, "views" => DEFAULT_VIEWS,
                    "background" => DEFAULT_BACKGROUND, "engine" => DEFAULT_ENGINE }
    }.freeze

    # The live check, which runs the contract's own rules in the browser: paste a
    # document and see whether the service would accept it. Its tested twin is
    # BpConf::Blender.validate.
    CHECKS = {
      title: "Checks",
      help: "help-blender-checks",
      blurb: "What the contract does with the document above, in its own order. " \
             "This page does not run the service; it runs the same rules, so a " \
             "document the service would reject is rejectable before anything is " \
             "rendered. Nothing here ranks or recommends — a size, an engine and a " \
             "view count are yours, and this only says whether the contract can " \
             "render them.",
      fields: [
        { label: "document", env: nil, type: :document, default: DEFAULT_DOCUMENT,
          hint: "The geometry document, as it would be posted.",
          help: "The whole document: `elements` plus the optional tiling, extrude, " \
                "render and export blocks. It is parsed here before anything is " \
                "waited on, so a document that does not parse is a form error " \
                "rather than a failed render." },
        { label: "views", env: nil, type: :select, default: DEFAULT_VIEWS,
          options: VIEW_CHOICES,
          hint: "1 answers with the frame; more answers with a manifest.",
          help: "The view count, as `render.views`. It is the field that decides " \
                "the RESPONSE SHAPE, so it is stated here as well as read out of " \
                "the document: #{DEFAULT_VIEWS} answers with " \
                "#{SUCCESS_FRAME}, more answers with #{SUCCESS_MANIFEST} and the " \
                "client fetches each frame from /files/<name>." },
        { label: "engine", env: nil, type: :select, default: DEFAULT_ENGINE,
          options: ENGINES,
          hint: "The spec's render.engine vocabulary.",
          help: "As `render.engine`. #{ENGINES.join(' and ')} are the spec's two " \
                "words — #{DEFAULT_ENGINE} is the fast rasteriser (needs no GPU), " \
                "eevee is the shaded engine. chopshop-bp maps them to Blender's " \
                "internal identifiers, so a name outside this pair is a 400 " \
                "refusal rather than a fallback to the default." }
      ]
    }.freeze

    # What each response means, in the two shapes plus the one state. Shown on the
    # page as its own card, because this is what every caller branches on.
    RESPONSES = [
      ["one view, no GLB", "POST #{ROUTE} answers with #{SUCCESS_FRAME}: the rendered " \
                   "frame IS the response body, so a single-view render with no " \
                   "export is one round trip and the studio stores the bytes " \
                   "directly."],
      ["several views, or an export", "POST #{ROUTE} answers with #{SUCCESS_MANIFEST}: " \
                  "`{\"frames\": [names], \"glb\": name-or-null}`. The frames are " \
                  "NOT in the response — each one is fetched from " \
                  "GET /files/<name>, and `glb` names the export on the runner's " \
                  "disk (null when the document did not ask for one). An export " \
                  "at any view count answers this shape, because the GLB's name " \
                  "cannot travel inside a frame's bytes."],
      ["Blender absent", "A runner without Blender answers #{UNAVAILABLE} — the " \
                       "operation is not available there. That is a STATE a " \
                       "deployment is allowed to be in, not a fault: it is " \
                       "reported as such (BlenderClient::Unavailable) and the " \
                       "job fails with the service's own reason."],
      ["an invalid spec", "An unknown element type, a missing required field or a " \
                          "malformed block is refused before anything is built " \
                          "(BlenderClient::SpecError) — never a partially drawn " \
                          "scene that looks like a rendering bug."]
    ].freeze

    # ---------------------------------------------------------------------------
    # The page's cards. The same arrangement as the PLOT half: four setting cards
    # in a 2x2 grid, each documenting its own fields through the same array that
    # renders them, so the <dt> list and the <label>s cannot drift.
    #
    # `env` is the variable the service (or the studio's runner map) actually
    # reads. A field with `env: nil` is a request parameter or a contract fact,
    # not environment. The reference cards are `type: :static`: they report what
    # the contract accepts rather than offering an input that would do nothing.
    # ---------------------------------------------------------------------------
    CARDS = [
      {
        title: "Service",
        help: "help-blender-service",
        blurb: "How the studio reaches the operation. All of it is environment: the " \
               "service reads its own variables at call time and the studio reads " \
               "its runner map the same way, so neither repo names a host.",
        fields: [
          { label: "bind", env: "CHOPSHOP_BP_BIND", type: :text, default: DEFAULT_BIND,
            hint: "Loopback by default, deliberately.",
            help: "The address the service listens on. Loopback rather than " \
                  "0.0.0.0: a service that shells out to a renderer has no " \
                  "business on every interface. Reaching it from another machine " \
                  "is an explicit act — set it to the private address, and set " \
                  "the token with it. This is the SAME variable the PLOT page " \
                  "configures, because it is the same service." },
          { label: "port", env: "CHOPSHOP_BP_PORT", type: :number, default: DEFAULT_PORT,
            min: 1, max: 65_535,
            hint: "#{DEFAULT_PORT}: the service's port, the one PLOT already documents.",
            help: "#{DEFAULT_PORT} keeps it in the shop's range and off every port " \
                  "already taken — the mock runner owns 8790, chopshop-svg's " \
                  "runner owns 8787 and the FLUX service owns 8795. The blender " \
                  "operation is a route on that same service, so it is that same " \
                  "port rather than a second one." },
          { label: "token", env: "CHOPSHOP_BP_TOKEN", type: :text, default: "",
            hint: "Blank means every route is open.",
            help: "A bearer token, enforced on every route except /health when it " \
                  "is set. The SAME variable the PLOT page documents — blender is " \
                  "an operation on that one service, not a second server, so there " \
                  "is one token. /health is exempt on purpose: a health check that " \
                  "requires the secret cannot be used to decide whether to send the " \
                  "secret. Blank means open, which is why the bind default is " \
                  "loopback." },
          { label: "runner url", env: RUNNER_URL_ENV, type: :text,
            default: "http://#{DEFAULT_BIND}:#{DEFAULT_PORT}",
            hint: "Where the studio calls it. This is the whole seam.",
            help: "The studio half of the same pair. A runner is a URL and a kind " \
                  "(Job.runner_urls / Job.runner_kinds), so the studio does not " \
                  "know which machine Blender is on and the service does not know " \
                  "which machine the studio is on — moving either end is an edit " \
                  "to one environment variable. Blender has to be installed on " \
                  "the box this points at, because the service shells out to it." },
          { label: "runner kind", env: RUNNER_KIND_ENV, type: :text, default: RUNNER_LABEL,
            hint: "The kind is what makes it a blender runner rather than a plot one.",
            help: "What the runner DOES, not where it is. \"blender\" is a fifth " \
                  "surface beside svg, flux and plot: a label speaking this " \
                  "operation, holding no job state and tracing nothing. It is " \
                  "separate from \"plot\" because rendering geometry in 3D is a " \
                  "different job target from drawing a 2D document — and it is " \
                  "still not a pipeline runner, so it can never be a hand-off " \
                  "target." }
        ]
      },
      {
        title: "Operation",
        help: "help-blender-operation",
        blurb: "One operation, one JSON contract, one rendered frame (or a manifest " \
               "of them) out — and a JSON refusal instead of a partial scene when " \
               "the document is invalid.",
        fields: [
          { label: "op", env: nil, type: :static, default: OP,
            hint: "The envelope's operation AND the route it goes to.",
            help: "`#{OP}` is both the envelope's `op` and the route (#{ROUTE}): " \
                  "the studio posts `{\"op\": \"#{OP}\", \"spec\": {…}}` and the " \
                  "answer is a rendered frame or a frames manifest. There is no " \
                  "operation to choose for this kind — the route IS the " \
                  "operation — which is why a blender job stores no op and a plot " \
                  "job does." },
          { label: "takes", env: nil, type: :static, default: "a geometry document",
            hint: "An `elements` list.",
            help: "The document is an `elements` list (a list of " +
                  ELEMENTS.keys.join(", ") +
                  "). Tiling, extrude, render and export are optional blocks " \
                  "beside it. A document with no elements list is refused before " \
                  "it is posted, by the job's own validation." },
          { label: "answers", env: nil, type: :static,
            default: "#{SUCCESS_FRAME} or #{SUCCESS_MANIFEST}",
            hint: "Read by content type, never guessed at.",
            help: "one view with no GLB export is the frame itself; anything that " \
                  "produced a second artifact (several views, or an export) is a " \
                  "manifest naming frames on the runner. The client reads the " \
                  "answer by content type, so a 200 that is neither is an error " \
                  "rather than bytes stored as a render." },
          { label: "unavailable", env: nil, type: :static, default: UNAVAILABLE.to_s,
            hint: "Answered when Blender is not installed on the runner.",
            help: "#{UNAVAILABLE} means the renderer is not there. It is a state, " \
                  "not a fault: the studio raises BlenderClient::Unavailable with " \
                  "the service's own reason, and the job fails with it rather than " \
                  "waiting." }
        ]
      },
      {
        title: "Scene",
        help: "help-blender-scene",
        blurb: "What the document may draw. Every positional field in the table " \
               "is required — a circle without its centre is refused.",
        fields: [
          { label: "elements", env: nil, type: :static, default: ELEMENTS.keys.join(", "),
            hint: "Eight types; the FIELDS popup lists what each one must carry.",
            help: "The element types a document may use — the SAME vocabulary the " \
                  "generate half draws with, because chopshop_bp/spec.py validates " \
                  "one element table for both operations. Unknown types and unknown " \
                  "fields on a known type are both refused, so a typo is a " \
                  "SpecError rather than an element that silently never renders. " \
                  "One type is refused HERE by name: `text` draws a label, and a " \
                  "label has no 3D reading, so the blender operation answers 400 " \
                  "invalid_spec for it — the other seven are the flat vocabulary " \
                  "this operation builds solids and stroke tubes from." },
          { label: "tiling", env: nil, type: :static, default: TILING_FIELDS.join(", "),
            hint: "Optional: repeats `element` across a `grid` of cells.",
            help: "An optional block that repeats one element across a `grid` of " \
                  "cells of size `cell`, starting at `origin`; the element's own " \
                  "coordinates are offsets within its cell. Tiling and `elements` " \
                  "compose, and tiled elements are built first." },
          { label: "extrude", env: nil, type: :static, default: EXTRUDE_FIELDS.join(", "),
            hint: "Optional: gives flat geometry depth.",
            help: "The block that turns a 2D outline into a solid: `depth` is how " \
                  "far it is pushed along Z, `bevel_depth` rounds its edges and " \
                  "`bevel_resolution` says how finely. This is the whole reason to " \
                  "render in 3D rather than draw, so a document that omits it is " \
                  "flat — legal, and usually not what was meant." }
        ]
      },
      {
        title: "Render",
        help: "help-blender-render",
        blurb: "How it is rendered, and what comes back. Every field here is " \
               "optional — the defaults below are what the studio composes when the " \
               "document omits the block.",
        fields: [
          { label: "size", env: nil, type: :static,
            default: "#{SIZE_FIELDS.join(' × ')} — #{DEFAULT_SIZE['width']} × #{DEFAULT_SIZE['height']}",
            hint: "The frame's pixel size.",
            help: "`render.size` is `width` and `height` in pixels. #{DEFAULT_SIZE['width']} " \
                  "× #{DEFAULT_SIZE['height']} is the studio's documented default " \
                  "for a document that names no size; a size that the renderer " \
                  "cannot honour is a refusal, not a silent rescale." },
          { label: "views", env: nil, type: :static, default: DEFAULT_VIEWS,
            hint: "1 keeps the frame; more asks for a manifest.",
            help: "How many views the service renders. #{DEFAULT_VIEWS} answers with " \
                  "the frame itself; more than #{DEFAULT_VIEWS} answers with a frames " \
                  "manifest, and the studio fetches and keeps every frame. The " \
                  "count is what decides the RESPONSE SHAPE, so it is the first " \
                  "field to check when an answer looks wrong — the Checks card " \
                  "below is where it is changed." },
          # `:static`, not `:text` (#16): this card's four siblings are contract
          # facts, and background belongs with them. The composer reads only the
          # env block and the Checks card's views/engine -- nothing consumes
          # `background` -- so an input here let the operator type a colour the
          # composed document never carried.
          { label: "background", env: nil, type: :static, default: DEFAULT_BACKGROUND,
            hint: "The frame's background colour.",
            help: "The scene's background, as a colour the renderer understands. " \
                  "#{DEFAULT_BACKGROUND} is opaque white: a transparent or black " \
                  "background makes a thin extrusion unreadable, and a frame the " \
                  "operator cannot see is not a preview." },
          { label: "engine", env: nil, type: :static, default: DEFAULT_ENGINE,
            hint: "#{DEFAULT_ENGINE} is the fast rasteriser; eevee is the shaded engine.",
            help: "Which spec engine renders the frame. #{ENGINES.join(' and ')} are " \
                  "the spec's two words — #{DEFAULT_ENGINE} is the fast rasteriser " \
                  "(needs no GPU) and eevee is the shaded engine. chopshop-bp maps " \
                  "them to Blender's internal identifiers. An engine name outside " \
                  "this pair is a 400 refusal — never a fallback to the default, " \
                  "which would render something other than what was asked for." },
          { label: "export", env: nil, type: :static,
            default: "#{EXPORT_FIELDS.join(', ')} — #{DEFAULT_GLB ? 'on' : 'off'} by default",
            hint: "Optional: glb writes the mesh beside the frames.",
            help: "`export.glb` writes a glTF binary of the scene on the runner and " \
                  "names it in the manifest's `glb` field (`null` when it was not " \
                  "asked for). Off by default: it is a second file on someone " \
                  "else's disk, and a render that only needed a picture should not " \
                  "write one." }
        ]
      }
    ].freeze

    # The response shapes as their own full-width card: this is what every caller
    # branches on, and it is an answer rather than a setting.
    SHAPES = {
      title: "Responses",
      help: "help-blender-shapes",
      blurb: "Two success shapes and one refusal that is a state, read by content " \
             "type. This page does not run the service; it states what the service " \
             "answers so a caller knows which of the two it is holding.",
      entries: RESPONSES
    }.freeze

    # The two ways this is deployed. The same code either way: the only difference
    # is two environment variables, one on each side — and one of them is a token,
    # because a shared network is not a private one.
    PLACEMENT = {
      title: "Where it runs",
      help: "help-blender-placement",
      blurb: "This page configures a SERVICE OPERATION. The service and this studio " \
             "are two programs talking over HTTP, joined by a URL — so the same " \
             "pair runs on one box or on two, and nothing here names a host.",
      shapes: [
        ["one box", "The service, Blender and this studio on the same machine. The " \
                    "service listens on #{DEFAULT_BIND} — loopback, so nothing on " \
                    "the network can reach it — and the studio's runner URL is a " \
                    "loopback address too. Blender is installed beside the " \
                    "service, because the service shells out to it. Nothing to " \
                    "expose, nothing to authenticate.",
         [[RUNNER_KIND_ENV, "where the studio learns which operation it is talking to"],
          ["CHOPSHOP_BP_BIND=#{DEFAULT_BIND}", "where the service listens — loopback"],
          ["#{RUNNER_URL_ENV}=http://127.0.0.1:#{DEFAULT_PORT}", "where the studio calls"]]],
        ["split", "The studio on one machine, the rendering host on another. Over a " \
                  "private network (a tailnet, a LAN, a tunnel) that host sets the " \
                  "bind to the address the studio can reach it on AND sets a token; " \
                  "the studio sets its runner URL to that same address. Both are " \
                  "required together: a render endpoint on a shared network with no " \
                  "token is somebody else's Blender.",
         [[RUNNER_KIND_ENV, "unchanged: the kind never encodes the topology"],
          ["CHOPSHOP_BP_BIND=<the private address>", "on that host: where it listens"],
          ["CHOPSHOP_BP_TOKEN=<shared secret>", "on that host: who may call it"],
          ["#{RUNNER_URL_ENV}=http://<that address>:#{DEFAULT_PORT}",
           "on the studio box: where the renderer is"]]]
      ],
      entries: [
        ["one box / split", "The two deployments this supports. They differ only in " \
                            "the URLs and whether a token is set — not in code, not " \
                            "in a build, not in a config file in either repo."],
        ["the URL is the whole seam", "A runner is a URL and a kind. Neither repo is " \
                                      "allowed to record a host, so moving either end " \
                                      "is an edit to one environment variable."],
        ["the same service as the plot half", "This is chopshop-bp, one operation further " \
                                             "on: #{ROUTE} sits beside /generate, /digest " \
                                             "and /query on the same surface. It gets its " \
                                             "own KIND because rendering geometry in 3D is " \
                                             "a different job target, not because it is a " \
                                             "different service."],
        ["Blender is the dependency", "A runner of this kind needs Blender " \
                                     "installed. Without it the operation answers " \
                                     "#{UNAVAILABLE} and the studio says so; with " \
                                     "it, nothing else changes. That is the whole " \
                                     "difference between a deployment that can " \
                                     "render and one that cannot."],
        ["turning it off", "The service is a program you start and stop, so stopping " \
                           "it is a normal state, not a fault: the nav's runner pill " \
                           "shows it down, and a blender job fails with the " \
                           "service's own message rather than waiting."]
      ]
    }.freeze

    class << self
      def element_type?(type)
        ELEMENTS.key?(type.to_s)
      end

      # Everything the page needs to check a document, handed to the browser as
      # one JSON blob so the rules are NOT restated in JavaScript. A second copy of
      # a rule is a second thing to get wrong.
      def facts
        {
          "service" => SERVICE,
          "op" => OP,
          "route" => ROUTE,
          "elements" => ELEMENTS,
          "elementTypes" => ELEMENTS.keys,
          "docKeys" => DOC_KEYS,
          "tilingFields" => TILING_FIELDS,
          "extrudeFields" => EXTRUDE_FIELDS,
          "extrudeDefaults" => EXTRUDE_DEFAULTS,
          "renderFields" => RENDER_FIELDS,
          "sizeFields" => SIZE_FIELDS,
          "viewChoices" => VIEW_CHOICES,
          "exportFields" => EXPORT_FIELDS,
          "engines" => ENGINES,
          "defaults" => {
            "size" => DEFAULT_SIZE,
            "views" => DEFAULT_VIEWS,
            "background" => DEFAULT_BACKGROUND,
            "engine" => DEFAULT_ENGINE,
            "glb" => DEFAULT_GLB
          },
          "successFrame" => SUCCESS_FRAME,
          "successManifest" => SUCCESS_MANIFEST,
          "unavailable" => UNAVAILABLE,
          "defaultBind" => DEFAULT_BIND,
          "defaultPort" => DEFAULT_PORT
        }
      end

      # Validate a document exactly as the service does, in the service's own
      # sentences. Returns the problems (a violation the service would refuse) and
      # the notes (something true about the document that is not a refusal) — the
      # same two-channel shape BpConf::Plot.validate uses, because "refused" and
      # "worth knowing" are different answers.
      # `document` is the whole document, or nil when only the three scalar
      # controls are known. It is read for ONE thing -- whether a `tiling` block
      # is present -- because that block is what makes an empty `elements` list
      # renderable rather than refused (see the empty-list check below).
      def validate(elements: nil, views: nil, engine: nil, document: nil)
        problems = []
        notes = []

        has_elements = elements.is_a?(Array)
        document_has_tiling = document.is_a?(Hash) && document["tiling"].is_a?(Hash)

        if elements.present? && !has_elements
          problems << "'elements' must be an array of element objects, got #{elements.class}"
        end
        unless has_elements
          problems << "a document needs an 'elements' list: " \
                      "there is nothing to render"
        end

        if views.present? && !views.to_s.match?(/\A\d+\z/)
          problems << "'views' must be a whole number, got #{views.inspect}"
        elsif views.to_s.match?(/\A\d+\z/) && views.to_i < 1
          problems << "'views' must be at least 1, got #{views}"
        end

        if engine.to_s.strip.present? && !ENGINES.include?(engine.to_s)
          problems << "'engine' must be one of #{ENGINES.join(', ')}, got #{engine.inspect}"
        end

        if views.to_s.match?(/\A\d+\z/) && views.to_i > 1
          notes << "views > 1 answers with a frames manifest (#{SUCCESS_MANIFEST}) " \
                   "rather than one #{SUCCESS_FRAME} frame — the studio fetches each " \
                   "frame from /files/<name>."
        end
        # An empty `elements` list is NOT legal. chopshop-bp's own validator
        # raises "nothing to render -- 'elements' is empty and there is no
        # 'tiling'" (chopshop_bp/blender.py:241-243, asserted at
        # tests/test_blender.py:97), so the service answers 400 invalid_spec for
        # a body this card used to call a legal empty scene. An empty list WITH a
        # `tiling` block is the one case that renders -- the tiling is the
        # geometry then -- so the tiling is what decides, and the card says which.
        if has_elements && elements.respond_to?(:empty?) && elements.empty?
          if document_has_tiling
            notes << "an empty 'elements' list is legal HERE because the document " \
                     "carries a 'tiling' block -- the tiling is the geometry the " \
                     "scene repeats, and 'elements' only adds to it."
          else
            problems << "an empty 'elements' list renders nothing: the service " \
                        "refuses it unless the document carries a 'tiling' block, " \
                        "which would be the geometry instead"
          end
        end
        notes << "the engine and the size are the document's to set — nothing here " \
                 "ranks the options or recommends one" unless problems.any?

        { problems: problems, notes: notes }
      end
    end
  end
end
