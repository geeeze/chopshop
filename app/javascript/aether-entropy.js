// Aether pointer entropy: ONE polled source of randomness, seeded by the real
// mouse/finger, shared by the background particle field (aether-core.js) and the
// login orb's sunspot drift (login.html.erb).
//
// WHY POLLED, AND WHY NOT Math.random()
//
//  - Math.random() is a PRNG seeded once per page load. Every decorative
//    decision drawn from it is a FIXED sequence, so two visits see the same
//    "random" drift and the background can only ever look like the one timeline
//    that seed implies.
//  - The pointer is the only thing on the page that is different every visit,
//    and its TIMING carries most of it: a hand travelling a straight line still
//    arrives at uneven intervals.
//  - "Polled" is the affordability rule. The listener does ONE assignment per
//    event -- no maths, no DOM write, no rAF -- and all the mixing happens when a
//    consumer asks (poll()/activity()). A page where nothing asks pays nothing,
//    and there is no new timer anywhere: no interval, no timeout.
//
// COLD START IS NOT A CONSTANT. With no pointer input at all -- a phone nobody
// has touched, a headless run -- the pool still mixes the clock, so a consumer
// never reads a frozen value; pointer samples are what make it differ per USER
// rather than per millisecond. Math.random() is the last-resort fallback for a
// consumer that runs before this module (see aether-core's `rand()`), never the
// primary source.
//
// The login page's draw canvas does NOT use this: it spawns AT the pointer, so
// it is already seeded by the hand by construction.
//
// Everything a consumer reads is bounded by the CONSUMER, not here: this module
// hands out numbers, and each effect keeps its own tuned range (see the speed
// ceiling in aether-core and the clamp in the drift tick).
export default (function () {
  'use strict';

  var QUIET_MS = 2500;      // how long a gesture keeps counting as recent motion
  var FULL_TRAVEL = 600;    // px of travel inside the window that reads as 1.0
  var UINT32 = 4294967296;

  // 32-bit mixing state, seeded from the clock so the first poll() already
  // differs between two loads a millisecond apart, and never allowed to be zero.
  var pool = 0x9e3779b9;
  var micro = Math.floor((window.performance && window.performance.now
    ? window.performance.now() : Date.now()) * 1000) || 1;

  var last = null;          // {x, y, t} newest sample
  var prev = null;          // the sample before it, for the path delta
  var travel = 0;           // px travelled inside the current window
  var samples = 0;          // pointer samples seen since load
  var lastAt = 0;           // ms clock of the newest sample

  function clock() {
    return (window.performance && window.performance.now)
      ? window.performance.now() : Date.now();
  }

  // murmur3's 32-bit finaliser. Math.imul is ES2015, the same baseline as the ES
  // modules this app is loaded as, so there is no older engine to serve.
  function hash32(a) {
    a = a | 0;
    a ^= a >>> 16;
    a = Math.imul(a, 0x7feb352d);
    a ^= a >>> 15;
    a = Math.imul(a, 0x846ca68b);
    a ^= a >>> 16;
    return a >>> 0;
  }

  // ---------- the sample: one assignment per event, nothing else
  function sample(x, y) {
    var t = clock();
    // A gap longer than the window opens a NEW gesture, and the travel from the
    // old one must not be credited to it.
    if (lastAt && t - lastAt > QUIET_MS) travel = 0;
    if (last) {
      var dx = x - last.x, dy = y - last.y;
      travel += Math.sqrt(dx * dx + dy * dy);
    }
    prev = last;
    last = { x: x, y: y, t: t };
    lastAt = t;
    samples += 1;
  }

  function fromMouse(e) {
    if (e.clientX || e.clientY) sample(e.clientX, e.clientY);
  }

  // pointermove covers mouse, pen AND finger in one event, so on a modern engine
  // it is the only listener there is; the mousemove+touchmove pair is the
  // fallback for an engine without PointerEvent. Both are passive -- this must
  // never be the reason a scroll or a swipe stalls.
  if (window.PointerEvent) {
    document.addEventListener('pointermove', fromMouse, { passive: true });
  } else {
    document.addEventListener('mousemove', fromMouse, { passive: true });
    document.addEventListener('touchmove', function (e) {
      var t = e.touches && e.touches[0];
      if (t) sample(t.clientX, t.clientY);
    }, { passive: true });
  }

  // ---------- what consumers read

  // #pointer-entropy-poll -- the randomness itself: a float in [0, 1).
  //
  // The pointer's path is folded in first -- position, and the gap since the
  // previous sample, which is the part with real entropy in it -- then the pool
  // is mixed with the current clock, so back-to-back calls cannot repeat and a
  // cold pool still varies.
  function poll() {
    var word = Math.round(clock()) ^ micro;
    if (last) {
      var gap = prev ? (last.t - prev.t) : 0;
      word ^= Math.round(last.x);
      word ^= Math.round(last.y) << 1;
      word ^= Math.round(gap * 1000) * 0x9e3779b1;
    }
    micro = hash32(word);
    pool = hash32(pool ^ micro);
    return pool / UINT32;
  }

  // A coin, from the same source, named for what the call sites decide with it:
  // ebb or flow.
  function coin() { return poll() < 0.5; }

  // #pointer-entropy-activity -- 0..1, how much the hand has moved LATELY.
  //
  // Decay is read-time and there is no timer: nothing recent reads 0, and it
  // fades to 0 across the window. Pure and idempotent, so a probe may poll it as
  // often as it likes -- the travel it measures is reset on the sample boundary
  // above, not here.
  function activity() {
    if (!lastAt) return 0;
    var quiet = clock() - lastAt;
    if (quiet >= QUIET_MS) return 0;
    return Math.min(1, travel / FULL_TRAVEL) * (1 - quiet / QUIET_MS);
  }

  // Direction and length of the newest stroke, for a consumer that wants the
  // field to lean the way the pointer is going rather than merely to liven up.
  function motion() {
    if (!last || !prev) return null;
    return { x: last.x, y: last.y, dx: last.x - prev.x, dy: last.y - prev.y, t: last.t };
  }

  function stats() {
    return {
      samples: samples,
      travel: Math.round(travel),
      activity: activity(),
      last: last ? { x: last.x, y: last.y, t: Math.round(last.t) } : null,
      pointerEvents: !!window.PointerEvent
    };
  }

  var api = { poll: poll, coin: coin, activity: activity, motion: motion, stats: stats };

  // The same namespace aether-core publishes into. The login page's inline drift
  // script reads window.Aether.entropy at TICK time, because it runs before this
  // module does: the inline script is classic, the modules are deferred.
  window.Aether = window.Aether || {};
  window.Aether.entropy = api;

  return api;
})();
