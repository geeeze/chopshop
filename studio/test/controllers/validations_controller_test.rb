require "test_helper"

# The row is created as "pending" and only THEN dispatched to the runner, so any
# failure in between used to leave it queued forever — a phantom back-half run
# the operator never started and that could never execute. That is not
# hypothetical: a stray ArgumentError (not a RunnerClient::RunnerError, so it
# sailed past the only rescue) stranded five such rows, four of them the
# operator's own retries after each Proof click 500'd.
class ValidationsControllerTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def sign_in
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def done_job_with_candidate
    job = Job.create!(name: "regression", state: "done", source_kind: "svg",
                      input_path: "/data/x.svg", stem: "regression", spec: {}, runner: "mock")
    [job, job.candidates.create!(file: "candidate_01.svg")]
  end

  # Minitest 6 dropped minitest/mock (no Object#stub), so swap the singleton
  # method out and restore it by hand.
  def with_create_validation(replacement)
    original = RunnerClient.method(:create_validation)
    RunnerClient.define_singleton_method(:create_validation, replacement)
    yield
  ensure
    RunnerClient.define_singleton_method(:create_validation, original)
  end

  test "a non-runner failure leaves the validation terminal, not stranded pending" do
    sign_in
    job, candidate = done_job_with_candidate
    before = Validation.count

    boom = ->(*) { raise ArgumentError, "wrong number of arguments (given 1, expected 2)" }
    with_create_validation(boom) do
      # It still surfaces for the logs/500 rather than being swallowed ...
      assert_raises(ArgumentError) do
        post validations_path, params: { job_id: job.id, candidate_file: candidate.file },
                               headers: { "User-Agent" => MODERN_UA }
      end
    end

    # ... but the row it created is left in a terminal state.
    assert_equal before + 1, Validation.count, "the attempt should still be recorded"
    validation = Validation.order(:id).last
    assert_equal "error", validation.state,
                 "a failed dispatch must not leave the row queued forever"
    assert_match(/ArgumentError/, validation.error.to_s)
    refute_nil validation.finished_at, "a terminal row should carry finished_at"
    assert_nil validation.runner_validation_id, "the run was never dispatched"
  end

  test "a runner rejection is reported to the operator and the row is terminal" do
    sign_in
    job, candidate = done_job_with_candidate

    reject = ->(*) { raise RunnerClient::RunnerError, "job not ready" }
    with_create_validation(reject) do
      post validations_path, params: { job_id: job.id, candidate_file: candidate.file },
                             headers: { "User-Agent" => MODERN_UA }
    end

    assert_response :redirect
    validation = Validation.order(:id).last
    assert_equal "error", validation.state
    assert_equal "job not ready", validation.error
    refute_nil validation.finished_at
  end

  test "no queued validation is left behind after either failure mode" do
    sign_in
    job, candidate = done_job_with_candidate

    with_create_validation(->(*) { raise "unexpected" }) do
      begin
        post validations_path, params: { job_id: job.id, candidate_file: candidate.file },
                               headers: { "User-Agent" => MODERN_UA }
      rescue StandardError
        nil
      end
    end

    assert_equal 0, Validation.where(state: %w[pending running]).count,
                 "the queue must be empty after a failed Proof"
  end
end
