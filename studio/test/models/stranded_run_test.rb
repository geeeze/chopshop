require "test_helper"

# A run that says `running` with nothing behind it can never settle, and nothing
# in the stack can move it. That is issue #19, and it was MEASURED rather than
# theorised: a live row sat `running` from 07:57:23 with `runner_job_id` NULL and
# the runner answering `GET /jobs/183` -> 404 for ~11 hours, while the job list
# showed a run in progress and offered nothing that would notice. The only remedy
# was the operator's own Cancel, by hand.
#
# The shape of the fault, so the tests below are not testing a paraphrase of it:
#
#   * `RunJob#perform` sets `state: "running"` the moment the worker picks the job
#     up (run_job.rb:51) -- that is a claim the worker STARTED, not that anything
#     is running;
#   * `runner_job_id` is written only LATER, when a pipeline/flux step dispatches
#     to a runner (:789, :1025);
#   * between the two is every window in which a restart, a kill or an
#     interrupted demo strands the row;
#   * and afterwards `sync_from_runner!` returns immediately
#     (`return unless runner_job_id`), so the pages have no poll, there is no
#     timeout, and the orphan sweep is keyed by upload stem rather than by state.
#
# So this file pins three things, and the third is the one that matters most:
# the DETECTION is correct, the REAP is durable and names its reason, and the
# condition is VISIBLE before the reaper's threshold elapses -- because a reaper
# alone still leaves the operator looking at "running" for the first fifteen
# minutes, which is the same over-claim in a shorter window.
class StrandedRunTest < ActiveSupport::TestCase
  setup do
    Current.user_handle = "tester"
    @owner = User.find_or_create_by!(handle: "tester") { |u| u.password = SecureRandom.hex(8) }
  end

  teardown { Current.user_handle = nil }

  def stranded_job(attrs = {})
    Job.create!({ owner: "tester", name: "demo-cap-hold-flux", state: "running",
                  started_at: 11.hours.ago, runner_job_id: nil,
                  input_path: "source.png", runner: "mock" }.merge(attrs))
  end

  # --- detection ------------------------------------------------------------

  test "a running row with no runner job past the threshold is stranded" do
    job = stranded_job
    assert job.stranded?,
           "11 hours of `running` with nothing at the runner is the measured case, " \
           "and it must be detected rather than displayed as work in progress"
    assert_nil job.runner_job_id, "the fixture has to be genuinely stranded"
  end

  test "a running row WITH a runner job is not stranded, however long it has been running" do
    job = stranded_job(runner_job_id: "runner-abc")
    refute job.stranded?,
           "a long trace is a long trace, not a dead one -- reaping this would kill " \
           "real work, which is the worse bug"
  end

  test "a queued or pending row with no runner job is NOT stranded" do
    # The distinction that keeps the reaper from being a blunt instrument: a
    # `queued` row has not been picked up yet, which is exactly what queued
    # means. Only `running` is a claim the row cannot back up.
    %w[queued pending].each do |state|
      job = stranded_job(state: state)
      refute job.stranded?, "a #{state} row with no runner job is waiting, not stranded"
    end
  end

  test "a row that has not been running long enough is not yet stranded" do
    job = stranded_job(started_at: 2.minutes.ago)
    refute job.stranded?,
           "`running` with no runner id is NORMAL for the seconds between marking " \
           "and dispatching; reaping inside that window would fail every job"
  end

  test "the threshold is the queue's own order of magnitude, and it is named" do
    assert_equal 15.minutes, Job::STUCK_RUNNING_AFTER,
                 "the window has to be comfortably longer than a dispatch takes and " \
                 "shorter than the ~11 hours a stranded row survived unnoticed"
    # And it is a constant rather than a literal at the call site, so the reason
    # written into the row and the test that pins it cannot drift apart.
    assert_match(/running for/, Job.stranded_reason_for(stranded_job),
                 "the reason NAMES how long, so the operator can see it is not fresh")
  end

  test "a sequenced job whose step already dispatched is not stranded on the chain's own id" do
    # `runner_job_id` is whichever step dispatched LAST, so a chain between steps
    # can have the column blank while a real runner job exists. Treating that as
    # stranded would reap a healthy chain mid-run -- the same class of mistake as
    # `sync_from_runner!` adopting a step's verdict, in the opposite direction.
    job = stranded_job(state: "running", started_at: 11.hours.ago)
    job.update_columns(steps_state: { "current" => 2,
                                         "steps" => [{ "kind" => "trace",
                                                       "runner_job_id" => "runner-7" }] })
    refute job.reload.stranded?,
           "a step's runner job IS a runner job; the chain is mid-flight, not dead"
  end

  test "stranded_reason is nil for a healthy row, so it cannot be written by accident" do
    assert_nil stranded_job(runner_job_id: "r1").stranded_reason
    assert_nil stranded_job(state: "done").stranded_reason
  end

  # --- the reaper -----------------------------------------------------------

  test "reaping settles a stranded row as error and NAMES the reason" do
    job = stranded_job
    reaped = Job.reap_stranded!

    assert_equal [job.id], reaped, "the reaper returns what it settled, so a caller can log it"
    job.reload
    assert_equal "error", job.state,
                 "the row must end in a state that means DEAD, not one that means " \
                 "'in progress' forever"
    assert job.finished_at.present?, "a settled row is finished, and says when"
    assert_match(/no runner job was ever created/, job.error,
                 "the reason is the operator's only clue; 'error' alone is the same " \
                 "silence with a different word")
    assert_match(/nothing at the runner/, job.error)
    refute job.in_flight?, "and it must leave the in-flight set, or the pages keep polling it"
  end

  test "the reaper leaves a healthy long run completely alone" do
    healthy = stranded_job(runner_job_id: "runner-abc")
    queued = stranded_job(state: "queued", runner_job_id: nil)
    fresh = stranded_job(started_at: 1.minute.ago)

    assert_empty Job.reap_stranded!, "nothing here is stranded, so nothing may be touched"

    [healthy, queued, fresh].each do |job|
      job.reload
      assert_equal job.state == "queued" ? "queued" : "running", job.state
      assert_nil job.error, "a live run must not acquire a death certificate"
      assert_nil job.finished_at
    end
  end

  test "the reaper is idempotent, and a reaped row is not reaped again" do
    stranded_job
    assert_equal 1, Job.reap_stranded!.size
    assert_empty Job.reap_stranded!,
                 "a second pass must find nothing: the row is `error` now, and a " \
                 "reaper that re-reaps is a reaper that can resurrect a settled row"
  end

  test "the reaper query agrees with stranded? on an unstamped fresh row" do
    # A REAL regression this file caught in its own first draft, kept because the
    # bug class is the one this issue is about: two expressions of one rule that
    # quietly disagree.
    #
    # The worker marks `running` and stamps `started_at` in the same `update!`, so
    # a NULL `started_at` on a `running` row is rare -- but the jobs-grid test
    # builds exactly that row (it only wants a job in the `running` state), and
    # the first draft of the SQL read `started_at` alone where `stranded?` read
    # `started_at || created_at`. So a job created a moment ago was reaped
    # instantly and its cancel button vanished: the reaper killed the one job it
    # was supposed to be the safety net for.
    fresh = stranded_job(started_at: nil, created_at: Time.current)
    refute fresh.stranded?, "stranded? says a fresh row is not stranded"
    assert_empty Job.reap_stranded!,
                 "and the reaper must agree -- a fresh running row is the NORMAL " \
                 "state, and reaping it is the failure this issue is about"
    assert_equal "running", fresh.reload.state
    assert_nil fresh.finished_at

    # And the disagreement must not be reintroduced silently: the same rows are
    # put in front of both expressions, so the SQL and the predicate cannot drift
    # apart again without this failing.
    old = stranded_job(started_at: 11.hours.ago)
    young = stranded_job(started_at: 30.seconds.ago)
    queued = stranded_job(state: "queued", started_at: 11.hours.ago)

    reaped = Job.reap_stranded!
    assert_equal [old.id], reaped,
                 "the reaper must select exactly the rows stranded? calls stranded"
    assert_equal "error", old.reload.state
    assert_equal "running", young.reload.state
    assert_equal "queued", queued.reload.state
  end

  test "the reaper writes through update_columns, so a job that would fail validation still settles" do
    # A row whose name is blank is exactly the shape that makes `update!` raise,
    # and a failure nobody can write is a failure nobody sees -- which is the
    # defect this whole issue is about, one level down.
    job = stranded_job
    # Bypass the validation the reaper must survive: a row whose name is blank
    # cannot be written with `update!`, which is the whole point of the test.
    job.update_columns(name: "")
    assert_nothing_raised { Job.reap_stranded! }
    assert_equal "error", job.reload.state,
                 "the reaper must not be defeatable by the row it is rescuing"
  end

  test "the reaper reaches a stranded row belonging to an operator who is NOT looking" do
    # Unscoped ON PURPOSE, and this is the test for that decision. The row is
    # invisible by definition -- nothing polls it -- so a sweep scoped to whoever
    # is browsing would only find it when the right person happened to be on the
    # page. The isolation this must not break is the PAGE's, not the reaper's:
    # what the reaper must never do is hide a row from its owner, and it does
    # not, because it only ever WRITES a state and a reason to the row itself.
    other = User.find_or_create_by!(handle: "other") { |u| u.password = SecureRandom.hex(8) }
    theirs = Job.create!(owner: "other", name: "theirs", state: "running",
                         started_at: 11.hours.ago, runner_job_id: nil,
                         input_path: "source.png", runner: "mock")
    mine = stranded_job

    reaped = Job.reap_stranded!
    assert_includes reaped, theirs.id, "an unattended stranded row is exactly the one that must be reaped"
    assert_includes reaped, mine.id
    assert_equal "error", theirs.reload.state
    assert_equal "other", theirs.owner, "and the row is still the same operator's row"
  end

  # --- and the operator can SEE it ------------------------------------------

  test "the job list flags a stranded run instead of showing a plain running pill" do
    # Before the threshold elapses there is nothing to reap, and the page must
    # still not read as healthy -- otherwise the fix is a fifteen-minute window
    # on the same over-claim.
    job = stranded_job(started_at: 20.minutes.ago)
    html = Nokogiri::HTML(render_row(job))
    pill = html.at_css("td.col-center .status-pill")

    refute_nil pill, "the row keeps its state column; the fix does not remove the claim"
    assert_match(/stuck/, pill.text, "a stranded run is labelled as stuck, not as plain `running`")
    assert_match(/no runner job was ever created/, pill["title"].to_s,
                 "and the reason is on the element itself, so it is a hover away " \
                 "rather than a row somebody has to open")
  end

  test "a healthy long run still reads as plain running" do
    html = Nokogiri::HTML(render_row(stranded_job(runner_job_id: "runner-abc")))
    pill = html.at_css("td.col-center .status-pill")
    assert_equal "running", pill.text.strip,
                 "the flag is for stranded rows only -- putting it on a real long run " \
                 "would train the operator to ignore it"
  end

  test "the grid card says the same thing as the list row" do
    # Two templates for one row is the drift this repo's own comment above
    # _row.html.erb warns about, so the same claim is asserted on both.
    job = stranded_job(started_at: 20.minutes.ago)
    assert_match(/stuck/, render_card(job), "the grid card must not be the copy that forgot")
  end

  private

  def render_row(job)
    ApplicationController.render(partial: "jobs/row", locals: { job: job })
  end

  def render_card(job)
    ApplicationController.render(partial: "jobs/card", locals: { job: job })
  end
end
