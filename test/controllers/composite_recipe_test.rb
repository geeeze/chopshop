require "test_helper"

# The vector-preserving compose: a composite's layer KIND, the recipe endpoint
# that hands an agent the exact spec to POST, and the vector flatten that asks
# the svg runner to merge the layers itself instead of rasterising them.
#
# The two things these tests exist to protect:
#
#   * a layer without a `kind` is RASTER — every composite stored before the
#     field existed must flatten exactly as it did, through the browser's PNG.
#   * a traced SVG is composed as VECTORS. It is never rasterised and re-traced,
#     which is the entire point of the vector path.
class CompositeRecipeTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  SVG_ONE = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10">' \
            '<rect width="20" height="10" fill="#101010"/></svg>'.freeze
  SVG_TWO = '<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4">' \
            '<circle cx="2" cy="2" r="2"/></svg>'.freeze
  COMPOSED = '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">' \
             '<g id="composed"><rect width="100" height="100"/></g></svg>'.freeze

  setup do
    @original_password = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    @saved_env = {}
    %w[CHOPSHOP_COMPOSE_URL CHOPSHOP_COMPOSE_RUNNER].each { |k| @saved_env[k] = ENV.delete(k) }
    @files = []
  end

  teardown do
    ENV["CHOPSHOP_PASSWORD"] = @original_password
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    @files.each { |f| File.delete(f) if File.exist?(f) }
  end

  def sign_in
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  # --- fixtures -------------------------------------------------------------

  def stored_item(name:, body:, kind: "candidate")
    dir = Rails.root.join("storage", "scrapbook")
    dir.mkpath
    stored = "recipe_probe_#{SecureRandom.hex(4)}#{File.extname(name)}"
    File.binwrite(dir.join(stored), body)
    @files << dir.join(stored)
    ScrapbookItem.create!(name: name, kind: kind, file: stored)
  end

  def svg_item(name: "candidate_01.svg", body: SVG_ONE)
    stored_item(name: name, body: body, kind: "candidate")
  end

  def png_item(name: "proof.png")
    stored_item(name: name, body: "\x89PNG\r\n\x1a\n".b + ("\x00" * 32), kind: "proof")
  end

  def vector_layer(item, extra = {})
    { "key" => "v#{item.id}", "name" => item.name, "kind" => "vector",
      "src" => scrapbook_item_file_path(item),
      "x" => 5, "y" => 6, "w" => 30, "h" => 20, "z" => 0,
      "opacity" => 0.5, "hue" => 30, "visible" => true }.merge(extra)
  end

  def raster_layer(item, extra = {})
    { "key" => "r#{item.id}", "name" => item.name, "kind" => "raster",
      "src" => scrapbook_item_file_path(item),
      "x" => 1, "y" => 2, "w" => 10, "h" => 10, "z" => 1,
      "opacity" => 1.0, "hue" => 0, "visible" => true }.merge(extra)
  end

  def png_upload(bytes = nil)
    bytes ||= "\x89PNG\r\n\x1a\n".b + ("\x00" * 64)
    file = Tempfile.new(["composite", ".png"])
    file.binmode
    file.write(bytes)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "image/png")
  end

  # Swap ComposeClient.compose for a stub (`responder`, a lambda), capture every
  # call, and put the real method back in ensure — the same swap the
  # plot/flux/blender tests use. `body` receives the captured calls.
  def with_compose(responder, &body)
    calls = []
    original = ComposeClient.method(:compose)
    ComposeClient.define_singleton_method(:compose) do |base, spec, **kwargs|
      calls << { base: base, spec: spec, kwargs: kwargs }
      responder.call(base, spec)
    end
    body.call(calls)
  ensure
    ComposeClient.define_singleton_method(:compose, original)
  end

  def composed_result
    { bytes: COMPOSED, content_type: "image/svg+xml", name: "compose-abc123.svg" }
  end

  # A real Net::HTTPResponse, so the client's own parsing is exercised without a
  # server: the same objects parse_svg sees from Net::HTTP. The body is set as an
  # instance variable because a response built by hand was never read from a
  # socket, and #body= refuses outside that block.
  def http_response(code, body, content_type = nil)
    res = Net::HTTPResponse::CODE_TO_OBJ[code.to_s].new("1.1", code.to_s, "")
    res.instance_variable_set(:@body, body)
    res.instance_variable_set(:@read, true)
    res["Content-Type"] = content_type if content_type
    res
  end

  # --- kind -----------------------------------------------------------------

  test "a layer's kind defaults to raster and vector is opt-in" do
    c = Composite.create!(name: "kinds", width: 100, height: 100, layers: [
      { "key" => "a", "x" => 0 },
      { "key" => "b", "kind" => "vector", "src" => "/scrapbook/1/file" },
      # An unknown word must compose as pixels rather than crash a flatten: the
      # layers column is free-form JSON.
      { "key" => "c", "kind" => "sausage", "src" => "data:image/png;base64,AAAA" }
    ])

    assert_equal %w[a b c], c.layers.map { |l| l["key"] }
    assert_equal [Composite::KIND_RASTER, Composite::KIND_VECTOR, Composite::KIND_RASTER],
                 c.layers.map { |l| c.layer_kind_of(l) },
                 "a layer with no kind (or an unknown one) is raster"
    assert_equal %w[b], c.vector_layers.map { |l| l["key"] }
    assert c.vector?, "one vector layer makes the composite a compose"
    refute c.all_vector?
  end

  test "all_vector? is true only when every paintable layer is a vector" do
    v1 = { "key" => "v1", "kind" => "vector", "src" => "data:image/svg+xml,<svg/>" }
    v2 = { "key" => "v2", "kind" => "vector", "src" => "data:image/svg+xml,<svg/>" }
    r = { "key" => "r", "kind" => "raster", "src" => "data:image/png;base64,AAAA" }

    assert Composite.create!(name: "empty", width: 10, height: 10, layers: [])
                     .all_vector? == false,
           "nothing to compose is not a vector composite"

    both = Composite.create!(name: "v", width: 10, height: 10, layers: [v1, v2])
    assert both.all_vector?

    mixed = Composite.create!(name: "mixed", width: 10, height: 10, layers: [v1, r])
    refute mixed.all_vector?
    assert mixed.vector?, "still a compose — the vector layer is painted as vectors"

    hidden_raster = Composite.create!(name: "hidden", width: 10, height: 10,
                                      layers: [v1, r.merge("visible" => false)])
    assert hidden_raster.all_vector?,
           "an invisible layer is not painted, so it is not in the compose at all"
  end

  # --- recipe ---------------------------------------------------------------

  test "the recipe endpoint answers the compose spec with vector sources inlined" do
    sign_in
    v = svg_item
    p = png_item
    assert_difference -> { Composite.count }, 1 do
      post create_composite_path,
           params: { name: "recipe", width: 1200, height: 800,
                     background: "#ffffff", palette: "#ff0000, #00ff00",
                     layers: JSON.generate([vector_layer(v), raster_layer(p)]) },
           headers: { "User-Agent" => MODERN_UA }
    end
    c = Composite.order(:id).last

    get recipe_composite_path(c), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    spec = JSON.parse(response.body)

    assert_equal 1200, spec["width"]
    assert_equal 800, spec["height"]
    assert_equal "#ffffff", spec["background"]
    assert_equal %w[#ff0000 #00ff00], spec["palette"],
                 "the palette the form posted is part of the spec"
    assert_equal %w[svg raster], spec["layers"].map { |l| l["type"] }

    vector, raster = spec["layers"]
    assert_includes vector["src"], "<svg", "a vector layer's src is the SVG TEXT, inline"
    refute_includes vector["src"], "/scrapbook/", "never a path — the runner cannot see storage"
    assert_equal [5, 6, 30, 20], %w[x y w h].map { |k| vector[k] }
    assert_equal 0.5, vector["opacity"]
    assert_equal 30, vector["hue"]

    assert raster["src"].start_with?("data:image/png;base64,"),
           "a raster layer's src is a data URI"
    assert_equal File.binread(p.stored_path), raster["src"].split(",", 2).last.unpack1("m"),
                 "and its bytes are the item's own file"
  end

  test "the recipe is login-gated and a missing composite is a 404" do
    v = svg_item
    c = Composite.create!(name: "gated", width: 10, height: 10, layers: [vector_layer(v)])

    get recipe_composite_path(c), headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect, "the recipe is as private as the composite it describes"

    sign_in
    get recipe_composite_path(999_999), headers: { "User-Agent" => MODERN_UA }
    assert_response :not_found
  end

  test "an SVG marked raster is composed as a vector anyway" do
    sign_in
    v = svg_item
    # No `kind` at all: the pre-vector default. The bytes decide, not the label —
    # rasterising a trace because a stale layer forgot to say "vector" would
    # re-trace it downstream.
    layer = vector_layer(v).except("kind")
    c = Composite.create!(name: "stale", width: 10, height: 10, layers: [layer])
    refute c.vector?, "the composite itself does not claim a vector layer"

    get recipe_composite_path(c), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    spec = JSON.parse(response.body)
    assert_equal "svg", spec["layers"].first["type"]
    assert_includes spec["layers"].first["src"], "<svg"
  end

  test "a vector layer whose source is not an SVG is refused by name" do
    sign_in
    p = png_item
    c = Composite.create!(name: "broken", width: 10, height: 10,
                          layers: [vector_layer(p)])

    post flatten_composite_path(c), params: { file: png_upload },
                                    headers: { "User-Agent" => MODERN_UA }
    assert_response :unprocessable_entity
    assert_match(/vector layer/, JSON.parse(response.body)["error"])
  end

  test "a vector layer whose source has gone is refused, not half-composed" do
    sign_in
    gone = svg_item(name: "gone.svg")
    c = Composite.create!(name: "gone", width: 10, height: 10, layers: [vector_layer(gone)])
    # The item is still in the scrapbook; its file is not on disk any more.
    File.delete(gone.stored_path)

    post flatten_composite_path(c), params: { file: png_upload },
                                    headers: { "User-Agent" => MODERN_UA }
    assert_response :unprocessable_entity
    assert_match(/missing on disk/, JSON.parse(response.body)["error"])
  end

  # --- vector flatten -------------------------------------------------------

  test "a vector flatten POSTs the spec to the svg runner's /compose and stores the SVG" do
    sign_in
    ENV["CHOPSHOP_COMPOSE_URL"] = "http://127.0.0.1:9999"
    v = svg_item
    c = Composite.create!(name: "badge", width: 100, height: 100,
                          layers: [vector_layer(v)])

    stub = ->(_base, _spec) { composed_result }

    with_compose(stub) do |calls|
      assert_difference -> { ScrapbookItem.count }, 1 do
        # The browser still posts its PNG — the server decides which flatten runs.
        post flatten_composite_path(c), params: { file: png_upload },
                                        headers: { "User-Agent" => MODERN_UA }
      end
      assert_response :success
      json = JSON.parse(response.body)

      assert_equal 1, calls.size, "exactly one compose call"
      assert_equal "http://127.0.0.1:9999", calls.first[:base],
                   "the placement comes from CHOPSHOP_COMPOSE_URL"
      spec = calls.first[:spec]
      assert_equal 100, spec["width"]
      assert_equal "svg", spec["layers"].first["type"]
      assert_includes spec["layers"].first["src"], "<svg"
      refute_match(%r{/scrapbook/}, spec["layers"].first["src"])

      assert_equal "vector", json["mode"]
      assert_equal "image/svg+xml", json["content_type"]
      assert_match(/upload_preview/, json["preview_url"])

      item = ScrapbookItem.find(json["scrapbook_id"])
      assert_equal "svg", item.kind
      assert_equal COMPOSED, File.binread(item.stored_path),
                   "the stored artefact is the runner's SVG, not the browser's PNG"
      assert File.file?(json["path"])
      assert_equal COMPOSED, File.binread(json["path"])
      assert_equal ".svg", File.extname(json["path"])
      @files << Pathname.new(json["path"])
      @files << item.stored_path
    end
  end

  test "the composite's palette rides the compose spec, and a caller may override it" do
    sign_in
    v = svg_item
    c = Composite.create!(name: "inked", width: 10, height: 10, palette: %w[#111111 #222222],
                          layers: [vector_layer(v)])

    get recipe_composite_path(c), headers: { "User-Agent" => MODERN_UA }
    assert_equal %w[#111111 #222222], JSON.parse(response.body)["palette"]

    with_compose(->(_b, _s) { composed_result }) do |calls|
      post flatten_composite_path(c), params: { file: png_upload, palette: "#abcdef" },
                                      headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      assert_equal %w[#abcdef], calls.first[:spec]["palette"],
                   "an explicit palette wins for that one flatten"

      json = JSON.parse(response.body)
      @files << Pathname.new(json["path"])
      @files << ScrapbookItem.find(json["scrapbook_id"]).stored_path
    end
  end

  test "a compose refusal is a 502 and stores nothing" do
    sign_in
    v = svg_item
    c = Composite.create!(name: "refused", width: 10, height: 10, layers: [vector_layer(v)])

    with_compose(->(_base, _spec) { raise ComposeClient::ComposeError, "compose 400: layers[0].src is not SVG" }) do
      assert_no_difference -> { ScrapbookItem.count } do
        post flatten_composite_path(c), params: { file: png_upload },
                                        headers: { "User-Agent" => MODERN_UA }
      end
      assert_response :bad_gateway
      assert_match(/compose 400/, JSON.parse(response.body)["error"])
    end
  end

  test "a raster-only composite still flattens its PNG and never composes" do
    sign_in
    p = png_item
    c = Composite.create!(name: "raster", width: 100, height: 100,
                          # No kind: the pre-vector layer shape.
                          layers: [raster_layer(p).except("kind")])

    # Any compose call at all would fail the test: the vector path must not be
    # entered for a raster-only composite.
    with_compose(->(_b, _s) { raise "the raster path must not compose" }) do |calls|
      assert_difference -> { ScrapbookItem.count }, 1 do
        post flatten_composite_path(c), params: { file: png_upload },
                                        headers: { "User-Agent" => MODERN_UA }
      end
      assert_empty calls
      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "raster", json["mode"]
      assert_equal "image/png", json["content_type"]

      stored = ScrapbookItem.find(json["scrapbook_id"])
      assert_equal "upload", stored.kind
      assert_equal [0x89, 0x50, 0x4E, 0x47],
                   File.open(stored.stored_path, "rb") { |f| f.read(4).bytes },
                   "the PNG path still stores PNG bytes"
      assert_equal ".png", File.extname(json["path"])
      @files << Pathname.new(json["path"])
      @files << stored.stored_path
    end
  end

  test "an explicit raster mode keeps a vector composite on the PNG path" do
    sign_in
    v = svg_item
    c = Composite.create!(name: "screenshot", width: 100, height: 100, layers: [vector_layer(v)])

    with_compose(->(_b, _s) { raise "raster mode must not compose" }) do
      post flatten_composite_path(c), params: { file: png_upload, mode: "raster" },
                                      headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "raster", json["mode"]
      @files << Pathname.new(json["path"])
      @files << ScrapbookItem.find(json["scrapbook_id"]).stored_path
    end
  end

  # --- layers_available -----------------------------------------------------

  test "ComposeClient reads the SVG by content, and a refusal by its envelope" do
    dense = ComposeClient.compact("width" => 10, "palette" => nil, "background" => "transparent")
    assert_equal %w[width background], dense.keys,
                 "a nil-valued key is omitted, not sent as null"
    assert_equal ["#ff0000"], ComposeClient.compact("width" => 10, "palette" => ["#ff0000"])["palette"]

    ok = ComposeClient.parse_svg(http_response(200, COMPOSED, "image/svg+xml"))
    assert_equal COMPOSED, ok[:bytes]
    assert_equal "image/svg+xml", ok[:content_type]
    assert_match(/\Acompose-[0-9a-f]{12}\.svg\z/, ok[:name])
    assert_equal ok[:name], ComposeClient.svg_name(COMPOSED),
                 "the name is the document's digest, not a clock"

    # A 200 that is not an SVG document is an error, not bytes to store.
    assert_raises(ComposeClient::ComposeError) { ComposeClient.parse_svg(http_response(200, "{}", "application/json")) }

    err = assert_raises(ComposeClient::ComposeError) do
      ComposeClient.parse_svg(http_response(400, '{"error":"spec.layers is required"}'))
    end
    assert_match(/compose 400: spec.layers is required/, err.message)

    assert_raises(ComposeClient::ComposeError) { ComposeClient.compose(nil, { "width" => 1 }) }
  end

  test "layers_available tells the page which items are vectors" do
    sign_in
    v = svg_item(name: "candidate_09.svg")
    p = png_item(name: "proof.png")

    get composite_layers_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    rows = JSON.parse(response.body).to_h { |r| [r["id"], r] }

    assert_equal "vector", rows[v.id]["kind"]
    assert_equal "vector", rows[v.id]["layer_kind"]
    assert_equal "candidate", rows[v.id]["item_kind"], "the artifact kind is still reported"
    assert_equal true, rows[v.id]["vector"]

    assert_equal "raster", rows[p.id]["kind"]
    assert_equal "proof", rows[p.id]["item_kind"]
    assert_equal false, rows[p.id]["vector"]
  end
end
