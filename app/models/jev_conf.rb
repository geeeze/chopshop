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
