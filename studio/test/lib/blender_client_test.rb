require "test_helper"
require "socket"

# The chopshop-plot BLENDER operation's client. No service is contacted: the
# transport is swapped out where the arguments matter, and the RESPONSE parsing
# is exercised over a real socket, because that is where this client differs
# from every other one in the app: success is EITHER a PNG frame (views == 1)
# OR a JSON frames manifest (views > 1) whose frames are then fetched, and the
# two are told apart by what the answer IS rather than by what it says.
#
# Net::HTTPResponse#body= is a no-op and #body reads the socket, so a hand-built
# response cannot carry a body at all. A loopback server that answers with
# canned bytes — and, for the manifest case, that answers the frame fetches too
# — is the honest way to test what the client does with them.
class BlenderClientTest < ActiveSupport::TestCase
  BASE = "http://127.0.0.1:8796".freeze

  # A real PNG header, so the client's signature check is exercised rather than
  # bypassed: the bytes after the magic number are arbitrary.
  PNG = "\x89PNG\r\n\x1a\n".b + "frame-one".b
  PNG_TWO = "\x89PNG\r\n\x1a\n".b + "frame-two".b

  SPEC = { "elements" => [{ "type" => "rect", "x" => 0, "y" => 0,
                            "width" => 10, "height" => 10 }] }.freeze

  def stub_transport(post: nil)
    swaps = { post: post }.reject { |_, v| v.nil? }
    originals = swaps.keys.to_h { |name| [name, BlenderClient.method(name)] }
    swaps.each do |name, block|
      BlenderClient.define_singleton_method(name) { |*args, **kwargs| block.call(*args, **kwargs) }
    end
    yield
  ensure
    originals.each { |name, original| BlenderClient.define_singleton_method(name, original) }
  end

  def ok_frame(body = PNG)
    { bytes: body, content_type: "image/png", name: BlenderClient.png_name(body),
      views: 1, frames: nil, glb: nil, entries: nil }
  end

  # A server that accepts N connections in order, reads each request, answers
  # with the next canned response and closes. Ephemeral port, so the suite can
  # run beside anything — and one connection per response, because each
  # Net::HTTP.start in the client is its own connection.
  def with_stub_service(*responses)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    queue = responses.flatten.dup
    thread = Thread.new do
      queue.each do |response|
        socket = server.accept
        length = 0
        while (line = socket.gets)
          break if line == "\r\n"
          length = line.split(":", 2).last.to_i if line =~ /\AContent-Length:/i
        end
        socket.read(length) if length.positive?
        socket.write("HTTP/1.1 #{response[:status] || '200 OK'}\r\n")
        socket.write("Content-Type: #{response[:content_type] || 'application/json'}\r\n")
        socket.write("Content-Length: #{response[:body].to_s.bytesize}\r\n")
        socket.write("Connection: close\r\n\r\n")
        socket.write(response[:body].to_s)
        socket.close
      end
    end
    yield "http://127.0.0.1:#{port}"
  ensure
    thread&.join(2)
    thread&.kill
    server&.close
  end

  # -- the envelope ---------------------------------------------------------

  test "render posts the contract's envelope to /blender" do
    calls = []
    stub_transport(post: ->(url, body, **_) { calls << [url, body]; ok_frame }) do
      BlenderClient.render(BASE, SPEC)
    end
    assert_equal "#{BASE}/blender", calls.first.first
    assert_equal({ op: "blender", spec: SPEC }, calls.first.last,
      "the op is sent explicitly, so a document sent to the wrong operation is refused")
  end

  test "render refuses a spec that is not a document rather than posting it" do
    stub_transport(post: ->(*_a, **_k) { flunk "nothing may be posted without a document" }) do
      error = assert_raises(BlenderClient::SpecError) { BlenderClient.render(BASE, nil) }
      assert_match(/JSON object/, error.message)
      assert_raises(BlenderClient::SpecError) { BlenderClient.render(BASE, "elements") }
    end
  end

  # -- the two success shapes ----------------------------------------------

  test "views == 1 comes back as the frame itself, with a name derived from its bytes" do
    with_stub_service(status: "200 OK", content_type: "image/png", body: PNG) do |base|
      result = BlenderClient.render(base, SPEC)
      assert_equal PNG, result[:bytes]
      assert_equal "image/png", result[:content_type]
      assert_equal 1, result[:views]
      assert_nil result[:frames], "a single frame has no manifest"
      assert_nil result[:glb]
      assert_match(/\Ablender-[0-9a-f]{12}\.png\z/, result[:name],
        "a basename with no host and no clock in it: the same render must not " \
        "look like two different frames")
      assert_equal %i[name bytes content_type views frames glb entries spec], result.keys,
        "the plot shape (name/bytes/content_type), plus the facts a 3D render has"
    end
  end

  test "the same frame always has the same name, different bytes do not" do
    assert_equal BlenderClient.png_name(PNG), BlenderClient.png_name(PNG)
    refute_equal BlenderClient.png_name(PNG), BlenderClient.png_name(PNG_TWO)
    assert_equal "blender-#{Digest::SHA256.hexdigest(PNG)[0, 12]}.png",
                 BlenderClient.png_name(PNG)
  end

  test "views > 1 comes back as a manifest, and every frame is FETCHED" do
    manifest = JSON.generate({ "frames" => %w[frame-1.png frame-2.png],
                               "glb" => "scene.glb" })
    with_stub_service(
      { status: "200 OK", content_type: "application/json", body: manifest },
      { status: "200 OK", content_type: "image/png", body: PNG },
      { status: "200 OK", content_type: "image/png", body: PNG_TWO }
    ) do |base|
      result = BlenderClient.render(base, SPEC)
      assert_equal 2, result[:views], "the count is the frames the manifest actually named"
      assert_equal %w[frame-1.png frame-2.png], result[:frames]
      assert_equal "scene.glb", result[:glb], "the export's name is carried, not fetched"
      assert_equal 2, result[:entries].size
      assert_equal PNG, result[:entries].first[:bytes]
      assert_equal PNG_TWO, result[:entries].last[:bytes],
        "the second frame is kept too: a set must not be reduced to its first element"
      assert_equal "frame-1.png", result[:entries].first[:name],
        "a fetched frame keeps the SERVICE's name, because that is what named it"
      assert_equal PNG, result[:bytes], "the primary frame is the first one"
      assert_equal "image/png", result[:content_type]
    end
  end

  test "a manifest with no glue for its frames is an error rather than a partial render" do
    body = JSON.generate({ "frames" => [], "glb" => nil })
    with_stub_service(status: "200 OK", content_type: "application/json", body: body) do |base|
      error = assert_raises(BlenderClient::BlenderError) { BlenderClient.render(base, SPEC) }
      assert_match(/named no frames/, error.message)
    end
  end

  test "a 200 that is neither a frame nor a manifest is an error, not bytes to store" do
    with_stub_service(status: "200 OK", content_type: "text/html",
                      body: "<html>a proxy that forgot to proxy</html>") do |base|
      error = assert_raises(BlenderClient::BlenderError) { BlenderClient.render(base, SPEC) }
      assert_match(/expected a image\/png frame or a application\/json frames manifest/,
                   error.message)
      assert_match(/text\/html/, error.message)
    end
  end

  # -- the refusals, classified --------------------------------------------

  test "503 is Unavailable, with the service's own reason verbatim" do
    body = JSON.generate({ "error" => "Blender is not installed on this host",
                           "kind" => "unavailable" })
    with_stub_service(status: "503 Service Unavailable", body: body) do |base|
      error = assert_raises(BlenderClient::Unavailable) { BlenderClient.render(base, SPEC) }
      assert_match(/blender 503/, error.message)
      assert_match(/Blender is not installed on this host/, error.message,
        "the one message that has to reach the operator survives verbatim")
      assert_kind_of BlenderClient::BlenderError, error,
        "and it is still one thing for RunJob to rescue"
    end
  end

  test "an invalid spec is a SpecError, on the codes the service refuses with" do
    body = JSON.generate({ "error" => "unknown element type 'arc'", "kind" => "invalid_spec" })
    with_stub_service(status: "400 Bad Request", body: body) do |base|
      error = assert_raises(BlenderClient::SpecError) { BlenderClient.render(base, SPEC) }
      assert_match(/unknown element type 'arc'/, error.message)
    end
    with_stub_service(status: "422 Unprocessable Entity", body: body) do |base|
      assert_raises(BlenderClient::SpecError) { BlenderClient.render(base, SPEC) }
    end
  end

  test "a refusal that is not JSON still reports rather than raising twice" do
    with_stub_service(status: "500 Internal Server Error", content_type: "text/plain",
                      body: "boom") do |base|
      error = assert_raises(BlenderClient::BlenderError) { BlenderClient.render(base, SPEC) }
      assert_match(/blender 500: boom/, error.message)
    end
    assert_equal "boom", BlenderClient.error_message("boom")
    assert_equal %("kept"), BlenderClient.error_message(JSON.generate("kept")),
      "a JSON body that is not an envelope is not an envelope"
  end

  # -- a frame fetch --------------------------------------------------------

  test "a frame name that is not a bare basename is refused, not resolved" do
    error = assert_raises(BlenderClient::SpecError) { BlenderClient.get_file(BASE, "../etc/passwd") }
    assert_match(/not a bare filename/, error.message)
    error = assert_raises(BlenderClient::SpecError) { BlenderClient.get_file(BASE, "a/b.png") }
    assert_match(/not a bare filename/, error.message)
  end

  test "a frame fetch that 503s is Unavailable too" do
    with_stub_service(status: "503 Service Unavailable",
                      body: JSON.generate({ "error" => "no Blender" })) do |base|
      error = assert_raises(BlenderClient::Unavailable) { BlenderClient.get_file(base, "f.png") }
      assert_match(/fetching frame f\.png/, error.message)
    end
  end

  # -- health ---------------------------------------------------------------

  test "health reads /health and reports a 503 rather than raising" do
    with_stub_service(status: "200 OK", body: JSON.generate({ "ok" => true })) do |base|
      body = BlenderClient.health(base)
      assert_equal true, body["ok"]
    end
    with_stub_service(status: "503 Service Unavailable",
                      body: JSON.generate({ "error" => "no Blender" })) do |base|
      body = BlenderClient.health(base)
      assert_equal 503, body["status"], "the health READ reports the state, it does not raise"
      assert_match(/no Blender/, body["error"])
    end
  end

  test "health answers with the failure instead of raising, so a page can still render" do
    body = BlenderClient.health("http://127.0.0.1:1")
    assert_match(/connection failed/, body["error"].to_s)
  end

  # -- the transport, unreachable -------------------------------------------

  test "an unreachable service is a BlenderError, not a raw socket error" do
    error = assert_raises(BlenderClient::BlenderError) do
      BlenderClient.get_file("http://127.0.0.1:1", "f.png")
    end
    assert_match(/connection failed/, error.message)
  end

  test "a BlenderError from the transport is not re-wrapped on the way out" do
    stub_transport(post: ->(*_a, **_k) { raise BlenderClient::Unavailable, "blender 503: no Blender" }) do
      error = assert_raises(BlenderClient::Unavailable) { BlenderClient.render(BASE, SPEC) }
      assert_match(/\Ablender 503: no Blender\z/, error.message)
    end
  end

  # -- the token ------------------------------------------------------------

  test "the token is read from the shared plot-service env var, and absent is fine" do
    original = ENV["CHOPSHOP_BP_TOKEN"]
    begin
      ENV.delete("CHOPSHOP_BP_TOKEN")
      assert_nil BlenderClient.token, "an unauthenticated service is the default"
      ENV["CHOPSHOP_BP_TOKEN"] = "s3cret"
      assert_equal "s3cret", BlenderClient.token
    ensure
      original.nil? ? ENV.delete("CHOPSHOP_BP_TOKEN") : ENV["CHOPSHOP_BP_TOKEN"] = original
    end
  end
end
