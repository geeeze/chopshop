class PagesController < ApplicationController
  # These pages are ungated by omission and therefore PUBLIC: `/about`, `/json`
  # and `/jev` render without a session, while Jobs and Validations both declare
  # `before_action :require_login`. The spec builder is the important one — it
  # documents the job contract and the palette library, and `/json/use` stashes a
  # spec draft into the session. A password gate that leaves these open is not a
  # gate. Deliberately explicit rather than inherited so a future page is gated
  # by default: add new public pages to the `except:` list with a reason.
  before_action :require_login, except: []

  # The two documents the STATUS page asks chopshop-plot to draw. The tree is
  # drawn LEFT-TO-RIGHT (layout "lr") so its leaves — the candidates — stack
  # VERTICALLY down the page; only its width is pinned, and the service fits the
  # height to however many candidates there are (a fixed height would clip a
  # long list). The log keeps a fixed size: it is one row per event, so its
  # height is bounded and two reads stay comparable.
  STATUS_TREE_SIZE = { "width" => 1200 }.freeze
  STATUS_LOG_SIZE  = { "width" => 1200, "height" => 600 }.freeze

  # The small humanizers the STATUS page uses for BOTH renderings -- the spec it
  # posts and the HTML fallback -- so a node's status and metrics are decided
  # once rather than restated in the view.
  helper_method :status_source_label, :status_candidate_status, :status_candidate_metrics,
                :status_event_label, :status_ordered_candidates

  # JSON — the spec (job contract) builder. Docs live in the view; the
  # generated JSON is assembled client-side and applied via #apply_spec.
  def schema
    # The predefined palettes come from the pipeline (config/palettes.json,
    # kept in sync by bin/sync-palettes) — read-only reference next to the
    # spec's own palette list.
    @palette_library = PaletteLibrary.load
  end

  # Store a validated spec draft in the session and hand it to the new-run
  # form as its default textarea content.
  def apply_spec
    raw = params[:spec].to_s
    begin
      parsed = JSON.parse(raw)
    rescue JSON::ParserError
      parsed = nil
    end
    if parsed.is_a?(Hash)
      session[:spec_draft] = JSON.pretty_generate(parsed)
      redirect_to new_job_path, notice: "Spec loaded into the new-run form."
    else
      redirect_to json_path, alert: "That didn't parse as a JSON object."
    end
  end

  # JEV — the decision sidecar contract: the four questions Jev is asked,
  # the confidence rules, and the verdict the studio renders.
  def jev
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
  # stated on the page for the same reason.
  MIRROR_THRESHOLD = 16

  TOURNAMENT_ENTRANTS = %w[
    tiger badger otter falcon heron marten lynx ibex stoat
  ].freeze

  def tournament
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

  # STATUS — the ML telemetry surface, and the reason the event log exists: the
  # candidate-triage LEARNING SIGNAL as two documents. A HIERARCHY (source → job
  # → candidate) and an EVENT LOG (one row per recorded human action), each
  # POSTed to chopshop-plot's tree and log operations and inlined as the SVG they
  # answer with. The page draws nothing itself -- the same rule PLOT holds -- and
  # with no plot runner configured it renders the SAME two documents as plain
  # HTML instead, so the signal is readable on a deployment without the service
  # (and in CI).
  def status
    # Newest-first jobs (Job#recent), each with its candidates preloaded. The
    # candidates are read in the same (hard, advisory, id) order the candidate
    # table and Event.position_of use: an event's `pos` is a position in THAT
    # order, so the log and the tree have to agree about it or the position is
    # meaningless.
    @jobs = Job.recent.includes(:candidates)
    @events = Event.recent
    @plot_runners = Job.plot_runners

    # The two summaries this page ALSO reports, both read here rather than
    # derived in the view: the recorded signal in counts (what the footer's
    # check-engine light leads here for) and the pipeline's shipped ML/ranking
    # constants. Read-only, like everything else on the page -- the studio
    # records the signal and serves it; it does not train or configure.
    @telemetry = Telemetry.metrics
    @telemetry_config = Telemetry::CONFIG

    @tree_spec = status_tree_spec(@jobs)
    @log_spec  = status_log_spec(@events)
    @tree_svg  = status_svg("tree", @tree_spec)
    @log_svg   = status_svg("log", @log_spec)
  end

  # ??? — basic info about the shop.
  def about
  end

  private

  # The hierarchy: one subtree per job, rooted at the source it was traced from
  # -- source → job → candidate. Node ids are slugged from the record's OWN id,
  # so they are unique across jobs and JSON-safe whatever the labels contain.
  # Candidate status is the triage state, and candidate metrics are the three
  # numbers the comparison carries.
  def status_tree_spec(jobs)
    nodes = []
    edges = []

    jobs.each do |job|
      source_id = status_node_id("source", job.id)
      job_node_id = status_node_id("job", job.id)

      nodes << { "id" => source_id, "label" => status_source_label(job),
                 "kind" => "source", "status" => job.state.to_s, "metrics" => {} }
      nodes << { "id" => job_node_id, "label" => job.name.to_s,
                 "kind" => "job", "status" => job.state.to_s,
                 "metrics" => status_job_metrics(job) }
      edges << { "from" => source_id, "to" => job_node_id }

      status_ordered_candidates(job).each do |candidate|
        candidate_node_id = status_node_id("candidate", candidate.id)
        nodes << { "id" => candidate_node_id, "label" => candidate.file.to_s,
                   "kind" => "candidate", "status" => status_candidate_status(candidate),
                   "metrics" => status_candidate_metrics(candidate) }
        edges << { "from" => job_node_id, "to" => candidate_node_id }
      end
    end

    {
      "title" => "Candidate triage — source, job, candidate",
      "size" => STATUS_TREE_SIZE,
      "layout" => "lr",
      "nodes" => nodes,
      "edges" => edges
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

  # Ask the FIRST configured plot runner to draw one document. Success is the SVG
  # itself; a refusal or a service that is down returns nil, and the page falls
  # back to its own HTML -- telemetry degrades, it does not 500.
  def status_svg(op, spec)
    label = @plot_runners.first
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

  # The candidates in the one order that matters: (hard, advisory, id), the same
  # order the table renders and Event.position_of counts.
  def status_ordered_candidates(job)
    job.candidates.order(:hard, :advisory, :id)
  end

  # A node id: the record's kind and id, which cannot collide across jobs.
  def status_node_id(kind, id)
    "#{kind}-#{id}"
  end

  # A job's source, as the operator named the file: the basename of the path it
  # was traced from, falling back to the stem for a job with no input path.
  def status_source_label(job)
    File.basename(job.input_path.to_s).presence || job.stem.to_s
  end

  # The candidate's triage state, in the three words the panels use: a pass is a
  # pass, a hard-gate failure is a discard (it can never be picked), and a
  # candidate that only tripped an advisory is a warn.
  def status_candidate_status(candidate)
    return "pass" if candidate.passed
    return "discard" if candidate.hard.to_i.positive?
    "warn"
  end

  # The comparison's own numbers, and only where they are present: hard and
  # advisory are gate counts, mae_art is measured fidelity. mae_art is ABSENT
  # (not zero) when the back half did not run -- missing is a state, not a zero.
  def status_candidate_metrics(candidate)
    metrics = {}
    metrics["hard"] = candidate.hard unless candidate.hard.nil?
    metrics["advisory"] = candidate.advisory unless candidate.advisory.nil?
    fidelity = candidate.fidelity
    mae = fidelity.is_a?(Hash) ? fidelity["mae_art"] : nil
    metrics["mae_art"] = mae unless mae.nil?
    metrics
  end

  # What a job node reports about its own candidates: how many there are and how
  # many passed, which is the one-line summary of the subtree beneath it.
  def status_job_metrics(job)
    list = status_ordered_candidates(job).to_a
    { "candidates" => list.size, "passed" => list.count(&:passed) }
  end

  # The log row's name: the checksum, else the action's own payload name (a
  # star/pick records the artifact it was made on), else the job it came from.
  def status_event_label(event)
    event.svg_sha.presence || status_payload_name(event) || status_job_label(event)
  end

  def status_payload_name(event)
    payload = event.payload
    payload.is_a?(Hash) ? payload["name"].presence : nil
  end

  def status_job_label(event)
    event.job_id ? "job ##{event.job_id}" : "event ##{event.id}"
  end
end
