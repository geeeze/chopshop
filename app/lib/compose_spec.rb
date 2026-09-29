# The COMPOSE SPEC: one document, built in one place, saying what a composite
# looks like to the compose operation.
#
# Two callers read it and they must not disagree: `CompositesController#flatten`
# POSTs it to the svg runner's `/compose` (the vector flatten), and
# `CompositesController#recipe` answers with it as JSON — the single contract an
# agent reads to drive compose -> collect without re-deriving any of this. A
# second builder for the recipe would drift from the one that actually composes,
# so there is only this one.
#
# The shape is the sibling repo's wire contract, verbatim:
#
#   {"op": "compose",
#    "spec": {"width", "height", "background",
#             "palette" (optional),
#             "layers": [{"type": "svg"|"raster", "src", "x", "y", "w", "h",
#                         "opacity", "hue"}]}}
#
# `src` is INLINE by contract: a vector layer carries the candidate SVG'S OWN
# TEXT, a raster layer a data URI. Never a path — the runner is on another box
# and cannot see this app's storage, which is the whole reason the resolution
# happens here.
#
# Resolution is by what the bytes ARE, not only by what the layer claims: an SVG
# that a composite happens to have marked raster is still sent as `type: "svg"`.
# The one thing this module refuses is a layer marked vector whose bytes are not
# an SVG — that composite is broken, and quietly rasterising it would re-trace a
# traced vector, which is exactly the fidelity the vector path exists to keep.
module ComposeSpec
  module_function

  MIME_BY_EXT = {
    ".svg" => "image/svg+xml",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".pdf" => "application/pdf"
  }.freeze

  # Build the spec for a composite. `palette` (a list of #rrggbb) overrides the
  # composite's own, for a caller that wants one flatten in different inks.
  def build(composite, palette: nil)
    {
      "width" => composite.width.to_i,
      "height" => composite.height.to_i,
      "background" => composite.background.presence || "transparent",
      "palette" => normalize_palette(palette.presence || composite.palette),
      "layers" => composite.paintable_layers.map { |layer| layer_spec(layer) }
    }
  end

  # One layer of the spec. `visible` has no wire equivalent (see
  # Composite#paintable_layers), and the optional placement fields are omitted
  # rather than guessed at when the layer does not carry them.
  def layer_spec(layer)
    resolved = read(layer["src"])
    declared = Composite.layer_kind(layer)
    svg = svg?(resolved)

    if declared == Composite::KIND_VECTOR && !svg
      raise Error, "#{label(layer)} is marked a vector layer but its source is " \
                   "#{resolved[:content_type]} — a vector layer must be an SVG"
    end

    spec = {
      # What the bytes are, then what the layer claimed: a mis-marked SVG is
      # composed as vectors anyway.
      "type" => svg ? "svg" : "raster",
      "src" => svg ? utf8(resolved[:bytes]) : data_uri(resolved),
      "x" => number(layer["x"]),
      "y" => number(layer["y"]),
      "w" => number(layer["w"]),
      "h" => number(layer["h"])
    }
    spec["opacity"] = number(layer["opacity"]) unless layer["opacity"].nil?
    spec["hue"] = number(layer["hue"]) unless layer["hue"].nil?
    spec
  end

  # Resolve a layer's `src` to the BYTES it names: {bytes:, content_type:, name:}.
  #
  # Every form a layer can hold today, in the order they are tried:
  #
  #   data:…                  — an upload the browser inlined
  #   /scrapbook/<id>/file    — a scrapbook artefact (the picker's url)
  #   /jobs/upload_preview/<n>— a stored upload
  #   a path under storage/   — the stored path a flatten handed back
  #   http(s)://…             — a runner file proxy, through RunnerClient
  #
  # Anything else is refused by name rather than fetched on a guess.
  def read(src)
    raw = src.to_s
    raise Error, "a layer has no source to compose" if raw.blank?

    return decode_data_uri(raw) if raw.start_with?("data:")

    if (path = local_path(raw))
      raise Error, "the layer's source is missing on disk: #{raw}" unless path.file?

      return { bytes: File.binread(path), content_type: mime_for(path.to_s), name: File.basename(path) }
    end

    return read_remote(raw) if raw.match?(%r{\Ahttps?://})

    raise Error, "cannot read the layer's source: #{raw}"
  end

  # The local file a studio-relative src names, or nil. Every branch resolves to
  # a path INSIDE storage/ — a bare path from a composite is never followed out
  # of it, because a layer's src is data from a client.
  def local_path(raw)
    storage = Rails.root.join("storage")

    if (m = raw.match(%r{\A/scrapbook/(\d+)/file\z}))
      item = ScrapbookItem.find_by(id: m[1])
      raise Error, "scrapbook item #{m[1]} no longer exists" unless item

      return item.stored_path
    end

    if (m = raw.match(%r{\A/jobs/upload_preview/([^/?]+)}))
      name = File.basename(m[1])
      return Rails.root.join("storage", "uploads", name)
    end

    return nil unless File.file?(raw) || raw.start_with?(storage.to_s + File::SEPARATOR)

    expanded = File.expand_path(raw)
    return nil unless expanded.start_with?(storage.to_s + File::SEPARATOR)

    Pathname.new(expanded)
  end

  # A runner-side file (the file proxy), through the client that already knows
  # how to carry the runner token.
  def read_remote(url)
    fetched = RunnerClient.get_file(url)
    unless fetched[:status] == 200 && fetched[:body].present?
      raise Error, "the runner could not serve the layer's source (#{fetched[:status]})"
    end

    { bytes: fetched[:body], content_type: fetched[:content_type].presence || mime_for(url),
      name: File.basename(URI.parse(url).path) }
  rescue URI::InvalidURIError
    raise Error, "cannot read the layer's source: #{url}"
  end

  # `data:image/svg+xml;base64,…` and its percent-encoded twin. Base64 is read
  # with unpack rather than the base64 gem, so nothing here needs a new
  # dependency.
  def decode_data_uri(raw)
    m = raw.match(%r{\Adata:([\w.+-]+/[\w.+-]+)?((?:;[\w.+-]+)*),(.*)\z}m)
    raise Error, "a layer's data URI is malformed" unless m

    payload = m[3]
    bytes = m[2].to_s.include?("base64") ? payload.unpack1("m") : percent_decode(payload)
    { bytes: bytes, content_type: m[1].presence || "application/octet-stream", name: "inline" }
  end

  def percent_decode(text)
    text.gsub(/%([0-9A-Fa-f]{2})/) { [Regexp.last_match(1)].pack("H2") }
  end

  # What the bytes ARE. An SVG is text that opens with `<svg` (a leading XML
  # declaration or comment is common, so the tag is looked for rather than
  # required first); the content type is checked too, because a scraper that
  # reported image/svg+xml with a BOM is still a vector.
  def svg?(resolved)
    return false unless resolved

    resolved[:content_type].to_s == "image/svg+xml" || svg_text?(resolved[:bytes])
  end

  def svg_text?(bytes)
    bytes.to_s.b.include?("<svg".b)
  end

  def data_uri(resolved)
    "data:#{resolved[:content_type].presence || 'application/octet-stream'};base64," \
      "#{[resolved[:bytes].to_s].pack('m0')}"
  end

  # Inline text going into a JSON body has to be valid UTF-8: an SVG read as
  # binary bytes is ASCII-8BIT, and JSON.generate refuses a string whose encoding
  # claims nothing. A byte sequence that is not valid UTF-8 is scrubbed rather
  # than raised on — the alternative is a flatten that fails on one stray byte in
  # a comment.
  def utf8(bytes)
    text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
    text.valid_encoding? ? text : text.scrub
  end

  def mime_for(name)
    MIME_BY_EXT.fetch(File.extname(name.to_s).downcase, "application/octet-stream")
  end

  # The palette as the contract wants it: a flat list of colour strings, and
  # omitted (nil) when there is none. Accepts a comma/space separated string too,
  # because that is what a text field posts.
  def normalize_palette(value)
    return nil if value.blank?

    list = value.is_a?(Array) ? value : value.to_s.split(/[\s,]+/)
    list = list.map { |c| c.to_s.strip }.reject(&:blank?)
    list.any? ? list : nil
  end

  # A layer's geometry, as a number. The canvas stores these as numbers; a string
  # from a hand-written JSON payload is coerced, and one that will not parse is
  # nil (the contract treats x/y/w/h as placement the compose applies as given).
  def number(value)
    return nil if value.nil? || value.to_s.strip.empty?
    return value if value.is_a?(Numeric)

    Float(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def label(layer)
    name = layer.is_a?(Hash) ? layer["name"].presence || layer["key"].presence : nil
    "layer #{name || '?'}"
  end

  # A composite that cannot be composed as asked. Surfaces as a 422 with the
  # reason, never as a half-composed image.
  class Error < StandardError; end
end
