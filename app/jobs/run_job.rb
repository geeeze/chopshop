# The single serial gate every job passes through. A flux generation, a plot
# drawing, a blender render and a pipeline run are ALL enqueued here, and Solid
# Queue runs the "runs" queue with exactly one worker thread — so the studio
# never sends more than one job to a runner (or a renderer) at a time.
# Everything else waits in order, and a queued job can be cancelled before its
# turn.
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

    # One serial gate, four kinds of work: a generator, a drawer, a renderer, or
    # a pipeline runner.
    return run_flux(job) if job.flux?
    return run_plot(job) if job.plot?
    return run_blender(job) if job.blender?
    run_pipeline(job)
  rescue FluxClient::FluxError => e
    fail_job(job, "FLUX: #{e.message}")
  rescue PlotClient::PlotError => e
    fail_job(job, "PLOT: #{e.message}")
  rescue BlenderClient::BlenderError => e
    fail_job(job, "BLENDER: #{e.message}")
  rescue RunnerClient::RunnerError => e
    fail_job(job, e.message)
  rescue StandardError => e
    fail_job(job, "runner connection failed: #{e.message}")
  end

  private

  # The studio-side progress line, for the job page's poll card. Each kind says
  # what it is actually doing: a generator draws a raster for the pipeline, a
  # plot service draws the deliverable, a blender runner renders it, a pipeline
  # runner is dispatched to.
  def activity_line(job)
    return "generating raster…" if job.flux?
    return "drawing plot…" if job.plot?
    return "rendering…" if job.blender?
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
    facts = flux_render_facts(rendered, rasters)
    spec = job.spec.merge("flux" => job.flux_config.merge("rendered" => facts))

    if job.raster_only?
      # Nothing to trace: the picture IS the deliverable. Every variation is
      # kept; the first is the job's primary raster, the rest are previewed on
      # the job page and saveable.
      #
      # There is also no RUNNER here, so there is no prep stage and no
      # source.inverse.png for the job page's source/inverse pair to proxy. The
      # twin is inverted from the raster itself, now, and recorded with the rest
      # of the render facts — one name the page, the popup and the download
      # bundle all read. A raster the inverter cannot read (an unusual PNG)
      # leaves the job complete with no twin; its tile self-hides.
      inverse = FluxInverseTwin.write(File.basename(rasters.first.to_s))
      spec = spec.merge("flux" => spec["flux"].merge("rendered" => facts.merge("inverse" => inverse))) if inverse

      job.update!(spec: spec, input_path: rasters.first.to_s, state: "done",
                  candidate_count: 0, finished_at: Time.current,
                  prep_summary: "flux raster — #{rendered[:name]}")
    else
      # TRACE MODE, and a batch: spec.flux.images > 1 asked the service for
      # several variations and every one of them is stored as an upload — but
      # only the FIRST is handed to the pipeline. `input_path` is rasters.first
      # and exactly ONE pipeline job is created, so one variation is traced and
      # the rest are previewed on the job page (spec[...]["rendered"]["images"])
      # and saveable, never traced.
      #
      # Per-variation tracing is NOT built, deliberately: it would mean one
      # pipeline job per raster and a job record with several traced trees, which
      # is a feature decision rather than a fix. This comment is here so the
      # behaviour is documented instead of being discovered.
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

  # A blender job's render happens HERE, in-process and synchronously, for the
  # same reason a plot job's drawing does: the service takes one document and
  # answers with one frame (or a manifest of them) — no queue and no job to poll
  # — so the worker holds the serial slot for the round trip. Blender is slower
  # than a 2D draw, which is what the client's longer read timeout is for.
  #
  # The frames are stored like any other upload and the job is DONE when they
  # land: a render IS the deliverable, so there are no candidates to gate and no
  # runner to hand anything to.
  def run_blender(job)
    label = blender_runner_for(job)
    raise BlenderClient::Unavailable,
          "no blender runner is configured to render on" unless label

    rendered = BlenderClient.render(Job.runners.fetch(label), job.blender_doc)

    # Cancelled while the service was rendering: drop the frames and store
    # nothing.
    return if job.reload.state != "running"

    stored = store_blender_frames(rendered)
    name = File.basename(stored.first.to_s)

    # The render facts ride under the job's own blender block, beside the
    # document that asked for them, so one record carries both the ask and the
    # answer — the same arrangement a plot job uses.
    job.update!(
      spec: job.spec.merge(
        "blender" => job.blender_config.merge(
          "rendered" => blender_render_facts(job, rendered, stored, name)
        )
      ),
      state: "done", candidate_count: 0, finished_at: Time.current,
      prep_summary: "blender render — #{name}"
    )
  end

  # Which runner renders this job: the blender runner it was filed against when
  # that label IS one (the normal case — Job#blender? asked the same registry),
  # else the first configured blender runner. Nil when the deployment has none,
  # which is the one case RunJob has to report rather than attempt.
  def blender_runner_for(job)
    return job.runner if Job.blender_runner?(job.runner)
    Job.blender_runners.first
  end

  # Every frame the answer carried, written as a normal storage/uploads PNG. A
  # single-view render (views == 1) answers with its frame in the response body;
  # a multi-view one answers with a manifest, and the client has already fetched
  # each of those frames — so this is the same write either way, and a set is
  # never silently reduced to its first element.
  def store_blender_frames(rendered)
    entries = Array(rendered[:entries]).presence || [rendered]
    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    entries.map do |entry|
      dest = uploads.join("blender_#{SecureRandom.hex(6)}.png")
      File.binwrite(dest, entry[:bytes])
      dest
    end
  end

  # The facts worth keeping about a render: the frame that landed and the whole
  # set when the manifest named one, plus the render settings the answer was
  # produced with — size, views and engine — and the exported GLB's name.
  #
  # `views` comes from the ANSWER rather than from the document's render block:
  # the manifest is what actually came back, so it is what is recorded, and a
  # service that answered with more or fewer frames than asked for is visible in
  # the record rather than hidden by it.
  def blender_render_facts(job, rendered, stored, name)
    doc = job.blender_doc || {}
    render = doc["render"].is_a?(Hash) ? doc["render"] : {}
    size = render["size"].is_a?(Hash) ? render["size"] : BlenderConf::DEFAULT_SIZE
    {
      "file" => name,
      "files" => stored.map { |path| File.basename(path.to_s) },
      "service_name" => rendered[:name],
      "frames" => rendered[:frames],
      "size" => size,
      "views" => rendered[:views],
      "engine" => render["engine"].to_s.strip.presence || BlenderConf::DEFAULT_ENGINE,
      "glb" => rendered[:glb],
      "content_type" => rendered[:content_type]
    }
  end

  def run_pipeline(job)
    resp = RunnerClient.create_job(job)
    job.update!(runner_job_id: resp[:id], state: "running")
  end

  # Record the failure on the studio record, so the operator sees the reason.
  #
  # `update_columns` rather than `update!` for one reason: the model validates
  # that a job's runner is one of the CONFIGURED runners, so a job whose runner
  # has since been removed from the deployment fails that validation on every
  # save — and a failure that cannot be written down is a failure nobody can see.
  # This is the one write that has to land regardless; the DB's own constraints
  # still apply, only the model's validations are bypassed.
  def fail_job(job, message)
    return unless job
    job.update_columns(state: "error", error: message, finished_at: Time.current)
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
