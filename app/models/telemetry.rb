# The two things the check-engine light reports, in one place.
#
#   #telemetry-metrics  -- the owner's RECORDED learning signal: how much of it
#                          there is, per kind. The footer's orb colours its dot
#                          from this (amber with none, green with at least one)
#                          and the STATUS page summarises it.
#   #telemetry-config   -- the SHIPPED constants of the pipeline that trains on
#                          that signal: the ranker, the bandit and the triage
#                          gates, transcribed from chopshop-svg. Read-only, the
#                          same rule FluxConf and PlotConf hold: these tables are
#                          what the service IS configured with, and nothing here
#                          can change it.
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
  # Transcribed from chopshop-svg's scripts/triage_ranker.py and scripts/
  # triage.py. Each entry is {title:, body:}: the title is the constant's name
  # and the body is what it does, with the shipped values VERBATIM in <span
  # class="mono"> -- a re-worded number here would make the STATUS page a page
  # that lies about the pipeline it describes.
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

  # Where the learned model and the bandit's statistics live. They are the
  # pipeline's files, in the pipeline's learning dir -- the studio records the
  # signal and serves it at GET /events; it does not train or hold the model.
  LEARNING = [
    { title: "Files",
      body: "<mono>learned_ranker.json</mono> and <mono>learned_buckets.json</mono>, in the " \
            "pipeline's learning dir (<mono>PIPELINE_LEARNING_DIR</mono>)." },
    { title: "Trained on",
      body: "This studio's event log — the same signal the " \
            "<mono>GET /events</mono> endpoint serves." }
  ].freeze

  # The whole of the ML / ranking section, grouped the way the pipeline splits it.
  CONFIG = [
    { title: "Ranker", note: "chopshop-svg · scripts/triage_ranker.py", entries: RANKER },
    { title: "Bandit", note: "same file — how the next bucket is chosen", entries: BANDIT },
    { title: "Triage gates", note: "chopshop-svg · scripts/triage.py spec defaults", entries: GATES },
    { title: "Learned files", note: "the pipeline trains, this studio records", entries: LEARNING }
  ].freeze
end
