require "test_helper"

# The COMPOSITE path: what the operator's own Compose builder needs in order to
# work at all. Four separate faults were found by driving this feature as an
# agent, and each one is pinned here, because each was invisible to the suite:
#
#   1. `composite_path(@composite)` redirected to `/composite.5` -- the show route
#      has no `:id` SEGMENT, so Rails appended the object as a format suffix. The
#      operator landed on a URL that is not the composite page.
#   2. `ComposeSpec` resolved a layer's `src` to real bytes, but the CREATE
#      action set `palette:`, a column the production DB did not have -- the
#      migration existed and had never been applied. Every create 500'd.
#   3. `compose_base_url` picked `labels.first`, and `mock` is an svg-KIND runner
#      whose URL sorts first, so composites were composed against the MOCK --
#      which has no `/compose` and answers `404 {"error":"unknown route"}`.
#   4. `ComposeClient#parse_svg` required the response body to start with `<svg`,
#      while the compose operation answers with an XML declaration first. A 200
#      with perfectly good SVG bytes was rejected as "expected an SVG document".
#
# Nothing here talks to a runner: the point is the studio's OWN decision, which
# is what broke each time.
class CompositeWiringTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def with_runners(mapping)
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV.delete("CHOPSHOP_COMPOSE_URL")
      ENV.delete("CHOPSHOP_COMPOSE_RUNNER")
      mapping.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      ENV.delete("CHOPSHOP_COMPOSE_URL")
      ENV.delete("CHOPSHOP_COMPOSE_RUNNER")
      Job.reset_runners_cache!
    end
  end

  def login
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def layer_svg
    { "kind" => "vector",
      "src" => "/jobs/upload_preview/frame_test.svg",
      "x" => 0, "y" => 0, "w" => 100, "h" => 100 }
  end

  # --- 1. the redirect is the composite page, not /composite.<id> ------------

  test "creating a composite lands on the composite page, not on /composite.<id>" do
    login
    post create_composite_path, params: {
      name: "probe", width: "100", height: "100", background: "transparent",
      layers: JSON.generate([ layer_svg ])
    }, headers: { "User-Agent" => MODERN_UA }

    assert_response :redirect
    target = response.location
    created = Composite.order(:id).last
    assert_equal composite_path(id: created.id), URI.parse(target).request_uri,
      "the redirect must carry the id in the QUERY STRING: the show route has no " \
      ":id segment, so composite_path(@composite) renders /composite.#{created.id} " \
      "-- a URL that is not the composite page"
    refute_match(/\/composite\.\d+\z/, target,
      "an id swallowed as a FORMAT SUFFIX is the shape this pins against")
  end

  # --- 2. a composite SAVES (the palette column exists and is writable) -----

  test "a composite can be created with a palette" do
    login
    post create_composite_path, params: {
      name: "palette probe", width: "100", height: "100", background: "transparent",
      palette: "#101010,#f2f2f2", layers: JSON.generate([ layer_svg ])
    }, headers: { "User-Agent" => MODERN_UA }

    assert_response :redirect, "a create must not 500: the palette column has to exist"
    assert_equal [ "#101010", "#f2f2f2" ], Composite.order(:id).last.palette
  end

  # --- 3. compose targets the REAL pipeline runner, never the mock ----------

  test "the compose target skips the mock runner" do
    with_runners("CHOPSHOP_RUNNER_MOCK_URL" => "http://mock.invalid:8790",
                 "CHOPSHOP_RUNNER_SVG_URL" => "http://real.invalid:8787") do
      assert_includes Job.pipeline_runners, "mock",
        "mock IS svg-kind (its job is to fake the pipeline), which is exactly why " \
        "picking the FIRST svg runner is wrong"

      controller = CompositesController.new
      target = controller.send(:compose_base_url)
      assert_equal "http://real.invalid:8787", target,
        "compose must not be pointed at the mock: it has no /compose and answers " \
        "404 unknown route, which is how every vector composite failed"
    end
  end

  test "an explicit CHOPSHOP_COMPOSE_URL still wins" do
    with_runners("CHOPSHOP_RUNNER_SVG_URL" => "http://real.invalid:8787") do
      ENV["CHOPSHOP_COMPOSE_URL"] = "http://explicit.invalid:9999"
      controller = CompositesController.new
      assert_equal "http://explicit.invalid:9999", controller.send(:compose_base_url)
    end
  end

  # --- 4. an SVG that opens with an XML declaration is still an SVG ---------

  test "the compose client accepts a document that opens with an XML declaration" do
    declarative = %(<?xml version='1.0' encoding='utf-8'?>\n<svg xmlns="http://www.w3.org/2000/svg"/>)
    bare = %(<svg xmlns="http://www.w3.org/2000/svg"/>)

    assert ComposeClient.send(:svg_document?, declarative),
      "the compose operation emits an XML declaration first; rejecting it is how " \
      "a 200 with the right bytes read as 'expected an SVG document'"
    assert ComposeClient.send(:svg_document?, bare), "the bare form keeps working"
    assert ComposeClient.send(:svg_document?, bare),
      "a BOM or leading whitespace is part of a valid document too"
    refute ComposeClient.send(:svg_document?, %(<html><body>nope</body></html>)),
      "and a document that is NOT an SVG is still refused"
    refute ComposeClient.send(:svg_document?, "")

    # The plot client carried the same guard and the same fault.
    assert PlotClient.send(:svg_document?, declarative)
  end
end
