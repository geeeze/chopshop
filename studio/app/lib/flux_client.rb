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
  # A generate is answered with the WHOLE batch: the service renders every
  # image before it replies, so the read budget has to grow with `images` and
  # with pixels. A flat 300s aborted a 4-image 1024x1024 run at exactly 300.0s
  # while the service was still rendering it (job 507, 2026-10-22) -- and the
  # render kept going on the card with nobody left to collect it. Measured on
  # the reference box (klein-4b, 1024x1024): ~117s for the first frame including
  # the load, ~20-75s per further frame once the pipeline is resident.
  #
  # BASE covers a cold load plus the GPU guard's whole wait budget; PER_IMAGE is
  # the allowance for each frame AFTER the first, scaled by area so a 2048x2048
  # request is not held to a 1024x1024 figure.
  GENERATE_READ_TIMEOUT = 300
  GENERATE_PER_IMAGE_READ_TIMEOUT = 180
  GENERATE_TIMEOUT_REFERENCE_PIXELS = 1024 * 1024
  FILE_READ_TIMEOUT = 120

  module_function

  # The read timeout for one generate, as a function of what was asked for.
  #
  # `images` is the count the service will render in one answer; `width`/`height`
  # size each frame. Both are the CALLER's numbers, so a spec with no explicit
  # size (the service's registry default applies) is charged at the reference
  # size rather than at zero.
  #
  # Env overrides exist because this is a duration that depends on the box: a
  # slower card or a bigger registry default needs more, and waiting long is
  # cheaper than aborting a render that is still working.
  def generate_read_timeout(width: nil, height: nil, images: nil)
    base = env_seconds("CHOPSHOP_STUDIO_FLUX_GENERATE_TIMEOUT", GENERATE_READ_TIMEOUT)
    per_image = env_seconds("CHOPSHOP_STUDIO_FLUX_GENERATE_PER_IMAGE_TIMEOUT",
                            GENERATE_PER_IMAGE_READ_TIMEOUT)
    frames_after_first = [images.to_i - 1, 0].max
    w = width.to_i
    h = height.to_i
    pixels = w.positive? && h.positive? ? w * h : GENERATE_TIMEOUT_REFERENCE_PIXELS
    area = [pixels.to_f / GENERATE_TIMEOUT_REFERENCE_PIXELS, 1.0].max
    base + (frames_after_first * per_image * area).round
  end

  # A positive whole number of seconds from the environment, else the default.
  # Blank counts as absent, and a non-numeric value is the default rather than a
  # zero-second timeout -- a typo must not make every generation abort.
  def env_seconds(name, default)
    raw = ENV[name].to_s.strip
    value = Integer(raw, exception: false) if raw.match?(/\A\d+\z/)
    value && value.positive? ? value : default
  end

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
  # `references` is the MULTI-reference form of the same thing: several data URLs
  # conditioned on as ONE set, in the order given, which is the whole of what
  # the caller is saying ("the pose from the first, the palette from the
  # second"). /edit's `image` accepts a list, and whether a given model may be
  # sent one is the checkpoint's own `multi_reference` flag -- the service REFUSES
  # a second reference on a family that takes one (a 400 naming the model,
  # before the GPU is touched), so this client passes the list through rather
  # than second-guessing it, and a `reference` is the one-element case of the
  # same list. A single URL is still sent as a bare string, not a one-element
  # array, because that is the shape every existing caller sends and the service
  # documents both.
  #
  # `references` and `reference` are merged in order (the scalar first), so a
  # caller may pass either or both without either silently winning.
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
  # `strength` is img2img-only and SD-family-only. The service passes it to the
  # pipeline only for a model whose registry says `img2img_strength: true` AND
  # when a reference image is actually there — so a text-to-image call never
  # carries it, and neither does a klein (its unified call has no strength
  # parameter). Where it does apply it says how far an edit may move from the
  # reference. Blank is left out rather than sent, so the pipeline's own default
  # applies instead of a zero.
  #
  # `modifiers` is the list of LoRA keys to stack, `modifier_scales` a key ->
  # multiplier map for the ones the operator typed a scale for, and `vae` a
  # decoder swap. All three are omitted when blank, on the same rule as every
  # other setting here: an absent key means the service's own default, while an
  # empty array or object would be a caller saying "none" in a way the service
  # has to interpret. Which combinations are LEGAL is the registry's business
  # (FluxConf.validate) and is checked before anything loads.
  #
  # The service reports a server-side `path`, which is useless here (the studio
  # is not on that box), so the fetch goes through the documented `/files/<name>`
  # route instead.
  def render(base, prompt:, reference: nil, references: nil, model: nil,
             width: nil, height: nil,
             steps: nil, guidance: nil, seed: nil, images: nil, negative_prompt: nil,
             strength: nil, modifiers: nil, modifier_scales: nil, vae: nil)
    body = { prompt: prompt }
    # The reference list, normalised ONCE here so every rule below reads the
    # same shape: the scalar `reference` (the pre-multi-reference argument, kept
    # so no existing caller changes) first, then `references` in the order given.
    # Blanks are dropped, so an empty slot on a hand-written spec is "not asked
    # for" rather than an empty string the service would have to interpret.
    refs = [reference, *Array(references)].map { |r| r.to_s.strip }.reject(&:empty?)
    body[:model] = model if model.present?
    body[:width] = width.to_i if width.present?
    body[:height] = height.to_i if height.present?
    body[:steps] = steps.to_i if steps.present?
    body[:guidance] = guidance.to_f if guidance.present?
    body[:seed] = seed.to_i if seed.present?
    body[:images] = images.to_i if images.present?
    body[:negative_prompt] = negative_prompt if negative_prompt.present?
    body[:strength] = strength.to_f if strength.present?
    # Array()/Hash() rather than a presence check alone: a spec is editable text,
    # and a hand-written `"modifiers": "klein-outpaint"` should reach the service
    # as the one-element list it means rather than as a JSON string.
    body[:modifiers] = Array(modifiers).map(&:to_s) if Array(modifiers).any?
    body[:modifier_scales] = modifier_scales if modifier_scales.to_h.any?
    body[:vae] = vae if vae.present?
    route = refs.any? ? "edit" : "generate"
    # ONE reference rides as the bare data URL every existing caller sends;
    # SEVERAL ride as a list, in the order given. Both are documented shapes of
    # /edit's `image`, and a list is the only way to say "the first is the pose
    # and the second is the palette".
    body[:image] = refs.length == 1 ? refs.first : refs if refs.any?

    meta = post("#{base}/#{route}", body,
                read_timeout: generate_read_timeout(width: width, height: height,
                                                    images: images))
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
      message = parsed&.fetch('error', body)
      # The service's GPU-contention guard returns 503 with kind=gpu_busy when
      # another process holds the card. This is a refusal, not a failure: the
      # request was well-formed and retrying is the right response. Raise a
      # distinct class so callers can retry without catching every FluxError.
      if parsed&.fetch('kind', nil) == 'gpu_busy'
        raise FluxGpuBusy.new("flux #{res.code}: #{message}")
      else
        raise FluxError.new("flux #{res.code}: #{message}")
      end
    end
  end

  class FluxError < StandardError; end
  # Raised when the flux service refuses a request because another process
  # holds the GPU (HTTP 503, kind=gpu_busy). Subclasses FluxError so existing
  # rescue clauses still catch it, but callers can distinguish a busy card
  # from a real generation failure and retry the request.
  class FluxGpuBusy < FluxError; end
end
