# The per-request user context. Set from the session in ApplicationController
# (#set_current) and read by the owned models' default_scope, so every query is
# already scoped to the signed-in user before any controller code runs.
#
# Blank in the Solid Queue worker thread (no request, no session), which is what
# lets RunJob load any user's job by id without an owner filter — the worker
# must be able to advance any user's queued job.
class Current < ActiveSupport::CurrentAttributes
  attribute :user_handle
end
