require "test_helper"

# A missing job or composite is not the bare themed 404: it is the id-specific
# state (kb R9 shape, issue #4) -- the id is named, the state is said out loud,
# and a search is built from the id. Both controllers render the same view.
class MissingRecordTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  MISSING_ID = 999_999

  def sign_in
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  test "a missing job renders the id and a search built from it, not the bare 404" do
    sign_in
    get job_path(MISSING_ID), headers: { "User-Agent" => MODERN_UA }
    assert_response :not_found
    body = response.body
    assert_includes body, MISSING_ID.to_s, "the id is named"
    assert_includes body, "no document for it here yet", "the state is said out loud"
    assert_includes body, "q=#{MISSING_ID}", "a search is built from the id"
    assert_includes body, "Chopshop", "the themed chrome is kept"
  end

  test "a missing composite renders the id and a search built from it" do
    sign_in
    get composite_path(id: MISSING_ID), headers: { "User-Agent" => MODERN_UA }
    assert_response :not_found
    body = response.body
    assert_includes body, MISSING_ID.to_s, "the id is named"
    assert_includes body, "q=#{MISSING_ID}", "a search is built from the id"
    assert_includes body, "Chopshop", "the themed chrome is kept"
  end

  test "a JSON request for a missing record still gets a 404 in its own shape" do
    sign_in
    get recipe_composite_path(MISSING_ID), headers: { "User-Agent" => MODERN_UA }
    assert_response :not_found
    assert_equal "application/json", response.media_type
    assert_match(/not found/, JSON.parse(response.body)["error"])
  end
end
