require "test_helper"

# The Run Job page's Job name field carries a tooltip, and getting it onto the
# input is not as automatic as it looks: the title is a Ruby string inside ERB
# and the hint is raw HTML, so a unicode escape works in one and renders
# literally in the other.
class RunJobNameTooltipTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  CROSSED = "\u{1F91E}".freeze

  def doc
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    # /jobs/new is behind the password gate like every other page.
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get new_job_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  test "the tooltip is the emoji and nothing else" do
    input = doc.at_css("#job_name")
    refute_nil input, "the name field"
    assert_equal CROSSED, input["title"].to_s,
      "just the crossed fingers, got #{input['title'].inspect} -- a sentence " \
      "here reads as nagging, and the hint underneath already says what the " \
      "stem is for"
  end

  test "the emoji does not appear anywhere else on the page" do
    d = doc
    assert_equal 1, d.to_html.scan(CROSSED).size,
      "only the tooltip carries it, and it is not repeated under the field"
  end

  test "the emoji is the real character, not an escape left in the markup" do
    input = doc.at_css("#job_name")
    refute_includes input["title"].to_s, "\\u{",
      "a \\u{1F91E} escape survives Ruby's string parsing, so it can only leak " \
      "into the raw-HTML hint -- check both"
    assert_equal CROSSED, input["title"][CROSSED]
    assert doc.to_html.include?(CROSSED), "the hint carries it too"
  end

  test "the hint below the field is the pre-existing line, with no emoji" do
    d = doc
    field = d.at_css(".field #job_name").ancestors("div").first
    refute_nil field
    hint = field.at_css(".hint")
    refute_nil hint
    assert_equal "Used as the stem for candidates and reports.", hint.text.strip
    refute_includes hint.text, CROSSED, "the crossed fingers belong in the tooltip only"
  end

  test "the label is still associated with the input" do
    d = doc
    label = d.at_css("label[for='job_name']")
    refute_nil label, "f.label :name gives a for= the input's id"
    assert_includes label.text, "name"
  end

  test "the field is unchanged otherwise" do
    input = doc.at_css("#job_name")
    assert input["required"].present?, "still required"
    assert_equal "job[name]", input["name"]
    assert_includes input["placeholder"], "got-a-jobby"
  end
end
