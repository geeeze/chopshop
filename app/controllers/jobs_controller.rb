class JobsController < ApplicationController
  before_action :require_login, except: [:login, :authenticate]

  def index
    @jobs = Job.recent.limit(50)
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
          begin
            log_tail = Array(RunnerClient.get_job(@job)[:log_tail])
          rescue RunnerClient::RunnerError
            log_tail = []
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
    # Default to the first real runner when one is configured, else mock. The
    # keys are env-driven (mock is always present; a deployment adds its own via
    # CHOPSHOP_RUNNER_<LABEL>_URL), so this stays host-agnostic while preferring
    # the live pipeline over the local simulation on any box that has one.
    default_runner = Job::RUNNERS.keys.find { |r| r != "mock" } || "mock"
    # A name carried in from the inverse-twin hand-off is a starting point the
    # operator edits, not a commitment — the field stays theirs to change.
    @job = Job.new(runner: default_runner, source_kind: "raster",
                   name: params[:name].presence)
    @carried = params[:carried_from].presence
    @runner_health = Job::RUNNERS.keys.map { |r| [r, RunnerClient.health(Job::RUNNERS[r])] }
  end

  def create
    @job = Job.new(job_params)
    @job.spec = job_spec
    if @job.valid? && @job.spec && @job.save
      resp = RunnerClient.create_job(@job)
      @job.update!(runner_job_id: resp[:id], state: "running")
      redirect_to @job, notice: "Job started."
    else
      flash.now[:alert] = @job.errors.full_messages.to_sentence
      render :new, status: :unprocessable_entity
    end
  rescue StandardError => e
    @job.update(state: "error", error: e.message) if @job.persisted?
    message = e.is_a?(RunnerClient::RunnerError) ? e.message : "runner connection failed: #{e.message}"
    flash.now[:alert] = "Runner unavailable: #{message}"
    @runner_health = Job::RUNNERS.keys.map { |r| [r, RunnerClient.health(Job::RUNNERS[r])] }
    render :new, status: :unprocessable_entity
  end

  def refresh
    @job = Job.find(params[:id])
    @job.sync_from_runner!
    redirect_to @job
  end

  # Ask the runner to stop an in-flight job, then mark it cancelled locally.
  def cancel
    @job = Job.find(params[:id])
    if @job.in_flight?
      begin
        RunnerClient.cancel_job(@job)
      rescue RunnerClient::RunnerError => e
        return respond_cancel_error(e.message)
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
