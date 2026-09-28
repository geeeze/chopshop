class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a transient failure, or discard
  # poisoned ones, with ActiveJob::Retry. Unused for now: RunJob catches its own
  # failures and records them on the studio Job so the operator sees the reason,
  # rather than leaving the queue to retry a call that will fail the same way.
end
