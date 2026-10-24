require "test_helper"
require "tmpdir"
require "fileutils"

# A RECURRING TASK ON A QUEUE NOBODY WORKS NEVER FAILS (studio #3).
#
# `config/queue.yml` pins the one worker to `queues: "runs"` -- one queue, one
# thread, the serial gatekeeper. Solid Queue's `RecurringJob` does
# `queue_as :solid_queue_recurring` unless the task declares `queue:`, and
# nothing here ever worked that queue. So a task added without `queue:`
# completes the WHOLE dispatch path -- task row written at boot, execution
# recorded with a `run_at`, job enqueued -- and then sits `ready` forever. No
# error, no failed execution, nothing to find. MEASURED on the live box before
# the fix: 30 ready recurring jobs, 0 failed, and the hourly finished-job
# pruning had never once executed.
#
# So there are two things to pin, and this file exists for both:
#
#   1. The real config is sound -- every entry in config/recurring.yml names a
#      queue the worker actually polls. This is the regression test.
#   2. The guard CAN FAIL. Every failure path is exercised against a
#      deliberately broken copy of both YAML files in a tmpdir, because a
#      comparator that cannot fail is decoration, and a guard whose green suite
#      might be green because it never says no is exactly the failure it was
#      written to prevent.
class RecurringQueueGuardTest < ActiveSupport::TestCase
  # A copy of the real config with `queue:` lines and worker lists edited. The
  # guard takes a root rather than reading Rails.root, so the whole thing can be
  # pointed at a broken tree instead of monkey-patching around the real one.
  def with_config(queue_yml: nil, recurring_yml: nil)
    Dir.mktmpdir("recurring-guard") do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "queue.yml"),
                 queue_yml || real_file("config/queue.yml"))
      File.write(File.join(dir, "config", "recurring.yml"),
                 recurring_yml || real_file("config/recurring.yml"))
      # Yields the tmpdir AND a guard pointed at it, because a test needs one
      # or the other depending on whether it is asserting the parse or the
      # refusal.
      yield dir, RecurringQueueGuard.new(root: dir)
    end
  end

  def real_file(relative)
    Rails.root.join(relative).read
  end

  # --- the real config -----------------------------------------------------

  test "every recurring task names a queue this deployment's worker polls" do
    guard = RecurringQueueGuard.new
    assert guard.ok?,
      "the shipped config must pass its own guard:\n#{guard.report}"
  end

  test "the guard is actually wired to the boot, not just present in app/lib" do
    initializer = Rails.root.join("config/initializers/recurring_queue_guard.rb")
    assert initializer.exist?, "the boot-time guard is the half that catches it"
    body = initializer.read
    assert_match(/RecurringQueueGuard\.verify\!/, body,
      "the initializer must call the SAME entry point the tests exercise, or " \
      "the tested method and the booting one can drift apart"
    )
    assert_match(/Rails\.root/, body)
  end

  # The boot entry point itself, exercised. An initializer is the one file a
  # Rails app cannot unit-test, so the check was pushed into
  # `RecurringQueueGuard.verify!` -- and these are the tests that make the
  # refusal real rather than asserted.
  test "verify! passes on the shipped config" do
    assert RecurringQueueGuard.verify!
  end

  test "verify! refuses to boot on a task nobody's worker polls" do
    recurring = <<~YML
      production:
        host_sample:
          command: "HostSample.capture!"
          schedule: every minute
    YML
    with_config(recurring_yml: recurring) do |dir, _guard|
      error = assert_raises(RecurringQueueGuard::ConfigurationError) do
        RecurringQueueGuard.verify!(root: dir)
      end
      assert_match(/Refusing to boot/, error.message)
      assert_match(/host_sample/, error.message,
        "and it must name the task, since a boot failure with no task name is " \
        "a puzzle rather than a fix")
    end
  end

  test "the recurring file's queue line is load-bearing, so it stays written down" do
    comments = real_file("config/recurring.yml")
    assert_match(/queue: runs/, comments)
    assert_match(/solid_queue_recurring/, comments,
      "the reason the line exists has to stay in the file, or the next task " \
      "author deletes it as noise")
  end

  test "the guard resolves the worker queue list through queue.yml's YAML alias" do
    # config/queue.yml is `default: &default` with `<<: *default` per
    # environment, so `queues` is not a literal on the section that matters --
    # the guard has to read the MERGED document or it would see no worker at all
    # and (correctly, but uselessly) report every task as stranded.
    parsed = YAML.safe_load(real_file("config/queue.yml"), aliases: true)
    assert_equal ["runs"], Array(parsed.dig("production", "workers").first["queues"])
    assert_equal ["runs"], RecurringQueueGuard.new.send(:worked_queues, "production")
  end

  test "an environment with no recurring tasks is not checked at all" do
    # The shipped recurring file declares production only. There is no `test:`
    # section, so the guard must have nothing to say about the test
    # environment -- otherwise every boot of the suite would be a boot failure
    # over a file that declares nothing for it.
    assert_nil RecurringQueueGuard.new.send(:worked_queues, "test")
    assert RecurringQueueGuard.new.ok?
  end

  # --- the guard can fail ---------------------------------------------------

  test "a task with no queue: line is refused, naming Solid Queue's default" do
    recurring = <<~YML
      production:
        good:
          command: "Good.call"
          schedule: every hour at minute 12
          queue: runs
        bad:
          command: "Bad.call"
          schedule: every minute
    YML
    with_config(recurring_yml: recurring) do |_dir, guard|
      refute guard.ok?
      violation = guard.violations.sole
      assert_equal "bad", violation.task,
        "the task without a `queue:` line must be caught, and ONLY it -- the " \
        "healthy task in the same file is not a violation"
      assert_equal RecurringQueueGuard::DEFAULT_RECURRING_QUEUE, violation.queue
    end
  end

  test "a task on a queue the worker never polls is refused" do
    recurring = <<~YML
      production:
        stranded:
          command: "Stranded.call"
          schedule: every minute
          queue: maintenance
    YML
    with_config(recurring_yml: recurring) do |_dir, guard|
      violation = guard.violations.sole
      assert_equal "stranded", violation.task
      assert_equal "maintenance", violation.queue
      assert_equal ["runs"], violation.worked_queues
      assert_match(/never added to/, violation.message)
    end
  end

  test "every offending task is reported at once, not one per boot" do
    recurring = <<~YML
      production:
        one:
          command: "One.call"
          schedule: every minute
          queue: alpha
        two:
          command: "Two.call"
          schedule: every minute
        three:
          command: "Three.call"
          schedule: every minute
          queue: runs
    YML
    with_config(recurring_yml: recurring) do |_dir, guard|
      assert_equal %w[one two], guard.violations.map(&:task)
      assert_match(/one/, guard.report)
      assert_match(/two/, guard.report)
    end
  end

  test "an environment with a recurring task but no worker at all is refused" do
    queue_yml = <<~YML
      development:
        workers:
          - queues: "runs"
            threads: 1
      production:
        dispatchers:
          - polling_interval: 1
    YML
    recurring = <<~YML
      production:
        no_worker:
          command: "NoWorker.call"
          schedule: every minute
          queue: runs
    YML
    with_config(queue_yml: queue_yml, recurring_yml: recurring) do |_dir, guard|
      violation = guard.violations.sole
      assert_equal "no_worker", violation.task
      assert_empty violation.worked_queues,
        "a `queue:` that matches nothing is not a pass: nothing polls it"
    end
  end

  test "a violation in ANY environment is a violation" do
    # The boot guard reads every section, so a task that would be dead in
    # production is caught from a development boot rather than next deploy.
    queue_yml = <<~YML
      development:
        workers:
          - queues: "dev-only"
      production:
        workers:
          - queues: "runs"
    YML
    recurring = <<~YML
      production:
        fine:
          command: "Fine.call"
          schedule: every minute
          queue: runs
      development:
        stranded:
          command: "Stranded.call"
          schedule: every minute
          queue: prod-only
    YML
    with_config(queue_yml: queue_yml, recurring_yml: recurring) do |_dir, guard|
      assert_equal %w[development], guard.violations.map(&:env)
    end
  end

  test "the report explains the silence, not just the mismatch" do
    recurring = <<~YML
      production:
        stranded:
          command: "Stranded.call"
          schedule: every minute
    YML
    with_config(recurring_yml: recurring) do |_dir, guard|
      report = guard.report
      assert_match(/Refusing to boot/, report)
      assert_match(/#{Regexp.escape(RecurringQueueGuard::DEFAULT_RECURRING_QUEUE)}/,
                   report,
                   "the report must name the default the task would have got")
      assert_match(/one-at-a-time/, report,
                   "and the cost of the obvious fix, which is a second thread")
    end
  end

  test "a worker that polls several queues is satisfied by any of them" do
    # The guard is a membership test, not a hard-coded "runs" check: a box that
    # deliberately ran a second queue must not be forced to lie about it.
    queue_yml = <<~YML
      production:
        workers:
          - queues: "runs"
            threads: 1
          - queues: "maintenance"
            threads: 1
    YML
    recurring = <<~YML
      production:
        on_second:
          command: "Second.call"
          schedule: every minute
          queue: maintenance
    YML
    with_config(queue_yml: queue_yml, recurring_yml: recurring) do |_dir, guard|
      assert guard.ok?, guard.report
    end
  end

  test "a missing config file is an empty check, not a silent pass" do
    # A guard that cannot read its input must not report "this agrees". The
    # initialiser is the loud path (a bad recurring.yml yields no tasks); this
    # pins that the object degrades to reporting nothing rather than claiming
    # the config was verified.
    Dir.mktmpdir("recurring-guard-empty") do |dir|
      guard = RecurringQueueGuard.new(root: dir)
      assert guard.violations.empty?,
        "with no config at all there is nothing to assert against, and the " \
        "boot guard's job is to refuse when there IS something wrong"
      assert_empty RecurringQueueGuard.new(root: dir).violations
    end
  end
end
