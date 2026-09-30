# THE RECURRING QUEUE TRAP, MADE IMPOSSIBLE TO RE-ARM.
#
# config/recurring.yml is a plain list of Solid Queue recurring tasks and
# config/queue.yml pins the ONE worker to `queues: "runs"` -- one queue, one
# thread, the serial gatekeeper that keeps two runner jobs off a runner at once.
#
# The trap this exists to close (studio #3): Solid Queue's `RecurringJob`
# does `queue_as :solid_queue_recurring` unless the task declares `queue:`.
# Nothing in this deployment ever worked `solid_queue_recurring`. So a task
# added without a `queue:` line completes the ENTIRE dispatch path -- the
# task row is written at boot, an execution is recorded with a `run_at`, the
# job is enqueued -- and then sits in `ready` forever. No error, no failed
# execution, nothing to find. Measured on the live box before the fix: 30
# ready recurring jobs, 0 failed, and the hourly finished-job pruning had never
# executed once.
#
# A task on a queue nobody works is a CONFIGURATION ERROR, not a task that may
# be ignored, so it is refused at boot rather than discovered by a chart that
# quietly stops updating. The assertion is deliberately narrow: it says nothing
# about schedules, commands or cadence, only that every declared task lands on a
# queue this deployment's worker actually polls.
#
# Host-agnostic by construction: both files are read relative to the Rails root
# and only the CURRENT environment's sections are compared, so the guard means
# the same thing in dev, test and production.
class RecurringQueueGuard
  # Raised at boot. Named rather than a bare RuntimeError so a rescue -- or a
  # deploy log -- can tell "this configuration is wrong" apart from any other
  # failure to boot.
  class ConfigurationError < StandardError; end

  # A single violation, as a readable sentence. Returned rather than raised so a
  # caller (the initializer, a test, a console) can report ALL of them at once --
  # fixing them one boot at a time is the slow loop this guard is meant to end.
  Violation = Struct.new(:env, :task, :queue, :worked_queues, :message, keyword_init: true)

  attr_reader :root

  # Solid Queue's own default when a task omits `queue:`, named here so the
  # failure message can say what the task would have got instead of only what it
  # asked for.
  DEFAULT_RECURRING_QUEUE = "solid_queue_recurring".freeze

  def initialize(root: Rails.root)
    @root = Pathname.new(root)
  end

  # Every mismatch in every environment section, [] when the config is sound.
  def violations
    recurring_sections.flat_map { |env, tasks| violations_for(env, tasks) }
  end

  def ok?
    violations.empty?
  end

  # What the boot initializer calls, and what this file's tests call against a
  # broken config tree. Returns true when the config is sound; RAISES
  # ConfigurationError with the full report otherwise, so a bad recurring.yml
  # stops the deploy rather than quietly starting a job that will sit `ready`
  # forever.
  def self.verify!(root: Rails.root)
    guard = new(root: root)
    raise ConfigurationError, guard.report unless guard.ok?

    true
  end

  # The message the initializer aborts the boot with. All violations, not the
  # first: a deployment that added two bad tasks should learn about both.
  def report
    lines = violations.map { |v| "  - #{v.message}" }
    <<~MESSAGE
      Refusing to boot: a recurring task names a queue no worker in this
      deployment polls (config/recurring.yml against config/queue.yml).

      A recurring task on an unwatched queue never fails. Solid Queue writes the
      task row, records an execution and enqueues the job, and it then sits
      `ready` forever: no error, no failed execution, nothing to find. MEASURED on
      this deployment before the guard existed: 30 ready recurring jobs in the
      `#{DEFAULT_RECURRING_QUEUE}` queue, 0 failed, and the hourly finished-job
      pruning had never run once.

      #{lines.join("\n")}

      Fix it by giving each task a `queue:` that config/queue.yml's worker
      actually polls, or by adding that queue to the worker's `queues:` list --
      and know that a second queue thread gives up the one-at-a-time guarantee
      this deployment's queue exists for.
    MESSAGE
  end

  private

  def config
    @config ||= @root.join("config")
  end

  # Every environment section that actually declares tasks, as [env, tasks]
  # pairs. Solid Queue only reads the CURRENT environment's section at boot, so
  # the others are inert on this boot -- but they are the ones a deploy will
  # pick up, and a task that would be dead there is a configuration error now.
  def recurring_sections
    recurring.filter_map do |env, tasks|
      [env.to_s, tasks] if tasks.is_a?(Hash) && tasks.any?
    end
  end

  def violations_for(env, tasks)
    worked = worked_queues(env)
    return [] if worked.nil?

    tasks.filter_map do |name, task|
      next unless task.is_a?(Hash)

      queue = task["queue"] || task[:queue] || DEFAULT_RECURRING_QUEUE
      next if worked.include?(queue.to_s)

      Violation.new(
        env: env, task: name, queue: queue.to_s, worked_queues: worked,
        message: "#{env}/#{name} declares queue #{queue.inspect} but the worker " \
                 "polls #{worked.to_a.sort.inspect} (#{queue == DEFAULT_RECURRING_QUEUE ? "no `queue:` line, so Solid Queue's default" : "a queue it was never added to"})"
      )
    end
  end

  # The queues the worker for `env` polls, [] when that environment has no
  # worker at all (nothing polls, so every task is a violation), and nil when
  # the environment simply has no recurring tasks to check.
  #
  # queue.yml is a YAML alias tree (`production: <<: *default`), so the merge
  # has already happened by the time this reads it -- `queues` is present on
  # every section that has a worker.
  def worked_queues(env)
    return nil if recurring[env].nil?

    workers = Array(queue_config.dig(env, "workers"))
    workers.flat_map { |w| w["queues"].to_s.split(",") }.map(&:strip).reject(&:empty?)
  end

  def recurring
    @recurring ||= load_yaml(config.join("recurring.yml"))
  end

  def queue_config
    @queue_config ||= load_yaml(config.join("queue.yml"))
  end

  def load_yaml(path)
    return {} unless path.exist?

    parsed = YAML.safe_load(path.read, aliases: true) || {}
    parsed.is_a?(Hash) ? parsed : {}
  end
end
