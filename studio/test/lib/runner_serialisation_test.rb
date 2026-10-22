require "test_helper"

# Structural pins for the serialised mock runner. The behaviour is covered by
# mock-runner/test_runner_serialised.py (real HTTP, single worker); these read
# the source so the deployment-critical properties cannot be edited away without
# a failing test in the main suite.
#
# mock-runner/runner_serialised.py is the file the operator applies over the
# deployed ~/chopshop-mock-runner/runner.py; runner_deployed.py is the current
# deployed copy kept for reference.
class RunnerSerialisationTest < ActiveSupport::TestCase
  def runner_source
    path = Rails.root.join("mock-runner", "runner_serialised.py")
    assert_path_exists path, "the serialised runner must exist to be deployed"
    path.read
  end

  test "the runner still binds loopback by default" do
    source = runner_source
    assert_match(/MOCK_BIND", "127\.0\.0\.1"/, source,
                 "the default bind must stay loopback")
    assert_match(/ThreadingHTTPServer\(\(host, PORT\)/, source)
  end

  test "front jobs go through one worker queue, not a thread per job" do
    source = runner_source
    assert_match(/JOB_QUEUE.*queue\.Queue/, source)
    assert_match(/def worker_loop/, source)
    assert_match(/JOB_QUEUE\.put\(job_id\)/, source,
                 "POST /jobs must enqueue rather than spawn")
    refute_match(/Thread\(target=_guarded, args=\(run_front, job\)\)/, source,
                 "the per-job front thread is what serialisation removes")
  end

  test "exactly one worker thread drains the queue" do
    source = runner_source
    starts = source.scan(/Thread\(target=worker_loop/)
    assert_equal 1, starts.size, "one worker means one job at a time"
  end

  test "back-half validations stay threaded, as documented" do
    source = runner_source
    assert_match(/Thread\(target=_guarded, args=\(run_back, val\)/, source,
                 "validations were deliberately left threaded")
  end
end
