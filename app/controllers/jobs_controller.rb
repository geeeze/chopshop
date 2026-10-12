class JobsController < ApplicationController
  include ProjectPicker

  before_action :require_login, except: [:login, :authenticate]

  def show
    @job = Job.find(params[:id])
    # Same reaper as the index, and for the same reason: opening the job is the
    # one moment the operator is looking straight at the row that cannot settle.
    Job.reap_stranded!
    @job.reload
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
    # The runner the form opens on follows the DEFAULT TEMPLATE's KIND, because
    # the contract in the textarea opens on that template: a runner of another
    # kind means the page shows one kind's panel beside another kind's contract.
    # Measured in a browser — when the default became the General job
    # (`generate_only`, a flux template) the form opened on the svg runner and
    # the artwork panel while the spec was a flux generation.
    #
    # This replaces "a generator is never the default even when it sorts first,
    # because the ordinary job is the pipeline". That was right while the default
    # template was a trace preset; the default is a generation now, so the runner
    # follows it rather than arguing with it. The fallbacks keep the old
    # preference (a real pipeline runner over mock) for a box with no runner of
    # the default's kind.
    default_kind = PipelineConf.template_kind(PipelineConf::DEFAULT_TEMPLATE)
    default_runner = Job.form_runners.find { |r| Job.runner_kind(r) == default_kind } ||
                     Job.pipeline_runners.find { |r| r != "mock" } ||
                     Job.form_runners.first
    # A model carried in from the FLUX page. That page's model control
    # configures the generation SERVICE — and its Run Job link was bare, so an
    # operator who picked a hosted model there filed a job that ran the form's
    # own default (klein-4b) and never knew why. Carried as a param it does what
    # it always looked like it did. Validated against the registry: a value the
    # service does not know is dropped rather than posted.
    @flux_model = params[:flux_model].presence
    @flux_model = nil unless @flux_model && FluxConf::MODELS.key?(@flux_model)
    # A carried model means the operator has ALREADY chosen to generate, so the
    # generator is the deliberate choice and its panel (where the model lives)
    # is the one that must be showing. Without this the form opened on the
    # pipeline runner, hid the flux panel, and the carried model was invisible.
    default_runner = Job.flux_runners.first || default_runner if @flux_model
    # A name carried in from the inverse-twin hand-off is a starting point the
    # operator edits, not a commitment — the field stays theirs to change.
    @job = Job.new(runner: default_runner, source_kind: "raster",
                   name: params[:name].presence)
    # A project_id carried in from the project workspace page scopes the new
    # job to that project. The project is owner-scoped, so no cross-user leak.
    @job.project_id = params[:project_id].presence
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
    # The structured prompt composer (issue #50): the slots the form shows. A
    # spec draft may carry a hydrated slot list (spec["prompt_slots"]); a
    # drawn prompt from the DATASETS library arrives as a prompt draft and
    # becomes the FIRST free-text slot, exactly as it filled the whole textarea
    # before the composer existed. With neither, the default thing / location /
    # style trio is the starting layout.
    @prompt_slots = initial_prompt_slots(@spec_draft, @prompt_draft)
    assign_form_context
  end

  def create
    @job = Job.new(job_params)
    @job.spec = job_spec
    project_msg = resolve_form_project!
    return create_failed(project_msg) if project_msg
    # The BP tournament template: the studio runs the sim itself — no runner,
    # no queue — so it is decided BEFORE anything that looks at a runner block
    # or a source raster.
    return create_tournament_job if params[:tournament_source].present?
    # "Random from DiffusionDB": the run's prompt is DRAWN at filing, here,
    # before anything reads it — the typed prompt is deliberately ignored while
    # the source says random, and the provenance lands in the spec.
    source_msg = apply_prompt_source!
    return create_failed(source_msg) if source_msg
    # The structured prompt composer: N slots (free text / boilerplate /
    # dataset) combine into ONE prompt. Runs after the draw because the draw
    # fills flux["prompt"] directly and the composer then overwrites it with
    # the composed string.
    composer_msg = compose_prompt!
    return create_failed(composer_msg) if composer_msg
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
      remember_prompt!(@job)
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
      format.html { redirect_to @job.project_id ? project_path(@job.project_id) : root_path, notice: "Job cancelled." }
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
      format.html { redirect_to @job.project_id ? project_path(@job.project_id) : root_path, notice: "Job deleted." }
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
      return redirect_to @job.project_id ? project_path(@job.project_id) : root_path, alert: "Only completed jobs can be downloaded."
    end
    return download_flux_bundle if @job.flux?
    # A locally-produced job (a compose) has no runner job to archive: it never
    # dispatched anything. Serving the artefact itself is the honest answer, and
    # it is what the operator asked for by pressing download -- asking the runner
    # for an archive of a job it has never heard of is a 404 rendered as a
    # generic failure.
    if @job.locally_produced?
      file = @job.compose_output_file
      return redirect_to @job.project_id ? project_path(@job.project_id) : root_path, alert: "This job has no artefact to download." if file.blank?

      return redirect_to upload_preview_jobs_path(name: file, download: 1)
    end

    data = RunnerClient.get_file(@job.archive_url, read_timeout: RunnerClient::ARCHIVE_READ_TIMEOUT)
    unless data[:status] == 200
      return redirect_to @job.project_id ? project_path(@job.project_id) : root_path, alert: "Archive unavailable (runner #{data[:status]})."
    end
    send_data data[:body], filename: "#{@job.stem}.7z",
              type: "application/x-7z-compressed", disposition: "attachment"
  rescue RunnerClient::RunnerError => e
    redirect_to @job.project_id ? project_path(@job.project_id) : root_path, alert: "Archive failed: #{e.message}"
  rescue FluxArchive::Unavailable => e
    redirect_to @job.project_id ? project_path(@job.project_id) : root_path, alert: "Archive failed: #{e.message}"
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
    # NOTE: this action loads the row into a LOCAL `job` (it does not run the
    # shared loader that sets @job the way #show/#download do), so every
    # redirect below must read `job` — the @job references this action inherited
    # from #download raised NoMethodError on every failure path (found by
    # test/controllers/job_dataset_proxy_test.rb, which pins all three).
    if job.runner_job_id.blank?
      return redirect_to job.project_id ? project_path(job.project_id) : root_path, status: :not_found,
             alert: "This job has no dataset: it never ran on a runner, so no " \
                    "proof of it exists to derive a training set from."
    end

    candidate = params[:candidate].to_s
    return head :bad_request unless candidate.match?(/\A[\w.\-]+\z/)

    data = RunnerClient.dataset_package(job, candidate)
    unless data[:status] == 200
      return redirect_to job.project_id ? project_path(job.project_id) : root_path, alert: "Dataset unavailable (runner #{data[:status]})."
    end
    send_data data[:body],
              filename: "#{RunnerClient.dataset_stem(candidate)}.dataset.7z",
              type: "application/x-7z-compressed", disposition: "attachment"
  rescue RunnerClient::RunnerError => e
    redirect_to job.project_id ? project_path(job.project_id) : root_path, alert: "Dataset failed: #{e.message}"
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
    # The request itself, against FluxConf.validate: a size the model in the box
    # would refuse is a form error HERE, before the job record exists and before
    # a GPU is paid for, rather than a 400 from the service after both. The two
    # reference checks above stay as they are -- this adds the registry's own
    # size rules (each model's floor, step and pixel cap). The licence gate
    # stays the service's; see RunJob.validate_flux_spec! for why.
    RunJob.validate_flux_spec!(@job.spec)

    unless @job.valid? && @job.save
      return create_failed(@job.errors.full_messages.to_sentence)
    end

    remember_prompt!(@job)
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

  # The health of the runners the form OFFERS, not of every configured label:
  # the superseded `plot`/`blender` kinds are no longer selectable, so listing
  # them under the runner dropdown named a label with no option to match it.
  # See Job.form_runners for what "offered" means.
  def runner_health_rows
    Job.form_runners.map { |r| [r, RunnerClient.health(Job.runners[r])] }
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
    # The project picker's options: the operator's own projects. Loaded here
    # (not only in #new) so a create_failed re-render still has them — the
    # prompt must survive the error that proved it necessary.
    @owned_projects = Project.for_owner(Current.user_handle).order(:name)
    # The prompt recall list. Loaded here rather than only in #new, so the
    # refusal re-render (create_failed) still carries it — the popup must not
    # go empty exactly when the operator is being asked to try again.
    @prompt_records = PromptRecord.recent
  end

  # Remember the prompt a run was FILED with, so the form can offer it back.
  #
  # Deliberately after the save and never inside a rescue path: a prompt whose
  # run was refused (an empty draw, a bad reference, a missing project) never
  # reached the service, so recalling it would offer back a prompt that has
  # never once produced anything.
  def remember_prompt!(job)
    flux = job.spec.is_a?(Hash) ? job.spec["flux"] : nil
    return unless flux.is_a?(Hash)

    PromptRecord.remember!(flux["prompt"], source: prompt_origin(job), job_id: job.id)
  rescue StandardError => e
    # The recall list is a convenience. It must never be the reason a run that
    # would otherwise be queued comes back refused.
    Rails.logger.warn("prompt record failed for job #{job.id}: #{e.class}: #{e.message}")
    nil
  end

  # Which door the prompt came through, for the line under it in the list.
  # Checked in the order the create path applies them: a random draw writes
  # `prompt_source` and a composer writes `prompt_slots`, and a run can carry
  # both (the draw fills flux["prompt"], then the composer overwrites it).
  def prompt_origin(job)
    return "typed" unless job.spec.is_a?(Hash)
    return "dataset" if job.spec["prompt_source"].present?
    return "composer" if job.spec["prompt_slots"].present?

    "typed"
  end

  # A run-again hand-off names the new job after where the raster came from:
  # the inverse keeps the "-inverse" suffix #use_inverse already gives it, the
  # source keeps the job's own name.
  def reused_name(job, name)
    name.start_with?("source.inverse") ? "#{job.name}-inverse" : job.name
  end

  def respond_cancel_error(message)
    respond_to do |format|
      format.html { redirect_to @job.project_id ? project_path(@job.project_id) : root_path, alert: "Cancel failed: #{message}" }
      format.json { render json: { error: message }, status: :bad_gateway }
    end
  end

  # The Run Job form asks which project the run belongs to, because a
  # project-less job is listed NOWHERE under the Projects workspace (the
  # redesign's one jobs surface is the per-project page). "Create a new
  # project…" posts job[project_name] — the special select value "__new__"
  # carries no id — so make the project first (owner stamped by the Owned
  # concern, is_test false, the same shape projects#create's form sends) and
  # file the run under it. The HTML form may not file project-less; an agent
  # posting JSON may still omit it, per the agent-api contract. The rule itself
  # lives in ProjectPicker, shared with the composite builder's picker.
  #
  # Returns a message string to render as a failed create, or nil to proceed.
  def resolve_form_project!
    id, error = pick_project(params.require(:job)[:project_id],
                             params.require(:job)[:project_name], what: "run")
    @job.project_id = id
    error
  end

  # The form's PROMPT SOURCE: "Random from DiffusionDB" means the prompt is
  # drawn from the datasets library AT FILING rather than typed — so every
  # filed run can carry a fresh prompt without the operator visiting the
  # library first. Draws server-side: a client-side draw would be a
  # request before the request, and the spec must record which row was used.
  #
  # Returns nil to proceed, or the message for a failed create.
  def apply_prompt_source!
    return nil unless params[:prompt_source].to_s == "random"

    flux = @job.spec.is_a?(Hash) && @job.spec["flux"].is_a?(Hash) ? @job.spec["flux"] : nil
    unless flux
      return "The prompt source draws into a generation job \u2014 this run has " \
             "no generation to draw for."
    end

    topic = params[:prompt_topic].presence
    drawn = PromptSource.draw(topic: topic)
    if drawn.nil?
      # A nil draw has THREE causes and they need different remedies, so the
      # message names the one that actually happened. Reporting every nil as
      # "the library is empty" told an operator with 60,000 loaded rows that
      # nothing was loaded -- measured 2026-10-11, and it was filed as the
      # library being broken rather than as a typo in an exact-match filter.
      return "The prompt library is empty \u2014 ingest it before drawing from it." if PromptSource.count.zero?
      if topic
        return "No prompt in the library matches topic #{topic.inspect} \u2014 the " \
               "topic is an exact match against the library's own labels. Clear " \
               "the box to draw from the whole library."
      end
      return "No prompt in the library could be drawn \u2014 it has rows, but " \
             "none are drawable."
    end

    flux["prompt"] = drawn.prompt
    @job.spec["prompt_source"] = {
      "dataset" => drawn.dataset, "id" => drawn.id,
      "topic" => drawn.topic, "provenance" => drawn.provenance
    }
    nil
  end

  # The STRUCTURED PROMPT COMPOSER (issue #50): the form posts N slots, each
  # free text, a boilerplate key, or a dataset draw. Composed into ONE prompt
  # HERE, at filing — the same place the prompt source draws — so the spec's
  # flux["prompt"] is the composed string and spec["prompt_slots"] records the
  # structure that produced it.
  #
  # Returns nil to proceed, or the message for a failed create.
  def compose_prompt!
    return nil unless params[:prompt_slots].present?

    flux = @job.spec.is_a?(Hash) && @job.spec["flux"].is_a?(Hash) ? @job.spec["flux"] : nil
    unless flux
      return "The prompt composer builds a generation prompt — this run has " \
             "no generation to compose for."
    end

    raw = params[:prompt_slots]
    raw = JSON.parse(raw) if raw.is_a?(String)
    slots = PromptComposer.normalize(raw)
    composed = PromptComposer.compose(slots)
    return "The prompt composer needs at least one filled slot — " \
           "describe something, pick a boilerplate, or draw from the dataset." if composed.blank?

    flux["prompt"] = composed
    @job.spec["prompt_slots"] = slots
    nil
  end

  # The slots the form opens with: a hydrated list from the spec draft, a
  # drawn prompt as the first free-text slot (the datasets#use hand-off), or
  # the default thing / location / style trio.
  def initial_prompt_slots(spec_draft, prompt_draft)
    if spec_draft.present?
      begin
        parsed = JSON.parse(spec_draft)
        return parsed["prompt_slots"] if parsed.is_a?(Hash) && parsed["prompt_slots"].is_a?(Array)
      rescue JSON::ParserError
        # a spec draft that is not JSON: fall through to the defaults
      end
    end
    slots = PromptComposer::DEFAULT_SLOTS.map { |s| { "label" => s["label"] } }
    if prompt_draft.present?
      slots.first["text"] = prompt_draft
    end
    slots
  end

  # The BP TOURNAMENT template's create: a SIMULATED single-elimination
  # bracket the studio runs ITSELF — no runner, no dispatch, no queue (the
  # same rule TournamentSim exists under: it decides nothing, and the job page
  # says SIMULATED exactly as /tournament does). The request is validated here
  # rather than by a kind validator — there is no runner block to validate —
  # and the whole simulation is deterministic in the seed: the same prompt
  # yields the same bracket, and a job page's "view bracket" link (entrants +
  # seed back to /tournament) reproduces it.
  def create_tournament_job
    source = params[:tournament_source].to_s
    unless %w[prompt memes].include?(source)
      return create_failed("A tournament's entrant source is prompt or meme seeds.")
    end

    prompt = params[:tournament_prompt].to_s.strip
    if source == "prompt" && prompt.blank?
      return create_failed(
        "A prompt tournament needs a prompt \u2014 describe the bracket's seed, " \
        "or switch the source to random meme seeds."
      )
    end

    count = (params[:tournament_entrants].presence || "8").to_i.clamp(2, 32)
    if source == "memes"
      field = MemeVocabulary.random_entrants(count)
      seed = params[:tournament_seed].presence || SecureRandom.hex(8)
    else
      # The prompt IS the seed: a specific prompt yields a specific bracket
      # (score_for derives from the seed string), so two filings of one prompt
      # are the same tournament, visibly different from another prompt's.
      field = TournamentSim::DEFAULT_ENTRANTS.first(count)
      seed = params[:tournament_seed].presence || prompt
    end

    # Layout derived exactly as load_tournament derives it — same threshold,
    # same probe — so the job page's bracket link renders the same geometry.
    probe = TournamentSim.new(field, seed: seed, layout: :ltr)
    layout = probe.size >= TournamentSim::MIRROR_THRESHOLD ? :mirror : :ltr
    sim = TournamentSim.new(field + [TournamentSim::MEME_NAME], seed: seed, layout: layout)
    champion = sim.champion # runs the sim; fills outcomes in round order

    @job.spec = {
      "tournament" => {
        "simulated" => true,
        "source" => source,
        "prompt" => (prompt if source == "prompt"),
        "seed" => seed,
        "layout" => layout.to_s,
        # The FIELD, not the padded participants: /tournament appends the meme
        # entrant itself, so this exact array posted back to the page
        # reproduces the bracket this job ran.
        "entrants" => field,
        "rounds" => sim.rounds,
        "champion" => champion,
        "outcomes" => sim.outcomes.map do |o|
          { "round" => o.round + 1, "index" => o.index, "a" => o.a, "b" => o.b,
            "winner" => o.winner, "note" => o.note }
        end
      }
    }
    @job.source_kind = params[:source_kind].presence || "raster"
    @job.input_path = ""
    @job.state = "done"
    @job.prep_summary = "simulated bracket \u2014 #{field.size + 1} entrants, " \
                         "#{sim.rounds} rounds"

    if @job.valid? && @job.save
      redirect_to @job,
                  notice: "Tournament simulated \u2014 #{sim.rounds} rounds, " \
                          "champion: #{champion}."
    else
      create_failed(@job.errors.full_messages.to_sentence)
    end
  end

  def job_params
    params.require(:job).permit(:name, :source_kind, :input_path, :runner, :project_id)
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
        return redirect_to @job.project_id ? project_path(@job.project_id) : root_path, alert: "Archive unavailable (runner #{fetched[:status]})."
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
