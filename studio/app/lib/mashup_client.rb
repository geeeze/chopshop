# Synthesizes N>=1 library prompts into ONE image-generation prompt, via the
# LM Studio server that shares the GPU box (issue #47).
#
# A thin HTTP client in the FluxClient shape: Ruby stdlib only, timeouts as
# constants, every failure surfaced as a MashupError with a clear message, and
# the wire contract verified live against LM Studio (the design note is
# skills/chopshop-studio/references/datasets-library.md).
#
# WHY the OpenAI-compatible endpoint: LM Studio's structured output is
# PER-REQUEST on POST /v1/chat/completions, carried in `response_format`. The
# native /api/v1/chat endpoint rejects response_format outright, so it is not
# used here -- every structured-output key is refused there.
#
# The answer comes back as a JSON STRING in choices[0].message.content (not
# output[0].content, which is the native endpoint's shape). It is parsed here
# and held to exactly the two-field contract the request demanded: a malformed
# or partial answer is a failed mashup, not a mangled prompt.
require "net/http"
require "json"

module MashupClient
  # Bounding the connection is cheap; synthesis is not. A small local model
  # answers in a couple of seconds, but a cold load or a contended GPU box does
  # not, so the read timeout is minutes rather than the connect timeout's
  # seconds -- the same reasoning as FluxClient's generate timeout.
  TIMEOUT = 15
  MASHUP_READ_TIMEOUT = 120

  # The FIRST mashup is deterministic by design: low temperature and a fixed
  # seed, so the same N sources synthesize the same prompt. The iterative UX
  # (#51) escapes that determinism by raising the temperature per advance --
  # which is why both ride on the request as overridable knobs with defaults
  # rather than being baked into the call.
  DEFAULT_TEMPERATURE = 0.2
  DEFAULT_SEED = 20_260_0101

  # The service's base URL and model are OPERATOR settings, read at call time
  # from the environment like every other fleet client (FluxClient.token, the
  # CHOPSHOP_FLUX_* pair in the runner). The URL var names the same box
  # CHOPSHOP_FLUX_LMSTUDIO_URL names on the flux side, but this is the
  # STUDIO's own service, so it carries the studio's own var.
  #
  # The model default is the geenet-flash ALIAS on the box, not the raw
  # checkpoint id: an alias is what the operator pinned and what survives the
  # operator swapping the underlying weights.
  URL_ENV = "CHOPSHOP_STUDIO_LMSTUDIO_URL".freeze
  MODEL_ENV = "CHOPSHOP_STUDIO_LMSTUDIO_MODEL".freeze
  TOKEN_ENV = "CHOPSHOP_STUDIO_LMSTUDIO_TOKEN".freeze
  DEFAULT_MODEL = "geenet-flash".freeze

  # The strict JSON contract, verbatim. This goes on the wire as
  # response_format.json_schema, and the parsed answer is held to exactly these
  # two fields: the schema says additionalProperties: false, so an answer with
  # anything else is a contract violation, not a superset to be tolerated.
  SCHEMA = {
    "name" => "mashup",
    "strict" => true,
    "schema" => {
      "type" => "object",
      "properties" => {
        "prompt" => { "type" => "string" },
        "rationale" => { "type" => "string" }
      },
      "required" => %w[prompt rationale],
      "additionalProperties" => false
    }
  }.freeze

  # What the model is asked to do, and the one thing it may not do: invent
  # subject matter. Merging the shared concrete subject and the descriptors is
  # the job; a mashup that adds a subject no source named is a fabrication
  # wearing the sources' clothes.
  SYSTEM_PROMPT = <<~TEXT.freeze
    You synthesize image-generation prompts. You are given source prompts drawn
    from a prompt library. Combine them into ONE image-generation prompt: keep
    the concrete subject the sources share, merge their descriptors, and
    elaborate the descriptors where that makes the single prompt clearer. Do
    NOT introduce any subject, object, person, place, or action that is absent
    from every source prompt. Answer with JSON only: "prompt" is the single
    synthesized image-generation prompt, and "rationale" is one or two
    sentences in third person explaining what was merged and why.
  TEXT

  # The synthesis, and the model's account of it. Both are kept: the rationale
  # is the provenance the mashup UX shows beside the result (#50/#51), so the
  # operator can judge a merge without re-reading every source.
  class MashupResult
    attr_reader :prompt, :rationale

    def initialize(prompt:, rationale:)
      @prompt = prompt.to_s
      @rationale = rationale.to_s
      freeze
    end

    def to_h
      { prompt: @prompt, rationale: @rationale }
    end
  end

  class MashupError < StandardError; end

  module_function

  # The mashup itself. `prompts` is one source prompt or a list of them (N>=1;
  # 2 is the common case). `base`, `model`, `temperature` and `seed` exist so
  # tests and #51's temperature escalation can drive the request explicitly;
  # each defaults to the deterministic first mashup against the configured
  # service.
  def synthesize(prompts, base: nil, model: nil,
                 temperature: DEFAULT_TEMPERATURE, seed: DEFAULT_SEED)
    # A single prompt and a list of prompts are the same call; a blank slot is
    # dropped rather than sent as an empty string the model would have to
    # interpret -- the same rule FluxClient.render applies to references.
    sources = Array(prompts).map { |p| p.to_s.strip }.reject(&:empty?)
    if sources.empty?
      raise MashupError, "a mashup needs at least one source prompt"
    end

    url = configured_url(base)
    body = {
      model: chosen_model(model),
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: user_message(sources) }
      ],
      temperature: temperature,
      seed: seed,
      stream: false,
      response_format: { type: "json_schema", json_schema: SCHEMA }
    }
    res = post("#{url}/v1/chat/completions", body, read_timeout: MASHUP_READ_TIMEOUT)
    MashupResult.new(**validate_answer(parse_response(res)))
  end

  # --- configuration -------------------------------------------------------

  # The configured base URL, trailing slashes trimmed so the route can be
  # joined without a doubled one. Refuses to guess: an unset URL is an
  # operator error named as such, never a default host.
  def configured_url(base = nil)
    url = base.presence || ENV[URL_ENV].to_s.strip
    url = url.sub(%r{/+\z}, "")
    if url.empty?
      raise MashupError,
            "LM Studio is not configured for mashups: set #{URL_ENV} to the " \
            "server's base URL (no hostname is baked into the app)"
    end
    url
  end

  def chosen_model(override)
    override.presence || ENV[MODEL_ENV].presence || DEFAULT_MODEL
  end

  # The server's bearer token, sent when configured (LM Studio's server-side
  # auth) -- the same shape as FluxClient.token. Absent means no header; an
  # unauthenticated server answers 401 and that surfaces as a MashupError.
  def token
    ENV[TOKEN_ENV].presence
  end

  # --- the request ---------------------------------------------------------

  # The source prompts, numbered, so the model can refer to them and so a
  # human reading the request can audit what went in.
  def user_message(sources)
    list = sources.each_with_index.map { |p, i| "#{i + 1}. #{p}" }.join("\n")
    "Combine these #{sources.length} source prompt(s) into ONE " \
    "image-generation prompt:\n\n#{list}"
  end

  # TRANSPORT ONLY: hand the raw Net::HTTP response back to the caller and let
  # `parse_response` decide what it means. This is the seam the tests stub (they
  # return a response object, never a parsed body), and it is the ONE thing that
  # separates a stubbed pass from a live one: this method used to call
  # `parse_response(res)` and return a Hash, so `synthesize` parsed a SECOND time
  # and died on `Hash#body` — every test green, every live mashup a 500.
  #
  # The rescue clauses stay here because a socket failure has no response to
  # return: an unreachable or timed-out server must surface as a MashupError, not
  # a raw ECONNREFUSED -- the same wrapping FluxClient.post does, because every
  # caller in this app rescues MashupError, not socket errors.
  def post(url, body, read_timeout: TIMEOUT)
    # Request construction lives in build_request so a test can pin the
    # headers without a socket: the bearer token is the difference between a
    # working Mash and LM Studio's 401 (#87).
    uri = URI(url)
    req = build_request(uri, body)
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = TIMEOUT
      http.read_timeout = read_timeout
      http.request(req)
    end
  rescue MashupError
    raise
  rescue StandardError => e
    raise MashupError, "LM Studio connection failed: #{e.message}"
  end

  def build_request(uri, body)
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json"
    req["Authorization"] = "Bearer #{token}" if token
    req.body = JSON.generate(body)
    req
  end

  # A non-200 is the service's answer about the request, so its own message is
  # carried through (LM Studio's error shape when there is one, the raw body
  # otherwise), truncated so a huge body cannot bloat the log or the UI.
  def parse_response(res)
    body = res.body.to_s
    parsed = parse_json(body)
    return parsed || {} if res.is_a?(Net::HTTPSuccess)

    message = parsed.is_a?(Hash) ? (parsed["error"] || parsed["message"]) : nil
    message = body if message.blank?
    raise MashupError,
          "LM Studio returned #{res.code}: #{message.to_s.strip[0, 300]}"
  end

  # choices[0].message.content is the answer, as a JSON STRING. Parse it, then
  # hold the parsed object to the contract the request demanded: exactly the
  # two fields the schema names, both present and non-blank. No regex salvage,
  # no guessing -- a malformed answer is a failed mashup.
  def validate_answer(meta)
    content = meta.is_a?(Hash) ? meta.dig("choices", 0, "message", "content") : nil
    if content.blank?
      raise MashupError,
            "LM Studio returned no mashup answer (choices[0].message.content " \
            "was empty or missing)"
    end

    answer = parse_json(content.to_s)
    unless answer.is_a?(Hash)
      raise MashupError,
            "LM Studio's mashup answer is not a JSON object: " \
            "#{content.to_s.strip[0, 200]}"
    end

    unexpected = answer.keys - %w[prompt rationale]
    missing = %w[prompt rationale] - answer.keys
    if unexpected.any? || missing.any?
      raise MashupError,
            "LM Studio's mashup answer does not match the strict schema " \
            "(#{missing.join(', ')} missing, #{unexpected.join(', ')} " \
            "unexpected): #{content.to_s.strip[0, 200]}"
    end

    prompt = answer["prompt"]
    rationale = answer["rationale"]
    unless prompt.is_a?(String) && rationale.is_a?(String) &&
           prompt.strip.present? && rationale.strip.present?
      raise MashupError,
            "LM Studio's mashup answer has a blank or non-string prompt or " \
            "rationale: #{content.to_s.strip[0, 200]}"
    end

    { prompt: prompt.strip, rationale: rationale.strip }
  end

  def parse_json(text)
    return nil if text.blank?

    JSON.parse(text)
  rescue JSON::ParserError
    nil
  end
end
