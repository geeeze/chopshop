# Thin HTTP client for the chopshop-flux service's OWN API (that repo's
# docs/API.md). Ruby stdlib only, like RunnerClient, so the app runs on the
# default bundle.
#
# This is deliberately a SECOND protocol, not the runner contract. The flux
# service is a narrow generator that other applications also call, so it keeps a
# clean standard API of its own and does NOT grow a runner-contract shim. The
# studio does the joining instead: ask flux for a raster, store the bytes as an
# upload, then start an ordinary job on a pipeline runner with that raster as its
# source. So the flux service needs no knowledge of this app at all.
require "net/http"
require "json"

module FluxClient
  # Metadata calls are cheap; generation is not. A cold generate measured 54s on
  # the reference box -- 41s of which was the initial model load -- and the
  # service serialises on one GPU, so a queued request waits rather than running
  # beside it. A 15s timeout here would abort a call that is working fine.
  TIMEOUT = 15
  GENERATE_READ_TIMEOUT = 300
  FILE_READ_TIMEOUT = 120

  module_function

  def post(url, body, read_timeout: TIMEOUT)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json"
    req["Authorization"] = "Bearer #{token}" if token
    req.body = JSON.generate(body)
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = TIMEOUT
      http.read_timeout = read_timeout
      http.request(req)
    end
    parse(res)
  rescue FluxError
    raise
  rescue StandardError => e
    raise FluxError, "flux service connection failed: #{e.message}"
  end

  def get(url)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req["Accept"] = "application/json"
    req["Authorization"] = "Bearer #{token}" if token
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      http.request(req)
    end
    parse(res)
  rescue FluxError
    raise
  rescue StandardError => e
    raise FluxError, "flux service connection failed: #{e.message}"
  end

  # Proxy image bytes out of GET /files/<name>. Same shape as
  # RunnerClient.get_file, and the same reason for wrapping StandardError: an
  # unreachable service must surface as a FluxError, not a raw ECONNREFUSED.
  def get_file(url, read_timeout: FILE_READ_TIMEOUT)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{token}" if token
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = TIMEOUT
      http.read_timeout = read_timeout
      http.request(req)
    end
    { status: res.code.to_i, body: res.body, content_type: res["Content-Type"] }
  rescue FluxError
    raise
  rescue StandardError => e
    raise FluxError, "flux service connection failed: #{e.message}"
  end

  # GET /health is the one public route: no token, so a studio that is merely
  # configured (not yet trusted) can still report whether the box is up.
  def health(base)
    get("#{base}/health")
  rescue StandardError => e
    { error: e.message }
  end

  def models(base)
    get("#{base}/models")
  end

  # Text -> image, or image + text -> image when a reference is supplied.
  #
  # `reference` is a `data:image/png;base64,...` URL, which is the ONLY form
  # /edit accepts -- the service refuses a bare path or a non-image payload. It
  # is nil for a plain generation, and the route follows from that rather than
  # from a separate flag, so the two can never disagree.
  #
  # `images` is the batched count (num_images_per_prompt): one request can
  # produce a set of variations -- a triptych, a swatch sheet -- in the cheap
  # kind of parallelism, instead of N round-trips that each wait on the GPU.
  # Every image produced is returned in `entries`; the FIRST also sits at the
  # top level (`name`/`bytes`/`entry`) so the single-image caller is unchanged.
  #
  # `negative_prompt` only means anything on a model whose registry says
  # `negative_prompt: true` (sdxl-1.0, sd-1.5); on a distilled klein it is
  # reported by the service as a warning, not silently dropped.
  #
  # The service reports a server-side `path`, which is useless here (the studio
  # is not on that box), so the fetch goes through the documented `/files/<name>`
  # route instead.
  def render(base, prompt:, reference: nil, model: nil, width: nil, height: nil,
             steps: nil, guidance: nil, seed: nil, images: nil, negative_prompt: nil)
    body = { prompt: prompt }
    body[:model] = model if model.present?
    body[:width] = width.to_i if width.present?
    body[:height] = height.to_i if height.present?
    body[:steps] = steps.to_i if steps.present?
    body[:guidance] = guidance.to_f if guidance.present?
    body[:seed] = seed.to_i if seed.present?
    body[:images] = images.to_i if images.present?
    body[:negative_prompt] = negative_prompt if negative_prompt.present?
    route = reference.present? ? "edit" : "generate"
    body[:image] = reference if reference.present?

    meta = post("#{base}/#{route}", body, read_timeout: GENERATE_READ_TIMEOUT)
    entries = Array(meta["images"])
    raise FluxError, "the flux service reported no images" if entries.empty?

    fetched = entries.map do |entry|
      name = entry["name"].to_s
      raise FluxError, "the flux service reported an image with no name" if name.empty?

      img = get_file("#{base}/files/#{name}")
      unless img[:status] == 200
        raise FluxError, "flux service returned #{img[:status]} fetching #{name}"
      end

      { name: name, bytes: img[:body], content_type: img[:content_type], entry: entry }
    end

    first = fetched.first
    { name: first[:name], bytes: first[:bytes], content_type: first[:content_type],
      meta: meta, entry: first[:entry], entries: fetched }
  end

  # A local PNG as the data URL /edit requires. Mirrors the service's own MIME
  # table: anything else is a caller error rather than a guess.
  MIME_BY_EXT = { ".png" => "image/png", ".jpg" => "image/jpeg",
                  ".jpeg" => "image/jpeg", ".webp" => "image/webp" }.freeze

  def data_url(path)
    ext = File.extname(path.to_s).downcase
    mime = MIME_BY_EXT[ext]
    unless mime
      raise FluxError, "unsupported reference image #{ext.inspect} " \
                       "(known: #{MIME_BY_EXT.keys.sort.join(', ')})"
    end
    require "base64"
    "data:#{mime};base64,#{Base64.strict_encode64(File.binread(path))}"
  end

  def token
    ENV["CHOPSHOP_FLUX_TOKEN"].presence
  end

  def parse(res)
    body = res.body.to_s
    parsed = body.presence && JSON.parse(body)
    if res.is_a?(Net::HTTPSuccess)
      (parsed || {}).with_indifferent_access
    else
      raise FluxError.new("flux #{res.code}: #{parsed&.fetch('error', body)}")
    end
  end

  class FluxError < StandardError; end
end
