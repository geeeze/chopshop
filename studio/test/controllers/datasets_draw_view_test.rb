require "test_helper"

# datasets#draw from a curated view (issue #48): the ?view=NAME named filter.
# The view's rule and manifest live in DatasetView; a draw reads the same
# deterministic slice. No network.
class DatasetsDrawViewTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def login!
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  setup do
    PromptSource.delete_all
    DatasetView.delete_all
    3.times do |i|
      PromptSource.create!(dataset: "diffusiondb", topic: "portrait",
                           phrase_root: "r#{i}", prompt: "portrait #{i}", x: i, y: i)
    end
    @view = DatasetView.create!(name: "portraits", rule: { "topic" => "portrait" })
    @view.build!
  end

  test "draw from a view returns prompts from that view's slice" do
    login!
    get draw_datasets_path(view: "portraits", count: 2),
        headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body["count"]
    assert(body["prompts"].all? { |p| p["topic"] == "portrait" })
  end

  test "draw from an unknown view is a 404, not a silent fallback" do
    login!
    get draw_datasets_path(view: "no-such-view"),
        headers: { "User-Agent" => MODERN_UA }
    assert_response :not_found
    assert_includes JSON.parse(response.body)["error"], "no view named"
  end

  test "draw without a view still works as the plain filtered draw" do
    login!
    get draw_datasets_path(topic: "portrait", count: 1),
        headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_equal 1, JSON.parse(response.body)["count"]
  end
end
