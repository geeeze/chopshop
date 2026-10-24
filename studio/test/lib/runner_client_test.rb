require "test_helper"

class RunnerClientTest < ActiveSupport::TestCase
  test "connection failures are exposed as runner errors" do
    error = assert_raises(RunnerClient::RunnerError) do
      RunnerClient.post("http://127.0.0.1:1/jobs", {})
    end

    assert_match(/connection refused/i, error.message)
  end
end
