# Refuse to boot on a recurring task that names a queue no worker polls.
#
# The failure this prevents is the total-silence one (studio #3). A recurring
# task without a `queue:` line goes to Solid Queue's `solid_queue_recurring`
# queue, which nothing in this deployment works -- the whole dispatch path
# completes and looks healthy, and the job then sits `ready` forever. Measured
# here before the guard existed: 30 such jobs, 0 failed, and the hourly
# finished-job pruning had never once run.
#
# EVERY environment section in config/recurring.yml is checked, not just the
# running one, so a task that would be dead in production is a boot failure
# here rather than a chart that quietly stops updating next deploy. That is
# deliberate: the alternative is discovering it from silence.
#
# The guard only says something about QUEUES. Schedules, commands and cadence
# are not its business, and the queue a task lands on is the one property whose
# failure mode is invisible from every surface the studio offers.
require_relative "../../app/lib/recurring_queue_guard"

# The raise lives in the guard rather than here so it can be exercised against a
# deliberately broken config tree in the test suite. An initializer is the ONE
# place a Rails app cannot be tested, and the failure it prevents is invisible
# from every other surface -- so the boot check is the thing that has to be
# provable, and `RecurringQueueGuard.verify!(root:)` is what the initializer runs
# and what the tests run.
RecurringQueueGuard.verify!(root: Rails.root)
