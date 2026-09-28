require "test_helper"

# The composite builder: a job's source raster assembled from layers. The
# controller's own job is persistence plus the ONE thing that must be
# server-side — the flatten, which stores the browser-composed PNG twice (a
# scrapbook artefact and the upload the runner reads) and refuses anything that
# is not a PNG.
class CompositeTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  setup do
    @original_password = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
  end

  teardown do
    ENV["CHOPSHOP_PASSWORD"] = @original_password
  end

  def sign_in
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def layer(x: 10, y: 20, w: 300, h: 200, z: 0)
    { "key" => "l1", "name" => "piece", "src" => nil,
      "x" => x, "y" => y, "w" => w, "h" => h, "z" => z,
      "opacity" => 1.0, "hue" => 0, "visible" => true }
  end

  def png_upload(bytes = nil)
    bytes ||= "\x89PNG\r\n\x1a\n".b + ("\x00" * 64)
    file = Tempfile.new(["composite", ".png"])
    file.binmode
    file.write(bytes)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "image/png")
  end

  test "the builder page is login-gated and renders a canvas" do
    get new_composite_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect

    sign_in
    get new_composite_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_includes response.body, 'id="compCanvas"'
    assert_includes response.body, 'id="compLayers"',
      "the hidden layer field is what the form posts"
  end

  test "creates a composite with sensible defaults and round-trips its layers" do
    sign_in
    layers = [layer, layer(x: 500, z: 1).merge("key" => "l2")]
    assert_difference -> { Composite.count }, 1 do
      post create_composite_path,
           params: { name: "badge", width: 1200, height: 1200,
                     background: "#ffffff",
                     layers: JSON.generate(layers) },
           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :redirect

    c = Composite.order(:id).last
    assert_equal "badge", c.name
    assert_equal 2, c.layers.size
    assert_equal %w[l1 l2], c.layers.map { |l| l["key"] }
    # Paint order is z, not array order.
    assert_equal %w[l1 l2], c.ordered_layers.map { |l| l["key"] }
  end

  test "update replaces the layers the canvas posted" do
    sign_in
    c = Composite.create!(name: "c", width: 100, height: 100, layers: [layer])
    patch composite_update_path(c),
          params: { name: "c2", width: 200, height: 200,
                    layers: JSON.generate([layer(x: 5, y: 6, z: 3)]) },
          headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    c.reload
    assert_equal "c2", c.name
    assert_equal 200, c.width
    assert_equal 6, c.layers.first["y"]
  end

  test "a malformed layers payload does not blank the layers" do
    sign_in
    c = Composite.create!(name: "c", width: 100, height: 100, layers: [layer])
    patch composite_update_path(c),
          params: { layers: "not json at all" },
          headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal 1, c.reload.layers.size, "a bad payload must not wipe the layers"
  end

  test "flatten stores the PNG as a scrapbook item AND as an upload" do
    sign_in
    c = Composite.create!(name: "badge", width: 100, height: 100, layers: [layer])
    assert_difference -> { ScrapbookItem.count }, 1 do
      post flatten_composite_path(c), params: { file: png_upload },
                                      headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :success
    json = JSON.parse(response.body)
    assert ScrapbookItem.find(json["scrapbook_id"]).stored_path.file?,
      "the flattened composite is a re-usable scrapbook artefact"
    assert File.file?(json["path"]), "and an upload the runner can read"
    assert_match %r{upload_preview}, json["preview_url"]
  end

  test "flatten refuses non-PNG bytes" do
    sign_in
    c = Composite.create!(name: "badge", width: 100, height: 100, layers: [layer])
    assert_no_difference -> { ScrapbookItem.count } do
      post flatten_composite_path(c),
           params: { file: png_upload("definitely not a png") },
           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :bad_request
  end

  test "use hands the flattened upload to the new-job form" do
    sign_in
    c = Composite.create!(name: "badge", width: 100, height: 100, layers: [layer])
    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    dest = uploads.join("upload_composite_probe.png")
    File.binwrite(dest, "\x89PNG".b)

    post use_composite_path(c), params: { path: dest.to_s },
                                headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_match %r{/jobs/new\?.*input_path=}, response.location
  ensure
    File.delete(dest) if dest && File.exist?(dest)
  end

  test "use refuses a path outside the uploads dir" do
    sign_in
    c = Composite.create!(name: "badge", width: 100, height: 100, layers: [layer])
    post use_composite_path(c), params: { path: "/etc/passwd" },
                                headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal composite_path(c), URI.parse(response.location).path
  end

  test "layers_available lists scrapbook items as importable layers" do
    sign_in
    dir = Rails.root.join("storage", "scrapbook")
    dir.mkpath
    stored = "layer_probe.png"
    File.binwrite(dir.join(stored), "\x89PNG".b)
    item = ScrapbookItem.create!(name: "piece.png", kind: "upload", file: stored)

    get composite_layers_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    ids = JSON.parse(response.body).map { |i| i["id"] }
    assert_includes ids, item.id
  end

  test "the nav carries Composite between Run Job and JSON" do
    sign_in
    get new_composite_path, headers: { "User-Agent" => MODERN_UA }
    doc = Nokogiri::HTML(response.body)
    labels = doc.css("nav.topbar .nav-links a").map { |a| a.text.strip }
    assert_includes labels, "Composite"
    assert_operator labels.index("Composite"), :>, labels.index("Run Job")
    assert_operator labels.index("Composite"), :<, labels.index("JSON")
  end
end
