require "test_helper"

# Pointer entropy: the polled mouse/touch source that seeds the background
# particle field and the login orb's sunspot drift.
#
# What is pinned here is the SHAPE, because that is where the risk is: no new
# timer, ONE listener that does no work per event, and every range the effects
# were tuned to left exactly where it was. The entropy changes WHERE the numbers
# come from, never how far they may go -- see sunspot_weather_test.rb for the
# drift's own clamps, which this file deliberately does not restate.
class PointerEntropyTest < ActionDispatch::IntegrationTest
  JS = Rails.root.join("app/javascript/aether-entropy.js").read
  CORE = Rails.root.join("app/javascript/aether-core.js").read
  VIEW = Rails.root.join("app/views/application/login.html.erb").read
  IMPORTMAP = Rails.root.join("config/importmap.rb").read

  # Prose is allowed to NAME the thing it replaced -- several of these comments
  # say "not Math.random()" on purpose. Assertions about what the code does strip
  # the comments first, or they fail on their own explanation.
  def code(src)
    src.gsub(%r{//[^\n]*}, "")
  end

  # ---------- the page that needs it actually loads it

  test "the login page gets it without the site bundle" do
    assert_match(/pin "aether-entropy", to: "aether-entropy\.js"/, IMPORTMAP)
    # The login entry point is aether-core ONLY (login_js_gate_test.rb), so the
    # import has to hang off the core file or the unauth'd page never loads it.
    assert_includes CORE, 'import "aether-entropy";'
  end

  # ---------- the source: one listener, no timer, no DOM

  test "one listener, passive, and not a single timer" do
    assert_equal 1, JS.scan(/document\.addEventListener\('pointermove'/).size,
      "pointermove covers mouse, pen and finger, so there is no second listener"
    assert_equal 1, JS.scan(/document\.addEventListener\('mousemove'/).size
    assert_equal 1, JS.scan(/document\.addEventListener\('touchmove'/).size
    assert_equal 3, JS.scan(/\{ passive: true \}/).size,
      "every listener passive: this must never stall a scroll or a swipe"
    refute_match(/setInterval|setTimeout|requestAnimationFrame/, JS,
      "polled means the consumer asks -- there is no clock in here at all")
  end

  test "the event handler only records where and when" do
    # The affordability rule: one assignment per event. All the mixing happens in
    # poll(), which a consumer calls when it wants a number and not before.
    body = JS[/function sample\(x, y\) \{(.*?)\n  \}/m, 1]
    refute_nil body, "no sample() found"
    refute_match(/style\.|classList|getContext|innerHTML|getComputedStyle|canvas/, body,
      "the handler must not touch the DOM")
    assert_match(/last = \{ x: x, y: y, t: t \};/, body)
  end

  test "the module writes no CSS and keeps no second copy of any effect's state" do
    # One number, one home: the drift's state lives in the layer's custom
    # property and the field's in its own closure. This module hands out numbers.
    refute_match(/classList|setAttribute|innerHTML|getComputedStyle/, JS)
    refute_match(/style\./, JS)
  end

  test "a cold pool still varies, so nothing reads a frozen value" do
    # No pointer input at all -- a phone nobody has touched, a headless run --
    # must not pin the value: the clock is mixed in on every poll.
    assert_match(/function poll\(\) \{/, JS)
    assert_match(/var word = Math\.round\(clock\(\)\) \^ micro;/, JS)
    assert_match(/return pool \/ UINT32;/, JS, "the result is a float in [0, 1)")
    assert_match(/function coin\(\) \{ return poll\(\) < 0\.5; \}/, JS)
  end

  test "activity decays on read, so it needs no timer and is pure" do
    body = JS[/function activity\(\) \{(.*?)\n  \}/m, 1]
    refute_nil body
    assert_match(/if \(!lastAt\) return 0;/, body, "never moved -> exactly 0")
    assert_match(/if \(quiet >= QUIET_MS\) return 0;/, body, "fades to 0 across the window")
    refute_match(/travel =|travel \*=/, body,
      "a probe may poll it as often as it likes -- the read must not drain it")
  end

  # ---------- consumer 1: the background particle field

  test "the field is seeded by the pointer, with the shipped ranges intact" do
    assert_match(/function rand\(\) \{/, CORE)
    assert_match(/return e \? e\.poll\(\) : Math\.random\(\);/, CORE,
      "Math.random is the cold-pool fallback, never the primary source")

    reset = CORE[/Particle\.prototype\.reset = function \(\) \{(.*?)\n    \};/m, 1]
    refute_nil reset, "no Particle.prototype.reset found"
    refute_match(/Math\.random/, code(reset), "every spawn value now comes through rand()")
    assert_equal 9, code(reset).scan(/rand\(\)/).size,
      "position, size, speed x2, opacity, colour, breathe, drift"
    # The ranges are the shipped ones: |speedX| and |speedY| spawn under 0.4.
    assert_match(/this\.speedX = \(rand\(\) - 0\.5\) \* 0\.8;/, reset)
    assert_match(/this\.speedY = \(rand\(\) - 0\.5\) \* 0\.8;/, reset)
    assert_match(/this\.size = rand\(\) \* 2 \+ 0\.5;/, reset)
  end

  test "the breeze cannot raise the speed the field was tuned to" do
    # 0.4 is the per-axis maximum the spawn already produces; the breeze may push
    # a node toward it, and the clamp is what stops it going past.
    assert_match(/var MAX_SPEED = 0\.4;/, CORE)
    assert_match(/var BREEZE_MAX = 0\.12;/, CORE)
    assert_match(/if \(vx > MAX_SPEED\) vx = MAX_SPEED; else if \(vx < -MAX_SPEED\) vx = -MAX_SPEED;/, CORE)
    assert_match(/if \(vy > MAX_SPEED\) vy = MAX_SPEED; else if \(vy < -MAX_SPEED\) vy = -MAX_SPEED;/, CORE)
  end

  test "a still pointer leaves the field exactly as it shipped" do
    body = CORE[/function sampleFlow\(\) \{(.*?)\n    \}/m, 1]
    refute_nil body, "no sampleFlow found"
    assert_match(/live = e\.activity\(\);/, body)
    assert_match(/if \(live <= 0\) \{ flow\.x = 0; flow\.y = 0; return; \}/, body,
      "activity 0 zeroes the breeze")
    assert_equal 1, CORE.scan(/sampleFlow\(\);/).size,
      "read ONCE per frame, never per particle"
    refute_match(/sampleFlow\(\)/, CORE[/Particle\.prototype\.update = function \(dt\) \{(.*?)\n    \};/m, 1].to_s,
      "the per-particle update must not poll")
  end

  test "the shimmer keeps its band and its phase accumulates" do
    update = CORE[/Particle\.prototype\.update = function \(dt\) \{(.*?)\n    \};/m, 1]
    refute_nil update, "no Particle.prototype.update found"
    assert_match(/this\.opacity = Math\.sin\(this\.breathe\) \* 0\.2 \+ 0\.3;/, update,
      "the shipped 0.1..0.5 opacity band, unchanged")
    assert_match(/this\.breathe \+= dt \* 0\.001 \* \(1 \+ live \* 0\.5\);/, update,
      "tempo, bounded at 1.5x")
    refute_match(/Date\.now\(\)/, code(update),
      "a wall-clock rate cannot change without the phase jumping to static")
  end

  # ---------- consumer 2: the login orb's drift

  test "the drift's coin is polled, not the page's one PRNG sequence" do
    tick = VIEW[/function sunTick\(\) \{(.*?)\n    \}/m, 1]
    refute_nil tick, "no sunTick found"
    assert_match(/\(e \? e\.coin\(\) : \(Math\.random\(\) < 0\.5\)\) \? -1 : 1/, tick,
      "the polled coin, with Math.random only as the fallback")
    assert_match(/var e = driftEntropy\(\);/, tick,
      "read at TICK time: the module is deferred and this inline script is classic")
  end

  test "the step band scales the walk, and the clamp still owns the range" do
    assert_match(/stepBand: 0\.5,/, VIEW)
    assert_match(/var step = SUN\.stepS \* \(1 \+ \(live - 0\.5\) \* SUN\.stepBand\);/, VIEW)
    # 0.75x .. 1.25x of the shipped 0.1818s step, and the clamp still holds the
    # rate inside the floor/ceiling pair the CSS is tuned against -- the widest
    # step (0.227s) is a fraction of the narrowest band (80s).
    assert_in_delta 0.1818 * 1.25, 0.22725, 0.00001
    assert_match(/Math\.min\(t\.max, Math\.max\(t\.min, now \+ dir \* step\)\)/, VIEW)
    assert_match(/if \(now \+ dir \* step > t\.max\) dir = -1;/, VIEW)
    assert_match(/if \(now \+ dir \* step < t\.min\) dir = 1;/, VIEW)
  end

  test "the entropy added no timer to the login page" do
    # A 60s tick cannot use the instant, so the minute's movement is read off the
    # module's own sample count -- which is why no second interval was needed.
    assert_match(/var seen = e\.stats\(\)\.samples;/, VIEW)
    assert_match(/Math\.min\(1, recent \/ 120\)/, VIEW)
    assert_equal 2, VIEW.scan(/= setInterval\(/).size, "still exactly two timers"
    refute_match(/__sunEntropyTimer|__pointerTimer|__driftActivityTimer/, VIEW)
    teardown = VIEW[/function stopSunDrift\(\) \{(.*?)\n    \}/m, 1]
    refute_nil teardown, "no stopSunDrift found"
    %w[__sunDriftTimer __sunBalanceTimer].each { |t| assert_includes teardown, t }
  end

  test "the balance walk is left on its own state machine" do
    # Its direction is carried as state, not decided by a coin -- a coin there
    # jitters 1% both ways for ever and never reaches an extreme (see
    # sunspot_weather_test). The entropy is for the turn RATES only.
    bal = VIEW[/function sunBalanceTick\(\) \{(.*?)\n    \}/m, 1]
    refute_nil bal, "no sunBalanceTick found"
    refute_match(/coin\(\)|Math\.random/, bal)
  end

  # ---------- the numbers are readable from a browser

  test "both consumers are observable" do
    assert_match(/window\.Aether\.entropy = api;/, JS)
    assert_match(/var api = \{ poll: poll, coin: coin, activity: activity, motion: motion, stats: stats \};/, JS)
    assert_match(/activity: activityNow\(\),/, CORE)
    assert_match(/flow: flowNow\(\),/, CORE)
    assert_match(/entropy: \(window\.Aether\.entropy \? window\.Aether\.entropy\.stats\(\) : null\)/, CORE)
  end
end
