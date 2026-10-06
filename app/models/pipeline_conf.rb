# The lever BOUNDS, and the templates that choose a subset of them.
#
# Two constants hashes and the arithmetic between them, because they are two
# different kinds of fact and the whole design rests on keeping them apart:
#
#   BOUNDS  — what each runner's contract will accept at all. Transcribed from
#              the SERVICES, not invented here: chopshop-svg's trace_sweep.py /
#              front_common.py / spec.example.json, chopshop-flux's config.py +
#              models.py, chopshop-bp's config.py + spec.py. Same house pattern
#              as FluxConf and PlotConf (config in a model, transcribed
#              verbatim, never paraphrased): a bound the studio invents is a
#              request the service will refuse, and a batch built from one
#              discovers that at the GPU, not at the form.
#   TEMPLATES — a NAME and a CHOSEN SUBSET of the bounds above, with sane
#              defaults inside them. A template carries NO ranges. If it
#              restated them it would become a second source of truth for
#              every default and every limit, which is the exact drift trap
#              already paid for once between FluxConf and config.py (it costs
#              a cross-repo parity test to keep them in step). The subset is
#              the feature: "expose these levers, configurable" is what makes
#              the form usable without the operator reading the JSON page.
#
# Why a template is a parameter SPACE and not a preset: `max_colors: 6` alone
# is a single point, which is not sampleable — an automated batch wants the
# range it may sweep. `max_colors: 4..8` is directly sampleable and the bounds
# are the guardrail, so a batch cannot generate a request the runner refuses.
#
# A template names a RUNNER KIND, not a runner label: the levers are a property
# of the contract, and the labels are this deployment's env (`CHOPSHOP_RUNNER_*`).
# A deployment that renames its runner still gets the templates.
class PipelineConf
  # The lever vocabulary. Each entry is the JSON pointer into a job's spec, a
  # type, the bound the service enforces, and the DEFAULT when the operator
  # touches nothing. `spec_path` is read by the form, which is the only place
  # these are surfaced — the JSON page remains the union of everything and the
  # escape hatch for anyone who wants the raw contract.
  #
  # The dash key is the LEVER's name in the template, not the spec's: a template
  # author writes levers, the form maps them onto the fields the pipeline reads.
  BOUNDS = {
    # ---- chopshop-svg, the trace pipeline (docs/runner-contract.md) ----
    # `max_colors` is the ink budget both gate layers read; the pipeline's own
    # example spec ships 6.
    "max_colors" => {
      kind: "svg", label: "Colour budget", spec_path: %w[max_colors], type: :integer,
      min: 2, max: 12, default: 6, step: 1,
      bound_source: "spec.example.json `max_colors`; a screen-print ink budget, and the gate reads it",
      note: "How many inks the print check will pass. Fewer is a smaller palette to sort, not a worse trace."
    },
    # trace_sweep.py: `cap < 1` is clamped, and the sweep is the candidate
    # generator — so this is a COST lever as much as a depth one.
    "max_candidates" => {
      kind: "svg", label: "Candidates", spec_path: %w[print sweep max_candidates],
      type: :integer, min: 1, max: 24, default: 12, step: 1,
      bound_source: "trace_sweep.py DEFAULT_SWEEP[\"max_candidates\"] = 12",
      note: "How many traced candidates come back to choose from. More is more time on the runner."
    },
    "filter_speckle" => {
      kind: "svg", label: "Speckle sweep", spec_path: %w[print sweep filter_speckle],
      type: :integer_list, min: 0, max: 64, default: [2, 8, 16],
      bound_source: "trace_sweep.py DEFAULT_SWEEP[\"filter_speckle\"] = [2, 8, 16]",
      note: "Dots dropped at these pixel radii. An empty box sweeps no speckle axis at all."
    },
    "presets" => {
      kind: "svg", label: "Tracer presets", spec_path: %w[print sweep presets],
      type: :enum_list, values: %w[bw poster photo], default: %w[bw poster photo],
      bound_source: "trace_sweep.py PRESETS — a CLOSED list, so an unknown name is refused",
      note: "`photo` needs allow_gradients on; the pipeline drops it otherwise."
    },
    "hierarchical" => {
      kind: "svg", label: "Node-preserving modes", spec_path: %w[print sweep hierarchical],
      type: :enum_list, values: %w[cutout stacked], default: %w[cutout stacked],
      bound_source: "trace_sweep.py DEFAULT_SWEEP[\"hierarchical\"]",
      note: "The two orthogonal levers: one moves the colour count, the other the worst path's node count."
    },
    "min_stroke_width_pt" => {
      kind: "svg", label: "Min stroke", spec_path: %w[geometry min_stroke_width_pt],
      type: :float, min: 0.25, max: 6.0, default: 1.5, step: 0.25,
      bound_source: "spec.example.json `geometry.min_stroke_width_pt`",
      note: "Below this a screen cannot hold the line at all."
    },
    "max_nodes_per_path" => {
      kind: "svg", label: "Nodes per path", spec_path: %w[geometry max_nodes_per_path],
      type: :integer, min: 50, max: 5000, default: 500, step: 50,
      bound_source: "spec.example.json `geometry.max_nodes_per_path`",
      note: "A cutter's per-path limit. Raising it does not simplify anything; see the About page on node weight."
    },
    "dpi" => {
      kind: "svg", label: "Prep DPI", spec_path: %w[print dpi], type: :integer,
      min: 72, max: 600, default: 300, step: 1,
      bound_source: "front_common.py DEFAULT_DPI = 300",
      note: "The resolution prep rasterises to. Higher is a bigger upload for the same trace."
    },
    "ink_limit_percent" => {
      kind: "svg", label: "Ink limit", spec_path: %w[ink_limit_percent], type: :integer,
      min: 100, max: 600, default: 300, step: 10,
      bound_source: "spec.example.json `ink_limit_percent`",
      note: "Total coverage the print check allows. Above 300% will not cure on most garments."
    },
    "prep_colors" => {
      kind: "svg", label: "Prep colour quantisation",
      spec_path: %w[print prep_colors], type: :integer, min: 2, max: 256, default: 16,
      bound_source: "front_common.py PRINT_DEFAULTS[\"prep_colors\"] = 16",
      note: "pngquant's budget in prep. Lower collapses gradients before the tracer ever sees them."
    },

    # ---- chopshop-flux, the generator (a Run Job TARGET, not a pipeline) ----
    # `max_colors` here is the POST-PROCESS ink cap, which is a different fact
    # from the trace gate's budget of the same name — hence two levers, two
    # levers' worth of copy, and no shared default. FluxConf::POSTERIZE_MIN_COLORS
    # (8) is the floor the service enforces on posterize.
    "flux_variations" => {
      kind: "flux", label: "Variations", spec_path: %w[flux images], type: :integer,
      min: 1, max: 8, default: 1, step: 1,
      bound_source: "the form's own cap — the service takes a list, and every one is kept",
      note: "A set in one call (a triptych, a swatch sheet). Every variation is kept and previewed."
    },
    "flux_guidance" => {
      kind: "flux", label: "Guidance", spec_path: %w[flux guidance], type: :float,
      min: 0.0, max: 8.0, default: nil, step: 0.1,
      bound_source: "model-specific; each FluxConf::MODELS entry carries its measured guidance",
      note: "Blank is the model's own. IGNORED on a distilled checkpoint with no guidance embedding — the service warns."
    },
    "flux_steps" => {
      kind: "flux", label: "Steps", spec_path: %w[flux steps], type: :integer,
      min: 1, max: 50, default: nil, step: 1,
      bound_source: "model-specific; each FluxConf::MODELS entry carries its measured steps",
      note: "Blank is the model's own. More steps do NOT help a distilled checkpoint; stage paging dominates on this box."
    },
    "flux_width" => {
      kind: "flux", label: "Width", spec_path: %w[flux width], type: :integer,
      min: 64, max: 4096, default: 1024, step: 16,
      bound_source: "config.py MIN_DIMENSION = 64; the multiple is PER MODEL (FluxConf::MODELS[.dim_multiple])",
      note: "The model decides the multiple and the pixel cap — a Sana checkpoint bins a size it has no bucket for."
    },
    "flux_height" => {
      kind: "flux", label: "Height", spec_path: %w[flux height], type: :integer,
      min: 64, max: 4096, default: 1024, step: 16,
      bound_source: "config.py MIN_DIMENSION = 64; the multiple is PER MODEL",
      note: "Same rule as width. Generate at the model's native size when you can."
    },
    # `flux_ink_cap` is the GENERATOR's colour budget — the postprocess ink cap
    # — and its floor is deliberately BELOW the service's own posterize floor.
    # `postprocess.py` refuses `posterize` with `ink_cap < POSTERIZE_MIN_COLORS`
    # (8), but `ink_cap` is also readable on its own without posterize, so 8
    # would refuse a value the service accepts. The service's number is carried
    # in `note` rather than invented into `:min`, because a floor here that is
    # not a service limit is exactly the "bound the studio invented" this file
    # exists to prevent.
    "flux_ink_cap" => {
      kind: "flux", label: "Generation ink cap",
      spec_path: %w[flux postprocess ink_cap], type: :integer,
      min: 1, max: 64, default: nil, step: 1,
      bound_source: "postprocess.py POSTERIZE_MIN_COLORS = 8 applies to the posterize MODE, not to ink_cap itself",
      note: "The GENERATOR's colour budget, not the trace gate's. Blank leaves post-processing off. Under 8 is refused if the mode is posterize."
    },

    # ---- chopshop-bp, draw + render (a Run Job TARGET) ----
    "bp_op" => {
      kind: "bp", label: "Operation", spec_path: %w[bp op], type: :enum,
      values: Job::BP_OPS, default: "generate",
      bound_source: "Job::BP_OPS, which is bp's OPERATIONS tuple as the studio knows it",
      note: "Five of the six draw a document; `blender` renders geometry in 3D and answers with files."
    },
    # The canvas is the two numbers a geometry document may carry. bp's schema
    # puts no ceiling on either — MAX_BODY_BYTES (8MB) is the real limit, and a
    # canvas is a pair of integers — so the bound here is a FORM guardrail for a
    # person editing a number, not a service limit. Said so, rather than dressed
    # up as a contract rule the studio would then have to keep true.
    "bp_canvas_width" => {
      kind: "bp", label: "Canvas width", spec_path: %w[bp doc canvas width],
      type: :integer, min: 1, max: 8192, default: 800, step: 1,
      bound_source: "a form guardrail: bp's schema puts no ceiling on canvas.width",
      note: "Only for a document you author here; a pasted document brings its own canvas."
    },
    "bp_canvas_height" => {
      kind: "bp", label: "Canvas height", spec_path: %w[bp doc canvas height],
      type: :integer, min: 1, max: 8192, default: 400, step: 1,
      bound_source: "a form guardrail: bp's schema puts no ceiling on canvas.height",
      note: "A digest or query chart does not read the canvas at all."
    },
    # views is a CLOSED list in the contract — BlenderConf::VIEW_CHOICES, not a
    # range. A bound stated as `1..8` would accept 3, which the service refuses,
    # so the bound IS the choice list and the copy says why.
    "bp_views" => {
      kind: "bp", label: "Render views", spec_path: %w[bp doc render views],
      type: :enum_list, values: BlenderConf::VIEW_CHOICES,
      default: BlenderConf::DEFAULT_VIEWS,
      bound_source: "BlenderConf::VIEW_CHOICES — a CLOSED list, so 3 is not a value",
      note: "One view is a PNG; several are a JSON frames manifest plus a GLB export."
    },
    "bp_depth" => {
      kind: "bp", label: "Extrude depth", spec_path: %w[bp doc extrude depth],
      type: :float, min: 0.0, max: 10.0,
      default: BlenderConf::EXTRUDE_DEFAULTS["depth"], step: 0.05,
      bound_source: "BlenderConf::EXTRUDE_DEFAULTS[\"depth\"] — the SERVICE's constant, mirrored",
      note: "0 is a flat document, with no solid to shade."
    },
    "bp_bevel_depth" => {
      kind: "bp", label: "Bevel", spec_path: %w[bp doc extrude bevel_depth],
      type: :float, min: 0.0, max: 2.0,
      default: BlenderConf::EXTRUDE_DEFAULTS["bevel_depth"], step: 0.01,
      bound_source: "BlenderConf::EXTRUDE_DEFAULTS[\"bevel_depth\"] — the SERVICE's constant, mirrored",
      note: "A small round on the extruded edges. Much above a fraction of the depth is a mistake."
    },
    # ---- the blender pass's own render levers (bp's contract: docs/contract.md)
    # The document is pasted, so these override the PASTED document's render
    # block only where the operator sets them; the bound_source names bp's own
    # default rather than inventing one, because a default the studio makes up
    # is a request the service may refuse.
    "bp_render_width" => {
      kind: "bp", label: "Render width", spec_path: %w[bp doc render size width],
      type: :integer, min: 64, max: 4096, default: 1024, step: 1,
      bound_source: "bp's DEFAULT_RENDER_SIZE 1024x1024; the ceiling is a form guardrail (bp requires only a positive number)",
      note: "Frame width in pixels. Powers of two are what a game engine wants for a texture."
    },
    "bp_render_height" => {
      kind: "bp", label: "Render height", spec_path: %w[bp doc render size height],
      type: :integer, min: 64, max: 4096, default: 1024, step: 1,
      bound_source: "bp's DEFAULT_RENDER_SIZE 1024x1024; the ceiling is a form guardrail",
      note: "Frame height in pixels."
    },
    "bp_background" => {
      kind: "bp", label: "Background", spec_path: %w[bp doc render background],
      type: :enum,
      values: ["#1a1a24", "#0d0f16", "#ffffff", "transparent"],
      default: "#1a1a24",
      bound_source: "bp's DEFAULT_BACKGROUND plus the `transparent` sentinel bp validates (hex or the sentinel, nothing else)",
      note: "`transparent` writes an RGBA frame with the world omitted — the sprite/prop form. The contract accepts any hex; another colour is typed in the JSON box."
    },
    "bp_projection" => {
      kind: "bp", label: "Projection", spec_path: %w[bp doc render projection],
      type: :enum, values: %w[ortho perspective], default: "ortho",
      bound_source: "bp's PROJECTIONS tuple — a CLOSED list",
      note: "ortho is framing independent of distance: the orthographic read a sprite or a technical view wants."
    },
    "bp_elevation" => {
      kind: "bp", label: "Elevation", spec_path: %w[bp doc render elevation],
      type: :float, min: 0.0, max: 360.0, default: 25.0, step: 1.0,
      bound_source: "bp's DEFAULT_ELEVATION 25; bp accepts any number, the range is a form guardrail",
      note: "Degrees above the horizon. 0 is the horizon (front view), 90 is the plan view a blueprint is read in."
    },
    "bp_azimuth" => {
      kind: "bp", label: "Azimuth", spec_path: %w[bp doc render azimuth],
      type: :float, min: 0.0, max: 360.0, default: 0.0, step: 1.0,
      bound_source: "bp's DEFAULT_AZIMUTH 0; the range is a form guardrail",
      note: "Where the view sweep starts — views step evenly around from it."
    },
    "bp_engine" => {
      kind: "bp", label: "Render engine", spec_path: %w[bp doc render engine],
      type: :enum, values: BlenderConf::ENGINES, default: BlenderConf::DEFAULT_ENGINE,
      bound_source: "BlenderConf::ENGINES — the SERVICE's two words, not Blender's internal names",
      note: "The service accepts only these two and maps them itself; spelling Blender's own engine breaks the round trip."
    }
  }.freeze

  # The templates. A template is a NAME, a KIND, a one-line reason, and the
  # SUBSET of BOUNDS it exposes — each with a sane default of its own where the
  # service's default is not the right one for this shape of work.
  #
  # Two are deliberately identical to the services' own defaults, because that
  # IS the sane starting point: `standard` and `pipeline_default` differ only in
  # which levers they surface, not in what they produce.
  TEMPLATES = {
    # The DEFAULT the form opens on, and the one a person demonstrating the
    # basic flow never has to know exists. One colour budget, one candidate cap,
    # no bench, no gate to reason about.
    "standard" => {
      label: "Standard",
      blurb: "One colour budget, a full preset sweep, the pipeline's own defaults. What an ordinary trace job is.",
      levers: %w[max_colors max_candidates presets hierarchical filter_speckle min_stroke_width_pt],
      overrides: {}
    },

    # Few colours, hard-edged: the screen-print case. The ink budget is the
    # whole point, so it is the only lever that varies.
    "screenprint" => {
      label: "Screen print",
      blurb: "Four inks and a hard minimum stroke. Fewer candidates — with four inks the interesting axis is the palette, not the sweep.",
      levers: %w[max_colors min_stroke_width_pt max_candidates prep_colors],
      overrides: { "max_colors" => 4, "max_candidates" => 8, "prep_colors" => 8 }
    },

    # The photo case. `photo` needs gradients, so this template is the one that
    # turns them on — and it exposes ink_limit_percent, because a full-coverage
    # photo is the run that runs out of ink.
    "photo" => {
      label: "Photographic",
      blurb: "The photo preset with gradients allowed, and an ink limit that says so. The one template that relaxes a gate.",
      levers: %w[max_colors max_candidates presets hierarchical min_stroke_width_pt ink_limit_percent],
      overrides: {
        "max_colors" => 8,
        "presets" => %w[bw poster photo],
        "min_stroke_width_pt" => 0.75,
        "ink_limit_percent" => 400
      },
      spec: { "geometry" => { "allow_gradients" => true } }
    },

    # The exhaustive one: everything the sweep offers, for when the answer is
    # "none of these" and the operator needs the corners of the space.
    "deep_sweep" => {
      label: "Deep sweep",
      blurb: "Every preset and both node-preserving modes, at the candidate ceiling. Slow, and worth it when the ordinary sweep found nothing.",
      levers: %w[max_colors max_candidates presets hierarchical filter_speckle min_stroke_width_pt max_nodes_per_path],
      overrides: { "max_candidates" => 24 }
    },

    # Generate a source, then trace it. The only template that spans both
    # halves, and the one the flux panel needs to keep its raster-pass block
    # from looking like configuration for a stage that never runs.
    "generate_and_trace" => {
      label: "Generate, then trace",
      blurb: "FLUX draws the raster, the sweep traces it. Variations first — the whole point is choosing which one to trace.",
      kind: "flux",
      levers: %w[flux_variations flux_steps flux_guidance flux_width flux_height max_colors max_candidates presets],
      overrides: { "flux_variations" => 4 }
    },

    # One image, the model's own settings, no sweep. The generate-only case.
    "generate_only" => {
      label: "Generate only",
      blurb: "The raster IS the deliverable. Nothing is traced and no gates run.",
      kind: "flux",
      levers: %w[flux_variations flux_steps flux_guidance flux_width flux_height],
      overrides: {},
      spec: { "flux" => { "mode" => "raster" } }
    },

    # Draw a document.
    "draw_document" => {
      label: "Draw a document",
      blurb: "chopshop-bp draws the geometry you paste. The canvas is the only lever the form owns.",
      kind: "bp",
      levers: %w[bp_op bp_canvas_width bp_canvas_height],
      overrides: { "bp_op" => "generate" }
    },

    # Render it in 3D.
    "render_3d" => {
      label: "Render in 3D",
      blurb: "The same document, extruded and shaded. Depth and bevel are what turn a flat drawing into a solid.",
      kind: "bp",
      levers: %w[bp_op bp_views bp_depth bp_bevel_depth bp_engine],
      overrides: { "bp_op" => "blender" }
    },

    # ---- game-asset templates ------------------------------------------------
    # Both ask bp for frames a GAME can use rather than a document a person
    # reads. `sprite_alpha` is the one that needed bp to grow a `transparent`
    # sentinel: an RGBA frame with the subject cut out is the whole point of a
    # sprite, and every frame used to come back opaque.
    "sprite_alpha" => {
      label: "Sprite (alpha)",
      blurb: "One orthographic frame, front-on, nothing behind it: an RGBA PNG with the subject cut out, at a power-of-two size.",
      kind: "bp",
      levers: %w[bp_op bp_render_width bp_render_height bp_background bp_projection
                 bp_elevation bp_views bp_engine],
      overrides: {
        "bp_op" => "blender", "bp_background" => "transparent",
        "bp_projection" => "ortho", "bp_elevation" => 0.0, "bp_views" => 1,
        "bp_render_width" => 512, "bp_render_height" => 512,
        "bp_engine" => "workbench"
      }
    },

    # Four angles around from the front, plus the mesh: the frames a 2D game
    # swaps between for a turning prop, and the GLB a 3D one imports.
    "prop_turntable" => {
      label: "Prop turntable + GLB",
      blurb: "Four orthographic views walked evenly around the object, with a GLB beside them.",
      kind: "bp",
      levers: %w[bp_op bp_views bp_elevation bp_projection bp_render_width
                 bp_render_height bp_engine],
      overrides: {
        "bp_op" => "blender", "bp_views" => 4, "bp_elevation" => 25.0,
        "bp_projection" => "ortho", "bp_render_width" => 512,
        "bp_render_height" => 512, "bp_engine" => "workbench"
      },
      # The export is a static fragment rather than a lever: BOUNDS has no
      # boolean type (a checkbox would post "true" as a string and bp refuses
      # it), and a fragment is what a template's own non-sweepable facts are for.
      spec: { "bp" => { "doc" => { "export" => { "glb" => true } } } }
    },

    # ---- the two pipelines, ONE job ------------------------------------------
    # A step list is not a lever (there is no number to sweep), so it rides as a
    # static fragment; and a template names a RUNNER KIND, never a label — labels
    # are this deployment's env — so each step carries `kind` and the form
    # resolves it to a label when it hydrates the rows. Everything else about a
    # step is the same per-kind block a single-action job posts, which is why
    # there is no second spec shape to drift.
    #
    # The chain itself is the hand-off table's own example: flux leaves a .png,
    # the trace NEEDS a raster and leaves an .svg, bp accepts an .svg and, for
    # the blender op, derives its elements from that file at run time — so the
    # bp document below carries an EMPTY elements list on purpose (validation
    # wants the key; the trace fills it).
    "generate_trace_render" => {
      label: "Generate → trace → render",
      blurb: "FLUX draws the raster, the pipeline traces it to SVG, bp renders that geometry in 3D — one job, three steps, each handed the file the step before produced. Fill the prompt in the first row.",
      kind: "flux",
      levers: [],
      overrides: {},
      spec: {
        "steps" => [
          { "kind" => "flux", "flux" => { "mode" => "raster" } },
          { "kind" => "svg", "svg" => { "max_colors" => 6 } },
          { "kind" => "bp", "bp" => { "op" => "blender",
                                       "doc" => { "elements" => [],
                                                  "render" => { "background" => "transparent",
                                                                "views" => 1 },
                                                  "extrude" => { "depth" => 0.5,
                                                                 "bevel_depth" => 0.02 } } } }
        ]
      }
    }
  }.freeze

  # Compose a template into a spec: the LEVERS the template carries, each at
  # its sane default, written at the lever's own `spec_path`, plus the template's
  # static fragment.
  #
  # This is the whole feature, and it is deliberately NOT the form's job. The
  # Run Job page already has exactly one way to build a contract —
  # `hydratePanels()` reads a spec into the controls and `writePanels()` writes
  # the controls back into it — so a template that wrote its own values straight
  # into the DOM would be a SECOND spec path that could disagree with the first
  # (which is how a "I set it and it came back different" bug happens). Instead
  # the template produces a spec fragment, the operator sees it appear in the
  # contract textarea, and the existing round-trip hydrates the panels from it.
  # One authority, and a hand-edited template result still wins as usual.
  #
  # Deep-merged rather than assigned: a spec may already carry keys this template
  # says nothing about (a palette, a substrate, a validation block), and a
  # template that replaced the document would throw them away.
  def self.compose(template_key, into: {}, overrides: {})
    # An override naming a lever that does not exist is a TYPO, and a silent
    # no-op here means a form field that sets something the contract never
    # carries — the operator moves a control and nothing happens, which is the
    # failure this whole file's comment keeps warning about. Raise before any
    # writing, so a bad call has no partial effect.
    overrides.each_key do |lever|
      next if self.template(template_key).fetch(:levers).include?(lever.to_s)
      raise ArgumentError,
            "#{template_key} has no lever #{lever.inspect} — an override for " \
            "something the template does not expose would set a value the " \
            "contract never carries"
    end

    # A fresh hash, up front: `into` is the caller's spec and every write below
    # mutates its target, so without the copy this method would edit the hash a
    # caller still holds. `stringify_keys` both copies and normalises, so it does
    # the job `deep_dup` was doing AND gives every key one type.
    # stringify_keys, not just deep_dup: the caller's spec may be symbol-keyed
    # (a Ruby literal, as in a test) while a lever path arrives as STRINGS, so
    # `write_at` would look for "print", not find the existing `:print`, and add
    # a second one — a document with `print` twice that JSON.generate renders
    # twice and the runner reads once. Converting the whole spine up front makes
    # every later lookup find what is there.
    spec = stringify_keys(into || {})
    # The template is the operator's CHOSEN subset, so applying one clears the
    # levers it does not expose. It used to only ADD: standard -> generate_only
    # kept print.sweep.*, max_colors and the trace levers even though the new
    # template owns none of them, so the contract carried one shape of work
    # next to another. Non-lever keys (a palette, a substrate, a validation
    # block, a pasted document) live on no lever path and are untouched.
    remove_decay(spec, template_key)
    self.template(template_key).fetch(:levers).each do |name|
      value = resolve(name, template_key, overrides)
      bound = self.bound(name)
      # Blank means "the service's own", and for a lever whose own default is
      # blank there is nothing to write — a null would post an explicit "no
      # value" where the runner wants the key absent.
      next if value.nil? && bound[:default].nil?
      write_at(spec, bound[:spec_path], value)
    end
    merge_deep!(spec, self.static_spec(template_key))
    spec
  end

  # Strip what an EARLIER template left behind when the chosen one does not own
  # it: every lever path whose lever is not in this template's exposure, and
  # every cross-template static-fragment path (photo's allow_gradients,
  # generate_only's flux.mode) that this template does not restate.
  def self.remove_decay(spec, template_key)
    chosen = self.template(template_key)
    owned = chosen.fetch(:levers).map(&:to_s)
    BOUNDS.each do |name, bound|
      deep_remove(spec, bound[:spec_path]) unless owned.include?(name.to_s)
    end
    own_static = static_leaf_paths(chosen.fetch(:spec, {}))
    ALL_STATIC_PATHS.each do |path|
      deep_remove(spec, path) unless own_static.include?(path)
    end
    spec
  end

  # The leaf paths a static fragment writes, so two templates' fragments can be
  # told apart for removal (photo owns allow_gradients, generate_only owns
  # flux.mode — each goes away when the other shape of work is chosen).
  def self.static_leaf_paths(node, prefix = [])
    return [prefix] unless node.is_a?(Hash)
    node.flat_map { |k, v| static_leaf_paths(v, prefix + [k.to_s]) }
  end

  # The leaf paths ANY template's static fragment writes.
  ALL_STATIC_PATHS = TEMPLATES.values.flat_map do |tpl|
    static_leaf_paths(tpl.fetch(:spec, {}))
  end.freeze

  # Delete a value at a path and prune the empty objects left behind, so
  # removing print/sweep/max_candidates does not leave a bare "print": {}.
  def self.deep_remove(spec, path)
    segments = path.map(&:to_s)
    return spec if segments.empty?
    trail = []
    node = spec
    segments[0..-2].each do |segment|
      child = node.is_a?(Hash) ? node[segment] : nil
      break unless child.is_a?(Hash)
      trail << [node, segment]
      node = child
    end
    if node.is_a?(Hash) && node.key?(segments.last)
      node.delete(segments.last)
      trail.reverse_each do |parent, key|
        parent.delete(key) if parent[key].is_a?(Hash) && parent[key].empty?
      end
    end
    spec
  end

  # A lever's value under a template: the CALLER's override if it gave one, then
  # the template's own override, then the bound's default. Three levels, in that
  # order, because a form value the operator just typed is the most recent fact
  # and must not be overwritten by the template it started from.
  def self.resolve(name, template_key, overrides = {})
    key = name.to_s
    given = overrides.key?(key) ? deep_value(overrides[key]) : nil
    # A BLANK override falls through rather than writing nil. An untouched
    # number input posts "", and `Number("")` is 0 — the same trap that made a
    # cleared `filter_speckle` post a sweep axis nobody asked for. So "not set"
    # and "set to nothing" are the same thing here, and both mean the template's
    # own answer stands.
    unless given.nil?
      return given
    end
    tpl = self.template(template_key)
    return tpl[:overrides][key] if tpl[:overrides].key?(key)
    self.bound(key)[:default]
  end

  # An override that arrived from a form is a STRING for everything a <input>
  # carries, and "4" is not 4. Coerced to the bound's own type here rather than
  # in the view, so the contract that reaches the runner carries a number and a
  # list bound carries a list — the same rule the JSON page's own composers
  # follow. A value that will not coerce is DROPPED, not passed through as text:
  # `max_candidates: "twelve"` is a request the runner refuses, and refusing it
  # here says why.
  def self.deep_value(value)
    case value
    when Array then value.map { |v| deep_value(v) }
    when String then value.strip.empty? ? nil : value
    else value
    end
  end

  # Coerce to the bound's declared type. Raises on junk so the caller can report
  # it rather than posting a lie.
  #
  # BLANK is nil for every type, and it is checked as an empty string as well as
  # nil — an untouched form field posts "", and `Integer("")` raises rather than
  # returning 0. Treating blank as 0 is the cleared-numeric-list trap in its
  # simplest form: a box nobody filled in would post a real value.
  def self.coerce(name, value)
    b = self.bound(name)
    return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)
    case b[:type]
    when :integer
      Integer(scalar(value).to_s.strip, 10)
    when :float
      Float(scalar(value).to_s.strip)
    when :integer_list
      return nil if value.nil?
      # The sweep's `filter_speckle` is ONE text box holding "2, 8, 16", so a
      # list bound has to read a comma-separated string as readily as an array —
      # otherwise the value the control posts is the one value coerce refuses.
      # Blanks are dropped BEFORE the coercion, not after: `Integer("")` raises
      # rather than returning 0, so a trailing comma ("2, 8,") would abort the
      # whole list. Dropping after coercion would work only if 0 were
      # acceptable, and it is not — that is the cleared-list trap.
      list = value.is_a?(Array) ? value : value.to_s.split(",")
      list.map { |v| v.to_s.strip }.reject(&:empty?).map { |v| Integer(v, 10) }
    when :enum
      return nil if value.nil?
      scalar(value).to_s
    when :enum_list
      return nil if value.nil?
      Array(value).map { |v| v.to_s.strip }
    else
      value
    end
  end

  # Write a value at a path of segment NAMES, creating the objects along the way
  # and MERGING at each level rather than replacing — so writing
  # `print/sweep/max_candidates` into a spec that already carries `print/dpi`
  # keeps the dpi, and a spec holding string keys stays string-keyed.
  #
  # Every key is stringified on the way in. A job's spec arrives from JSON, so its
  # keys are strings; `spec_path` segments read better as symbols but writing them
  # through as symbols produces a hash that has `"print"` and `:print` in it at
  # once — which JSON.generate then renders as a document with the key twice and
  # the runner reads only one of them. Everything here speaks strings, and
  # `read_spec` in the form does the same.
  def self.write_at(spec, path, value)
    segments = path.map(&:to_s)
    node = spec
    segments[0..-2].each do |segment|
      # Stringify the existing node too, so a symbol-keyed spec handed in by a
      # caller converges to the same shape rather than growing a second spine.
      if node.key?(segment)
        node[segment] = stringify_keys(node[segment]) unless node[segment].is_a?(Hash)
      else
        node[segment] = {}
      end
      node = node[segment]
    end
    node[segments.last] = value
    spec
  end

  # A deep copy with every key stringified, so symbol-keyed and string-keyed
  # specs cannot both be true of one document.
  def self.stringify_keys(value)
    case value
    when Hash  then value.each_with_object({}) { |(k, v), out| out[k.to_s] = stringify_keys(v) }
    when Array then value.map { |v| stringify_keys(v) }
    else value
    end
  end

  # Merge `source` into `target` IN PLACE, recursing where both sides hold an
  # object. Keys are compared as strings, because a static fragment is written
  # with string keys and a lever path arrives as symbols — comparing them raw
  # would treat `"print"` and `:print` as two different keys and merge nothing.
  def self.merge_deep!(target, source)
    source.each do |key, value|
      k = key.to_s
      if target[k].is_a?(Hash) && value.is_a?(Hash)
        merge_deep!(target[k], value)
      else
        target[k] = value
      end
    end
    target
  end

  # The form opens on this one. "Standard", not "deep sweep": a person
  # demonstrating basic functionality must never have to know the settings
  # exist, and a form that opens on the ceiling spends the runner's time
  # before anyone has asked for it.
  DEFAULT_TEMPLATE = "standard".freeze

  # Which kind a template belongs to, defaulting to the trace pipeline — so a
  # template that names no kind is a `svg` template, which is what a trace
  # template is and what four of the eight are.
  def self.template_kind(key)
    TEMPLATES.fetch(key.to_s).fetch(:kind, "svg")
  end

  def self.template(key)
    TEMPLATES[key.to_s] or raise ArgumentError, "no such template: #{key.inspect}"
  end

  def self.template_keys
    TEMPLATES.keys
  end

  # The levers a template exposes, as [name, bound] pairs, in BOUNDS order
  # rather than the order the template lists them — so two templates showing the
  # same levers render in the same order, and a caller never has to carry a bare
  # key and look it up a second time.
  #
  # SORTED, not filtered: BOUNDS is grouped by runner kind, so its natural order
  # already groups a template's levers by what they belong to, which is how an
  # operator reads them.
  #
  # `fetch` rather than a silent skip: a template naming a lever BOUNDS does not
  # define is a typo that would otherwise render as a control that does nothing.
  def self.levers_for(key)
    order = BOUNDS.keys.each_with_index.to_h
    self.template(key).fetch(:levers)
        .map { |name| [name, BOUNDS.fetch(name)] }
        .sort_by { |name, _| order.fetch(name) }
  end

  # The lever names a template exposes, in BOUNDS order.
  def self.lever_names_for(key)
    levers_for(key).map(&:first)
  end

  # The sane default for a lever UNDER A TEMPLATE: the template's override if
  # it states one, else the bound's own default. This is the ONLY place the two
  # meet, which is what stops a template from becoming a second copy of every
  # default in the app.
  def self.default_for(template_key, name)
    tpl = self.template(template_key)
    return tpl[:overrides][name.to_s] if tpl[:overrides].key?(name.to_s)
    bound(name)[:default]
  end

  def self.bound(name)
    BOUNDS.fetch(name.to_s) { raise ArgumentError, "no such lever: #{name.inspect}" }
  end

  # A template's STATIC spec fragment — the keys that are not levers at all, so
  # they cannot be swept and there is no number to range them over. `photo`
  # turning on `allow_gradients` is one; the `generate_only` mode is another.
  # Merged UNDER the lever values, so a lever always wins over a fragment, and
  # this is shallow on purpose: a template never restates a gate an operator
  # may want to disagree with.
  def self.static_spec(template_key)
    self.template(template_key).fetch(:spec, {}).deep_dup
  end

  # Is a value inside the bound? The guardrail a batch gets for free: it is
  # asked here rather than discovering the refusal at the runner.
  #
  # A CLOSED list is compared by STRING on both sides. That is deliberate and
  # it is not cosmetic: bp's `render.views` is a list of INTEGERS
  # (BlenderConf::VIEW_CHOICES) while its operations and its two engine words
  # are STRINGS, so the lists are not all one type. Comparing `4 == 4` alone
  # works and `4 == "4"` fails for the same value on a lever whose list happens
  # to hold strings, so a form that posts JSON — where a select's value always
  # arrives as a string — would be refused a number the service accepts.
  def self.within_bounds?(name, value)
    b = BOUNDS[name.to_s] or return false
    case b[:type]
    when :integer, :float
      value.is_a?(Numeric) && value >= b[:min] && value <= b[:max]
    when :integer_list
      Array(value).all? { |v| v.is_a?(Numeric) && v >= b[:min] && v <= b[:max] }
    when :enum
      # A single-valued enum still answers through the list compare, so one
      # rule covers both and a scalar cannot slip past a list check.
      enum_include?(b, value)
    when :enum_list
      Array(value).all? { |v| enum_include?(b, v) }
    else
      true
    end
  end

  # A ONE-element array is the scalar it came from. The controller splits every
  # posted value on commas — right for a list lever, and for a scalar like "20"
  # it produces ["20"], which `Integer` will not take. Unwrapping here rather
  # than in the controller keeps ONE place that knows a scalar is not a list.
  def self.scalar(value)
    value.is_a?(Array) && value.size == 1 ? value.first : value
  end

  # Membership in a closed list, stringified on both sides. `values` is
  # whatever the source constant holds — integers for views, strings for the
  # rest — and the answer is about the NAME the contract carries.
  def self.enum_include?(bound, value)
    Array(bound[:values]).any? { |allowed| allowed.to_s == value.to_s }
  end

  # Clamp a sampled value into the bound. An automated batch that asks for a
  # range gets an answer inside it, never a refusal.
  def self.clamp(name, value)
    b = BOUNDS[name.to_s] or return value
    case b[:type]
    when :integer, :float
      return value unless value.is_a?(Numeric)
      num = b[:type] == :integer ? value.round : value
      num.clamp(b[:min], b[:max])
    else
      value
    end
  end

  # The bounds grouped by kind, for a page that shows every lever the app knows
  # about (the JSON page's contract reference, and any future settings page).
  def self.bounds_by_kind
    BOUNDS.values.group_by { |b| b[:kind] }
  end
end