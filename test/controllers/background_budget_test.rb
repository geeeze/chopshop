require "test_helper"

# The background's node budget, and the canvas resize path.
class BackgroundBudgetTest < ActionDispatch::IntegrationTest
  JS = Rails.root.join("app/javascript/aether-core.js").read

  # ---- the budget ----

  test "a small or portrait viewport gets 30% fewer background nodes" do
    assert_match(/var PARTICLE_FULL = 120;/, JS)
    assert_match(/var PARTICLE_LIGHT = 84;/, JS)
    # 84/120 = 0.70, so this is the 20-30% asked for and no more.
    assert_equal 84, (120 * 0.7).round
    assert_operator 120 - 84, :>=, (120 * 0.20).round
    assert_operator 120 - 84, :<=, (120 * 0.30).round
  end

  test "the light budget is chosen on width OR portrait, not on pointer type" do
    # A narrow desktop window is the same constrained device as a phone, and
    # `(pointer: fine)` would have kept the full 120 there.
    assert_match(/light: w < 860 \|\| h > w/, JS)
    assert_match(/setCount\(lightNow \? PARTICLE_LIGHT : PARTICLE_FULL\);/, JS)
  end

  test "the population is not hardcoded anywhere any more" do
    # It used to be `for (var i = 0; i < 120; i++)` at the bottom of
    # startParticles. Left in place it would be ADDED to the budget rather than
    # replaced by it, and the narrow viewport would have run 204 nodes.
    refute_match(/i < 120/, JS, "the hardcoded population is back")
    assert_equal 1, JS.scan(/particles\.push\(new Particle\(\)\)/).size,
      "particles should only be created by setCount"
    assert_match(/while \(particles\.length > n\) particles\.pop\(\);/, JS,
      "and shrunk back down, so a resize across 860px is reversible")
  end

  test "onResize runs its handler after Particle.reset exists" do
    # Particle.prototype.reset is an ASSIGNMENT, not a hoisted declaration. An
    # onResize() near the top of startParticles runs immediately and builds the
    # population, so it throws "this.reset is not a function" -- and because
    # that escapes startParticles, startMesh never runs and the mesh canvas
    # silently stays at its default 300x150.
    def_pos = JS.index("Particle.prototype.reset =")
    reg = JS.index("onResize(resize);", def_pos)
    refute_nil reg, "startParticles no longer registers its resize handler"
    assert_operator reg, :>, def_pos,
      "the registration must come after Particle.prototype.reset is assigned"
  end

  # ---- the resize path ----

  test "one debounced resize path feeds both canvases" do
    assert_match(/new ResizeObserver\(queueResize\)\.observe\(document\.documentElement\)/, JS,
      "the root element is observed, so zoom and the mobile URL bar are caught")
    assert_match(/window\.addEventListener\('resize', queueResize\)/, JS)
    assert_match(/window\.addEventListener\('orientationchange', queueResize\)/, JS,
      "an orientation change is a resize that some browsers do not report as one")
    # Not <body>: body height is content-driven, so observing it would fire on
    # every scroll-driven reflow.
    refute_match(/observe\(document\.body\)/, JS)
  end

  test "the debounce cannot latch shut" do
    # rAF is suspended in a hidden tab. The latch is set before rAF is
    # requested, so an rAF-only debounce would leave resizeQueued true forever
    # and drop every later resize -- the background would freeze at one size
    # until a reload.
    body = JS[/function queueResize\(\) \{(.*?)\n  \}/m, 1]
    refute_nil body
    assert_match(/setTimeout\(run,/, body, "the rAF needs a timeout backstop")
    assert_match(/if \(ran\) return;/, body, "and the two must not both run")
  end

  test "the mesh is measured from its wrapper, not the canvas" do
    # .gradient-mesh is the fixed full-size element; the canvas inside it has
    # no css size and reports its intrinsic 300x150. Measuring the canvas pins
    # the mesh to 300x150 forever, and it still LOOKS right because a smooth
    # radial gradient stretched from 300x150 reads the same.
    assert_match(/var box = canvas\.parentNode \|\| canvas;/, JS)
    assert_match(/var b = boxOf\(box\);/, JS)
    assert_match(/getBoundingClientRect/, JS,
      "clientWidth is truthy (300) on an unsized canvas and defeats a fallback")
    refute_match(/canvas\.clientWidth/, JS)
  end

  test "the canvases are observable, so the above can be checked in a browser" do
    assert_match(/window\.Aether\.background = function/, JS)
    assert_match(/resizes: resizeCount/, JS)
    assert_match(/pairs: n \* \(n - 1\) \/ 2/, JS,
      "pairs, not nodes, is what the frame loop iterates")
  end
end
