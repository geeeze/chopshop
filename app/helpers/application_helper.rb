module ApplicationHelper
  # Render one Jev answer into the three fields the card needs.
  #
  # A live Jev response is TYPED, and the three types carry their certainty in
  # different places (verified against api.typesafe.ai, model jev-1.13.0):
  #
  #   choice -> { choice:, confidence: }              confidence is real
  #   score  -> { score:, probabilities:, legend: }   confidence is reported 0.0
  #   noul   -> { noul: 0.1 }                         P(true); no confidence field
  #
  # Reading `ans["choice"]` for all of them (what the view did) renders two of
  # the four cards blank, and reading `ans["confidence"]` prints "confidence 0%"
  # on a score answer, because Ruby treats 0.0 as truthy.
  def jev_answer_view(ans)
    return { value: ans.to_s, note: nil, confidence: nil } unless ans.is_a?(Hash)

    case ans["type"]
    when "score"
      score = ans["score"]
      # Mirror the annotator's `_fraction_label`: a fractional score maps onto
      # the NEAREST described level (0.35 -> level 0), not the exact key, so the
      # label matches the verdict Jev itself folded.
      level = score.is_a?(Numeric) ? score.round.to_s : score.to_s
      legend = ans["legend"].is_a?(Hash) ? ans["legend"][level] : nil
      { value: jev_words(score), note: legend, confidence: jev_max_probability(ans) }
    when "noul"
      p_true = ans["noul"]
      { value: "P(true) #{percent(p_true)}",
        note: jev_noul_note(p_true),
        confidence: jev_noul_confidence(p_true) }
    else # "choice", and older answers that predate the type field
      confidence = ans["confidence"]
      { value: jev_words(ans["choice"]),
        note: nil,
        confidence: confidence.is_a?(Numeric) && confidence.positive? ? confidence : nil }
    end
  end

  def jev_words(value)
    value.to_s.tr("_", " ")
  end

  # The proof's short name: candidate_06.svg -> proof_06 (no extension).
  # Everything the proof-detail popup shows, pulled off a Validation in one
  # place. It used to be seven locals reassembled inside a loop on the job
  # results page; the Jobs LIST needs the same popup, and re-deriving it there
  # would be a second copy to drift.
  def proof_detail(v)
    manifest = v.manifest.is_a?(Hash) ? v.manifest : {}
    stats = manifest["stats"] || {}
    findings = Array(manifest["findings"])
    hard = findings.count { |f| f["severity"] == "hard" }
    {
      validation: v,
      manifest: manifest,
      summary: manifest["summary"] || {},
      stats: stats,
      statics: stats["static"] || {},
      findings: findings,
      cleared: hard.zero? ? cleared_checks(manifest) : { cleared: [], skipped: [] },
      png: manifest["proof"].presence,
      pdf: manifest["print_pdf"].presence
    }
  end

  # The proof a job's list row should link to: the most recent FINISHED one.
  # A job that has not been picked through to a proof yet falls back to the job
  # itself, so the thumbnail and the name are never dead.
  def job_proof_path(job)
    proof = job.validations.select { |v| v.state == "done" }.last ||
            job.validations.last
    proof ? validation_path(proof) : job_path(job)
  end

  def proof_label(file)
    proof_name(file).sub(/\.[^.]+\z/, "")
  end

  # A proof's name follows the candidate it was made
  # from: candidate_06.svg -> proof_06.svg. A proof is identified by the sweep
  # slot it came from -- never by a database id and never by a score.
  def proof_name(file)
    file.to_s.sub(/\Acandidate_/, "proof_")
  end

  # The deterministic gates, stated POSITIVELY when they clear.
  #
  # The manifest only records failures, so a proof with nothing wrong rendered as
  # an empty Findings card -- which reads as "nothing was checked". Every
  # statement below is anchored on a measurement the pipeline actually wrote
  # into the manifest for THIS run, and is suppressed the moment its rule fires,
  # so a gate that failed (or never ran) is never reported as cleared.
  #
  # Returns { cleared: [{area:, label:, detail:}], skipped: [String] }. The
  # skipped list matters just as much: an unchecked gate must not be read as a
  # cleared one.
  def cleared_checks(manifest)
    stats = manifest["stats"].is_a?(Hash) ? manifest["stats"] : {}
    static = stats["static"].is_a?(Hash) ? stats["static"] : {}
    fired = Array(manifest["findings"]).map { |f| f["rule"].to_s }
    cleared = []
    skipped = []

    # --- Layer A: source validation ------------------------------------------
    if static.any?
      cleared << cleared_entry("source", "Colour budget",
                       "#{pluralize(static['color_count'], 'declared colour')} — within the job's max_colors") if static["color_count"].present? && !fired.include?("COLOR_COUNT")

      cleared << cleared_entry("source", "Palette", "every declared colour is on the spec palette") if static["palette_conformance"] == "all colours on palette"

      if static["paths"].present? && static["paths_over_node_limit"].to_i.zero?
        detail = "worst path #{static['path_nodes_max']} nodes"
        detail += ", #{static['path_nodes_total']} across #{pluralize(static['paths'], 'path')}" if static["path_nodes_total"].present?
        cleared << cleared_entry("source", "Node budget", "#{detail} — none over the per-path limit")
      end

      cleared << cleared_entry("source", "Hairlines", "no stroke under the job's minimum stroke width") unless fired.include?("MIN_STROKE_WIDTH")

      if static["stroke_scale_advisories"].present? && static["stroke_scale_advisories"].to_i.zero?
        cleared << cleared_entry("source", "Stroke scaling",
                         "no scaled strokes; 1 user unit = #{static['mm_per_user_unit']} mm")
      end

      unless fired.include?("ZERO_AREA_PATH") || fired.include?("PATH_PARSE_ERROR") || fired.include?("SVG_PARSE_ERROR")
        cleared << cleared_entry("source", "Path integrity", "every path parsed, no zero-area shapes")
      end

      cleared << cleared_entry("source", "Raster embeds", "vectors only — nothing rasterised into the artwork") unless fired.include?("RASTER_EMBED")

      skipped << "the size gate (#{static['size_check']})" if static["size_check"].to_s.start_with?("skipped")
    end

    # --- Layer B: rendered preflight -----------------------------------------
    if stats["rendered_ink_colors"].present?
      unless fired.include?("CONTINUOUS_TONE") || fired.include?("RENDERED_COLORS")
        if stats["rendered_ramp_colors"].to_i.zero? && stats["rendered_largest_ramp_percent"].to_f.zero?
          cleared << cleared_entry("render", "Gradients", "flat inks only — no tonal ramp in the render")
        end
      end

      if stats["rendered_continuous_tone"] == false && stats["rendered_diffuse_tone"] == false
        cleared << cleared_entry("render", "Tone",
                         "no continuous or diffuse tone — coverage is flat ink")
      end

      if stats["rendered_blends_absorbed"].to_i.zero?
        cleared << cleared_entry("render", "Screens",
                         "#{pluralize(stats['rendered_ink_colors'], 'rendered ink')} across " \
                         "#{pluralize(stats['rendered_screens'], 'screen')}, none absorbed by the blend tolerance")
      end

      if stats["ink_tac_max_percent"].present? && stats["ink_tac_limit_percent"].present? &&
         stats["ink_tac_max_percent"].to_f < stats["ink_tac_limit_percent"].to_f
        detail = "peak #{tidy_number(stats['ink_tac_max_percent'])}% against the #{tidy_number(stats['ink_tac_limit_percent'])}% limit"
        detail += " (an estimate — the PDF is RGB; see the manifest notes)" if stats["tac_is_estimate"]
        cleared << cleared_entry("render", "Ink coverage", detail)
      end

      if stats["pdf_pages"].to_i == 1 && Array(stats["pdf_fonts"]).empty? && Array(stats["pdf_images"]).empty?
        cleared << cleared_entry("render", "Print PDF",
                         "1 page at #{stats['pdf_page_size']}, no fonts to substitute, no raster images")
      end
    end

    { cleared: cleared, skipped: skipped }
  end

  def percent(value)
    return "–" unless value.is_a?(Numeric)

    "#{(value * 100).round}%"
  end

  # ------------------------------------------------- the check-engine light
  # #engine-light-metrics
  #
  # The owner's RECORDED learning signal, for the footer orb and the telemetry
  # popup it opens. One read, memoized: the layout renders on EVERY authed page,
  # so without the memo a footer control would cost a COUNT per kind per page.
  #
  # Every number is OWNER-SCOPED, three ways: Event, Job and ScrapbookItem carry
  # Owned's default_scope (which reads Current.user_handle, stamped by the
  # controller's before_action), and the candidate count goes through the
  # owner-scoped Job relation as a subquery -- candidates have no owner column of
  # their own, they belong to a job, so scoping them any other way would report
  # another operator's rows.
  #
  # The kinds come from Event::KINDS and the per-kind counts from the
  # Event.of_kind scope, so a new kind cannot be added to the log without
  # appearing here.
  def engine_light_metrics
    @engine_light_metrics ||= Telemetry.metrics
  end

  # Amber until a human has recorded something: before the first star, pick or
  # delete there is nothing for the ranker to learn from, and that is exactly
  # what the light reports. Green the moment one event exists.
  def engine_light_cold?
    engine_light_metrics[:events].zero?
  end

  # One configuration body from Telemetry::CONFIG as markup. The string is
  # ESCAPED FIRST and only then are its <mono>…</mono> markers swapped for the
  # app's .mono span -- so the table can read like a config file with its values
  # marked, and a value still cannot inject markup of its own.
  def telemetry_body(text)
    ERB::Util.html_escape(text)
               .gsub("&lt;mono&gt;", '<span class="mono">')
               .gsub("&lt;/mono&gt;", "</span>")
               .html_safe
  end

  # The state as words, for the orb's title/aria-label (the orb itself carries
  # no text -- it is an icon, not a word button).
  def engine_light_state
    return "no training signal yet" if engine_light_cold?

    "learning signal: #{engine_light_metrics[:events]} recorded"
  end

  # HSL -> #rrggbb, for the colour map on the JSON page.
  #
  # The map's cells must carry REAL hex, not `hsl(...)` strings: the builder's
  # HEX_RE is /^#[0-9a-fA-F]{6}$/ and rejects anything else, so an hsl() cell
  # would be refused by addColour() with "not a #rrggbb colour". Converting here
  # also means the title tooltips show the hex the user will actually get.
  #
  # h in 0..360, s and l in 0..100 (percentages, not fractions).
  def hsl_hex(h, s, l)
    h = h.to_f % 360
    s = s.to_f.clamp(0, 100) / 100.0
    l = l.to_f.clamp(0, 100) / 100.0
    c = (1 - (2 * l - 1).abs) * s
    hp = h / 60.0
    x = c * (1 - ((hp % 2) - 1).abs)
    rgb = case hp
          when 0...1 then [c, x, 0]
          when 1...2 then [x, c, 0]
          when 2...3 then [0, c, x]
          when 3...4 then [0, x, c]
          when 4...5 then [x, 0, c]
          else [c, 0, x]
          end
    m = l - c / 2.0
    format("#%02x%02x%02x", *rgb.map { |v| ((v + m) * 255).round.clamp(0, 255) })
  end

  private

  # One cleared-gate row. `area` is the pipeline layer it came from, in the same
  # words the findings rows use.
  # 300.0 -> "300"; keep a real fraction at one decimal.
  def tidy_number(value)
    f = value.to_f
    f == f.round ? f.round.to_s : format("%.1f", f)
  end

  def cleared_entry(area, label, detail) # :nodoc:
    { area: area, label: label, detail: detail }
  end

  def jev_max_probability(ans)
    probabilities = ans["probabilities"]
    return nil unless probabilities.is_a?(Hash) && probabilities.any?

    probabilities.values.map { |v| v.is_a?(Numeric) ? v : 0 }.max
  end

  # Certainty for a noul answer is distance from a coin flip: 0.5 -> 0, 0/1 -> 1.
  def jev_noul_confidence(value)
    return nil unless value.is_a?(Numeric)

    2 * (value - 0.5).abs
  end

  def jev_noul_note(value)
    return nil unless value.is_a?(Numeric)

    case value
    when 0.0..0.35 then "the measurements are not enough on their own"
    when 0.35..0.65 then "the measurements are borderline"
    else "the measurements support a production call"
    end
  end

end
