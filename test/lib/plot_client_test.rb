require "test_helper"
require "socket"

# The chopshop-plot service client. No service is contacted: the two transports
# are swapped out and the arguments they receive are what gets asserted, which is
# the same seam the runner and flux client tests use. What IS exercised for real
# is the response parsing, because that is where this client differs from flux's:
# success is an SVG DOCUMENT rather than a JSON envelope, so the two are told
# apart by the body and a 200 that is not an SVG must not be stored as one.
#
# Those cases go over a real socket rather than through a stub response object:
# Net::HTTPResponse#body= is a no-op and #body reads the socket, so a hand-built
# response cannot carry a body at all. A one-shot loopback server that answers
# with canned bytes is the honest way to test what the client does with them.
class PlotClientTest < ActiveSupport::TestCase
  BASE = "http://127.0.0.1:8796".freeze

  SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" ' \
        'viewBox="0 0 10 10"></svg>'.freeze

  def stub_transport(post: nil, get: nil)
    swaps = { post: post, get: get }.reject { |_, v| v.nil? }
    originals = swaps.keys.to_h { |name| [name, PlotClient.method(name)] }
    swaps.each do |name, block|
      PlotClient.define_singleton_method(name) { |*args, **kwargs| block.call(*args, **kwargs) }
    end
    yield
  ensure
    originals.each { |name, original| PlotClient.define_singleton_method(name, original) }
  end

  def ok_svg(body = SVG)
    { bytes: body, content_type: "image/svg+xml; charset=utf-8", name: PlotClient.svg_name(body) }
  end

  # A server that accepts one connection, reads the request, answers with exactly
  # these bytes and closes. Ephemeral port, so the suite can run beside anything.
  def with_stub_service(status: "200 OK", content_type: "application/json", body: "")
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
      socket.write("Content-Type: #{content_type}\r\n")
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

  # -- which route, and what it carries -------------------------------------

  test "generate posts the contract's envelope to /generate" do
    calls = []
    spec = { "canvas" => { "width" => 10, "height" => 10 }, "elements" => [] }
    stub_transport(post: ->(url, body, **_) { calls << [url, body]; ok_svg }) do
      PlotClient.generate(BASE, spec)
    end
    assert_equal "#{BASE}/generate", calls.first.first
    assert_equal({ op: "generate", spec: spec }, calls.first.last,
      "the op is sent explicitly, so the service refuses a document sent to the wrong operation")
    refute calls.first.last.key?(:runs), "a generation carries no run records"
  end

  test "digest posts the envelope to /digest, with no run records" do
    calls = []
    stub_transport(post: ->(url, body, **_) { calls << [url, body]; ok_svg }) do
      PlotClient.digest(BASE, { "chart" => "bar", "data" => { "values" => [1] } })
    end
    assert_equal "#{BASE}/digest", calls.first.first
    assert_equal "digest", calls.first.last[:op]
  end

  test "query posts the envelope with its run records, to /query" do
    calls = []
    runs = [{ "stem" => "r1", "candidates" => [] }]
    stub_transport(post: ->(url, body, **_) { calls << [url, body]; ok_svg }) do
      PlotClient.query(BASE, runs, { "chart" => "scatter", "x" => "hard", "y" => "mae_art" })
    end
    assert_equal "#{BASE}/query", calls.first.first
    assert_equal runs, calls.first.last[:runs]
    assert_equal "query", calls.first.last[:op]
  end

  test "a query with no records is refused here rather than round-tripped" do
    stub_transport(post: ->(*_a, **_k) { flunk "nothing may be posted without record set" }) do
      error = assert_raises(PlotClient::PlotError) { PlotClient.query(BASE, [], {}) }
      assert_match(/run records/, error.message)
      error = assert_raises(PlotClient::PlotError) do
        PlotClient.query(BASE, { "stem" => "r1" }, {})
      end
      assert_match(/array/, error.message,
        "a bare record is not a record SET: the caller must say which records are being drawn")
    end
  end

  # -- the answer ------------------------------------------------------------

  test "the SVG comes back as bytes with its content type and a stable name" do
    stub_transport(post: ->(*_a, **_k) { ok_svg }) do
      result = PlotClient.generate(BASE, {})
      assert_equal SVG, result[:bytes]
      assert_equal "image/svg+xml; charset=utf-8", result[:content_type]
      assert_equal "generate", result[:op]
      assert_match(/\Aplot-[0-9a-f]{12}\.svg\z/, result[:name],
        "a basename with no host and no clock in it: the same drawing must not " \
        "look like two different sources")
      assert_equal %i[name bytes content_type op spec], result.keys,
        "the same return shape FluxClient.render uses, so a caller that handles " \
        "a generated raster handles a generated vector"
    end
  end

  test "the same SVG always has the same name, different SVG does not" do
    assert_equal PlotClient.svg_name(SVG), PlotClient.svg_name(SVG)
    refute_equal PlotClient.svg_name(SVG), PlotClient.svg_name(SVG + "<!--x-->")
    assert_equal "plot-#{Digest::SHA256.hexdigest(SVG)[0, 12]}.svg", PlotClient.svg_name(SVG)
  end

  test "a 200 that is not an SVG document is an error, not bytes to store" do
    with_stub_service(status: "200 OK", content_type: "text/html",
                      body: "<html>a proxy that forgot to proxy</html>") do |base|
      error = assert_raises(PlotClient::PlotError) { PlotClient.generate(base, {}) }
      assert_match(/expected an SVG document/, error.message)
      assert_match(/text\/html/, error.message)
    end
  end

  test "a refusal is surfaced with the service's own message, verbatim" do
    body = JSON.generate({ "error" => "scatter: axis 'preset' is not a numeric metric field",
                           "kind" => "invalid_spec" })
    with_stub_service(status: "400 Bad Request", body: body) do |base|
      error = assert_raises(PlotClient::PlotError) { PlotClient.generate(base, {}) }
      assert_match(/plot 400/, error.message)
      assert_match(/axis 'preset' is not a numeric metric field/, error.message,
        "the refusal is the one message that must survive verbatim")
    end
  end

  test "a refusal that is not JSON still reports rather than raising twice" do
    with_stub_service(status: "500 Internal Server Error", content_type: "text/plain",
                      body: "boom") do |base|
      error = assert_raises(PlotClient::PlotError) { PlotClient.generate(base, {}) }
      assert_match(/plot 500: boom/, error.message)
    end
    assert_equal "boom", PlotClient.error_message("boom")
    assert_equal %("kept"), PlotClient.error_message(JSON.generate("kept")),
      "a JSON body that is not an envelope is not an envelope: the raw body is the message"
  end

  test "the SVG is read from the response body and named by its content" do
    with_stub_service(status: "200 OK", content_type: "image/svg+xml", body: SVG) do |base|
      result = PlotClient.generate(base, { "canvas" => { "width" => 10, "height" => 10 } })
      assert_equal SVG, result[:bytes]
      assert_equal "image/svg+xml", result[:content_type]
      assert_equal PlotClient.svg_name(SVG), result[:name]
    end
  end

  # -- health ----------------------------------------------------------------

  test "health reads /health, unauthenticated by default" do
    seen = []
    stub_transport(get: ->(url) { seen << url; { "ok" => true, "service" => "chopshop-plot" }.with_indifferent_access }) do
      body = PlotClient.health(BASE)
      assert_equal true, body["ok"]
      assert_equal "chopshop-plot", body["service"]
    end
    assert_equal ["#{BASE}/health"], seen
  end

  test "health answers with the failure instead of raising, so a page can still render" do
    stub_transport(get: ->(_url) { raise PlotClient::PlotError, "down" }) do
      assert_equal({ error: "down" }, PlotClient.health(BASE))
    end
  end

  # -- the transport, unreachable -------------------------------------------

  test "an unreachable service is a PlotError, not a raw socket error" do
    # The real transport, against a port nothing listens on: this is the wrapping
    # the rest of the app relies on, so it must be exercised rather than stubbed.
    error = assert_raises(PlotClient::PlotError) { PlotClient.get("http://127.0.0.1:1/health") }
    assert_match(/connection failed/, error.message)
  end

  test "a PlotError from the transport is not re-wrapped on the way out" do
    stub_transport(post: ->(*_a, **_k) { raise PlotClient::PlotError, "plot 400: bad chart" }) do
      error = assert_raises(PlotClient::PlotError) { PlotClient.generate(BASE, {}) }
      assert_match(/\Aplot 400: bad chart\z/, error.message)
    end
  end

  # -- the token -------------------------------------------------------------

  test "the token is read from the service's own env var, and absent is fine" do
    original = ENV["CHOPSHOP_PLOT_TOKEN"]
    begin
      ENV.delete("CHOPSHOP_PLOT_TOKEN")
      assert_nil PlotClient.token, "an unauthenticated service is the default"
      ENV["CHOPSHOP_PLOT_TOKEN"] = "s3cret"
      assert_equal "s3cret", PlotClient.token
    ensure
      original.nil? ? ENV.delete("CHOPSHOP_PLOT_TOKEN") : ENV["CHOPSHOP_PLOT_TOKEN"] = original
    end
  end
end
