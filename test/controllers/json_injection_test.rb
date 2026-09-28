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

  test "no view still html_safe's a JSON string into a script block" do
    %w[jobs/new.html.erb composites/show.html.erb].each do |view|
      source = Rails.root.join("app/views", view).read(encoding: "UTF-8")
      refute_match(/\.to_json\.html_safe|\bjson_escape\(\)\.html_safe/, source,
        "#{view} must not mark a JSON string html_safe")
    end
  end
end
