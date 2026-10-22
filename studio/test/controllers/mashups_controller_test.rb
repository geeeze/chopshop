require "test_helper"

# The iterative mashup UX controller (#51). MashupClient.synthesize is stubbed
# for every test so no live LM Studio server is contacted.
class MashupsControllerTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  PROMPT = "a red phoenix rising from ashes, flat ink three colours".freeze
  RATIONALE = "Both sources name the phoenix; the flat ink style is kept.".freeze

  def login!
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # Stub MashupClient.synthesize for the duration of the block. The stub
  # returns a MashupResult with the given prompt/rationale. When `sequence`
  # is given, each successive call returns the next prompt in the sequence
  # (the counter advances per call, wrapping at the end), so a create then a
  # re-mash return different prompts.
  def stub_mashup(prompt: PROMPT, rationale: RATIONALE, sequence: nil)
    calls = 0
    mutex = Mutex.new
    original = MashupClient.method(:synthesize)
    MashupClient.define_singleton_method(:synthesize) do |*_args, **kw|
      mutex.synchronize do
        p = sequence ? sequence[calls % sequence.length] : prompt
        calls += 1
        MashupClient::MashupResult.new(prompt: p, rationale: rationale)
      end
    end
    yield MashupClient.method(:synthesize)
  ensure
    MashupClient.define_singleton_method(:synthesize, original)
  end

  # POST /mashup with the given sources, returning the parsed JSON response.
  def mashup_create(sources: nil, source_ids: nil)
    params = {}
    params[:sources] = sources if sources
    params[:source_ids] = source_ids if source_ids
    post mashups_path, params: params, headers: { "User-Agent" => MODERN_UA }
    JSON.parse(response.body)
  end

  # POST /mashup/:token/remash, returning the parsed JSON response.
  def mashup_remash(token)
    post remash_mashup_path(token), headers: { "User-Agent" => MODERN_UA }
    JSON.parse(response.body)
  end

  # POST /mashup/:token/revert, returning the parsed JSON response.
  def mashup_revert(token)
    post revert_mashup_path(token), headers: { "User-Agent" => MODERN_UA }
    JSON.parse(response.body)
  end

  # POST /mashup/:token/use, following the redirect.
  def mashup_use(token)
    post use_mashup_path(token), headers: { "User-Agent" => MODERN_UA }
  end

  # --- create ---------------------------------------------------------------

  test "the first mashup creates a chain and returns the token" do
    login!
    stub_mashup do |_m|
      body = mashup_create(sources: ["a red phoenix", "flat ink, three colours"])
      assert_response :success
      assert body["token"], "the response carries the chain token"
      assert_equal PROMPT, body["prompt"]
      assert_equal RATIONALE, body["rationale"]
      assert_equal 0.2, body["temp"]
      assert_equal 0, body["position"]
      assert_equal 1, body["chain_length"]
      assert_equal false, body["can_revert"]
      assert_equal 0.35, body["next_temp"]
    end
  end

  test "the first mashup accepts library source ids" do
    login!
    p1 = PromptSource.create!(dataset: "diffusiondb", prompt: "a red phoenix")
    p2 = PromptSource.create!(dataset: "diffusiondb", prompt: "flat ink, three colours")
    stub_mashup do |_m|
      body = mashup_create(source_ids: [p1.id, p2.id])
      assert_response :success
      assert body["token"]
    end
  end

  test "create with no sources is refused" do
    login!
    body = mashup_create(sources: [])
    assert_response :unprocessable_entity
    assert_match(/at least one source/, body["error"])
  end

  test "create with an unknown source id is refused" do
    login!
    body = mashup_create(source_ids: [999_999])
    assert_response :unprocessable_entity
    assert_match(/no library prompts/, body["error"])
  end

  test "create propagates a MashupError from the client" do
    login!
    original = MashupClient.method(:synthesize)
    MashupClient.define_singleton_method(:synthesize) { |*_a, **_k|
      raise MashupClient::MashupError, "LM Studio connection failed: ECONNREFUSED"
    }
    body = mashup_create(sources: ["a red phoenix"])
    assert_response :bad_gateway
    assert_match(/connection failed/, body["error"])
  ensure
    MashupClient.define_singleton_method(:synthesize, original)
  end

  # --- show -----------------------------------------------------------------

  test "show returns the current state" do
    login!
    stub_mashup(sequence: [PROMPT, "a bolder phoenix"]) do |_m|
      body = mashup_create(sources: ["a red phoenix", "flat ink"])
      token = body["token"]

      get mashup_path(token), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      shown = JSON.parse(response.body)
      assert_equal PROMPT, shown["prompt"]
      assert_equal 0, shown["position"]
    end
  end

  test "show with an unknown token is a 404" do
    login!
    get mashup_path("no-such-token"), headers: { "User-Agent" => MODERN_UA }
    assert_response :not_found
  end

  # --- remash ---------------------------------------------------------------

  test "re-mash escalates temperature and appends a chain entry" do
    login!
    stub_mashup(sequence: [PROMPT, "a bolder phoenix, wider wingspan"]) do |_m|
      body = mashup_create(sources: ["a red phoenix", "flat ink"])
      token = body["token"]

      remashed = mashup_remash(token)
      assert_response :success
      assert_equal "a bolder phoenix, wider wingspan", remashed["prompt"]
      assert_equal 0.35, remashed["temp"]
      assert_equal 1, remashed["position"]
      assert_equal 2, remashed["chain_length"]
      assert_equal true, remashed["can_revert"]
      assert_equal 0.5, remashed["next_temp"]
    end
  end

  test "re-mash after revert escalates from the reverted position" do
    login!
    stub_mashup(sequence: [PROMPT, "v2", "v3"]) do |_m|
      body = mashup_create(sources: ["a", "b"])
      token = body["token"]

      mashup_remash(token) # 0.35
      mashup_remash(token) # 0.50

      reverted = mashup_revert(token)
      assert_equal 0.35, reverted["temp"]
      assert_equal 1, reverted["position"]

      remashed = mashup_remash(token)
      assert_equal 0.5, remashed["temp"],
        "escalation tracks the pointer, not a global counter"
    end
  end

  test "re-mash with an unknown token is a 404" do
    login!
    post remash_mashup_path("no-such-token"), headers: { "User-Agent" => MODERN_UA }
    assert_response :not_found
  end

  test "the temperature is capped at the maximum" do
    login!
    stub_mashup(sequence: (1..20).map { |i| "prompt #{i}" }) do |_m|
      body = mashup_create(sources: ["a", "b"])
      token = body["token"]

      temps = [0.2]
      loop do
        result = mashup_remash(token)
        break if result["error"]
        temps << result["temp"]
        break if temps.length >= 10
      end
      assert_equal 1.0, temps.last
    end
  end

  # --- revert ---------------------------------------------------------------

  test "revert walks the pointer back to an earlier result" do
    login!
    stub_mashup(sequence: [PROMPT, "v2", "v3"]) do |_m|
      body = mashup_create(sources: ["a", "b"])
      token = body["token"]

      mashup_remash(token)
      mashup_remash(token)

      reverted = mashup_revert(token)
      assert_response :success
      assert_equal 1, reverted["position"]
      assert_equal "v2", reverted["prompt"]
      assert_equal 0.35, reverted["temp"]

      reverted = mashup_revert(token)
      assert_equal 0, reverted["position"]
      assert_equal PROMPT, reverted["prompt"]
      assert_equal 0.2, reverted["temp"]
    end
  end

  test "revert at the start is refused" do
    login!
    stub_mashup do |_m|
      body = mashup_create(sources: ["a", "b"])
      token = body["token"]

      post revert_mashup_path(token), headers: { "User-Agent" => MODERN_UA }
      assert_response :unprocessable_entity
      body = JSON.parse(response.body)
      assert_match(/already at the first/, body["error"])
    end
  end

  test "revert with an unknown token is a 404" do
    login!
    post revert_mashup_path("no-such-token"), headers: { "User-Agent" => MODERN_UA }
    assert_response :not_found
  end

  # --- use ------------------------------------------------------------------

  test "use hands the chosen prompt to the Run Job form via a prompt draft token" do
    login!
    stub_mashup(sequence: [PROMPT, "a bolder phoenix"]) do |_m|
      body = mashup_create(sources: ["a red phoenix", "flat ink"])
      token = body["token"]

      # Advance to the second result, then use it.
      mashup_remash(token)
      mashup_use(token)

      assert_response :redirect
      uri = URI.parse(response.location)
      assert_match %r{/jobs/new}, uri.path
      draft_token = Rack::Utils.parse_query(uri.query)["prompt_draft_token"]
      refute_nil draft_token, "the hand-off carries a prompt draft token"

      # The Run Job form shows the mashup result as the prompt default.
      get uri.path + "?" + uri.query, headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      assert_includes response.body, "a bolder phoenix",
        "the mashup result is the prompt default on the Run Job form"
      assert_includes response.body, "mashup",
        "the provenance names the mashup"
    end
  end

  test "use after revert hands the reverted prompt" do
    login!
    stub_mashup(sequence: [PROMPT, "a bolder phoenix"]) do |_m|
      body = mashup_create(sources: ["a red phoenix", "flat ink"])
      token = body["token"]

      mashup_remash(token)
      mashup_revert(token)
      mashup_use(token)

      uri = URI.parse(response.location)
      draft_token = Rack::Utils.parse_query(uri.query)["prompt_draft_token"]
      get uri.path + "?" + uri.query, headers: { "User-Agent" => MODERN_UA }
      assert_includes response.body, PROMPT,
        "the reverted (first) prompt is what gets used"
    end
  end

  test "use with an unknown token redirects with an alert" do
    login!
    mashup_use("no-such-token")
    assert_response :redirect
    assert_match(/no such mashup/, flash[:alert].to_s)
  end

  # --- auth -----------------------------------------------------------------

  test "the mashup endpoints require login" do
    post mashups_path, params: { sources: ["a"] }
    assert_redirected_to login_path

    get mashup_path("some-token")
    assert_redirected_to login_path

    post remash_mashup_path("some-token")
    assert_redirected_to login_path

    post revert_mashup_path("some-token")
    assert_redirected_to login_path

    post use_mashup_path("some-token")
    assert_redirected_to login_path
  end
end
