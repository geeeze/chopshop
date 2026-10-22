require "test_helper"

# The login orb's sunspot: intensity and frequency are tuned as a PAIR. Bumping
# one without the other is the bug this file exists to prevent.
#
# Factors CUMULATE and the timelines in ORIGINAL are the anchor, so each ask of
# "stronger and more frequent" is one more factor rather than a fresh set of
# hand-written numbers nobody can check. 1.10 was the first bump; 1.25 is the
# second, applied after the balance walk and the burst turned out to be
# invisible in practice (see the balance and burst tests below).
class SunspotWeatherTest < ActionDispatch::IntegrationTest
  BUMP = 1.10
  BUMP2 = 1.25
  TOTAL = BUMP * BUMP2

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

  # Clamped at full: 0.80 * 1.375 is 1.10, and opacity cannot exceed 1. The
  # increase therefore lives in the REST of the curve, which is what the next
  # test checks -- scaling the peaks alone would have made the effect louder
  # only at its loudest and changed its shape.
  test "flare peaks are at the top of the range" do
    ["login-sun-flare", "login-sun-flare-b"].each do |kf|
      peak = keyframe_opacities(kf).max
      assert_in_delta [0.80 * TOTAL, 1.0].min, peak, 0.001, "#{kf} peak"
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
        want = [old * TOTAL, 1.0].min
        if old.zero?
          assert_in_delta 0, now[i], 0.001, "#{kf}[#{i}] a rest stays a rest"
        else
          assert_in_delta want, now[i], 0.011,
            "#{kf}[#{i}] #{old} should be #{'%.2f' % want}, got #{now[i]}"
          assert_operator now[i], :<=, 1.0, "#{kf}[#{i}] stays in range"
        end
      end
    end
  end

  test "every sunspot period is shorter by the cumulative factor" do
    a = @css[/--sun-turn-a:\s*([\d.]+)s/, 1]
    b = @css[/--sun-turn-b:\s*([\d.]+)s/, 1]
    assert_in_delta 200 / TOTAL, a.to_f, 0.01, "layer a drift"
    assert_in_delta 260 / TOTAL, b.to_f, 0.01, "layer b drift"

    fa = @css[/login-sun-flare ([\d.]+)s/, 1]
    fb = @css[/login-sun-flare-b ([\d.]+)s/, 1]
    assert_in_delta 53 / TOTAL, fa.to_f, 0.01, "layer a flare"
    assert_in_delta 61 / TOTAL, fb.to_f, 0.01, "layer b flare"
  end

  test "the JS clamp moved with the CSS, or the first tick undoes the change" do
    # THE trap. `--sun-turn-*` is a custom property the page's own timer writes
    # every 60s, clamped between a floor and a ceiling. Change the CSS base and
    # the base is only the starting value: within a minute the tick walks it back
    # into [min, max]. So a CSS-only "faster" is reverted a minute later, which
    # looks like the change not having worked at all.
    %w[--sun-turn-a --sun-turn-b].each_with_index do |prop, i|
      floor = @view[/#{prop}', min: (\d+)/, 1]
      ceil  = @view[/#{prop}', min: \d+, max: (\d+)/, 1]
      refute_nil floor, "no clamp found for #{prop}"

      old_floor = [150, 150][i]
      old_ceil  = [260, 320][i]
      assert_in_delta old_floor / TOTAL, floor.to_i, 1.0, "#{prop} floor"
      assert_in_delta old_ceil / TOTAL, ceil.to_i, 1.0, "#{prop} ceiling"
    end
  end

  test "the wander step is scaled too" do
    # The step is a nudge to the RATE. At the old rates 0.25s was ~0.125% of a
    # turn; at the new rates 0.25s would be ~0.137%, so the drift itself would
    # speed up on top of the animation.
    step = @view[/stepS:\s*([\d.]+)/, 1]
    assert_in_delta 0.25 / TOTAL, step.to_f, 0.002
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

  test "the balance walk is wired: declared in CSS, read as a hue, written by JS" do
    assert_match(/--sun-balance:\s*50;/, @css,
      "the property must exist with a centre default, or the first tick reads NaN")
    assert_match(/hsl\(calc\([\d.]+deg \+ var\(--sun-balance\) \* [\d.]+deg\)/, @css,
      "the layer must consume it as a COLOUR, or there is nothing for the walk to move")
    # It used to be `filter: hue-rotate()` on the mottle layer, which rotated
    # nothing: that layer is near-black, white and one cyan fleck. Measured at
    # the two extremes it moved 3.8% of the orb's pixels by at most 16/255 --
    # invisible, and the reason the walk looked unimplemented.
    refute_match(/filter: hue-rotate\(calc\(\(var\(--sun-balance\)/, @css,
      "hue rotation of a grey is a grey; drive the hue directly instead")
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
    assert_equal 2500, bal, "the balance tick, found in its own block"
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

  test "the balance travels the blue and pink ends of the brand pair" do
    # The two ends are what the effect is FOR: "balance shifting between the
    # blue/pink main colour". One hue angle driven off --sun-balance, so the
    # extremes and the centre are all readable off the rule.
    m = @css.match(/hsl\(calc\(([\d.]+)deg \+ var\(--sun-balance\) \* ([\d.]+)deg\)/)
    assert m, "the balance-driven hue is gone -- the walk has no colour to move"
    base, per = m[1].to_f, m[2].to_f
    cool = base                 # --sun-balance: 0
    warm = base + 100 * per     # --sun-balance: 100
    centre = (cool + warm) / 2

    assert_operator cool,  :>=, 200, "cool end is a blue, not a cyan (#{cool}deg)"
    assert_operator cool,  :<=, 250, "cool end is a blue, not a violet (#{cool}deg)"
    assert_operator warm,  :>=, 320, "warm end reaches pink (#{warm}deg)"
    assert_operator warm,  :<=, 350, "but is still a pink, not a red (#{warm}deg)"
    assert_operator centre, :>=, 255, "centre sits between the two (#{centre}deg)"
    assert_operator centre, :<=, 310, "centre sits between the two (#{centre}deg)"
    assert_operator warm - cool, :>=, 80,
      "far enough apart to read as a shift across the traverse (#{warm - cool}deg)"
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

  test "the burst is its own element, never a pseudo of the flare span" do
    # THE bug this file did not catch. As `::before` the burst's opacity was
    # multiplied by the flare span's, and the flare sits at 0.00 for about 45%
    # of its cycle -- measured, six of the seven strike keyframes rendered at a
    # combined 0.000 and the layer was invisible in practice. Two animations
    # driving `opacity` on ONE element do not sum either (the later wins), so
    # neither the span nor a pseudo of it can carry this.
    assert_match(/\.login-sun-burst\s*\{[^}]*animation: login-sun-burst/m, @css)
    refute_match(/\.login-sun-layer::before\s*\{[^}]*login-sun-burst/m, @css,
      "a pseudo of the flare span is gated by the flare again")
    span = @css[/\.login-sun-layer \{(.*?)\n\}/m, 1]
    assert_nil span[/login-sun-burst/],
      "the span must not carry the burst animation as well"
    # In the markup it has to be a SIBLING, or it inherits the flare's opacity
    # down the tree even with a class of its own.
    assert_match(
      /<span class="login-sun-layer"[^>]*><\/span><span class="login-sun-burst"/, @view,
      "the burst must close the flare span rather than sit inside it")
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
    assert_includes sunspot.first, ".login-sun-burst"
  end

  # ---------- the pink section (a fourth sibling) ----------

  # Position AND opacity of a keyframe, so interpolated rests and irregular gaps
  # are measurable rather than assumed from the stylesheet text.
  def keyframes_with_opacity(name)
    body = @css[re("@keyframes " + name + " \\{(.*?)\\n\\}"), 1]
    raise "no @keyframes #{name}" unless body
    out = []
    body.scan(re("([\\d.]+)%(?:,\\s*([\\d.]+)%)?\\s*\\{\\s*opacity:\\s*([\\d.]+)")) do
      [$1, $2].compact.each { |pct| out << [pct.to_f, $3.to_f] }
    end
    out.sort
  end

  # Runs of lit keyframes, each closed by the zero that ends it. Shared shape
  # with burst_segments, kept separate so the burst's numbers stay the anchor.
  def segments_from(kf)
    segs, cur = [], []
    kf.each do |pos, v|
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

  test "the pink section is its own element, never a pseudo of the flare span" do
    # Same trap the burst fell into. A pseudo of the flare span inherits the
    # flare's opacity, which sits at 0.00 for about 45% of its cycle, so the band
    # would render at 0 through most of its life and look unimplemented.
    assert_match(/\.login-sun-pink\s*\{[^}]*animation:[^}]*login-sun-pink-flare/m, @css)
    refute_match(/\.login-sun-layer::(?:before|after)\s*\{[^}]*login-sun-pink/m, @css,
      "a pseudo of the flare span is gated by the flare again")
    span = @css[/\.login-sun-layer \{(.*?)\n\}/m, 1]
    assert_nil span[/login-sun-pink/],
      "the flare span must not carry the pink layer as well"
    assert_match(
      /<span class="login-sun-burst"[^>]*><\/span><span class="login-sun-pink"/, @view,
      "the pink section must be a SIBLING after the burst")
  end

  test "the pink section rotates counterclockwise and slower than both turns" do
    pink = @css[/--sun-turn-pink:\s*([\d.]+)s/, 1].to_f
    a = @css[/--sun-turn-a:\s*([\d.]+)s/, 1].to_f
    b = @css[/--sun-turn-b:\s*([\d.]+)s/, 1].to_f
    assert_operator pink, :>, 0, "the pink period is declared"
    assert_operator pink, :>, a, "slower than layer a"
    assert_operator pink, :>, b, "slower than layer b"
    assert_operator pink, :>, 200, "the slow feel: more than 200s per turn"
    # Direction: `reverse` plays the 0->360deg keyframes backwards.
    assert_match(/login-sun-pink-drift var\(--sun-turn-pink\) linear infinite reverse/, @css,
      "counterclockwise needs the drift played in reverse")
  end

  test "the pink section flares intermittently, not as a strobe" do
    period = @css[/login-sun-pink-flare ([\d.]+)s/, 1].to_f
    assert_operator period, :>=, 60, "a long cycle keeps the visits rare"
    kf = keyframes_with_opacity("login-sun-pink-flare")
    assert_equal 0.0, kf.first[1], "the cycle opens on a rest"
    segs = segments_from(kf)
    assert_operator segs.size, :>=, 3, "but it does come back"
    assert_operator segs.size, :<=, 6, "a handful of visits per cycle, not a strobe"
    peaks = segs.map { |s| s.map(&:last).max }
    assert_operator peaks.uniq.size, :>=, 3, "not all the same brightness"
    assert_operator peaks.max - peaks.min, :>, 0.2, "a real spread of intensities"
    starts = segs.map { |s| s.first[0] }
    gaps = starts.each_cons(2).map { |a, b| b - a }
    assert_operator gaps.uniq.size, :>=, 2, "and not evenly spaced, or it reads as a rhythm"
    assert kf.any? { |_, v| v.zero? }, "it must rest at 0, not sit lit"
  end

  test "reduced motion disables the pink section too" do
    blocks = @css.scan(re("@media \\(prefers-reduced-motion: reduce\\) \\{(.*?)\\n\\}"))
    sunspot = blocks.map(&:first).select { |b| b.include?(".login-sun-layer") }
    assert_equal 1, sunspot.size, "exactly one reduced-motion block for the sunspot layers"
    assert_includes sunspot.first, ".login-sun-pink"
  end

  # ---------- the mottle bands breathe ----------

  test "the mottle band alphas reference a breathing variable, not a literal" do
    layer = @css[/\.login-sun-layer \{(.*?)\n\}/m, 1]
    pseudo = @css[/\.login-sun-layer::after \{(.*?)\n\}/m, 1]
    [layer, pseudo].each do |block|
      refute_nil block
      assert_match(/hsl\([^\n]*\/\s*var\(--sun-band-/, block,
        "the hsl alpha must be a variable, or the band cannot breathe")
      refute_match(/hsl\([^\n]*\/\s*[\d.]+\)/, block,
        "an hsl alpha is still a literal number")
    end
    # The variables have to be REGISTERED and ANIMATED, or the reference resolves
    # to a fixed value wearing a variable's name and nothing breathes at all.
    %w[pink rose violet blue cyan spread-a spread-b].each do |name|
      prop = "--sun-band-#{name}"
      assert_match(/@property #{Regexp.escape(prop)}\b/, @css, "#{prop} is not registered")
    end
    assert_match(/@keyframes login-sun-band-alpha/, @css)
    assert_match(/@keyframes login-sun-band-width/, @css)
    assert_match(/login-sun-band-alpha 71s/, @css, "the alpha curve must be applied")
    assert_match(/login-sun-band-width 89s/, @css, "the width curve must be applied")
  end

  test "the breathing needs no timer, and teardown still covers every timer" do
    # The pink drift and the band breathing are pure CSS -- nothing new writes a
    # custom property from JS -- so there is no new interval to clear. Confirm
    # that, and that the existing teardown still clears each timer there is.
    refute_match(/__sunPinkTimer|__sunBandTimer/, @view)
    teardown = @view[/function stopSunDrift\(\) \{(.*?)\n    \}/m, 1]
    refute_nil teardown, "no stopSunDrift found"
    %w[__sunDriftTimer __sunBalanceTimer].each do |t|
      assert_includes teardown, t, "stopSunDrift must clear #{t}"
    end
  end
end
