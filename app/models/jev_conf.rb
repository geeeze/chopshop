# The Jev conf, mirrored from chopshop-jev.
#
# This is a faithful copy of `QUESTIONS` + `CONFIDENCE_FLOOR` in
# chopshop-jev/scripts/jev_annotate.py, which is what the annotator actually
# asks. It is shown and edited on the JEV page so the questions, their types,
# their criteria and the confidence floor are visible instead of implied.
#
# IMPORTANT, and the reason this is a model and not a settings table: the
# annotator has NO conf input. QUESTIONS is a module-level constant that
# build_envelope() deep-copies into the request, and the CLI exposes no
# --questions / --conf flag. So editing this in the browser does not yet change
# what Jev is asked -- see JevConf#editable? and the note on the page. Wiring it
# through means adding a --questions flag to jev_annotate.py and passing the
# payload from here; that is a change in another repo and is not done.
class JevConf
  # The annotator's default. Keys and criteria strings must match
  # scripts/jev_annotate.py QUESTIONS exactly.
  DEFAULT = {
    "confidence_floor" => 0.6,
    "questions" => {
      "failure_mode" => {
        "type" => "choice",
        "instructions" => "Based only on the supplied preflight measurements and finding " \
                          "details, which failure signature best describes this candidate?",
        "criteria" => {
          "screen_explosion" => "The rendered or declared artwork needs far more distinct colours " \
                                "or screens than the contract allows.",
          "continuous_tone" => "A smooth tonal transition or photographic ramp was traced, which " \
                               "flat-colour printing cannot reproduce.",
          "geometry_overload" => "Paths carry far more nodes than the limit, making the file slow to " \
                                 "RIP and hard to hand-edit.",
          "palette_mismatch" => "Declared colours fall outside the contract palette.",
          "render_or_tool_failure" => "The proof or PDF could not be produced, or a tool was missing.",
          "no_hard_failure" => "No hard finding is present in the supplied measurements.",
          "unclear" => "The supplied measurements do not identify one clear failure signature."
        }
      },
      "print_route" => {
        "type" => "choice",
        "instructions" => "Which production route best fits this artwork as measured?",
        "criteria" => {
          "screen_spot_low" => "Spot-colour screen printing within the contract colour budget.",
          "screen_spot_multi" => "Spot-colour screen printing, but above the contract budget and " \
                                 "needing more screens or a redesign.",
          "process_halftone" => "Four-colour process or simulated-process printing is required " \
                                "because tone must be reproduced.",
          "dtg_or_dtf" => "Direct-to-garment or direct-to-film fits better than screen printing " \
                          "for this artwork.",
          "unsuitable" => "No route reproduces this artwork as measured without rework.",
          "unclear" => "The measurements do not determine a production route."
        }
      },
      "tonal_structure" => {
        "type" => "score",
        "instructions" => "How faithfully did the trace preserve the source's tonal structure, " \
                          "judging only from the measured colour count, ramp and coverage numbers?",
        "criteria" => [
          "Broken: tone collapsed into noise or non-printing blends.",
          "Flat: tonal range reduced to a few hard steps with visible banding.",
          "Retained: a coherent tonal read survives in flat colours.",
          "Engraving-grade: dense, ordered tonal structure suitable as a deliberate " \
          "screen/engraving look."
        ]
      },
      "evidence_is_actionable" => {
        "type" => "noul",
        "instructions" => "Do the supplied measurements contain enough reliable evidence to act on " \
                          "a production decision, given the stated limitations?",
        "criteria" => {
          "true" => "The source, render and PDF evidence are present and their stated limitations " \
                    "do not block a production decision.",
          "false" => "A required measurement is missing, failed, or is an estimate whose limitation " \
                     "blocks a production decision."
        }
      }
    }
  }.freeze

  # The annotator's metrics: the deterministic numbers each failure mode is
  # measured against. From chopshop-jev/scripts/remediation_table.json.
  METRICS = %w[
    color_count_rendered
    color_count_declared
    path_nodes_max
    path_nodes_total
    inks_in_render
    total_area_coverage_percent
    min_stroke_width_pt
    tonal_range_steps
  ].freeze

  # Example question/response pairs, one per criterion. These are what the "?"
  # on each question reveals: a measured case, and the answer it would produce.
  #
  # The RESPONSES are deliberately short -- they are the succinct label for the
  # criterion, not the full description in DEFAULT, which is the wording the
  # annotator is actually sent and belongs in the form field above.
  EXAMPLES = {
    "failure_mode" => [
      ["7 distinct colours, 6 allowed", "Too many colours"],
      ["A 640px photographic gradient traced to a 200px ramp", "Tonal ramp — unprintable flat"],
      ["14,200 path nodes against a 2,000 limit", "Too many nodes. Slow to RIP"],
      ["Declared #ff00aa, outside the contract palette", "Colours fall outside the palette"],
      ["Inkscape returned exit 2; no PDF written", "The proof or PDF failed"],
      ["No hard finding in the manifest", "No hard finding"],
      ["Colour count 6, but 1,800 nodes and no ramp", "No single clear signature"]
    ],
    "print_route" => [
      ["3 spot colours inside a 4-colour budget", "Spot colour, within budget"],
      ["9 screens against a 6-colour budget", "Spot colour, over budget"],
      ["A continuous ramp: tone cannot be screened", "4-colour process — tone must survive"],
      ["Photographic, 5.8M pixels, full-coverage bleed", "DTG or DTF fits better"],
      ["14,200 nodes, no route under 20s", "No route fits without rework"],
      ["Colour count 6 and 1,800 nodes, nothing dominant", "Route not determined"]
    ],
    "tonal_structure" => [
      ["Ramp length 41 steps, 4 inks, hue drift 0.4", "Preserved"],
      ["Banding visible at 2 steps per inch", "Banded"],
      ["Tone collapsed into 2 inks, no midtones", "Collapsed"],
      ["Ramp length 4 steps, mostly posterised", "Binary"],
      ["No tonal variation to measure", "Flat"]
    ],
    "evidence_is_actionable" => [
      ["COLOR_COUNT: 7 colours, 6 allowed, L2", "Yes — the rule and the layer are named"],
      ["Tonal collapse, 2 inks, no gradient path", "Yes — the fix is bounded"],
      ["PEAK_OPACITY: 0.41 at L1, below 0.6", "Yes — the threshold is stated"],
      ["Artwork lost during prep; no source raster", "No — required input missing"]
    ]
  }.freeze

  # The help behind each "?" on the Jev page. Everything here is transcribed
  # from the annotator, not written around it: `project_manifest` in
  # chopshop-jev/scripts/jev_annotate.py decides what Jev is allowed to see,
  # `compose_verdict` decides what the answers are allowed to conclude, and
  # `_answer_confidence` decides which answers the floor applies to. The page
  # was showing example Q/A pairs with no account of the state behind them,
  # which left the questions looking like opinions.
  HELP = {
    "reads" => [
      ["passed", "Whether the preflight passed outright. Not the point of asking, but it is in the state."],
      ["input", "kind, and the file and spec paths shortened to their basenames."],
      ["summary", "hard, advisory, by_layer, print_method, gradient_handling, require_cmyk, tac_exact."],
      ["findings", "Each one reduced to rule/code, severity, layer, value, actual, limit, expected, and a scrubbed detail string."],
      ["stats", "About forty decision-useful scalars: dpi, proof_pixels, the rendered colour and screen counts, white-screen handling, continuous tone, ramp and diffuse coverage, ink TAC, PDF pages and colour spaces, and render_error/pdf_error."],
      ["notes", "Scrubbed and bounded."]
    ],
    "never_sends" => [
      "The full manifest is never transmitted. Only the projection above goes out.",
      "Colour lists are dropped and reduced to their counts -- the counts are what a decision turns on.",
      "Every finding's path is shortened to its basename, and free text is scrubbed and length-capped."
    ],
    "returns" => [
      ["answer", "One object per question, matching the type it was asked as."],
      ["verdict.headline", "The failure_mode choice, verbatim."],
      ["verdict.print_route", "The print_route choice, verbatim."],
      ["verdict.tonal_score · tonal_label", "The rounded tonal score and its nearest described level, folded into the print-ready candidates."],
      ["verdict.evidence_actionable", "True when the noul's P(true) reaches 0.5."],
      ["verdict.low_confidence", "Every question whose confidence falls under the floor -- listed, not dropped and not blocking."],
      ["sidecar", "Written next to the manifest as <name>.jev.json: the state it read, the questions it was asked, the answers, the verdict, and token usage."]
    ],
    "limit" => [
      "Jev never overrides a deterministic gate. A verdict can only call a candidate print-ready when the hard findings already allow it.",
      "The floor is a warning, not a filter: a low-confidence answer is surfaced in low_confidence rather than being dropped, and it does not veto the others."
    ]
  }.freeze

  # Which projected fields each question actually leans on. Without this the
  # four cards look like four unrelated opinions; with it they read as four
  # reads of the same evidence.
  READS = {
    "failure_mode" => %w[passed summary.hard summary.advisory summary.by_layer
                         stats.rendered_distinct_colors stats.rendered_significant_colors
                         stats.rendered_ink_colors stats.rendered_screens
                         stats.rendered_continuous_tone stats.rendered_ramp_colors
                         findings[].rule findings[].severity findings[].actual
                         findings[].limit stats.render_error stats.pdf_error],
    "print_route" => %w[summary.print_method summary.gradient_handling
                        summary.require_cmyk summary.tac_exact
                        stats.rendered_screens stats.rendered_distinct_colors
                        stats.rendered_ink_colors stats.ink_tac_max_percent
                        stats.ink_tac_area_over_limit_percent
                        stats.pdf_color_spaces stats.pdf_pages],
    "tonal_structure" => %w[stats.rendered_significant_colors stats.rendered_ramp_colors
                            stats.rendered_largest_ramp_percent stats.rendered_diffuse_tone
                            stats.rendered_diffuse_colors stats.rendered_diffuse_area_percent
                            stats.rendered_continuous_tone stats.rendered_blends_absorbed
                            stats.rendered_white_screen],
    "evidence_is_actionable" => %w[stats.dpi stats.proof_pixels stats.pdf_pages
                                   stats.pdf_color_spaces stats.pdf_images.count
                                   stats.pdf_fonts.count stats.pdf_fonts.embedded
                                   stats.render_error stats.pdf_error notes[]],
    "__floor" => %w[verdict.low_confidence confidence_floor],
    "__metrics" => %w[stats.rendered_distinct_colors stats.rendered_significant_colors
                      stats.rendered_ink_colors stats.rendered_screens
                      stats.rendered_diffuse_area_percent stats.ink_tac_max_percent
                      stats.ink_tac_area_over_limit_percent summary.print_method
                      summary.gradient_handling summary.require_cmyk
                      stats.pdf_color_spaces]
  }.freeze

  # How each type's answer comes back. The floor is type-aware, which is not
  # obvious and is the single easiest thing to get wrong when reading the
  # sidecar: a score answer always reports confidence 0.0, so the floor would
  # flag every one of them.
  RETURN_TYPE = {
    "choice" => "Reports a confidence, and the floor applies to it. Its value is the chosen key.",
    "score" => "Reports confidence 0.0, which is not a certainty at all, so the floor is applied to the highest value in its probabilities distribution instead. Read the distribution, not the 0.0.",
    "noul" => "Carries no confidence field. Its value is P(true), and the floor is applied to the distance from a coin-flip: 0.5 scores 0, 0 or 1 scores 1."
  }.freeze

  # remediation_table.json lives in the Jev repo, not here -- it is read by
  # jev_remediate.py at remediation time, not by the annotator. The page only
  # shows it, so the path is resolved relative to this checkout and a missing
  # file degrades to a message rather than a 500.
  REMEDIATION_PATH = Rails.root.parent.join("chopshop-jev/scripts/remediation_table.json")

  # The help for the remediation popup, transcribed from the table's OWN notes
  # keys rather than paraphrased, so it cannot drift from the file it explains.
  def self.remediation_help
    data = remediation
    return [["file", "unreadable at #{REMEDIATION_PATH.relative_path_from(Rails.root)}"]] unless data

    rows = []
    %w[_comment _grounding_note _metrics_note _metrics_source_note].each do |k|
      rows << [k.delete_prefix("_").tr("_", " "), data[k]] if data[k]
    end
    rows << ["remedies", "#{data['remedies'].size} entries. Each is a table lookup on a " \
                        "failure_mode plus bounded arithmetic -- no model output ever " \
                        "becomes a parameter value."]
    rows << ["entry keys", data["remedies"].first.keys.join(", ")] if data["remedies"].first
    rows
  end

  def self.remediation
    return @remediation if defined?(@remediation)
    @remediation = REMEDIATION_PATH.exist? ? JSON.parse(REMEDIATION_PATH.read) : nil
  rescue JSON::ParserError
    @remediation = nil
  end

  def self.remediation_json
    return "" unless REMEDIATION_PATH.exist?
    REMEDIATION_PATH.read
  end

  def self.default_json
    JSON.pretty_generate(DEFAULT)
  end

  # Parse an edited conf. Returns [hash_or_nil, error_or_nil] so the view can
  # show the failure beside the box instead of silently falling back -- a
  # silently-rejected edit is how you end up running something you did not write.
  def self.parse(text)
    parsed = JSON.parse(text.to_s)
    return [nil, "the conf must be a JSON object"] unless parsed.is_a?(Hash)
    return [nil, "the conf needs a \"questions\" object"] unless parsed["questions"].is_a?(Hash)
    if parsed["questions"].empty?
      return [nil, "\"questions\" cannot be empty -- Jev would be asked nothing"]
    end
    [parsed, nil]
  rescue JSON::ParserError => e
    [nil, "invalid JSON: #{e.message.lines.first.to_s.strip}"]
  end
end
