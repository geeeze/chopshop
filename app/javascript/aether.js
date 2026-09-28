// Aether engine: particles + orbs + gradient mesh + custom cursor.
// Extracted from Public/Aether.html, adapted for Turbo navigation.
(function () {
  'use strict';

  function isDesktop() {
    return window.matchMedia('(pointer: fine)').matches;
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
      this.x = Math.random() * canvas.width;
      this.y = Math.random() * canvas.height;
      this.size = Math.random() * 2 + 0.5;
      this.speedX = (Math.random() - 0.5) * 0.8;
      this.speedY = (Math.random() - 0.5) * 0.8;
      this.opacity = Math.random() * 0.6 + 0.1;
      this.color = ['#6366f1', '#ec4899', '#06b6d4', '#8b5cf6', '#10b981'][Math.floor(Math.random() * 5)];
    };
    Particle.prototype.update = function () {
      this.x += this.speedX;
      this.y += this.speedY;
      if (this.x < 0 || this.x > canvas.width) this.speedX *= -1;
      if (this.y < 0 || this.y > canvas.height) this.speedY *= -1;
      this.opacity = Math.sin(Date.now() * 0.001 + this.x) * 0.2 + 0.3;
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

    (function animate() {
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      particles.forEach(function (p) { p.update(); p.draw(); });
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

  // ---------- polling for in-flight jobs (no extra deps)
  //
  // The log console follows the newest output, tail -f style: every refresh
  // keeps the tail in view. Replacing innerHTML alone would snap the view back
  // to the TOP on every poll, which is precisely when the operator is trying to
  // read the newest lines — and would also throw away their position if they
  // scrolled up to read something. So: if they are at the bottom, stay at the
  // bottom; if they scrolled away, hold the position they chose.
  function bindLogFollow(box) {
    if (!box || box.dataset.followBound) return;
    box.dataset.followBound = '1';
    box.dataset.follow = '1';
    box.addEventListener('scroll', function () {
      // 8px tolerance: scrollTop rarely lands exactly on scrollHeight minus
      // clientHeight (fractional line heights, zoom), and a strict comparison
      // would silently stop following.
      var atBottom = box.scrollHeight - box.scrollTop - box.clientHeight <= 8;
      box.dataset.follow = atBottom ? '1' : '0';
    });
  }

  function refreshLogConsole(box, html) {
    if (!box) return;
    bindLogFollow(box);
    var following = box.dataset.follow === '1';
    var held = box.scrollTop;
    box.innerHTML = html;
    // Both writes happen in the same task, so the scroll event the browser
    // fires afterwards sees the final position — it cannot flip us out of
    // follow mode behind our own back.
    box.scrollTop = following ? box.scrollHeight : held;
  }

  function pollRunningJobs() {
    var el = document.querySelector('[data-poll-url]');
    if (!el) return;
    var url = el.dataset.pollUrl;
    var interval = parseInt(el.dataset.pollInterval || '2000', 10);
    if (el.dataset.polling) return;
    el.dataset.polling = '1';
    var timer = setInterval(function () {
      fetch(url, { headers: { Accept: 'application/json' } })
        .then(function (r) { return r.json(); })
        .then(function (data) {
          if (data.done) {
            clearInterval(timer);
            window.location.reload();
          } else if (data.log_html) {
            refreshLogConsole(document.getElementById('job-log'), data.log_html);
          }
        })
        .catch(function () { /* transient; keep polling */ });
    }, interval);
  }

  // ---------- modal: blurred backdrop, glass panel, site aesthetic
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
      '      <button class="btn btn-secondary btn-sm" data-cs-close="1" type="button">✕ Close</button>' +
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
    wrap.classList.add('open');
    wrap.setAttribute('aria-hidden', 'false');
    document.body.style.overflow = 'hidden';
  }

  function closeCsModal() {
    var wrap = document.getElementById('csModal');
    if (!wrap) return;
    wrap.classList.remove('open');
    wrap.setAttribute('aria-hidden', 'true');
    document.body.style.overflow = '';
    // Drop the playlist with the popup. The ←/→ handler only checks that *a*
    // modal is open, so a list left behind here would let the arrows step the
    // candidate sweep into whatever modal opens next (a manifest, say).
    csView.list = [];
    csView.i = 0;
    var cb = csOnClose;
    csOnClose = null;
    if (cb) cb();
  }

  // wires any [data-cs-view] element: opens its data-cs-view url in the modal
  // (SVG fetch → inline <img>, or manifest JSON pretty-print).
  //
  // An element carrying data-cs-group belongs to an ordered playlist (a job's
  // full candidate sweep, passed by the view as an escaped data-cs-playlist
  // attribute). Those open the stepped viewer instead: prev/next, ←/→ keys, and
  // the candidate's SVG source on show, because "which one is this?" is the
  // question the popup exists to answer.
  // Caches are module-level, so they outlive a single page only if Turbo is ever
  // enabled. csGroupCache is therefore self-validating (keyed by the raw payload,
  // not just the element id) — `id="cs-candidates"` is identical on every job's
  // page, so an id-keyed cache would serve job A's candidates while viewing job B.
  var csGroupCache = {};
  var csCodeCache = {};
  var csView = { list: [], i: 0, title: '' };

  function csReadGroup(id) {
    var node = document.getElementById(id);
    var raw = node ? (node.dataset.csPlaylist || node.textContent || '') : '';
    var hit = csGroupCache[id];
    // re-parse whenever the payload differs from what we cached
    if (hit !== undefined && hit.raw === raw) return hit.list;
    var list = null;
    if (raw) {
      try {
        var parsed = JSON.parse(raw);
        if (Object.prototype.toString.call(parsed) === '[object Array]' && parsed.length) list = parsed;
      } catch (e) { list = null; }
    }
    csGroupCache[id] = { raw: raw, list: list };
    return list;
  }

  // Minimal HTML-attribute/text escape for the strings the viewer splices into
  // markup. The candidate names come from the runner and the urls from Rails
  // path helpers, so this is defence in depth rather than a live hole — but a
  // filename is still external input and a quote in it would break the markup.
  function csEsc(value) {
    return String(value === null || value === undefined ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function csViewerHtml() {
    return '<div class="cs-viewer">' +
      '<div class="art-frame cs-modal-art"><img id="csViewerImg" alt="candidate"></div>' +
      '<div class="cs-viewer-bar">' +
      '  <button type="button" class="btn btn-secondary btn-sm" id="csPrev">‹ Prev</button>' +
      '  <span class="mono cs-nav-count" id="csNavCount"></span>' +
      '  <button type="button" class="btn btn-secondary btn-sm" id="csNext">Next ›</button>' +
      '  <button type="button" class="btn btn-secondary btn-sm" id="csCodeToggle">Code ▸</button>' +
      // Proof slot: filled per candidate by csShow(). A highlighted Proof
      // button for the one being viewed, because "run the back half on THIS
      // one" is the decision the sweep is for.
      '  <span class="cs-proof-slot" id="csProofSlot"></span>' +
      '</div>' +
      '<div class="cs-code-pane" id="csCodePane">' +
      '  <div class="cs-code-head"><span class="mono" id="csCodeName"></span>' +
      '    <button type="button" class="btn btn-secondary btn-sm" id="csCodeCopy">Copy</button></div>' +
      '  <pre id="csCodePre">loading…</pre>' +
      '</div>' +
      '</div>';
  }

  // The Proof submission for the candidate currently in the viewer. Posting a
  // real form (not fetch) keeps the redirect/back-half flow identical to the
  // per-row button_to, and the CSRF token comes from the page meta tag since
  // this form is built in JS.
  function csProofSlotHtml(item) {
    if (item.proof) {
      return '<a class="btn btn-secondary btn-sm cs-proof-link" href="' + csEsc(item.proof_url || '#') +
        '" download title="Download the proof PNG for ' + csEsc(item.file) + '">Proof ⬇</a>';
    }
    // NOT .cs-proof-btn: that class damps the ring to the sticky header's
    // subdued 0.62, which is right for the candidates TABLE (a column of them
    // is too much highlight at once) but wrong here. This is the only Proof
    // button on screen, so it gets the full-strength .btn-primary ring.
    return '<button type="button" class="btn btn-primary btn-sm cs-proof-run" id="csProofRun" ' +
      'title="Run the back half (Layer A + Layer B, proof + PDF) on ' + csEsc(item.file) + '">Proof</button>';
  }

  function csSubmitProof() {
    var item = csView.list[csView.i];
    var host = document.getElementById('cs-candidates');
    if (!item || !host) return;
    var url = host.dataset.csProofUrl;
    if (!url) return;
    var form = document.createElement('form');
    form.method = 'post';
    form.action = url;
    var fields = { authenticity_token: host.dataset.csCsrf,
                   job_id: host.dataset.csJob,
                   candidate_file: item.file };
    Object.keys(fields).forEach(function (k) {
      var input = document.createElement('input');
      input.type = 'hidden';
      input.name = k;
      input.value = fields[k] || '';
      form.appendChild(input);
    });
    document.body.appendChild(form);
    form.submit();
  }

  function csShow(index) {
    var n = csView.list.length;
    if (!n) return;
    // wrap at both ends so a sweep is a loop, not a dead end
    csView.i = ((index % n) + n) % n;
    var item = csView.list[csView.i];
    var img = document.getElementById('csViewerImg');
    if (img) img.src = item.url;
    var count = document.getElementById('csNavCount');
    if (count) count.textContent = (csView.i + 1) + ' / ' + n;
    var name = document.getElementById('csCodeName');
    if (name) name.textContent = item.file;
    document.getElementById('csModalTitle').textContent = item.file;
    var tabLink = document.getElementById('csModalOpenTab');
    if (tabLink) {
      tabLink.href = item.url;
      tabLink.style.display = '';
    }
    var dlLink = document.getElementById('csModalDownload');
    if (dlLink) {
      dlLink.href = item.url;
      dlLink.setAttribute('download', item.file || '');
      dlLink.style.display = '';
    }
    // Proof belongs to the candidate on screen, so it is re-rendered on every
    // step: a highlighted run button while there is no proof, a download link
    // once there is one.
    var slot = document.getElementById('csProofSlot');
    if (slot) slot.innerHTML = csProofSlotHtml(item);
    csLoadCode(item);
  }

  function csLoadCode(item) {
    var pre = document.getElementById('csCodePre');
    if (!pre) return;
    if (csCodeCache[item.url] !== undefined) {
      pre.textContent = csCodeCache[item.url];
      return;
    }
    pre.textContent = 'loading…';
    fetch(item.url)
      .then(function (r) { return r.text(); })
      .then(function (text) {
        csCodeCache[item.url] = text;
        // textContent, never innerHTML: runner-produced SVG must not execute here
        if (document.getElementById('csCodePre') && csView.list[csView.i] &&
            csView.list[csView.i].url === item.url) {
          pre.textContent = text;
        }
      })
      .catch(function () {
        if (document.getElementById('csCodePre')) pre.textContent = 'Could not load the source.';
      });
  }

  function openCsViewer(list, index) {
    csView.list = list;
    openCsModal('', csViewerHtml(), { url: list[index] ? list[index].url : '' });

    var body = document.getElementById('csModalBody');
    body.querySelector('#csPrev').addEventListener('click', function () { csShow(csView.i - 1); });
    body.querySelector('#csNext').addEventListener('click', function () { csShow(csView.i + 1); });

    var pane = body.querySelector('#csCodePane');
    var toggle = body.querySelector('#csCodeToggle');
    var viewer = body.querySelector('.cs-viewer');

    // The code pane opens COLLAPSED: the popup exists first of all to let the
    // operator see the candidate, and `.code-collapsed` is what gives the art
    // the large 62vh of its two heights. The source is one click away, and the
    // toggle advertises which way it goes.
    function setCodeCollapsed(collapsed) {
      if (!pane || !toggle) return;
      pane.style.display = collapsed ? 'none' : '';
      toggle.textContent = collapsed ? 'Code ▸' : 'Code ▾';
      toggle.setAttribute('aria-expanded', String(!collapsed));
      if (viewer) viewer.classList.toggle('code-collapsed', collapsed);
    }
    setCodeCollapsed(true);
    toggle.addEventListener('click', function () {
      setCodeCollapsed(pane.style.display !== 'none');
    });
    body.querySelector('#csCodeCopy').addEventListener('click', function () {
      var pre = document.getElementById('csCodePre');
      var btn = document.getElementById('csCodeCopy');
      if (!pre || !btn) return;
      // navigator.clipboard is undefined on a non-secure origin, so this has to
      // degrade rather than throw — the studio is served over plain http on the
      // LAN, not just on localhost.
      if (!navigator.clipboard) { btn.textContent = 'Copy unavailable'; return; }
      navigator.clipboard.writeText(pre.textContent).then(function () {
        btn.textContent = 'Copied ✓';
        setTimeout(function () { btn.textContent = 'Copy'; }, 1500);
      }).catch(function () {
        btn.textContent = 'Copy failed';
        setTimeout(function () { btn.textContent = 'Copy'; }, 1500);
      });
    });

    // Delegated, because the Proof slot is re-rendered on every step: a direct
    // listener would be lost each time csShow() replaces the button.
    body.addEventListener('click', function (e) {
      if (e.target.closest('#csProofRun')) {
        e.preventDefault();
        csSubmitProof();
      }
    });

    csShow(index);
  }

  // ←/→ step the sweep while the popup is open; typing in a field must not.
  document.addEventListener('keydown', function (e) {
    var wrap = document.getElementById('csModal');
    if (!wrap || !wrap.classList.contains('open') || !csView.list.length) return;
    // Only the stepped viewer has a nav row — if it isn't in the popup, the
    // arrows must stay inert (this also covers a modal opened over another).
    if (!document.getElementById('csPrev')) return;
    var tag = (e.target && e.target.tagName || '').toLowerCase();
    if (tag === 'input' || tag === 'textarea' || tag === 'select') return;
    if (e.key === 'ArrowLeft') { e.preventDefault(); csShow(csView.i - 1); }
    if (e.key === 'ArrowRight') { e.preventDefault(); csShow(csView.i + 1); }
  });

  function wireViewers() {
    document.querySelectorAll('[data-cs-view]').forEach(function (el) {
      if (el.dataset.csWired) return;
      el.dataset.csWired = '1';
      el.addEventListener('click', function (e) {
        // A click inside a form belongs to that form. The candidate rows carry
        // the viewer wiring, so without this the row handler would swallow the
        // submit of the "Run back half" button_to nested inside it. Anchors and
        // buttons (download / manifest / proof) must also win over the row's
        // viewer, so skip those too.
        //
        // Comparing against `el`: the wired element is ITSELF an anchor when it
        // is a preview tile, so a bare closest() check would reject the tile's
        // own click and the popup would never open. Only a NESTED interactive
        // element wins over the viewer.
        var interactive = e.target.closest('form, a, button');
        if (interactive && interactive !== el) return;
        e.preventDefault();
        e.stopPropagation();
        var kind = el.dataset.csView;          // "svg" | "json"
        var url  = el.dataset.csUrl;
        var title = el.dataset.csTitle || '';
        if (kind === 'svg') {
          var list = el.dataset.csGroup ? csReadGroup(el.dataset.csGroup) : null;
          var idx = parseInt(el.dataset.csIndex || '0', 10) || 0;
          if (list) {
            openCsViewer(list, Math.min(idx, list.length - 1));
          } else {
            openCsModal(title,
              '<div class="art-frame cs-modal-art cs-image-view"><img src="' + url + '" alt="candidate"></div>',
              { url: url, filename: title, useUrl: el.dataset.csUseUrl });
          }
        } else {
          openCsModal(title, '<div class="log-console" style="max-height:none;"><pre id="csJsonPre">loading…</pre></div>');
          fetch(url, { headers: { Accept: 'application/json' } })
            .then(function (r) { return r.json(); })
            .then(function (j) {
              document.getElementById('csJsonPre').textContent = JSON.stringify(j, null, 2);
            })
            .catch(function () {
              document.getElementById('csJsonPre').textContent = 'Could not load.';
            });
        }
      });
    });
  }

  // Confirm dialog on the jobs index (delete / cancel). Reuses the glass
  // modal; the header's Open/Download links are hidden because no URL is
  // passed, leaving just the message and Cancel / action buttons.
  function csConfirm(message, label, danger, onConfirm) {
    openCsModal('Confirm',
      '<div class="cs-confirm">' +
      '<p class="cs-confirm-msg">' + message + '</p>' +
      '<div class="cs-confirm-actions">' +
      '<button type="button" class="btn btn-secondary btn-sm" data-cs-close="1">Cancel</button>' +
      '<button type="button" class="btn btn-sm ' + (danger ? 'btn-danger' : 'btn-primary') + '" id="csConfirmOk">' + label + '</button>' +
      '</div></div>');
    var ok = document.getElementById('csConfirmOk');
    if (ok) ok.addEventListener('click', function () {
      closeCsModal();
      if (onConfirm) onConfirm();
    });
  }

  function wireJobActions() {
    document.querySelectorAll('button[data-cs-job-action]').forEach(function (btn) {
      if (btn.dataset.csWired) return;
      btn.dataset.csWired = '1';
      btn.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        var action = btn.dataset.csJobAction; // "cancel" | "delete"
        var name = btn.dataset.csName || 'this job';
        var danger = action === 'delete';
        var msg = danger
          ? 'Delete "' + name + '"? This removes the job and its files permanently.'
          : 'Cancel "' + name + '"? Any in-flight work is stopped.';
        csConfirm(msg, danger ? 'Delete' : 'Cancel job', danger, function () {
          var token = document.querySelector('meta[name="csrf-token"]');
          fetch(btn.dataset.url, {
            method: danger ? 'DELETE' : 'POST',
            headers: {
              'X-CSRF-Token': token ? token.getAttribute('content') : '',
              'Accept': 'application/json'
            },
            credentials: 'same-origin'
          }).then(function () {
            window.location.reload();
          }).catch(function () {
            window.location.reload();
          });
        });
      });
    });
  }

  // ---------- scrapbook sidebar ----------
  //
  // A left drawer of favourited sources/inverts/candidates/proofs. It is its own
  // store (storage/scrapbook) and survives deleting the jobs it came from. The
  // drawer and the toggle are in the layout, so they exist on every authed page;
  // the favourite buttons are per-view but speak one delegated listener here.
  var scrapbookBound = false;

  function scrapbookInit() {
    if (scrapbookBound) return;
    scrapbookBound = true;

    var toggle = document.getElementById('scrapbookToggle');
    var sidebar = document.getElementById('scrapbookSidebar');
    if (!toggle || !sidebar) return;

    // The drawer SHARES the screen with the page: while it is open, the nav,
    // main and footer are padded left by its width so the content slides aside
    // instead of being covered. A `scrapbook-open` class on BODY is the whole
    // mechanism, and it is also what hides the star — the toggle is the drawer's
    // opener, so leaving it on screen means a fixed handle floating over the
    // drawer it just opened. The width is read from the drawer's own box and
    // published as --scrapbook-w, so the padding and the drawer cannot drift.
    function syncWidth() {
      var w = Math.round(sidebar.getBoundingClientRect().width);
      if (w > 0) document.documentElement.style.setProperty('--scrapbook-w', w + 'px');
    }

    function open() {
      syncWidth();
      sidebar.classList.add('open');
      sidebar.setAttribute('aria-hidden', 'false');
      toggle.setAttribute('aria-expanded', 'true');
      document.body.classList.add('scrapbook-open');
      loadScrapbook();
    }
    function close() {
      sidebar.classList.remove('open');
      sidebar.setAttribute('aria-hidden', 'true');
      toggle.setAttribute('aria-expanded', 'false');
      document.body.classList.remove('scrapbook-open');
    }

    toggle.addEventListener('click', function () {
      if (sidebar.classList.contains('open')) close(); else open();
    });

    sidebar.addEventListener('click', function (e) {
      if (e.target.closest('[data-scrap-close]')) { close(); return; }
      var del = e.target.closest('[data-scrap-delete]');
      if (del) { scrapDelete(del); return; }
      var trace = e.target.closest('[data-scrap-trace]');
      if (trace) { scrapTrace(trace); return; }
      var edit = e.target.closest('[data-scrap-edit]');
      if (edit) { scrapOpenEditor(edit.getAttribute('data-url'), edit.getAttribute('data-name')); return; }
      var view = e.target.closest('[data-scrap-view]');
      if (view) { scrapView(view); return; }
    });

    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && sidebar.classList.contains('open')) close();
    });

    // One delegated listener for every favourite button on the page. Bound once
    // rather than per button, so a full page of candidate rows does not stack N
    // handlers (the same rule the magnetic buttons learned).
    document.addEventListener('click', function (e) {
      var btn = e.target.closest('[data-scrap-favourite]');
      if (!btn) return;
      e.preventDefault();
      e.stopPropagation();
      scrapFavourite(btn);
    });
  }

  function scrapEsc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function scrapFavourite(btn) {
    var job = btn.getAttribute('data-scrap-job');
    var name = btn.getAttribute('data-scrap-name');
    var token = document.querySelector('meta[name="csrf-token"]');
    btn.disabled = true;
    fetch('/scrapbook', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': token ? token.content : ''
      },
      credentials: 'same-origin',
      body: JSON.stringify({ job_id: job, name: name })
    })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (res) {
        btn.disabled = false;
        if (!res.ok) {
          btn.classList.add('fav-failed');
          setTimeout(function () { btn.classList.remove('fav-failed'); }, 1500);
          return;
        }
        btn.classList.add('fav-done');
        setTimeout(function () { btn.classList.remove('fav-done'); }, 1500);
        loadScrapbook();
      })
      .catch(function () {
        btn.disabled = false;
        btn.classList.add('fav-failed');
        setTimeout(function () { btn.classList.remove('fav-failed'); }, 1500);
      });
  }

  function loadScrapbook() {
    var body = document.getElementById('scrapbookBody');
    if (!body) return;
    fetch('/scrapbook', { headers: { Accept: 'application/json' }, credentials: 'same-origin' })
      .then(function (r) { return r.json(); })
      .then(function (items) { renderScrapbook(body, items); })
      .catch(function () {
        body.innerHTML = '<p class="scrapbook-empty">Could not load the scrapbook.</p>';
      });
  }

  function renderScrapbook(body, items) {
    if (!items || !items.length) {
      body.innerHTML = '<p class="scrapbook-empty">Nothing favourited yet. ' +
        'Use the &#9734; on a source, invert, candidate or proof to keep it here.</p>';
      return;
    }
    var html = '<div class="scrap-grid">';
    items.forEach(function (it) {
      html += '<div class="scrap-item" data-scrap-id="' + scrapEsc(it.id) + '">' +
        '<button type="button" class="scrap-thumb" data-scrap-view data-url="' + scrapEsc(it.url) + '" data-name="' + scrapEsc(it.name) + '" title="' + scrapEsc(it.name) + ' — view">' +
        '<img src="' + scrapEsc(it.url) + '" alt="' + scrapEsc(it.name) + '" loading="lazy">' +
        '</button>' +
        '<div class="scrap-name mono" title="' + scrapEsc(it.name) + '">' + scrapEsc(it.name) + '</div>' +
        '<div class="scrap-actions">' +
        '<span class="scrap-kind">' + scrapEsc(it.kind) + '</span>' +
        '<button type="button" class="btn btn-secondary btn-sm" data-scrap-trace data-id="' + scrapEsc(it.id) + '" title="Trace as a new job">Trace</button>' +
        '<button type="button" class="btn btn-secondary btn-sm" data-scrap-edit data-url="' + scrapEsc(it.url) + '" data-name="' + scrapEsc(it.name) + '" title="Edit — crop, erase, colour shift">Edit</button>' +
        '<button type="button" class="btn btn-icon" data-scrap-delete data-id="' + scrapEsc(it.id) + '" title="Remove from scrapbook" aria-label="Remove ' + scrapEsc(it.name) + '">✕</button>' +
        '</div>' +
        '</div>';
    });
    html += '</div>';
    body.innerHTML = html;
  }

  function scrapView(el) {
    var url = el.getAttribute('data-url');
    var name = el.getAttribute('data-name') || '';
    if (window.CsModal) {
      window.CsModal.open(name,
        '<div class="art-frame cs-modal-art cs-image-view"><img src="' + scrapEsc(url) + '" alt="' + scrapEsc(name) + '"></div>',
        { url: url, filename: name });
    }
  }

  function scrapDelete(el) {
    var id = el.getAttribute('data-id');
    var token = document.querySelector('meta[name="csrf-token"]');
    fetch('/scrapbook/' + encodeURIComponent(id), {
      method: 'DELETE',
      headers: { 'X-CSRF-Token': token ? token.content : '', 'Accept': 'application/json' },
      credentials: 'same-origin'
    }).then(function () { loadScrapbook(); })
      .catch(function () { loadScrapbook(); });
  }

  function scrapTrace(el) {
    var id = el.getAttribute('data-id');
    var token = document.querySelector('meta[name="csrf-token"]');
    // A real form POST, not fetch: the server's redirect lands on the new-job
    // form with the file already attached, same as the inverse-twin carry.
    var form = document.createElement('form');
    form.method = 'post';
    form.action = '/scrapbook/' + encodeURIComponent(id) + '/use';
    var input = document.createElement('input');
    input.type = 'hidden';
    input.name = 'authenticity_token';
    input.value = token ? token.content : '';
    form.appendChild(input);
    document.body.appendChild(form);
    form.submit();
  }

  // ---------- scrapbook image editor ----------
  //
  // A single-image editor over a scrapbook item: crop (drag a rectangle),
  // erase (paint transparent PNG), and a hue-rotate colour shift. "Save to
  // scrapbook" exports the result as a new PNG item via /scrapbook/import.
  // This is the SURFACE editing the operator asked for — crop / cut / paste /
  // erase / colour shift — not the compositor: layering, resize/reposition and
  // the composite builder are a separate feature. The hue shift is a view
  // transform on the working canvas, baked into the export at save time; crop
  // and erase mutate the base, so they compose in any order.
  var scrapEditor = { work: null, tool: 'crop', hue: 0, srcUrl: '', srcName: '',
                      dragging: false, sx: 0, sy: 0, cx: 0, cy: 0, last: null };

  function scrapEditorHtml() {
    return '<div class="scrap-editor">' +
      '<div class="scrap-editor-tools">' +
      '  <button type="button" class="btn btn-secondary btn-sm active" data-scrap-tool="crop">Crop</button>' +
      '  <button type="button" class="btn btn-secondary btn-sm" data-scrap-tool="erase">Erase</button>' +
      '  <label class="scrap-hue mono">hue <input type="range" id="scrapHue" min="0" max="360" step="1" value="0"><span id="scrapHueVal">0°</span></label>' +
      '  <button type="button" class="btn btn-secondary btn-sm" data-scrap-reset>Reset</button>' +
      '  <button type="button" class="btn btn-primary btn-sm" id="scrapSave">Save to scrapbook</button>' +
      '</div>' +
      '<div class="scrap-editor-stage"><canvas id="scrapCanvas"></canvas></div>' +
      '<div class="scrap-editor-hint mono" id="scrapEditorHint"></div>' +
      '</div>';
  }

  function scrapOpenEditor(url, name) {
    if (!window.CsModal) return;
    scrapEditor.srcUrl = url;
    scrapEditor.srcName = name || '';
    scrapEditor.tool = 'crop';
    scrapEditor.hue = 0;
    window.CsModal.open('Edit — ' + scrapEditor.srcName, scrapEditorHtml(), {});
    scrapLoadEditorImage(url, name);
    scrapBindEditor(name);
  }

  function scrapLoadEditorImage(url, name) {
    var hint = document.getElementById('scrapEditorHint');
    if (hint) hint.textContent = 'loading…';
    var img = new Image();
    img.onload = function () {
      var maxDim = 1200;
      var w = img.naturalWidth, h = img.naturalHeight;
      var ratio = Math.min(1, maxDim / Math.max(w, h));
      w = Math.max(1, Math.round(w * ratio));
      h = Math.max(1, Math.round(h * ratio));
      var work = document.createElement('canvas');
      work.width = w; work.height = h;
      work.getContext('2d').drawImage(img, 0, 0, w, h);
      scrapEditor.work = work;
      scrapEditor.hue = 0;
      var range = document.getElementById('scrapHue');
      if (range) range.value = 0;
      var val = document.getElementById('scrapHueVal');
      if (val) val.textContent = '0°';
      var canvas = document.getElementById('scrapCanvas');
      if (canvas) { canvas.width = work.width; canvas.height = work.height; }
      redrawEditor();
      if (hint) { hint.textContent = 'drag to crop · choose Erase to paint transparent · hue shifts colour'; hint.style.color = ''; }
    };
    img.onerror = function () { if (hint) hint.textContent = 'could not load the image.'; };
    img.src = url;
  }

  function editorPoint(e) {
    var canvas = document.getElementById('scrapCanvas');
    var r = canvas.getBoundingClientRect();
    var scale = canvas.width / r.width;
    return { x: (e.clientX - r.left) * scale, y: (e.clientY - r.top) * scale };
  }

  function redrawEditor() {
    var canvas = document.getElementById('scrapCanvas');
    var work = scrapEditor.work;
    if (!canvas || !work) return;
    var ctx = canvas.getContext('2d');
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    if (scrapEditor.hue) ctx.filter = 'hue-rotate(' + scrapEditor.hue + 'deg)';
    else ctx.filter = 'none';
    ctx.drawImage(work, 0, 0);
    ctx.filter = 'none';
    if (scrapEditor.tool === 'crop' && scrapEditor.dragging) {
      var x = Math.min(scrapEditor.sx, scrapEditor.cx);
      var y = Math.min(scrapEditor.sy, scrapEditor.cy);
      var w = Math.abs(scrapEditor.cx - scrapEditor.sx);
      var h = Math.abs(scrapEditor.cy - scrapEditor.sy);
      ctx.fillStyle = 'rgba(99, 102, 241, 0.12)';
      ctx.fillRect(x, y, w, h);
      ctx.strokeStyle = 'rgba(99, 102, 241, 0.9)';
      ctx.lineWidth = 2;
      ctx.strokeRect(x, y, w, h);
    }
  }

  function applyCrop() {
    var work = scrapEditor.work;
    var x = Math.min(scrapEditor.sx, scrapEditor.cx);
    var y = Math.min(scrapEditor.sy, scrapEditor.cy);
    var w = Math.abs(scrapEditor.cx - scrapEditor.sx);
    var h = Math.abs(scrapEditor.cy - scrapEditor.sy);
    scrapEditor.dragging = false;
    if (w < 4 || h < 4) { redrawEditor(); return; }
    var next = document.createElement('canvas');
    next.width = Math.round(w); next.height = Math.round(h);
    next.getContext('2d').drawImage(work, x, y, w, h, 0, 0, next.width, next.height);
    scrapEditor.work = next;
    var canvas = document.getElementById('scrapCanvas');
    if (canvas) { canvas.width = next.width; canvas.height = next.height; }
    redrawEditor();
  }

  function eraseAt(p, last) {
    var work = scrapEditor.work;
    if (!work) return;
    var ctx = work.getContext('2d');
    var r = Math.max(4, work.width / 60);
    ctx.save();
    ctx.globalCompositeOperation = 'destination-out';
    if (last && (p.x !== last.x || p.y !== last.y)) {
      ctx.strokeStyle = 'rgba(0,0,0,1)';
      ctx.lineWidth = r * 2;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      ctx.beginPath();
      ctx.moveTo(last.x, last.y);
      ctx.lineTo(p.x, p.y);
      ctx.stroke();
    } else {
      ctx.fillStyle = 'rgba(0,0,0,1)';
      ctx.beginPath();
      ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
  }

  function scrapBindEditor(name) {
    var body = document.getElementById('csModalBody');
    if (!body || body.dataset.scrapEditorBound) return;
    body.dataset.scrapEditorBound = '1';
    var canvas = document.getElementById('scrapCanvas');

    canvas.addEventListener('pointerdown', function (e) {
      e.preventDefault();
      canvas.setPointerCapture(e.pointerId);
      var p = editorPoint(e);
      if (scrapEditor.tool === 'crop') {
        scrapEditor.sx = p.x; scrapEditor.sy = p.y;
        scrapEditor.cx = p.x; scrapEditor.cy = p.y;
        scrapEditor.dragging = true;
      } else {
        scrapEditor.last = p;
        eraseAt(p, null);
        redrawEditor();
      }
    });
    canvas.addEventListener('pointermove', function (e) {
      if (scrapEditor.tool === 'crop' && scrapEditor.dragging) {
        var p = editorPoint(e);
        scrapEditor.cx = p.x; scrapEditor.cy = p.y;
        redrawEditor();
      } else if (scrapEditor.tool === 'erase' && scrapEditor.last) {
        var q = editorPoint(e);
        eraseAt(q, scrapEditor.last);
        scrapEditor.last = q;
        redrawEditor();
      }
    });
    canvas.addEventListener('pointerup', function () {
      if (scrapEditor.tool === 'crop' && scrapEditor.dragging) applyCrop();
      scrapEditor.last = null;
    });

    body.addEventListener('click', function (e) {
      var tool = e.target.closest('[data-scrap-tool]');
      if (tool) {
        scrapEditor.tool = tool.getAttribute('data-scrap-tool');
        body.querySelectorAll('[data-scrap-tool]').forEach(function (b) { b.classList.remove('active'); });
        tool.classList.add('active');
        return;
      }
      if (e.target.closest('[data-scrap-reset]')) {
        scrapLoadEditorImage(scrapEditor.srcUrl, scrapEditor.srcName);
        return;
      }
      if (e.target.closest('#scrapSave')) { scrapSave(); return; }
    });

    body.addEventListener('input', function (e) {
      if (e.target.id === 'scrapHue') {
        scrapEditor.hue = parseInt(e.target.value, 10) || 0;
        document.getElementById('scrapHueVal').textContent = scrapEditor.hue + '°';
        redrawEditor();
      }
    });
  }

  function scrapSave() {
    var work = scrapEditor.work;
    if (!work) return;
    var out = document.createElement('canvas');
    out.width = work.width; out.height = work.height;
    var ctx = out.getContext('2d');
    if (scrapEditor.hue) ctx.filter = 'hue-rotate(' + scrapEditor.hue + 'deg)';
    ctx.drawImage(work, 0, 0);
    ctx.filter = 'none';
    var hint = document.getElementById('scrapEditorHint');
    out.toBlob(function (blob) {
      if (!blob) { if (hint) hint.textContent = 'export failed'; return; }
      var fd = new FormData();
      fd.append('file', blob, 'edited.png');
      var token = document.querySelector('meta[name="csrf-token"]');
      if (hint) { hint.textContent = 'saving…'; hint.style.color = ''; }
      fetch('/scrapbook/import', {
        method: 'POST',
        headers: { 'X-CSRF-Token': token ? token.content : '', 'Accept': 'application/json' },
        credentials: 'same-origin',
        body: fd
      })
        .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
        .then(function (res) {
          if (!res.ok) {
            if (hint) { hint.textContent = res.j.error || 'save failed'; hint.style.color = 'var(--danger)'; }
            return;
          }
          if (hint) { hint.textContent = 'saved to scrapbook'; hint.style.color = 'var(--success)'; }
          loadScrapbook();
        })
        .catch(function () {
          if (hint) { hint.textContent = 'save failed'; hint.style.color = 'var(--danger)'; }
        });
    }, 'image/png');
  }

  // close the runner dropdown when clicking anywhere outside it
  document.addEventListener('click', function (e) {
    document.querySelectorAll('details.runner-menu[open]').forEach(function (d) {
      if (!d.contains(e.target)) d.removeAttribute('open');
    });
  });

  document.addEventListener('turbo:load', function () {
    ensureBackground();
    ensureCursor();
    magneticButtons();
    pollRunningJobs();
    wireViewers();
    wireJobActions();
    scrapbookInit();
  });

  // Inert without Turbo (the importmap does not pin it, so this never fires),
  // but correct the moment someone adds the pin: a re-run rewrites
  // candidate_NN.svg at an unchanged URL, so a surviving code cache would show
  // the previous run's source.
  document.addEventListener('turbo:before-cache', function () {
    csCodeCache = {};
    csGroupCache = {};
  });
  // ---------- welcome typewriter overlay (post-login) ----------
  function typedWelcome() {
    var overlay = document.getElementById('welcomeOverlay');
    var el = document.getElementById('welcomeType');
    if (!overlay || !el) return;
    var text = 'Welcome to Chopshop Studio';
    var i = 0;
    var timer = null;
    var done = false;

    function dismiss() {
      if (done) return;
      done = true;
      if (timer) clearInterval(timer);
      overlay.classList.add('welcome-out');
      setTimeout(function () { overlay.remove(); }, 420);
    }

    timer = setInterval(function () {
      i++;
      el.textContent = text.slice(0, i);
      if (i >= text.length) {
        clearInterval(timer);
        timer = null;
        setTimeout(dismiss, 1600);
      }
    }, 55);

    overlay.addEventListener('click', dismiss);
    document.addEventListener('keydown', function h() {
      dismiss();
      document.removeEventListener('keydown', h);
    });
  }

  // ---------------------------------------------------------------- popups
  // Any element with data-popup="<id>" opens that dialog. The Ask Jev button
  // also
  // POSTs first and renders the reply into the dialog, so one button both asks
  // and shows. Delegated, so it survives Turbo navigation without rebinding.
  function openPopup(id) {
    var el = document.getElementById(id);
    if (!el) return;
    el.hidden = false;
    document.body.style.overflow = 'hidden';
    var close = el.querySelector('[data-popup-close]');
    if (close) close.focus();
  }

  function closePopup(el) {
    if (!el) return;
    el.hidden = true;
    document.body.style.overflow = '';
  }

  function renderJevCards(data) {
    var esc = function (s) {
      var d = document.createElement('div');
      d.textContent = s == null ? '' : String(s);
      return d.innerHTML;
    };
    var html = '';
    var v = (data.meta && data.meta.verdict) || null;
    if (v && v.headline) {
      html += '<p class="jev-verdict mono">' + esc(v.headline);
      if (v.print_route) html += ' &middot; route ' + esc(v.print_route);
      if (v.low_confidence && v.low_confidence.length) {
        html += ' &middot; low confidence: ' + esc(v.low_confidence.join(', '));
      }
      html += '</p>';
    }
    html += '<div class="jev-grid">';
    (data.cards || []).forEach(function (c) {
      html += '<div class="jev-card"><div class="q">' + esc(c.question) + '</div>';
      html += '<div class="a">' + esc(c.value) + '</div>';
      if (c.note) html += '<div class="note">' + esc(c.note) + '</div>';
      if (c.confidence != null) {
        html += '<div class="conf">confidence ' + esc(Math.round(c.confidence * 100)) + '%</div>';
      }
      html += '</div>';
    });
    html += '</div>';
    var m = data.meta || {};
    if (m.model) {
      html += '<p class="mono" style="color:var(--text-tertiary);font-size:0.72rem;margin-top:0.75rem;">'
        + esc(m.model) + ' &middot; ' + esc(m.endpoint) + ' &middot; ' + esc(m.latency_ms) + 'ms</p>';
    }
    return html;
  }

  function wirePopups() {
    // A validation that already has recorded answers marks its Ask Jev button
    // on load, so the title line says Jev has spoken before you click it --
    // otherwise the green state only ever appears in the session that asked.
    // Any Jev button whose validation already carries answers gets the green
    // state on load, wherever it sits -- the jobs page puts them on popup rows,
    // not in a .page-head-line.
    document.querySelectorAll('.jev-btn[data-jev-url]').forEach(function (b) {
      if (b.dataset.hasAnswers === '1') b.classList.add('has-answers');
    });

    document.addEventListener('click', function (ev) {
      var trigger = ev.target.closest('[data-popup]');
      if (trigger) {
        ev.preventDefault();
        var id = trigger.getAttribute('data-popup');
        var dialog = document.getElementById(id);
        openPopup(id);
        // Ask Jev on open, unless answers are already on the page. A validation
        // whose answers already exist (data-has-answers="1") has the reply
        // pre-rendered into the dialog by the server, so opening it just shows
        // those answers — no second POST.
        // Detect the Jev dialog by its body slot, not by the id 'jev-popup':
        // the jobs page renders one dialog per proof row (jev-popup-<id>), so
        // a single hardcoded id left every row past the first dead.
        if (dialog && dialog.querySelector('[data-jev-body]') && trigger.dataset.jevUrl
            && !dialog.dataset.asked && trigger.dataset.hasAnswers !== '1') {
          askJev(trigger, dialog);
        }
        return;
      }
      // "?" buttons beside section headings: surface that section's deep field
      // notes in the glass modal. Delegated so it works on every page without
      // per-page wiring; the notes live in a hidden <dl> keyed by the button's
      // data-help-target.
      var help = ev.target.closest('.help-btn[data-help-target]');
      if (help) {
        ev.preventDefault();
        var notes = document.getElementById(help.dataset.helpTarget);
        if (notes) {
          openCsModal(help.dataset.helpTitle || 'Notes', notes.innerHTML);
        }
        return;
      }
      if (ev.target.closest('[data-popup-close]')) {
        ev.preventDefault();
        closePopup(ev.target.closest('.popup'));
        return;
      }
      // Backdrop click closes; clicks inside the panel must not.
      var pop = ev.target.closest('.popup');
      if (pop && ev.target === pop) { closePopup(pop); return; }
    });

    // Escape closes the open popup. A keydown listener, not a click one: a
    // click event has no `.key`, so the check inside the click handler above
    // was dead code and Escape never closed anything.
    document.addEventListener('keydown', function (ev) {
      if (ev.key === 'Escape') {
        var open = document.querySelector('.popup:not([hidden])');
        if (open) closePopup(open);
      }
    });
  }

  function askJev(trigger, dialog) {
    var body = dialog.querySelector('[data-jev-body]');
    trigger.classList.add('is-busy');
    trigger.setAttribute('aria-busy', 'true');
    body.innerHTML = '<p class="popup-empty">Asking Jev&hellip;</p>';
    var token = document.querySelector('meta[name="csrf-token"]');
    fetch(trigger.dataset.jevUrl, {
      method: 'POST',
      headers: {
        'Accept': 'application/json',
        'X-CSRF-Token': trigger.dataset.jevCsrf || (token && token.content) || '',
        'X-Requested-With': 'XMLHttpRequest'
      },
      credentials: 'same-origin'
    })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (res) {
        trigger.classList.remove('is-busy');
        trigger.removeAttribute('aria-busy');
        if (!res.ok) {
          body.innerHTML = '<p class="popup-empty" style="color:var(--danger);">'
            + (res.j.error || 'Jev call failed.') + '</p>';
          return;
        }
        dialog.dataset.asked = '1';
        trigger.classList.add('has-answers');
        body.innerHTML = renderJevCards(res.j);
      })
      .catch(function (err) {
        trigger.classList.remove('is-busy');
        body.innerHTML = '<p class="popup-empty" style="color:var(--danger);">'
          + String(err) + '</p>';
      });
  }

  // ---------- lift every popup out of .container and onto <body>
  //
  // `main.container` is `position: relative; z-index: 1`, which is what keeps
  // page content above the background orbs and canvases (all z-index: 0). It
  // also makes .container a STACKING CONTEXT, and a modal's z-index is then
  // scoped inside it -- so a popup at z-index 9600 competes only against its
  // siblings in that context and loses to the plain z-index:100 sticky header,
  // which sits outside it. Measured: the popup painted UNDER the topbar, and
  // under the first-run welcome overlay at z-index 9500, despite 9600.
  //
  // Raising .container instead would put the whole page above the header, and
  // dropping its z-index would drop the content behind the orbs. So the popup
  // moves: position:fixed already means it is anchored to the viewport, not to
  // its parent, so relocating it changes nothing about where it draws -- only
  // which stacking context it competes in.
  //
  // Done here, once, for every page, rather than per template. Ids are
  // unchanged, so the inline page scripts that look them up still find them.
  function portalPopups() {
    var popups = document.querySelectorAll('main .popup, .container .popup');
    for (var i = 0; i < popups.length; i++) {
      if (popups[i].parentElement !== document.body) {
        document.body.appendChild(popups[i]);
      }
    }
  }

  document.addEventListener('DOMContentLoaded', function () {
    wirePopups();
    portalPopups();
    if (!window.Turbo) {
      ensureBackground();
      ensureCursor();
      magneticButtons();
      pollRunningJobs();
      wireViewers();
      wireJobActions();
      scrapbookInit();
      typedWelcome();
    }
  });

  // Expose the glass modal for page-level scripts (the JSON page opens the
  // predefined-palettes library in it). Bound at load, so page scripts that
  // run before this module can still reach it on click.
  window.CsModal = { open: openCsModal, close: closeCsModal };
})();
