# The machine-readable twin of the footer's check-engine light.
#
# The footer orb answers one question in colour -- is there a learning signal,
# and is the pipeline behind it alive -- and links the operator to STATUS for the
# prose. An agent cannot read a colour or a paragraph, so this endpoint reports
# the same facts as one JSON document: which runners are configured and whether
# each answers /health, how much recorded signal this owner has (per kind, not
# one total), what the pipeline has PRODUCED (the STATUS page's use tally) and
# what the HOST itself has been doing (its newest sample, and whether the sampler
# is still running), plus what the ranker the pipeline trains is shipped
# configured with.
#
# It is deliberately READ-ONLY and COMPOSED, never a second source of truth:
#
#   * the counts come from EngineMetrics.metrics, the same method the footer and
#     the STATUS page read, so the three surfaces cannot disagree;
#   * the produced tally and the host reading come from EngineMetrics.use and
#     HostSample, which is what the STATUS page draws, so the page and this twin
#     report the same numbers by construction;
#   * the ranker's constants come from Telemetry's own tables, so a value
#     re-worded in the STATUS panel is re-worded here too -- a second copy would
#     be free to drift from the page it claims to twin.
#
# Owner scoping is not implemented here, it is inherited: EngineMetrics.metrics
# counts through the owner-scoped models, so another operator's jobs, events and
# scrapbook rows are invisible to this payload by construction.
#
# Login-gated like every other authed route, because runner health and event
# volume are facts about a private deployment.
class EngineController < ApplicationController
  before_action :require_login

  def show
    # A wrapper, not the bare EngineMetrics.metrics hash: the JSON also has to say
    # WHICH runner is down and WHICH ranker state this is, and those are facts
    # the metric counts do not carry.
    render json: engine_json
  end

  private

  def engine_json
    metrics = EngineMetrics.metrics
    {
      ok: true,
      generated_at: Time.current.utc.iso8601,
      owner: Current.user_handle,
      cold: EngineMetrics.cold?,
      runners: runner_rows,
      events: { total: metrics[:events], by_kind: metrics[:by_kind] },
      counts: { jobs: metrics[:jobs], candidates: metrics[:candidates],
                scrapbook: metrics[:scrapbook], composites: metrics[:composites][:count] },
      # The two panels the STATUS page gained, read through the SAME methods the
      # page reads -- EngineMetrics.use and HostSample -- so the page and its
      # machine-readable twin cannot drift apart about a number.
      use: EngineMetrics.use,
      host: host_summary,
      # The ARRANGEMENT half of the signal, exactly as EngineMetrics aggregates it —
      # the same scoring /composite/:id/metrics serves per composite, so an agent
      # reading one composite and an agent reading the fleet cannot get two
      # different answers about how the pieces sit.
      layout: metrics[:composites],
      ranker: ranker_summary(metrics)
    }
  end

  # #engine-host-summary
  # The newest host sample as data, plus the two facts an agent cannot infer from
  # it: WHEN it was taken, and whether the sampler is still running. `stale` is
  # the one that matters — an hour-old CPU percentage is a true reading of an
  # hour ago and a lie about now — and a box that has never been sampled says so
  # with `sampled: false` rather than reporting six nulls.
  #
  # `window` describes the chart the STATUS page draws (its span and how many
  # buckets it has) rather than shipping its several hundred numbers: the series
  # is a drawing, and an agent that wants the shape of the last hours can ask for
  # the samples themselves.
  def host_summary
    sample = HostSample.latest
    data = HostSample.chart_data
    window = { window_seconds: HostSample::WINDOW_SECONDS,
               bucket_seconds: HostSample::BUCKET_SECONDS,
               points: data[:points], from: data[:from]&.iso8601, to: data[:to]&.iso8601,
               series: data[:swap] ? %w[cpu mem swap] : %w[cpu mem] }

    return { sampled: false, sampled_at: nil, stale: true, values: nil, window: window } if sample.nil?

    {
      sampled: true,
      sampled_at: sample.captured_at.utc.iso8601,
      stale: HostSample.stale?,
      # swap_* is nil when the box has no swap configured: absent, not zero.
      values: {
        cpu_pct: sample.cpu_pct,
        mem_pct: sample.mem_pct, mem_used_mb: sample.mem_used_mb, mem_total_mb: sample.mem_total_mb,
        swap_pct: sample.swap_pct, swap_used_mb: sample.swap_used_mb,
        swap_total_mb: sample.swap_total_mb,
        load1: sample.load1
      },
      window: window
    }
  end

  # One row per configured runner label -- label, KIND, where it is, and whether
  # it is answering. `RunnerClient.health` never raises (it returns the error as
  # data), so a dead box reports itself here instead of taking the whole
  # aggregate down with it; that is the entire point of an aggregate.
  def runner_rows
    Job.runners.map do |label, url|
      health = RunnerClient.health(url)
      down = health.respond_to?(:key?) && health.key?(:error)
      {
        label: label,
        kind: Job.runner_kind(label),
        url: url,
        healthy: !down,
        health: down ? nil : health,
        error: down ? health[:error] : nil
      }
    end
  end

  # The ranker's state, in one place: what this owner has recorded, what the
  # cold-start gates are, and the constants the pipeline is shipped with.
  #
  # `state` is the same question the footer's dot answers -- "cold" means the
  # hand order still stands because there is nothing to train on.
  def ranker_summary(metrics)
    {
      state: EngineMetrics.cold? ? "cold" : "live",
      recorded_events: metrics[:events],
      picks: metrics[:by_kind]["pick"].to_i,
      jobs_with_picks: jobs_with_picks,
      thresholds: thresholds,
      learned_files: learned_files,
      learning_dir_env: learning_dir_env,
      shipped: shipped_config
    }
  end

  # The picks this owner has made across how many distinct jobs: the two numbers
  # the ranker's cold-start gate is written in terms of, so an agent can tell
  # "no signal yet" from "signal, not enough of it" without reading prose.
  def jobs_with_picks
    Event.of_kind("pick").where.not(job_id: nil).distinct.count(:job_id)
  end

  # The shipped thresholds, read out of the same table the STATUS page renders
  # rather than restated: the panel writes them as learn_min_picks=30 and
  # learn_min_jobs=2 in the ranker's own words.
  def thresholds
    match = Telemetry::RANKER.map { |entry| entry[:body] }.join(" ")
                     .match(/learn_min_picks=(\d+).*?learn_min_jobs=(\d+)/m)
    return {} unless match
    { min_picks: match[1].to_i, min_jobs: match[2].to_i }
  end

  # The learned-model files, from the same table (they are named there as the
  # monospaced tokens ending in .json). Scanned, not matched once: one entry
  # names both files.
  def learned_files
    Telemetry::LEARNING.flat_map { |entry| entry[:body].scan(/<mono>([\w.]+\.json)<\/mono>/).flatten }
  end

  # Where those files live, named by the environment variable the pipeline reads
  # -- the same variable name the panel shows, never a path this app cannot know.
  def learning_dir_env
    Telemetry::LEARNING.filter_map { |entry| entry[:body][/<mono>([A-Z][A-Z0-9_]+)<\/mono>/, 1] }.first
  end

  # The ML / ranking constants, grouped as the pipeline splits them. The bodies
  # carry <mono> markup for the page; JSON gets the text without the tags, so a
  # consumer never has to parse HTML out of a data field.
  def shipped_config
    Telemetry::CONFIG.map do |group|
      {
        title: group[:title],
        note: group[:note],
        entries: group[:entries].map do |entry|
          { title: entry[:title], body: entry[:body].gsub(/<\/?mono>/, "") }
        end
      }
    end
  end
end
