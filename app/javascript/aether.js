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

  function startParticles(canvas) {
    var ctx = canvas.getContext('2d');
    var particles = [];

    function resize() {
      canvas.width = window.innerWidth;
      canvas.height = window.innerHeight;
    }
    resize();
    window.addEventListener('resize', resize);

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

    for (var i = 0; i < 120; i++) particles.push(new Particle());

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
    function resize() {
      canvas.width = window.innerWidth;
      canvas.height = window.innerHeight;
    }
    resize();
    window.addEventListener('resize', resize);

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
    btn.style.transform = 'translate(' + magneticState.x + 'px, '
      + magneticState.y + 'px)';
  }

  function magneticButtons() {
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
  }

  var csOnClose = null;

  function openCsModal(title, bodyHtml, options) {
    ensureModal();
    csOnClose = (options && typeof options.onClose === 'function') ? options.onClose : null;
    var wrap = document.getElementById('csModal');
    document.getElementById('csModalTitle').textContent = title;
    document.getElementById('csModalBody').innerHTML = bodyHtml;
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
              '<div class="art-frame cs-modal-art"><img src="' + url + '" alt="candidate"></div>', { url: url, filename: title });
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
    document.querySelectorAll('.jev-btn[data-jev-url]').forEach(function (b) {
      if (b.closest('.page-head-line') && b.dataset.hasAnswers === '1') {
        b.classList.add('has-answers');
      }
    });

    document.addEventListener('click', function (ev) {
      var trigger = ev.target.closest('[data-popup]');
      if (trigger) {
        ev.preventDefault();
        var id = trigger.getAttribute('data-popup');
        var dialog = document.getElementById(id);
        openPopup(id);
        // Ask Jev on open, unless answers are already on the page.
        if (dialog && dialog.id === 'jev-popup' && trigger.dataset.jevUrl
            && !dialog.dataset.asked) {
          askJev(trigger, dialog);
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

  document.addEventListener('DOMContentLoaded', function () {
    wirePopups();
    if (!window.Turbo) {
      ensureBackground();
      ensureCursor();
      magneticButtons();
      pollRunningJobs();
      wireViewers();
      wireJobActions();
      typedWelcome();
    }
  });

  // Expose the glass modal for page-level scripts (the JSON page opens the
  // predefined-palettes library in it). Bound at load, so page scripts that
  // run before this module can still reach it on click.
  window.CsModal = { open: openCsModal, close: closeCsModal };
})();
