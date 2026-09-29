# Thin HTTP client for the svg runner's compose operation — the vector-
# preserving merge of a composite's layers (that repo's composer, reached as
# POST /compose). Ruby stdlib only, like RunnerClient, PlotClient and
# FluxClient, so the app runs on the default bundle.
#
# The rule that shapes this client, exactly as it shapes PlotClient: SUCCESS IS
# THE SVG ITSELF (`image/svg+xml`), and every refusal is a JSON envelope
# (`{"error": …, "kind": …}`). So the answer is read by what arrived and not by
# the status alone — a 200 that is not an SVG document is an error rather than
# bytes that would be stored as a composite artefact and fail later, at the
# runner, where nobody is looking.
#
# Why this exists at all: a raster flatten of a traced source re-tracing it is a
# fidelity loss with no upside. The compose operation merges the vectors
# themselves, so a composite of traces stays a trace — and this client is the
# studio's end of it.
require "net/http"
require "json"
require "digest"

module ComposeClient
  # Composing is bundle assembly on the runner (parse N documents, merge, write
  # one), not a model call: the same 15s every non-Jev call gets.
  TIMEOUT = 15

  # The operation's route on an svg runner, appended to the runner's base URL.
  PATH = "/compose".freeze

  module_function

  # Merge a composite's layers server-side and answer the SVG.
  #
  # `spec` is ComposeSpec's document, verbatim. The envelope (`op` + `spec`) is
  # the runner's, so a document sent to the wrong operation is REFUSED by the
  # service rather than best-effort composed as something it was not.
  #
  # The return shape mirrors FluxClient.render's and PlotClient.render's
  # (name/bytes/content_type), so a caller that stores a generated raster stores
  # a generated vector the same way.
  def compose(base, spec, read_timeout: TIMEOUT)
    raise ComposeError, "no svg runner is configured to compose against" if base.blank?

    result = post("#{base}#{PATH}", { op: "compose", spec: compact(spec) },
                  read_timeout: read_timeout)
    result.merge(op: "compose", spec: spec)
  end

  # A nil-valued key is omitted rather than sent as null: the contract makes
  # `palette` optional, and "no palette" is the same statement as an absent key —
  # while a strict service may refuse a null where it expects a list. The recipe
  # endpoint still carries the key explicitly (null), so a reader sees what the
  # field is even when it is empty.
  def compact(spec)
    spec.reject { |_key, value| value.nil? }
  end

  def post(url, body, read_timeout: TIMEOUT)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    # Both answers are legitimate: the SVG on success, the envelope on refusal.
    req["Accept"] = "image/svg+xml, application/json"
    req["Authorization"] = "Bearer #{token}" if token
    req.body = JSON.generate(body)
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = TIMEOUT
      http.read_timeout = read_timeout
      http.request(req)
    end
    parse_svg(res)
  rescue ComposeError
    raise
  rescue StandardError => e
    raise ComposeError, "compose service connection failed: #{e.message}"
  end

  def token
    ENV["RUNNER_TOKEN"].presence
  end

  # The name of the document a caller is about to store. Host-agnostic and
  # stable: the digest, not the clock — composing the same composite twice must
  # not look like two different artefacts.
  def svg_name(body)
    "compose-#{Digest::SHA256.hexdigest(body)[0, 12]}.svg"
  end

  def parse_svg(res)
    body = res.body.to_s
    if res.is_a?(Net::HTTPSuccess)
      unless body.start_with?("<svg")
        raise ComposeError, "compose #{res.code}: expected an SVG document, got " \
                            "#{res['Content-Type'] || 'no content type'} " \
                            "(#{body.bytesize} bytes)"
      end
      return { bytes: body, content_type: res["Content-Type"].presence || "image/svg+xml",
               name: svg_name(body) }
    end

    raise ComposeError, "compose #{res.code}: #{error_message(body)}"
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

  class ComposeError < StandardError; end
end
