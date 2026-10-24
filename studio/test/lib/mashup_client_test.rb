require "test_helper"

# The LM Studio mashup client. No server is contacted: the transport is swapped
# out and the arguments it receives are what gets asserted -- the same seam the
# flux client tests use, and for the same reason: this is the deterministic
# foundation for #50/#51, so the wire contract must be pinned without a live
# server (which is exactly the constraint the task set).
class MashupClientTest < ActiveSupport::TestCase
  BASE = "http://127.0.0.1:1234".freeze
  DEFAULT_SEED = 20_260_0101

  PROMPT = "a red phoenix rising from ashes".freeze
  RATIONALE = "Both sources name the phoenix; the rising pose is kept.".freeze

  # NO MODEL ALIAS IS BAKED INTO THE CLIENT, so every test that reaches the wire
  # has to configure one -- exactly as a deployment must. This is the same
  # argument the URL already makes: the client refuses when it is not configured,
  # and a test that ran without configuration would be testing a default no other
  # host has.
  setup do
    @saved_model = ENV[MashupClient::MODEL_ENV]
    ENV[MashupClient::MODEL_ENV] = "test-alias"
  end

  teardown do
    if @saved_model
      ENV[MashupClient::MODEL_ENV] = @saved_model
    else
      ENV.delete(MashupClient::MODEL_ENV)
    end
  end

  # Replace only the transport the block needs, and put it back afterwards even
  # if the block raises.
  def stub_transport(post: nil)
    swaps = { post: post }.compact
    originals = swaps.keys.to_h { |name| [ name, MashupClient.method(name) ] }
    swaps.each do |name, block|
      MashupClient.define_singleton_method(name) { |*args, **kwargs| block.call(*args, **kwargs) }
    end
    yield
  ensure
    originals.each { |name, original| MashupClient.define_singleton_method(name, original) }
  end

  # A real 200 response carrying the model's answer as a JSON string in
  # choices[0].message.content -- the same fake-response trick the flux client
  # tests use for parse, so parse_response sees exactly what it would see from
  # the wire.
  def ok_response(prompt: PROMPT, rationale: RATIONALE)
    content = { "prompt" => prompt, "rationale" => rationale }.to_json
    ok_choice(content)
  end

  def ok_choice(content)
    res = Net::HTTPOK.new("1.1", 200, "OK")
    res.instance_variable_set(:@body, { "choices" => [ { "message" => { "role" => "assistant",
                                                                       "content" => content } } ] }.to_json)
    def res.body; @body; end
    res
  end

  def http_error(code, message, body = nil)
    klass = {
      "400" => Net::HTTPBadRequest, "401" => Net::HTTPUnauthorized,
      "404" => Net::HTTPNotFound, "500" => Net::HTTPInternalServerError,
      "503" => Net::HTTPServiceUnavailable
    }.fetch(code.to_s)
    res = klass.new("1.1", code.to_s, message)
    res.instance_variable_set(:@body, body || { "error" => message }.to_json)
    def res.body; @body; end
    res
  end

  # --- the request --------------------------------------------------------

  test "one source prompt is synthesized into a single prompt plus its rationale" do
    calls = []
    stub_transport(post: ->(url, body, **_) { calls << [ url, body ]; ok_response }) do
      result = MashupClient.synthesize("a red phoenix rising from ashes", base: BASE)
      assert_equal PROMPT, result.prompt
      assert_equal RATIONALE, result.rationale
      assert_equal PROMPT, result.to_h[:prompt]
      assert_equal RATIONALE, result.to_h[:rationale]
    end
    url, body = calls.first
    assert_equal "#{BASE}/v1/chat/completions", url,
      "structured output is per-request on the OpenAI-compatible endpoint"
    assert_equal "system", body[:messages].first[:role]
    assert_match(/combine/i, body[:messages].first[:content])
    assert_match(/1\. a red phoenix/, body[:messages].last[:content])
    assert_equal DEFAULT_SEED, body[:seed], "the first mashup is seeded for determinism"
    assert_equal MashupClient::DEFAULT_TEMPERATURE, body[:temperature],
      "the first mashup is low-temperature by design"
  end

  test "N source prompts are combined in one request, numbered in order" do
    bodies = []
    stub_transport(post: ->(_url, body, **_) { bodies << body; ok_response }) do
      result = MashupClient.synthesize(
        [ "a red phoenix", "rising from ashes", "flat ink, three colours" ], base: BASE
      )
      assert_equal PROMPT, result.prompt
    end
    content = bodies.first[:messages].last[:content]
    assert_match(/3 source prompt/, content)
    assert_equal [ "1. a red phoenix", "2. rising from ashes",
                   "3. flat ink, three colours" ],
                 content.lines.map(&:strip).reject(&:empty?)[1..],
                 "the sources ride in the caller's order so the model can refer to them"
  end

  test "a blank slot in the source list is dropped, not sent as an empty prompt" do
    bodies = []
    stub_transport(post: ->(_url, body, **_) { bodies << body; ok_response }) do
      MashupClient.synthesize([ "a red phoenix", "  ", nil, "rising from ashes" ], base: BASE)
    end
    content = bodies.first[:messages].last[:content]
    refute_match(/^\d+\.\s*$/m, content)
    assert_match(/1\. a red phoenix/, content)
    assert_match(/2\. rising from ashes/, content)
  end

  # --- the wire contract ---------------------------------------------------

  test "the strict schema goes on the request as response_format" do
    bodies = []
    stub_transport(post: ->(_url, body, **_) { bodies << body; ok_response }) do
      MashupClient.synthesize("x", base: BASE)
    end
    format = bodies.first[:response_format]
    assert_equal "json_schema", format[:type]
    # The schema hash is defined with string keys (it is a verbatim wire
    # contract), so it is read with string keys here.
    schema = format[:json_schema]
    assert_equal "mashup", schema["name"]
    assert_equal true, schema["strict"]
    assert_equal %w[prompt rationale], schema["schema"]["required"]
    assert_equal false, schema["schema"]["additionalProperties"]
    assert_equal %w[prompt rationale], schema["schema"]["properties"].keys.sort,
      "the schema is exactly the two fields the design demands -- no more, no less"
  end

  test "the answer is parsed from choices[0].message.content as a JSON string" do
    stub_transport(post: ->(_url, _body, **_) { ok_response }) do
      result = MashupClient.synthesize("x", base: BASE)
      assert_equal PROMPT, result.prompt,
        "the model's answer is a JSON string in the message content, parsed here"
    end
  end

  test "a model override and the #51 temperature knobs ride on the request" do
    bodies = []
    stub_transport(post: ->(_url, body, **_) { bodies << body; ok_response }) do
      MashupClient.synthesize("x", base: BASE, model: "some-other-model",
                              temperature: 0.35, seed: 42)
    end
    assert_equal "some-other-model", bodies.first[:model]
    assert_equal 0.35, bodies.first[:temperature]
    assert_equal 42, bodies.first[:seed]
  end

  # --- errors --------------------------------------------------------------

  test "an unparseable answer is refused, not salvaged" do
    stub_transport(post: ->(_url, _body, **_) { ok_choice("this is not JSON") }) do
      error = assert_raises(MashupClient::MashupError) { MashupClient.synthesize("x", base: BASE) }
      assert_match(/not a JSON object/, error.message)
      assert_match(/this is not JSON/, error.message)
    end
  end

  test "a truncated JSON string is refused rather than partially parsed" do
    stub_transport(post: ->(_url, _body, **_) { ok_choice('{"prompt": "a phoenix') }) do
      error = assert_raises(MashupClient::MashupError) { MashupClient.synthesize("x", base: BASE) }
      assert_match(/not a JSON object/, error.message)
    end
  end

  test "an answer missing a field is refused with the schema named" do
    stub_transport(post: ->(_url, _body, **_) { ok_choice({ "prompt" => "a phoenix" }.to_json) }) do
      error = assert_raises(MashupClient::MashupError) { MashupClient.synthesize("x", base: BASE) }
      assert_match(/rationale missing/, error.message)
    end
  end

  test "an answer with a field the schema does not allow is refused" do
    stub_transport(post: ->(_url, _body, **_) do
      ok_choice({ "prompt" => "a phoenix", "rationale" => "r", "extra" => "x" }.to_json)
    end) do
      error = assert_raises(MashupClient::MashupError) { MashupClient.synthesize("x", base: BASE) }
      assert_match(/unexpected/, error.message)
      assert_match(/strict schema/, error.message)
    end
  end

  test "a blank field in an otherwise valid answer is refused" do
    stub_transport(post: ->(_url, _body, **_) do
      ok_choice({ "prompt" => "   ", "rationale" => "r" }.to_json)
    end) do
      error = assert_raises(MashupClient::MashupError) { MashupClient.synthesize("x", base: BASE) }
      assert_match(/blank/, error.message)
    end
  end

  test "an empty choices list or missing message is refused, not indexed blindly" do
    res = Net::HTTPOK.new("1.1", 200, "OK")
    res.instance_variable_set(:@body, { "choices" => [] }.to_json)
    def res.body; @body; end
    stub_transport(post: ->(_url, _body, **_) { res }) do
      error = assert_raises(MashupClient::MashupError) { MashupClient.synthesize("x", base: BASE) }
      assert_match(/no mashup answer/, error.message)
    end
  end

  test "a non-200 carries the service's own message and status" do
    stub_transport(post: ->(_url, _body, **_) { http_error(503, "model not loaded") }) do
      error = assert_raises(MashupClient::MashupError) { MashupClient.synthesize("x", base: BASE) }
      assert_match(/503/, error.message)
      assert_match(/model not loaded/, error.message)
    end
  end

  test "a non-200 without a JSON error body falls back to the raw body" do
    res = http_error(500, "Internal Server Error", "boom")
    stub_transport(post: ->(_url, _body, **_) { res }) do
      error = assert_raises(MashupClient::MashupError) { MashupClient.synthesize("x", base: BASE) }
      assert_match(/500/, error.message)
      assert_match(/boom/, error.message)
    end
  end

  test "an unreachable server is a MashupError, not a raw socket error" do
    # The real transport, against a port nothing listens on: this is the wrapping
    # the app relies on, so it must be exercised rather than stubbed.
    error = assert_raises(MashupClient::MashupError) do
      MashupClient.synthesize("x", base: "http://127.0.0.1:1")
    end
    assert_match(/connection failed/, error.message)
  end

  test "a MashupError from the transport is not re-wrapped on the way out" do
    stub_transport(post: ->(_url, _body, **_) do
      raise MashupClient::MashupError, "LM Studio returned 401: bad key"
    end) do
      error = assert_raises(MashupClient::MashupError) { MashupClient.synthesize("x", base: BASE) }
      assert_match(/LM Studio returned 401/, error.message)
    end
  end

  # --- configuration and refusal --------------------------------------------

  test "an empty prompt list is refused before anything is sent" do
    sent = false
    stub_transport(post: ->(_url, _body, **_) { sent = true; ok_response }) do
      error = assert_raises(MashupClient::MashupError) { MashupClient.synthesize([], base: BASE) }
      assert_match(/at least one source prompt/, error.message)
      refute sent, "a refused mashup must not reach the network"
    end
  end

  test "a list of only blanks is refused the same way" do
    error = assert_raises(MashupClient::MashupError) do
      MashupClient.synthesize([ "", "  ", nil ], base: BASE)
    end
    assert_match(/at least one source prompt/, error.message)
  end

  test "the base URL is read from the studio's env var, and an unset one is refused" do
    original_url = ENV[MashupClient::URL_ENV]
    original_model = ENV[MashupClient::MODEL_ENV]
    begin
      ENV[MashupClient::URL_ENV] = BASE
      assert_equal BASE, MashupClient.configured_url

      ENV.delete(MashupClient::URL_ENV)
      error = assert_raises(MashupClient::MashupError) { MashupClient.configured_url }
      assert_match(/#{MashupClient::URL_ENV}/, error.message,
        "the refusal names the env var the operator must set")
      refute_match(/127\.0\.0\.1|localhost/, error.message,
        "no hostname is baked into the app")
    ensure
      original_url.nil? ? ENV.delete(MashupClient::URL_ENV) : ENV[MashupClient::URL_ENV] = original_url
      original_model.nil? ? ENV.delete(MashupClient::MODEL_ENV) : ENV[MashupClient::MODEL_ENV] = original_model
    end
  end

  test "a trailing slash on the base URL does not double up on the route" do
    bodies = []
    stub_transport(post: ->(url, body, **_) { bodies << [ url, body ]; ok_response }) do
      MashupClient.synthesize("x", base: "#{BASE}/")
    end
    assert_equal "#{BASE}/v1/chat/completions", bodies.first.first
  end

  test "the model comes from configuration, and an unset one refuses rather than guessing" do
    original = ENV[MashupClient::MODEL_ENV]
    begin
      ENV.delete(MashupClient::MODEL_ENV)
      # No alias is baked in: a code default naming one server's alias is a host
      # fact that works only on the box that wrote it. Unset must REFUSE and name
      # the variable, not send an empty model the server answers with an opaque 400.
      err = assert_raises(MashupClient::MashupError) { MashupClient.chosen_model(nil) }
      assert_match(/CHOPSHOP_STUDIO_LMSTUDIO_MODEL/, err.message,
        "the refusal must name the variable, or the reader cannot act on it")
      ENV[MashupClient::MODEL_ENV] = "operator-model"
      assert_equal "operator-model", MashupClient.chosen_model(nil)
      assert_equal "caller-model", MashupClient.chosen_model("caller-model"),
        "an explicit override wins over the configuration"
    ensure
      original.nil? ? ENV.delete(MashupClient::MODEL_ENV) : ENV[MashupClient::MODEL_ENV] = original
    end
  end

  test "the synthesis is frozen, so a caller cannot mutate the result" do
    result = MashupClient::MashupResult.new(prompt: "p", rationale: "r")
    assert result.frozen?
    assert_raises(FrozenError) { result.instance_variable_set(:@prompt, "x") }
  end

  # #13: the rationale is the model's OWN account of the merge, measured live to
  # assert merges that did not happen and invent shared subjects the sources never
  # shared. The comment on MashupResult used to call it "the provenance the
  # mashup UX shows beside the result" -- the claim this pins against.
  test "the rationale is documented as the model's account, not provenance" do
    comment = Rails.root.join("app/lib/mashup_client.rb").read
    block = comment[/# The synthesis.*?\n  class MashupResult/m]
    refute_nil block, "the MashupResult comment must be readable"
    assert_match(/model's account/i, block)
    refute_match(/is the provenance/, block,
      "the rationale is the model's account (#13), not provenance")
  end

  # --- the REAL transport, with nothing stubbed -----------------------------
  #
  # Every test above replaces `post`, so they pin the CONTRACT and prove nothing
  # about the implementation -- and a client that parsed its own response and
  # then parsed it AGAIN passed all of them while every live mashup was a 500
  # (`undefined method 'body' for an instance of Hash`, because `post` returned a
  # Hash and `synthesize` called `parse_response` on it). The stub returned the
  # shape the REAL `post` never produced, so the seam agreed with a bug.
  #
  # These two run the shipped `post` + `parse_response` over a loopback socket,
  # which is the only thing that exercises both halves together.

  # A server that accepts one connection, reads the request, answers with exactly
  # these bytes and closes. Ephemeral port, so the suite runs beside anything.
  def with_stub_service(status: "200 OK", body: "")
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      socket = server.accept
      length = 0
      while (line = socket.gets)
        break if line == "\r\n"
        length = line.split(":", 2).last.to_i if line =~ /\AContent-Length:/i
      end
      socket.read(length) if length.positive?
      socket.write("HTTP/1.1 #{status}\r\n")
      socket.write("Content-Type: application/json\r\n")
      socket.write("Content-Length: #{body.bytesize}\r\n")
      socket.write("Connection: close\r\n\r\n")
      socket.write(body)
      socket.close
    end
    yield "http://127.0.0.1:#{port}"
  ensure
    thread&.join(2)
    thread&.kill
    server&.close
  end

  # The answer shape LM Studio actually sends: the mashup JSON as a STRING in
  # choices[0].message.content.
  def wire_answer(prompt: PROMPT, rationale: RATIONALE)
    { "model" => "some-alias",
      "choices" => [ { "message" => { "role" => "assistant",
                                      "content" => { "prompt" => prompt,
                                                     "rationale" => rationale }.to_json } } ] }.to_json
  end

  test "a live answer over a real socket is parsed once, not twice" do
    with_stub_service(body: wire_answer) do |url|
      result = MashupClient.synthesize("a red phoenix rising from ashes", base: url)
      assert_equal PROMPT, result.prompt,
        "post must hand back the response and synthesize must parse it — exactly once"
      assert_equal RATIONALE, result.rationale
    end
  end

  test "a real refusal over a socket surfaces as a MashupError naming the status" do
    with_stub_service(status: "503 Service Unavailable",
                      body: { "error" => "No models loaded. Please load a model." }.to_json) do |url|
      error = assert_raises(MashupClient::MashupError) do
        MashupClient.synthesize("a red phoenix", base: url)
      end
      assert_match(/503/, error.message)
      assert_match(/No models loaded/, error.message,
        "the service's own message is what the operator needs to read")
    end
  end

  # The bearer token is the difference between a working Mash and LM Studio's
  # 401 (#87). Request construction is pinned directly, below the stubbed
  # transport seam, so the header cannot silently regress.
  test "build_request carries the bearer token when the env is set" do
    prior = ENV["CHOPSHOP_STUDIO_LMSTUDIO_TOKEN"]
    ENV["CHOPSHOP_STUDIO_LMSTUDIO_TOKEN"] = "tok-123"
    req = MashupClient.build_request(URI("#{BASE}/v1/chat/completions"), { "a" => 1 })
    assert_equal "Bearer tok-123", req["Authorization"]
  ensure
    prior ? ENV["CHOPSHOP_STUDIO_LMSTUDIO_TOKEN"] = prior : ENV.delete("CHOPSHOP_STUDIO_LMSTUDIO_TOKEN")
  end

  test "build_request sends no Authorization header when the token env is unset" do
    prior = ENV.delete("CHOPSHOP_STUDIO_LMSTUDIO_TOKEN")
    req = MashupClient.build_request(URI("#{BASE}/v1/chat/completions"), { "a" => 1 })
    assert_nil req["Authorization"], "no token configured means no header, never an empty bearer"
    assert_equal "application/json", req["Content-Type"]
    assert_equal({ "a" => 1 }.to_json, req.body)
  ensure
    ENV["CHOPSHOP_STUDIO_LMSTUDIO_TOKEN"] = prior if prior
  end
end
