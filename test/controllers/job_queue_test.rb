require "test_helper"

# The serial queue's contract: a queue bounded PER USER (MAX_QUEUE_PER_USER
# queued jobs for the signed-in handle) behind a global MAX_QUEUE backstop, and
# a queued job that can be cancelled before it runs — where "cancelled" means the
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

  # The owner is passed EXPLICITLY rather than left to Owned's stamp: a request
  # completes with Current reset, so a record built here would otherwise have a
  # blank owner and be invisible to the per-user gate this file exists to pin.
  def queue_a_job_for(owner, name:)
    Job.create!(name: name, state: "queued", source_kind: "raster",
                input_path: "/data/#{name}.png", runner: "mock", owner: owner)
  end

  test "RunJob is the single serial gate on the runs queue, capped per user" do
    assert_equal "runs", RunJob.queue_name
    assert_equal 5, RunJob::MAX_QUEUE_PER_USER,
      "the per-user cap is the primary gate and it is five"
    assert_equal 255, RunJob::MAX_QUEUE,
      "the global cap stays as the backstop behind it, not as the gate"
    assert_operator RunJob::MAX_QUEUE_PER_USER, :<, RunJob::MAX_QUEUE,
      "a per-user cap that is not under the global one would never be the " \
      "binding limit"
  end

  test "a user's queue refuses a sixth waiting job, and says why in their terms" do
    sign_in
    RunJob::MAX_QUEUE_PER_USER.times { |i| queue_a_job_for("test", name: "queued-#{i}") }
    assert_equal RunJob::MAX_QUEUE_PER_USER,
                 Job.unscoped.where(state: "queued", owner: "test").count

    post jobs_path,
         params: { job: { name: "overflow", source_kind: "raster",
                          runner: "mock", input_path: "/data/y.png",
                          spec: "{}" } },
         headers: { "User-Agent" => MODERN_UA }

    assert_response :unprocessable_entity
    assert_match(/queue is full/, response.body,
      "the operator must be told why the job did not queue")
    assert_match(/#{RunJob::MAX_QUEUE_PER_USER} jobs waiting for you/, response.body,
      "and the limit quoted must be the per-user one, not the box's backstop")
  end

  test "one user at their cap does not stop a different user queueing" do
    sign_in
    RunJob::MAX_QUEUE_PER_USER.times { |i| queue_a_job_for("test", name: "mine-#{i}") }

    User.create!(handle: "other", password: "other-password")
    post login_path, params: { password: "other-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect

    post jobs_path,
         params: { job: { name: "theirs", source_kind: "raster",
                          runner: "mock", input_path: "/data/y.png",
                          spec: "{}" } },
         headers: { "User-Agent" => MODERN_UA }

    assert_response :redirect,
      "the five jobs waiting belong to the first user; a second user's queue is empty"
    job = Job.unscoped.order(:id).last
    assert_equal "other", job.owner
    assert_equal "queued", job.state
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
