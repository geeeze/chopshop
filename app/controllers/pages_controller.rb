class PagesController < ApplicationController
  # These pages are ungated by omission and therefore PUBLIC: `/about`, `/json`
  # and `/jev` render without a session, while Jobs and Validations both declare
  # `before_action :require_login`. The spec builder is the important one — it
  # documents the job contract and the palette library, and `/json/use` stashes a
  # spec draft into the session. A password gate that leaves these open is not a
  # gate. Deliberately explicit rather than inherited so a future page is gated
  # by default: add new public pages to the `except:` list with a reason.
  before_action :require_login, except: []

  # The documents the STATUS page asks the blend-plot service to draw, and the
  # geometry of each. Both charts are fixed-size — an axis only reads as a chart
  # at a known width, where the page's own column is fluid — and the log, one row
  # per event, keeps a bounded height so two reads stay comparable.
  STATUS_USE_SIZE  = { "width" => 1200, "height" => 320 }.freeze
  STATUS_HOST_SIZE = { "width" => 1200, "height" => 360 }.freeze
  STATUS_LOG_SIZE  = { "width" => 1200, "height" => 600 }.freeze

  # The pipeline-use chart's bars, in ONE place: the chart's own labels, the
  # values it plots and the tiles beside it all read this list, so a count cannot
  # be drawn without being named, or named in a different order than it is drawn.
  USE_BARS = [
    ["jobs", :jobs],
    ["generated", :generated],
    ["traced", :traced],
    ["proofs", :proofs],
    ["scrapbooked", :scrapbooked],
    ["composited", :composited]
  ].freeze

  # The log's own humanizer, shared by BOTH of its renderings — the spec the page
  # posts and the HTML it falls back to — so a row's name is decided once rather
  # than restated in the view.
  helper_method :status_event_label

  # JSON — the spec (job contract) builder. Docs live in the view; the
  # generated JSON is assembled client-side and applied via #apply_spec.
  def schema
    # The predefined palettes come from the pipeline (config/palettes.json,
    # kept in sync by bin/sync-palettes) — read-only reference next to the
    # spec's own palette list.
    @palette_library = PaletteLibrary.load
  end

  # Store a validated spec draft in the database and hand it to the new-run form
  # as the token the form reads it by. NOT the session: a built contract can run
  # to tens of kilobytes and the session is a 4 KB cookie, so this raised
  # CookieOverflow for the larger specs while the redirect itself had already
  # been answered. See SessionDraft.
  def apply_spec
    raw = params[:spec].to_s
    begin
      parsed = JSON.parse(raw)
    rescue JSON::ParserError
      parsed = nil
    end
    if parsed.is_a?(Hash)
      token = SessionDraft.store(kind: SessionDraft::SPEC, body: JSON.pretty_generate(parsed))
      redirect_to new_job_path(spec_draft_token: token), notice: "Spec loaded into the new-run form."
    else
      redirect_to json_path, alert: "That didn't parse as a JSON object."
    end
  end

  # Apply a TEMPLATE to a spec. The Run Job form's template control posts the
  # key plus whatever is in the contract textarea, and gets back the composed
  # document as a DRAFT — the same hand-off `pages#apply_spec` uses for the JSON
  # page, for the same reason: the composer runs HERE, so the bounds and the
  # coercion that turn a form's strings into contract values stay server-side
  # code with one definition, rather than a second implementation in JavaScript
  # that could disagree with the Ruby one.
  #
  # POST, because it changes what the operator is looking at. GET would be
  # cacheable, and a cached template application would silently show a stale
  # contract.
  def apply_template
    key = params[:template].to_s
    unless PipelineConf.template_keys.include?(key)
      return respond_to do |format|
        format.html { redirect_to new_job_path, alert: "No such template: #{key}." }
        format.json { render json: { error: "no such template: #{key}" },
                             status: :unprocessable_entity }
      end
    end

    # The textarea's current contents are the BASE, so a template refines what
    # the operator already has rather than replacing a hand-written contract
    # they may have spent effort on. A body that will not parse is treated as an
    # empty spec — composing onto broken JSON would raise here, and the form
    # already refuses a broken spec at submit with a message that belongs there.
    base = begin
      parsed = JSON.parse(params[:spec].to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    # Whatever is in the panels is the most recent fact, so it wins over the
    # textarea's copy of it: an operator who moved a slider and then hit Apply
    # means the slider.
    #
    # BOTH calls are inside the rescue: `template_overrides` raises for an
    # unknown lever (it is the method that notices), and the rescue used to wrap
    # only `compose`, so the refusal escaped as a 500 instead of the 422 that
    # says what was wrong.
    spec =
      begin
        PipelineConf.compose(key, into: base, overrides: template_overrides)
      rescue ArgumentError => e
        return respond_to do |format|
          format.html { redirect_to new_job_path, alert: e.message }
          format.json { render json: { error: e.message }, status: :unprocessable_entity }
        end
      end

    token = SessionDraft.store(kind: SessionDraft::SPEC, body: JSON.pretty_generate(spec))
    respond_to do |format|
      format.html { redirect_to new_job_path(spec_draft_token: token),
                             notice: "#{PipelineConf.template(key)[:label]} template applied." }
      format.json { render json: { template: key, spec: spec } }
    end
  end

  # The lever values the panels currently hold, read by the bound's declared
  # type so the composer receives numbers rather than strings.
  #
  # Only levers this TEMPLATE exposes are read, and only the ones whose panel is
  # on screen. Reading a hidden control would carry a stale value into the
  # contract — the same rule the form's own writePanels() follows, and for the
  # same reason: a control that is off screen must not write into the contract.
  def template_overrides
    key = params[:template].to_s
    return {} unless PipelineConf.template_keys.include?(key)

    # `params[:levers]` is an ActionController::Parameters, NOT a Hash — it answers
  # `is_a?(Hash)` with FALSE, so a `return {} unless values.is_a?(Hash)` guard
  # here discarded EVERY posted lever silently. Found by posting to the live
  # page: `max_candidates` came back as the template's own 8 instead of the 20
  # that was sent. The check is `.respond_to?(:[])`, which both a Parameters and
  # a plain Hash answer, so the guard works for a test that passes a Hash too.
  values = params[:levers]
  return {} unless values.respond_to?(:[])
  return {} unless values.respond_to?(:keys)

    exposed = PipelineConf.lever_names_for(key)
    # An override for a lever this template does not expose is refused HERE, not
    # skipped. Silently dropping it means a form field that posts a control the
    # template never had, and the operator sees the value applied to nothing.
    # `PipelineConf.compose` also refuses, but it runs after this method has
    # already filtered the keys out, so without this the refusal never fires.
    unknown = values.keys.map(&:to_s) - exposed
    unless unknown.empty?
      raise ArgumentError,
            "#{key} has no lever #{unknown.first.inspect} — an override for " \
            "something the template does not expose would set a value the " \
            "contract never carries"
    end

    exposed.each_with_object({}) do |lever, out|
      raw = values[lever]
      next if raw.nil?
      begin
        # A LIST lever is posted as ONE comma-separated string — the checkbox
      # group joins its ticked values in the form's JS — so it must be handed to
      # `coerce` already split. Passing the whole string produced
      # `["bw,poster"]`, a single preset name the trace stage would refuse.
      # An Array is already split, so it is joined back only to be re-split,
      # which keeps one code path (and handles `levers[presets][]=` too).
      value = raw.is_a?(Array) ? raw : raw.to_s.split(",")
      coerced = PipelineConf.coerce(lever, value)
      rescue ArgumentError, TypeError
        # A lever the operator typed nonsense into is left to the template's own
        # default rather than aborting the whole application: the form's own
        # refusal at submit is where a bad number belongs, with the field named.
        next
      end
      out[lever] = coerced unless coerced.nil?
    end
  end

  # JEV — the decision sidecar contract: the four questions Jev is asked,
  # the confidence rules, and the verdict the studio renders.
  def jev
    # WHICH SERVICE ANSWERED. The backend is selected in the RUNNER's
    # environment, so this app cannot report a configured value -- it does not
    # own that environment. What it does own is the provenance: every stored
    # answer carries the endpoint and model it came from, so a proof answered
    # before a cutover and one answered after it say different things, and the
    # page can show the real distribution instead of a claim. Bounded, because
    # this is a page render and not an audit query.
    @jev_answered_by = Validation.where.not(jev_meta: nil)
                                 .order(id: :desc)
                                 .limit(200)
                                 .pluck(:jev_meta)
                                 .filter_map { |m| m.is_a?(Hash) ? [m["endpoint"], m["model"]] : nil }
                                 .tally
                                 .sort_by { |(_endpoint, _model), count| -count }
  end

  # FLUX — the generation service's configuration and model registry, mirrored
  # from chopshop-flux's config.py and models.py. Read-only by design: the page
  # shows what the service would be started with, validates a request the way the
  # service does, and hands you the env block and JSON to copy. It does not run
  # the service and cannot set its environment.
  def flux
  end

  # BP — Blend-Plot: the geometry source, the metrics digest and the 3D render
  # operation as ONE page, because they are ONE service. The repo behind both
  # halves was renamed chopshop-plot -> chopshop-bp because it hosts both: `plot`
  # draws documents and `blend` renders geometry in 3D. Same read-only rule as
  # FLUX: the page shows what the service would be started with, what each half's
  # contract accepts, and the runners this studio files each half under — it does
  # not run the service and cannot set its environment.
  def bp
    # Each half's runners, read from the env-driven map so the page reports the
    # real ones rather than the defaults it documents. Empty is a normal state:
    # that half then says so and its settings stand on their own.
    @plot_runners = Job.plot_runners.to_h { |label| [label, Job.runners[label]] }
    @blender_runners = Job.blender_runners.to_h { |label| [label, Job.runners[label]] }
  end

  # PLOT and BLENDER were separate pages before the two halves were recognised as
  # ONE service. Both URLs stay — existing links and bookmarks must never 404 —
  # and both land on the one page. A permanent redirect: the move is permanent,
  # and the two pages they used to render no longer exist as templates.
  def plot
    redirect_to bp_path, status: :moved_permanently
  end

  def blender
    redirect_to bp_path, status: :moved_permanently
  end

  # TOURNAMENT — a SIMULATED single-elimination bracket over a candidate set,
  # drawn in the mirrored (two-sided) layout: the tree folded at its ROOT, the
  # final in the CENTRE column, round one at both outer edges. That is what
  # "mirrored" means in the literature, and it is deliberately NOT per-round
  # alternation — in any bracket the connectors already alternate up and down
  # because feeder 2j sits above its target and 2j+1 below it, so a per-round
  # reordering would be a second, wrong mechanism dressed as a feature.
  #
  # The rule this page exists under: THE PIPELINE NEVER PICKS A WINNER. So the
  # sim decides nothing. It reads no Job, no Candidate and no Event, it writes
  # nothing, and it is not owner-scoped — it is a demonstration of a shape, like
  # every other page here. The entrants are the names this file declares, plus
  # the meme candidate: a deliberately terrible entrant whose only job is to
  # make the LOSER path visible, because a bracket that has only ever rendered
  # winners has not been shown to handle an elimination, a tie or a bye.
  #
  # `layout` is defaulted from the SIZE rather than from taste: below 16 slots
  # the plain left-to-right bracket is both smaller and simpler and the mirror
  # buys nothing, so mirroring a small field would be theatre. The threshold is
  # stated on the page for the same reason. The constant lives on the sim now
  # (the job path derives the same layout); the page keeps its own name for it.
  MIRROR_THRESHOLD = TournamentSim::MIRROR_THRESHOLD

  TOURNAMENT_ENTRANTS = TournamentSim::DEFAULT_ENTRANTS

  def tournament
    load_tournament
  end

  # The bracket WITHOUT the page head or the layout: what the BP page's
  # TOURNAMENT popup fetches, so the shape has one definition rather than a page
  # and a popup that drift. Same arrangement as the datasets surface — see
  # bp.html.erb for why the trigger lives there.
  def tournament_surface
    load_tournament
    render partial: "pages/tournament_surface", layout: false
  end

  # STATUS — the telemetry surface, and the reason the event log exists.
  #
  # THREE panels, each drawn by the blend-plot service and each falling back to
  # the page's own HTML when the service cannot answer:
  #
  #   * PIPELINE USE — what this studio has PRODUCED: runs, generated rasters,
  #     traced candidates, proofs, scrapbook items and composites, as one bar
  #     chart with the same counts as tiles beside it.
  #   * SERVER — what the HOST was doing while it did: CPU, memory and swap over
  #     the last six hours, from HostSample's minute samples, plus the newest
  #     reading and when it was taken.
  #   * EVENT LOG — one row per recorded human action, newest first: the learning
  #     signal a later learned ranker reads.
  #
  # The page draws nothing itself (the rule PLOT holds for the same reason): a
  # document is POSTed to the service's operation and the SVG it answers with is
  # inlined. `digest` is asked for twice and `log` once, and nothing is asked
  # when there is nothing to draw -- a deployment with no samples yet must not
  # receive a chart of zeros, which reads as a measurement.
  #
  # The HIERARCHY that used to lead this page is GONE deliberately: source → job
  # → candidate restated the jobs table in a shape nobody could read a number out
  # of, and the operator asked for the measurements the table cannot show. The
  # absence is pinned by test/controllers/status_page_test.rb so it cannot creep
  # back as a card. The reasoning is in docs/ui-conventions.md.
  def status
    @events = Event.recent
    # ONE name for the service behind all three panels: a bp runner when the
    # deployment has one, the legacy plot kind otherwise -- see status_draw_runners.
    @status_runners = status_draw_runners

    # The recorded signal in counts (what the footer's check-engine light leads
    # here for) and the pipeline's shipped ML/ranking constants. Both are read
    # here rather than derived in the view, and both are read-only: the studio
    # records the signal and serves it, it does not train or configure.
    @telemetry = Telemetry.metrics
    @telemetry_config = Telemetry::CONFIG

    # What the studio produced, and what the box was doing. Read once: the spec
    # posted to the service, the tiles rendered beside it and GET /engine.json all
    # read these two hashes, so no two surfaces can disagree about a number.
    @use = Telemetry.use
    @host = HostSample.latest
    @host_stale = HostSample.stale?
    @host_data = HostSample.chart_data
    # The bar order and wording, handed to the view rather than restated in it:
    # the chart's labels, its values and the tiles all read this one list.
    @use_bars = USE_BARS

    @use_spec  = status_use_spec(@use)
    @host_spec = @host_data[:points].positive? ? status_host_spec(@host_data) : nil
    @log_spec  = status_log_spec(@events)

    # Nothing to draw is nothing to ask for: a fresh deployment has no samples
    # yet and no recorded events, and a bar chart of six zeros or a timeline with
    # no rows is a drawing of an absence. The numbers are still rendered.
    @use_svg  = @use.values.sum.positive? ? status_svg("digest", @use_spec) : nil
    @host_svg = @host_spec && status_svg("digest", @host_spec)
    @log_svg  = @events.any? ? status_svg("log", @log_spec) : nil
  end

  # ??? — basic info about the shop.
  def about
  end

  private

  # A memory figure in the unit it is read in: GB to one decimal at a gigabyte
  # and above, MB below it, and a dash when the reading is ABSENT — the same rule
  # as everywhere else on this page, an unmeasured value is not a zero.
  def status_host_size(mb)
    return "—" if mb.nil?
    mb >= 1024 ? format("%.1f GB", mb / 1024.0) : "#{mb} MB"
  end
  helper_method :status_host_size

  # #status-draw-runners
  # The runners that can DRAW this page, in preference order: a `bp` runner
  # first — one action whose op selector covers all six operations, which is what
  # the site offers a new job — and the legacy `plot` kind second, because that is
  # the same service under an older label and a deployment that has not added its
  # `CHOPSHOP_RUNNER_BP_*` line should still get its charts. Both speak the same
  # `{op, spec}` wire; BpClient routes everything but `blender` to PlotClient, and
  # this page only ever draws.
  def status_draw_runners
    Job.bp_runners.presence || Job.plot_runners
  end

  # #status-use-chart
  # The pipeline-use bar chart: one bar per count, in USE_BARS' order, from the
  # same Telemetry.use hash the tiles and /engine.json read. A bar chart rather
  # than a line because these are six unrelated totals — a line between them
  # would imply a progression that does not exist.
  def status_use_spec(use)
    {
      "chart" => "bar",
      "title" => "Pipeline use — what this studio has produced",
      "size" => STATUS_USE_SIZE,
      "data" => {
        "labels" => USE_BARS.map(&:first),
        "series" => [{ "name" => "files", "values" => USE_BARS.map { |(_, key)| use[key].to_i } }]
      }
    }
  end

  # #status-host-chart
  # The server chart: CPU and memory as two series over one label list, plus swap
  # as a THIRD only when the box actually has swap.
  #
  # `data[:swap]` is nil rather than a row of nils when it cannot be drawn, and
  # that is the whole reason for the branch: bp's contract takes NUMBERS, so a
  # nil could only be smuggled in as a zero, which draws a flat line on the floor
  # and states a measurement nobody made. The panel says swap is unmeasured
  # instead of drawing it.
  def status_host_spec(data)
    series = [
      { "name" => "cpu %", "values" => data[:cpu] },
      { "name" => "mem %", "values" => data[:mem] }
    ]
    series << { "name" => "swap %", "values" => data[:swap] } if data[:swap]

    {
      "chart" => "line",
      "title" => "Server — CPU, memory and swap",
      "size" => STATUS_HOST_SIZE,
      "data" => { "labels" => data[:labels], "series" => series }
    }
  end

  # The event log: one row per recorded action, in Event#recent's order (newest
  # first). `label` is the artifact's checksum when it has one -- the signal is
  # keyed by content, so the digest is the honest name -- and a job-derived label
  # when it does not, because a row with no name at all says nothing.
  def status_log_spec(events)
    {
      "title" => "Candidate triage — recorded events",
      "size" => STATUS_LOG_SIZE,
      "events" => events.map do |event|
        {
          "t" => event.created_at&.iso8601,
          "kind" => event.event.to_s,
          "label" => status_event_label(event),
          "pos" => event.pos
        }
      end
    }
  end

  # Ask the FIRST configured draw runner for one document. Success is the SVG
  # itself; a refusal or a service that is down returns nil, and the page falls
  # back to its own HTML -- telemetry degrades, it does not 500. The error is
  # remembered, so the page can say WHICH panel is missing and why.
  def status_svg(op, spec)
    label = @status_runners.first
    return nil if label.blank?

    result = PlotClient.post("#{Job.runners.fetch(label)}/#{op}", { op: op, spec: spec })
    # Net::HTTP hands the body back as binary (ASCII-8BIT); the SVG is text, so
    # force it to UTF-8 before it is spliced into the UTF-8 template -- leaving
    # it binary raises Encoding::CompatibilityError on `html_safe`.
    svg = result[:bytes].to_s.dup.force_encoding(Encoding::UTF_8)
    return nil unless svg.valid_encoding?
    svg
  rescue PlotClient::PlotError => e
    @status_plot_error = e.message
    nil
  end

  # The log row's name: the checksum, else the action's own payload name (a
  # star/pick records the artifact it was made on), else the job it came from.
  def status_event_label(event)
    event.svg_sha.presence || status_payload_name(event) || status_job_label(event)
  end

  # The bracket, built in ONE place so the page (tournament) and the popup
  # (tournament_surface) cannot render a different tournament. The popup passes
  # no params, so it gets the auto-chosen layout — which is the same bracket the
  # page shows when you arrive without asking for the other one.
  def load_tournament
    names = params[:entrants].present? ? Array(params[:entrants]).first(32) : TOURNAMENT_ENTRANTS.dup
    names = names + [TournamentSim::MEME_NAME]

    probe = TournamentSim.new(names, layout: :ltr)
    layout = if params[:layout].present?
               params[:layout].to_sym
             else
               probe.size >= MIRROR_THRESHOLD ? :mirror : :ltr
             end

    @sim = TournamentSim.new(names, seed: params[:seed].presence || "chopshop", layout: layout)
    @champion = @sim.champion
    @outcomes = @sim.outcomes
    @auto_layout = params[:layout].blank?
    @threshold = MIRROR_THRESHOLD
  end

  def status_payload_name(event)
    payload = event.payload
    payload.is_a?(Hash) ? payload["name"].presence : nil
  end

  def status_job_label(event)
    event.job_id ? "job ##{event.job_id}" : "event ##{event.id}"
  end
end
