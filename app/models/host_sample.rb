# The HOST's own record: what the machine this app runs on was doing while the
# pipeline ran, one row a minute.
#
# WHY THIS EXISTS. The STATUS page reports two things that are not about jobs at
# all: whether the box has room to work (CPU, memory, swap) and how it got
# there OVER TIME. Neither can be answered from the studio's own tables — those
# hold what the OPERATOR did, not what the HOST was doing — so the sample is
# taken from the kernel and kept here.
#
# WHY NOT A GEM. `sysstat`, `vmstat` and `psutil` all answer "what is happening
# NOW" and none of them keeps a series; a chart over time needs a store, and the
# store the app already has is its database. Reading /proc is four small parses
# of documented text, so the dependency buys nothing and costs a native build.
#
# THE DATA IS THE HOST'S, NOT AN OPERATOR'S. There is deliberately no `owner`
# column and no Owned include: two operators on one box are looking at the same
# machine, and scoping its CPU history per user would report a half-empty chart
# for whoever logged in second. Every other table here is owner-scoped; this one
# is the box's.
#
# THREE RULES KEEP THE CHART HONEST, and each of them is a bug this file exists
# to not have:
#
#   * A MISSING READING IS nil, NEVER A ZERO. A box with no swap configured must
#     not read "0% swap used" (that is a measurement it never made), and a CPU
#     percentage that cannot be computed over the interval it is drawn at is
#     absent rather than zero.
#   * A GAP IS NOT SPREAD OVER. A CPU percentage is a DELTA against the previous
#     sample, so a sample taken three hours after the last one describes three
#     hours, not a minute — it is reported as nil rather than as a spike that
#     never happened (see MAX_GAP_SECONDS).
#   * THE SAMPLER IS A STATE, NOT A GIVEN. A deployment whose recurring task is
#     not running shows its last sample and says when it was taken; it never
#     presents an hour-old number as the current one.
class HostSample < ActiveRecord::Base
  # The kernel's own files. Read as text and PARSED by the three free functions
  # below, so every rule about their shape is testable with a fixture string and
  # none of it needs this box's /proc.
  STAT = "/proc/stat".freeze
  MEMINFO = "/proc/meminfo".freeze
  LOADAVG = "/proc/loadavg".freeze

  # One row a minute, written by the recurring task in config/recurring.yml.
  INTERVAL_SECONDS = 60

  # The chart's geometry. A 6-hour window in 5-minute buckets is 72 points:
  # bp's line renderer draws one x label per point with no collision avoidance,
  # so the label list is SPARSE (every 6th bucket = every half hour) and the
  # rest are empty strings. Widening the window means widening the bucket with
  # it, or the axis turns into overlapping text.
  WINDOW_SECONDS = 6 * 60 * 60
  BUCKET_SECONDS = 5 * 60
  LABEL_EVERY = 6

  # The longest gap a CPU percentage may be computed ACROSS. Five minutes is one
  # bucket: inside it the number still describes roughly the interval the point
  # is drawn at. Past it, the honest answer is "not measured" — see the class
  # comment.
  MAX_GAP_SECONDS = BUCKET_SECONDS

  # A sampler that has missed five minutes has stopped, not slowed: the page
  # says so rather than showing the last good number as if it were current.
  STALE_SECONDS = 5 * 60

  # A week of one-minute samples is ~10k rows — small enough that the chart can
  # aggregate in Ruby, long enough to answer "was it always like this?".
  KEEP_SECONDS = 7 * 24 * 60 * 60

  # #host-sample-read
  # Whether this host can be sampled AT ALL. /proc is the Linux kernel's; a box
  # without it (or without read permission) is a state the page reports, not an
  # exception to rescue — `capture!` returns nil and the panel says why.
  def self.sampled?
    File.readable?(STAT) && File.readable?(MEMINFO)
  end

  # #host-sample-capture
  # One sample. The texts are injectable so a test can drive the whole write
  # path with fixture kernels rather than whatever this box happens to be doing.
  def self.capture!(now: Time.current, stat_text: nil, meminfo_text: nil, loadavg_text: nil)
    stat_text = read_text(STAT) if stat_text.nil?
    meminfo_text = read_text(MEMINFO) if meminfo_text.nil?
    return nil if stat_text.nil? || meminfo_text.nil?

    stat = parse_stat(stat_text)
    mem = parse_meminfo(meminfo_text)
    return nil if stat.nil? || mem.nil?

    previous = order(captured_at: :desc, id: :desc).first

    row = create!(
      captured_at: now,
      # The DELTAS against the previous sample, kept so the NEXT sample can
      # difference against this one. A cumulative counter is the only thing that
      # can be averaged honestly across a window we did not control.
      cpu_total: stat[:total],
      cpu_idle: stat[:idle],
      cpu_pct: cpu_percent(previous, stat, now),
      mem_total_mb: mem[:mem_total_mb],
      mem_used_mb: mem[:mem_used_mb],
      mem_pct: percent(mem[:mem_used_mb], mem[:mem_total_mb]),
      # nil, not 0, when there is no swap: see the class comment.
      swap_total_mb: mem[:swap_total_mb],
      swap_used_mb: mem[:swap_used_mb],
      swap_pct: percent(mem[:swap_used_mb], mem[:swap_total_mb]),
      load1: parse_loadavg(loadavg_text || read_text(LOADAVG).to_s)
    )

    prune!(now)
    row
  end

  # The CPU percentage between `previous` and `stat`, or nil when it cannot be
  # computed honestly: no previous counters (the first sample after install),
  # a gap longer than a bucket, or a clock that did not advance.
  def self.cpu_percent(previous, stat, now)
    return nil unless previous&.cpu_total && previous.cpu_idle && previous.captured_at
    return nil if (now - previous.captured_at) > MAX_GAP_SECONDS

    total = stat[:total] - previous.cpu_total
    idle = stat[:idle] - previous.cpu_idle
    return nil if total <= 0

    ((total - idle) * 100.0 / total).round(1)
  end

  # A percentage, or nil when the denominator is absent or zero — no swap
  # configured, or an unreadable memory total. nil is the measurement's absence,
  # and the chart drops it rather than drawing it on the floor.
  def self.percent(used, total)
    return nil if used.nil? || total.nil? || total.to_i <= 0
    (used.to_f * 100 / total).round(1)
  end

  # #host-sample-parse-stat
  # The aggregate `cpu` line: user nice system idle iowait irq softirq steal
  # guest guest_nice. Only the FIRST EIGHT are summed — guest and guest_nice are
  # already counted inside user and nice, so including them inflates the total
  # and reports a CPU that is busier than the box.
  #
  # Idle is `idle + iowait`: waiting on disk is time the CPU had no work to do,
  # which is what `top` and `vmstat` both report as idle.
  def self.parse_stat(text)
    line = text.to_s.each_line.find { |l| l.start_with?("cpu ") }
    return nil unless line

    fields = line.split[1, 8].map(&:to_i)
    return nil if fields.size < 5

    { total: fields.sum, idle: fields[3].to_i + fields[4].to_i }
  end

  # #host-sample-parse-meminfo
  # MemTotal / MemAvailable / SwapTotal / SwapFree, in kB. MemAvailable (kernel
  # 3.14+) is the only reading that answers "how much can I actually use" — the
  # free/buffers/cached sum is an approximation of it — so when it is absent the
  # used figure is nil rather than a guess.
  def self.parse_meminfo(text)
    kb = {}
    text.to_s.each_line do |line|
      name, value, unit = line.split
      next unless unit == "kB"
      kb[name.to_s.delete_suffix(":")] = value.to_i
    end

    total = kb["MemTotal"]
    available = kb["MemAvailable"]
    swap_total = kb["SwapTotal"].to_i
    swap_free = kb["SwapFree"]

    # No MemTotal is not a box with an unmeasurable memory: it is not a
    # /proc/meminfo at all (an unreadable or empty read), and there is nothing to
    # record. Returning nil here is what makes capture! skip the sample instead of
    # writing a row of absences.
    return nil if total.nil?

    # A conditional INSIDE a hash literal is a syntax error in Ruby, so the two
    # figures that can be absent are resolved first.
    used = available ? (total - available) / 1024 : nil
    swap_used = swap_total.positive? && swap_free ? (swap_total - swap_free.to_i) / 1024 : nil

    {
      mem_total_mb: total / 1024,
      mem_used_mb: used,
      swap_total_mb: swap_total / 1024,
      swap_used_mb: swap_used
    }
  end

  # The 1-minute load average. A box with no /proc/loadavg (or an unparseable
  # line) gets nil, which the panel simply does not print.
  def self.parse_loadavg(text)
    first = text.to_s.split.first
    return nil if first.nil? || !first.match?(/\A\d+(\.\d+)?\z/)
    first.to_f
  end

  # ------------------------------------------------------------- reading back

  # The newest sample, or nil before the sampler has ever run.
  def self.latest
    order(captured_at: :desc, id: :desc).first
  end

  # Whether the newest sample is old enough to mean the sampler stopped.
  def self.stale?(now: Time.current)
    last = latest
    last.nil? || (now - last.captured_at) > STALE_SECONDS
  end

  # #host-sample-buckets
  # The window aggregated into BUCKET_SECONDS buckets, oldest first, each the
  # MEAN of the samples that fell in it. A bucket that cannot fill the readings
  # the chart REQUIRES (cpu and memory, both taken from the same two files) is
  # dropped whole rather than plotted at zero: every series shares one label
  # list, so a bucket missing from one has to leave all of them, and the
  # alternatives — a zero, or the last value carried forward — are lines that
  # lie. `swap` is optional per bucket: it is nil whenever there is no swap, and
  # chart_data decides whether the series can be drawn at all.
  def self.buckets(window: WINDOW_SECONDS, step: BUCKET_SECONDS, now: Time.current)
    rows = where("captured_at >= ?", now - window).order(:captured_at).to_a
    grouped = rows.group_by { |row| row.captured_at.to_i / step }

    grouped.keys.sort.filter_map do |key|
      batch = grouped[key]
      cpu = mean(batch.map(&:cpu_pct))
      mem = mean(batch.map(&:mem_pct))
      next if cpu.nil? || mem.nil?

      { at: Time.at(key * step).utc, cpu: cpu, mem: mem, swap: mean(batch.map(&:swap_pct)) }
    end
  end

  # #host-sample-chart-data
  # The chart's arrays, ready to drop into a bp `digest` document: one value per
  # bucket per metric and ONE label list they share.
  #
  # `swap` is nil rather than an array of nils when the series cannot be drawn —
  # no swap on the box, or a window in which some bucket has no swap reading —
  # because the contract's values must be numbers and a nil smuggled in as a zero
  # would draw a flat line at the floor. The caller omits the series and says so.
  def self.chart_data(window: WINDOW_SECONDS, step: BUCKET_SECONDS, now: Time.current)
    points = buckets(window: window, step: step, now: now)
    swaps = points.map { |p| p[:swap] }

    {
      labels: points.each_with_index.map { |p, i| (i % LABEL_EVERY).zero? ? p[:at].strftime("%H:%M") : "" },
      cpu: points.map { |p| p[:cpu] },
      mem: points.map { |p| p[:mem] },
      swap: (swaps if points.any? && swaps.none?(&:nil?)),
      from: points.first&.dig(:at),
      to: points.last&.dig(:at),
      points: points.size
    }
  end

  # The mean of the values that are PRESENT, or nil when none are. A mean that
  # counted an absent reading as zero is the same lie in a different place.
  def self.mean(values)
    present = values.compact
    return nil if present.empty?
    (present.sum / present.length).round(1)
  end

  # Rows past the retention window. Deleted, not archived: this is a rolling
  # view of the box, and the chart's own window is far shorter.
  def self.prune!(now = Time.current)
    where("captured_at < ?", now - KEEP_SECONDS).delete_all
  end

  def self.read_text(path)
    return nil unless File.readable?(path)
    File.read(path)
  rescue SystemCallError
    nil
  end
end
