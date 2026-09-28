# The chopshop-flux conf, mirrored from the repo that defines it.
#
# This is a faithful copy of the constants in chopshop-flux's
# `chopshop_flux/config.py` and the registry in `chopshop_flux/models.py`, which
# is what the service actually reads. It is shown on the FLUX page so the
# settings, the model facts and the licence are visible instead of implied.
#
# IMPORTANT, and the reason this is a model and not a settings table: this page
# does not run the service and cannot change its environment. It shows what the
# service would be started with, validates a request the same way the service
# does, and hands you the env block and the JSON to copy. See #writable? and the
# note on the page -- the same honesty the JEV page carries.
#
# Anything here that drifts from config.py/models.py is a bug in THIS file. The
# values are transcribed, not paraphrased: a licence string that is not the
# licence string is worse than no licence string.
class FluxConf
  SERVICE = "chopshop-flux".freeze

  # config.py, verbatim.
  DEFAULT_BIND = "127.0.0.1".freeze
  DEFAULT_PORT = 8795

  # The service's HTTP surface, as seen from here. Listed because the point of
  # that service is that it is a STANDARD API: these are the routes any other
  # application calls too, not something shaped around this studio.
  API = {
    routes: "POST /generate, POST /edit, GET /models, GET /health, " \
            "GET /files/<name>"
  }.freeze
  DEFAULT_OUT_DIR = "./out".freeze
  MIN_DIMENSION = 64
  DIMENSION_MULTIPLE = 16
  DEFAULT_MAX_PIXELS = 4 * 1024 * 1024
  MAX_UPLOAD_BYTES = 32 * 1024 * 1024

  # models.py, verbatim. Licence strings are kept exactly as they appear on the
  # model cards so a grep for the licence finds the thing the licence is called.
  APACHE_2 = "Apache-2.0".freeze
  FLUX_NONCOMMERCIAL = "FLUX Non-Commercial License v2.1".freeze

  DEFAULT_MODEL_KEY = "klein-4b".freeze

  MODELS = {
    "klein-4b" => {
      "key" => "klein-4b",
      "repo_id" => "black-forest-labs/FLUX.2-klein-4B",
      "params_b" => 4,
      "licence" => APACHE_2,
      "commercial_ok" => true,
      "vram_gb" => 13.0,
      "repo_bytes" => 15.98e9,
      "layout" => "diffusers",
      "default_steps" => 4,
      "default_guidance" => 1.0,
      "distilled" => true,
      "gated" => false,
      "negative_prompt" => false,
      "aliases" => %w[4b klein klein4b klein-4B],
      "notes" => "Apache 2.0, so generated output is yours to sell. The default."
    },
    "klein-4b-base" => {
      "key" => "klein-4b-base",
      "repo_id" => "black-forest-labs/FLUX.2-klein-base-4B",
      "params_b" => 4,
      "licence" => APACHE_2,
      "commercial_ok" => true,
      "vram_gb" => 13.0,
      "repo_bytes" => 16.0e9,
      "layout" => "diffusers",
      "default_steps" => 28,
      "default_guidance" => 4.0,
      "distilled" => false,
      "gated" => false,
      "negative_prompt" => false,
      "aliases" => %w[4b-base klein-base base-4b],
      # Undistilled: it preserves the full training signal, which is why it is
      # the fine-tuning starting point -- and why guidance > 1.0 works on it.
      "notes" => "Undistilled sibling of klein-4b. Slower, but guidance > 1.0 and " \
                 "a negative prompt actually do something."
    },
    "klein-9b" => {
      "key" => "klein-9b",
      "repo_id" => "black-forest-labs/FLUX.2-klein-9B",
      "params_b" => 9,
      "licence" => FLUX_NONCOMMERCIAL,
      "commercial_ok" => false,
      "vram_gb" => 24.0,
      "repo_bytes" => 18.16e9,
      "layout" => "diffusers",
      "default_steps" => 4,
      "default_guidance" => 1.0,
      "distilled" => true,
      "gated" => true,
      "negative_prompt" => false,
      "aliases" => %w[9b klein9b],
      "notes" => "NON-COMMERCIAL: local/non-commercial use only. HF gates it, so a " \
                 "token is needed. ~24 GB VRAM at bf16 against a 17 GB card, so it " \
                 "only runs with CPU offload."
    },
    "sdxl-1.0" => {
      "key" => "sdxl-1.0",
      "repo_id" => "stabilityai/stable-diffusion-xl-base-1.0",
      "params_b" => 3.5,
      "licence" => "CreativeML Open RAIL++-M License",
      "commercial_ok" => true,
      "vram_gb" => 8.0,
      "repo_bytes" => 13.9e9,
      "layout" => "diffusers",
      "default_steps" => 30,
      "default_guidance" => 5.0,
      "distilled" => false,
      "gated" => false,
      "negative_prompt" => true,
      "img2img_strength" => true,
      "aliases" => %w[sdxl sdxl-1 sdxl1],
      "notes" => "OpenRAIL++-M, so generated output is commercially usable. " \
                 "SD-style: it takes a real negative_prompt, and img2img takes a " \
                 "strength. ~8 GB VRAM."
    }
  }.freeze

  # These exist and are deliberately NOT loadable. Both are single-file builds
  # with no model_index.json, so `from_pretrained` cannot load them at all --
  # they are ComfyUI's format. Listed so that "can we just use the fp8 one?" has
  # a written answer instead of being re-derived, and so nobody adds one to the
  # select above and ships a model that fails at load time.
  UNLOADABLE = {
    "klein-9b-fp8" => "black-forest-labs/FLUX.2-klein-9b-fp8 (9.43 GB) is a " \
                      "single-file build with no model_index.json — a ComfyUI " \
                      "format. diffusers needs from_single_file plus a matching " \
                      "text encoder and VAE, which that repo does not ship.",
    "klein-9b-nvfp4" => "black-forest-labs/FLUX.2-klein-9b-nvfp4 (5.76 GB) is " \
                        "single-file NVFP4, and NVFP4 is an NVIDIA format — not " \
                        "runnable on this ROCm box."
  }.freeze

  # The four SETTING cards, in the 2x2 grid. Each pairs with a card of similar
  # weight so neither row is stretched by a tall neighbour: Service|Model, then
  # Resolution|Hand-off. The live validation is deliberately NOT one of these --
  # it is a different kind of thing (an answer, not a setting), and wedging it
  # into the Resolution card stretched the whole row and left the Hand-off card
  # two-thirds empty.
  #
  # Each card's "?" documents that card's fields and nothing else: the help text
  # for a field is the field's own `:help`, so the <dt> list and the <label>s
  # cannot drift -- both are rendered from this one array. (The JSON page has the
  # same rule enforced by a test because its cards are hand-written; here the
  # structure makes drift impossible.)
  #
  # `env` is the variable the service actually reads. Fields without one are
  # request parameters, not environment.
  CARDS = [
    {
      title: "Service",
      help: "help-flux-service",
      blurb: "How a runner reaches the service. Every one of these is an " \
             "environment variable the service reads at call time, so nothing " \
             "in the flux repo names a host.",
      fields: [
        { label: "bind", env: "CHOPSHOP_FLUX_BIND", type: :text, default: DEFAULT_BIND,
          hint: "Loopback by default, deliberately.",
          help: "The address the service listens on. The default is loopback " \
                "rather than 0.0.0.0: a service that generates images and " \
                "streams them back has no business on every interface. " \
                "chopshop-svg's runner.py ships 0.0.0.0 and its own contract " \
                "doc calls that a footgun. Reaching this from elsewhere is an " \
                "explicit act — set it to the private address." },
        { label: "port", env: "CHOPSHOP_FLUX_PORT", type: :number, default: DEFAULT_PORT,
          min: 1, max: 65_535,
          hint: "8791 is the SVG runner, 8790 the studio's mock runner.",
          help: "8795 keeps it in the same range as the rest of the shop but " \
                "clear of both: chopshop-svg's runner owns 8791 and the " \
                "studio's mock runner owns 8790, so a collision here would look " \
                "like the wrong service answering." },
        { label: "out_dir", env: "CHOPSHOP_FLUX_OUT", type: :text, default: DEFAULT_OUT_DIR,
          hint: "Generated PNGs land here.",
          help: "Where generated PNGs are written — and the ONLY tree " \
                "GET /files/ will serve. The name in a download request arrives " \
                "over the network, so the service checks containment rather than " \
                "assuming it: anything resolving outside this directory is a 404." },
        { label: "token", env: "CHOPSHOP_FLUX_TOKEN", type: :text, default: "",
          hint: "Blank means every route is open.",
          help: "A bearer token, enforced on every route except /health when it " \
                "is set. /health is exempt on purpose: a health check that " \
                "requires the secret cannot be used to decide whether to send " \
                "the secret. Blank means open — which is why the bind default " \
                "is loopback." },
        { label: "url", env: "CHOPSHOP_FLUX_URL", type: :text,
          default: "http://#{DEFAULT_BIND}:#{DEFAULT_PORT}",
          hint: "Where the client looks for the service.",
          help: "The client's side of the same coin. This is what gen2pipe and " \
                "the rest of the CLI dial, which is how a runner on another " \
                "machine reaches a service on the GPU box without either end " \
                "knowing a hostname the other one does not." }
      ]
    },
    {
      title: "Model",
      help: "help-flux-model",
      blurb: "Which model, and what running it commits you to. The licence is " \
             "not decoration: the smaller models are the ones you are allowed to " \
             "sell output from.",
      fields: [
        { label: "model", env: "CHOPSHOP_FLUX_MODEL", type: :select,
          default: DEFAULT_MODEL_KEY, options: MODELS.keys,
          hint: "klein-4b is the default: Apache 2.0.",
          help: "Which registered model to load. Four are loadable (the three " \
                "klein and sdxl-1.0) and two more exist that are not — see the " \
                "Models popup for the fp8 and nvfp4 builds, which are " \
                "single-file ComfyUI formats that from_pretrained cannot load at " \
                "all. sdxl-1.0 is SD-style: it takes a real negative prompt." },
        { label: "steps", env: nil, type: :number, default: nil, min: 1, max: 100,
          hint: "Follows the model. klein is distilled: 4.",
          help: "Inference steps. The default follows the model, and it is not " \
                "the pipeline class's default: Flux2KleinPipeline.__call__ " \
                "defaults to 50 steps because that is what a BASE model wants. " \
                "Running a distilled checkpoint at 50 is running the wrong " \
                "schedule, so the registry's value always overrides it." },
        { label: "guidance", env: nil, type: :number, default: nil, step: 0.1,
          min: 0, max: 20,
          hint: "1.0 on distilled klein. Above that is ignored.",
          help: "Classifier-free guidance. On a distilled klein it does " \
                "NOTHING: the pipeline's own do_classifier_free_guidance is " \
                "`guidance_scale > 1 and not is_distilled`, so it is always " \
                "false and diffusers logs \"Guidance scale X is ignored\". This " \
                "is also the whole reason a negative prompt has no effect — CFG " \
                "is the machinery a negative prompt acts through. If you " \
                "genuinely need real guidance, use klein-4b-base." },
        { label: "negative_prompt", env: nil, type: :text, default: nil,
          hint: "Only a model with a real CFG path (sdxl-1.0).",
          help: "What the generation should steer away from. A request " \
                "parameter, not environment: it rides with the request, and " \
                "it is only passed to the pipeline for a model whose registry " \
                "says negative_prompt: true — sdxl-1.0. Flux2KleinPipeline." \
                "__call__ has no such parameter at all, so a negative prompt " \
                "on klein is generated anyway and reported instead of silently " \
                "dropped: \"negative prompt ignored: klein-4b has no " \
                "negative_prompt parameter\"." },
        { label: "strength", env: nil, type: :number, default: nil, min: 0, max: 1,
          step: 0.05,
          hint: "img2img only, and only on sdxl-1.0, and only with a reference.",
          help: "How far an edit may move from the reference image, for the " \
                "SD-style model called as img2img. A request parameter, not " \
                "environment, and img2img-only in two senses: the service " \
                "passes strength= to the pipeline only for a model whose " \
                "registry says img2img_strength: true, and only when a " \
                "reference image is actually present — so a text-to-image call " \
                "never carries it, and a klein has no strength parameter to " \
                "carry it to. Blank means the key is not sent at all, leaving " \
                "the pipeline's own default in place rather than a zero." },
        { label: "offload", env: "CHOPSHOP_FLUX_OFFLOAD", type: :select,
          default: "cpu", options: %w[cpu none],
          hint: "None does not fit this card.",
          help: "Where the model's stages live between calls. 'cpu' pages each " \
                "stage in and out; 'none' keeps everything resident. Measured on " \
                "this box: the 4B weights are 15.97 GB against a card torch " \
                "reports as 15.92 GiB (17.10 GB), so resident runs reach VAE " \
                "decode with 174 MiB free and die there. 'none' is for measuring " \
                "the difference on a card that can afford it, not for using here." },
        { label: "vae_tiling", env: "CHOPSHOP_FLUX_VAE_TILING", type: :select,
          default: "0", options: %w[0 1],
          hint: "For large decodes. Off until measured.",
          help: "Decode the VAE in tiles, reducing the peak memory of the " \
                "decode. Off by default: the memory failure that prompted it was " \
                "in RESIDENT mode, which CPU offload removes, so it is left off " \
                "until something measured asks for it. Note the switch lives on " \
                "the VAE (pipe.vae.enable_tiling()) — Flux2KleinPipeline has no " \
                "enable_vae_tiling(), so the obvious call raises AttributeError " \
                "and tiling silently never happens." },
        { label: "ack_noncommercial", env: "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL",
          type: :select, default: "0", options: %w[0 1],
          hint: "Required to load a non-commercial model.",
          help: "The licence gate, and the one setting here that is a business " \
                "decision rather than a technical one. klein-9b is FLUX " \
                "Non-Commercial: local, non-commercial use only, and commercial " \
                "use of its output needs a licence from Black Forest Labs. " \
                "Loading it requires this set explicitly, so a commercial " \
                "deployment cannot happen by accident. The check lives in the " \
                "registry, on every path that loads a model — not in the view." }
      ]
    },
    {
      title: "Resolution",
      help: "help-flux-resolution",
      blurb: "FLUX.2's own limits, enforced by the service before anything loads: " \
             "a bad size is a caller error, not a failed generation.",
      fields: [
        { label: "width", env: nil, type: :number, default: 1024, min: MIN_DIMENSION,
          step: DIMENSION_MULTIPLE,
          hint: "Multiple of 16.",
          help: "Pixels across. Every dimension must be a multiple of " \
                "#{DIMENSION_MULTIPLE} and at least #{MIN_DIMENSION} — that rule " \
                "is the model's, not ours, so it is not negotiable and the " \
                "service rejects a violation as a 400 rather than discovering it " \
                "mid-generation." },
        { label: "height", env: nil, type: :number, default: 1024, min: MIN_DIMENSION,
          step: DIMENSION_MULTIPLE,
          hint: "Multiple of 16.",
          help: "Pixels down, under the same rules as the width. The pair is " \
                "also capped in total — see the derived panel for what this " \
                "request comes to." },
        { label: "images", env: nil, type: :number, default: 1, min: 1, max: 8,
          hint: "Batched in one call.",
          help: "How many images one request produces, via " \
                "num_images_per_prompt. This is genuinely batched and is the " \
                "cheap kind of parallelism. Separate concurrent requests are " \
                "NOT parallel — there is one GPU, so a second request waits on a " \
                "lock rather than over-subscribing VRAM, and the response " \
                "reports how long it waited." }
      ]
    },
    {
      title: "Hand-off",
      help: "help-flux-handoff",
      blurb: "gen2pipe generates, fetches the raster, then calls chopshop-svg's " \
             "front pipeline. This layer calls the pipeline; the pipeline never " \
             "calls it.",
      fields: [
        { label: "pipeline", env: "CHOPSHOP_FLUX_PIPELINE", type: :text, default: "",
          hint: "A chopshop-svg checkout. Blank disables gen2pipe.",
          help: "Where front_pipeline.sh lives. Deliberately not defaulted: the " \
                "hand-off refuses to guess, because guessing where the pipeline " \
                "lives is how you trace the wrong tree — and across a network it " \
                "is how you trace someone else's. Only gen2pipe needs it." },
        { label: "sweep", env: nil, type: :text, default: "",
          hint: "Passed as --sweep=FILE.",
          help: "A sweep spec file to hand the pipeline, passed in the " \
                "equals form (--sweep=FILE). The two-token form hits " \
                "front_pipeline.sh's unknown-option path and the sweep is " \
                "silently not applied — chopshop-sui shipped exactly that bug, " \
                "and chopshop-flux carries a regression test for it." },
        { label: "skip_prep", env: nil, type: :select, default: "0", options: %w[0 1],
          hint: "Pass --skip-prep when the raster is already prepped.",
          help: "Skips the prep stage of the front pipeline. Use it when the " \
                "generated raster is already the size and colour space you want, " \
                "so prep does not re-do work that would change nothing. It never " \
                "silently transforms a source — prep is check-first, and this is " \
                "the explicit way to say you do not want it run at all." }
      ]
    }
  ].freeze

  # The live validation card, which runs the service's own rules in the browser.
  # `entries` documents what the card shows, in the same field-help vocabulary
  # the setting cards use, so its "?" reads like theirs.
  CHECKS = {
    title: "Checks",
    help: "help-flux-checks",
    blurb: "What the service does with the settings above, in its own order, and " \
           "what this request comes to. This page does not run the service; it " \
           "runs the same rules, so a request the service would reject is " \
           "rejectable before anything loads.",
    entries: [
      ["pixels", "width x height, against the cap on the right. Shown as a share " \
                 "of the cap so a request that is legal but heavy is visible as " \
                 "heavy rather than only as legal. The cap is INCLUSIVE: 2048x2048 " \
                 "IS 4 MP exactly, so it is allowed."],
      ["verdict", "Accepted or rejected, by the same checks the service runs " \
                  "before it loads anything. A violation is a 400 — a caller " \
                  "error — not a failed generation, which is why the problems " \
                  "appear in the JSON as well as in the status line."],
      ["the checks, in order", "Integer, then the minimum, then the multiple of " \
                               "16, then the cap. The first failure reported is " \
                               "the first one the service would hit, because the " \
                               "order is its order."]
    ]
  }.freeze

  # The derived legend under the Checks card: what the service checks, in the
  # order it checks it, with the message it actually raises.
  SIZE_RULES = [
    ["integer", "A dimension must be an integer. A JSON body with 1024.0 in it is a caller error, not a rounding opportunity."],
    ["at least #{MIN_DIMENSION}", "The model's floor on either side."],
    ["multiple of #{DIMENSION_MULTIPLE}", "The model's alignment. Not ours, and not negotiable."],
    ["at most #{DEFAULT_MAX_PIXELS / (1024 * 1024)} MP", "The default cap on width x height. Inclusive: 2048x2048 IS 4 MP exactly and is allowed."]
  ].freeze

  # The two ways this is deployed, on the page because it was the first question
  # the page did not answer: where does any of this run, and what has to be true
  # of a box for it to work there. Both shapes are the same code — the only
  # difference is two environment variables, one on each side.
  PLACEMENT = {
    title: "Where it runs",
    help: "help-flux-placement",
    blurb: "This page configures a SERVICE. The service and this studio are two " \
           "programs that talk over HTTP, and the only thing joining them is a " \
           "URL — so the same pair runs on one machine or on two, and nothing " \
           "here names a host.",
    shapes: [
      ["one box", "The service and this studio on the same machine. The service " \
                  "listens on #{DEFAULT_BIND} — loopback, so nothing on the " \
                  "network can reach it — and the studio's runner URL is a " \
                  "loopback address too. Nothing to expose, nothing to " \
                  "authenticate. This is the shape a laptop or a single " \
                  "workstation wants.",
       [["CHOPSHOP_FLUX_BIND=#{DEFAULT_BIND}", "where the service listens — loopback"],
        ["CHOPSHOP_RUNNER_FLUX_URL=http://127.0.0.1:#{DEFAULT_PORT}", "where the studio calls"]]],
      ["split", "The studio on one machine, the GPU on another — a VPS driving a " \
                "box at home, say. Over a private network (a tailnet, a LAN, a " \
                "tunnel) the GPU box sets the bind to the address the studio can " \
                "reach it on AND sets a token; the studio sets its runner URL to " \
                "that same address. Both are required together: a generation " \
                "endpoint on a shared network with no token is somebody else's " \
                "free GPU.",
       [["CHOPSHOP_FLUX_BIND=<the private address>", "on the GPU box: where it listens"],
        ["CHOPSHOP_FLUX_TOKEN=<shared secret>", "on the GPU box: who may call it"],
        ["CHOPSHOP_RUNNER_FLUX_URL=http://<that address>:#{DEFAULT_PORT}",
         "on the studio box: where the GPU is"]]]
    ],
    entries: [
      ["one box / split", "The two deployments this supports. They differ only " \
                          "in the URLs and whether a token is set — not in code, " \
                          "not in a build, not in a config file in either repo."],
      ["the URL is the whole seam", "A runner is a URL and a kind. The service " \
                                    "does not know which machine the studio is " \
                                    "on, and the studio does not know which " \
                                    "machine the GPU is on. Neither repo is " \
                                    "allowed to record a host, so moving either " \
                                    "end is an edit to one environment variable."],
      ["other applications", "The service is a plain HTTP API — #{API[:routes]} — " \
                             "and this studio is one client of it, not its " \
                             "reason for existing. Anything that can send a POST " \
                             "can generate an image without knowing this studio " \
                             "exists. That is why the studio holds a token of its " \
                             "own rather than sharing the pipeline's."],
      ["turning it off", "The service is a program you start and stop, so the GPU " \
                         "is yours when you want it — and stopping it is a normal " \
                         "state, not a fault. Run Job shows it offline, and a flux " \
                         "job fails with the service's own message instead of " \
                         "waiting. Start it again and nothing needs reconfiguring."],
      ["the raster comes back over /files/", "The service reports where it wrote " \
                                             "the PNG on ITS disk, which is " \
                                             "useless to a studio on another " \
                                             "machine. So the studio fetches the " \
                                             "bytes from the documented " \
                                             "/files/<name> route instead — the " \
                                             "same route any other client would " \
                                             "use."]
    ]
  }.freeze

  class << self
    def model(key)
      MODELS[key] || MODELS[DEFAULT_MODEL_KEY]
    end

    def model_for(key)
      MODELS[key.to_s]
    end

    # Everything the page needs to validate a request, handed to the browser as
    # one JSON blob so the rules are NOT restated in JavaScript. A second copy of
    # a rule is a second thing to get wrong.
    def facts
      {
        "constraints" => {
          "minDimension" => MIN_DIMENSION,
          "dimensionMultiple" => DIMENSION_MULTIPLE,
          "maxPixels" => DEFAULT_MAX_PIXELS,
          "defaultModel" => DEFAULT_MODEL_KEY
        },
        "models" => MODELS,
        "unloadable" => UNLOADABLE
      }
    end

    # Validate a request exactly as the service does, and return the SAME
    # sentences. Returns problems and warnings separately because the service
    # treats them differently: a violation is a 400 the caller must fix, a
    # warning is something the service does anyway and tells you about.
    def validate(width:, height:, images:, model_key:, guidance:, ack:,
                 negative_prompt: nil, strength: nil)
      problems = []
      warnings = []
      spec = model(model_key)

      [["width", width], ["height", height]].each do |label, value|
        if value.nil? || value.to_s.strip.empty?
          problems << "#{label} is required"
          next
        end
        unless value.to_s.match?(/\A-?\d+\z/)
          problems << "#{label} must be an integer, got #{value}"
          next
        end
        n = value.to_i
        problems << "#{label} must be at least #{MIN_DIMENSION}, got #{n}" if n < MIN_DIMENSION
        if n % DIMENSION_MULTIPLE != 0
          problems << "#{label} must be a multiple of #{DIMENSION_MULTIPLE}, got #{n}"
        end
      end

      if images.to_s.match?(/\A-?\d+\z/) && images.to_i < 1
        problems << "images must be a positive integer, got #{images}"
      end

      pixels = nil
      if problems.empty?
        pixels = width.to_i * height.to_i
        if pixels > DEFAULT_MAX_PIXELS
          problems << "#{width}x#{height} is #{pixels} pixels, over the " \
                      "#{DEFAULT_MAX_PIXELS} cap"
        end
      end

      # The guidance warning is the engine's, and it says what the pipeline does
      # rather than what we wish it did.
      if spec["distilled"] && guidance.to_s.match?(/\A\d+(\.\d+)?\z/) && guidance.to_f != 1.0
        warnings << "guidance_scale #{guidance} is ignored: #{spec['key']} is " \
                    "step-wise distilled, so the pipeline never runs " \
                    "classifier-free guidance. That is also why a negative prompt " \
                    "has no effect on it — put the steering in the prompt and the " \
                    "reference image."
      end

      # The two request parameters a model may not have. The service generates
      # anyway and says so in `warnings` rather than silently dropping them, and
      # so does this: a caller who asked for a negative prompt on a distilled
      # klein needs to know it did nothing.
      if negative_prompt.to_s.strip.present? && !spec["negative_prompt"]
        warnings << "negative prompt ignored: #{spec['key']} has no " \
                    "negative_prompt parameter"
      end
      if strength.to_s.strip.present? && !spec["img2img_strength"]
        warnings << "strength ignored: #{spec['key']} is not an SD-style " \
                    "img2img model"
      end

      # The licence gate, in the registry's own words.
      if spec["commercial_ok"] == false && ack.to_s != "1"
        problems << "#{spec['key']} is #{spec['licence']} — non-commercial use " \
                    "only. Loading it requires an explicit acknowledgement " \
                    "(CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1) so a commercial " \
                    "deployment cannot happen by accident; commercial use of its " \
                    "output requires a licence from Black Forest Labs."
      end

      { problems: problems, warnings: warnings, pixels: pixels, spec: spec }
    end
  end
end
