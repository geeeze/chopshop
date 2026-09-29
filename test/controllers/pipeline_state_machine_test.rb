require "test_helper"

# Pins the job lifecycle the contract describes: queued -> running -> done|error,
# and cancel -> cancelled, with a queued (not yet started) job cancellable too.
#
# The studio side is what matters here. With the serialised runner a job can sit
# in "queued" for a while before the worker picks it up; Job::IN_FLIGHT_STATES
# already includes "queued", so the list and show pages keep polling it and the
# operator sees queued rather than a stuck "running".
class PipelineStateMachineTest < ActionDispatch::IntegrationTest
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

  def new_job(state: "queued", runner_job_id: "rj-1")
    Job.create!(name: "lifecycle", state: state, source_kind: "raster",
                input_path: "/data/probe.png", stem: "lifecycle",
                spec: {}, runner: "mock", runner_job_id: runner_job_id)
  end

  # Minitest 6 dropped minitest/mock, so swap singleton methods and restore.
  def with_runner_method(name, replacement)
    original = RunnerClient.method(name)
    RunnerClient.define_singleton_method(name, replacement)
    yield
  ensure
    RunnerClient.define_singleton_method(name, original)
  end

  def reporting(state, error: nil)
    ->(_job) { { state: state, prep_summary: nil, candidate_count: 0,
                 comparison: nil, error: error } }
  end

  test "the model names every state in the contract" do
    %w[queued running done error].each do |state|
      assert_includes Job::STATES, state, "Job::STATES must know #{state}"
    end
  end

  test "queued and running are in flight; done, error and cancelled are not" do
    %w[queued running].each do |state|
      assert new_job(state: state).in_flight?, "#{state} must be in flight"
    end
    %w[done error cancelled].each do |state|
      refute new_job(state: state).in_flight?, "#{state} must be terminal"
    end
  end

  test "sync_from_runner! adopts queued -> running -> done/error" do
    job = new_job(state: "queued")
    %w[running done error].each do |state|
      with_runner_method(:get_job, reporting(state)) { job.sync_from_runner! }
      assert_equal state, job.reload.state, "sync must adopt #{state}"
    end
  end

  # A chain is N steps and ONE record, so `runner_job_id` names whichever step
  # last dispatched to a runner — not the chain. Mirroring that step's state
  # settled the whole chain: measured on production, a 7-step job read done with
  # `finished_at` nil and step 7 still running, because the show page's own
  # sync adopted the trace step's "done" while the blender step rendered.
  test "a step's runner job cannot settle a chain" do
    job = new_job(state: "running")
    job.update_columns(spec: { "steps" => [ { "runner" => "mock",
                                              "svg" => { "print_method" => "screen_print" } } ] })

    with_runner_method(:get_job, reporting("done")) { job.sync_from_runner! }

    assert_equal "running", job.reload.state,
                 "a chain's state is written by the chain, never by one step's runner job"
  end

  test "a queued job is cancellable before the worker ever starts it" do
    job = new_job(state: "queued")
    sign_in

    calls = []
    with_runner_method(:cancel_job, ->(j) { calls << j.id; { state: "cancelled" } }) do
      post cancel_job_path(job), headers: { "User-Agent" => MODERN_UA }
    end

    assert_equal [ job.id ], calls, "cancel must be forwarded to the runner"
    assert_equal "cancelled", job.reload.state
    assert_equal "cancelled by operator", job.error
  end

  test "cancel on a running job settles it cancelled" do
    job = new_job(state: "running")
    sign_in
    with_runner_method(:cancel_job, ->(_j) { { state: "cancelling" } }) do
      post cancel_job_path(job), headers: { "User-Agent" => MODERN_UA }
    end
    assert_equal "cancelled", job.reload.state
  end

  test "cancel on a finished job is a no-op that never calls the runner" do
    job = new_job(state: "done")
    sign_in
    called = false
    with_runner_method(:cancel_job, ->(_j) { called = true; {} }) do
      post cancel_job_path(job), headers: { "User-Agent" => MODERN_UA }
    end
    refute called, "a terminal job must not be sent a cancel"
    assert_equal "done", job.reload.state
  end

  # Create no longer dispatches synchronously: it enqueues a RunJob and the
  # single queue worker performs the dispatch. The create response is still only
  # { id, stem } -- it carries no state -- so the worker sets "running"
  # optimistically, and because "running" is in flight the very next sync
  # corrects it to whatever the runner actually reports ("queued" under the
  # serialised runner).
  test "create queues, the worker dispatches, and the first sync corrects to queued" do
    sign_in
    with_runner_method(:create_job, ->(_job) { { id: "rj-new", stem: "created" } }) do
      perform_enqueued_jobs do
        post jobs_path,
             params: { job: { name: "created", source_kind: "raster",
                              runner: "mock", input_path: "/data/x.png",
                              spec: "{}" } },
             headers: { "User-Agent" => MODERN_UA }
      end
    end

    assert_response :redirect
    job = Job.order(:id).last
    assert_equal "rj-new", job.runner_job_id
    assert_equal "running", job.state, "the worker dispatches and sets running"

    with_runner_method(:get_job, reporting("queued")) { job.sync_from_runner! }
    assert_equal "queued", job.reload.state,
                 "the first sync must be able to move running back to queued"
  end
end
