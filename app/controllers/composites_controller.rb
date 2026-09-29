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
      palette: parse_palette(params[:palette]),
      layers: parse_layers(params[:layers])
    )
    if @composite.save
      respond_to do |format|
        format.html { redirect_to composite_path(id: @composite.id) }
        format.json { render json: run_handoff(@composite) }
      end
    else
      respond_to do |format|
        format.html do
          flash.now[:alert] = @composite.errors.full_messages.to_sentence
          @composite = Composite.new
          render :show, status: :unprocessable_entity
        end
        format.json do
          render json: { error: @composite.errors.full_messages.to_sentence },
                 status: :unprocessable_entity
        end
      end
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
    # The palette is posted the way the background is — as text — so it is parsed
    # rather than assigned raw: a json column given a String casts to [] and
    # would silently drop every colour the operator chose.
    @composite.palette = parse_palette(params[:palette]) if params.key?(:palette)
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
      respond_to do |format|
        format.html { redirect_to composite_path(id: @composite.id), notice: "Composite saved." }
        format.json { render json: run_handoff(@composite) }
      end
    else
      respond_to do |format|
        format.html do
          flash.now[:alert] = @composite.errors.full_messages.to_sentence
          render :show, status: :unprocessable_entity
        end
        format.json do
          render json: { error: @composite.errors.full_messages.to_sentence },
                 status: :unprocessable_entity
        end
      end
    end
  end

  def destroy
    Composite.find(params[:id]).destroy
    redirect_to new_composite_path, notice: "Composite deleted."
  end

  # Flatten a composite into ONE artefact, stored twice: a scrapbook item (the
  # re-usable copy, which can be favourited and composed again) and an upload
  # (the only input location the runner contract reads).
  #
  # ONE composite, TWO flattens, and this action starts both. The raster path is
  # the original: the browser rasterised the canvas and posted the PNG, which is
  # still what a raster-only composite gets. A composite holding any VECTOR layer
  # never gets here — pixels of a trace are a re-trace waiting to happen, so
  # #flatten_vector asks the svg runner to compose the vectors themselves.
  def flatten
    composite = Composite.find(params[:id])
    # A caller may still insist on pixels (a screenshot of a vector composite,
    # say) by asking for the raster mode explicitly; otherwise vectors win.
    return flatten_vector(composite) if composite.vector_layers.any? && !raster_mode?

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
      preview_url: upload_preview_jobs_path(name: File.basename(upload)),
      content_type: "image/png",
      mode: "raster"
    }
  end

  # The recipe: the EXACT spec this composite's vector flatten POSTs to the svg
  # runner's /compose, with every vector layer's `src` already resolved to its
  # inline SVG text (never a path — the runner cannot see this app's storage).
  #
  # It is the single JSON contract an agent reads to drive compose -> collect:
  # compose that spec at /compose, and the SVG you get back is what the studio
  # itself would have stored. Reading the composite and rebuilding this by hand
  # is the thing this endpoint exists to make unnecessary, and it cannot drift
  # from the flatten because both are built by ComposeSpec.
  def recipe
    composite = Composite.find(params[:id])
    render json: ComposeSpec.build(composite, palette: palette_param)
  rescue ComposeSpec::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
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
      return redirect_to composite_path(id: composite.id),
                          alert: "Flatten this composite before running it."
    end

    redirect_to new_job_path(input_path: candidate.to_s,
                             preview_url: upload_preview_jobs_path(name: File.basename(candidate)),
                             name: composite.name,
                             carried_from: "composite #{composite.name}")
  end

  # The scrapbook items available as layers, so the page can offer "import from
  # scrapbook" without hardcoding anything the sidebar already lists.
  #
  # `kind` here is the LAYER kind the compose contract speaks — "vector" for an
  # SVG item (a traced candidate, a source, or a composite the studio composed
  # itself), "raster" for everything else — so the page can offer a vector layer
  # and mark it as one. `item_kind` keeps the scrapbook's own artifact kind, so
  # a caller can still tell a candidate from a proof.
  def layers_available
    items = ScrapbookItem.recent.limit(200)
    render json: items.map { |i|
      kind = layer_kind_of(i)
      { id: i.id, name: i.name, kind: kind, layer_kind: kind,
        item_kind: i.kind, vector: i.vector?, url: scrapbook_item_file_path(i) }
    }
  end

  private

  # VECTOR flatten: build the compose spec, ask the svg runner to merge the
  # layers itself, and store the SVG it answers with exactly where the raster
  # flatten stores its PNG (a scrapbook artefact plus the upload the runner
  # reads). The composite is NOT rasterised anywhere in this path.
  #
  # Which runner composes is the svg-kind label the deployment configured, not a
  # literal: the operation belongs to the runner that speaks the contract, and
  # the placement is env-driven like every other runner.
  def flatten_vector(composite)
    spec = ComposeSpec.build(composite, palette: palette_param)
    written = ComposeClient.compose(compose_base_url, spec)
    stored = store_svg(composite, written[:bytes])

    render json: stored.merge(content_type: written[:content_type], mode: "vector")
  rescue ComposeSpec::Error => e
    # A composite that cannot be composed as asked (a vector layer whose source
    # is gone, or is not an SVG). 422, with the reason — never a half-composed
    # artefact.
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ComposeClient::ComposeError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # The SVG the compose returned, stored twice like the raster flatten's PNG:
  # the scrapbook item (kind "svg", the re-usable artefact) and the upload (the
  # only input location the runner contract reads).
  def store_svg(composite, bytes)
    scrap = Rails.root.join("storage", "scrapbook")
    uploads = Rails.root.join("storage", "uploads")
    scrap.mkpath
    uploads.mkpath

    stored = "composite_#{SecureRandom.hex(6)}.svg"
    File.binwrite(scrap.join(stored), bytes)
    item = ScrapbookItem.create!(name: "#{composite.name}.svg", kind: "svg",
                                 file: stored, job_id: nil,
                                 sha256: Digest::SHA256.hexdigest(bytes))

    upload = uploads.join("upload_#{SecureRandom.hex(6)}.svg")
    File.binwrite(upload, bytes)

    { scrapbook_id: item.id,
      path: upload.to_s,
      preview_url: upload_preview_jobs_path(name: File.basename(upload)) }
  end

  # Where the compose operation lives. An explicit CHOPSHOP_COMPOSE_URL (or
  # CHOPSHOP_COMPOSE_RUNNER, a pipeline label) wins; otherwise the first
  # svg-kind runner — the same question `Job.pipeline_runners` answers, asked
  # again here so a deployment that renames its labels keeps working.
  def compose_base_url
    explicit = ENV["CHOPSHOP_COMPOSE_URL"].presence
    return explicit if explicit

    labels = Job.pipeline_runners
    chosen = ENV["CHOPSHOP_COMPOSE_RUNNER"].presence&.downcase
    chosen = nil unless chosen && labels.include?(chosen)
    # NOT labels.first: `mock` is an svg-KIND runner too and its URL sorts first,
    # so "the first svg runner" resolved to the MOCK -- whose whole job is to fake
    # the pipeline, and which has no /compose. Every composite that held a vector
    # layer therefore failed with `compose 404: unknown route` in production. The
    # compose target is the real pipeline runner, which is the same rule
    # Job.handoff_runner already applies to the flux hand-off.
    target = chosen || labels.find { |label| label != "mock" } || labels.first
    Job.runners[target]
  end

  # The caller's palette for THIS request: a JSON array, or the comma/space
  # separated list a text field posts. Absent means "use the composite's own", and
  # an empty one means the same thing — there is no "clear the palette for this
  # one flatten" that would send an empty list the contract has no meaning for.
  def palette_param
    values = parse_palette(params[:palette])
    values.any? ? values : nil
  end

  # The raster path is opt-in for a composite that holds vectors. Explicit, so a
  # caller that really wants pixels says so instead of the server guessing.
  def raster_mode?
    params[:mode].to_s == "raster" || params[:raster].to_s == "1"
  end

  def layer_kind_of(item)
    item.vector? ? Composite::KIND_VECTOR : Composite::KIND_RASTER
  end

  def composite_json(c)
    { id: c.id, name: c.name, width: c.width, height: c.height,
      background: c.background, palette: c.palette, layers: c.layers,
      vector: c.vector?, all_vector: c.all_vector? }
  end

  # A palette as the contract wants it: a list of colour strings from a JSON
  # array or the comma/space separated text a field posts. `[]` when the field is
  # blank, because the column's own default is `[]` and a composite with no
  # palette must answer the same either way.
  def parse_palette(raw)
    return [] if raw.blank?

    values = raw.is_a?(Array) ? raw : split_palette(raw.to_s)
    return [] unless values.is_a?(Array)

    values.map { |c| c.to_s.strip }.reject(&:blank?)
  end

  # A palette posted as TEXT: a JSON array (what an agent sends) or the
  # comma/space separated list the field posts. A string that is neither is taken
  # as a one-item list rather than refused — a typo must not 500 a save.
  def split_palette(text)
    parsed = JSON.parse(text)
    parsed.is_a?(Array) ? parsed : [text]
  rescue JSON::ParserError
    text.split(/[\s,]+/)
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

  # The hand-off the page's Run Job / Flatten needs after a save: the id and the
  # two URLs the next steps POST to. JSON only — the HTML path still redirects.
  def run_handoff(composite)
    { id: composite.id,
      flatten_url: flatten_composite_path(id: composite.id),
      use_url: use_composite_path(id: composite.id) }
  end
end
