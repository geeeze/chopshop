// Aether core: background orbs/particles/mesh, custom cursor, magnetic hover,
// and the glass modal (window.CsModal) — the only JavaScript the login page
// needs. Split out of aether.js so the unauth'd login page stops downloading
// the whole site bundle (scrapbook, candidate/proof viewer, Jev, job polling)
// it never runs. Shared by the login page AND every authed page.
//
// #pointer-entropy-module -- the polled pointer entropy both this file's
// particle field and the login page's inline drift script read. It rides in as a
// side-effect import (it installs window.Aether.entropy), and it has to live
// here rather than in the site module: the login page loads ONLY this file.
import "aether-entropy";

export default (function () {
  'use strict';


  function isDesktop() {
    return window.matchMedia('(pointer: fine)').matches;
  }

  // ---------- the background's randomness, seeded by the pointer
  //
  // #pointer-entropy-rand -- every decorative value in the particle field is
  // drawn through here, so the field is a function of THIS visit's hand rather
  // than of the single PRNG sequence a page load starts with. Math.random()
  // remains the fallback for a pool that is still cold (a page nobody has
  // touched yet), so the scatter is never degenerate either way.
  function rand() {
    var e = window.Aether && window.Aether.entropy;
    return e ? e.poll() : Math.random();
  }

  // ---------- background canvases: create once, persist across Turbo visits
  function ensureBackground() {
    if (document.getElementById('particle-canvas')) return;

    ['orb-1', 'orb-2', 'orb-3'].forEach(function (cls) {
      var orb = document.createElement('div');
      orb.className = 'bg-gradient-orb ' + cls;
      document.body.prepend(orb);
    });

    var mesh = document.createElement('div');
    mesh.className = 'gradient-mesh';
    var meshCanvas = document.createElement('canvas');
    meshCanvas.id = 'gradient-mesh';
    mesh.appendChild(meshCanvas);
    document.body.prepend(mesh);

    var pc = document.createElement('canvas');
    pc.id = 'particle-canvas';
    document.body.prepend(pc);

    startParticles(pc);
    startMesh(meshCanvas);
    trackOrbs();
  }

  // The background is a node-link graph, not a scatter: every pair of particles
  // within 200px is joined by a stroked line, so the per-frame cost is O(n^2).
  // At the full 120 that is 7140 distance checks a frame, ~428k a second at
  // 60fps, for decoration behind a page of forms.
  //
  // A phone, a portrait window, or any window under 860px gets 84 nodes instead
  // of 120 -- 30% fewer -- which takes the pair loop to 3486, a 51% cut. The
  // budget is on NODES as asked; the saving is larger than 30% because the work
  // is quadratic.
  //
  // Width and orientation, not pointer type: a narrow desktop window is the
  // same constrained device as a phone, and isDesktop()'s `(pointer: fine)`
  // would keep the full 120 there.
  var PARTICLE_FULL = 120;
  var PARTICLE_LIGHT = 84;

  // ---------- one resize path, driven by the ELEMENT not the window
  //
  // Both canvases used to listen to window 'resize' directly. That covers a
  // dragged window and an orientation change, but it is the wrong trigger: it
  // says nothing about the box the canvas actually occupies, and it misses a
  // container resizing, a zoom change, and the mobile URL bar showing or
  // hiding -- all of which leave the canvases at their old pixel size until a
  // reload.
  //
  // A ResizeObserver on the root element catches those, because it reports the
  // real content box. Both signals feed one rAF-debounced handler: a drag fires
  // a resize event per frame, and resizing a canvas reallocates its backing
  // store, so doing it per event thrashes. Once per frame is enough -- the
  // paint that follows is on the same frame anyway.
  var resizeHandlers = [];
  var resizeQueued = false;
  var resizeCount = 0;

  function queueResize() {
    if (resizeQueued) return;
    resizeQueued = true;
    var ran = false;
    function run() {
      if (ran) return;
      ran = true;
      resizeQueued = false;
      resizeCount++;
      for (var i = 0; i < resizeHandlers.length; i++) resizeHandlers[i]();
    }
    // rAF is the right clock when we are painting anyway -- it lines the
    // reallocation up with the frame that will show it.
    if (window.requestAnimationFrame) requestAnimationFrame(run);
    // But rAF is SUSPENDED in a hidden tab, and that matters here more than
    // usual: the latch above is set before rAF is requested, so if rAF never
    // fires, resizeQueued stays true and every later resize is dropped
    // permanently -- the background would freeze at one size until a reload.
    // A timeout is the backstop, and `ran` keeps it to a single run.
    setTimeout(run, 100);
  }

  // Register a handler and run it once, so the first paint is already correct
  // rather than waiting for the observer's first delivery.
  function onResize(fn) {
    resizeHandlers.push(fn);
    fn();
  }

  if (window.ResizeObserver) {
    // The root element, not <body>: body height is content-driven, so
    // observing it would fire on every scroll-driven reflow.
    new ResizeObserver(queueResize).observe(document.documentElement);
  }
  window.addEventListener('resize', queueResize);
  window.addEventListener('orientationchange', queueResize);

  // ---------- a way to see what the background is doing
  //
  // Read by the test suite, which cannot otherwise see inside these closures.
  // It reports pairs as well as particles, because pairs are what the frame
  // loop actually iterates and they are quadratic in the node count -- a 30%
  // cut in nodes is a 51% cut in work.
  window.Aether = window.Aether || {};
  window.Aether.background = function () {
    var n = particleCount();
    return {
      particles: n,
      pairs: n * (n - 1) / 2,
      light: lightNow,
      resizes: resizeCount,
      // What the pointer is contributing: 0 means the field is exactly the one
      // that shipped, before any hand touched it.
      activity: activityNow(),
      flow: flowNow(),
      entropy: (window.Aether.entropy ? window.Aether.entropy.stats() : null),
      particleCanvas: canvasSize('particle-canvas'),
      meshCanvas: canvasSize('gradient-mesh')
    };
  };
  window.Aether.forceResize = queueResize;
  window.Aether.budgets = { full: PARTICLE_FULL, light: PARTICLE_LIGHT };

  function canvasSize(id) {
    var c = document.getElementById(id);
    return c ? { w: c.width, h: c.height, cssW: c.clientWidth, cssH: c.clientHeight } : null;
  }

  // Set by the particle canvas's resize; read by window.Aether.background().
  var particleCount = function () { return 0; };
  var lightNow = false;

  // The breeze readings, set by startParticles the same way: the closure owns
  // the real values, so the observability hook reads them through these.
  var activityNow = function () { return 0; };
  var flowNow = function () { return { x: 0, y: 0 }; };

  // The box to draw into, taken from the ELEMENT rather than window.innerWidth
  // -- that is the whole point of watching the element.
  //
  // `box` is the thing to measure, which is not always the canvas. The particle
  // canvas is `position:fixed; width:100%; height:100%` itself, so measuring the
  // canvas is right. The mesh canvas has NO css size: `.gradient-mesh` is the
  // fixed full-size element and the canvas is a bare child, so the canvas
  // reports its intrinsic 300x150 default. Measuring the canvas there pins the
  // mesh to 300x150 forever -- and it still LOOKS right, because a smooth
  // radial gradient stretched from 300x150 reads the same, which is exactly why
  // it would have gone unnoticed.
  //
  // getBoundingClientRect, not clientWidth: a canvas with no css box has a
  // clientWidth of 300, which is truthy and so defeats a `|| window` fallback.
  function boxOf(box) {
    var r = box.getBoundingClientRect();
    var w = r.width || window.innerWidth;
    var h = r.height || window.innerHeight;
    return { w: w, h: h, light: w < 860 || h > w };
  }

  function startParticles(canvas) {
    var ctx = canvas.getContext('2d');
    var particles = [];

    function resize() {
      var b = boxOf(canvas);
      canvas.width = b.w;
      canvas.height = b.h;
      lightNow = b.light;
      setCount(lightNow ? PARTICLE_LIGHT : PARTICLE_FULL);
    }
    // Grow or shrink to the budget, so rotating a phone or dragging a desktop
    // window across the 860px line gets the count back without a reload.
    function setCount(n) {
      while (particles.length > n) particles.pop();
      while (particles.length < n) particles.push(new Particle());
      particleCount = function () { return particles.length; };
    }

    function Particle() { this.reset(); }
    Particle.prototype.reset = function () {
      // Through rand(), not Math.random(): the population is seeded by the
      // pointer when the pool is warm. The RANGES are untouched -- size, the
      // +/-0.4 per-axis speed, opacity and the palette are the shipped ones.
      this.x = rand() * canvas.width;
      this.y = rand() * canvas.height;
      this.size = rand() * 2 + 0.5;
      this.speedX = (rand() - 0.5) * 0.8;
      this.speedY = (rand() - 0.5) * 0.8;
      this.opacity = rand() * 0.6 + 0.1;
      this.color = ['#6366f1', '#ec4899', '#06b6d4', '#8b5cf6', '#10b981'][Math.floor(rand() * 5)];
      // Per-node character, drawn from the same source. `breathe` is the phase
      // accumulator the shimmer walks (seeded here, so the field shimmers rather
      // than pulsing as one sheet) and `drift` is how much of a passing breeze
      // this node takes -- some nodes lead, some drag, so a breeze bends the
      // field instead of sliding the whole canvas sideways.
      this.breathe = rand() * Math.PI * 2;
      this.drift = 0.5 + rand() * 0.5;
    };
    // #pointer-entropy-breeze -- pointer motion, bounded.
    //
    // The field is allowed to lean the way the pointer is going, but only INSIDE
    // the budget the spawn above already uses: MAX_SPEED is that same per-axis
    // 0.4, and the total displacement is clamped to it, so a stirred node is
    // never faster than the fastest node the tune implies.
    //
    // Read ONCE per frame from the polled sample -- never per particle, and never
    // in the event handler -- and with no pointer input activity() is exactly 0,
    // which zeroes the flow and leaves the field bit-for-bit as it shipped.
    var MAX_SPEED = 0.4;     // px/frame/axis; |speedX| and |speedY| spawn under this
    var BREEZE_MAX = 0.12;   // px/frame at full activity, before the clamp
    var flow = { x: 0, y: 0 };
    var live = 0;            // the activity the last frame read

    function sampleFlow() {
      var e = window.Aether && window.Aether.entropy;
      if (!e) return;
      live = e.activity();
      if (live <= 0) { flow.x = 0; flow.y = 0; return; }
      var m = e.motion();
      if (!m) return;
      var len = Math.sqrt(m.dx * m.dx + m.dy * m.dy);
      if (len < 0.5) return;               // a jitter is not a direction
      flow.x = (m.dx / len) * live * BREEZE_MAX;
      flow.y = (m.dy / len) * live * BREEZE_MAX;
    }
    activityNow = function () { return live; };
    flowNow = function () { return { x: flow.x, y: flow.y }; };

    Particle.prototype.update = function (dt) {
      var vx = this.speedX + flow.x * this.drift;
      var vy = this.speedY + flow.y * this.drift;
      if (vx > MAX_SPEED) vx = MAX_SPEED; else if (vx < -MAX_SPEED) vx = -MAX_SPEED;
      if (vy > MAX_SPEED) vy = MAX_SPEED; else if (vy < -MAX_SPEED) vy = -MAX_SPEED;
      this.x += vx;
      this.y += vy;
      if (this.x < 0 || this.x > canvas.width) this.speedX *= -1;
      if (this.y < 0 || this.y > canvas.height) this.speedY *= -1;
      // #pointer-entropy-breathe -- the same 0.1..0.5 opacity band as the shipped
      // sin(): the pointer changes the TEMPO (up to 1.5x while the hand is
      // moving) and the phase, never how bright the band is.
      //
      // The phase ACCUMULATES instead of reading the wall clock, because the rate
      // is now variable: with Date.now() in the formula, any change in rate
      // multiplies the whole elapsed time at once and the shimmer would jump to
      // static rather than speed up.
      this.breathe += dt * 0.001 * (1 + live * 0.5);
      this.opacity = Math.sin(this.breathe) * 0.2 + 0.3;
    };
    Particle.prototype.draw = function () {
      ctx.beginPath();
      ctx.arc(this.x, this.y, this.size, 0, Math.PI * 2);
      ctx.fillStyle = this.color;
      ctx.globalAlpha = this.opacity;
      ctx.fill();
      ctx.globalAlpha = 1;
    };

    // Registered HERE, at the bottom, and not at the top of the function.
    // onResize() runs its handler immediately, and the handler builds the
    // population with `new Particle()` -- but Particle.prototype.reset is an
    // ASSIGNMENT below, not a hoisted declaration, so registering any earlier
    // constructs a particle before reset exists and throws "this.reset is not
    // a function". That exception escaped startParticles, which is why
    // startMesh never ran and the mesh canvas stayed at its default 300x150.
    onResize(resize);

    var lastFrame = 0;
    (function animate() {
      var stamp = Date.now();
      // Clamped: rAF is suspended in a hidden tab, and the frame after a resume
      // must not arrive as one huge step in the breathing phase.
      var dt = lastFrame ? Math.min(64, stamp - lastFrame) : 16;
      lastFrame = stamp;
      // #pointer-entropy-frame -- the breeze is read ONCE here, for the whole
      // field, and never inside the per-particle loop.
      sampleFlow();
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      particles.forEach(function (p) { p.update(dt); p.draw(); });
      for (var a = 0; a < particles.length; a++) {
        for (var b = a + 1; b < particles.length; b++) {
          var p1 = particles[a], p2 = particles[b];
          var dx = p1.x - p2.x, dy = p1.y - p2.y;
          var d2 = dx * dx + dy * dy;
          if (d2 < 40000) {
            var dist = Math.sqrt(d2);
            ctx.beginPath();
            ctx.moveTo(p1.x, p1.y);
            ctx.lineTo(p2.x, p2.y);
            ctx.strokeStyle = 'rgba(99, 102, 241, ' + (0.03 * (1 - dist / 200)) + ')';
            ctx.lineWidth = 0.5;
            ctx.stroke();
          }
        }
      }
      requestAnimationFrame(animate);
    })();
  }

  function startMesh(canvas) {
    var ctx = canvas.getContext('2d');
    // The wrapper is the sized element; the canvas inside it is not.
    var box = canvas.parentNode || canvas;
    function resize() {
      var b = boxOf(box);
      canvas.width = b.w;
      canvas.height = b.h;
    }
    onResize(resize);

    (function animate() {
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      var w = canvas.width, h = canvas.height;
      var gradient = ctx.createRadialGradient(w * 0.3, h * 0.3, 0, w * 0.7, h * 0.7, Math.max(w, h));
      gradient.addColorStop(0, 'rgba(99, 102, 241, 0.03)');
      gradient.addColorStop(0.5, 'rgba(236, 72, 153, 0.02)');
      gradient.addColorStop(1, 'rgba(6, 182, 212, 0.01)');
      ctx.fillStyle = gradient;
      ctx.fillRect(0, 0, w, h);
      requestAnimationFrame(animate);
    })();
  }

  function trackOrbs() {
    document.addEventListener('mousemove', function (e) {
      var orbs = document.querySelectorAll('.bg-gradient-orb');
      var x = e.clientX / window.innerWidth;
      var y = e.clientY / window.innerHeight;
      orbs.forEach(function (orb, i) {
        if (orb.classList.contains('orb-pinned')) return;
        var speed = (i + 1) * 25;
        orb.style.transform = 'translate(' + (-x + 0.5) * speed + 'px, ' + (-y + 0.5) * speed + 'px)';
      });
    });
  }

  // ---------- custom cursor (fine pointers only)
  function ensureCursor() {
    if (!isDesktop()) return;
    if (document.getElementById('cursorCore')) return;

    var system = document.createElement('div');
    system.className = 'cursor-system';
    system.innerHTML =
      '<div class="cursor-core" id="cursorCore"></div>' +
      '<div class="cursor-orbit" id="cursorOrbit"></div>' +
      '<div class="cursor-trail" id="cursorTrail"></div>';
    document.body.appendChild(system);

    var core = system.querySelector('#cursorCore');
    var orbit = system.querySelector('#cursorOrbit');
    var trail = system.querySelector('#cursorTrail');

    var mouseX = 0, mouseY = 0, orbitX = 0, orbitY = 0, trailX = 0, trailY = 0;

    document.addEventListener('mousemove', function (e) {
      mouseX = e.clientX;
      mouseY = e.clientY;
      core.style.left = mouseX + 'px';
      core.style.top = mouseY + 'px';
    });

    (function updateOrbit() {
      orbitX += (mouseX - orbitX) * 0.15;
      orbitY += (mouseY - orbitY) * 0.15;
      orbit.style.left = orbitX + 'px';
      orbit.style.top = orbitY + 'px';
      requestAnimationFrame(updateOrbit);
    })();
    (function updateTrail() {
      trailX += (mouseX - trailX) * 0.08;
      trailY += (mouseY - trailY) * 0.08;
      trail.style.left = trailX + 'px';
      trail.style.top = trailY + 'px';
      requestAnimationFrame(updateTrail);
    })();

    // hover states on interactive elements (delegated — survives Turbo swaps)
    document.addEventListener('mouseover', function (e) {
      var el = e.target.closest('a, button, input, select, textarea, label, tr.rowlink, .card');
      if (el) {
        orbit.style.borderColor = 'var(--accent)';
        orbit.style.width = '48px';
        orbit.style.height = '48px';
        core.style.background = 'var(--secondary)';
        core.style.boxShadow = '0 0 20px var(--secondary), 0 0 40px var(--secondary)';
      }
    });
    document.addEventListener('mouseout', function (e) {
      var el = e.target.closest('a, button, input, select, textarea, label, tr.rowlink, .card');
      if (el) {
        orbit.style.borderColor = 'var(--primary-light)';
        orbit.style.width = '36px';
        orbit.style.height = '36px';
        core.style.background = 'var(--accent)';
        core.style.boxShadow = '0 0 10px var(--accent)';
      }
    });
  }

  // ---------- button magnetic hover (Aether)
  // Magnetic buttons: a small pull toward the cursor.
  //
  // Two things were wrong before and both showed up as "the buttons move in
  // sync and it is distracting":
  //
  //  1. A per-element `mousemove` listener, bound once per button. Under Turbo
  //     navigation the same logical button is re-bound on every visit, so after
  //     a few page changes one mousemove fired N transforms at once. The
  //     `dataset.magnetic` guard does not help: Turbo replaces the body, so
  //     every visit lands on fresh elements with no flag set. The guard made it
  //     look handled while making it worse.
  //  2. `requestAnimationFrame` was not used, so a fast mouse produced a
  //     transform per event rather than one per frame.
  //
  // Now: ONE delegated listener on the document, so there is exactly one
  // handler no matter how many times the page is visited, and writes are
  // coalesced into a single rAF. Strength is also down from 0.15 to 0.08 --
  // enough to feel alive, not enough to pull a row of buttons out of alignment
  // with each other.
  var magneticState = { btn: null, x: 0, y: 0, frame: 0 };
  var MAGNETIC_STRENGTH = 0.08;

  function applyMagnetic() {
    magneticState.frame = 0;
    var btn = magneticState.btn;
    if (!btn) return;
    // The hover LIFT rides in this same transform. It has to: this inline value
    // beats the stylesheet, so a `.btn-primary:hover { transform: ... }` rule can
    // never apply to a magnetised button -- and since the magnetic offset is ~0
    // when the pointer sits at the button's centre, the hover state then had no
    // movement at all, only a shadow change, which read as "flat". Keep the -3px
    // and 1.03 in step with the :hover rule in application.css, which now serves
    // as the fallback for a button this never touches.
    btn.style.transform = 'translate(' + magneticState.x + 'px, '
      + (magneticState.y - 3) + 'px) scale(1.03)';
  }

  function magneticButtons() {
    // Resolution note: this replaces the per-button binding that was here
    // before, which bound one mousemove per element per page visit. The
    // `dataset.magnetic` guard could not prevent that -- Turbo replaces the
    // body, so every visit landed on fresh elements with no flag set -- so
    // after a few navigations one mousemove fired N transforms and a row of
    // buttons visibly moved in sync. One delegated listener cannot stack.
    //
    // Cleared with `transform = ''` rather than `translate(0,0)` on purpose:
    // any transform value, including the identity, makes the element a
    // stacking context, and a leftover one flips a `.btn-primary`'s
    // z-index:-1 glow ring from behind the button to over its fill -- so a
    // button looked subtly wrong for the rest of the session.
    if (magneticState.bound) return;
    magneticState.bound = '1';

    document.addEventListener('mousemove', function (e) {
      // Ignore non-primary buttons and touch, where there is no hover intent.
      if (e.buttons && e.buttons !== 1) return;
      var btn = e.target.closest ? e.target.closest('.btn') : null;
      if (!btn) {
        if (magneticState.btn) {
          magneticState.btn.style.transform = '';
          magneticState.btn = null;
        }
        return;
      }
      var rect = btn.getBoundingClientRect();
      magneticState.btn = btn;
      magneticState.x = (e.clientX - rect.left - rect.width / 2) * MAGNETIC_STRENGTH;
      magneticState.y = (e.clientY - rect.top - rect.height / 2) * MAGNETIC_STRENGTH;
      if (!magneticState.frame) {
        magneticState.frame = requestAnimationFrame(applyMagnetic);
      }
    }, { passive: true });

    // Leaving the document entirely must release the button, or a transform
    // can survive a scroll that moves the target out from under the cursor.
    document.addEventListener('mouseleave', function () {
      if (magneticState.btn) magneticState.btn.style.transform = '';
      magneticState.btn = null;
    });
  }

  // ---------- modal: blurred backdrop, glass panel, site aesthetic
  //
  // The modal owns the shared scroll lock. aether.js's popups delegate to these
  // two functions (aliased from this module), so the lock and the scrollbar
  // reservation live in ONE place, loaded by the login page as well as every
  // authed page. Writing `body.style.overflow` directly from the modal is what
  // #86 is about: `body { overflow: hidden }` is propagated to the viewport,
  // which REMOVES the viewport scrollbar and widens the viewport by the
  // scrollbar's width, so every `1fr` track on the page grows by a share of it
  // (#78). Reserving the width the scrollbar took with `padding-right` keeps the
  // body's content box the same width locked or not, so nothing shifts.
  function lockScroll() {
    if (document.body.style.overflow === 'hidden') return; // already locked, width already reserved
    var scrollbar = window.innerWidth - document.documentElement.clientWidth;
    document.body.style.overflow = 'hidden';
    if (scrollbar > 0) document.body.style.paddingRight = scrollbar + 'px';
  }

  // One lock serves every open overlay: closing one of two must not drop the
  // lock (and the reserved width) while the other is still up.
  function unlockScroll() {
    if (document.querySelector('.popup:not([hidden])')) return;
    if (document.querySelector('.cs-modal.open')) return;
    document.body.style.overflow = '';
    document.body.style.paddingRight = '';
  }

  // The focusables the Tab trap cycles among. `:not([disabled])` keeps a
  // disabled control out of the ring; `[tabindex]:not([tabindex="-1"])` keeps
  // programmatically-focusable-only nodes out.
  var CS_FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), ' +
    'select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

  function csFocusables(wrap) {
    // A control the browser cannot focus (display:none, visibility:hidden) must
    // stay out of the ring, or the trap wraps to it and focus is lost.
    return Array.prototype.slice.call(wrap.querySelectorAll(CS_FOCUSABLE)).filter(function (el) {
      var s = window.getComputedStyle(el);
      return s.display !== 'none' && s.visibility !== 'hidden';
    });
  }

  // Tab trap: while the modal is open, Tab and Shift+Tab cycle among the modal's
  // focusable controls instead of escaping to the page behind it.
  function csTrapTab(wrap, e) {
    if (e.key !== 'Tab' || !wrap.classList.contains('open')) return;
    var nodes = csFocusables(wrap);
    if (!nodes.length) { e.preventDefault(); return; }
    var first = nodes[0];
    var last = nodes[nodes.length - 1];
    var active = document.activeElement;
    if (e.shiftKey) {
      if (!wrap.contains(active) || active === first) { e.preventDefault(); last.focus(); }
    } else {
      if (!wrap.contains(active) || active === last) { e.preventDefault(); first.focus(); }
    }
  }

  function ensureModal() {
    if (document.getElementById('csModal')) return;
    var wrap = document.createElement('div');
    wrap.className = 'cs-modal';
    wrap.id = 'csModal';
    wrap.setAttribute('aria-hidden', 'true');
    wrap.innerHTML =
      '<div class="cs-modal-backdrop" data-cs-close="1"></div>' +
      '<div class="cs-modal-panel" role="dialog" aria-modal="true">' +
      '  <div class="cs-modal-head">' +
      '    <div class="cs-modal-title mono" id="csModalTitle"></div>' +
      '    <div class="cs-modal-actions">' +
      // Scissor orb, FIRST in the right-aligned row: "start a new job from this
      // file". Only shown when the opener supplied useUrl (today: the inverse
      // preview tile), so the popup never offers an action it cannot perform.
      '      <button class="btn btn-primary btn-scissor" id="csModalUse" type="button"' +
      '        title="Start a new job from this file" aria-label="Start a new job from this file">✂</button>' +
      '      <a class="btn btn-secondary btn-sm" id="csModalOpenTab" target="_blank" rel="noopener">Open in new tab ↗</a>' +
      '      <a class="btn btn-secondary btn-sm" id="csModalDownload" download>Download ⬇</a>' +
      '      <button class="btn btn-secondary btn-sm" id="csModalClose" data-cs-close="1" type="button">✕ Close</button>' +
      '    </div>' +
      '  </div>' +
      '  <div class="cs-modal-body" id="csModalBody"></div>' +
      '</div>';
    document.body.appendChild(wrap);

    wrap.addEventListener('click', function (e) {
      if (e.target.closest('[data-cs-close]') && !e.target.closest('.btn-primary')) {
        // don't close when clicking primary action buttons (Run back half etc.)
        if (!e.target.closest('form')) closeCsModal();
      }
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') closeCsModal();
    });
    // Tab must not escape the dialog while it is open.
    document.addEventListener('keydown', function (e) {
      csTrapTab(wrap, e);
    });

    wrap.addEventListener('click', function (e) {
      var use = e.target.closest('#csModalUse');
      if (use) {
        e.preventDefault();
        csUseAsSource(use.dataset.url);
        return;
      }
    });
  }

  // Hand the file currently in the popup to the new-job form as its artwork.
  // A real form POST rather than fetch, so the server's redirect lands the
  // operator on the job form with the file already attached; the CSRF token comes
  // from the page meta tag because this form is built in JS.
  function csUseAsSource(url) {
    if (!url) return;
    var token = document.querySelector('meta[name="csrf-token"]');
    var form = document.createElement('form');
    form.method = 'post';
    form.action = url;
    var input = document.createElement('input');
    input.type = 'hidden';
    input.name = 'authenticity_token';
    input.value = token ? token.getAttribute('content') : '';
    form.appendChild(input);
    document.body.appendChild(form);
    form.submit();
  }

  var csOnClose = null;

  function openCsModal(title, bodyHtml, options) {
    ensureModal();
    csOnClose = (options && typeof options.onClose === 'function') ? options.onClose : null;
    var wrap = document.getElementById('csModal');
    document.getElementById('csModalTitle').textContent = title;
    document.getElementById('csModalBody').innerHTML = bodyHtml;
    var useBtn = document.getElementById('csModalUse');
    if (options && options.useUrl) {
      useBtn.dataset.url = options.useUrl;
      useBtn.style.display = '';
    } else {
      useBtn.dataset.url = '';
      useBtn.style.display = 'none';
    }
    var tabLink = document.getElementById('csModalOpenTab');
    if (options && options.url) {
      tabLink.href = options.url;
      tabLink.style.display = '';
    } else {
      tabLink.style.display = 'none';
    }
    var dlLink = document.getElementById('csModalDownload');
    if (options && options.url) {
      dlLink.href = options.url;
      dlLink.setAttribute('download', options.filename || '');
      dlLink.style.display = '';
    } else {
      dlLink.style.display = 'none';
    }
    // Any popup whose body holds a single image gets the preview toolbox
    // (favourite / run again / reference / hue / save). That toolbox lives in
    // the site module, so it is reached through a hook rather than called here.
    if (previewBinder) previewBinder(options || {});
    wrap.classList.add('open');
    wrap.setAttribute('aria-hidden', 'false');
    lockScroll();
    // Focus the close control (the .popup convention) so keyboard and screen
    // reader users start inside the dialog, not on the page behind it.
    var closeBtn = wrap.querySelector('#csModalClose');
    if (closeBtn) closeBtn.focus();
  }

  function closeCsModal() {
    var wrap = document.getElementById('csModal');
    if (!wrap) return;
    wrap.classList.remove('open');
    wrap.setAttribute('aria-hidden', 'true');
    unlockScroll();
    var cb = csOnClose;
    csOnClose = null;
    if (cb) cb();
    // Run the site module's close hooks (e.g. dropping the viewer playlist with
    // the popup — csView lives in aether.js, not here, so the reset rides a hook).
    for (var k = 0; k < closeHooks.length; k++) closeHooks[k]();
  }
  // ---------- shared init: background, cursor, magnetic (core only)
  document.addEventListener('turbo:load', function () {
    ensureBackground();
    ensureCursor();
    magneticButtons();
  });

  document.addEventListener('DOMContentLoaded', function () {
    if (!window.Turbo) {
      ensureBackground();
      ensureCursor();
      magneticButtons();
    }
  });

  // Expose the glass modal for page-level scripts (the JSON page opens the
  // predefined-palettes library in it; the login page opens the password
  // gate). Bound at load, so page scripts that run before this module can
  // still reach it on click.
  window.CsModal = { open: openCsModal, close: closeCsModal };

  // Extension points the site module wires into. The modal and the preview
  // toolbox / viewer live in different modules, so the modal calls these
  // hooks instead of reaching into aether.js directly.
  var previewBinder = null;
  var closeHooks = [];

  return {
    openCsModal: openCsModal,
    closeCsModal: closeCsModal,
    lockScroll: lockScroll,
    unlockScroll: unlockScroll,
    ensureBackground: ensureBackground,
    ensureCursor: ensureCursor,
    magneticButtons: magneticButtons,
    setPreviewBinder: function (fn) { previewBinder = fn; },
    onClose: function (fn) { closeHooks.push(fn); }
  };
})();
