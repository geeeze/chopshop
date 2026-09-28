require "test_helper"

# The serial queue's contract: a bounded queue (MAX_QUEUE waiting jobs), and a
# queued job that can be cancelled before it runs — where "cancelled" means the
# worker never dispatches it. The one-at-a-time serialisation itself is Solid
# Queue's (config/queue.yml pins a single worker thread on the "runs" queue);
# these tests pin the studio's side of that contract.
class JobQueueTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  setup do
    @original_password = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
  end

  teardown do
    ENV["CHOPSHOP_PASSWORD"] = @original_password
  end

  def sign_in
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  test "RunJob is the single serial gate on the runs queue" do
    assert_equal "runs", RunJob.queue_name
    assert_equal 255, RunJob::MAX_QUEUE
  end

  test "the queue refuses a new job once MAX_QUEUE are waiting" do
    sign_in
    RunJob::MAX_QUEUE.times do |i|
      Job.create!(name: "queued-#{i}", state: "queued", source_kind: "raster",
                  input_path: "/data/x.png", runner: "mock")
    end
    assert_equal RunJob::MAX_QUEUE, Job.where(state: "queued").count

    post jobs_path,
         params: { job: { name: "overflow", source_kind: "raster",
                          runner: "mock", input_path: "/data/y.png",
                          spec: "{}" } },
         headers: { "User-Agent" => MODERN_UA }

    assert_response :unprocessable_entity
    assert_match(/queue is full/, response.body,
      "the operator must be told why the job did not queue")
  end

  test "a queued job is cancelled before it runs and never dispatched" do
    sign_in
    dispatched = []
    original = RunnerClient.method(:create_job)
    RunnerClient.define_singleton_method(:create_job) do |job|
      dispatched << job.id
      { id: "runner-#{job.id}" }
    end
    begin
      post jobs_path,
           params: { job: { name: "cancel-me", source_kind: "raster",
                            runner: "mock", input_path: "/data/z.png",
                            spec: "{}" } },
           headers: { "User-Agent" => MODERN_UA }
      assert_response :redirect
      job = Job.order(:id).last
      assert_equal "queued", job.state, "create queues, it does not dispatch"

      post cancel_job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_equal "cancelled", job.reload.state
      assert_equal "cancelled by operator", job.error

      # If the worker ever reaches it, the cooperative check must no-op it.
      perform_enqueued_jobs
      assert_empty dispatched, "a cancelled job must never be dispatched"
    ensure
      RunnerClient.define_singleton_method(:create_job, original)
    end
  end
end
