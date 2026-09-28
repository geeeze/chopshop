require "test_helper"

# Every value field in every form block renders in the mono face -- the same one
# the two hex pickers already used.
#
# `.field input` said `font-family: inherit`, which resolves against the BODY,
# and the body is Inter. So every value field on every form page was sans while
# the RRGGBB box in the colour picker a few inches below it was monospaced: two
# hex codes, on one screen, in two alphabets.
class FormFieldFontTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  setup do
    @css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  HEX_RULE = /\.pal-picker\.hex-pair input\[type="text"\] \{([^}]*)\}/m
  FIELD_RULE = /\.field input, \.field select, \.field textarea \{([^}]*)\}/m

  test "form fields are mono, not inherited" do
    rule = @css[FIELD_RULE, 1]
    refute_nil rule, "the shared form-field rule is gone"
    assert_match(/font-family:\s*var\(--font-mono\)/, rule)
    refute_match(/font-family:\s*inherit/, rule,
      "`inherit` resolves against the body face, which is the whole bug")
  end

  test "the hex pickers still ask for the same face" do
    # The reference the fields are matched TO. NOTE the compound selector: the
    # background_hex row is styled as one control through `.pal-picker.hex-pair`,
    # which must outrank palette-tool.css's later `.pal-picker input[type=text]`.
    rule = @css[HEX_RULE, 1]
    refute_nil rule,
      "the hex-picker rule has moved or changed shape; the fields are matched " \
      "to THIS, and it is the reference rather than a convenience"
    assert_match(/font-family:\s*var\(--font-mono\)/, rule)
  end

  test "both rules name the same family" do
    fam = ->(r) { r[/font-family:\s*([^;]+)/, 1].to_s.strip }
    assert_equal fam.(@css[HEX_RULE, 1]), fam.(@css[FIELD_RULE, 1]),
      "the fields and the hex pickers must name the SAME family, or the two " \
      "RRGGBB boxes on the JSON page are set in different type"
  end

  test "the form pages still render their fields" do
    original = ENV["CHOPSHOP_PASSWORD"]; ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    ENV["CHOPSHOP_PASSWORD"] = original

    { "json" => json_path, "jev" => jev_path, "new" => new_job_path }.each do |name, path|
      get path, headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      fields = Nokogiri::HTML(response.body)
              .css(".field input, .field select, .field textarea")
      assert_operator fields.size, :>, 0, "#{name} has no form fields left"
      # A field carrying `.mono` is not a conflict -- that utility sets
      # var(--font-mono) too, so it agrees with the shared rule. What must not
      # appear is a field carrying a class that sets a DIFFERENT family, which
      # would override the shared rule for that one field alone.
      util = @css[/\.mono \{([^}]*)\}/m, 1]
      assert_match(/font-family:\s*var\(--font-mono\)/, util.to_s,
        ".mono must name the same family as the shared field rule, or a field " \
        "carrying both is set in two fonts at once")
    end
  end
end
