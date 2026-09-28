require "test_helper"

# The scrapbook sidebar (layout) and the favourite buttons (job show) are the
# two surfaces the feature exposes. The sidebar lives on every authed page; the
# favourite buttons sit on the source/invert tiles and on each candidate and
# finished-proof row.
class ScrapbookUiTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def sign_in
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  setup do
    @original_password = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
  end

  teardown do
    ENV["CHOPSHOP_PASSWORD"] = @original_password
  end

  test "the sidebar and toggle render on authenticated pages, not on the login page" do
    get jobs_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect, "jobs require login first"

    sign_in
    get jobs_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_includes response.body, 'id="scrapbookSidebar"'
    assert_includes response.body, 'id="scrapbookToggle"'
  end

  test "the job show page carries favourite buttons for source, invert and candidates" do
    sign_in
    job = Job.create!(name: "favs", state: "done", source_kind: "raster",
                      input_path: "/data/x.png", stem: "favs", spec: {}, runner: "mock",
                      comparison: { "candidates" => [
                        { "file" => "candidate_01.svg", "sweep" => { "preset" => "bw" },
                          "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" },
                          "hard" => 0, "advisory" => 0, "fidelity" => {}, "passed" => true }
                      ] })
    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    html = response.body
    assert_includes html, 'data-scrap-name="source.png"'
    assert_includes html, 'data-scrap-name="source.inverse.png"'
    assert_includes html, 'data-scrap-name="candidate_01.svg"'
  end
end
