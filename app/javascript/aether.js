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
          var dist = Math.sqrt(dx * dx + dy * dy);
          if (dist < 200) {
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
  function magneticButtons() {
    document.querySelectorAll('.btn').forEach(function (btn) {
      if (btn.dataset.magnetic) return;
      btn.dataset.magnetic = '1';
      btn.addEventListener('mousemove', function (e) {
        var rect = btn.getBoundingClientRect();
        var x = e.clientX - rect.left - rect.width / 2;
        var y = e.clientY - rect.top - rect.height / 2;
        btn.style.transform = 'translate(' + x * 0.15 + 'px, ' + y * 0.15 + 'px)';
      });
      btn.addEventListener('mouseleave', function () {
        btn.style.transform = 'translate(0, 0)';
      });
    });
  }

  // ---------- polling for in-flight jobs (no extra deps)
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
            var box = document.getElementById('job-log');
            if (box) box.innerHTML = data.log_html;
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

  function openCsModal(title, bodyHtml, options) {
    ensureModal();
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
  }

  // wires any [data-cs-view] element: opens its data-cs-view url in the modal
  // (SVG fetch → inline <img>, or manifest JSON pretty-print).
  function wireViewers() {
    document.querySelectorAll('[data-cs-view]').forEach(function (el) {
      if (el.dataset.csWired) return;
      el.dataset.csWired = '1';
      el.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        var kind = el.dataset.csView;          // "svg" | "json"
        var url  = el.dataset.csUrl;
        var title = el.dataset.csTitle || '';
        if (kind === 'svg') {
          openCsModal(title,
            '<div class="art-frame cs-modal-art"><img src="' + url + '" alt="candidate"></div>', { url: url });
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
  });
  document.addEventListener('DOMContentLoaded', function () {
    if (!window.Turbo) {
      ensureBackground();
      ensureCursor();
      magneticButtons();
      pollRunningJobs();
      wireViewers();
    }
  });
})();
