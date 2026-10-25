# frozen_string_literal: true

# The ONE registry of studio hints (#41).
#
# A page's small-print hint is, by rule, ONE line: the sentence an operator
# reads without opening anything. Anything longer — the account of a gate, the
# shape of a contract, where a thing is actually changed — belongs HERE, as the
# `detail` a `help_tip(key)` `?` opens, rather than being re-typed inline on
# every page that needs it.
#
# One key per hint, so the text has exactly one home:
#
#   key        -> { line:, detail:, change_at: }
#   line         the one sentence that stays inline (safe to show as-is).
#   detail       the popup body. HTML is allowed because the existing hints
#                carry <span class="mono"> markers; it is authored here, never
#                taken from a request.
#   change_at    where the thing is changed (contract key / env var / code),
#                or nil when the hint is a read-only account of something this
#                app cannot change.
#
# Adding a hint: add the key here and call `help_tip(key)` from a view. The
# registry-integrity test (test/lib/help_tips_test.rb) fails if a key is used
# in a view but missing here, or present here but used nowhere — so an orphan
# cannot survive either direction.
module HelpTips
  REGISTRY = {
    # --------------------------------------------------------------- JEV page
    "jev.page" => {
      line: "Four typed questions the annotator answers.",
      detail: "Four typed questions the annotator answers from a proof's measurements, and the confidence floor below which an answer is discarded. The fields are a working COPY, and that is all they are: an edit changes the preview and the JSON you copy out, but nothing the service asks — <span class=\"mono\">chopshop-jev</span>'s annotator ships those four questions in its own source and has no <span class=\"mono\">--questions</span> flag, so a run never sees this page.",
      change_at: "chopshop-jev scripts/jev_annotate.py (QUESTIONS)"
    },
    "jev.type" => {
      line: "choice · score · noul, each with its own certainty.",
      detail: "choice carries a real confidence · score reads <span class=\"mono\">max(probabilities)</span> · noul is <span class=\"mono\">2·|v − 0.5|</span>",
      change_at: "chopshop-jev scripts/jev_annotate.py (_answer_confidence)"
    },
    "jev.question_key" => {
      line: "The key the answer comes back under.",
      detail: "The key the answer comes back under. Fixed — the verdict reads it by name.",
      change_at: "chopshop-jev scripts/jev_annotate.py (QUESTIONS keys)"
    },
    "jev.criteria" => {
      line: "One row per permitted value, or one per tonal grade.",
      detail: "One row per permitted value. An unexpected answer falls through to unclear. For a score question the rows are tonal grades: the label is fixed, and the wording is yours.",
      change_at: "chopshop-jev scripts/jev_annotate.py (QUESTIONS criteria)"
    },
    "jev.instructions" => {
      line: "Sent verbatim as the question.",
      detail: "Sent verbatim as the question. Keep it closed — the annotator is told to judge only from the supplied measurements.",
      change_at: "chopshop-jev scripts/jev_annotate.py (QUESTIONS instructions)"
    },
    "jev.confidence_floor" => {
      line: "Answers below this floor land in low_confidence.",
      detail: "Answers below this land in <span class=\"mono\">low_confidence</span> instead of being reported as settled. A module constant in <span class=\"mono\">jev_annotate.py</span>.",
      change_at: "chopshop-jev scripts/jev_annotate.py (DEFAULT_CONFIDENCE_FLOOR)"
    },
    "jev.metrics" => {
      line: "The measured values the annotator reads.",
      detail: "One per line, from <a href=\"#\" class=\"jev-file-link\" data-popup=\"jev-remediation-popup\" title=\"View and edit remediation_table.json\" aria-label=\"View and edit remediation_table.json\"><span class=\"mono\">remediation_table.json</span></a>. These define progress for a mode: ANY improves, NONE regresses. No model output ever becomes a parameter value. Read-only because the annotator's conf carries no metrics field — the list is the runner's own constant, shown here so it can be read, not sent.",
      change_at: "chopshop-jev remediation_table.json"
    },
    "jev.answered_by" => {
      line: "Which service answered, over the last 200 answers.",
      detail: "What has actually answered, over the last 200 stored answers. The endpoint and the model it reported are what tell the two backends apart in practice — the hosted service names <span class=\"mono\">jev-1.x</span>, a locally served one names its own decision head.",
      change_at: nil
    },
    "jev.local_service" => {
      line: "How to run the local decision service.",
      detail: "To run the local one: the quadlet <span class=\"mono\">jev/deploy/laya/chopshop-laya.container</span> and <span class=\"mono\">jev/deploy/chopshop-laya.env.example</span>, with <span class=\"mono\">jev/docs/local-decision-service.md</span> for the install, the cutover and the order to verify it in.",
      change_at: "chopshop-jev deploy/ and docs/"
    },

    # --------------------------------------------------------------- BP page
    # BpConf's field hints, the same one-key-per-hint shape the JEV page's
    # fields use (#41). A field whose hint is longer than one line carries a
    # `help_key` and renders the registry's `?`; a field whose hint is short
    # keeps its own inline text. The long account lives HERE, not under the
    # control.
    #
    # The Operations card's hints are the six operations' own `draws` strings
    # (chopshop-bp's OPERATIONS), so a long one is keyed by operation.
    "bp.port" => {
      line: "Clear of the mock, SVG and FLUX ports.",
      detail: "8796: clear of the mock runner (8790), the SVG runner (8787) and FLUX (8795).",
      change_at: "env CHOPSHOP_BP_PORT"
    },
    "bp.plot.runner_kind" => {
      line: "What makes it a plot runner, not a pipeline one.",
      detail: "The kind is what makes it a plot runner rather than a pipeline one.",
      change_at: "env CHOPSHOP_RUNNER_PLOT_KIND"
    },
    "bp.blender.runner_kind" => {
      line: "What makes it a blender runner, not a plot one.",
      detail: "The kind is what makes it a blender runner rather than a plot one.",
      change_at: "env CHOPSHOP_RUNNER_BLENDER_KIND"
    },
    "bp.elements" => {
      line: "The eight element types; FIELDS lists what each carries.",
      detail: "Eight types; the FIELDS popup lists what each one must carry.",
      change_at: "chopshop_bp/spec.py (check_element)"
    },
    "bp.plot.chart" => {
      line: "Which charts belong to which operation.",
      detail: "scatter / pareto / diff draw over runs; bar / line / scatter over one run.",
      change_at: "chopshop_bp/query.py (QUERY_CHARTS)"
    },
    "bp.blender.engine" => {
      line: "workbench is fast; eevee is shaded.",
      detail: "workbench is the fast rasteriser; eevee is the shaded engine.",
      change_at: "chopshop_bp/blender.py (render.engine)"
    },
    "bp.op.generate" => {
      line: "Draws shapes, tiling and patterns.",
      detail: "shapes, tiling and patterns — a programmatic SOURCE for the front half",
      change_at: "chopshop_bp/server.py (OPERATIONS)"
    },
    "bp.op.query" => {
      line: "Draws a cross-run scatter, Pareto frontier or diff.",
      detail: "cross-run scatter, a Pareto trade-off frontier, or a two-way diff",
      change_at: "chopshop_bp/server.py (OPERATIONS)"
    },
    "bp.op.tree" => {
      line: "Draws a layered diagram in id order.",
      detail: "a layered diagram — roots, depth, one slot per leaf, in id order",
      change_at: "chopshop_bp/server.py (OPERATIONS)"
    },
    "bp.op.log" => {
      line: "Draws one row per event, in spec order.",
      detail: "one row per event, in the order given — the spec order IS the time order",
      change_at: "chopshop_bp/server.py (OPERATIONS)"
    },
    "bp.op.blender" => {
      line: "Renders files: a frame, or a frames manifest.",
      detail: "rendered FILES, not a document — one view as `image/png`, or a frames manifest plus a GLB export name",
      change_at: "chopshop_bp/server.py (OPERATIONS)"
    },

    # ------------------------------------------------------------- JSON page
    "json.page" => {
      line: "Every job runs against a contract.",
      detail: "Every job runs against a contract: colour budget, geometry limits, tolerances, sweep caps. Every key is optional — anything you leave out falls back to the pipeline's default.",
      change_at: "spec (the job contract)"
    },
    "json.allow_raster_embed" => {
      line: "Allow a raster hidden in the vector.",
      detail: "Allow a raster hidden in the vector. Off is a hard finding — <span class=\"mono\">RASTER_EMBED</span>: an <span class=\"mono\">&lt;image&gt;</span>, an <span class=\"mono\">&lt;feImage&gt;</span>, a <span class=\"mono\">&lt;foreignObject&gt;</span>, a reference to another document, or a raster paint server.",
      change_at: "spec.geometry.allow_raster_embed"
    },
    "json.allow_gradients" => {
      line: "Allow gradients / continuous tone.",
      detail: "Allow gradients / continuous tone. Off is a hard finding — <span class=\"mono\">GRADIENT_NOT_ALLOWED</span>: a declared gradient, or any <span class=\"mono\">url(#…)</span> paint server.",
      change_at: "spec.geometry.allow_gradients"
    },
    "json.count_white_as_ink" => {
      line: "Count pure white as an ink.",
      detail: "Count pure white as an ink. The pipeline's default is <span class=\"mono\">false</span> — white is the substrate. Set it true for a <em>dark</em> garment, where white is the underbase screen: the page then also writes the implied <span class=\"mono\">dark_garment_underbase</span>.",
      change_at: "spec.print.count_white_as_ink"
    },
    "json.ramp_min_members" => {
      line: "A merged ink from this many colours is a ramp.",
      detail: "A merged ink built from at least this many colours is a ramp, not a flat ink.",
      change_at: "spec.print.ramp_min_members"
    },
    "json.validation_variants" => {
      line: "Build a training set from the proof.",
      detail: "Out of the box this asks for every copy. Name a comma-separated subset to ask for less — an unknown name is refused by the runner, which quotes its vocabulary.",
      change_at: "spec.validation.variants"
    },
    "json.assume_opaque_bg" => {
      line: "Skip background removal.",
      detail: "The source has no transparent background, so prep does not strip one. Off is the documented default.",
      change_at: "spec.print.assume_opaque_bg"
    },
    "json.prep_colors" => {
      line: "pngquant's colour budget for the prepped raster.",
      detail: "pngquant's colour budget for the prepped raster. <span class=\"mono\">null</span> disables quantisation outright. Blank leaves the pipeline its own default (16).",
      change_at: "spec.print.prep_colors"
    },
    "json.filters" => {
      line: "ImageMagick passes before tracing.",
      detail: "ImageMagick passes on the source, before tracing. Each variant is a candidate input, never a trace.",
      change_at: "spec.print.prep_expand.filters"
    },
    "json.keep_alpha_filters" => {
      line: "Keep the matte through the filter bench.",
      detail: "Off, every variant is flattened onto <span class=\"mono\">background_hex</span>; on, the matte survives the bench. Only worth it when the artwork really is a knockout.",
      change_at: "spec.print.prep_expand.filters.keep_alpha"
    },
    "json.filters_spec" => {
      line: "The spec.json the remap presets read.",
      detail: "The spec.json the remap presets read — their <span class=\"mono\">background_hex</span> and their palette. Blank uses the tool's own default.",
      change_at: "spec.print.prep_expand.filters.spec"
    },
    "json.tune_speckle" => {
      line: "Speckle sizes this bench sweeps.",
      detail: "Speckle sizes this bench sweeps, comma-separated px. The main sweep's own speckle list is on Job Spec; this is the bench's.",
      change_at: "spec.print.prep_expand.tune.filter_speckle"
    },
    "json.tune_hier" => {
      line: "Layer stacking modes this bench sweeps.",
      detail: "Layer stacking modes this bench sweeps. Blank uses the tool's own list.",
      change_at: "spec.print.prep_expand.tune.hierarchical"
    },
    "json.tune_node_reduce" => {
      line: "Rank the REDUCED node counts in the tune table.",
      detail: "Runs node_reduce on each cell's trace, so the tune table ranks the REDUCED node counts. Off by default: it multiplies the bench's cost.",
      change_at: "spec.print.prep_expand.tune.with_node_reduce"
    },
    "json.nr_tolerance" => {
      line: "How far the simplifier may pull a point.",
      detail: "How far the simplifier may pull a point, in px. Larger removes more nodes and bends the outline more.",
      change_at: "spec.print.prep_expand.node_reduce.tolerance"
    },
    "json.nr_tolerance_cap" => {
      line: "The ceiling a path's tolerance may reach.",
      detail: "The ceiling a path's tolerance may be raised to while it is still over the node gate. Blank leaves the tool its own cap.",
      change_at: "spec.print.prep_expand.node_reduce.tolerance_cap"
    },
    "json.nr_verify" => {
      line: "Report ink lost and the gap blob.",
      detail: "Reports ink lost and the gap blob. Clearing the gate is not the same as the art surviving.",
      change_at: "spec.print.prep_expand.node_reduce.verify"
    },
    "json.substrate_hex" => {
      line: "The fabric itself, declared outright.",
      detail: "The fabric itself, declared outright. An explicit <span class=\"mono\">#rrggbb</span> WINS over the fabric mark on a palette chip, and typing one clears it.",
      change_at: "spec.print.substrate"
    },
    "json.substrate_index" => {
      line: "Which palette entry is the garment, counting from 0.",
      detail: "Which palette entry is the garment, counting from 0. Set by the fabric mark on a chip in the strip below; it is ignored while a hex is in the box above, which is what wins.",
      change_at: "spec.print.substrate_index"
    },

    # ---------------------------------------------------------- colour map
    # Rendered by shared/_colour_map.html.erb, which the JSON page and the
    # composite builder both include -- so the key is not page-prefixed.
    "colour_map.library" => {
      line: "The shop's palette library.",
      detail: "The shop's palette library — geometry is untouched by a palette, only the colour vectors change. Click a palette's frame to copy it in whole, or take colours from it one at a time with ＋; the spec's own palette stays editable in the colour spec block.",
      change_at: "chopshop-svg scripts/palettes.json"
    },

    # ------------------------------------------------------------- FLUX page
    "flux.page" => {
      line: "This page configures the chopshop-flux generation service.",
      detail: "This page configures the <span class=\"mono\">chopshop-flux</span> generation service and generates nothing itself — the prompt, the reference image and the size are on Run Job.",
      change_at: "chopshop-flux (the service's own env)"
    },
    "flux.width" => {
      line: "Multiple of the model's own alignment.",
      detail: "Multiple of the model's own alignment — 16 on klein, 32 on Sana, 8 on SDXL.",
      change_at: "chopshop-flux models.py (dim_multiple)"
    },
    "flux.strength" => {
      line: "img2img only, and only on sdxl-1.0.",
      detail: "img2img only, and only on sdxl-1.0, and only with a reference.",
      change_at: "chopshop-flux (the model's own img2img_strength flag)"
    },

    # ------------------------------------------------------ JOB TYPE notes
    # The Run Job page's job-type notes (issue #14). ONE KEY PER TEMPLATE,
    # because a template's notes are its own: the blurb, the levers it sets
    # with the value each would compose, and the account of where the bounds
    # actually come from.
    #
    # They were inline small print under the button row -- eleven templates
    # each restating the same block, the tallest thing on the page and the
    # least read -- then a hidden target a bespoke `?` read. They live HERE
    # now, and the row's `?` is a help_tip(key) like every other hint on the
    # site, so the popup is the app's standard one rather than a second
    # mechanism.
    #
    # The lever rows are pinned against PipelineConf in
    # test/controllers/run_job_jobtype_tips_test.rb: a template gaining or
    # losing a lever, or a default moving, fails a test rather than quietly
    # describing the wrong contract.
    #
    # The template's own blurb is the detail's opening sentence. Its source
    # is the model (PipelineConf::TEMPLATES); it is quoted here because the
    # popup is rendered from this registry and never re-reads the model.
    "jobtype.standard" => {
      line: "One colour budget, a full preset sweep.",
      detail: "One colour budget, a full preset sweep, the pipeline's own defaults. What an ordinary trace job is.<span class=\"jobtype-set\"><span class=\"jobtype-set-head\">What it sets</span><span class=\"jobtype-set-row\"><span class=\"mono\">max_colors</span><span class=\"jobtype-set-val\">6</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">max_candidates</span><span class=\"jobtype-set-val\">12</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">filter_speckle</span><span class=\"jobtype-set-val\">2, 8, 16</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">presets</span><span class=\"jobtype-set-val\">bw, poster, photo</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">hierarchical</span><span class=\"jobtype-set-val\">cutout, stacked</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">min_stroke_width_pt</span><span class=\"jobtype-set-val\">1.5</span></span></span><span class=\"jobtype-prose\">A template never restates a range. The bound for each lever belongs to the service that enforces it — <span class=\"mono\">trace_sweep.py</span>'s <span class=\"mono\">DEFAULT_SWEEP</span>, <span class=\"mono\">config.py</span>'s <span class=\"mono\">MIN_DIMENSION</span>, the blend document's own <span class=\"mono\">render.views</span> — so a service changing its default changes what this offers.</span>",
      change_at: "studio/app/models/pipeline_conf.rb (TEMPLATES[\"standard\"])"
    },
    "jobtype.screenprint" => {
      line: "Four inks and a hard minimum stroke.",
      detail: "Four inks and a hard minimum stroke. Fewer candidates — with four inks the interesting axis is the palette, not the sweep.<span class=\"jobtype-set\"><span class=\"jobtype-set-head\">What it sets</span><span class=\"jobtype-set-row\"><span class=\"mono\">max_colors</span><span class=\"jobtype-set-val\">4</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">max_candidates</span><span class=\"jobtype-set-val\">8</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">min_stroke_width_pt</span><span class=\"jobtype-set-val\">1.5</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">prep_colors</span><span class=\"jobtype-set-val\">8</span></span></span><span class=\"jobtype-prose\">A template never restates a range. The bound for each lever belongs to the service that enforces it — <span class=\"mono\">trace_sweep.py</span>'s <span class=\"mono\">DEFAULT_SWEEP</span>, <span class=\"mono\">config.py</span>'s <span class=\"mono\">MIN_DIMENSION</span>, the blend document's own <span class=\"mono\">render.views</span> — so a service changing its default changes what this offers.</span>",
      change_at: "studio/app/models/pipeline_conf.rb (TEMPLATES[\"screenprint\"])"
    },
    "jobtype.photo" => {
      line: "The photo preset, gradients allowed.",
      detail: "The photo preset with gradients allowed, and an ink limit that says so. The one template that relaxes a gate.<span class=\"jobtype-set\"><span class=\"jobtype-set-head\">What it sets</span><span class=\"jobtype-set-row\"><span class=\"mono\">max_colors</span><span class=\"jobtype-set-val\">8</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">max_candidates</span><span class=\"jobtype-set-val\">12</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">presets</span><span class=\"jobtype-set-val\">bw, poster, photo</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">hierarchical</span><span class=\"jobtype-set-val\">cutout, stacked</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">min_stroke_width_pt</span><span class=\"jobtype-set-val\">0.75</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">ink_limit_percent</span><span class=\"jobtype-set-val\">400</span></span></span><span class=\"jobtype-prose\">A template never restates a range. The bound for each lever belongs to the service that enforces it — <span class=\"mono\">trace_sweep.py</span>'s <span class=\"mono\">DEFAULT_SWEEP</span>, <span class=\"mono\">config.py</span>'s <span class=\"mono\">MIN_DIMENSION</span>, the blend document's own <span class=\"mono\">render.views</span> — so a service changing its default changes what this offers.</span>",
      change_at: "studio/app/models/pipeline_conf.rb (TEMPLATES[\"photo\"])"
    },
    "jobtype.deep_sweep" => {
      line: "Every preset, both node modes, at the ceiling.",
      detail: "Every preset and both node-preserving modes, at the candidate ceiling. Slow, and worth it when the ordinary sweep found nothing.<span class=\"jobtype-set\"><span class=\"jobtype-set-head\">What it sets</span><span class=\"jobtype-set-row\"><span class=\"mono\">max_colors</span><span class=\"jobtype-set-val\">6</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">max_candidates</span><span class=\"jobtype-set-val\">24</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">filter_speckle</span><span class=\"jobtype-set-val\">2, 8, 16</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">presets</span><span class=\"jobtype-set-val\">bw, poster, photo</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">hierarchical</span><span class=\"jobtype-set-val\">cutout, stacked</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">min_stroke_width_pt</span><span class=\"jobtype-set-val\">1.5</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">max_nodes_per_path</span><span class=\"jobtype-set-val\">500</span></span></span><span class=\"jobtype-prose\">A template never restates a range. The bound for each lever belongs to the service that enforces it — <span class=\"mono\">trace_sweep.py</span>'s <span class=\"mono\">DEFAULT_SWEEP</span>, <span class=\"mono\">config.py</span>'s <span class=\"mono\">MIN_DIMENSION</span>, the blend document's own <span class=\"mono\">render.views</span> — so a service changing its default changes what this offers.</span>",
      change_at: "studio/app/models/pipeline_conf.rb (TEMPLATES[\"deep_sweep\"])"
    },
    "jobtype.generate_and_trace" => {
      line: "FLUX draws the raster, the sweep traces it.",
      detail: "FLUX draws the raster, the sweep traces it. Variations first — the whole point is choosing which one to trace.<span class=\"jobtype-set\"><span class=\"jobtype-set-head\">What it sets</span><span class=\"jobtype-set-row\"><span class=\"mono\">max_colors</span><span class=\"jobtype-set-val\">6</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">max_candidates</span><span class=\"jobtype-set-val\">12</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">presets</span><span class=\"jobtype-set-val\">bw, poster, photo</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">flux_variations</span><span class=\"jobtype-set-val\">4</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">flux_guidance</span><span class=\"jobtype-set-val\">the service's own</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">flux_steps</span><span class=\"jobtype-set-val\">the service's own</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">flux_width</span><span class=\"jobtype-set-val\">1024</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">flux_height</span><span class=\"jobtype-set-val\">1024</span></span></span><span class=\"jobtype-prose\">A template never restates a range. The bound for each lever belongs to the service that enforces it — <span class=\"mono\">trace_sweep.py</span>'s <span class=\"mono\">DEFAULT_SWEEP</span>, <span class=\"mono\">config.py</span>'s <span class=\"mono\">MIN_DIMENSION</span>, the blend document's own <span class=\"mono\">render.views</span> — so a service changing its default changes what this offers.</span>",
      change_at: "studio/app/models/pipeline_conf.rb (TEMPLATES[\"generate_and_trace\"])"
    },
    "jobtype.generate_only" => {
      line: "The raster IS the deliverable.",
      detail: "The raster IS the deliverable. Nothing is traced and no gates run.<span class=\"jobtype-set\"><span class=\"jobtype-set-head\">What it sets</span><span class=\"jobtype-set-row\"><span class=\"mono\">flux_variations</span><span class=\"jobtype-set-val\">1</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">flux_guidance</span><span class=\"jobtype-set-val\">the service's own</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">flux_steps</span><span class=\"jobtype-set-val\">the service's own</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">flux_width</span><span class=\"jobtype-set-val\">1024</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">flux_height</span><span class=\"jobtype-set-val\">1024</span></span></span><span class=\"jobtype-prose\">A template never restates a range. The bound for each lever belongs to the service that enforces it — <span class=\"mono\">trace_sweep.py</span>'s <span class=\"mono\">DEFAULT_SWEEP</span>, <span class=\"mono\">config.py</span>'s <span class=\"mono\">MIN_DIMENSION</span>, the blend document's own <span class=\"mono\">render.views</span> — so a service changing its default changes what this offers.</span>",
      change_at: "studio/app/models/pipeline_conf.rb (TEMPLATES[\"generate_only\"])"
    },
    "jobtype.draw_document" => {
      line: "chopshop-bp draws the geometry you paste.",
      detail: "chopshop-bp draws the geometry you paste. The canvas is the only lever the form owns.<span class=\"jobtype-set\"><span class=\"jobtype-set-head\">What it sets</span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_op</span><span class=\"jobtype-set-val\">generate</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_canvas_width</span><span class=\"jobtype-set-val\">800</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_canvas_height</span><span class=\"jobtype-set-val\">400</span></span></span><span class=\"jobtype-prose\">A template never restates a range. The bound for each lever belongs to the service that enforces it — <span class=\"mono\">trace_sweep.py</span>'s <span class=\"mono\">DEFAULT_SWEEP</span>, <span class=\"mono\">config.py</span>'s <span class=\"mono\">MIN_DIMENSION</span>, the blend document's own <span class=\"mono\">render.views</span> — so a service changing its default changes what this offers.</span>",
      change_at: "studio/app/models/pipeline_conf.rb (TEMPLATES[\"draw_document\"])"
    },
    "jobtype.render_3d" => {
      line: "The same document, extruded and shaded.",
      detail: "The same document, extruded and shaded. Depth and bevel are what turn a flat drawing into a solid.<span class=\"jobtype-set\"><span class=\"jobtype-set-head\">What it sets</span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_op</span><span class=\"jobtype-set-val\">blender</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_views</span><span class=\"jobtype-set-val\">1</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_depth</span><span class=\"jobtype-set-val\">0.5</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_bevel_depth</span><span class=\"jobtype-set-val\">0.02</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_engine</span><span class=\"jobtype-set-val\">workbench</span></span></span><span class=\"jobtype-prose\">A template never restates a range. The bound for each lever belongs to the service that enforces it — <span class=\"mono\">trace_sweep.py</span>'s <span class=\"mono\">DEFAULT_SWEEP</span>, <span class=\"mono\">config.py</span>'s <span class=\"mono\">MIN_DIMENSION</span>, the blend document's own <span class=\"mono\">render.views</span> — so a service changing its default changes what this offers.</span>",
      change_at: "studio/app/models/pipeline_conf.rb (TEMPLATES[\"render_3d\"])"
    },
    "jobtype.sprite_alpha" => {
      line: "One orthographic frame, front-on, cut out.",
      detail: "One orthographic frame, front-on, nothing behind it: an RGBA PNG with the subject cut out, at a power-of-two size.<span class=\"jobtype-set\"><span class=\"jobtype-set-head\">What it sets</span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_op</span><span class=\"jobtype-set-val\">blender</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_views</span><span class=\"jobtype-set-val\">1</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_render_width</span><span class=\"jobtype-set-val\">512</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_render_height</span><span class=\"jobtype-set-val\">512</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_background</span><span class=\"jobtype-set-val\">transparent</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_projection</span><span class=\"jobtype-set-val\">ortho</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_elevation</span><span class=\"jobtype-set-val\">0.0</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_engine</span><span class=\"jobtype-set-val\">workbench</span></span></span><span class=\"jobtype-prose\">A template never restates a range. The bound for each lever belongs to the service that enforces it — <span class=\"mono\">trace_sweep.py</span>'s <span class=\"mono\">DEFAULT_SWEEP</span>, <span class=\"mono\">config.py</span>'s <span class=\"mono\">MIN_DIMENSION</span>, the blend document's own <span class=\"mono\">render.views</span> — so a service changing its default changes what this offers.</span>",
      change_at: "studio/app/models/pipeline_conf.rb (TEMPLATES[\"sprite_alpha\"])"
    },
    "jobtype.prop_turntable" => {
      line: "Four views around, plus a GLB.",
      detail: "Four orthographic views walked evenly around the object, with a GLB beside them.<span class=\"jobtype-set\"><span class=\"jobtype-set-head\">What it sets</span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_op</span><span class=\"jobtype-set-val\">blender</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_views</span><span class=\"jobtype-set-val\">4</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_render_width</span><span class=\"jobtype-set-val\">512</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_render_height</span><span class=\"jobtype-set-val\">512</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_projection</span><span class=\"jobtype-set-val\">ortho</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_elevation</span><span class=\"jobtype-set-val\">25.0</span></span><span class=\"jobtype-set-row\"><span class=\"mono\">bp_engine</span><span class=\"jobtype-set-val\">workbench</span></span></span><span class=\"jobtype-prose\">A template never restates a range. The bound for each lever belongs to the service that enforces it — <span class=\"mono\">trace_sweep.py</span>'s <span class=\"mono\">DEFAULT_SWEEP</span>, <span class=\"mono\">config.py</span>'s <span class=\"mono\">MIN_DIMENSION</span>, the blend document's own <span class=\"mono\">render.views</span> — so a service changing its default changes what this offers.</span>",
      change_at: "studio/app/models/pipeline_conf.rb (TEMPLATES[\"prop_turntable\"])"
    },
    "jobtype.generate_trace_render" => {
      line: "One job, three steps: draw, trace, render.",
      detail: "FLUX draws the raster, the pipeline traces it to SVG, bp renders that geometry in 3D — one job, three steps, each handed the file the step before produced. Fill the prompt in the first row.<span class=\"jobtype-prose\">A template never restates a range. The bound for each lever belongs to the service that enforces it — <span class=\"mono\">trace_sweep.py</span>'s <span class=\"mono\">DEFAULT_SWEEP</span>, <span class=\"mono\">config.py</span>'s <span class=\"mono\">MIN_DIMENSION</span>, the blend document's own <span class=\"mono\">render.views</span> — so a service changing its default changes what this offers.</span>",
      change_at: "studio/app/models/pipeline_conf.rb (TEMPLATES[\"generate_trace_render\"])"
    }
  }.freeze

  # The hint for a key, or nil when the key is unknown. A caller that gets nil
  # decides what to show; the integrity test is what keeps a typo from silently
  # rendering nothing.
  def self.fetch(key)
    REGISTRY[key.to_s]
  end

  def self.key?(key)
    REGISTRY.key?(key.to_s)
  end

  def self.keys
    REGISTRY.keys
  end
end
