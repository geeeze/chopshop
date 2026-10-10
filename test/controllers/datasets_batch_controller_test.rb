require "test_helper"

# The batch driver controller action (issue #46): POST /datasets/batch files
# N jobs and returns the manifest JSON. No network; the library is built
# in-process and the flux runner is stubbed.
class DatasetsBatchControllerTest < ActionDispatch::IntegrationTest
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
    Job.delete_all
    @project = Project.create!(name: "batch-controller-test", is_test: false)
    5.times do |i|
      PromptSource.create!(dataset: "diffusiondb", topic: "art",
                           phrase_root: "r#{i}", prompt: "art prompt #{i}", x: i, y: i)
    end
    # The runner registry must contain a flux label for the job to validate,
    # and the network must never be reached.
    @saved_env = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| @saved_env[k] = ENV.delete(k) }
    ENV["CHOPSHOP_RUNNER_FLUX_URL"] = "http://generator.invalid:8795"
    ENV["CHOPSHOP_RUNNER_FLUX_KIND"] = "flux"
    Job.reset_runners_cache!
  end

  teardown do
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
    @saved_env.each { |k, v| ENV[k] = v }
    Job.reset_runners_cache!
  end

  test "POST /datasets/batch files N jobs and returns the manifest" do
    login!
    assert_difference "Job.count", 3 do
      post batch_datasets_path,
           params: { count: 3, project_id: @project.id, seed: "ctrl-seed" },
           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 3, body["count"]
    assert_equal 3, body["jobs"].size
    assert body["jobs"].all? { |j| j["prompt"].present? && j["job_id"].present? }
  end

  test "the batch id is deterministic for the same seed" do
    login!
    post batch_datasets_path,
         params: { count: 2, project_id: @project.id, seed: "same-seed" },
         headers: { "User-Agent" => MODERN_UA }
    first_id = JSON.parse(response.body)["batch_id"]

    post batch_datasets_path,
         params: { count: 2, project_id: @project.id, seed: "same-seed" },
         headers: { "User-Agent" => MODERN_UA }
    second_id = JSON.parse(response.body)["batch_id"]

    assert_equal first_id, second_id
  end

  test "TOPIC filter is honored" do
    PromptSource.create!(dataset: "diffusiondb", topic: "portrait",
                         phrase_root: "p", prompt: "a portrait", x: 9, y: 9)
    login!
    post batch_datasets_path,
         params: { count: 5, topic: "portrait", project_id: @project.id },
         headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    body = JSON.parse(response.body)
    assert(body["jobs"].all? { |j| j["topic"] == "portrait" })
  end

  test "a missing project_id is refused" do
    login!
    assert_no_difference "Job.count" do
      post batch_datasets_path,
           params: { count: 3 },
           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "project_id"
  end

  test "an unknown view is a 404" do
    login!
    post batch_datasets_path,
         params: { count: 2, view: "no-such-view", project_id: @project.id },
         headers: { "User-Agent" => MODERN_UA }
    assert_response :not_found
    assert_includes JSON.parse(response.body)["error"], "no view named"
  end

  test "an unauthenticated request is redirected to login" do
    post batch_datasets_path,
         params: { count: 2, project_id: @project.id },
         headers: { "User-Agent" => MODERN_UA }
    assert_redirected_to login_path
  end
end
