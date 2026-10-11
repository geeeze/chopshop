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
                     background: "#ffffff", project_id: picker_project.id,
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
    # composite_path(c) is WRONG here and was asserting the bug: the show route
    # has no :id segment, so passing the record renders "/composite.1" -- the id
    # swallowed as a format suffix, which is not the composite page. The correct
    # target carries the id in the query string.
    # request_uri, not path: the id rides in the QUERY STRING, which `path` drops.
    assert_equal composite_path(id: c.id), URI.parse(response.location).request_uri
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

  test "Composite left the header; Compose sits on the Run Job page under Run Job" do
    sign_in
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    doc = Nokogiri::HTML(response.body)
    labels = doc.css("nav.topbar .nav-links a").map { |a| a.text.strip }
    refute_includes labels, "Composite",
      "Composite is not a header listing any more — it is reached from the Run Job page"

    # The Compose button sits under Run Job in the page head, like JSON on other
    # pages. The --below grid SLOT is carried by the row that occupies it (the
    # pair), not by each button: several actions share one cell and flex inside
    # it, so the head stays two lines tall instead of growing a line per button.
    head = doc.at_css(".page-head")
    refute_nil head, "the Run Job page must render its page head"
    slot = head.at_css(".head-action--below")
    refute_nil slot, "the head's second row must carry the --below grid slot"
    assert_includes slot["class"].split, "head-action-pair",
      "the row is a pair, so its buttons share one grid cell"

    compose = slot.at_css("a.head-action[href=\"#{new_composite_path}\"]")
    refute_nil compose, "a Compose link must point at the composite builder"
    assert_equal "Compose", compose.text.strip

    # PROMPTS / MASHUP / JSON share that row -- the controls for the prompt and
    # the contract sit under Run Job with Compose.
    [ "prompts-popup", "mashup-popup", "job-json-popup" ].each do |popup|
      refute_nil slot.at_css("button.head-action[data-popup='#{popup}']"),
        "#{popup} must have its own button in the head row"
    end
  end

  test "the compose page is titled Compose and carries the Run Job head action" do
    sign_in
    get new_composite_path, headers: { "User-Agent" => MODERN_UA }
    doc = Nokogiri::HTML(response.body)
    title = doc.at_css(".page-head .section-title")
    assert_equal "Compose", title.text.strip

    btn = doc.at_css("#compRunJob")
    refute_nil btn, "the compose page must carry a Run Job button in the head"
    assert_equal "Run Job", btn.text.strip
    assert_includes btn["class"].split, "head-action"
    assert_includes btn["class"].split, "btn-primary"

    refute_nil doc.at_css("#compCanvas"), "the canvas still renders"
    refute_nil doc.at_css("#compLayers"), "the hidden layer field still renders"
  end

  test "the excess create-composite and use-as-source buttons are gone" do
    sign_in
    get new_composite_path, headers: { "User-Agent" => MODERN_UA }
    body = response.body
    refute_includes body, "Create composite", "the create button is gone"
    refute_includes body, "Save composite", "the save button is gone"
    refute_includes body, "Use as job source", "the use-as-source button is gone"
    refute_match(/id="compRun"/, body, "the old compRun id is gone")
    refute_match(/id="compSave"/, body, "the old compSave id is gone")
  end
end
