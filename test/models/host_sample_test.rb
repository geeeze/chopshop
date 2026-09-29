require "test_helper"

# The HOST sampler: one row a minute of what the machine running this app was
# doing, read from /proc by the STAT's own text.
#
# Everything here is driven by fixture text rather than by this box's kernel, so
# the suite asserts the RULES and not the machine it happens to run on — and the
# rules are the whole point of the model:
#
#   * a missing reading is nil, never a zero (no swap, no predecessor, a
#     percentage that would have to be computed across a gap);
#   * a CPU percentage is a delta against the sample BEFORE it, so the raw
#     counters travel with the reading;
#   * a bucket that cannot fill the readings the chart requires is dropped whole
#     rather than plotted at zero, because the series share one label list.
class HostSampleTest < ActiveSupport::TestCase
  # Two consecutive /proc/stat samples. The FIRST EIGHT fields are what count:
  # user nice system idle iowait irq softirq steal, with guest/guest_nice
  # (the last two) deliberately NON-ZERO here, because summing them would
  # double-count time already inside user/nice and report a busier CPU.
  STAT_A = "cpu  1200 30 400 8000 100 0 20 0 7 8\ncpu0 600 15 200 4000 50 0 10 0 3 4\n".freeze
  STAT_B = "cpu  1400 40 500 8800 120 0 30 0 7 8\n".freeze

  MEMINFO = <<~TEXT.freeze
    MemTotal:        3868192 kB
    MemFree:          700000 kB
    MemAvailable:    2233000 kB
    Buffers:           20000 kB
    Cached:          1800000 kB
    SwapTotal:       2000000 kB
    SwapFree:        1600000 kB
  TEXT

  # A box with NO swap configured: SwapTotal is 0, which must report an ABSENT
  # swap reading rather than 0% used.
  MEMINFO_NO_SWAP = <<~TEXT.freeze
    MemTotal:        3868192 kB
    MemAvailable:    2233000 kB
    SwapTotal:             0 kB
    SwapFree:              0 kB
  TEXT

  def teardown
    HostSample.delete_all
  end

  # -- the parsers, on fixture text ------------------------------------------

  test "the cpu line sums the first eight fields and counts idle plus iowait as idle" do
    stat = HostSample.parse_stat(STAT_A)
    # 1200+30+400+8000+100+0+20+0 = 9750, with guest 7 and guest_nice 8 EXCLUDED.
    assert_equal 9750, stat[:total], "guest and guest_nice are already inside user and nice"
    assert_equal 8100, stat[:idle], "idle is idle + iowait: waiting on disk is not work"
  end

  test "a cpu line of fewer fields than the kernel's is refused rather than guessed" do
    assert_nil HostSample.parse_stat("cpu  1 2 3\n")
    assert_nil HostSample.parse_stat("intr 1 2 3\ncpu0 1 2 3 4 5 6 7 8\n")
    assert_nil HostSample.parse_stat("")
  end

  test "meminfo reports used as total minus available, in MB" do
    mem = HostSample.parse_meminfo(MEMINFO)
    assert_equal 3777, mem[:mem_total_mb]
    assert_equal 1596, mem[:mem_used_mb], "3868192 - 2233000 kB"
    assert_equal 1953, mem[:swap_total_mb]
    assert_equal 390, mem[:swap_used_mb]
  end

  test "a box with no swap reports no swap measurement, not zero" do
    mem = HostSample.parse_meminfo(MEMINFO_NO_SWAP)
    assert_equal 0, mem[:swap_total_mb]
    assert_nil mem[:swap_used_mb], "0 used would claim a measurement nobody made"
  end

  test "meminfo without MemAvailable leaves the used figure absent" do
    mem = HostSample.parse_meminfo("MemTotal: 1000 kB\nMemFree: 400 kB\n")
    assert_equal 0, mem[:mem_total_mb], "1000 kB is 0 MB at this resolution"
    assert_nil mem[:mem_used_mb]
  end

  test "the load average is the first field, and an unparseable line is absent" do
    assert_in_delta 0.97, HostSample.parse_loadavg("0.97 0.79 0.43 2/412 182875\n")
    assert_nil HostSample.parse_loadavg("")
    assert_nil HostSample.parse_loadavg("nonsense\n")
  end

  # -- capture!: the write path ----------------------------------------------

  test "the first sample records memory and swap but NO cpu percentage" do
    at = Time.utc(2026, 9, 29, 12, 0, 0)
    sample = HostSample.capture!(now: at, stat_text: STAT_A, meminfo_text: MEMINFO,
                                 loadavg_text: "0.50 0.40 0.30 1/200 99\n")

    refute_nil sample
    assert_equal at, sample.captured_at
    assert_nil sample.cpu_pct, "there is no earlier reading to difference against"
    assert_equal 9750, sample.cpu_total, "the counters travel with the reading"
    assert_equal 8100, sample.cpu_idle
    assert_equal 42.3, sample.mem_pct
    assert_equal 20.0, sample.swap_pct
    assert_in_delta 0.5, sample.load1
  end

  test "the next sample differences the counters into a cpu percentage" do
    HostSample.capture!(now: Time.utc(2026, 9, 29, 12, 0, 0), stat_text: STAT_A,
                        meminfo_text: MEMINFO, loadavg_text: "0.5 0.4 0.3 1/2 3\n")
    second = HostSample.capture!(now: Time.utc(2026, 9, 29, 12, 1, 0), stat_text: STAT_B,
                                 meminfo_text: MEMINFO, loadavg_text: "0.5 0.4 0.3 1/2 3\n")

    # STAT_B total 10890 - 9750 = 1140 ticks; idle 8920 - 8100 = 820.
    # busy = 320/1140 = 28.07% -> 28.1
    assert_in_delta 28.1, second.cpu_pct, 0.05
  end

  test "a gap longer than a bucket leaves the cpu reading absent rather than spread over it" do
    HostSample.capture!(now: Time.utc(2026, 9, 29, 12, 0, 0), stat_text: STAT_A,
                        meminfo_text: MEMINFO)
    late = HostSample.capture!(now: Time.utc(2026, 9, 29, 12, 30, 0), stat_text: STAT_B,
                               meminfo_text: MEMINFO)

    assert_nil late.cpu_pct, "a 30-minute delta drawn as one point is a spike that never happened"
  end

  test "samples older than the retention window are pruned" do
    old = HostSample.capture!(now: Time.utc(2026, 9, 1, 12, 0, 0), stat_text: STAT_A,
                              meminfo_text: MEMINFO)
    fresh = HostSample.capture!(now: Time.utc(2026, 9, 29, 12, 0, 0), stat_text: STAT_B,
                               meminfo_text: MEMINFO)

    assert_equal [fresh.id], HostSample.pluck(:id)
    refute HostSample.exists?(old.id)
  end

  test "a host that cannot be read is a nil sample, not an exception" do
    # An empty read stands for a kernel with no /proc to parse: the sampler
    # returns nothing and the page reports the absence.
    assert_nil HostSample.capture!(now: Time.utc(2026, 9, 29, 12, 0, 0), stat_text: "",
                                   meminfo_text: MEMINFO)
    assert_nil HostSample.capture!(now: Time.utc(2026, 9, 29, 12, 0, 0), stat_text: STAT_A,
                                   meminfo_text: "")
  end

  # -- reading back: the freshness state -------------------------------------

  test "stale? is true with no samples at all, and false for one just taken" do
    assert HostSample.stale?, "no sampler has ever run"
    assert_nil HostSample.latest

    now = Time.utc(2026, 9, 29, 12, 0, 0)
    HostSample.capture!(now: now, stat_text: STAT_A, meminfo_text: MEMINFO)
    refute HostSample.stale?(now: now + 30)
    assert HostSample.stale?(now: now + HostSample::STALE_SECONDS + 1)
  end

  # -- the chart's data ------------------------------------------------------

  # A window of samples: `count` buckets, one sample each, with a controllable
  # cpu percentage so the bucket means are readable in the assertions.
  def seed_window(count:, now:, step: HostSample::BUCKET_SECONDS, cpu: nil, swap_total_mb: nil)
    count.times do |i|
      at = now - i * step
      HostSample.create!(captured_at: at, cpu_pct: cpu ? cpu.call(i) : 10 + i,
                         mem_pct: 40 + i, swap_pct: swap_total_mb ? 5 + i : nil,
                         swap_total_mb: swap_total_mb,
                         mem_total_mb: 3777, mem_used_mb: 1500)
    end
  end

  test "buckets average their samples and the labels are sparse enough to read" do
    now = Time.utc(2026, 9, 29, 12, 0, 0)
    # Three samples inside ONE bucket: the bucket is their mean.
    HostSample.create!(captured_at: now - 10, cpu_pct: 10.0, mem_pct: 40.0, swap_pct: 5.0, swap_total_mb: 100)
    HostSample.create!(captured_at: now - 20, cpu_pct: 20.0, mem_pct: 50.0, swap_pct: 5.0, swap_total_mb: 100)
    HostSample.create!(captured_at: now - 30, cpu_pct: 30.0, mem_pct: 60.0, swap_pct: 5.0, swap_total_mb: 100)

    data = HostSample.chart_data(now: now)
    assert_equal 1, data[:points], "one bucket"
    assert_equal [20.0], data[:cpu]
    assert_equal [50.0], data[:mem]
    assert_equal [5.0], data[:swap]
    assert_equal 1, data[:labels].length
    refute_equal "", data[:labels].first, "the first bucket is labelled"
  end

  test "labels land every sixth bucket and the rest are blank" do
    now = Time.utc(2026, 9, 29, 12, 0, 0)
    # 12 buckets, one sample each, 5 minutes apart.
    seed_window(count: 12, now: now, swap_total_mb: 100)

    data = HostSample.chart_data(now: now)
    assert_equal 12, data[:points]
    labels = data[:labels]
    assert_equal 12, labels.length
    assert_equal 6, labels[1..6].size
    assert_equal [""] * 5, labels[1..5], "only the marked buckets carry text"
    labeled = labels.each_index.select { |i| labels[i] != "" }
    assert_equal [0, 6], labeled, "every sixth bucket carries the time"
    assert_match(/\A\d{2}:\d{2}\z/, labels[0])
  end

  test "the window is bounded: older samples are outside it" do
    now = Time.utc(2026, 9, 29, 12, 0, 0)
    seed_window(count: 3, now: now, step: HostSample::BUCKET_SECONDS, swap_total_mb: 100)
    HostSample.create!(captured_at: now - HostSample::WINDOW_SECONDS - 60, cpu_pct: 99.0,
                       mem_pct: 99.0, swap_total_mb: 100, swap_pct: 99.0)

    data = HostSample.chart_data(now: now)
    assert_equal 3, data[:points]
    refute_includes data[:cpu], 99.0, "a sample outside the window is not in the chart"
  end

  test "a bucket with no cpu measurement is dropped whole, never plotted at zero" do
    now = Time.utc(2026, 9, 29, 12, 0, 0)
    # One good bucket, then a bucket whose only sample could not be measured.
    HostSample.create!(captured_at: now, cpu_pct: 30.0, mem_pct: 40.0, swap_total_mb: 100, swap_pct: 5.0)
    HostSample.create!(captured_at: now - HostSample::BUCKET_SECONDS, cpu_pct: nil, mem_pct: 41.0,
                       swap_total_mb: 100, swap_pct: 5.0)

    data = HostSample.chart_data(now: now)
    assert_equal 1, data[:points]
    assert_equal [30.0], data[:cpu]
    assert_equal [40.0], data[:mem], "the whole bucket goes, so the series stay aligned"
  end

  test "swap is a series only when every bucket measured it" do
    now = Time.utc(2026, 9, 29, 12, 0, 0)
    seed_window(count: 3, now: now, swap_total_mb: 100)
    assert HostSample.chart_data(now: now)[:swap], "swap measured throughout: the series exists"

    # A different window (the first one's rows are gone) on a box with no swap.
    HostSample.delete_all
    seed_window(count: 3, now: now + 1.day)
    assert_nil HostSample.chart_data(now: now + 1.day)[:swap],
      "no swap on the box: nil, so the caller omits the series instead of drawing a line at zero"
  end

  test "an empty window is an empty chart, not an error" do
    data = HostSample.chart_data(now: Time.utc(2026, 9, 29, 12, 0, 0))
    assert_equal 0, data[:points]
    assert_equal [], data[:labels]
    assert_nil data[:from]
    assert_nil data[:swap]
  end

  # -- the model's other contract: it is the box's, not an operator's ---------

  test "host samples carry no owner: the box is one machine for every operator" do
    refute HostSample.column_names.include?("owner")
  end
end
