# The single serial gate every job passes through. A flux generation and a
# pipeline run are BOTH enqueued here, and Solid Queue runs the "runs" queue
# with exactly one worker thread — so the studio never sends more than one job
# to a runner (or the flux box) at a time. Everything else waits in order, and
# a queued job can be cancelled before its turn.
#
# The studio Job record is the source of truth; this job is only the trigger.
# It re-reads the record at the start and aborts if it is no longer "queued"
# (cancelled while waiting). That cooperative check is the backstop behind the
# Solid Queue discard in JobsController#cancel, so a cancelled job can never be
# dispatched even if the discard misses.
class RunJob < ApplicationJob
  queue_as :runs

  # The most QUEUED jobs one user may have waiting behind the one that is
  # running. A job's owner is stamped from the signed-in user (see Owned), so
  # "the queue" is per user: five is one operator's whole allotment, and filling
  # it delays nobody else. Enforced in JobsController#enqueue_run.
  MAX_QUEUE_PER_USER = 5

  # The global backstop behind the per-user cap, so one pathological user (or a
  # bug in the per-user count) still cannot starve the single worker: the box
  # never waits on more than this many jobs in total. Enforced in
  # JobsController#enqueue_run beside the per-user gate.
  MAX_QUEUE = 255

  # Raised when a queue is already at its limit -- one user's
  # MAX_QUEUE_PER_USER, or the global MAX_QUEUE backstop; surfaced to the
  # operator as a form error rather than a silent drop.
  class QueueFull < StandardError; end

  # Reference images are validated here (synchronously, in the controller) so a
  # bad path in the spec is refused before anything is enqueued. The check is
  # the same one the data-URL build re-runs at generation time: only a basename
  # that resolves inside storage/uploads is honoured, never a directory.
  def self.validate_reference!(name)
    uploads = Rails.root.join("storage", "uploads")
    candidate = uploads.join(File.basename(name.to_s))
    unless candidate.file? && candidate.to_s.start_with?(uploads.to_s + File::SEPARATOR)
      raise FluxClient::FluxError,
            "reference image #{File.basename(name.to_s)} is not a stored upload"
    end
    true
  end

  def perform(job_id)
    job = Job.find_by(id: job_id)
    return unless job && job.state == "queued"

    job.update!(state: "running", started_at: Time.current,
                prep_summary: activity_line(job))

    job.flux? ? run_flux(job) : (job.plot? ? run_plot(job) : run_pipeline(job))
  rescue FluxClient::FluxError => e
    fail_job(job, "FLUX: #{e.message}")
  rescue PlotClient::PlotError => e
    fail_job(job, "PLOT: #{e.message}")
  rescue RunnerClient::RunnerError => e
    fail_job(job, e.message)
  rescue StandardError => e
    fail_job(job, "runner connection failed: #{e.message}")
  end

  private

  # The studio-side progress line, for the job page's poll card. Each kind says
  # what it is actually doing: a generator draws a raster for the pipeline, a
  # plot service draws the deliverable, a pipeline runner is dispatched to.
  def activity_line(job)
    return "generating raster…" if job.flux?
    return "drawing plot…" if job.plot?
    "dispatching to #{job.runner}…"
  end

  # A flux job's generation happens HERE, in-process, so the worker holds the
  # serial slot for the whole generation (tens of seconds) — which is exactly
  # what "one flux job at a time" means. Only after the raster lands is the job
  # either done (raster-only) or handed to a pipeline runner for tracing.
  def run_flux(job)
    rendered = FluxClient.render(
      job.generator_base_url,
      prompt: job.flux_prompt,
      reference: flux_reference_data_url(job),
      model: flux_setting(job, "model"),
      width: flux_setting(job, "width"),
      height: flux_setting(job, "height"),
      steps: flux_setting(job, "steps"),
      guidance: flux_setting(job, "guidance"),
      seed: flux_setting(job, "seed"),
      images: flux_setting(job, "images"),
      negative_prompt: flux_setting(job, "negative_prompt"),
      # img2img-only, and only for a model that takes one: the service ignores
      # it otherwise. flux_setting blanks out to nil, so an empty field means
      # the service's own default rather than a zero strength.
      strength: flux_setting(job, "strength")
    )

    # Cancelled while the box was drawing: drop the raster and never hand it off.
    return if job.reload.state != "running"

    rasters = store_flux_rasters(job, rendered)
    spec = job.spec.merge(
      "flux" => job.flux_config.merge("rendered" => flux_render_facts(rendered, rasters))
    )

    if job.raster_only?
      # Nothing to trace: the picture IS the deliverable. Every variation is
      # kept; the first is the job's primary raster, the rest are previewed on
      # the job page and saveable.
      job.update!(spec: spec, input_path: rasters.first.to_s, state: "done",
                  candidate_count: 0, finished_at: Time.current,
                  prep_summary: "flux raster — #{rendered[:name]}")
    else
      handoff = Job.handoff_runner
      raise RunnerClient::RunnerError,
            "no pipeline runner is configured to hand the raster to" unless handoff
      job.update!(spec: spec.merge("flux" => spec["flux"].merge("handoff" => handoff)),
                  input_path: rasters.first.to_s, prep_summary: "handed to #{handoff}")
      resp = RunnerClient.create_job(job)
      job.update!(runner_job_id: resp[:id], state: "running")
    end
  end

  # A plot job's drawing happens HERE, in-process and synchronously: the service
  # takes one document and answers with one SVG -- no queue, no GPU, no job to
  # poll -- so the worker holds the serial slot only for the round trip. Nothing
  # sleeps or polls, because there is nothing to wait for.
  #
  # The result is stored like any other upload (a file in storage/uploads) and
  # the job is DONE when it lands: a plot draws a report, it does not trace, so
  # there are no candidates to gate and no runner to hand anything to.
  def run_plot(job)
    op = job.plot_op
    rendered =
      case op
      when "query"  then PlotClient.query(job.base_url, job.plot_runs, job.plot_doc)
      when "digest" then PlotClient.digest(job.base_url, job.plot_doc)
      else               PlotClient.generate(job.base_url, job.plot_doc)
      end

    # Cancelled while the service was drawing: drop the SVG and store nothing.
    return if job.reload.state != "running"

    stored = store_plot_svg(rendered)
    name = File.basename(stored.to_s)

    job.update!(
      spec: job.spec.merge(
        "plot" => job.plot_config.merge(
          "rendered" => { "file" => name, "op" => rendered[:op],
                          "content_type" => rendered[:content_type] }
        )
      ),
      state: "done", candidate_count: 0, finished_at: Time.current,
      prep_summary: "plot #{op} — #{name}"
    )
  end

  def store_plot_svg(rendered)
    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    dest = uploads.join("plot_#{SecureRandom.hex(6)}.svg")
    File.binwrite(dest, rendered[:bytes])
    dest
  end

  def run_pipeline(job)
    resp = RunnerClient.create_job(job)
    job.update!(runner_job_id: resp[:id], state: "running")
  end

  def fail_job(job, message)
    job&.update!(state: "error", error: message, finished_at: Time.current)
  end

  # The spec's flux block as the service wants it: blank values are omitted
  # rather than sent as empty strings, so the service's own defaults apply and a
  # blank field cannot mean something different from an absent one.
  def flux_setting(job, key)
    job.flux_config[key].to_s.strip.presence
  end

  # An uploaded reference for /edit, as the data URL the service requires. Nil
  # for a plain generation. Re-validated here (not just in the controller)
  # because the spec is user-editable text and generation is where the path is
  # actually consumed.
  def flux_reference_data_url(job)
    name = job.flux_config["image"].to_s.strip
    return nil if name.blank?
    self.class.validate_reference!(name)
    FluxClient.data_url(Rails.root.join("storage", "uploads", File.basename(name)).to_s)
  end

  def store_flux_rasters(job, rendered)
    entries = Array(rendered[:entries]).presence || [rendered]
    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    entries.map do |e|
      dest = uploads.join("flux_#{SecureRandom.hex(6)}.png")
      File.binwrite(dest, e[:bytes])
      dest
    end
  end

  # The facts worth keeping about the generation: a summary of the first image
  # (the job's primary raster) plus the full list of variations, so a batch is
  # previewable and a raster is reproducible from its seed.
  def flux_render_facts(rendered, stored_paths)
    entries = Array(rendered[:entries]).presence || [rendered]
    images = entries.each_with_index.map do |e, i|
      entry = e[:entry] || {}
      {
        "file" => stored_paths[i] && File.basename(stored_paths[i].to_s),
        "name" => e[:name],
        "seed" => entry["seed"],
        "model" => entry["model"],
        "width" => entry["width"],
        "height" => entry["height"],
        "seconds" => entry["seconds"]
      }.compact
    end
    entry = rendered[:entry] || {}
    {
      "name" => rendered[:name],
      "seed" => entry["seed"],
      "model" => entry["model"],
      "width" => entry["width"],
      "height" => entry["height"],
      "seconds" => entry["seconds"],
      "license" => rendered.dig(:meta, "license"),
      "commercial_ok" => rendered.dig(:meta, "commercial_ok"),
      "warnings" => Array(rendered.dig(:meta, "warnings")),
      "images" => images
    }.compact
  end
end
