# The scrapbook: the operator's own store of favourited sources, inverts,
# candidates and proofs, browsed from the left sidebar. Every action here is
# login-gated; the store is deliberately independent of Job so it survives the
# jobs its contents came from.
class ScrapbooksController < ApplicationController
  before_action :require_login

  CONTENT_TYPES = {
    ".svg"  => "image/svg+xml",
    ".png"  => "image/png",
    ".jpg"  => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".pdf"  => "application/pdf"
  }.freeze

  def index
    items = ScrapbookItem.recent.limit(200).map { |i| item_json(i) }
    render json: items
  end

  # Favourite a runner artifact: fetch its bytes through the job's file proxy
  # and COPY them into storage/scrapbook. A copy, not a reference, because the
  # whole requirement is that the scrapbook survives deleting the job.
  def create
    job = Job.find(params[:job_id])
    name = params[:name].to_s
    unless name.match?(/\A[\w.\-]+\z/)
      return render json: { error: "bad filename" }, status: :bad_request
    end

    fetched = RunnerClient.get_file(job.file_url(name))
    unless fetched[:status] == 200 && fetched[:body].present?
      return render json: { error: "runner could not serve #{name} (#{fetched[:status]})" },
                    status: :bad_gateway
    end

    body = fetched[:body]
    sha = Digest::SHA256.hexdigest(body)

    # Content dedupe: the digest is the artifact's identity, so bytes this
    # operator already has need no second copy. The fetch above still happened
    # (it is what produced the digest), but nothing else does — and no star
    # event is appended, because the judgement was already recorded on the copy
    # that exists.
    if (dup = duplicate_of(sha))
      return render json: item_json(dup).merge(duplicate: true), status: :ok
    end

    ext = File.extname(name).downcase
    kind = kind_from_name(name)
    stored = "#{kind}_#{SecureRandom.hex(6)}#{ext}"
    dir = Rails.root.join("storage", "scrapbook")
    dir.mkpath
    File.binwrite(dir.join(stored), body)

    # Checksum at creation: the digest of the exact bytes just stored, kept on
    # the row so the scrapbook copy is identifiable by content (its runner name
    # belongs to a job that may be deleted) and the event log can carry it.
    item = ScrapbookItem.create!(name: name, kind: kind, file: stored,
                                 job_id: job.id, sha256: sha)
    #event-log-record: a favourite IS the operator's judgement on an artifact —
    # the star, with the position it held on the ordered candidate list.
    Event.record(event: "star", job_id: job.id, svg_sha: item.sha256,
                 pos: Event.position_of(job, name),
                 payload: { name: name, kind: kind })
    render json: item_json(item), status: :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: "job not found" }, status: :not_found
  rescue RunnerClient::RunnerError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # Serve a stored scrapbook file behind the login gate (storage/scrapbook is
  # private, like storage/uploads).
  def file
    item = ScrapbookItem.find(params[:id])
    path = item.stored_path
    return head :not_found unless path.file?

    send_file path, disposition: "inline",
              type: CONTENT_TYPES.fetch(File.extname(item.file).downcase,
                                        "application/octet-stream")
  end

  def destroy
    item = ScrapbookItem.find(params[:id])
    path = item.stored_path
    # Capture the provenance BEFORE the row goes: the event log's whole job is
    # to outlive the things it describes.
    provenance = { job_id: item.job_id, svg_sha: item.sha256,
                   name: item.name, kind: item.kind }
    item.destroy
    File.delete(path) if path.file?
    #event-log-record: unfavouriting is a NEGATIVE signal on the same artifact —
    # the position it held is gone with the job's candidate list, so pos stays
    # nil and the payload says which artifact it was.
    Event.record(event: "unstar", job_id: provenance[:job_id],
                 svg_sha: provenance[:svg_sha],
                 payload: provenance.slice(:name, :kind))
    head :ok
  end

  # "Trace it": copy a scrapbook item into storage/uploads and hand it to the
  # new-job form as the artwork. The runner only reads uploads, so the scrapbook
  # copy has to become a real upload first — the same carry the inverse twin
  # does, and the same redirect shape.
  def use
    item = ScrapbookItem.find(params[:id])
    path = item.stored_path
    unless path.file?
      return redirect_to scrapbook_path, alert: "That item's file is missing."
    end

    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    dest = uploads.join("upload_#{SecureRandom.hex(6)}#{File.extname(item.file)}")
    FileUtils.cp(path, dest)

    #event-log-record: trace-it is a PICK — the operator chose this artifact to
    # carry forward. Logged before the hand-off redirect; the job is looked up
    # best-effort because the favourite may outlive it.
    Event.record(event: "pick", job_id: item.job_id, svg_sha: item.sha256,
                 pos: Event.position_of(Job.find_by(id: item.job_id), item.name),
                 payload: { name: item.name, kind: item.kind, via: "scrapbook" })

    redirect_to new_job_path(input_path: dest.to_s,
                             preview_url: upload_preview_jobs_path(name: File.basename(dest)),
                             name: item.name.to_s.sub(/\.[^.]+\z/, ""),
                             carried_from: "scrapbook")
  end

  # Copy a scrapbook item into uploads so a DROP onto the Run Job page can use it
  # as the job's artwork.
  #
  # Deliberately not `#reference`: that one requires a raster, because a flux
  # reference travels inside an edit request as a data URI, while a job's SOURCE
  # may be an SVG the pipeline traces. And not `#use`, which REDIRECTS to the
  # new-job form: a drop happens on a form the operator may already have filled
  # in, so it has to answer JSON and let the page place the file, exactly as the
  # tile's own upload flow does.
  def artwork
    item = ScrapbookItem.find(params[:id])
    path = item.stored_path
    return render json: { error: "That item's file is missing." }, status: :not_found unless path.file?

    ext = File.extname(item.file.to_s).downcase
    # A job's source is a RASTER. An SVG artefact is still a legitimate thing to
    # keep in the scrapbook (a traced candidate, a flattened composite, a plot),
    # but it cannot be a job's artwork: the trace stage preps the source with PIL,
    # which has no SVG reader. This route used to accept one, which is how a
    # vector-flattened composite ended up in the runner as an
    # `UnidentifiedImageError`. The refusal is the SAME sentence the model's
    # validation uses, so both routes speak with one voice.
    unless Job.raster_source?(item.file.to_s)
      return render json: { error: Job.trace_source_refusal(item.file.to_s) },
                    status: :unprocessable_entity
    end

    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    dest = uploads.join("upload_#{SecureRandom.hex(6)}#{ext}")
    FileUtils.cp(path, dest)

    render json: {
      path: dest.to_s,
      preview_url: upload_preview_jobs_path(name: File.basename(dest)),
      name: item.name,
      size: File.size(dest),
      # Kept for the page's benefit, and honest: this route only accepts what the
      # trace stage can read, so the kind is always the raster one.
      source_kind: "raster"
    }
  end

  # Copy a scrapbook item into storage/uploads so it can be a FLUX reference
  # image (the edit input). Raster only: a reference is an image the generator
  # transforms, so SVG/PDF items are refused with a clear error. Returns the
  # same JSON the upload endpoint does, so the reference field's drop handler
  # can consume it unchanged.
  def reference
    item = ScrapbookItem.find(params[:id])
    path = item.stored_path
    return render json: { error: "That item's file is missing." }, status: :not_found unless path.file?

    head = File.open(path, "rb") { |f| f.read(10) }
    is_png = head&.bytes&.first(4) == [0x89, 0x50, 0x4E, 0x47]
    is_jpg = head&.bytes&.first(3) == [0xFF, 0xD8, 0xFF]
    unless is_png || is_jpg
      return render json: { error: "A reference image must be a PNG or JPEG — this item is not a raster." },
                    status: :unprocessable_entity
    end

    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    safe_ext = is_png ? ".png" : ".jpg"
    dest = uploads.join("upload_#{SecureRandom.hex(6)}#{safe_ext}")
    FileUtils.cp(path, dest)

    render json: {
      path: dest.to_s,
      preview_url: upload_preview_jobs_path(name: File.basename(dest)),
      name: item.name,
      size: File.size(dest)
    }
  end

  # Import a raw image (an edited scrape exported by the sidebar's canvas editor)
  # as a new scrapbook item. The bytes are validated by magic number, not the
  # client-supplied name, and always stored as a PNG/JPEG — an edited scrape is
  # raster by definition.
  def import
    file = params[:file]
    unless file.respond_to?(:original_filename)
      return render json: { error: "no file received" }, status: :bad_request
    end

    head = File.open(file.tempfile, "rb") { |f| f.read(10) }
    is_png = head&.bytes&.first(4) == [0x89, 0x50, 0x4E, 0x47]
    is_jpg = head&.bytes&.first(3) == [0xFF, 0xD8, 0xFF]
    unless is_png || is_jpg
      File.delete(file.tempfile) if File.exist?(file.tempfile)
      return render json: { error: "not a PNG or JPEG" }, status: :bad_request
    end

    # Checksum at creation: digest the bytes BEFORE the tempfile is moved away.
    sha = Digest::SHA256.file(file.tempfile.to_path).hexdigest

    # Content dedupe (see #create): these exact bytes are already stored, so the
    # export is dropped — the tempfile goes with it, and the unit has no second
    # copy to leak.
    if (dup = duplicate_of(sha))
      File.delete(file.tempfile) if File.exist?(file.tempfile)
      return render json: item_json(dup).merge(duplicate: true), status: :ok
    end

    ext = is_png ? ".png" : ".jpg"
    stored = "edit_#{SecureRandom.hex(6)}#{ext}"
    dir = Rails.root.join("storage", "scrapbook")
    dir.mkpath
    FileUtils.mv(file.tempfile.to_path, dir.join(stored))

    item = ScrapbookItem.create!(name: stored, kind: "upload", file: stored,
                                 sha256: sha)
    render json: item_json(item), status: :created
  end

  # Save a LOCAL upload (a generated flux raster) to the scrapbook. The normal
  # #create fetches through the runner's file proxy, but a generated raster lives
  # in storage/uploads and has no runner job behind it — so it is copied straight
  # from there. Only a flat basename that resolves inside storage/uploads is
  # honoured, never a path.
  def save_upload
    name = params[:name].to_s
    unless name.match?(/\A[\w.\-]+\z/)
      return render json: { error: "bad filename" }, status: :bad_request
    end

    src = Rails.root.join("storage", "uploads", name)
    unless src.file? && src.to_s.start_with?(Rails.root.join("storage", "uploads").to_s + File::SEPARATOR)
      return render json: { error: "not a stored upload" }, status: :not_found
    end

    # Checksum at creation: the stored upload's bytes, digested here so the
    # scrapbook copy carries its own content id from the moment it exists.
    sha = Digest::SHA256.file(src.to_s).hexdigest

    # Content dedupe (see #create): the same generated raster saved twice is one
    # item. The HTML form gets a notice saying so, the JSON caller the flag.
    if (dup = duplicate_of(sha))
      return respond_to do |format|
        format.html { redirect_back fallback_location: scrapbook_path, notice: "Already in the scrapbook: #{dup.name}." }
        format.json { render json: item_json(dup).merge(duplicate: true), status: :ok }
      end
    end

    ext = File.extname(name).downcase
    stored = "flux_#{SecureRandom.hex(6)}#{ext}"
    dir = Rails.root.join("storage", "scrapbook")
    dir.mkpath
    FileUtils.cp(src, dir.join(stored))

    item = ScrapbookItem.create!(name: name, kind: kind_from_name(name),
                                 file: stored, job_id: params[:job_id].presence,
                                 sha256: sha)
    respond_to do |format|
      format.html { redirect_back fallback_location: scrapbook_path, notice: "Saved #{name} to the scrapbook." }
      format.json { render json: item_json(item), status: :created }
    end
  end

  private

  # The row already holding these exact bytes FOR THIS USER, if there is one.
  # Scoped by owner as well as digest — content identity is per-workspace, so
  # another operator's copy of the same bytes is not this one's duplicate.
  # `override=1` is the explicit "save a second copy anyway": the confirm the
  # UI puts in front of the operator when it hears `duplicate: true` back.
  def duplicate_of(sha)
    return nil if sha.blank? || params[:override].to_s == "1"

    ScrapbookItem.find_by(sha256: sha, owner: Current.user_handle)
  end

  # The kind is derived from the runner's own filename, not trusted from the
  # client: a favourite button only ever sends a job id and a name, and the name
  # says what it is.
  #
  # TWO spellings are live for candidates and proofs, because a runner stamps the
  # JOB'S NAME into what it publishes (<job>-candidate-01.svg / <job>-proof-01.png)
  # while a job directory published before that carries the pipeline's own
  # candidate_01.svg / candidate_01.proof.png. Both must classify, or a favourite
  # saved off a named run lands in the sidebar as an anonymous "upload".
  def kind_from_name(name)
    return "invert"    if name.start_with?("source.inverse")
    return "source"    if name.start_with?("source.")
    return "proof"     if name.end_with?(".proof.png") || name.match?(/-proof-\d+\.png\z/)
    return "candidate" if name.start_with?("candidate_") || name.match?(/-candidate-\d+\.svg\z/)
    return "flux"      if name.start_with?("flux_")

    "upload"
  end

  def item_json(item)
    size = item.stored_path.file? ? item.stored_path.size : 0
    {
      id: item.id, name: item.name, kind: item.kind,
      url: scrapbook_item_file_path(item), job_id: item.job_id,
      sha256: item.sha256,
      # Whether the stored bytes are a VECTOR. The sidebar's drag payload carries
      # this whole document, so the composite builder can mark a dragged SVG
      # layer as vector without re-deriving it from the name.
      vector: item.vector?,
      size: size, created_at: item.created_at
    }
  end
end
