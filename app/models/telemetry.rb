# The two things the check-engine light reports, in one place.
#
#   #telemetry-metrics  -- the owner's RECORDED learning signal: how much of it
#                          there is, per kind. The footer's orb colours its dot
#                          from this (amber with none, green with at least one)
#                          and the STATUS page summarises it.
#   #telemetry-config   -- the SHIPPED constants of the pipeline that trains on
#                          that signal: the ranker, the bandit and the triage
#                          gates, transcribed from chopshop-svg's
#                          scripts/triage_ranker.py and scripts/triage.py.
#                          Read-only, the same rule FluxConf and PlotConf hold:
#                          these tables are what the service IS configured with,
#                          and nothing here can change it. The transcription is
#                          PINNED, not trusted -- see the #telemetry-config
#                          comment below.
#
# A model class rather than a helper because the STATUS page renders the config
# as data (PlotConf::ELEMENTS is the precedent) and because a table of shipped
# constants is a fact about the system, not a view concern.
class Telemetry
  # The learning signal's own shape. Every kind the event log can hold, in the
  # order the log documents them -- taken from Event::KINDS so a kind added
  # there appears here without a second list to keep in step.
  #
  # #telemetry-metrics
  #
  # Each count is OWNER-SCOPED and that is the whole point: one operator's
  # actions are never another's training data. Event, Job and ScrapbookItem all
  # carry Owned's default_scope, which reads Current.user_handle (stamped by
  # ApplicationController before any data access). Candidates have no owner
  # column of their own -- they belong to a job -- so their count goes through
  # the owner-scoped Job relation as a subquery. Scoping them any other way
  # would report another operator's rows.
  def self.metrics
    {
      events: Event.count,
      by_kind: Event::KINDS.to_h { |kind| [kind, Event.of_kind(kind).count] },
      jobs: Job.count,
      candidates: Candidate.where(job_id: Job.select(:id)).count,
      scrapbook: ScrapbookItem.count
    }
  end

  # No signal yet: nothing has been starred, picked or deleted, so there is
  # nothing for a learned model to train on and the hand order stands. This is
  # the state the footer's dot reports in amber.
  def self.cold?
    metrics[:events].zero?
  end

  # ---------------------------------------------------------------- the config
  # #telemetry-config
  #
  # The shipped constants of chopshop-svg's ML / ranking pipeline, read from
  # that repo's scripts/triage_ranker.py -- COLD_START_PICKS (learn_min_picks),
  # LEARN_MIN_JOBS (learn_min_jobs), RANK_VISIBLE_WINDOW (window),
  # DEFAULT_RANDOM_SLOTS (n_random_slots), DEFAULT_EPSILON_EXPLORE,
  # BANDIT_TTL_SECONDS and RANKER_FILENAME -- and scripts/triage.py's
  # TRIAGE_DEFAULTS (the gate thresholds). Each entry is {title:, body:}: the
  # title is the constant's name and the body is what it does, with the shipped
  # values VERBATIM in <span class="mono"> -- a re-worded number here would make
  # the STATUS page a page that lies about the pipeline it describes.
  #
  # That rule is CHECKED, not trusted: test/models/runner_conf_drift_test.rb
  # reads every shipped value back OUT of the <mono> spans below and asserts it
  # against test/fixtures/runner_conf_drift.json ("chopshop_svg"), which was
  # generated from those two scripts and is re-derived live when
  # CHOPSHOP_SIBLING_ROOT points at the siblings. So a number changed here must
  # be what the pipeline ships, or the drift test fails and names it. The
  # pipeline is the source of truth: when the two disagree, fix this file.
  RANKER = [
    { title: "Cold start",
      body: "A learned model is only used once the log holds " \
            "<mono>learn_min_picks=30</mono> picks across <mono>learn_min_jobs=2</mono> " \
            "jobs. Below either threshold the hand order stands." },
    { title: "Features",
      body: "<mono>bias + hard, advisory, node_count_max, mae_art, colours, speckles, " \
            "bucket_speckle_bin, bucket_colour_bin + one per-preset one-hot</mono>" },
    { title: "Hand order (the fallback)",
      body: "Fewest hard gates, then advisories, then artwork MAE. A candidate with a " \
            "missing reading sorts last." },
    { title: "Anti-feedback",
      body: "1 slot of the top-8 visible window is held back for a random or uncertain " \
            "candidate (<mono>n_random_slots=1</mono>, <mono>window=8</mono>), so the order a " \
            "human acts on is never fed back as its own answer." },
    { title: "What it never does",
      body: "It never picks a winner: it orders candidates and the human picks." }
  ].freeze

  BANDIT = [
    { title: "What it samples",
      body: "Beta-Bernoulli Thompson sampling over bucket keys, never over candidates: " \
            "per-bucket successes and attempts drive the draw." },
    { title: "Exploration",
      body: "<mono>epsilon 0.1</mono> — one draw in ten explores a bucket the statistics " \
            "do not favour." },
    { title: "TTL",
      body: "Bucket statistics expire after 30 days, so the mix follows the sources in " \
            "front of you rather than a season of them." },
    { title: "Veto list",
      body: "A veto list removes a bucket outright, whatever its sampled score." }
  ].freeze

  GATES = [
    { title: "Spec defaults",
      body: "<mono>max_unique_colors 8 · max_speckles 40 · max_glow_area_pct 8 · " \
            "min_silhouette_iou 0.85 · min_luma_delta 12 · weak_needed 3 · bucket_cap 2</mono>" },
    { title: "How they act",
      body: "A HARD gate drops a candidate on any hit, and a WEAK gate demotes it once the " \
            "<mono>weak_needed</mono> hits accumulate." }
  ].freeze

  # Where the learned model and the bandit's statistics live, and what they are
  # learned FROM. The files are the pipeline's, in the pipeline's learning dir.
  # The training signal is the PIPELINE's own event log -- written by the trace
  # and sweep stages, beside those files -- and NOT this studio's event table:
  # the studio records the operator's actions and serves them at GET /events,
  # while the ranker reads the pipeline's events.jsonl and never this app's
  # rows. The two are PARALLEL signals about the same runs, not one store.
  LEARNING = [
    { title: "Files",
      body: "<mono>learned_ranker.json</mono> and <mono>learned_buckets.json</mono>, in the " \
            "pipeline's learning dir (<mono>PIPELINE_LEARNING_DIR</mono>)." },
    { title: "Trained on",
      body: "The PIPELINE's own event log — <mono>events.jsonl</mono>, in that same " \
            "learning dir (<mono>06_run/_learning/</mono> by default) — which the " \
            "pipeline's own stages append to as they run. It is a PARALLEL signal to " \
            "this studio's event log, not the same store: the studio records the " \
            "operator's actions and serves them at <mono>GET /events</mono>, while " \
            "the ranker reads the pipeline's file. Two records of the same runs, " \
            "written by two programs, for two readers." }
  ].freeze

  # The whole of the ML / ranking section, grouped the way the pipeline splits it.
  CONFIG = [
    { title: "Ranker", note: "chopshop-svg · scripts/triage_ranker.py", entries: RANKER },
    { title: "Bandit", note: "same file — how the next bucket is chosen", entries: BANDIT },
    { title: "Triage gates", note: "chopshop-svg · scripts/triage.py spec defaults", entries: GATES },
    { title: "Learned files", note: "the pipeline trains, this studio records", entries: LEARNING }
  ].freeze
end
