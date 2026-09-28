class JobsController < ApplicationController
  before_action :require_login, except: [:login, :authenticate]

  def index
    # includes(:validations): each row now links to its proof and renders a
    # proof popup, so without this the list is 50 extra queries.
    @jobs = Job.recent.includes(:validations).limit(50)
    # refresh any in-flight jobs while listing
    @jobs.select { |j| j.runner_job_id && Job::IN_FLIGHT_STATES.include?(j.state) }
         .each(&:sync_from_runner!)
  end

  def show
    @job = Job.find(params[:id])
    @job.sync_from_runner! if Job::IN_FLIGHT_STATES.include?(@job.state)
    @candidates = @job.candidates.order(:hard, :advisory, :id)
    @validations = @job.validations.order(:created_at)

    respond_to do |format|
      format.html
      format.json do
        # Runner log for the "Log" popup (on-demand; the runner holds the log
        # tail in memory, so this works for done jobs too).
        if params[:log].present?
          log_tail = []
          begin
            log_tail = Array(RunnerClient.get_job(@job)[:log_tail])
          rescue RunnerClient::RunnerError
            log_tail = []
          end
          return render json: { log: log_tail }
        end

        # per-candidate detail for the Findings button: the trace sweep entry
        # plus, when a proof exists for it, that proof's manifest.
        if (cf = params[:candidate]).present? && @job.comparison.is_a?(Hash)
          entry = Array(@job.comparison["candidates"]).find { |c| c["file"] == cf.to_s }
          return head :not_found unless entry
          back = @job.validations.where(file: cf.to_s, state: "done")
                         .order(:id).last
          return render json: {
            file: entry["file"],
            job: { id: @job.id, name: @job.name, state: @job.state,
                   runner: @job.runner, created_at: @job.created_at },
            spec: @job.spec,
            sweep: entry,
            proof: back&.manifest
          }
        end

        log_tail = []
        if Job::IN_FLIGHT_STATES.include?(@job.state)
          if @job.runner_job_id.present?
            begin
              log_tail = Array(RunnerClient.get_job(@job)[:log_tail])
            rescue RunnerClient::RunnerError
              log_tail = []
            end
          else
            # queued, or mid-generation on the flux box: there is no runner job
            # yet, so surface the studio-side progress line instead of an empty
            # runner log.
            log_tail = [@job.prep_summary.to_s.presence || "waiting…"]
          end
        end
        render json: {
          done: !Job::IN_FLIGHT_STATES.include?(@job.state),
          log_html: log_tail.map { |l| ERB::Util.html_escape(l) }.join("\n")
        }
      end
    end
  end

  def new
    # Default to the first real PIPELINE runner when one is configured, else
    # mock. A generator is never the default even when it sorts first: the
    # ordinary job is the pipeline, and generating a source is the deliberate
    # choice. The keys are env-driven, so this stays host-agnostic.
    default_runner = Job.pipeline_runners.find { |r| r != "mock" } ||
                     Job.pipeline_runners.first || Job.runners.keys.first
    # A name carried in from the inverse-twin hand-off is a starting point the
    # operator edits, not a commitment — the field stays theirs to change.
    @job = Job.new(runner: default_runner, source_kind: "raster",
                   name: params[:name].presence)
    @carried = params[:carried_from].presence
    assign_form_context
  end

  def create
    @job = Job.new(job_params)
    @job.spec = job_spec
    if @job.spec && @job.flux?
      create_flux_job
    elsif @job.valid? && @job.spec && @job.save
      enqueue_run(@job)
      redirect_to @job, notice: "Job queued."
    else
      create_failed(@job.errors.full_messages.to_sentence)
    end
  rescue FluxClient::FluxError => e
    # The generation never happened, so there is nothing to trace. Persist the
    # reason -- the licence refusal for a non-commercial 9B, most usefully -- so
    # the job page can show it rather than only a flash that scrolls away.
    @job.update(state: "error", error: e.message) if @job.persisted?
    create_failed("FLUX: #{e.message}")
  rescue RunJob::QueueFull => e
    @job.update(state: "error", error: e.message) if @job.persisted?
    create_failed(e.message)
  rescue StandardError => e
    @job.update(state: "error", error: e.message) if @job.persisted?
    message = e.is_a?(RunnerClient::RunnerError) ? e.message : "runner connection failed: #{e.message}"
    create_failed("Runner unavailable: #{message}")
  end

  # A failed create renders the form for a browser but a JSON error for an
  # agent. A bare `render :new` has no JSON template, so an agent posting
  # `Accept: application/json` (a bad flux reference, a full queue) got a 500
  # MissingTemplate instead of the reason. Agents drive this app, so the reason
  # has to travel on the wire.
  def create_failed(alert)
    respond_to do |format|
      format.html do
        flash.now[:alert] = alert
        assign_form_context
        render :new, status: :unprocessable_entity
      end
      format.json { render json: { error: alert }, status: :unprocessable_entity }
    end
  end

  def refresh
    @job = Job.find(params[:id])
    @job.sync_from_runner!
    redirect_to @job
  end

  # Cancel a job. A job waiting in the studio queue (queued, no runner job yet)
  # is discarded before it ever runs — its Solid Queue entry is removed, and
  # RunJob's cooperative check is the backstop. A job already dispatched to a
  # runner (running, or the runner's own queued state, either way with a
  # runner_job_id) is cancelled at that runner.
  def cancel
    @job = Job.find(params[:id])
    if @job.state == "queued" && @job.runner_job_id.blank?
      discard_pending_run(@job)
      @job.update!(state: "cancelled", error: "cancelled by operator", finished_at: Time.current)
    elsif @job.in_flight?
      if @job.runner_job_id.present?
        begin
          RunnerClient.cancel_job(@job)
        rescue RunnerClient::RunnerError => e
          return respond_cancel_error(e.message)
        end
      end
      @job.update!(state: "cancelled", error: "cancelled by operator")
    end
    respond_to do |format|
      format.html { redirect_to jobs_path, notice: "Job cancelled." }
      format.json { head :ok }
    end
  end

  # Take a job's colour-inverted prep twin (source.inverse.png) and offer it as
  # the artwork for a NEW job: fetch it from the runner, store it as a normal
  # upload, and redirect to the new-job form with it already attached, so the
  # operator only has to name the run and start it.
  #
  # It is copied into storage/uploads rather than passed as a runner path on
  # purpose: the twin lives inside the old job's directory, which is deleted with
  # that job, and the uploads dir is the one input location the runner contract
  # already understands. Inverting an image to trace the negative is a normal
  # workflow, and hand-downloading plus re-uploading it was the only way to do it.
  def use_inverse
    job = Job.find(params[:id])
    fetched = RunnerClient.get_file(job.file_url("source.inverse.png"))
    body = fetched[:body].to_s
    unless fetched[:status] == 200 && body.b.start_with?("\x89PNG\r\n\x1a\n".b)
      return redirect_to job, alert: "This job has no inverse twin to reuse — " \
                                     "add print.invert to the spec and re-run the front half to get one."
    end

    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    dest = uploads.join("upload_#{SecureRandom.hex(6)}.png")
    File.binwrite(dest, body)

    redirect_to new_job_path(input_path: dest.to_s,
                             preview_url: upload_preview_jobs_path(name: File.basename(dest)),
                             name: "#{job.name}-inverse",
                             carried_from: job.name)
  rescue RunnerClient::RunnerError => e
    redirect_to job, alert: "Could not fetch the inverse twin: #{e.message}"
  end

  # "Run job again" from a source / inverse PREVIEW popup: carry the previewed
  # raster into a NEW job form, prefilled and with the current job's spec cloned.
  # The same hand-off shape as ScrapbooksController#use (#use_inverse's twin),
  # and deliberately NOT a re-run: nothing is submitted to the runner here, the
  # operator reviews the cloned contract and starts the run themselves.
  #
  # The two files a preview popup offers this for are the source and its
  # colour-inverted twin; those are the only names accepted, so the endpoint
  # cannot be turned into a general "copy any runner file into uploads".
  REUSABLE_FILES = %w[source.png source.inverse.png].freeze

  def reuse
    job = Job.find(params[:id])
    name = params[:name].to_s
    unless REUSABLE_FILES.include?(name)
      return redirect_to job, alert: "Only a source or its inverse twin can be run again."
    end

    fetched = RunnerClient.get_file(job.file_url(name))
    unless fetched[:status] == 200 && fetched[:body].present?
      return redirect_to job, alert: "Could not fetch #{name} (runner #{fetched[:status]})."
    end

    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    dest = uploads.join("upload_#{SecureRandom.hex(6)}#{File.extname(name)}")
    File.binwrite(dest, fetched[:body])

    # Clone the spec: the new-job form's textarea reads session[:spec_draft],
    # the same slot /json/use stashes a built contract into.
    session[:spec_draft] = JSON.pretty_generate(job.spec) if job.spec.is_a?(Hash)

    redirect_to new_job_path(input_path: dest.to_s,
                             preview_url: upload_preview_jobs_path(name: File.basename(dest)),
                             name: reused_name(job, name),
                             carried_from: job.name)
  rescue RunnerClient::RunnerError => e
    redirect_to job, alert: "Could not fetch #{params[:name]}: #{e.message}"
  end

  # Delete a job: tell the runner to drop its files, then remove the record.
  def destroy
    @job = Job.find(params[:id])
    begin
      RunnerClient.delete_job(@job)
    rescue RunnerClient::RunnerError
      # The runner may already be gone; deletion should still succeed locally.
    end
    @job.destroy
    respond_to do |format|
      format.html { redirect_to jobs_path, notice: "Job deleted." }
      format.json { head :ok }
    end
  end

  # Proxy the runner's 7z archive of the whole job (completed jobs only).
  def download
    @job = Job.find(params[:id])
    unless @job.state == "done"
      return redirect_to jobs_path, alert: "Only completed jobs can be downloaded."
    end
    data = RunnerClient.get_file(@job.archive_url, read_timeout: 120)
    unless data[:status] == 200
      return redirect_to jobs_path, alert: "Archive unavailable (runner #{data[:status]})."
    end
    send_data data[:body], filename: "#{@job.stem}.7z",
              type: "application/x-7z-compressed", disposition: "attachment"
  rescue RunnerClient::RunnerError => e
    redirect_to jobs_path, alert: "Archive failed: #{e.message}"
  end

  # proxy candidate/proof/pdf/manifest files from the runner
  def file
    job = Job.find(params[:id])
    name = params[:name].to_s
    unless name.match?(/\A[\w.\-]+\z/)
      return head :bad_request
    end
    fetched = RunnerClient.get_file(job.file_url(name))
    return head fetched[:status] unless fetched[:status] == 200

    send_data fetched[:body],
              filename: name,
              type: fetched[:content_type] || "application/octet-stream",
              disposition: params[:download].present? ? "attachment" : "inline"
  rescue RunnerClient::RunnerError => e
    head :bad_gateway
  end

  # upload endpoint: accept a PNG/JPEG (<= 50MB), store it, return a path
  # the runner can read + a thumbnail for the form.
  def upload
    file = params[:file]
    unless file.respond_to?(:original_filename)
      return redirect_to(new_job_path, alert: "No file received.")
    end

    name = file.original_filename.to_s
    size = File.size(file.tempfile)
    ext = File.extname(name).downcase

    unless %w[.png .jpg .jpeg].include?(ext)
      File.delete(file.tempfile) if File.exist?(file.tempfile)
      return redirect_to(new_job_path, alert: "Only PNG or JPEG, please.")
    end
    if size > 50.megabytes
      File.delete(file.tempfile) if File.exist?(file.tempfile)
      return redirect_to(new_job_path, alert: "50MB limit — that file is #{size / 1.megabyte}MB.")
    end

    # magic-byte check: don't trust the extension
    head = File.open(file.tempfile, "rb") { |f| f.read(10) }
    is_png = head&.bytes&.first(4) == [0x89, 0x50, 0x4E, 0x47]
    is_jpg = head&.bytes&.first(3) == [0xFF, 0xD8, 0xFF]
    unless is_png || is_jpg
      File.delete(file.tempfile) if File.exist?(file.tempfile)
      return redirect_to(new_job_path, alert: "File content doesn't look like PNG or JPEG.")
    end

    slug = SecureRandom.hex(6)
    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    safe_ext = is_png ? ".png" : ".jpg"
    dest = uploads.join("upload_#{slug}#{safe_ext}")
    FileUtils.mv(file.tempfile.to_path, dest)

    # Preview: the browser scales the original inside a tiny tile (CSS
    # max-height ~72px). Served through the login-gated #upload_preview route —
    # storage/uploads is private (the runner reads it via its bind mount), so
    # raw source rasters are NOT reachable under /uploads/ without a session.
    render json: {
      path: dest.to_s,
      preview_url: upload_preview_jobs_path(name: File.basename(dest)),
      name: name, size: size
    }
  rescue StandardError => e
    redirect_to new_job_path, alert: "Upload failed: #{e.message}"
  end

  # Serve a just-uploaded source raster behind the login gate.
  def upload_preview
    name = params[:name].to_s
    return head :bad_request unless name.match?(/\A[\w.\-]+\z/)
    path = Rails.root.join("storage", "uploads", name)
    return head :not_found unless path.file?
    send_file path, disposition: "inline",
              type: { ".png" => "image/png", ".jpg" => "image/jpeg",
                      ".jpeg" => "image/jpeg" }.fetch(File.extname(name).downcase,
                                                      "application/octet-stream")
  end

  private

  # A flux job is a GENERATION first: ask the service for a raster, store the
  # bytes as an upload, and only then does anything pipeline-shaped happen.
  #
  # The studio orchestrates this rather than the flux service growing a
  # runner-contract shim, because other applications call that API too and it
  # should stay a clean standard surface. Nothing about this app reaches the
  # service beyond POST /generate, POST /edit and GET /files/<name>.
  #
  # What gets stored is the same shape #use_inverse already writes (a PNG in
  # storage/uploads), so as far as the pipeline is concerned a generated raster
  # is an ordinary upload.
  #
  # The generation itself runs in RunJob (queued, one at a time) — this method
  # only validates and enqueues, so the POST returns immediately and the job
  # page's poll card can show it move queued → generating → running.
  def create_flux_job
    # The artwork field belongs to the pipeline half of the form, so anything it
    # carries is stale here -- for a flux job the source is what gets generated.
    # It also has to be non-null to save at all (input_path is NOT NULL), and the
    # record is created BEFORE the generation so a refusal is recorded as a job
    # with a reason, exactly as a failed runner connection is, rather than
    # vanishing into a flash.
    @job.input_path = ""
    if @job.flux_config["image"].to_s.strip.present?
      RunJob.validate_reference!(@job.flux_config["image"])
    end

    unless @job.valid? && @job.save
      return create_failed(@job.errors.full_messages.to_sentence)
    end

    enqueue_run(@job)
    redirect_to @job, notice: "Flux job queued for generation."
  end

  # Queue a saved job and remember which Solid Queue entry to discard if the
  # operator cancels it before it runs. Refuses once MAX_QUEUE jobs are already
  # waiting, so the queue can never grow unbounded.
  def enqueue_run(job)
    if Job.where(state: "queued").count >= RunJob::MAX_QUEUE
      raise RunJob::QueueFull,
            "the queue is full (#{RunJob::MAX_QUEUE} jobs waiting) — wait for one to finish or cancel one"
    end
    job.update!(state: "queued", prep_summary: "queued")
    job.update!(active_job_id: RunJob.perform_later(job.id).job_id)
  end

  # Remove a queued job's Solid Queue entry so it never reaches the worker. The
  # cooperative check in RunJob#perform is the backstop if this misses (or the
  # queue adapter is in-memory), so a cancelled job is never dispatched.
  def discard_pending_run(job)
    return unless job.active_job_id.present?
    SolidQueue::Job.find_by(active_job_id: job.active_job_id)&.discard
  rescue StandardError
    nil
  end

  def runner_health_rows
    Job.runners.keys.map { |r| [r, RunnerClient.health(Job.runners[r])] }
  end

  # Everything #new renders, in one place: the form re-renders on every failure
  # path, and a rescue that set only some of these left the page without its
  # runner list.
  def assign_form_context
    @runner_health = runner_health_rows
    # The form shows different fields for a generator than for a pipeline runner,
    # so the label -> kind map goes to the page and the switch happens in the
    # browser rather than by reloading the form on every dropdown change.
    @runner_kinds = Job.runner_kinds
    @handoff_runner = Job.handoff_runner
  end

  # A run-again hand-off names the new job after where the raster came from:
  # the inverse keeps the "-inverse" suffix #use_inverse already gives it, the
  # source keeps the job's own name.
  def reused_name(job, name)
    name.start_with?("source.inverse") ? "#{job.name}-inverse" : job.name
  end

  def respond_cancel_error(message)
    respond_to do |format|
      format.html { redirect_to jobs_path, alert: "Cancel failed: #{message}" }
      format.json { render json: { error: message }, status: :bad_gateway }
    end
  end

  def job_params
    params.require(:job).permit(:name, :source_kind, :input_path, :runner)
  end

  # spec arrives as a JSON string from the form textarea; parse it once here.
  def job_spec
    raw = params.require(:job)[:spec]
    return {} if raw.blank?
    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    nil # triggers the invalid-form branch in #create
  end
end
