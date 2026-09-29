require "test_helper"

# The sketch surfaces: the arrangement endpoints, and the builder page that
# drives them.
#
# The endpoint tests are here rather than only in the model's, because the model
# can be right while the WIRING is dead — this repo has shipped a feature that
# was unreachable from every page and green everywhere. A route that is not
# declared, a button that posts nothing, or a module that is never imported all
# look identical to a working feature from the model's side.
class CompositeSketchTest < ActionDispatch::IntegrationTest
  # The gate answers the modern-UA branch, so the login helper has to look like a
  # browser — the same shape every other authed test here uses.
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/120.0 Safari/537.36".freeze

  PAGES = %w[
    app/views/composites/show.html.erb
    app/javascript/aether-sketch.js
    app/javascript/aether.js
    config/importmap.rb
  ].freeze

  def src(path)
    Rails.root.join(path).read
  end

  # The builder page's own script, so the wiring assertions are about the code
  # that runs rather than the markup around it.
  def page_script
    src("app/views/composites/show.html.erb")[/<script>.*?<\/script>/m].to_s
  end

  setup do
    @original_password = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
  end

  teardown do
    ENV["CHOPSHOP_PASSWORD"] = @original_password
  end

  def login!
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def layers_json(count)
    (1..count).map do |i|
      { "key" => "l#{i}", "name" => "layer #{i}", "x" => i * 30, "y" => i * 20,
        "w" => 400, "h" => 300, "z" => i - 1, "visible" => true }
    end.to_json
  end

  # ------------------------------------------------------------ the module

  test "the builder page loads the sketch engine" do
    assert_match(/pin "aether-sketch", to: "aether-sketch\.js"/, src("config/importmap.rb"),
      "an unpinned module is a 404 in the importmap graph")
    # The builder page's own script is CLASSIC (inline), so the module has to be
    # reachable from the bundle that page loads: application -> aether ->
    # aether-sketch. Anything else and window.Aether.sketch is undefined on the
    # page that needs it, with no error anywhere.
    assert_includes src("app/javascript/aether.js"), 'import "aether-sketch";'
    assert_includes src("app/views/composites/show.html.erb"), "window.Aether && window.Aether.sketch"
  end

  test "the engine has no dependencies of its own" do
    js = src("app/javascript/aether-sketch.js")
    refute_match(/^\s*import /, js, "the engine must stand alone: no imports at all")
    refute_match(/require\(/, js)
    # Ruby side: standard library only.
    ruby = src("app/models/composite_layout.rb")
    refute_match(/^\s*require /, ruby, "the layout maths needs nothing outside the stdlib")
  end

  # ------------------------------------------------------------ the wiring

  test "the page offers the snap controls and the templates, in one place" do
    erb = src("app/views/composites/show.html.erb")
    doc = Nokogiri::HTML(erb.sub(/<%=.*?%>/m, ""))

    assert doc.at_css("[data-comp-couple]"), "the Couple toggle is the coupling gesture"
    assert doc.at_css("#compMetrics"), "the readout the score is shown in"
    assert doc.at_css("#compCouple[aria-pressed]"), "a mode, so it says whether it is on"

    # One button per template, from the server's own list: a hardcoded set here
    # would drift from CompositeLayout::TEMPLATES the first time one is added.
    assert_includes erb, "CompositeLayout::TEMPLATES.each"
    CompositeLayout::TEMPLATES.each { |t| assert_includes erb, "data-comp-template=\"<%= t %>\"" }

    # Both halves are wired: the drag snaps, the release couples. Plain booleans
    # on purpose — a failing `assert_includes` prints the whole 900-line file,
    # which buries the one line that mattered.
    script = page_script
    assert script.include?("s.snap(l, comp.layers"), "the drag must ask the engine to snap"
    assert script.include?("sketch().couple(l, k.how, k.to)"), "the release must be able to keep it"
    assert script.include?("Math.abs(k.delta) >= 1"),
      "only a snap that MOVED the layer is worth keeping: a zero-delta relation is " \
      "one the operator never asked for"
    assert script.include?("solveFrom(l.key)"), "coupled layers must be driven by the one being moved"
    assert script.include?("comp.snap.guides"), "the guides have to be drawn, or the snap is invisible"
  end

  test "a coupled layer says so, and can be released" do
    erb = src("app/views/composites/show.html.erb")
    assert_includes erb, "linkBadge(l)"
    assert_includes erb, "[data-comp-uncouple]"
    assert_match(/function releaseLinks/, erb, "the veto the operator needs")
    # A relation to a deleted layer must not linger.
    assert_match(/k\.to !== key/, erb, "removing a layer strips the links that pointed at it")
  end

  # ------------------------------------------------------------ the endpoints

  test "the template endpoint arranges the layers it is handed, without needing an id" do
    login!
    post composite_template_path, params: { template: "grid", layers: layers_json(4),
                                            width: 2000, height: 2000 },
                                  as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "grid", body["template"]
    assert_equal 4, body["placed"]
    assert_equal 4, body["layers"].length
    assert body["layers"].all? { |l| l["links"].any? },
      "a template that only writes coordinates is a very large snap"
    assert body["metrics"]["score"].is_a?(Numeric)
    assert_equal CompositeLayout::TEMPLATES.sort, body["templates"].sort
    assert body["constraints"]["align-left"].present?, "the vocabulary travels with the answer"
  end

  test "an arrangement that cannot satisfy itself still reports its score" do
    login!
    post composite_template_path, params: { template: "grid", layers: layers_json(1),
                                            width: 1000, height: 1000 },
                                  as: :json
    assert_response :success
    assert_equal 1, JSON.parse(response.body)["placed"]
  end

  test "an unknown template is refused with the names to choose from" do
    login!
    post composite_template_path, params: { template: "spiral", layers: layers_json(2) }, as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "unknown template", body["error"]
    assert_equal CompositeLayout::TEMPLATES.sort, body["templates"].sort
  end

  test "layers that are not a JSON array are a caller error, not an empty composite" do
    login!
    post composite_template_path, params: { template: "grid", layers: "not json" }, as: :json
    assert_response :bad_request
    assert_match(/JSON array/, JSON.parse(response.body)["error"])
  end

  test "the metrics endpoint reports one composite's arrangement, and its vocabulary" do
    login!
    margin = CompositeLayout.frame(width: 1200, height: 900)["margin"]
    composite = Composite.create!(name: "sketch-metrics", width: 1200, height: 900,
                                  background: "transparent",
                                  layers: [{ "key" => "a", "name" => "a", "x" => margin, "y" => margin,
                                             "w" => 400, "h" => 300, "z" => 0, "visible" => true,
                                             "links" => [{ "how" => "margin-left", "to" => "canvas" }] }])
    get composite_metrics_path(id: composite.id), as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal composite.id, body["composite_id"]
    assert_equal 1, body["metrics"]["layers"]
    assert_equal 1, body["metrics"]["links"]
    assert_equal 0.0, body["residual"]
    assert_equal "margin-left", body["constraints"].first["how"]
    assert body["vocabulary"].key?("mirror-x")
  ensure
    composite&.destroy
  end

  test "the metrics endpoint is login-gated like every other authed route" do
    composite = Composite.create!(name: "gated", width: 100, height: 100, background: "transparent")
    get composite_metrics_path(id: composite.id), as: :json
    assert_response :redirect
  ensure
    composite&.destroy
  end

  test "a template with an id applies to the stored composite" do
    login!
    composite = Composite.create!(name: "sketch-apply", width: 2000, height: 2000,
                                  background: "transparent",
                                  layers: (1..3).map { |i|
                                    { "key" => "l#{i}", "name" => "l#{i}", "x" => 5, "y" => 5,
                                      "w" => 300, "h" => 200, "z" => i, "visible" => true }
                                  })
    post composite_template_path, params: { id: composite.id, template: "row" }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert body["saved"], "applying to a stored composite persists it"
    assert_equal 3, composite.reload.layers.length
    assert composite.reload.layers.all? { |l| l["links"].any? }

    # Positions were written through the same plan the page uses, so the stored
    # composite's own metrics now score the arrangement rather than the mess.
    assert_equal body["metrics"]["score"], composite.reload.layout_metrics["score"]
  ensure
    composite&.destroy
  end
end
