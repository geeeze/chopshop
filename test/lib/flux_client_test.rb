require "test_helper"

# The flux service client. No service is contacted: the three transport methods
# are swapped out and the arguments they receive are what gets asserted, which is
# the same seam the runner tests use.
#
# What is worth pinning here is that /generate and /edit are chosen from the
# presence of a reference rather than a separate flag (so they cannot disagree),
# and that the bytes come back through the documented /files route rather than
# anything the service happens to put in the response body.
class FluxClientTest < ActiveSupport::TestCase
  BASE = "http://127.0.0.1:8795".freeze

  # Replace only the transports the block needs, and put them back afterwards
  # even if the block raises.
  def stub_transport(post: nil, get: nil, get_file: nil)
    swaps = { post: post, get: get, get_file: get_file }.reject { |_, v| v.nil? }
    originals = swaps.keys.to_h { |name| [name, FluxClient.method(name)] }
    swaps.each do |name, block|
      FluxClient.define_singleton_method(name) { |*args, **kwargs| block.call(*args, **kwargs) }
    end
    yield
  ensure
    originals.each { |name, original| FluxClient.define_singleton_method(name, original) }
  end

  def ok_meta(name: "20260927T183001Z-klein-4b-s1234567-01.png", **extra)
    {
      "model" => "klein-4b", "license" => "Apache-2.0", "commercial_ok" => true,
      "prompt" => "a phoenix", "edited" => false, "warnings" => [],
      "images" => [ { "name" => name, "bytes" => 402_133, "seed" => 1_234_567,
                      "model" => "klein-4b", "width" => 512, "height" => 512,
                      "seconds" => 3.4 }.merge(extra) ]
    }.with_indifferent_access
  end

  # --- which route ---------------------------------------------------------

  test "no reference means /generate" do
    calls = []
    stub_transport(
      post: ->(url, body, **_) { calls << [url, body]; ok_meta },
      get_file: ->(_url) { { status: 200, body: "PNGDATA", content_type: "image/png" } }
    ) do
      FluxClient.render(BASE, prompt: "a phoenix")
    end
    assert_equal "#{BASE}/generate", calls.first.first
    assert_equal "a phoenix", calls.first.last[:prompt]
    refute calls.first.last.key?(:image), "a generation must not carry an image key at all"
  end

  test "a reference means /edit, and rides as the data URL the service requires" do
    calls = []
    data = "data:image/png;base64,AAAA"
    stub_transport(
      post: ->(url, body, **_) { calls << [url, body]; ok_meta },
      get_file: ->(_url) { { status: 200, body: "PNGDATA", content_type: "image/png" } }
    ) do
      FluxClient.render(BASE, prompt: "flatten to 6 colours", reference: data)
    end
    assert_equal "#{BASE}/edit", calls.first.first
    assert_equal data, calls.first.last[:image]
  end

  # --- several references --------------------------------------------------

  # The WIRE SHAPE is the contract with the service, and it has two forms: one
  # reference rides as a bare data URL (what every existing caller sends, and
  # what /edit documents as the plain case) and several ride as a LIST. Sending
  # a one-element array for a single reference would be a gratuitous change to
  # every existing request, so the two are distinguished here and pinned.
  def capture_image(**kwargs)
    calls = []
    stub_transport(
      post: ->(url, body, **_) { calls << [url, body]; ok_meta },
      get_file: ->(_url) { { status: 200, body: "PNGDATA", content_type: "image/png" } }
    ) do
      FluxClient.render(BASE, prompt: "use the pose from the first", **kwargs)
    end
    calls.first
  end

  test "ONE reference still rides as the bare data URL, not a one-element list" do
    url, body = capture_image(references: [ "data:image/png;base64,AAAA" ])
    assert_equal "#{BASE}/edit", url
    assert_equal "data:image/png;base64,AAAA", body[:image],
      "a single reference keeps the shape every existing caller sends"
  end

  test "SEVERAL references ride as a list, in the order given" do
    pose = "data:image/png;base64,AAAA"
    palette = "data:image/png;base64,BBBB"
    url, body = capture_image(references: [ pose, palette ])
    assert_equal "#{BASE}/edit", url
    assert_equal [ pose, palette ], body[:image],
      "the list keeps the caller's order -- which reference is the pose is only the caller's to say"
  end

  test "the scalar reference and the list are one list, scalar first" do
    first = "data:image/png;base64,AAAA"
    second = "data:image/png;base64,BBBB"
    _url, body = capture_image(reference: first, references: [ second ])
    assert_equal [ first, second ], body[:image],
      "a caller passing both gets both, in a defined order, rather than one silently winning"
  end

  test "a blank slot in the list is dropped rather than sent as an empty string" do
    real = "data:image/png;base64,AAAA"
    _url, body = capture_image(references: [ real, "", "  ", nil ])
    assert_equal real, body[:image],
      "an empty slot is 'not asked for', not a payload the service has to interpret"
  end

  # The studio gates the SECOND SLOT on the model's multi_reference flag, so a
  # one-reference model is never offered one. But a hand-edited spec can still
  # send a list to any model, and this client must not second-guess it: the
  # service is the thing that knows which checkpoint takes a list, and its
  # refusal is a 400 carrying a specific sentence. Swallowing the list here, or
  # trimming it to one, would turn that clear refusal into a render that
  # silently ignored the second reference.
  test "a list is passed through to a model that may not take one, for the service to refuse" do
    two = [ "data:image/png;base64,AAAA", "data:image/png;base64,BBBB" ]
    _url, body = capture_image(references: two)
    assert_equal two, body[:image],
      "the client does not decide which checkpoint takes a list -- the service does"
  end

  test "the service's refusal of a second reference surfaces with its own sentence" do
    refusal = "sdxl-1.0 takes a single reference image, but 2 were given."
    stub_transport(
      post: ->(_url, _body, **_) { raise FluxClient::FluxError, refusal },
      get_file: ->(_url) { { status: 200, body: "PNG", content_type: "image/png" } }
    ) do
      error = assert_raises(FluxClient::FluxError) do
        FluxClient.render(BASE, prompt: "x",
                          references: [ "data:image/png;base64,AAAA", "data:image/png;base64,BBBB" ])
      end
      assert_match(/takes a single reference image/, error.message)
    end
  end

  # --- the body ------------------------------------------------------------

  test "blank settings are omitted rather than sent as empty values" do
    bodies = []
    stub_transport(
      post: ->(_url, body, **_) { bodies << body; ok_meta },
      get_file: ->(_url) { { status: 200, body: "PNG", content_type: "image/png" } }
    ) do
      FluxClient.render(BASE, prompt: "x", model: nil, width: nil, height: "",
                        steps: nil, guidance: nil, seed: nil, images: nil)
    end
    assert_equal [ :prompt ], bodies.first.keys,
      "an omitted key means the service's own default; a blank string is a " \
      "different thing and the service would reject width: ''"
  end

  test "the settings that are given are typed, not stringly passed" do
    bodies = []
    stub_transport(
      post: ->(_url, body, **_) { bodies << body; ok_meta },
      get_file: ->(_url) { { status: 200, body: "PNG", content_type: "image/png" } }
    ) do
      FluxClient.render(BASE, prompt: "x", width: "512", height: "512",
                        steps: "4", guidance: "1.0", seed: "42", images: "1")
    end
    assert_equal({ prompt: "x", width: 512, height: 512, steps: 4,
                   guidance: 1.0, seed: 42, images: 1 }, bodies.first)
  end

  test "images and negative_prompt are passed through, and a blank negative prompt is omitted" do
    bodies = []
    stub_transport(
      post: ->(_url, body, **_) { bodies << body; ok_meta },
      get_file: ->(_url) { { status: 200, body: "PNG", content_type: "image/png" } }
    ) do
      FluxClient.render(BASE, prompt: "x", images: "3", negative_prompt: "blurry, low contrast")
      FluxClient.render(BASE, prompt: "y", negative_prompt: "")
    end
    assert_equal 3, bodies.first[:images]
    assert_equal "blurry, low contrast", bodies.first[:negative_prompt]
    refute bodies.last.key?(:negative_prompt),
      "a blank negative prompt is an absent one, not an empty-string instruction"
  end

  test "a strength rides as a float, and a blank or absent one leaves the key out" do
    bodies = []
    ref = "data:image/png;base64,AAAA"
    stub_transport(
      post: ->(_url, body, **_) { bodies << body; ok_meta },
      get_file: ->(_url) { { status: 200, body: "PNG", content_type: "image/png" } }
    ) do
      FluxClient.render(BASE, prompt: "x", reference: ref, strength: "0.6")
      FluxClient.render(BASE, prompt: "y", reference: ref, strength: "")
      FluxClient.render(BASE, prompt: "z", reference: ref)
    end
    assert_equal 0.6, bodies.first[:strength], "0.6 is a number on the wire, not the string"
    refute_kind_of String, bodies.first[:strength]
    refute bodies[1].key?(:strength),
      "a blank strength is an absent one, so the pipeline's own default applies " \
      "rather than a zero"
    refute bodies[2].key?(:strength), "and one that was never given is absent too"
  end

  # --- the batch -----------------------------------------------------------

  test "a batch generation returns every image in entries, each with its own bytes" do
    meta = ok_meta.merge(
      "images" => [
        { "name" => "a.png", "bytes" => 10, "seed" => 1, "model" => "klein-4b",
          "width" => 512, "height" => 512, "seconds" => 3.0 },
        { "name" => "b.png", "bytes" => 10, "seed" => 1, "model" => "klein-4b",
          "width" => 512, "height" => 512, "seconds" => 3.0 },
        { "name" => "c.png", "bytes" => 10, "seed" => 1, "model" => "klein-4b",
          "width" => 512, "height" => 512, "seconds" => 3.0 }
      ]
    )
    fetched = []
    stub_transport(
      post: ->(_url, _body, **_) { meta },
      get_file: ->(url) { fetched << url; { status: 200, body: "PNG#{File.basename(url)}", content_type: "image/png" } }
    ) do
      result = FluxClient.render(BASE, prompt: "x", images: "3")
      assert_equal 3, result[:entries].size, "a triptych is three rasters, not one"
      assert_equal %w[a.png b.png c.png], result[:entries].map { |e| e[:name] }
      assert_equal %w[a.png b.png c.png], fetched.map { |u| File.basename(u) },
        "each raster is fetched through /files, not only the first"
      # The single-image caller is unchanged: the first image sits at the top.
      assert_equal "a.png", result[:name]
      assert_equal "PNGa.png", result[:bytes]
    end
  end

  # --- the bytes -----------------------------------------------------------

  test "the bytes come from /files, not from the response body" do
    fetched = []
    stub_transport(
      post: ->(_url, _body, **_) { ok_meta(name: "20260101T000000Z-klein-4b-s1-01.png") },
      get_file: ->(url) { fetched << url; { status: 200, body: "THEBYTES", content_type: "image/png" } }
    ) do
      result = FluxClient.render(BASE, prompt: "x")
      assert_equal "THEBYTES", result[:bytes]
      assert_equal "image/png", result[:content_type]
      assert_equal "20260101T000000Z-klein-4b-s1-01.png", result[:name]
      assert_equal 1_234_567, result[:entry]["seed"]
      assert_equal "Apache-2.0", result[:meta]["license"]
    end
    assert_equal [ "#{BASE}/files/20260101T000000Z-klein-4b-s1-01.png" ], fetched,
      "the service reports a server-side path, which is useless here -- the " \
      "documented file route is the only way to the pixels"
  end

  test "a generation the service reports but never made is an error, not an empty image" do
    stub_transport(post: ->(_url, _body, **_) { { "images" => [] }.with_indifferent_access }) do
      error = assert_raises(FluxClient::FluxError) { FluxClient.render(BASE, prompt: "x") }
      assert_match(/no images/, error.message)
    end
  end

  test "an image with no name cannot be fetched, and says so" do
    meta = { "images" => [ { "bytes" => 1 } ] }.with_indifferent_access
    stub_transport(post: ->(_url, _body, **_) { meta }) do
      error = assert_raises(FluxClient::FluxError) { FluxClient.render(BASE, prompt: "x") }
      assert_match(/no name/, error.message)
    end
  end

  test "a failed file fetch is an error rather than silent zero bytes" do
    stub_transport(
      post: ->(_url, _body, **_) { ok_meta },
      get_file: ->(_url) { { status: 500, body: "boom", content_type: "text/plain" } }
    ) do
      error = assert_raises(FluxClient::FluxError) { FluxClient.render(BASE, prompt: "x") }
      assert_match(/500/, error.message)
    end
  end

  # --- errors --------------------------------------------------------------

  test "a gpu_busy refusal raises FluxGpuBusy, not plain FluxError" do
    stub_transport(post: ->(_url, _body, **_) {
      raise FluxClient::FluxGpuBusy, "flux 503: GPU busy, held by LM Studio"
    }) do
      error = assert_raises(FluxClient::FluxGpuBusy) { FluxClient.render(BASE, prompt: "x") }
      assert_match(/LM Studio/, error.message)
    end
  end

  test "FluxGpuBusy is a FluxError, so existing rescue clauses still catch it" do
    assert FluxClient::FluxGpuBusy < FluxClient::FluxError
  end

  test "a gpu_busy error from parse is distinguishable from a real failure" do
    res = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
    res.instance_variable_set(:@body, { "error" => "GPU busy, held by ollama", "kind" => "gpu_busy" }.to_json)
    def res.body; @body; end

    error = assert_raises(FluxClient::FluxGpuBusy) { FluxClient.parse(res) }
    assert_match(/GPU busy/, error.message)
    assert_kind_of FluxClient::FluxError, error
  end

  test "a non-gpu_busy error still raises plain FluxError" do
    res = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    res.instance_variable_set(:@body, { "error" => "prompt required", "kind" => "bad_request" }.to_json)
    def res.body; @body; end

    error = assert_raises(FluxClient::FluxError) { FluxClient.parse(res) }
    assert_match(/prompt required/, error.message)
  end

  test "the service's refusal is surfaced with its own message" do
    stub_transport(post: ->(_url, _body, **_) {
      raise FluxClient::FluxError, "flux 403: sdxl-turbo is non-commercial"
    }) do
      error = assert_raises(FluxClient::FluxError) { FluxClient.render(BASE, prompt: "x") }
      assert_match(/non-commercial/, error.message,
        "the licence refusal is the one message that must survive verbatim")
    end
  end

  test "an unreachable service is a FluxError, not a raw socket error" do
    # The real transport, against a port nothing listens on: this is the wrapping
    # the rest of the app relies on, so it must be exercised rather than stubbed
    # (a stubbed `post` raises past it and proves nothing).
    error = assert_raises(FluxClient::FluxError) { FluxClient.get("http://127.0.0.1:1/health") }
    assert_match(/connection failed/, error.message)
  end

  test "a FluxError from the transport is not re-wrapped on the way out" do
    stub_transport(post: ->(_url, _body, **_) { raise FluxClient::FluxError, "flux 400: prompt required" }) do
      error = assert_raises(FluxClient::FluxError) { FluxClient.render(BASE, prompt: "") }
      assert_match(/flux 400: prompt required/, error.message)
    end
  end

  test "health answers with the failure instead of raising, so a form can still render" do
    stub_transport(get: ->(_url) { raise FluxClient::FluxError, "down" }) do
      assert_equal({ error: "down" }, FluxClient.health(BASE))
    end
  end

  # --- the data URL --------------------------------------------------------

  test "a local PNG becomes the data URL /edit wants" do
    require "base64"
    path = Rails.root.join("tmp", "flux-client-test.png")
    File.binwrite(path, "\x89PNG\r\n\x1a\n fake")
    begin
      expected = "data:image/png;base64,#{Base64.strict_encode64(File.binread(path))}"
      assert_equal expected, FluxClient.data_url(path)
    ensure
      File.delete(path)
    end
  end

  test "an extension the service does not accept is refused here, not posted" do
    path = Rails.root.join("tmp", "flux-client-test.tiff")
    File.binwrite(path, "not an image the service knows")
    begin
      error = assert_raises(FluxClient::FluxError) { FluxClient.data_url(path) }
      assert_match(/\.tiff/, error.message)
    ensure
      File.delete(path)
    end
  end

  # --- the token -----------------------------------------------------------

  test "the token is read from the service's own env var, and absent is fine" do
    original = ENV["CHOPSHOP_FLUX_TOKEN"]
    begin
      ENV.delete("CHOPSHOP_FLUX_TOKEN")
      assert_nil FluxClient.token, "an unauthenticated service is the default"
      ENV["CHOPSHOP_FLUX_TOKEN"] = "s3cret"
      assert_equal "s3cret", FluxClient.token
    ensure
      original.nil? ? ENV.delete("CHOPSHOP_FLUX_TOKEN") : ENV["CHOPSHOP_FLUX_TOKEN"] = original
    end
  end
end
