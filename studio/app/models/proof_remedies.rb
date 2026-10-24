# The studio-side remedy table, keyed by RULE ID (#44).
#
# WHY THIS EXISTS. A finding on the proof page named a rule and a detail, and
# nothing said what to CHANGE. The mapping existed only as prose
# (svg/docs/HOWTO-print-check.md) and as jev/scripts/remediation_table.json — the
# latter keyed by a `failure_mode` name, which is Jev vocabulary that svg/, being
# public, must not carry. So the rule id -> "what to change" table lives here as
# DATA, mirrored in the FluxConf discipline: nothing at runtime reads jev/ (see
# test/models/proof_remedies_test.rb for the structural pin).
#
# THE CONSTRAINT ON THE VOCABULARY, stated once because it is the sharpest
# requirement: entries are addressed in RULE IDS and SPEC KEYS ONLY. A
# `failure_mode` name never appears here, and no entry is written in terms of
# Jev's question set. The Ask Jev button on the same page stays exactly where it
# is — separate, and advisory. This table answers "what would change this
# finding", which is a deterministic, operator-facing answer, not an opinion.
#
# ENTRY SHAPE
#   rule         the finding's `rule` field, exactly as validate_svg.py /
#                preflight.py spell it (the test parses those sources).
#   meaning      plain language: what the check measured, in one sentence.
#   severity     "hard" | "advisory" | "conditional" — the DEFAULT reading of the
#                rule. "conditional" is used where preflight.py's classify()
#                makes the severity depend on the run's own spec (see below), so
#                the page never claims a hard gate that this run treated as
#                advisory.
#   change       what to change: { kind:, ... } where kind is
#                  :spec_key  -> { kind:, key:, to: }     a contract key + value
#                  :script    -> { kind:, script:, args: } a deterministic tool
#                  :template  -> { kind:, template:, label: }
#                  :artwork   -> { kind:, action: }       an edit to the artwork
#                  :route     -> { kind:, action: }       a print-route decision
#                nil is an EXPLICIT "no suggestion" — the acceptance criterion
#                allows it, and ProofRemedies.covered? counts it as covered. An
#                entry that is simply ABSENT is not covered.
#   link         the section of svg/docs/HOWTO-print-check.md this entry is
#                grounded in, as a fragment.
#
# SEVERITY, and why it is not one flat list: the manifest's own `severity` field
# is authoritative for the finding in front of you. This table's `severity` is
# what the rule MEANS in general, and where the pipeline makes that depend on the
# run's spec the entry says "conditional" and names the key — see INK_COVERAGE,
# FONT_EMBED and CONTINUOUS_TONE.
class ProofRemedies
  # preflight.py's LAYER_A_RULES, mirrored. The pipeline decides the `layer`
  # field of a finding; this list is what ProofRemedies.layer_of reads, so a rule
  # reclassified in the pipeline and not here is a page that mislabels a finding.
  LAYER_A = %w[
    RASTER_EMBED COLOR_COUNT MIN_STROKE_WIDTH ZERO_AREA_PATH OPEN_PATH
    SVG_PARSE_ERROR PATH_PARSE_ERROR NODE_COUNT PALETTE DIMENSIONS
    GRADIENT_NOT_ALLOWED SPEC_ERROR INPUT_ERROR
  ].freeze

  # The advisory-by-default rules: preflight.py's _ALWAYS_ADVISORY (NODE_COUNT,
  # PALETTE) plus the three advisory TAGS (EFFECT_REFERENCE, TRANSLUCENT_PAINT,
  # UNCHECKED_DEFINITION), which the pipeline writes to `notes` rather than to
  # `failings` precisely so they can never fail a job.
  ADVISORY_BY_DEFAULT = %w[
    NODE_COUNT PALETTE EFFECT_REFERENCE TRANSLUCENT_PAINT UNCHECKED_DEFINITION
  ].freeze

  ENTRIES = {
    # ------------------------------------------------------------ Layer A
    "COLOR_COUNT" => {
      meaning: "The file declares more colours than the contract's budget. The count is of DECLARATIONS, not of pixels: a shape whose cascade never sets fill is painted black and counts, and a colour a later rule overrides still occupies a slot.",
      severity: "hard",
      change: { kind: :script, script: "snap_colors.py",
                args: "--force (cheapest: no retrace, geometry preserved byte-identically)" },
      link: "what-it-checks-and-why-it-matters"
    },
    "COLOR_COUNT_RENDERED" => {
      meaning: "The rendered artwork needs more distinct inks than the budget. Two written colours can render as hundreds: a two-stop gradient is 2 in the file and one ink per step once rasterised.",
      severity: "hard",
      change: { kind: :script, script: "snap_colors.py",
                args: "--force, then --tolerance if colours remain off palette" },
      link: "what-it-checks-and-why-it-matters"
    },
    "MIN_STROKE_WIDTH" => {
      meaning: "A stroke thinner than the contract's minimum. It renders as an ordinary line, so only the source check sees that it will break up on press.",
      severity: "hard",
      change: { kind: :spec_key, key: "geometry.min_stroke_width_pt",
                to: "raise it to a printable width, or lower the limit to match the artwork" },
      link: "hard-gates-vs-advisories"
    },
    "ZERO_AREA_PATH" => {
      meaning: "A path encloses no area — a degenerate shape that prints nothing but still occupies a slot in the file.",
      severity: "hard",
      change: { kind: :artwork, action: "delete the zero-area shape, or give it real geometry" },
      link: "what-it-checks-and-why-it-matters"
    },
    "OPEN_PATH" => {
      meaning: "A path left open on a cutting job. A plotter follows the path and a cut that does not close leaves the shape uncut.",
      severity: "hard",
      change: { kind: :spec_key, key: "geometry.allow_open_paths",
                to: "true, if open paths are wanted for this job — otherwise close the path in the artwork" },
      link: "hard-gates-vs-advisories"
    },
    "SVG_PARSE_ERROR" => {
      meaning: "The file is not well-formed XML, so it cannot be read at all. Nothing downstream of the parse can be trusted.",
      severity: "hard",
      change: { kind: :artwork, action: "fix the malformed XML — re-export from the editor" },
      link: "what-it-checks-and-why-it-matters"
    },
    "PATH_PARSE_ERROR" => {
      meaning: "A path's `d` data could not be parsed. The shape is in the file but unreadable, so its colour and stroke were never checked.",
      severity: "hard",
      change: { kind: :artwork, action: "re-draw or re-export the offending path" },
      link: "what-it-checks-and-why-it-matters"
    },
    "SPEC_ERROR" => {
      meaning: "The job contract itself is invalid — a missing key, a wrong type, or a negative limit. The artwork was never evaluated against a legal spec.",
      severity: "hard",
      change: { kind: :spec_key, key: "spec (the whole contract)",
                to: "fix the offending key in the job's spec.json; the finding's detail names which" },
      link: "hard-gates-vs-advisories"
    },
    "INPUT_ERROR" => {
      meaning: "The file the run was asked to check is not where the spec says it is. No check ran.",
      severity: "hard",
      change: { kind: :spec_key, key: "spec / the candidate path",
                to: "point the run at a file that exists" },
      link: "hard-gates-vs-advisories"
    },
    "DIMENSIONS" => {
      meaning: "The artwork is not the physical size the contract asked for.",
      severity: "hard",
      change: { kind: :spec_key, key: "dimensions",
                to: "set the artwork's real size in the contract, or resize the artwork to match" },
      link: "hard-gates-vs-advisories"
    },
    "RASTER_EMBED" => {
      meaning: "A bitmap is reaching the artwork — an <image>, an <feImage>, a <foreignObject>, a reference to another document, or a raster paint server. Vectors are required here.",
      severity: "hard",
      change: { kind: :spec_key, key: "geometry.allow_raster_embed",
                to: "true, if a raster is genuinely wanted — otherwise trace the bitmap to vectors" },
      link: "hard-gates-vs-advisories"
    },
    "GRADIENT_NOT_ALLOWED" => {
      meaning: "The spec disallows gradients and the source declares one — a <linearGradient>/<radialGradient> or any url(#…) paint reference — so the file is refused before anything is rendered.",
      severity: "hard",
      change: { kind: :spec_key, key: "geometry.allow_gradients",
                to: "true for a process/halftone route — otherwise flatten the gradient to flat spot colour" },
      link: "the-two-gates"
    },
    "PALETTE" => {
      meaning: "A declared colour is outside the contract's palette. Reported, not failed: a stray colour may be deliberate.",
      severity: "advisory",
      change: { kind: :script, script: "snap_colors.py",
                args: "--tolerance (tightens the snap so near-misses stop being left unmatched)" },
      link: "hard-gates-vs-advisories"
    },
    "NODE_COUNT" => {
      meaning: "A path carries more nodes than the per-path limit. It makes the file slow to RIP and hard to hand-edit — a production-quality finding, not a printability one.",
      severity: "advisory",
      change: { kind: :script, script: "node_reduce.py",
                args: "--dry-run/--json first; it escalates its own tolerance and self-reports gate_cleared" },
      link: "what-it-checks-and-why-it-matters"
    },
    "EFFECT_REFERENCE" => {
      meaning: "The artwork references a filter, mask or clip-path. Layer A cannot measure what a blur or a flood does to the ink, so it is reported rather than failed.",
      severity: "advisory",
      change: { kind: :artwork, action: "flatten the effect into explicit geometry, or accept that the render is the only truth for it" },
      link: "hard-gates-vs-advisories"
    },
    "TRANSLUCENT_PAINT" => {
      meaning: "A paint with opacity between 0 and 1. A spot screen prints a tint of the same ink, so the rendered count may see two tints as two inks.",
      severity: "advisory",
      change: { kind: :artwork, action: "make the paint fully opaque, or accept the ink count as the render's own" },
      link: "hard-gates-vs-advisories"
    },
    "UNCHECKED_DEFINITION" => {
      meaning: "Shape elements inside <defs>/<symbol>/<pattern> that nothing references were not stroke- or colour-checked, so coverage of this file is partial.",
      severity: "advisory",
      change: { kind: :artwork, action: "reference the definition, or delete the unreferenced content" },
      link: "hard-gates-vs-advisories"
    },
    "STROKE_SCALE_TRANSFORM" => {
      meaning: "A stroke is painted through a transform, so its on-sheet width is the declared width multiplied by that transform. Layer A cannot resolve it.",
      severity: "advisory",
      change: { kind: :artwork, action: "set the stroke width on the element itself rather than inheriting it through a scale" },
      link: "what-it-checks-and-why-it-matters"
    },

    # ------------------------------------------------------------ Layer B
    "CONTINUOUS_TONE" => {
      meaning: "The render contains a smooth tonal ramp or photograph. Flat spot inks cannot reproduce it; it needs halftone screening, which means process printing.",
      severity: "conditional",
      change: { kind: :spec_key, key: "geometry.gradient_handling",
                to: "embedded_raster, where smooth tone is expected — otherwise it is a print-route decision, not a parameter one" },
      link: "what-it-checks-and-why-it-matters"
    },
    "INK_COVERAGE" => {
      meaning: "Total ink coverage on the darkest part of the sheet is over the limit. Above it the ink does not dry and sheets stick together.",
      severity: "conditional",
      change: { kind: :spec_key, key: "ink_limit_percent",
                to: "raise it only with a printer's agreement — and note the reading is exact only for genuinely CMYK input" },
      link: "what-it-checks-and-why-it-matters"
    },
    "IMAGE_RESOLUTION" => {
      meaning: "A placed bitmap is below the resolution floor, so it will print visibly soft.",
      severity: "hard",
      change: { kind: :artwork, action: "re-place the bitmap at a higher resolution, or raise spec.print.min_image_ppi to accept it" },
      link: "what-it-checks-and-why-it-matters"
    },
    "FONT_EMBED" => {
      meaning: "A font is not embedded, so the printer substitutes it and the layout shifts.",
      severity: "conditional",
      change: { kind: :spec_key, key: "print.require_embedded_fonts",
                to: "true to make it a gate — otherwise convert the text to outlines" },
      link: "what-it-checks-and-why-it-matters"
    },
    "CMYK_REQUIRED" => {
      meaning: "The contract demands CMYK and the output is not.",
      severity: "hard",
      change: { kind: :spec_key, key: "require_cmyk",
                to: "false, or supply a genuinely CMYK document" },
      link: "hard-gates-vs-advisories"
    },
    "RENDER_ERROR" => {
      meaning: "The artwork could not be rasterised — no proof PNG was produced. A missing or failing tool is an environment fault, not an artwork fault.",
      severity: "hard",
      change: { kind: :script, script: "(environment)",
                args: "check the toolchain (inkscape/gs/qpdf/poppler); retracing cannot fix it" },
      link: "the-honest-caveats"
    },
    "PDF_ERROR" => {
      meaning: "The print PDF could not be exported. As with RENDER_ERROR, this is a toolchain fault.",
      severity: "hard",
      change: { kind: :script, script: "(environment)",
                args: "check Inkscape and the PDF toolchain; retracing cannot fix it" },
      link: "the-honest-caveats"
    },
    "MISSING_TOOL" => {
      meaning: "A tool the check needs is not installed. The finding names which one.",
      severity: "hard",
      change: { kind: :script, script: "(environment)",
                args: "install the missing tool named in the finding's detail" },
      link: "the-honest-caveats"
    }
  }.freeze

  # The print check's own documentation, where each entry's `link` fragment is
  # grounded. The doc is PUBLIC (the chopshop monorepo is public; only the studio
  # and jev halves are private), so a remedy can link straight at the section it
  # is grounded in rather than the studio holding a second copy to drift.
  #
  # The fragment is the GitHub-style anchor of the doc's own `##` heading, so the
  # link lands on the section and not at the top of the page.
  PRINT_CHECK_DOC = "https://github.com/geeeze/chopshop/blob/main/svg/docs/HOWTO-print-check.md".freeze

  class << self
    # The entry for a rule, or nil. nil means ABSENT — not the same as an entry
    # whose `change` is nil, which is an explicit "no suggestion".
    def entry_for(rule)
      ENTRIES[rule.to_s]
    end

    def covered?(rule)
      entry_for(rule).present?
    end

    # The finding's layer, read from the mirrored list: the pipeline decides the
    # `layer` field of a finding, and a rule not in LAYER_A is Layer B.
    def layer_of(rule)
      LAYER_A.include?(rule.to_s) ? "source_validation" : "render_preflight"
    end

    # The rule's severity in general — the manifest's own `severity` field is
    # authoritative for the finding in front of you. "conditional" is where
    # preflight.py's classify() makes it depend on the run's spec.
    def severity_of(rule)
      entry_for(rule)&.dig(:severity) || "hard"
    end

    # The suggested change for a rule, or nil for an explicit "no suggestion".
    def change_for(rule)
      entry_for(rule)&.dig(:change)
    end

    # The absolute URL of the section an entry is grounded in. nil when the
    # entry names no section, so a view can omit the link rather than emit a
    # bare one.
    def doc_url_for(rule)
      entry = entry_for(rule)
      return nil if entry.nil? || entry[:link].blank?

      "#{PRINT_CHECK_DOC}##{entry[:link]}"
    end

    def keys
      ENTRIES.keys
    end

    def size
      ENTRIES.size
    end
  end
end
