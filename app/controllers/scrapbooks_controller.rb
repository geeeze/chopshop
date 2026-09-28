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

    ext = File.extname(name).downcase
    stored = "#{kind_from_name(name)}_#{SecureRandom.hex(6)}#{ext}"
    dir = Rails.root.join("storage", "scrapbook")
    dir.mkpath
    File.binwrite(dir.join(stored), fetched[:body])

    item = ScrapbookItem.create!(name: name, kind: kind_from_name(name),
                                 file: stored, job_id: job.id)
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
    item.destroy
    File.delete(path) if path.file?
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

    redirect_to new_job_path(input_path: dest.to_s,
                             preview_url: upload_preview_jobs_path(name: File.basename(dest)),
                             name: item.name.to_s.sub(/\.[^.]+\z/, ""),
                             carried_from: "scrapbook")
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

    ext = is_png ? ".png" : ".jpg"
    stored = "edit_#{SecureRandom.hex(6)}#{ext}"
    dir = Rails.root.join("storage", "scrapbook")
    dir.mkpath
    FileUtils.mv(file.tempfile.to_path, dir.join(stored))

    item = ScrapbookItem.create!(name: stored, kind: "upload", file: stored)
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

    ext = File.extname(name).downcase
    stored = "flux_#{SecureRandom.hex(6)}#{ext}"
    dir = Rails.root.join("storage", "scrapbook")
    dir.mkpath
    FileUtils.cp(src, dir.join(stored))

    item = ScrapbookItem.create!(name: name, kind: kind_from_name(name),
                                 file: stored, job_id: params[:job_id].presence)
    respond_to do |format|
      format.html { redirect_back fallback_location: scrapbook_path, notice: "Saved #{name} to the scrapbook." }
      format.json { render json: item_json(item), status: :created }
    end
  end

  private

  # The kind is derived from the runner's own filename, not trusted from the
  # client: a favourite button only ever sends a job id and a name, and the name
  # says what it is.
  def kind_from_name(name)
    return "invert"    if name.start_with?("source.inverse")
    return "source"    if name.start_with?("source.")
    return "proof"     if name.end_with?(".proof.png")
    return "candidate" if name.start_with?("candidate_")
    return "flux"      if name.start_with?("flux_")

    "upload"
  end

  def item_json(item)
    size = item.stored_path.file? ? item.stored_path.size : 0
    {
      id: item.id, name: item.name, kind: item.kind,
      url: scrapbook_item_file_path(item), job_id: item.job_id,
      size: size, created_at: item.created_at
    }
  end
end
