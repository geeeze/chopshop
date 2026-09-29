# Thin HTTP client for the chopshop-plot serve surface (that repo's
# docs/contract.md, "The service surface"). Ruby stdlib only, like RunnerClient
# and FluxClient, so the app runs on the default bundle.
#
# This is deliberately a THIRD protocol, not the runner contract. The runner
# contract's POST /jobs means "run the pipeline" — prep, trace, gate — and a plot
# runner traces nothing: it renders a geometry spec, a metrics digest or a
# cross-run query, and answers with one SVG document. Bending /jobs to also mean
# "draw me a chart" would make one contract mean two things, so the studio speaks
# the service's own surface, the same way it speaks flux's.
#
# The one rule that shapes every method here: SUCCESS IS THE SVG ITSELF
# (`image/svg+xml`), and every refusal is a JSON envelope
# (`{"error": …, "kind": …}`). So the answer is read by content type rather than
# guessed at, and a 200 that is not an SVG document is an error rather than
# bytes that would be stored as a candidate and fail later.
require "net/http"
require "json"
require "digest"

module PlotClient
  # Drawing an SVG is cheap — no model, no GPU, no queue — but a query body
  # carries run records, so it gets the same 15s as every other call and no more.
  TIMEOUT = 15

  module_function

  def post(url, body, read_timeout: TIMEOUT)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req["Accept"] = "image/svg+xml, application/json"
    req["Authorization"] = "Bearer #{token}" if token
    req.body = JSON.generate(body)
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = TIMEOUT
      http.read_timeout = read_timeout
      http.request(req)
    end
    parse_svg(res)
  rescue PlotError
    raise
  rescue StandardError => e
    raise PlotError, "plot service connection failed: #{e.message}"
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
    parse_json(res)
  rescue PlotError
    raise
  rescue StandardError => e
    raise PlotError, "plot service connection failed: #{e.message}"
  end

  # GET /health is the one public route: no token, so a studio that is merely
  # configured (not yet trusted) can still report whether the service is up. The
  # nav's runner pill reads the same route through RunnerClient; this is the
  # client's own view of it, with the engine's facts attached.
  def health(base)
    get("#{base}/health")
  rescue StandardError => e
    { error: e.message }
  end

  # The three operations. Each sends the contract's envelope — `op` and `spec` —
  # so a document sent to the wrong operation is REFUSED by the service rather
  # than best-effort drawn as something it was not.
  def generate(base, spec)
    render(base, "generate", spec)
  end

  def digest(base, spec)
    render(base, "digest", spec)
  end

  # `runs` is a list of run records (`.run.json`), the same set the archive
  # spine holds. It is transport rather than spec: the service strips it before
  # applying the envelope rule, so a bare chart spec works beside it.
  def query(base, runs, spec)
    unless runs.is_a?(Array) && runs.any?
      raise PlotError, "a query needs run records: pass the .run.json records as an array"
    end
    render(base, "query", spec, runs: runs)
  end

  # One operation, one round trip, one SVG. The return shape mirrors
  # FluxClient.render's (name/bytes/content_type) so a caller that handles a
  # generated raster handles a generated vector the same way.
  #
  # `name` is derived from the SVG's own bytes rather than from a clock: a
  # generated geometry can be asked for twice and must not then look like two
  # different sources. It is a basename, so writing it to storage/uploads is
  # enough.
  def render(base, op, spec, runs: nil)
    body = { op: op, spec: spec }
    body[:runs] = runs if runs
    result = post("#{base}/#{op}", body)
    {
      name: result[:name],
      bytes: result[:bytes],
      content_type: result[:content_type],
      op: op,
      spec: spec
    }
  end

  def token
    ENV["CHOPSHOP_PLOT_TOKEN"].presence
  end

  # An SVG DOCUMENT may legitimately open with an XML declaration, a byte-order
  # mark, or leading whitespace -- `<?xml version="1.0" encoding="utf-8"?>` is
  # part of a valid SVG, and the compose operation emits exactly that. A check of
  # `body.start_with?("<svg")` therefore REJECTS a perfectly good document, which
  # is how every composite holding a vector layer failed with "expected an SVG
  # document, got image/svg+xml" while the service was answering 200 with the
  # right bytes. Match the ROOT ELEMENT, after an optional declaration/BOM.
  SVG_DOCUMENT = /\A(?:\xEF\xBB\xBF)?\s*(?:<\?xml[^>]*\?>\s*)?<svg[\s>]/n.freeze

  def svg_document?(body)
    body.to_s.b.match?(SVG_DOCUMENT)
  end

  # The name of the document a caller is about to store. Host-agnostic and
  # stable: the digest, not the time.
  def svg_name(body)
    "plot-#{Digest::SHA256.hexdigest(body)[0, 12]}.svg"
  end

  def parse_svg(res)
    body = res.body.to_s
    if res.is_a?(Net::HTTPSuccess)
      unless svg_document?(body)
        raise PlotError, "plot #{res.code}: expected an SVG document, got " \
                         "#{res['Content-Type'] || 'no content type'} " \
                         "(#{body.bytesize} bytes)"
      end
      return { bytes: body, content_type: res["Content-Type"], name: svg_name(body) }
    end
    raise PlotError.new("plot #{res.code}: #{error_message(body)}")
  end

  def parse_json(res)
    body = res.body.to_s
    parsed = body.presence && JSON.parse(body)
    if res.is_a?(Net::HTTPSuccess)
      (parsed || {}).with_indifferent_access
    else
      raise PlotError.new("plot #{res.code}: #{error_message(body)}")
    end
  rescue JSON::ParserError => e
    raise PlotError, "plot #{res.code}: the service did not answer with JSON (#{e.message})"
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

  class PlotError < StandardError; end
end
