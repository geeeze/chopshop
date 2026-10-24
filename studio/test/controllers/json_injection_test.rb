require "test_helper"

# JSON embedded into <script> blocks must be json_escape'd, not html_safe'd.
# JSON.generate does NOT escape <, > or &, so a value carrying "</script>" broke
# out of the script element and executed as markup. Two surfaces did this, and
# both are pinned here so the raw value can never be reflected as markup again:
#
#   1. jobs/new reflected the input_path / preview_url query params into a
#      <script> block (an attacker-controlled path/endpoint).
#   2. composites/show embedded the layer JSON (layer names are user-controlled,
#      from scrapbook drags and uploads) and the background value.
#
# The fix is json_escape, which renders <, > and & as \u003c, \u003e and \u0026 --
# the browser's HTML parser never sees the closing tag, and the JS string still
# decodes to the original value.
class JsonInjectionTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  PAYLOAD = "</script><script>alert(1)</script>".freeze

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

  def assert_json_escaped(body)
    refute_includes body, "<script>alert(1)</script>",
      "the raw payload must never appear as markup"
    assert_includes body, "\\u003c",
      "the closing < must be json_escape'd to \\u003c so the browser never sees a tag"
  end

  test "jobs/new reflects the input_path and preview_url params as escaped JSON" do
    sign_in
    get new_job_path(input_path: PAYLOAD, preview_url: "https://x.invalid/"), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_json_escaped(response.body)
  end

  test "composites/show embeds layer names and the background as escaped JSON" do
    sign_in
    layer = { "key" => "l1", "name" => PAYLOAD, "src" => nil,
              "x" => 10, "y" => 10, "w" => 50, "h" => 50, "z" => 0,
              "opacity" => 1.0, "hue" => 0, "visible" => true }
    composite = Composite.create!(name: "c", width: 100, height: 100,
                                  background: PAYLOAD, layers: [layer])
    # The builder's GET always renders a NEW composite (the show route carries no
    # id), so the stored layers reach the page only through the update failure
    # path, which re-renders the builder with the layer JSON in hand. A blank name
    # trips presence validation and forces that re-render.
    patch composite_update_path(composite),
          params: { name: "", layers: JSON.generate([layer]) },
          headers: { "User-Agent" => MODERN_UA }
    assert_response :unprocessable_entity
    assert_json_escaped(response.body)
  end

  # THE CHECK THE ORIGINAL FIX LACKED, and the reason it shipped broken. Escaping
  # the payload is necessary and NOT sufficient: json_escape returns a plain
  # String, so a bare `<%= %>` escapes the result a SECOND time and the structural
  # quotes become &quot;. Entities are never decoded inside a <script>, so the block
  # stops being JavaScript — the whole inline script on the page dies, silently,
  # while the assertions above stayed green because they checked that \u003c was
  # present and never that the result still PARSED.
  #
  # So the block the params reach is asserted to be free of entities AND to parse.
  # Both halves matter: the first catches the double-escape, the second catches
  # anything else that would make it invalid JavaScript.
  test "the reflected script block is still JavaScript, not escaped markup" do
    sign_in
    get new_job_path(input_path: PAYLOAD, preview_url: "https://x.invalid/"),
                    headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    # THE RAW BODY, deliberately. Nokogiri DECODES entities when it hands back a
    # script element's text, so `css("script").text` reports a clean `"` for a
    # served `&quot;` -- a first version of this test asserted on exactly that and
    # PASSED with the bug restored. The bug is in the BYTES, so the bytes are what
    # is asserted on: entities are never decoded inside a real <script>, which is
    # why their presence there means the block is not JavaScript.
    raw = response.body
    at = raw.index("var carried = {")
    refute_nil at, "the block that carries the params must be on the page"
    open_tag = raw.rindex("<script>", at)
    close_tag = raw.index("</script>", at)
    refute_nil open_tag
    refute_nil close_tag, "the block must still close, or nothing after it is served"
    block = raw[(open_tag + "<script>".length)...close_tag]

    %w[&quot; &amp; &lt; &gt; &#39;].each do |entity|
      refute_includes block, entity,
        "#{entity} inside a <script> is never decoded, so the block would not be JavaScript"
    end
    assert_includes block, "json_escape",
      "the carried values are still the json_escape'd ones"

    # The strongest available check: hand the SERVED bytes to a real JS parser. A
    # brace or a quote out of place is what a regex would miss.
    require "open3"
    _out, status = Open3.capture2e("node", "--check", "-") { |stdin| stdin.write(block) }
    assert status.success?, "the served block must parse as JavaScript"
  end

  # The html_safe rule, stated precisely. What is FORBIDDEN is marking a RAW JSON
  # string safe — `.to_json.html_safe` hands the browser a value carrying
  # "</script>" with nothing having escaped it. What is REQUIRED is the opposite
  # pairing: wherever a reflected JSON value is marked html_safe, it is a
  # json_escape result, which has already rendered <, > and & as \u003c, \u003e and
  # \u0026. The bare `<%= json_escape(...) %>` form this replaces is the third
  # case — safe as escaping and broken as JavaScript.
  test "a reflected JSON value is escaped, and marked safe only once it has been" do
    %w[jobs/new.html.erb composites/show.html.erb].each do |view|
      source = Rails.root.join("app/views", view).read(encoding: "UTF-8")
      refute_match(/\.to_json\.html_safe/, source,
        "#{view} must not mark a RAW JSON string html_safe")
      source.scan(/<%=([^%]*)%>/) do |(tag)|
        next unless tag.include?(".html_safe")
        next unless tag.include?("json_escape").nil? == false || tag.match?(/to_json|layers_json/)
        assert_includes tag, "json_escape",
          "#{view}: a reflected JSON value marked html_safe must be json_escape'd first (#{tag.strip})"
      end
    end
  end
end
