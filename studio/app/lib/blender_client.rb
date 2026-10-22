# Thin HTTP client for chopshop-plot's BLENDER operation — the same serve
# surface PlotClient speaks, one route further on. Ruby stdlib only, like
# RunnerClient, FluxClient and PlotClient, so the app runs on the default
# bundle.
#
# This is the geometry source's 3D sibling, NOT a second protocol: the runner
# exposes `blender` as an OPERATION of the same service (POST /blender), so the
# envelope is the plot envelope — `{"op": "blender", "spec": {…}}` — and the
# refusal is the plot refusal, a JSON `{"error": …, "kind": …}` envelope. What
# differs is the ANSWER, and the answer is why this is a client of its own:
#
#   views == 1  -> image/png, the rendered frame itself, one round trip;
#   views > 1   -> application/json, a frames manifest
#                  `{"frames": [names], "glb": name-or-null}`, with each frame
#                  fetched from GET /files/<name> and the GLB (when the export
#                  block asked for one) left on the runner as the manifest names
#                  it;
#   Blender absent on the runner -> 503, which is a `Unavailable` here rather
#                  than a generic failure: it is a state a deployment is allowed
#                  to be in, and the operator is told which one.
#
# So every method reads the answer by CONTENT TYPE rather than guessing at it,
# and a 200 that is neither a PNG nor a manifest is an error rather than bytes
# that would be stored as a rendered frame and fail later.
require "net/http"
require "json"
require "digest"

module BlenderClient
  # Metadata calls are cheap. A render is not: the runner has to start a
  # headless Blender, build the scene and rasterise it, which is seconds of work
  # on a fast box and minutes on a cold or loaded one. FluxClient's 300s is the
  # precedent for a call that does real work, and a render is not much cheaper.
  TIMEOUT = 15
  RENDER_READ_TIMEOUT = 300
  FILE_READ_TIMEOUT = 120

  # The one operation this client speaks, named once. The route and the
  # envelope's `op` are the same word, which is what makes `render` a single
  # method rather than an operation table.
  OP = "blender".freeze

  # The two success shapes, in the words the page and the tests use.
  SUCCESS_PNG = "image/png".freeze
  SUCCESS_MANIFEST = "application/json".freeze

  # The PNG magic number. Blender writes a real PNG, and a 200 that is not one
  # is a proxy or a bug rather than a frame, so it is refused here instead of
  # being stored as a render and discovered by the <img> that cannot show it.
  PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

  module_function

  # One service, one token: `blender` is an OPERATION of the chopshop-plot
  # service, not a separate server, so it authenticates with the SAME variable
  # the PLOT client reads. A second name here (CHOPSHOP_BLENDER_TOKEN) would
  # send a bearer token the service has never seen, and every render in a
  # token-protected deployment would answer 401.
  def token
    ENV["CHOPSHOP_BP_TOKEN"].presence
  end

  # One HTTP round trip, with this client's one rule about failure: anything the
  # TRANSPORT raises is a BlenderError, so a caller never sees a raw socket
  # error. The response's own STATUS is not classified here — that belongs to the
  # method that knows what shape it asked for.
  def request(method, url, headers: {}, body: nil, read_timeout: TIMEOUT)
    uri = URI(url)
    req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
    headers.each { |name, value| req[name] = value }
    req["Authorization"] = "Bearer #{token}" if token
    req.body = body if body
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = TIMEOUT
      http.read_timeout = read_timeout
      http.request(req)
    end
  rescue BlenderError
    raise
  rescue StandardError => e
    raise BlenderError, "blender service connection failed: #{e.message}"
  end

  def post(url, body, read_timeout: TIMEOUT)
    res = request(:post, url,
                  headers: { "Content-Type" => "application/json",
                             "Accept" => "#{SUCCESS_PNG}, #{SUCCESS_MANIFEST}" },
                  body: JSON.generate(body), read_timeout: read_timeout)
    parse(res, base: base_of(url))
  end

  # The base URL a render's frames are fetched from: the render URL without its
  # route. Derived rather than passed around, because a caller has exactly one
  # URL in hand and the files route hangs off the same base.
  def base_of(url)
    url.to_s.sub(%r{/#{OP}\z}, "")
  end

  # GET /health is the one public route: no token, so a studio that is merely
  # configured (not yet trusted) can still report whether the service is up. A
  # 503 here is the honest answer when the runner is up and Blender is not, so
  # it is REPORTED rather than raised: this is a health read, not a render.
  def health(base)
    res = request(:get, "#{base}/health", headers: { "Accept" => SUCCESS_MANIFEST })
    body = res.body.to_s
    parsed = (JSON.parse(body) if body.present?)
    if res.is_a?(Net::HTTPSuccess)
      (parsed || {}).with_indifferent_access
    else
      { "error" => "#{OP} #{res.code}: #{error_message(body)}", "status" => res.code.to_i }
    end
  rescue JSON::ParserError => e
    { "error" => "#{OP}: /health did not answer with JSON (#{e.message})" }
  rescue BlenderError => e
    { "error" => e.message }
  end

  # One geometry document in, one rendered frame or one frames manifest out.
  #
  # The return shape mirrors PlotClient.render's (name/bytes/content_type) so a
  # caller that stores a drawn SVG stores a rendered frame the same way, plus
  # the facts a 3D render carries and a drawing does not: `views`, the frame
  # names the manifest listed, and the exported GLB's name.
  def render(base, spec)
    unless spec.is_a?(Hash)
      raise SpecError, "a blender spec is a JSON object with an elements list, " \
                       "got #{spec.class}"
    end

    result = post("#{base}/#{OP}", { op: OP, spec: spec },
                  read_timeout: RENDER_READ_TIMEOUT)
    {
      name: result[:name],
      bytes: result[:bytes],
      content_type: result[:content_type],
      views: result[:views],
      frames: result[:frames],
      glb: result[:glb],
      entries: result[:entries],
      spec: spec
    }
  end

  # GET /files/<name>: the bytes of one file the service wrote — a frame from a
  # multi-view manifest, or the GLB export. Same shape as FluxClient.get_file's
  # callers expect (name/bytes/content_type), so a stored frame is written from
  # the same three fields wherever it came from.
  #
  # `name` arrives from the SERVICE (a manifest this studio did not write), so a
  # bare basename is the ONLY thing honoured: a name carrying a separator or a
  # parent is a refusal, never a path to resolve.
  def get_file(base, name)
    frame_name = name.to_s
    unless frame_name.match?(/\A[\w.\-]+\z/) && frame_name == File.basename(frame_name)
      raise SpecError, "blender frame name #{name.inspect} is not a bare filename"
    end

    res = request(:get, "#{base}/files/#{frame_name}",
                  headers: { "Accept" => SUCCESS_PNG }, read_timeout: FILE_READ_TIMEOUT)
    body = res.body.to_s
    if res.is_a?(Net::HTTPSuccess)
      return { name: frame_name, bytes: body,
               content_type: res["Content-Type"] || SUCCESS_PNG }
    end
    raise frame_refusal(res.code, body, frame_name)
  end

  # The name of the frame a caller is about to store. Host-agnostic and stable:
  # the digest of the bytes, not the time, so the same render stored twice is
  # the same file rather than two that look different.
  def png_name(body)
    "#{OP}-#{Digest::SHA256.hexdigest(body)[0, 12]}.png"
  end

  def png?(body)
    body.to_s.b.start_with?(PNG_SIGNATURE)
  end

  # THE rule the whole client is shaped around: the answer is read by CONTENT
  # TYPE and by what it actually is, and the two success shapes are told apart
  # rather than guessed at.
  def parse(res, base: nil)
    body = res.body.to_s
    if res.is_a?(Net::HTTPSuccess)
      return frame(body, res) if png?(body)
      return manifest(body, res, base) if manifest?(res, body)

      raise BlenderError, "#{OP} #{res.code}: expected a #{SUCCESS_PNG} frame or a " \
                          "#{SUCCESS_MANIFEST} frames manifest, got " \
                          "#{res['Content-Type'].presence || 'no content type'} " \
                          "(#{body.bytesize} bytes)"
    end
    raise refusal(res.code, body)
  end

  # views == 1: the frame IS the response body, so a render is one round trip
  # rather than two.
  def frame(body, res)
    { bytes: body, content_type: res["Content-Type"] || SUCCESS_PNG,
      name: png_name(body), views: 1, frames: nil, glb: nil, entries: nil }
  end

  # views > 1: a frames manifest. The frames are NOT in the response, so they
  # are fetched — the manifest names files on the runner's disk, which is
  # useless to a studio on another machine, and is exactly why GET /files/<name>
  # exists. Every frame is kept, in the manifest's own order, so a multi-view
  # render is a set rather than a single file with N-1 of them lost.
  def manifest(body, res, base)
    parsed = JSON.parse(body)
    unless parsed.is_a?(Hash)
      raise BlenderError, "#{OP} #{res.code}: expected a frames manifest, got " \
                          "#{parsed.class}"
    end

    names = Array(parsed["frames"]).map(&:to_s).reject(&:empty?)
    raise BlenderError, "#{OP} #{res.code}: the manifest named no frames" if names.empty?
    raise BlenderError, "#{OP}: no base URL to fetch the frames from" if base.blank?

    entries = names.map { |name| get_file(base, name) }
    first = entries.first

    { bytes: first[:bytes], content_type: first[:content_type], name: first[:name],
      views: entries.size, frames: names, glb: parsed["glb"].to_s.strip.presence,
      entries: entries }
  rescue JSON::ParserError => e
    raise BlenderError, "#{OP} #{res.code}: the frames manifest did not parse (#{e.message})"
  end

  # A manifest answers with JSON; a JSON body is also accepted with no content
  # type at all, because a hand-rolled service may omit it and the shape is
  # still unambiguous once the PNG check has failed.
  def manifest?(res, body)
    content_type = res["Content-Type"].to_s
    return true if content_type.include?(SUCCESS_MANIFEST)
    content_type.empty? && body.lstrip.start_with?("{")
  end

  # A refusal, classified. 503 means Blender is not on the runner at all — a
  # state a deployment is allowed to be in, and one the operator has to be told
  # the reason for rather than shown as a broken render. A 400/422 is the spec
  # being wrong: something the caller can fix, and something the form should
  # have caught.
  def refusal(code, body)
    message = "#{OP} #{code}: #{error_message(body)}"
    case code.to_i
    when 503 then Unavailable.new(message)
    when 400, 422 then SpecError.new(message)
    else BlenderError.new(message)
    end
  end

  def frame_refusal(code, body, name)
    message = "#{OP} #{code}: fetching frame #{name}: #{error_message(body)}"
    code.to_i == 503 ? Unavailable.new(message) : BlenderError.new(message)
  end

  # A refusal is a JSON envelope, but a proxy or a crash can answer with
  # anything: the body is the fallback rather than a second exception on top of
  # the first.
  def error_message(body)
    parsed = body.presence && JSON.parse(body)
    return body unless parsed.is_a?(Hash)
    parsed["error"].to_s.presence || body
  rescue JSON::ParserError
    body
  end

  # The base class, so RunJob rescues ONE thing and a caller can tell the three
  # cases apart when it wants to: a spec to fix, a renderer that is not there,
  # or the service itself failing.
  class BlenderError < StandardError; end

  # 503: the runner answered, and Blender is not on it.
  class Unavailable < BlenderError; end

  # 400/422: the geometry spec is invalid — a refusal the operator can act on.
  class SpecError < BlenderError; end
end
