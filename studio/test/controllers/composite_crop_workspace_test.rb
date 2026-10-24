require "test_helper"
require "base64"

# The compose builder's two expansions: a WORKSPACE the operator can enlarge
# (the stage is half the grid until they say otherwise, and the choice
# persists), and a manual CROP — a marquee inside a raster layer that stores a
# source window in FRACTIONS of the image on the layer itself, so the preview,
# the save, a template re-arrange, the recipe and the vector compose all cut
# one rect. Pins the markup contract, the save/show round trip, the template
# endpoint's preservation (CompositeLayout.place must not strip the field),
# and ComposeSpec's validation of the window.
class CompositeCropWorkspaceTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  PNG_URI = "data:image/png;base64," +
            Base64.strict_encode64(
              [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack("C*") +
              "not-a-full-png-but-decodable-bytes".b
            )
  SVG_URI = "data:image/svg+xml;base64," +
            Base64.strict_encode64('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>')

  CROP = { "x" => 0.25, "y" => 0.0, "w" => 0.5, "h" => 1.0 }.freeze

  def login
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = nil
  end

  def raster_layer(extra = {})
    { "key" => "l1", "name" => "photo.png", "src" => PNG_URI,
      "x" => 10, "y" => 20, "w" => 300, "h" => 200, "z" => 0,
      "kind" => "raster" }.merge(extra)
  end

  test "the builder offers the workspace and crop controls" do
    login
    get new_composite_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    ws = doc.at_css("#compWorkspace")
    refute_nil ws, "the workspace toggle exists on the Canvas card"
    assert_equal "false", ws["aria-pressed"], "starts at fit"
    assert_match(/Workspace: fit/, ws.text)
    assert_equal "workspace", ws["data-comp-action"], "wired through the action switch"

    crop = doc.at_css("#compCrop")
    refute_nil crop, "the crop mode exists beside Couple"
    assert crop.has_attribute?("data-comp-crop"), "a mode, not a data-comp-action"
    assert_equal "false", crop["aria-pressed"]
    assert_match(/Crop: off/, crop.text)

    reset = doc.at_css("#compCropReset")
    refute_nil reset, "the crop's undo exists"
    assert reset.has_attribute?("hidden"),
      "nothing is cropped on a new composite — a visible Reset would be a lie"

    hint = doc.at_css("#compHint").text
    assert_match(/Crop/, hint)
    assert_match(/Workspace/, hint)

    body = response.body
    assert_includes body, "function applyCrop", "the crop math ships with the page"
    assert_includes body, "function setWorkspace"
    assert_includes body, "cropMode", "the mode state exists"
    assert_includes body, "localStorage.setItem('comp-workspace'", "the choice persists"

    css = File.read(Rails.root.join("app", "assets", "stylesheets", "application.css"))
    assert_includes css, '.run-grid[data-workspace="large"]',
      "the enlarged workspace is a real grid rule"
    assert_includes css, "max-height: 78vh", "large gives tall composites height too"
    assert_includes css, ".comp-crop-badge", "a cropped layer says so in its row"
  end

  test "a crop round-trips: the create posts it and the page gives it back" do
    p = Project.create!(name: "compose-crop-owned", is_test: false)
    login
    post create_composite_path,
         params: { name: "cropped-probe", width: "1000", height: "800",
                   background: "transparent", project_id: p.id,
                   layers: JSON.generate([raster_layer("crop" => CROP)]) },
         headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect

    stored = Composite.order(:id).last
    assert_equal CROP, stored.layers.first["crop"],
      "the controller's free-form parse keeps the window"

    # The show route is GET /composite?id=N (no path segment), so the id has
    # to ride as a query param — composite_path(record) has nowhere to put it.
    get composite_path(id: stored.id), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    posted = JSON.parse(doc.at_css("#compLayers")["value"] || "[]")
    assert_equal 0.25, posted.first["crop"]["x"], "the builder is handed its own crop back"
    assert_includes doc.at_css("body").to_html, "Reset crop"
  end

  test "a template re-arrange keeps the crop — place must not strip it" do
    login
    post "/composite/template",
         params: { template: CompositeLayout::TEMPLATES.first,
                   layers: JSON.generate([raster_layer("crop" => CROP)]),
                   width: 1000, height: 800 },
         headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
    assert_response :success
    out = JSON.parse(response.body)
    refute_nil out["layers"], "the template answered with arranged layers"
    got = out["layers"].find { |l| l["key"] == "l1" }
    refute_nil got
    assert_equal CROP, got["crop"],
      "CompositeLayout.place merges x/y/w/h into a dup — every other field rides along"
    refute_nil got["x"], "and it still got arranged"
  end

  test "ComposeSpec carries the window, refuses a malformed one, omits it for vectors" do
    cropped = Composite.new(name: "spec-crop", width: 1000, height: 800,
                            background: "transparent",
                            layers: [raster_layer("crop" => CROP)])
    spec = ComposeSpec.build(cropped)
    assert_equal CROP, spec["layers"].first["crop"],
      "the spec's window equals the numbers the canvas drew from"

    broken = Composite.new(name: "spec-broken", width: 1000, height: 800,
                           background: "transparent",
                           layers: [raster_layer("crop" => { "x" => 0.5, "y" => 0,
                                                             "w" => 0.75, "h" => 1 })])
    err = assert_raises(ComposeSpec::Error) { ComposeSpec.build(broken) }
    assert_match(/inside the image/, err.message,
                 "a crop that runs off the image is broken geometry, refused not painted")

    vector = Composite.new(name: "spec-vec", width: 1000, height: 800,
                           background: "transparent",
                           layers: [{ "key" => "v1", "name" => "t.svg", "src" => SVG_URI,
                                      "x" => 0, "y" => 0, "w" => 100, "h" => 100, "z" => 0,
                                      "kind" => "vector", "crop" => CROP }])
    spec = ComposeSpec.build(vector)
    refute spec["layers"].first.key?("crop"),
      "a vector layer is composed from its SVG — its frame is its content, and the builder refuses to crop one"
  end
end
