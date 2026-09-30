class JobsController < ApplicationController
  before_action :require_login, except: [:login, :authenticate]

  # How many runs ONE PAGE of the index holds. The list and the grid are the
  # same page -- the head toggle swaps two wrappers, it never refetches -- so a
  # single window serves both views and the infinite scroll appends to whichever
  # one is on screen. Kept at the size the index used to be unbounded at, so the
  # first paint is unchanged for anyone who never scrolls.
  PER_PAGE = 50

  def index
    # includes(:validations): each row links to its proof and renders a proof
    # popup, so without this the list is PER_PAGE extra queries.
    scope = Job.recent.includes(:validations)
    # A junk or negative page is page 1, not a negative OFFSET: `params[:page]`
    # is a string, and `-1 * 50` is a query that raises rather than a page.
    @page = [params[:page].to_i, 1].max
    @jobs = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    # The scroll sentinel's whole contract. Counted on the SAME scope (so owner
    # scoping cannot disagree with the rows), and only when the page came back
    # full -- a short page is the last one by definition and costs no COUNT.
    @has_more = @jobs.size == PER_PAGE && @page * PER_PAGE < Job.recent.count
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
                     Job.pipeline_runners.first || Job.job_runners.first
    # A name carried in from the inverse-twin hand-off is a starting point the
    # operator edits, not a commitment — the field stays theirs to change.
    @job = Job.new(runner: default_runner, source_kind: "raster",
                   name: params[:name].presence)
    @carried = params[:carried_from].presence
    # A prompt drawn from the DATASETS library rides in on a DRAFT, exactly like
    # a JSON spec draft rides in as the textarea's default: a starting point the
    # operator edits, never a committed value. It is a draft and not the session
    # because a prompt is unbounded text and the session is a 4 KB cookie (see
    # SessionDraft).
    @spec_draft = draft_body(params[:spec_draft_token], SessionDraft::SPEC)
    prompt_draft = SessionDraft.fetch(params[:prompt_draft_token], kind: SessionDraft::PROMPT)
    @prompt_draft = prompt_draft&.body.presence
    @prompt_draft_source = prompt_draft&.source.presence
    assign_form_context
  end

  def create
    @job = Job.new(job_params)
    @job.spec = job_spec
    normalize_plot_documents
    normalize_blender_documents
    normalize_bp_documents
    blank_document_source!
    # A trace job's source must be a raster, checked HERE because this is the one
    # door every real job comes through: the Run Job form, the composite and
    # inverse/reuse hand-offs that prefill it, and an agent posting the contract
    # over HTTP. `runner_kind` and the FILE decide it — never `source_kind`, which
    # every one of the failed jobs carried as "raster" while pointing at an SVG.
    if trace_source_refused?(@job)
      return create_failed(Job.trace_source_refusal(@job.input_path))
    end
    if @job.spec && @job.flux?
      create_flux_job
    elsif @job.valid? && @job.spec && @job.save
      # A plot job is saved and queued like any other: its whole request rides
      # in the spec, so it needs no generation step and no hand-off. RunJob does
      # the drawing, and the model's validation has already refused an op or a
      # document that is missing.
      enqueue_run(@job)
      redirect_to @job, notice: "Job queued."
    else
      create_failed(@job.errors.full_messages.to_sentence)
    end
  rescue FluxClient::FluxError => e
    # The generation never happened, so there is nothing to trace. Persist the
    # reason -- the licence refusal for a non-commercial model, most usefully -- so
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

    # Clone the spec through a DRAFT, not the session: the session is a cookie
    # and a job's spec outgrew it (measured: up to 15,816 bytes against a 4 KB
    # cookie, which raised CookieOverflow while committing this response's
    # cookie — a 500 on a request that had already answered 302). See
    # SessionDraft; the hand-off now carries a token.
    spec_token = SessionDraft.store(kind: SessionDraft::SPEC,
                                    body: JSON.pretty_generate(job.spec)) if job.spec.is_a?(Hash)

    redirect_to new_job_path(input_path: dest.to_s,
                             preview_url: upload_preview_jobs_path(name: File.basename(dest)),
                             name: reused_name(job, name),
                             carried_from: job.name,
                             spec_draft_token: spec_token)
  rescue RunnerClient::RunnerError => e
    redirect_to job, alert: "Could not fetch #{params[:name]}: #{e.message}"
  end

  # Delete a job: tell the runner to drop its files, then remove the record.
  def destroy
    @job = Job.find(params[:id])
    #event-log-record: log the DELETE before the row goes. job_id is provenance
    # only (no FK — see Event), so the event outlives the job it describes; the
    # payload keeps the identifying detail the deleted row no longer can.
    Event.record(event: "delete", job_id: @job.id,
                 payload: { name: @job.name, state: @job.state, runner: @job.runner })
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

  # Download a completed job, whole.
  #
  # A pipeline job's archive is the runner's and is proxied exactly as before. A
  # FLUX job's is not: how the raster was drawn — the prompt, the model and size,
  # the seed, the reference it was edited from — is the STUDIO's knowledge. The
  # runner was handed a raster and never saw the generation, so its archive
  # cannot carry the provenance. The studio therefore builds its own 7z and, in
  # trace mode, carries the runner's archive inside it as pipeline.7z. See
  # FluxArchive for the layout and why the runner's archive rides along whole.
  def download
    @job = Job.find(params[:id])
    unless @job.state == "done"
      return redirect_to jobs_path, alert: "Only completed jobs can be downloaded."
    end
    return download_flux_bundle if @job.flux?
    # A locally-produced job (a compose) has no runner job to archive: it never
    # dispatched anything. Serving the artefact itself is the honest answer, and
    # it is what the operator asked for by pressing download -- asking the runner
    # for an archive of a job it has never heard of is a 404 rendered as a
    # generic failure.
    if @job.locally_produced?
      file = @job.compose_output_file
      return redirect_to jobs_path, alert: "This job has no artefact to download." if file.blank?

      return redirect_to upload_preview_jobs_path(name: file, download: 1)
    end

    data = RunnerClient.get_file(@job.archive_url, read_timeout: RunnerClient::ARCHIVE_READ_TIMEOUT)
    unless data[:status] == 200
      return redirect_to jobs_path, alert: "Archive unavailable (runner #{data[:status]})."
    end
    send_data data[:body], filename: "#{@job.stem}.7z",
              type: "application/x-7z-compressed", disposition: "attachment"
  rescue RunnerClient::RunnerError => e
    redirect_to jobs_path, alert: "Archive failed: #{e.message}"
  rescue FluxArchive::Unavailable => e
    redirect_to jobs_path, alert: "Archive failed: #{e.message}"
  end

  # Download a proof's TRAINING SET: the runner's on-demand 7z of the variants it
  # derived from that proof when the run asked for them (`validation.variants`).
  #
  # Proxied exactly as #download proxies the archive — same RunnerError surface,
  # same alert-on-failure — because it is the same kind of call: an archive the
  # runner BUILDS while the caller waits. It is slower than the job archive (a
  # dozen-plus derived rasters and their vector twins), which is what the
  # client's dataset timeout is for.
  #
  # A job with no runner job has no dataset and never can: it never ran, so
  # nothing was proved. That is answered with a 404 carrying the reason rather
  # than by building a URL out of a nil id. The status is the load-bearing part —
  # no page links here for such a job (a raster-only flux job has no proof page),
  # so the flash is for the agent or the hand-typed URL, not for a browser to
  # follow.
  def dataset
    job = Job.find(params[:id])

    # The no-runner check comes FIRST, and that order is the point: a job that
    # never ran on a runner has no proof to derive anything from, so THAT is the
    # reason to give, whether or not the caller happened to name a candidate. With
    # the candidate check first, a bare `/jobs/:id/dataset` on such a job answered
    # 400 for a missing parameter instead of the 404-with-the-reason this action
    # is written to return.
    if job.runner_job_id.blank?
      return redirect_to jobs_path, status: :not_found,
             alert: "This job has no dataset: it never ran on a runner, so no " \
                    "proof of it exists to derive a training set from."
    end

    candidate = params[:candidate].to_s
    return head :bad_request unless candidate.match?(/\A[\w.\-]+\z/)

    data = RunnerClient.dataset_package(job, candidate)
    unless data[:status] == 200
      return redirect_to jobs_path, alert: "Dataset unavailable (runner #{data[:status]})."
    end
    send_data data[:body],
              filename: "#{RunnerClient.dataset_stem(candidate)}.dataset.7z",
              type: "application/x-7z-compressed", disposition: "attachment"
  rescue RunnerClient::RunnerError => e
    redirect_to jobs_path, alert: "Dataset failed: #{e.message}"
  end

  # proxy candidate/proof/pdf/manifest files from the runner
  #
  # `candidate` switches the read to a proof's DATASET directory. ONLY the
  # per-transform variants need it: the runner keeps them one level deeper, in
  # `<stem>.dataset/raster|vector/<name>`, served through a FOUR-segment route
  # `/files/<job>/<stem>.dataset/<name>` rather than the three-segment one every
  # other file call uses.
  #
  # The dataset's three FLAT names -- `<stem>.dataset.json`,
  # `<stem>.dataset.md` and `<stem>.dataset-contact-sheet.png` -- deliberately do
  # NOT need it. The runner puts them at the JOB ROOT so the existing
  # three-segment route resolves them, which is why the proof page requests them
  # by name alone. Passing `candidate:` for one of those builds a nested path the
  # runner has nothing at, and the file 404s.
  #
  # Nothing else about this action changes: the same name gate, the same
  # inline/attachment switch, the same proxy, so a dataset file opens in the
  # glass popup and can be favourited exactly like a proof render.
  def file
    job = Job.find(params[:id])
    name = params[:name].to_s
    unless name.match?(/\A[\w.\-]+\z/)
      return head :bad_request
    end
    candidate = params[:candidate].to_s
    unless candidate.blank? || candidate.match?(/\A[\w.\-]+\z/)
      return head :bad_request
    end

    url = candidate.present? ? RunnerClient.dataset_file(job, candidate, name) : job.file_url(name)
    fetched = RunnerClient.get_file(url)
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
                      ".jpeg" => "image/jpeg", ".svg" => "image/svg+xml" }
                    .fetch(File.extname(name).downcase, "application/octet-stream")
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
    # Every reference, not just the singular key: a hand-edited contract can
    # carry a list, and it is held to the SAME containment rule before anything
    # is enqueued. `flux_reference_names` is the read side (basename only);
    # this is the refusing side, and between them a path out of
    # storage/uploads cannot reach the service through either key.
    RunJob.validate_references!(@job.flux_reference_spec_values) if @job.flux?

    unless @job.valid? && @job.save
      return create_failed(@job.errors.full_messages.to_sentence)
    end

    enqueue_run(@job)
    redirect_to @job, notice: "Flux job queued for generation."
  end

  # Queue a saved job and remember which Solid Queue entry to discard if the
  # operator cancels it before it runs.
  #
  # Two gates, in order. The PRIMARY one is per user: a job's owner is stamped
  # from the signed-in handle, so an operator's five queued jobs are their own
  # allotment and a busy desk cannot be held up by someone else's backlog. The
  # global MAX_QUEUE behind it protects the BOX rather than a user -- it is the
  # backstop that stops one pathological user (or a bug in the per-user count)
  # from starving the single worker.
  def enqueue_run(job)
    waiting_for_you = Job.unscoped.where(state: "queued", owner: job.owner).count
    if waiting_for_you >= RunJob::MAX_QUEUE_PER_USER
      raise RunJob::QueueFull,
            "the queue is full (#{RunJob::MAX_QUEUE_PER_USER} jobs waiting for you) — " \
            "wait for one to finish or cancel one"
    end
    if Job.unscoped.where(state: "queued").count >= RunJob::MAX_QUEUE
      raise RunJob::QueueFull,
            "the studio queue is full (#{RunJob::MAX_QUEUE} jobs waiting) — " \
            "wait for one to finish or cancel one"
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

  # Whether this job is a trace job asking to be fed something the trace stage
  # cannot open. Asked of the KIND and the FILE: a chain's own artwork is checked
  # per step (where the message can name the step), and a blank input is left to
  # the existing "needs an artwork source" rules.
  def trace_source_refused?(job)
    return false if job.sequenced?
    return false unless Job.runner_kind(job.runner) == "svg"
    path = job.input_path.to_s.strip
    return false if path.blank?

    !Job.raster_source?(path)
  end

  # A plot or blender job has no source RASTER to point at -- the document in its
  # spec IS the request -- and input_path is NOT NULL, so a blank one is stored
  # as the empty string. The form already posts one (the artwork field belongs to
  # the pipeline half and is hidden for both kinds), but an agent posting the job
  # straight to this endpoint need not, and a NOT NULL failure surfacing as
  # "runner connection failed" is no way to be told.
  def blank_document_source!
    @job.input_path = "" if (@job.plot? || @job.blender?) && @job.input_path.blank?
  end

  # A plot job's request rides in the spec exactly as a flux job's does, and the
  # form composes it already parsed. An agent -- or a hand-edited contract -- may
  # instead paste the operation's document, or its run records, as a JSON STRING,
  # so parse those once here and hand the model (and RunJob) the objects they
  # expect. A string that does not parse is left where it was, and the model's
  # validation refuses the job with the reason.
  def normalize_plot_documents
    plot = @job.spec.is_a?(Hash) ? @job.spec["plot"] : nil
    return unless plot.is_a?(Hash)
    %w[doc runs].each do |key|
      value = plot[key]
      next unless value.is_a?(String) && value.present?
      plot[key] = JSON.parse(value)
    end
  rescue JSON::ParserError
    nil
  end

  # The blender half of the same rule: a blender job carries ONE document (the
  # geometry), and a pasted one arrives as a JSON string for exactly the same
  # reason. Parsed once here, so the model's validation and RunJob both read a
  # Hash; a string that does not parse is left where it was and the validation
  # refuses the job with the reason.
  def normalize_blender_documents
    blender = @job.spec.is_a?(Hash) ? @job.spec["blender"] : nil
    return unless blender.is_a?(Hash)
    value = blender["doc"]
    return unless value.is_a?(String) && value.present?
    blender["doc"] = JSON.parse(value)
  rescue JSON::ParserError
    nil
  end

  # The BP action's document and run records: the third half of the same rule, and
  # absent until now -- which meant a bp job whose `doc` arrived as a JSON string
  # (how an agent or a hand-edited contract sends it, since the form parses it in
  # the browser) was refused by the model's own validation with
  # "a BP job needs a document", even though the document was right there as text.
  # Parsed once here, so validation, the worker and every page read a Hash.
  def normalize_bp_documents
    bp = @job.spec.is_a?(Hash) ? @job.spec["bp"] : nil
    return unless bp.is_a?(Hash)
    %w[doc runs].each do |key|
      value = bp[key]
      next unless value.is_a?(String) && value.present?
      bp[key] = JSON.parse(value)
    end
  rescue JSON::ParserError
    nil
  end

  # The flux bundle: the studio's provenance 7z, plus — in trace mode — the
  # runner's own archive and the runner's inverse twin.
  #
  # The runner archive is the one runner read that is NOT best-effort: a
  # trace-mode bundle without its pipeline half would be a quietly partial
  # download, which is worse than the alert a pipeline job already gives. The
  # inverse twin is best-effort, because pipeline.7z already carries it.
  def download_flux_bundle
    pipeline = nil
    if @job.runner_job_id.present?
      fetched = RunnerClient.get_file(@job.archive_url, read_timeout: RunnerClient::ARCHIVE_READ_TIMEOUT)
      unless fetched[:status] == 200
        return redirect_to jobs_path, alert: "Archive unavailable (runner #{fetched[:status]})."
      end
      pipeline = fetched[:body]
    end

    body = FluxArchive.new(@job).build(pipeline_body: pipeline,
                                       inverse_body: runner_inverse_twin)
    send_data body, filename: "#{@job.stem}.7z",
              type: "application/x-7z-compressed", disposition: "attachment"
  end

  # The runner's colour-inverted twin for a trace-mode flux job: prep writes it
  # and the job page proxies it, so the bundle carries the same file rather than
  # a second, locally-inverted one that might disagree with what the operator
  # sees. Nil when the runner will not serve it — pipeline.7z holds it anyway.
  def runner_inverse_twin
    return nil if @job.runner_job_id.blank?
    fetched = RunnerClient.get_file(@job.file_url("source.inverse.png"))
    fetched[:status] == 200 ? fetched[:body] : nil
  rescue RunnerClient::RunnerError
    nil
  end
end
