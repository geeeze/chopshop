require "test_helper"

# The chained-recipe endpoint: one POST composes a composite's vector layers into
# the stored SVG artefact and records the compose job, then answers the created
# artefact and job (201). It never files a trace job against the SVG — the trace
# stage reads a RASTER only, so the composed SVG is the compose deliverable.
#
# Reuses flatten_vector's helpers: ComposeSpec, ComposeClient, store_svg,
# record_compose_job, compose_base_url. No new compose logic is written here.
class CompositesChainControllerTest < ActionDispatch::IntegrationTest
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
    # Runner labels are ENV-driven, and Job::RUNNER_DEFAULTS always supplies
    # `mock`, so this file used to depend on whichever runner an EARLIER test
    # happened to leave configured: with an `svg` label leaked in from elsewhere
    # in the suite the override was honoured, and running this file on its own
    # the override fell through to the default and the job was recorded against
    # `mock` ("Expected: \"svg\", Actual: \"mock\""). Set the labels this file
    # reads and restore them -- the rule for any test that creates a job.
    @saved_runners = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| @saved_runners[k] = ENV.delete(k) }
    ENV["CHOPSHOP_RUNNER_SVG_URL"] = "http://pipeline.invalid:8791"
    ENV["CHOPSHOP_RUNNER_SVG_KIND"] = "svg"
    Job.reset_runners_cache!
    @files = []
  end

  teardown do
    ENV["CHOPSHOP_PASSWORD"] = @original_password
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
    @saved_runners.each { |k, v| ENV[k] = v }
    Job.reset_runners_cache!
    @files.each { |f| File.delete(f) if File.exist?(f) }
    # Any job record created outside the tested assertions must be cleaned up,
    # or subsequent tests in the suite will see phantom jobs.
    Job.where("name LIKE ?", "%compose%").delete_all
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
    stored = "chain_probe_#{SecureRandom.hex(4)}#{File.extname(name)}"
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
      "opacity" => 1.0, "hue" => 0, "visible" => true }.merge(extra)
  end

  def raster_layer(item, extra = {})
    { "key" => "r#{item.id}", "name" => item.name, "kind" => "raster",
      "src" => scrapbook_item_file_path(item),
      "x" => 1, "y" => 2, "w" => 10, "h" => 10, "z" => 1,
      "opacity" => 1.0, "hue" => 0, "visible" => true }.merge(extra)
  end

  # Stub ComposeClient.compose the same way composite_recipe_test does.
  def with_compose(responder)
    calls = []
    original = ComposeClient.method(:compose)
    ComposeClient.define_singleton_method(:compose) do |base, spec, **kwargs|
      calls << { base: base, spec: spec, kwargs: kwargs }
      responder.call(base, spec)
    end
    yield(calls)
  ensure
    ComposeClient.define_singleton_method(:compose, original)
  end

  def composed_result
    { bytes: COMPOSED, content_type: "image/svg+xml", name: "compose-abc123.svg" }
  end

  # --- vector chain ---------------------------------------------------------

  test "a vector composite composes and records the job, returning 201" do
    sign_in
    item = svg_item
    c = Composite.create!(name: "badge", width: 100, height: 100,
                          layers: [vector_layer(item)],
                          project_id: picker_project.id)

    with_compose(lambda { |_base, _spec| composed_result }) do
      post chain_composite_path(c), headers: { "User-Agent" => MODERN_UA }
    end

    assert_response :created
    json = JSON.parse(response.body)

    assert json["composite_id"], "response carries the composite id"
    assert json["scrapbook_id"], "response carries a scrapbook artefact id"
    assert json["path"], "response carries the upload path"
    assert json["preview_url"], "response carries a preview_url"
    assert_equal "vector", json["mode"], "mode is vector (the SVG, never rasterised)"
    assert_equal "image/svg+xml", json["content_type"]
    assert_includes json, "job", "response carries a recorded job"
    assert_includes json["job"], "id"
    assert_includes json["job"], "name"
    assert_includes json["job"], "state"
    assert_includes json["job"], "runner"
    assert_includes json["job"], "url"
    assert_equal "done", json["job"]["state"], "the compose job is recorded already done"
    assert json["job_url"], "response carries a job_url"

    # The stored file exists on disk and is an SVG.
    assert File.file?(json["path"]), "the upload exists on disk"
    content = File.binread(json["path"])
    assert_match %r{<svg}, content, "the stored artefact is an SVG"

    # The job exists in the db with the right state.
    assert Job.exists?(json["job"]["id"])
    job = Job.find(json["job"]["id"])
    assert_equal "done", job.state
    assert_equal "vector", job.spec[Job::COMPOSE_SPEC_KEY]["mode"]
    assert_equal c.id, job.spec[Job::COMPOSE_SPEC_KEY]["composite_id"]
  end

  test "the response shape has all expected keys" do
    sign_in
    item = svg_item
    c = Composite.create!(name: "keys", width: 100, height: 100,
                          layers: [vector_layer(item)],
                          project_id: picker_project.id)

    with_compose(lambda { |_base, _spec| composed_result }) do
      post chain_composite_path(c), headers: { "User-Agent" => MODERN_UA }
    end

    json = JSON.parse(response.body)
    %w[composite_id scrapbook_id path mode content_type job job_url].each do |key|
      assert_includes json, key, "response has #{key}"
    end
  end

  test "returns the job name and runner recorded with the compose" do
    sign_in
    item = svg_item
    c = Composite.create!(name: "named", width: 100, height: 100,
                          layers: [vector_layer(item)],
                          project_id: picker_project.id)

    with_compose(lambda { |_base, _spec| composed_result }) do
      post chain_composite_path(c), headers: { "User-Agent" => MODERN_UA }
    end

    json = JSON.parse(response.body)
    assert_match /badge|keys|named/, json["job"]["name"]
    assert_not_nil json["job"]["runner"]
  end

  test "accepts a name override in the body" do
    sign_in
    item = svg_item
    c = Composite.create!(name: "orig", width: 100, height: 100,
                          layers: [vector_layer(item)],
                          project_id: picker_project.id)

    with_compose(lambda { |_base, _spec| composed_result }) do
      post chain_composite_path(c), params: { name: "custom-chain-name" },
                                   headers: { "User-Agent" => MODERN_UA }
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "custom-chain-name", json["job"]["name"],
                 "body name overrides the job name"
  end

  test "accepts a runner override in the body" do
    sign_in
    item = svg_item
    c = Composite.create!(name: "runr", width: 100, height: 100,
                          layers: [vector_layer(item)],
                          project_id: picker_project.id)

    with_compose(lambda { |_base, _spec| composed_result }) do
      post chain_composite_path(c), params: { runner: "svg" },
                                   headers: { "User-Agent" => MODERN_UA }
    end

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "svg", json["job"]["runner"]
  end

  # --- no vector layer ------------------------------------------------------

  test "a raster-only composite returns 422, no job created" do
    sign_in
    item = png_item
    c = Composite.create!(name: "flat", width: 100, height: 100,
                          layers: [raster_layer(item)],
                          project_id: picker_project.id)

    assert_difference -> { Job.count }, 0 do
      post chain_composite_path(c), headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json, "error"
    assert_not Job.exists?(c.id) # no job linked
  end

  test "an empty composite returns 422, no job created" do
    sign_in
    c = Composite.create!(name: "blank", width: 100, height: 100, layers: [],
                          project_id: picker_project.id)

    assert_difference -> { Job.count }, 0 do
      post chain_composite_path(c), headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json, "error"
  end

  # --- compose failure ------------------------------------------------------

  test "a vector layer whose source is missing returns 422, no job created" do
    sign_in
    # A vector layer whose src points to a scrapbook item that does not exist.
    c = Composite.create!(name: "gone", width: 100, height: 100,
                          layers: [{ "key" => "v1", "name" => "ghost", "kind" => "vector",
                                     "src" => "/nonexistent/path.svg",
                                     "x" => 5, "y" => 5, "w" => 30, "h" => 20, "z" => 0,
                                     "opacity" => 1.0, "hue" => 0, "visible" => true }],
                          project_id: picker_project.id)

    assert_difference -> { Job.count }, 0 do
      post chain_composite_path(c), headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json, "error"
    assert_includes json["error"].downcase, "source",
                 "the 422 explains that the layer's source is unreachable"
  end

  test "a vector layer whose source is an SVG but not a real svg document" do
    sign_in
    # A `data:` URI pointing at a real PNG byte stream: `read` resolves it, but
    # the bytes do not begin with `<svg`, so ComposeSpec.build raises.
    fake = stored_item(name: "x.png", body: "\x89PNG\r\n\x1a\n" + ("\x00" * 32), kind: "candidate")
    c = Composite.create!(name: "fake", width: 100, height: 100,
                          layers: [vector_layer(fake,
                                    "src" => scrapbook_item_file_path(fake))],
                          project_id: picker_project.id)

    assert_no_difference -> { Job.count } do
      post chain_composite_path(c), headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json, "error"
  end

  test "the compose runner answering an error envelope returns 502" do
    sign_in
    item = svg_item
    c = Composite.create!(name: "badrunner", width: 100, height: 100,
                          layers: [vector_layer(item)],
                          project_id: picker_project.id)

    # A ComposeClient::ComposeError is raised when the runner refuses / returns
    # an error envelope. ComposeClient.compose re-raises on non-200/invalid;
    # stub a responder that raises the client error.
    with_compose(lambda { |_base, _spec|
      raise ComposeClient::ComposeError, "compose service refused"
    }) do
      post chain_composite_path(c), headers: { "User-Agent" => MODERN_UA }
    end

    assert_response :bad_gateway
    json = JSON.parse(response.body)
    assert_includes json, "error"
    assert_equal "compose service refused", json["error"]
  end

  # --- owner scoping --------------------------------------------------------

  test "a non-owner cannot chain another user's composite — 404" do
    item = svg_item
    # A composite owned by SOMEONE ELSE (not the logged-in "test" user).
    other = User.create!(handle: "other-owner",
                         password_digest: BCrypt::Password.create("x"))
    theirs = Composite.create!(name: "theirs", width: 100, height: 100,
                               layers: [vector_layer(item)],
                               project_id: picker_project.id,
                               owner: other.handle)
    assert_equal "other-owner", theirs.owner

    sign_in  # the session is the "test" user, not other-owner

    assert_no_difference -> { Job.count } do
      with_compose(lambda { |_base, _spec| composed_result }) do
        post chain_composite_path(theirs), headers: { "User-Agent" => MODERN_UA }
      end
    end
    assert_response :not_found
  end

  test "login is required — unauthenticated 302" do
    item = svg_item
    c = Composite.create!(name: "open", width: 100, height: 100,
                          layers: [vector_layer(item)],
                          project_id: picker_project.id)

    post chain_composite_path(c), headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end
end
