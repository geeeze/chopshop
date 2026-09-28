# The composite builder: assemble a job's source raster out of layered pieces.
#
# The page is a canvas editor (page-level script in the view, not aether.js —
# it is one page's tool, not a site-wide widget). This controller owns the
# composite's persistence and the ONE thing that has to be server-side: the
# flatten. The browser can compose pixels for the preview, but the PNG the
# runner reads has to be produced somewhere it can be read from, and a canvas
# is not a file. So the browser posts the composed blob to #flatten, which
# stores it as a scrapbook item AND uploads it, then #use hands that upload to
# the new-job form.
#
# The result is deliberately routed THROUGH the scrapbook: a flattened composite
# is a favouritable artefact in its own right, and one store for "things I made"
# is simpler than two.
class CompositesController < ApplicationController
  before_action :require_login

  def index
    @composites = Composite.recent.limit(100)
    render json: @composites.map { |c| composite_json(c) }
  end

  # `/composite/new` and `/composite` both land here, and only the first carries
  # an id. `find(nil)` would 404 on the new page, so the absent id is a NEW
  # (unsaved) composite with the sensible defaults — which is exactly what the
  # page needs to render a blank canvas.
  def show
    @composite = params[:id].present? ? Composite.find(params[:id]) : Composite.new(
      name: "composite", width: Composite::DEFAULT_WIDTH,
      height: Composite::DEFAULT_HEIGHT, background: "transparent", layers: []
    )
  end

  def create
    @composite = Composite.new(
      name: params[:name].presence || "composite",
      width: params[:width].presence || Composite::DEFAULT_WIDTH,
      height: params[:height].presence || Composite::DEFAULT_HEIGHT,
      background: params[:background].presence || "transparent",
      layers: parse_layers(params[:layers])
    )
    if @composite.save
      redirect_to composite_path(@composite)
    else
      flash.now[:alert] = @composite.errors.full_messages.to_sentence
      @composite = Composite.new
      render :show, status: :unprocessable_entity
    end
  end

  def update
    @composite = Composite.find(params[:id])
    # Only the keys that were actually posted. Assigning the absent ones would
    # nil a required field (a partial update is a legitimate request, and a
    # malformed layers payload must not take the name down with it).
    %i[name width height background].each do |key|
      @composite.public_send("#{key}=", params[key]) if params.key?(key)
    end
    # Layers arrive as a JSON STRING from the page's hidden field, because the
    # canvas is the authority on placement and the form must post what it drew.
    #
    # It must be parsed here, not assigned raw: a json column given a String
    # casts to [] and silently drops every layer. The one way to tell a genuinely
    # empty composite from a mangled payload is a parse that yields nil.
    raw = params[:layers]
    parsed = parse_layers(raw)
    @composite.layers = parsed unless parsed.nil?
    if @composite.save
      redirect_to composite_path(@composite), notice: "Composite saved."
    else
      flash.now[:alert] = @composite.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity
    end
  end

  def destroy
    Composite.find(params[:id]).destroy
    redirect_to new_composite_path, notice: "Composite deleted."
  end

  # Store the browser-composed PNG: once as a scrapbook item (so it can be
  # favourited and re-used) and once as an upload (because that is the only
  # input location the runner contract reads). The upload is the one the job
  # uses; the scrapbook copy is the re-usable artefact.
  def flatten
    composite = Composite.find(params[:id])
    file = params[:file]
    unless file.respond_to?(:original_filename)
      return render json: { error: "no image received" }, status: :bad_request
    end

    head = File.open(file.tempfile, "rb") { |f| f.read(8) }
    unless head&.bytes&.first(4) == [0x89, 0x50, 0x4E, 0x47]
      File.delete(file.tempfile) if File.exist?(file.tempfile)
      return render json: { error: "not a PNG" }, status: :bad_request
    end

    scrap = Rails.root.join("storage", "scrapbook")
    uploads = Rails.root.join("storage", "uploads")
    scrap.mkpath
    uploads.mkpath

    stored = "composite_#{SecureRandom.hex(6)}.png"
    FileUtils.cp(file.tempfile.to_path, scrap.join(stored))
    item = ScrapbookItem.create!(name: "#{composite.name}.png", kind: "upload",
                                 file: stored, job_id: nil)

    upload = uploads.join("upload_#{SecureRandom.hex(6)}.png")
    FileUtils.cp(file.tempfile.to_path, upload)

    render json: {
      scrapbook_id: item.id,
      path: upload.to_s,
      preview_url: upload_preview_jobs_path(name: File.basename(upload))
    }
  end

  # "Run it": the flattened upload becomes a new job's artwork. The composite
  # records the upload it last produced, so returning to it can re-use the same
  # flatten rather than re-rasterising.
  def use
    composite = Composite.find(params[:id])
    upload = params[:path].to_s
    uploads = Rails.root.join("storage", "uploads")
    candidate = uploads.join(File.basename(upload))
    unless candidate.file? && candidate.to_s.start_with?(uploads.to_s + File::SEPARATOR)
      return redirect_to composite_path(composite),
                          alert: "Flatten this composite before running it."
    end

    redirect_to new_job_path(input_path: candidate.to_s,
                             preview_url: upload_preview_jobs_path(name: File.basename(candidate)),
                             name: composite.name,
                             carried_from: "composite #{composite.name}")
  end

  # The scrapbook items available as layers, so the page can offer "import from
  # scrapbook" without hardcoding anything the sidebar already lists.
  def layers_available
    items = ScrapbookItem.recent.limit(200)
    render json: items.map { |i| { id: i.id, name: i.name, kind: i.kind, url: scrapbook_item_file_path(i) } }
  end

  private

  def composite_json(c)
    { id: c.id, name: c.name, width: c.width, height: c.height,
      background: c.background, layers: c.layers }
  end

  # Layers arrive as a JSON string. Returns the parsed Array, or NIL when the
  # payload is absent or unparseable — deliberately distinct from `[]`, because
  # `[]` is a legitimate value (a composite whose layers were all removed) and
  # must not be confused with "the payload was mangled, keep what you had".
  def parse_layers(raw)
    return [] if raw.blank?
    parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
    parsed.is_a?(Array) ? parsed : nil
  rescue JSON::ParserError
    nil
  end
end
