# The owner-scoped DATA read-models, split out of Telemetry (#73).
#
# Telemetry held TWO jobs: this file's owner-scoped aggregation over the studio's
# own tables, AND the pinned CONFIG mirror of the pipeline that trains on that
# signal (the #telemetry-config tables). They are now one class each -- this one
# answers "how much signal does THIS owner have", Telemetry answers "what is the
# pipeline shipped configured with". A class that does both cannot say which of
# the two it is when a caller asks it for a number.
#
# A model class rather than a helper because these are facts about the system's
# own recorded data, read through the owner-scoped models -- the same precedent
# Telemetry::CONFIG follows for the config half, and HostSample before it.
class EngineMetrics
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
      scrapbook: ScrapbookItem.count,
      composites: composite_signal
    }
  end

  # #telemetry-composite-layout
  #
  # The ARRANGEMENT half of the learning signal, aggregated. A composite is a
  # set of placed layers, and CompositeLayout already scores how they sit
  # (alignment, even gaps, frame, balance, coupling) — so the aggregate is a
  # read of that same scoring rather than a second opinion about it. Reported
  # alongside the counts because "how many composites" says nothing about
  # whether the operator is COUPLING them: `coupled` is the share of
  # composites carrying at least one constraint, which is the difference
  # between a library of arrangements and a library of accidents.
  def self.composite_signal
    rows = Composite.all.to_a
    return { count: 0, scores: 0, mean_score: nil, coupled: 0, coupled_share: 0.0,
             links: 0, layers: 0 } if rows.empty?

    scores = []
    coupled = 0
    links = 0
    layers = 0
    rows.each do |c|
      m = c.layout_metrics
      scores << m["score"]
      layers += m["layers"]
      links += m["links"]
      coupled += 1 if m["links"].positive?
    end
    {
      count: rows.length,
      scores: scores.length,
      mean_score: (scores.sum / scores.length).round(3),
      coupled: coupled,
      coupled_share: (coupled.to_f / rows.length).round(3),
      links: links,
      layers: layers
    }
  end

  # No signal yet: nothing has been starred, picked or deleted, so there is
  # nothing for a learned model to train on and the hand order stands. This is
  # the state the footer's dot reports in amber.
  def self.cold?
    metrics[:events].zero?
  end

  # ------------------------------------------------------------------- the use
  # #telemetry-use
  #
  # THE PIPELINE USE TALLY: what this studio has actually PRODUCED, as opposed
  # to the training signal above (which is what the operator has JUDGED). The
  # STATUS page draws these as one bar chart, and GET /engine.json carries the
  # same hash, so the page and its machine-readable twin cannot disagree.
  #
  # Every count is owner-scoped, through the same models the rest of the app
  # reads — `metrics` for the four that live in the studio's own tables, plus the
  # generated files and proofs below, which are counted from the rows that
  # recorded them rather than from a runner's report. Nothing here asks a service
  # anything: a service being down must not turn a recorded fact into a zero.
  def self.use
    counts = metrics
    {
      jobs: counts[:jobs],
      generated: generated_files,
      traced: counts[:candidates],
      proofs: Validation.where(state: "done").count,
      scrapbooked: counts[:scrapbook],
      composited: counts[:composites][:count]
    }
  end

  # The raster files the generation layer produced for this owner: the sum of
  # each generation job's OWN recorded variations.
  #
  # Read through `Job#generated_variations`, which looks at the job's record
  # rather than at the configured runner kinds — see that method for why a tally
  # must not go through the deployment's configuration. Only the three columns
  # that method reads are selected, because this walks every job and a spec can
  # be tens of kilobytes; it is a page load, not an audit.
  def self.generated_files
    Job.select(:id, :spec, :input_path).sum { |job| job.generated_variations.size }
  end
end
