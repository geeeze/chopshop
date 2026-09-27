require "test_helper"

# The login orb's sunspot: intensity and frequency are tuned as a PAIR. Bumping
# one without the other is the bug this file exists to prevent.
class SunspotWeatherTest < ActionDispatch::IntegrationTest
  BUMP = 1.10

  setup do
    @css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))
    @view = File.read(Rails.root.join("app/views/application/login.html.erb"))
  end

  # Built with Regexp.new, not a literal: a `{` inside // is read as a
  # quantifier and the whole file fails to parse.
  def re(pattern)
    Regexp.new(pattern, Regexp::MULTILINE)
  end

  def keyframe_opacities(name)
    body = @css[re("@keyframes " + name + " \\{(.*?)\\n\\}"), 1]
    raise "no @keyframes #{name}" unless body
    body.scan(/opacity:\s*([\d.]+)/).flatten.map(&:to_f)
  end

  def ratio(old, new)
    old.to_f / new.to_f
  end

  test "flare peaks are 10% stronger" do
    ["login-sun-flare", "login-sun-flare-b"].each do |kf|
      peak = keyframe_opacities(kf).max
      assert_in_delta 0.80 * BUMP, peak, 0.001, "#{kf} peak"
    end
  end

  # The timelines as they were, so "the whole curve moved" is checkable rather
  # than assumed. Bumping the peaks alone would make the effect louder only at
  # its loudest and change its SHAPE -- a different animation, not a stronger
  # one.
  ORIGINAL = {
    "login-sun-flare"   => [0, 0.30, 0.80, 0.35, 0.62, 0.14, 0, 0.44, 0.72,
                            0.20, 0, 0.52, 0.18, 0],
    "login-sun-flare-b" => [0, 0.70, 0.25, 0.55, 0, 0.80, 0.30, 0.65, 0,
                            0.45, 0.75, 0.25, 0, 0.60, 0.20, 0]
  }.freeze

  test "the whole flare timeline scaled, not just the peaks" do
    ORIGINAL.each do |kf, original|
      now = keyframe_opacities(kf)
      assert_equal original.size, now.size, "#{kf}: same number of keyframes"

      original.each_with_index do |old, i|
        if old.zero?
          assert_in_delta 0, now[i], 0.001, "#{kf}[#{i}] a rest stays a rest"
        else
          assert_in_delta old * BUMP, now[i], 0.011,
            "#{kf}[#{i}] #{old} should be #{'%.2f' % (old * BUMP)}, got #{now[i]}"
          assert_operator now[i], :<=, 1.0, "#{kf}[#{i}] stays in range"
        end
      end
    end
  end

  test "every sunspot period is 10% shorter" do
    a = @css[/--sun-turn-a:\s*([\d.]+)s/, 1]
    b = @css[/--sun-turn-b:\s*([\d.]+)s/, 1]
    assert_in_delta 200 / BUMP, a.to_f, 0.01, "layer a drift"
    assert_in_delta 260 / BUMP, b.to_f, 0.01, "layer b drift"

    fa = @css[/login-sun-flare ([\d.]+)s/, 1]
    fb = @css[/login-sun-flare-b ([\d.]+)s/, 1]
    assert_in_delta 53 / BUMP, fa.to_f, 0.01, "layer a flare"
    assert_in_delta 61 / BUMP, fb.to_f, 0.01, "layer b flare"
  end

  test "the JS clamp moved with the CSS, or the first tick undoes the change" do
    # THE trap. `--sun-turn-*` is a custom property the page's own timer writes
    # every 60s, clamped between a floor and a ceiling. Change the CSS base and
    # the base is only the starting value: within a minute the tick walks it back
    # into [min, max]. So a CSS-only "10% faster" is reverted a minute later,
    # which looks like the change not having worked at all.
    %w[--sun-turn-a --sun-turn-b].each_with_index do |prop, i|
      floor = @view[/#{prop}', min: (\d+)/, 1]
      ceil  = @view[/#{prop}', min: \d+, max: (\d+)/, 1]
      refute_nil floor, "no clamp found for #{prop}"

      old_floor = [150, 150][i]
      old_ceil  = [260, 320][i]
      assert_in_delta old_floor / BUMP, floor.to_i, 1.0, "#{prop} floor"
      assert_in_delta old_ceil / BUMP, ceil.to_i, 1.0, "#{prop} ceiling"
    end
  end

  test "the wander step is scaled too" do
    # The step is a nudge to the RATE. At the old rates 0.25s was ~0.125% of a
    # turn; at the new rates 0.25s would be ~0.137%, so the drift itself would
    # speed up on top of the animation.
    step = @view[/stepS:\s*([\d.]+)/, 1]
    assert_in_delta 0.25 / BUMP, step.to_f, 0.001
  end

  test "the two layers are still out of phase with each other" do
    # The offset is what stops the two flares landing together. Scaling the
    # PERIOD without scaling the OFFSET would leave the same absolute offset
    # against a shorter cycle -- a different phase, and the effect would drift
    # toward synchronising over time.
    delay = @css[/animation-delay: 0s, -([\d.]+)s/, 1].to_f
    period_b = @css[/login-sun-flare-b ([\d.]+)s/, 1].to_f
    old_delay, old_period = 13.0, 61.0

    assert_in_delta old_delay / old_period, delay / period_b, 0.002,
      "same fraction of the cycle as before"
    refute_in_delta 0.0, delay / period_b, 0.001, "and not in phase"
  end

  test "reduced motion still disables it" do
    # Flicker is motion. A 10% stronger flicker that ignores this query is a
    # regression for anyone who asked for less of it.
    #
    # There is more than one `prefers-reduced-motion` block in the sheet and the
    # first one is the header mark's, so this has to find the block that
    # actually governs the layer -- matching the first one is a silent pass on
    # the wrong rule.
    blocks = @css.scan(re("@media \\(prefers-reduced-motion: reduce\\) \\{(.*?)\\n\\}"))
    sunspot = blocks.map(&:first).select { |b| b.include?(".login-sun-layer") }
    assert_equal 1, sunspot.size, "exactly one reduced-motion block for the sunspot layer"
    assert_match(/animation: none; opacity: 0;/, sunspot.first)
  end

  test "the balance walk is wired: declared in CSS, read by the filter, written by JS" do
    assert_match(/--sun-balance:\s*50;/, @css,
      "the property must exist with a centre default, or the first tick reads NaN")
    assert_match(/filter: hue-rotate\(calc\(\(var\(--sun-balance\) - 50\) \* [\d.]+deg\)\);/, @css,
      "the layer must actually consume it, or the walk is invisible")
    assert_includes @view, "SUN_BAL.prop"
    assert_includes @view, "stepPct: 1", "1% per increment, as asked"
  end

  test "the balance tick is faster than the drift tick" do
    # "more frequently" than the 60s drift, and fast enough that 1% steps
    # accumulate into visible movement rather than reading as noise.
    # Scope to each block: the FIRST `tickMs:` in the view is the drift's 60000,
    # so a bare search compares the balance against itself and passes/fails on
    # nothing. (It failed: 60000 < 60000.)
    bal = @view[/var SUN_BAL = \{[^}]*tickMs:\s*(\d+)/m, 1].to_i
    drift = @view[/var SUN = \{[^}]*tickMs:\s*(\d+)/m, 1].to_i
    assert_equal 4000, bal, "the balance tick, found in its own block"
    assert_equal 60000, drift, "the drift tick, found in its own block"
    assert_operator bal, :<, drift, "balance must tick more often than the drift"
    assert_operator bal, :<=, 10000, "and still slowly enough to read as gradual"
  end

  test "the walk commits to a direction instead of flipping a coin each tick" do
    # THE trap. A random sign per tick, cloned from the drift above, jitters the
    # balance by 1% in both directions forever and NEVER reaches either
    # extreme -- the feature silently does nothing while looking implemented.
    bal_block = @view[/var SUN_BAL = \{(.*?)\n    \};/m, 1]
    refute_nil bal_block, "no SUN_BAL config found"
    tick = @view[/function sunBalanceTick\(\) \{(.*?)\n    \}/m, 1]
    refute_nil tick, "no sunBalanceTick found"
    refute_match(/Math\.random/, tick,
      "no coin flip in the balance tick: direction must be carried as state")
    assert_match(/dir:\s*1/, @view, "direction is initialised")
    assert_match(/hold/, tick, "and there is a rest at each extreme")
  end

  test "both timers are torn down together" do
    # Turbo swaps the body but not window. A second interval that is not cleared
    # on the same events as the first leaves a dead timer per return to /login.
    assert_includes @view, "window.__sunBalanceTimer"
    teardown = @view[/function stopSunDrift\(\) \{(.*?)\n    \}/m, 1]
    %w[__sunDriftTimer __sunBalanceTimer].each do |t|
      assert_includes teardown, t, "stopSunDrift must clear #{t}"
    end
  end

  test "the balance extremes map to real hue rotation, with centre at zero" do
    # Centre must be no rotation, or the page loads with the palette already
    # shifted and the walk only ever covers half its range.
    m = @css.match(/filter: hue-rotate\(calc\(\(var\(--sun-balance\) - (\d+)\) \* ([\d.]+)deg\)\);/)
    assert m, "the hue-rotate rule is gone -- the balance walk is now invisible"
    # m[0] is the WHOLE match, m[1] the first group. Reading m[0]/m[1] here
    # silently compared the full rule text to a number.
    centre, per = m[1].to_i, m[2].to_f
    assert_equal 50, centre
    low  = (0 - centre) * per
    high = (100 - centre) * per
    assert_in_delta 0, (50 - centre) * per, 0.001, "centre is unrotated"
    assert low < -5, "cool extreme is far enough to see (#{low}deg)"
    assert high > 5, "warm extreme is far enough to see (#{high}deg)"
    assert_operator high - low, :<=, 90, "but not so far the cyan fleck leaves the palette"
  end

  # ---------- the burst layer (::before) ----------

  def burst_keyframes
    body = @css[re("@keyframes login-sun-burst \\{(.*?)\\n\\}"), 1]
    raise "no @keyframes login-sun-burst" unless body
    out = []
    body.scan(re("([\\d.]+)%(?:,\\s*([\\d.]+%)?)?\\s*\\{\\s*opacity:\\s*([\\d.]+)")) do
      [$1, $2].compact.each { |pct| out << [pct.to_f, $3.to_f] }
    end
    out.sort
  end

  # Each segment carries the ZERO keyframe that closes it, because a burst made
  # of one lit keyframe has no later keyframe of its own and would otherwise
  # measure as 0 seconds long.
  def burst_segments
    all = burst_keyframes
    segs, cur = [], []
    all.each do |pos, v|
      if v > 0
        cur << [pos, v]
      else
        segs << (cur + [[pos, 0.0]]) unless cur.empty?
        cur = []
      end
    end
    segs << (cur + [[100.0, 0.0]]) unless cur.empty?
    segs
  end

  test "the burst is its own layer, not a third animation on the span" do
    # Two animations driving `opacity` on ONE element do not sum -- the later
    # one in the list wins outright. Adding the burst to the span would have
    # silently replaced the flare for its whole 48s cycle. A pseudo-element has
    # its own opacity and the browser multiplies the two down the tree.
    assert_match(/\.login-sun-layer::before\s*\{[^}]*animation: login-sun-burst/m, @css)
    span = @css[/\.login-sun-layer \{(.*?)\n\}/m, 1]
    assert_nil span[/login-sun-burst/],
      "the span must not carry the burst animation as well"
  end

  test "the burst is infrequent" do
    segs = burst_segments
    assert_operator segs.size, :<=, 6, "a handful of strikes per cycle, not a strobe"
    period = @css[/login-sun-burst ([\d.]+)s/, 1].to_f
    assert_operator period, :>=, 60, "a long cycle keeps them rare"
  end

  test "each burst is short and rises near-instantaneously" do
    period = @css[/login-sun-burst ([\d.]+)s/, 1].to_f
    burst_segments.each do |seg|
      span = (seg.last[0] - seg.first[0]) / 100.0 * period
      assert_operator span, :<, 2.5, "burst at #{seg.first[0]}% lasts #{span.round(2)}s -- too long to read as a strike"
      assert_operator span, :>, 0.05, "and long enough to be seen at all"
    end
    # Sharpness of the rise: the first keyframe of a burst is already its value,
    # so there is no ramp. Measured off the keyframes rather than asserted from
    # the stylesheet, so a future easing that smoothed it would fail here.
    assert burst_segments.all? { |s| s.first[1] > 0.2 },
      "every burst opens on a real value, not a fade-up"
  end

  test "at least one burst is a double-strike" do
    # A single clean pulse reads as a blink. The re-strike -- a dip and then a
    # jump back up a few hundred ms later -- is what makes it read as
    # something electrical. Count RISES AFTER DIPS, not running maxima: a
    # re-strike need not be brighter than the strike before it, and burst 1
    # (0.92 -> 0.30 -> 0.74) is the clearest case of exactly that.
    doubles = burst_segments.count do |seg|
      vals = seg.map { |_, v| v }
      vals.each_cons(2).count { |a, b| b > a } > 0
    end
    assert_operator doubles, :>=, 1, "at least one re-strike"
  end

  test "bursts are irregular in both position and strength" do
    segs = burst_segments
    peaks = segs.map { |s| s.map(&:last).max }
    assert_operator peaks.uniq.size, :>=, 3, "not all the same brightness"
    assert_operator peaks.max - peaks.min, :>, 0.4, "a real spread of intensities"
    starts = segs.map { |s| s.first[0] }
    gaps = starts.each_cons(2).map { |a, b| b - a }
    assert_operator gaps.uniq.size, :>=, 2, "and not evenly spaced, or it reads as a rhythm"
  end

  test "reduced motion disables the burst layer too" do
    # A sharp intermittent flash is the most motion-sensitive thing on the
    # page. Leaving it on for someone who asked for less motion would be worse
    # than leaving the slow drift on.
    blocks = @css.scan(re("@media \\(prefers-reduced-motion: reduce\\) \\{(.*?)\\n\\}"))
    sunspot = blocks.map(&:first).select { |b| b.include?(".login-sun-layer") }
    assert_equal 1, sunspot.size, "exactly one reduced-motion block for the sunspot layers"
    assert_includes sunspot.first, ".login-sun-layer::before"
  end
end
