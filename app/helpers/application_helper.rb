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
      cleared: hard.zero? ? cleared_checks(manifest, spec: v.job&.spec) : { cleared: [], skipped: [] },
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

  # A proof's name follows the candidate it was made from: candidate_06.svg ->
  # proof_06.svg, and a job-named artifact follows its own name:
  # <job>-candidate-06.svg -> <job>-proof-06.svg. A proof is identified by the
  # sweep slot it came from -- never by a database id and never by a score.
  def proof_name(file)
    file.to_s.sub(/\Acandidate_/, "proof_").sub(/-candidate-/, "-proof-")
  end

  # The deterministic gates, stated POSITIVELY when they clear.
  #
  # The manifest only records failures, so a proof with nothing wrong rendered as
  # an empty Findings card -- which reads as "nothing was checked". Every
  # statement below is anchored on a measurement the pipeline actually wrote
  # into the manifest for THIS run, and is suppressed the moment its rule fires,
  # so a gate that failed (or never ran) is never reported as cleared.
  #
  # A gate can also be DISARMED by the run's own spec, and that is the subtler
  # half of the same rule: with `geometry.allow_gradients: true` the pipeline
  # returns before it looks for a gradient, and with
  # `geometry.allow_raster_embed: true` it skips the raster scan entirely, so
  # the absence of those findings means "never asked", not "asked and passed".
  # The two gates below are therefore conditional on the flag the RUN carried
  # (see run_gate_flags), and a disarmed or unsettleable one is reported as NOT
  # cleared rather than as a pass.
  #
  # `spec` is the run's own job spec where the caller has it. Optional because a
  # manifest alone still settles everything the manifest records -- but pass it,
  # or a gate whose flag the pipeline does not echo reads as unknown.
  #
  # Returns { cleared: [{area:, label:, detail:}], skipped: [String] }. The
  # skipped list matters just as much: an unchecked gate must not be read as a
  # cleared one.
  def cleared_checks(manifest, spec: nil)
    stats = manifest["stats"].is_a?(Hash) ? manifest["stats"] : {}
    static = stats["static"].is_a?(Hash) ? stats["static"] : {}
    flags = run_gate_flags(static, spec)
    fired = Array(manifest["findings"]).map { |f| f["rule"].to_s }
    # Advisory tags do NOT arrive as findings. The pipeline writes them into the
    # manifest's `notes` as "<RULE_ID>: detail" strings, precisely so that they
    # can never fail a job -- so `fired` alone would never see one, and an
    # advisory would be silently dropped instead of reported as unmeasured.
    # Both vectors are read: whichever one carries it, an advisory is not a
    # clearance.
    advisories = (fired + Array(manifest["notes"]).map(&:to_s)).join("\n")
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

      # RASTER_EMBED and GRADIENT_NOT_ALLOWED are the two Layer A gates the run's
      # OWN spec can disarm, so both are stated below against the flag the run
      # carried rather than against the absence of a finding.

      # GRADIENT_NOT_ALLOWED is a HARD gate: with allow_gradients off Layer A
      # refuses a source that declares a gradient or paints through a url(#…)
      # paint server. Before it existed this was only caught by Layer B's
      # rendered ink count, so a gradient-bearing file could read as clean at
      # source level.
      #
      # With allow_gradients ON the check returns before it checks anything, so
      # an absent finding is not a clearance -- it is a question nobody asked.
      # The run's own record settles it (validate_svg.py writes both the flag
      # and the counts into stats.static, and the counts are written either way,
      # so only the FLAG says whether the gate was armed).
      if flags[:gradients] == true
        skipped << "the flat-colour gate (geometry.allow_gradients is true in " \
                   "this run's spec, so Layer A was not asked to look for " \
                   "gradients or url(#…) paint servers at all)"
      elsif flags[:gradients] == false && !fired.include?("GRADIENT_NOT_ALLOWED")
        cleared << cleared_entry("source", "Gradients", "no gradient declaration and no url(#…) paint server in the source — flat spot colour only")
      elsif flags[:gradients].nil?
        skipped << "the flat-colour gate (neither this run's manifest nor its " \
                   "spec says whether geometry.allow_gradients was off)"
      end

      # Raster embeds, under the same rule: allow_raster_embed true skips
      # check_raster_embeds entirely. The manifest DOES echo this flag —
      # validate_svg.py has written allow_raster_embed into its stats since
      # 982e161 (2026-09-30), and preflight copies it into stats.static — so
      # run_gate_flags settles it from the run's own record first, and only
      # falls back to the spec (with the pipeline's own default: absent means
      # false, i.e. the gate is ON) for a manifest written before the echo.
      if flags[:raster] == true
        skipped << "the raster-embed gate (geometry.allow_raster_embed is true " \
                   "in this run's spec, so Layer A was not asked to check for " \
                   "an embedded bitmap)"
      elsif flags[:raster] == false && !fired.include?("RASTER_EMBED")
        cleared << cleared_entry("source", "Raster embeds", "vectors only — no <image>, no <feImage>, no <foreignObject>, no reference to another document and no raster paint server")
      elsif flags[:raster].nil?
        skipped << "the raster-embed gate (no run spec on hand, and the " \
                   "manifest does not record geometry.allow_raster_embed, so " \
                   "whether the gate was off cannot be settled here)"
      end

      # EVERY advisory tag is a "not checked" statement, never a clearance:
      # each one names something Layer A could not settle, so each is reported
      # as not cleared rather than dropped. The svg side pins these IDs
      # (validate_svg.py: RULE_EFFECT, RULE_TRANSLUCENT, RULE_UNCHECKED); a tag
      # nothing raises simply never appears, and an unknown one is not guessed
      # at.
      {
        "EFFECT_REFERENCE" => "the ink effect of this artwork's filter / mask / " \
                              "clip-path references (EFFECT_REFERENCE — Layer A " \
                              "cannot measure what they do to the ink)",
        "UNCHECKED_DEFINITION" => "any content inside a definition container that " \
                                  "nothing references (UNCHECKED_DEFINITION — the " \
                                  "colour and stroke checks cannot reach it, so " \
                                  "their coverage of this file is partial)",
        "TRANSLUCENT_PAINT" => "a partly transparent paint (TRANSLUCENT_PAINT — a " \
                               "spot screen prints a tint of the same ink, so the " \
                               "ink count may not be flat)"
      }.each do |rule, statement|
        skipped << statement if advisories.include?(rule)
      end

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
    @engine_light_metrics ||= EngineMetrics.metrics
  end

  # Whether the footer's report popup can actually FILE. It lives HERE rather
  # than in BugReportsController because the LAYOUT asks -- every page's footer
  # carries the button, so a helper_method on the one controller would be
  # undefined on all the others and the whole site would 500.
  def bug_reporting_configured?
    GithubIssues.configured?
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

  # Whether each DISARMABLE Layer A gate was ARMED for this run: true means the
  # spec turned the gate off, false means it was on, nil means nothing on hand
  # settles it. See cleared_checks for why a disarm is not a clearance.
  #
  # Two sources, in order of authority:
  #
  #   1. the manifest, because it is this run's own record — validate_svg.py
  #      writes `allow_gradients` into stats.static;
  #   2. the run's spec, which is the document the studio POSTed at create and
  #      the runner re-read for the back half. It is the fallback for a manifest
  #      written before the flag was recorded, and the only source for a flag the
  #      pipeline still does not echo (`geometry.allow_raster_embed`).
  #
  # Both flags default to OFF in the pipeline, so a spec that omits the key
  # resolves to "armed" — which is what makes this a reading rather than a guess.
  def run_gate_flags(static, spec) # :nodoc:
    geometry = spec_geometry(spec)
    from_spec = ->(key) { spec.nil? ? nil : geometry[key] == true }

    # The pipeline's own record wins over the spec: validate_svg.py echoes every
    # geometry.allow_* flag into its stats (982e161, 2026-09-30), and preflight
    # copies those stats into stats["static"] — so a manifest written by the
    # current pipeline settles BOTH gates from the run itself, spec or no spec.
    # Falls back to the spec for a manifest written before the echo existed.
    from_manifest = lambda do |key|
      return static[key] == true if static.key?(key)
      from_spec.call(key)
    end

    { gradients: from_manifest.call("allow_gradients"),
      raster: from_manifest.call("allow_raster_embed") }
  end

  # The geometry blocks a spec carries, merged into one: the top-level
  # `geometry`, plus the `svg` block of every step in a step list — a chained job
  # keeps its tracing spec INSIDE the step, so reading only the top level would
  # answer with the pipeline's defaults for a job that set them.
  #
  # Merged with `true` winning, because the question being asked is "was this
  # gate ever armed off", and one block that allowed gradients or rasters is
  # enough to make a clearance unearned.
  def spec_geometry(spec) # :nodoc:
    return {} unless spec.is_a?(Hash)

    blocks = [spec] + Array(spec["steps"]).select { |s| s.is_a?(Hash) }.map { |s| s["svg"] }
    blocks.filter_map { |block| block.is_a?(Hash) ? block["geometry"] : nil }
          .select { |geometry| geometry.is_a?(Hash) }
          .reduce({}) { |merged, geometry| merged.merge(geometry) { |_key, a, b| a || b } }
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

  # How long one STEP of a chain took, in seconds, or nil when it has not
  # finished. The ledger writes both ends as ISO-8601 (`RunJob#start_step!` /
  # `#finish_step!`); a page that printed them raw made the operator subtract two
  # timestamps by eye to answer "which step is the slow one" — the one question a
  # stepped process exists to answer.
  def step_seconds(entry)
    started = entry["started_at"].to_s.presence
    finished = entry["finished_at"].to_s.presence
    return nil if started.blank? || finished.blank?

    (Time.zone.parse(finished) - Time.zone.parse(started)).round(1)
  rescue ArgumentError, TypeError
    nil
  end

  # One step's state for the process table: what the ledger recorded, or what
  # the chain's own progress implies when it has not reached the step yet — the
  # steps above a running one are done and the ones below are still to come, so a
  # chain in flight reads as a process rather than as a list of blanks.
  def step_state(entry, number, current)
    recorded = entry["state"].to_s.presence
    return recorded if recorded.present?
    return "running" if current.present? && number == current
    return "done" if current.present? && number < current

    "pending"
  end

  # The LEVER -> CONTROL map for the Run Job template picker: which form control
  # already edits each lever a template exposes.
  #
  # It is here, in the helper layer, and not in the view or the script, for one
  # reason: a control that does not exist is a lever whose value the operator
  # cannot change, and the honest handling of that is to leave the lever out of
  # the map so the template's own default composes. Inventing a control here for
  # a lever the form never offered would be a SECOND place to edit one number —
  # the drift trap this app keeps paying for, in a smaller costume.
  #
  # A LIST lever maps to its checkbox GROUP rather than to one box, and the value
  # is read as "which of these are ticked". `max_colors` and the two gates are
  # absent deliberately: they live in the contract textarea and the JSON page,
  # not in a control on this form, so applying a template sets them and editing
  # them stays the power feature's job.
  #
  # `:multi` marks a group; without it the single control's value is the whole
  # value.
  RUN_JOB_LEVER_CONTROLS = {
    "max_candidates" => "sweep_max",
    "filter_speckle" => "sweep_speckle",
    "presets" => { controls: %w[sweep_bw sweep_poster sweep_photo], multi: true },
    "hierarchical" => { controls: %w[hier_cutout hier_stacked], multi: true },
    "prep_colors" => "pe_prep_colors",
    "flux_variations" => "flux_images",
    "flux_steps" => "flux_steps",
    "flux_guidance" => "flux_guidance",
    "flux_width" => "flux_width",
    "flux_height" => "flux_height",
    "bp_op" => "bp_op",
    # The blender pass's render levers. Before these the ONLY bp control on the
    # form was the operation: the rest were composed into the contract by a
    # template and then editable by hand in the JSON box, which is a control
    # that exists for one value and never for another. Ids equal lever names so
    # the map cannot drift from the markup that provides them.
    "bp_render_width" => "bp_render_width",
    "bp_render_height" => "bp_render_height",
    "bp_background" => "bp_background",
    "bp_projection" => "bp_projection",
    "bp_elevation" => "bp_elevation",
    "bp_azimuth" => "bp_azimuth",
    "bp_views" => "bp_views",
    "bp_engine" => "bp_engine",
    "bp_depth" => "bp_depth",
    "bp_bevel_depth" => "bp_bevel_depth",
    "plot_op" => "plot_op"
  }.freeze

  # The map rendered for the template select's options: lever name -> the CONTROL
  # IDS that edit it, flattened. A group becomes several ids joined by `+`, which
  # is the one character a lever name and a DOM id cannot both contain, so the
  # script splits on whitespace and then on `+`.
  #
  # Only levers whose controls ALL EXIST are included. A group missing one box is
  # dropped whole rather than half-mapped: posting the ticked half of a preset
  # list would compose a list the operator never chose.
  def run_job_lever_controls # :nodoc:
    RUN_JOB_LEVER_CONTROLS.each_with_object({}) do |(lever, spec), out|
      ids = spec.is_a?(String) ? [spec] : Array(spec[:controls])
      next unless ids.all? { |id| id.present? }
      out[lever] = ids.join("+")
    end
  end

  # The URL that serves a job's preview for a project card thumbnail — the same
  # two-sided answer the job card resolves inline: a finished proof or a runner
  # source.png goes through the runner's file proxy, a generated raster or a
  # plot/blender/bp output lives in storage/uploads behind the login-gated
  # preview route. ONE place decides it here because every project card (list
  # and grid alike) asks the same question.
  def project_preview_url(job)
    if job.preview_from_upload?
      upload_preview_jobs_path(name: job.preview_file)
    else
      file_job_path(job, name: job.preview_file)
    end
  end

  # ONE section heading for every record page -- facelift 2/4 (issue #94).
  #
  # The skeleton's `h3` is a MICRO-heading, not a card title: uppercase,
  # tertiary, letter-spaced (the vatican-kb entity page's rhythm). Every record
  # page renders its sections through here, so "Candidates", "Proofs", "Sources:"
  # on a job, "Composites" on a project and "Proof render" / "Findings" /
  # "Training set" on a proof all read as the same thing.
  #
  # The LOOK is decided once, in the sheet: `h3.record-section`. The TAG is part
  # of that selector on purpose -- it is (0,1,1) and ties with `.card h3`, which
  # is also (0,1,1), so the rule wins on source order; a bare `.record-section`
  # at (0,1,0) would LOSE to `.card h3` and the proof page's sections would keep
  # the card's 1.25rem title size (specificity is arithmetic -- see the studio
  # layout pitfalls).
  def record_section(label)
    content_tag(:h3, label, class: "record-section")
  end

end
