# The chopshop-plot BLENDER operation's conf, mirrored from the repo that
# defines it.
#
# A faithful copy of the constants in chopshop-plot's serve surface for the
# new `blender` operation — `chopshop_plot/config.py` (the service's own
# variables), the geometry spec in `chopshop_plot/spec.py` (the element types
# and the tiling/extrude/render/export blocks) and the route table — which is
# what the service actually reads. It is shown on the BLENDER page so the
# settings, the document's vocabulary and the two response shapes are visible
# instead of implied.
#
# IMPORTANT, and the reason this is a model and not a settings table: this page
# does not run the service and cannot change its environment. It shows what the
# service would be started with, validates a document the way the service does,
# and hands you the env block and the JSON to copy. PlotConf carries the same
# honesty about the same service; see its comment for the longer version.
#
# Anything here that drifts from config.py / spec.py is a bug in THIS file. The
# values are transcribed, not paraphrased: a document field that is not the
# field name is worse than no field name, because the render would be composed
# against nothing.
#
# The OP and the ROUTE are the same word, and that is the whole integration:
# blender is not a second service, it is a second OPERATION of chopshop-plot's
# serve surface, which is why the studio files it under its own runner KIND
# (Job::RUNNER_KINDS) while pointing at the same service the PLOT page
# configures.
class BlenderConf
  SERVICE = "chopshop-plot".freeze

  # The operation and the route it is served on. Named once: an envelope whose
  # `op` disagrees with the route asked for is refused by the service rather
  # than best-effort rendered.
  OP = "blender".freeze
  ROUTE = "/blender".freeze

  # Blender runs on the same box as the service that shells out to it, so this
  # is the SAME port the PLOT page documents: one service, two operations. The
  # KIND is what tells the studio which operation to call, so a deployment that
  # renders on a different host than it draws on sets a different URL — not a
  # different port in this file.
  DEFAULT_BIND = "127.0.0.1".freeze
  DEFAULT_PORT = 8796

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

  # chopshop_plot/spec.py, verbatim: the geometry element types and the fields
  # each one is REQUIRED to carry. A circle without its centre is an invalid
  # spec, never a circle at the origin.
  ELEMENTS = {
    "rect" => %w[x y width height],
    "circle" => %w[cx cy r],
    "ellipse" => %w[cx cy rx ry],
    "polygon" => %w[points],
    "polyline" => %w[points],
    "line" => %w[x1 y1 x2 y2],
    "path" => %w[d]
  }.freeze

  # A document is an `elements` list (optionally tiled and extruded). The
  # service has no other document shape — a document that carries no elements
  # list is the refusal the Job validation moves to the form.
  DOC_KEYS = %w[elements].freeze

  TILING_FIELDS = %w[grid cell origin element].freeze

  # The blocks that decorate an ELEMENTS document. Each is optional, so each key
  # below is the contract's and each default is the CONTRACT'S default (chopshop-
  # plot's chopshop_plot/blender.py DEFAULT_DEPTH/DEFAULT_BEVEL_DEPTH/
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
  # (chopshop-plot maps them to Blender's internal identifiers — 'eevee' ->
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
  # BlenderConf.validate.
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
              "eevee is the shaded engine. chopshop-plot maps them to Blender's " \
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
  # The page's cards. The same arrangement as the PLOT page: four setting cards
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
        { label: "bind", env: "CHOPSHOP_PLOT_BIND", type: :text, default: DEFAULT_BIND,
          hint: "Loopback by default, deliberately.",
          help: "The address the service listens on. Loopback rather than " \
                "0.0.0.0: a service that shells out to a renderer has no " \
                "business on every interface. Reaching it from another machine " \
                "is an explicit act — set it to the private address, and set " \
                "the token with it. This is the SAME variable the PLOT page " \
                "configures, because it is the same service." },
        { label: "port", env: "CHOPSHOP_PLOT_PORT", type: :number, default: DEFAULT_PORT,
          min: 1, max: 65_535,
          hint: "#{DEFAULT_PORT}: the service's port, the one PLOT already documents.",
          help: "#{DEFAULT_PORT} keeps it in the shop's range and off every port " \
                "already taken — the mock runner owns 8790, chopshop-svg's " \
                "runner owns 8791 and the FLUX service owns 8795. The blender " \
                "operation is a route on that same service, so it is that same " \
                "port rather than a second one." },
        { label: "token", env: "CHOPSHOP_PLOT_TOKEN", type: :text, default: "",
          hint: "Blank means every route is open.",
          help: "A bearer token, enforced on every route except /health when it " \
                "is set. The SAME variable the PLOT page documents — blender is " \
                "an operation on that one service, not a second server, so there " \
                "is one token. /health is exempt on purpose: a health check that " \
                "requires the secret cannot be used to decide whether to send " \
                "the secret. Blank means open, which is why the bind default is " \
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
      blurb: "What the document may draw. Every positional field in the table is " \
             "required — a circle without its centre is refused.",
      fields: [
        { label: "elements", env: nil, type: :static, default: ELEMENTS.keys.join(", "),
          hint: "Seven types; the FIELDS popup lists what each one must carry.",
          help: "The element types a document may use. Unknown types and unknown " \
                "fields on a known type are both refused, so a typo is a " \
                "SpecError rather than an element that silently never renders." },
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
        { label: "background", env: nil, type: :text, default: DEFAULT_BACKGROUND,
          hint: "The frame's background colour.",
          help: "The scene's background, as a colour the renderer understands. " \
                "#{DEFAULT_BACKGROUND} is opaque white: a transparent or black " \
                "background makes a thin extrusion unreadable, and a frame the " \
                "operator cannot see is not a preview." },
        { label: "engine", env: nil, type: :static, default: DEFAULT_ENGINE,
          hint: "#{DEFAULT_ENGINE} is the fast rasteriser; eevee is the shaded engine.",
          help: "Which spec engine renders the frame. #{ENGINES.join(' and ')} are " \
                "the spec's two words — #{DEFAULT_ENGINE} is the fast rasteriser " \
                "(needs no GPU) and eevee is the shaded engine. chopshop-plot maps " \
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
        ["CHOPSHOP_PLOT_BIND=#{DEFAULT_BIND}", "where the service listens — loopback"],
        ["#{RUNNER_URL_ENV}=http://127.0.0.1:#{DEFAULT_PORT}", "where the studio calls"]]],
      ["split", "The studio on one machine, the rendering host on another. Over a " \
                "private network (a tailnet, a LAN, a tunnel) that host sets the " \
                "bind to the address the studio can reach it on AND sets a token; " \
                "the studio sets its runner URL to that same address. Both are " \
                "required together: a render endpoint on a shared network with no " \
                "token is somebody else's Blender.",
       [[RUNNER_KIND_ENV, "unchanged: the kind never encodes the topology"],
        ["CHOPSHOP_PLOT_BIND=<the private address>", "on that host: where it listens"],
        ["CHOPSHOP_PLOT_TOKEN=<shared secret>", "on that host: who may call it"],
        ["#{RUNNER_URL_ENV}=http://<that address>:#{DEFAULT_PORT}",
         "on the studio box: where the renderer is"]]]
    ],
    entries: [
      ["one box / split", "The two deployments this supports. They differ only in " \
                          "the URLs and whether a token is set — not in code, not " \
                          "in a build, not in a config file in either repo."],
      ["the URL is the whole seam", "A runner is a URL and a kind. Neither repo is " \
                                    "allowed to record a host, so moving either " \
                                    "end is an edit to one environment variable."],
      ["the same service as PLOT", "This is chopshop-plot, one operation further " \
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
    # same two-channel shape PlotConf.validate uses, because "refused" and
    # "worth knowing" are different answers.
    def validate(elements: nil, views: nil, engine: nil)
      problems = []
      notes = []

      has_elements = elements.is_a?(Array)

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
      if has_elements && (elements.respond_to?(:empty?) ? elements.empty? : false)
        notes << "an empty 'elements' list renders an empty scene: legal, and " \
                 "almost never what was meant."
      end
      notes << "the engine and the size are the document's to set — nothing here " \
               "ranks the options or recommends one" unless problems.any?

      { problems: problems, notes: notes }
    end
  end
end
