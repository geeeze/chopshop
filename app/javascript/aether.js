import core from "aether-core";

// Aether site module: everything the authed pages need ON TOP of the shared
// core (background orbs/particles/mesh, custom cursor, magnetic hover, glass
// modal) — job polling, the preview-popup toolbox, the candidate/proof
// viewer, the scrapbook sidebar, Jev, and the popup plumbing. The login page
// loads only aether-core; it never pulls this file.
(function (core) {
  'use strict';

  // Aliases for the shared functions, so the body below reads unchanged.
  var openCsModal = core.openCsModal;
  var closeCsModal = core.closeCsModal;
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


  // ---------- preview-popup toolbox ----------
  //
  // Any CsModal whose body holds a single image gets the same toolbox, whether
  // it is a source/inverse tile, the stepped candidate viewer, a proof render
  // or a scrapbook item:
  //
  //   * favourite  — star it into the scrapbook from inside the popup;
  //   * run again  — carry a source/inverse into a prefilled new job form;
  //   * reference  — show a candidate/proof beside its source or inverse;
  //   * hue        — a view-only hue-rotate on the previewed image;
  //   * save       — export what is on screen (hue + split) to the scrapbook.
  //
  // It decorates whatever image the opener already rendered, so a new image
  // popup inherits all of it without per-view wiring. The opener passes the
  // facts it knows (job id, filename, hand-off url, reference urls) through the
  // CsModal options; anything absent simply hides its control.
  var csPreview = { hue: 0, info: null, main: null, refImg: null, stage: null };

  function csPreviewImg() {
    var body = document.getElementById('csModalBody');
    if (!body) return null;
    // The stepped viewer names its image; a plain image popup has exactly one.
    return body.querySelector('#csViewerImg') || body.querySelector('.cs-modal-art img');
  }

  function csPreviewToolsHtml() {
    return '<div class="cs-preview-tools" id="csPreviewTools">' +
      '<button type="button" class="btn btn-secondary btn-sm cs-preview-fav" id="csPreviewFav" hidden ' +
        'data-scrap-favourite data-scrap-job="" data-scrap-name="" ' +
        'title="Favourite" aria-label="Favourite">' +
        '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"></polygon></svg>' +
        ' Favourite</button>' +
      '<button type="button" class="btn btn-secondary btn-sm" id="csPreviewReuse" hidden>Run job again</button>' +
      '<label class="cs-ref-pick mono" id="csRefPick" hidden>reference ' +
        '<select id="csRefSel"><option value="">none</option>' +
        '<option value="source">source</option><option value="inverse">inverse</option></select></label>' +
      '<label class="cs-hue mono" id="csPreviewHueWrap">hue ' +
        '<input type="range" id="csPreviewHue" min="0" max="360" step="1" value="0">' +
        '<span id="csPreviewHueVal">0°</span></label>' +
      '<button type="button" class="btn btn-primary btn-sm" id="csPreviewSave">Save to scrapbook</button>' +
      '<span class="cs-preview-hint mono" id="csPreviewHint"></span>' +
      '</div>';
  }

  function csBindPreview(options) {
    var body = document.getElementById('csModalBody');
    if (!body) return;
    var old = document.getElementById('csPreviewTools');
    if (old) old.parentNode.removeChild(old);

    var main = csPreviewImg();
    if (!main) return; // not an image popup: leave it alone

    csPreview.hue = 0;
    csPreview.info = {
      job: options.job || '',
      file: options.name || options.filename || '',
      reuseUrl: options.reuseUrl || '',
      refSource: options.refSource || '',
      refInverse: options.refInverse || ''
    };

    // The reference is a second <img> in the SAME art frame, so the split view
    // is two images side by side and nothing else.
    var stage = main.closest('.cs-modal-art') || main.parentNode;
    var ref = stage.querySelector('#csRefImg');
    if (!ref) {
      ref = document.createElement('img');
      ref.id = 'csRefImg';
      ref.className = 'cs-ref-img';
      ref.alt = 'reference';
      ref.hidden = true;
      // A reference that will not load (a vector job has no inverse twin)
      // collapses the split rather than showing a broken frame.
      ref.onerror = function () {
        ref.hidden = true;
        stage.classList.remove('cs-split');
      };
      stage.appendChild(ref);
    }
    ref.hidden = true;
    ref.removeAttribute('src');
    stage.classList.remove('cs-split');
    csPreview.main = main;
    csPreview.refImg = ref;
    csPreview.stage = stage;

    body.insertAdjacentHTML('afterbegin', csPreviewToolsHtml());
    csPreviewApplyInfo();
    var tools = document.getElementById('csPreviewTools');
    if (!tools) return;

    var hue = document.getElementById('csPreviewHue');
    hue.addEventListener('input', function () {
      csPreview.hue = parseInt(hue.value, 10) || 0;
      document.getElementById('csPreviewHueVal').textContent = csPreview.hue + '°';
      csApplyHue();
    });

    var sel = document.getElementById('csRefSel');
    if (sel) sel.addEventListener('change', function () { csShowReference(sel.value); });

    var reuse = document.getElementById('csPreviewReuse');
    if (reuse) reuse.addEventListener('click', csReusePreview);

    var save = document.getElementById('csPreviewSave');
    save.addEventListener('click', csSavePreview);
  }

  // Toggle the controls whose facts came in with the open. Re-run after the
  // viewer steps to a new candidate, whose filename the favourite needs.
  function csPreviewApplyInfo() {
    var info = csPreview.info;
    if (!info) return;
    var fav = document.getElementById('csPreviewFav');
    if (fav) {
      var canFav = !!(info.job && info.file);
      fav.hidden = !canFav;
      if (canFav) {
        fav.setAttribute('data-scrap-job', info.job);
        fav.setAttribute('data-scrap-name', info.file);
        fav.setAttribute('title', 'Favourite ' + info.file);
        fav.setAttribute('aria-label', 'Favourite ' + info.file);
      }
    }
    var reuse = document.getElementById('csPreviewReuse');
    if (reuse) {
      reuse.hidden = !info.reuseUrl;
      if (info.reuseUrl) reuse.setAttribute('data-url', info.reuseUrl);
    }
    var pick = document.getElementById('csRefPick');
    if (pick) {
      var options = pick.querySelectorAll('option');
      pick.hidden = !(info.refSource || info.refInverse);
      // An option with no url is disabled, so the selector never selects a
      // reference the job does not have.
      options.forEach(function (o) {
        if (o.value === 'source') o.disabled = !info.refSource;
        if (o.value === 'inverse') o.disabled = !info.refInverse;
      });
    }
  }

  function csApplyHue() {
    var filter = csPreview.hue ? 'hue-rotate(' + csPreview.hue + 'deg)' : '';
    if (csPreview.main) csPreview.main.style.filter = filter;
    if (csPreview.refImg) csPreview.refImg.style.filter = filter;
  }

  function csShowReference(kind) {
    var info = csPreview.info, ref = csPreview.refImg, stage = csPreview.stage;
    if (!info || !ref || !stage) return;
    var url = kind === 'source' ? info.refSource : kind === 'inverse' ? info.refInverse : '';
    if (!url) {
      ref.hidden = true;
      ref.removeAttribute('src');
      stage.classList.remove('cs-split');
      return;
    }
    ref.src = url;
    ref.hidden = false;
    stage.classList.add('cs-split');
    csApplyHue();
  }

  // Carry a source/inverse into a new job form as a real form POST — the
  // server redirects to /jobs/new with the file attached and the spec cloned,
  // exactly like ScrapbooksController#use. Never a run.
  function csReusePreview() {
    var info = csPreview.info;
    if (!info || !info.reuseUrl) return;
    var token = document.querySelector('meta[name="csrf-token"]');
    var form = document.createElement('form');
    form.method = 'post';
    form.action = info.reuseUrl;
    [['authenticity_token', token ? token.getAttribute('content') : ''],
     ['name', info.file]].forEach(function (f) {
      var input = document.createElement('input');
      input.type = 'hidden';
      input.name = f[0];
      input.value = f[1];
      form.appendChild(input);
    });
    document.body.appendChild(form);
    form.submit();
  }

  function csLoadForCanvas(imgs) {
    return Promise.all(imgs.map(function (im) {
      if (im.complete && (im.naturalWidth || im.width)) return Promise.resolve(im);
      return new Promise(function (resolve, reject) {
        im.addEventListener('load', function () { resolve(im); });
        im.addEventListener('error', reject);
      });
    }));
  }

  // Export what is on screen: the main image, or the main + reference side by
  // side, with the hue shift baked in exactly as the preview shows it. The PNG
  // goes to /scrapbook/import (magic-byte validated server-side), the same
  // endpoint the sidebar editor's Save uses.
  function csSavePreview() {
    var main = csPreview.main;
    if (!main) return;
    var hint = document.getElementById('csPreviewHint');
    var ref = (csPreview.refImg && !csPreview.refImg.hidden) ? csPreview.refImg : null;
    var sources = ref ? [main, ref] : [main];

    csLoadForCanvas(sources).then(function (imgs) {
      var maxH = imgs.reduce(function (m, im) {
        return Math.max(m, im.naturalHeight || im.height || 1);
      }, 1);
      var pieces = imgs.map(function (im) {
        var w = im.naturalWidth || im.width || 1;
        var h = im.naturalHeight || im.height || 1;
        return { img: im, w: Math.max(1, Math.round(w * (maxH / h))), h: maxH };
      });
      var gap = ref ? 8 : 0;
      var totalW = pieces.reduce(function (a, p) { return a + p.w; }, 0) + gap * (pieces.length - 1);

      var out = document.createElement('canvas');
      out.width = Math.max(1, totalW);
      out.height = Math.max(1, maxH);
      var ctx = out.getContext('2d');
      if (csPreview.hue) ctx.filter = 'hue-rotate(' + csPreview.hue + 'deg)';
      var x = 0;
      pieces.forEach(function (p) {
        ctx.drawImage(p.img, x, 0, p.w, p.h);
        x += p.w + gap;
      });
      ctx.filter = 'none';
      out.toBlob(function (blob) { csImportPreview(blob, hint); }, 'image/png');
    }).catch(function () {
      if (hint) { hint.textContent = 'could not export'; hint.style.color = 'var(--danger)'; }
    });
  }

  function csImportPreview(blob, hint) {
    if (!blob) { if (hint) hint.textContent = 'export failed'; return; }
    var fd = new FormData();
    fd.append('file', blob, 'preview.png');
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
    // The toolbox's favourite names the candidate actually on screen, so it
    // must move with the sweep.
    if (csPreview.info && document.getElementById('csPreviewTools')) {
      csPreview.info.file = item.file;
      csPreviewApplyInfo();
    }
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
    // The playlist host carries the job id and the source/inverse reference
    // urls, so every candidate in the sweep can be favourited and compared
    // against the same pair.
    var host = document.getElementById('cs-candidates');
    openCsModal('', csViewerHtml(), {
      url: list[index] ? list[index].url : '',
      job: host ? host.dataset.csJob : '',
      refSource: host ? host.dataset.csRefSource : '',
      refInverse: host ? host.dataset.csRefInverse : ''
    });

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
              { url: url, filename: title, useUrl: el.dataset.csUseUrl,
                job: el.dataset.csJob, name: el.dataset.csName || title,
                reuseUrl: el.dataset.csReuseUrl,
                refSource: el.dataset.csRefSource, refInverse: el.dataset.csRefInverse });
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
  // Two guards, because Turbo Drive swaps the BODY (drawer + toggle included) on
  // every navigation while `document` survives it: element bindings must re-run
  // per navigation, but the document-level listeners register once.
  var scrapbookDocBound = false;
  var SCRAPBOOK_STATE_KEY = 'chopshop.scrapbook.open';

  // Drag-and-drop payload contract. Two native drags share this drawer code:
  // a scrapbook LAYER (a drawer/picker thumbnail dropped on the composite
  // canvas) and a FAVOURITE (a job-show thumbnail dropped on the drawer). The
  // MIME types are our own so a drop can tell them apart from a stray file or
  // text drag.
  var SCRAP_DRAG_LAYER = 'application/x-scrapbook+json';
  var SCRAP_DRAG_FAV = 'application/x-scrapbook-fav';
  var scrapDrag = { kind: null, fav: null };

  function scrapParse(raw) {
    if (!raw) return null;
    try { return JSON.parse(raw); } catch (e) { return null; }
  }

  function scrapEndDrag() {
    scrapDrag.kind = null;
    scrapDrag.fav = null;
    var sidebar = document.getElementById('scrapbookSidebar');
    if (sidebar) sidebar.classList.remove('drop-active');
    var toggle = document.getElementById('scrapbookToggle');
    if (toggle) toggle.classList.remove('drop-active');
  }

  // Open/close/sync look up the LIVE drawer every call — Turbo replaces the
  // nodes on navigation, so nothing may be cached across a turbo:load. The open
  // state is remembered in sessionStorage (per-tab) and restored on the next
  // navigation, which is what "keep the scrapbook open across page changes"
  // asks for.
  function scrapbookSyncWidth() {
    var sb = document.getElementById('scrapbookSidebar');
    if (!sb) return;
    var w = Math.round(sb.getBoundingClientRect().width);
    if (w > 0) document.documentElement.style.setProperty('--scrapbook-w', w + 'px');
  }

  function scrapbookOpen(persist) {
    var sidebar = document.getElementById('scrapbookSidebar');
    var toggle = document.getElementById('scrapbookToggle');
    if (!sidebar || !toggle) return;
    scrapbookSyncWidth();
    sidebar.classList.add('open');
    sidebar.setAttribute('aria-hidden', 'false');
    toggle.setAttribute('aria-expanded', 'true');
    document.body.classList.add('scrapbook-open');
    loadScrapbook();
    if (persist !== false) {
      try { sessionStorage.setItem(SCRAPBOOK_STATE_KEY, '1'); } catch (e) {}
    }
  }

  function scrapbookClose(persist) {
    var sidebar = document.getElementById('scrapbookSidebar');
    var toggle = document.getElementById('scrapbookToggle');
    if (!sidebar || !toggle) return;
    sidebar.classList.remove('open');
    sidebar.setAttribute('aria-hidden', 'true');
    toggle.setAttribute('aria-expanded', 'false');
    document.body.classList.remove('scrapbook-open');
    if (persist !== false) {
      try { sessionStorage.removeItem(SCRAPBOOK_STATE_KEY); } catch (e) {}
    }
  }

  function scrapbookInit() {
    var toggle = document.getElementById('scrapbookToggle');
    var sidebar = document.getElementById('scrapbookSidebar');
    if (!toggle || !sidebar) return;

    // Element bindings RE-RUN on every init: Turbo swaps these nodes each
    // navigation, so a once-guard here would leave the fresh drawer/toggle dead
    // (star click, close, and the drop targets all silently stop working).
    toggle.addEventListener('click', function () {
      if (sidebar.classList.contains('open')) scrapbookClose(); else scrapbookOpen();
    });

    sidebar.addEventListener('click', function (e) {
      if (e.target.closest('[data-scrap-close]')) { scrapbookClose(); return; }
      var del = e.target.closest('[data-scrap-delete]');
      if (del) { scrapDelete(del); return; }
      var trace = e.target.closest('[data-scrap-trace]');
      if (trace) { scrapTrace(trace); return; }
      var edit = e.target.closest('[data-scrap-edit]');
      if (edit) { scrapOpenEditor(edit.getAttribute('data-url'), edit.getAttribute('data-name')); return; }
      var view = e.target.closest('[data-scrap-view]');
      if (view) { scrapView(view); return; }
    });

    // The drawer and the fixed star toggle are the drop targets for a
    // favourite drag. dragover MUST preventDefault or the browser refuses the
    // drop entirely; the drawer lights up as a visible affordance while a drag
    // is over it. Re-bound per navigation for the same reason as the clicks.
    [sidebar, toggle].forEach(function (target) {
      target.addEventListener('dragover', function (e) {
        if (scrapDrag.kind !== 'fav') return;
        e.preventDefault();
        if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
        target.classList.add('drop-active');
      });
      target.addEventListener('dragleave', function (e) {
        if (e.relatedTarget && target.contains(e.relatedTarget)) return;
        target.classList.remove('drop-active');
      });
      target.addEventListener('drop', function (e) {
        e.preventDefault();
        var fav = scrapDrag.fav;
        var raw = e.dataTransfer ? e.dataTransfer.getData(SCRAP_DRAG_FAV) : '';
        if (!fav && raw) fav = scrapParse(raw);
        scrapEndDrag();
        if (!fav || !fav.name) return;
        scrapPostFavourite(fav.job_id, fav.name).then(function (res) {
          if (res && res.ok) loadScrapbook();
        });
      });
    });

    // Restore: if the drawer was open before this navigation, keep it open.
    // (No syncWidth needed — the open()/CSS path publishes --scrapbook-w.)
    try {
      if (sessionStorage.getItem(SCRAPBOOK_STATE_KEY)) scrapbookOpen(false);
    } catch (e) {}

    // Document-level listeners register ONCE (Turbo never replaces `document`).
    if (scrapbookDocBound) return;
    scrapbookDocBound = true;

    document.addEventListener('keydown', function (e) {
      if (e.key !== 'Escape') return;
      var sb = document.getElementById('scrapbookSidebar');
      if (sb && sb.classList.contains('open')) scrapbookClose();
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

    // One delegated dragstart for both payloads. The composite builder reads
    // the LAYER type off #compCanvas (its drop lives in the page script, which
    // owns addLayer); the drawer and its toggle read the FAVOURITE type here
    // and speak the same POST as the star. Delegation, like the click handler,
    // means a freshly rendered drawer grid needs no rebinding.
    document.addEventListener('dragstart', function (e) {
      if (!e.target || !e.target.closest) return;
      var layerThumb = e.target.closest('[data-scrap-item]');
      if (layerThumb) {
        var item = scrapParse(layerThumb.getAttribute('data-scrap-item'));
        if (!item) return;
        scrapDrag.kind = 'layer';
        e.dataTransfer.setData('text/plain', item.url || '');
        e.dataTransfer.setData(SCRAP_DRAG_LAYER, JSON.stringify(item));
        e.dataTransfer.effectAllowed = 'copy';
        return;
      }
      var favThumb = e.target.closest('[data-scrap-job][draggable="true"]');
      if (favThumb) {
        var fav = { job_id: favThumb.getAttribute('data-scrap-job'),
                    name: favThumb.getAttribute('data-scrap-name') };
        scrapDrag.kind = 'fav';
        scrapDrag.fav = fav;
        e.dataTransfer.setData('text/plain', fav.name || '');
        e.dataTransfer.setData(SCRAP_DRAG_FAV, JSON.stringify(fav));
        e.dataTransfer.effectAllowed = 'copy';
      }
    });

    document.addEventListener('dragend', function () { scrapEndDrag(); });
  }

  function scrapEsc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  // The ONE favourite POST. Both the star button and a thumbnail dropped on
  // the drawer go through it, so there is no second code path to keep in step.
  function scrapPostFavourite(job, name) {
    var token = document.querySelector('meta[name="csrf-token"]');
    return fetch('/scrapbook', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': token ? token.content : ''
      },
      credentials: 'same-origin',
      body: JSON.stringify({ job_id: job, name: name })
    }).then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); });
  }

  function scrapFavourite(btn) {
    var job = btn.getAttribute('data-scrap-job');
    var name = btn.getAttribute('data-scrap-name');
    btn.disabled = true;
    scrapPostFavourite(job, name)
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
        '<div class="scrap-thumb-wrap">' +
        '<button type="button" class="scrap-thumb" draggable="true" data-scrap-item="' + scrapEsc(JSON.stringify(it)) + '" data-scrap-view data-url="' + scrapEsc(it.url) + '" data-name="' + scrapEsc(it.name) + '" data-scrap-job="' + scrapEsc(it.job_id) + '" title="' + scrapEsc(it.name) + ' — view">' +
        '<img src="' + scrapEsc(it.url) + '" alt="' + scrapEsc(it.name) + '" loading="lazy">' +
        '</button>' +
        '<button type="button" class="scrap-remove" data-scrap-delete data-id="' + scrapEsc(it.id) + '" data-name="' + scrapEsc(it.name) + '" title="Remove from scrapbook" aria-label="Remove ' + scrapEsc(it.name) + '">&times;</button>' +
        '</div>' +
        '<div class="scrap-name mono" title="' + scrapEsc(it.name) + '">' + scrapEsc(it.name) + '</div>' +
        '<div class="scrap-size mono">' + scrapSize(it.size) + '</div>' +
        '<div class="scrap-actions">' +
        '<button type="button" class="btn btn-secondary btn-sm" data-scrap-trace data-id="' + scrapEsc(it.id) + '" title="Trace as a new job">Trace</button>' +
        '<button type="button" class="btn btn-secondary btn-sm" data-scrap-edit data-url="' + scrapEsc(it.url) + '" data-name="' + scrapEsc(it.name) + '" title="Edit — crop, erase, colour shift">Edit</button>' +
        '</div>' +
        '</div>';
    });
    html += '</div>';
    body.innerHTML = html;
  }

  // A stored file's size as a human string; the index passes bytes and the
  // drawer formats them so the server stays unit-agnostic.
  function scrapSize(bytes) {
    if (bytes == null) return '';
    var n = Number(bytes);
    if (!isFinite(n) || n <= 0) return '';
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    return (n / (1024 * 1024)).toFixed(1) + ' MB';
  }

  function scrapView(el) {
    var url = el.getAttribute('data-url');
    var name = el.getAttribute('data-name') || '';
    var job = el.getAttribute('data-scrap-job') || '';
    if (window.CsModal) {
      window.CsModal.open(name,
        '<div class="art-frame cs-modal-art cs-image-view"><img src="' + scrapEsc(url) + '" alt="' + scrapEsc(name) + '"></div>',
        { url: url, filename: name, job: job, name: name });
    }
  }

  function scrapDelete(el) {
    var id = el.getAttribute('data-id');
    var name = el.getAttribute('data-name') || 'this item';
    // A confirmation gate: removing is destructive and there is no undo, so it
    // asks before it deletes. The glass modal's message carries the item name.
    csConfirm('Remove "' + name + '" from the scrapbook? The file it came from is untouched.', 'Remove', true, function () {
      var token = document.querySelector('meta[name="csrf-token"]');
      fetch('/scrapbook/' + encodeURIComponent(id), {
        method: 'DELETE',
        headers: { 'X-CSRF-Token': token ? token.content : '', 'Accept': 'application/json' },
        credentials: 'same-origin'
      }).then(function () { loadScrapbook(); })
        .catch(function () { loadScrapbook(); });
    });
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
  // cut (drag a region — removed and held on a clipboard), paste (place the
  // clipboard), erase (paint transparent PNG), and a hue-rotate colour shift.
  // "Save to scrapbook" exports the result as a new PNG item via
  // /scrapbook/import. This is the SURFACE editing the operator asked for —
  // crop / cut / paste / erase / colour shift — not the compositor: layering,
  // resize/reposition and the composite builder are a separate feature. The
  // hue shift is a view transform on the working canvas, baked into the export
  // at save time; crop, cut and erase mutate the base, so they compose in any
  // order.
  var scrapEditor = { work: null, tool: 'crop', hue: 0, srcUrl: '', srcName: '',
                      dragging: false, sx: 0, sy: 0, cx: 0, cy: 0, last: null,
                      clip: null, pasteX: 0, pasteY: 0 };

  function scrapEditorHtml() {
    return '<div class="scrap-editor">' +
      '<div class="scrap-editor-tools">' +
      '  <button type="button" class="btn btn-secondary btn-sm active" data-scrap-tool="crop">Crop</button>' +
      '  <button type="button" class="btn btn-secondary btn-sm" data-scrap-tool="cut">Cut</button>' +
      '  <button type="button" class="btn btn-secondary btn-sm" data-scrap-tool="paste">Paste</button>' +
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
    scrapEditor.clip = null;
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
      if (hint) { hint.textContent = 'drag to crop · Cut removes a region to the clipboard · Paste places it · Erase paints transparent · hue shifts colour'; hint.style.color = ''; }
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
    if (scrapEditor.tool === 'cut' && scrapEditor.dragging) {
      // The cut region is shaded red so the operator can tell "remove this"
      // apart from crop's blue "keep this".
      var cx = Math.min(scrapEditor.sx, scrapEditor.cx);
      var cy = Math.min(scrapEditor.sy, scrapEditor.cy);
      var cw = Math.abs(scrapEditor.cx - scrapEditor.sx);
      var ch = Math.abs(scrapEditor.cy - scrapEditor.sy);
      ctx.fillStyle = 'rgba(244, 63, 94, 0.16)';
      ctx.fillRect(cx, cy, cw, ch);
      ctx.strokeStyle = 'rgba(244, 63, 94, 0.9)';
      ctx.lineWidth = 2;
      ctx.strokeRect(cx, cy, cw, ch);
    }
    if (scrapEditor.tool === 'paste' && scrapEditor.clip) {
      // A translucent preview of the clipboard under the pointer, so the
      // operator can position before committing. Placed top-left at the
      // pointer, clamped to the canvas so it can never be dropped off-image.
      var px = clampPaste(scrapEditor.pasteX, scrapEditor.pasteY).x;
      var py = clampPaste(scrapEditor.pasteX, scrapEditor.pasteY).y;
      ctx.save();
      ctx.globalAlpha = 0.55;
      ctx.drawImage(scrapEditor.clip, px, py);
      ctx.restore();
      ctx.strokeStyle = 'rgba(99, 102, 241, 0.9)';
      ctx.lineWidth = 2;
      ctx.strokeRect(px, py, scrapEditor.clip.width, scrapEditor.clip.height);
    }
  }

  function clampPaste(x, y) {
    var work = scrapEditor.work;
    var clip = scrapEditor.clip;
    if (!work || !clip) return { x: 0, y: 0 };
    return {
      x: Math.max(0, Math.min(x, work.width - clip.width)),
      y: Math.max(0, Math.min(y, work.height - clip.height))
    };
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

  // Cut removes the dragged region from the working canvas and holds it on the
  // clipboard for Paste. The region is erased with destination-out, so what it
  // leaves behind is transparency, not white — a cut on a PNG must read as a
  // hole, and pasting it elsewhere must not carry a white box.
  function applyCut() {
    var work = scrapEditor.work;
    var x = Math.min(scrapEditor.sx, scrapEditor.cx);
    var y = Math.min(scrapEditor.sy, scrapEditor.cy);
    var w = Math.abs(scrapEditor.cx - scrapEditor.sx);
    var h = Math.abs(scrapEditor.cy - scrapEditor.sy);
    scrapEditor.dragging = false;
    if (w < 4 || h < 4) { redrawEditor(); return; }
    var clip = document.createElement('canvas');
    clip.width = Math.round(w); clip.height = Math.round(h);
    clip.getContext('2d').drawImage(work, x, y, w, h, 0, 0, clip.width, clip.height);
    var ctx = work.getContext('2d');
    ctx.save();
    ctx.globalCompositeOperation = 'destination-out';
    ctx.fillStyle = 'rgba(0,0,0,1)';
    ctx.fillRect(x, y, w, h);
    ctx.restore();
    scrapEditor.clip = clip;
    // Cut hands straight to Paste — that is the whole point of cutting, and it
    // saves the operator two clicks to a tool they were about to pick anyway.
    scrapEditor.tool = 'paste';
    scrapEditor.pasteX = x; scrapEditor.pasteY = y;
    setActiveTool();
    redrawEditor();
    var hint = document.getElementById('scrapEditorHint');
    if (hint) hint.textContent = 'region cut — move the pointer to place it, click to drop';
  }

  // Paste commits the clipboard into the working canvas at the pointer, clamped
  // so it can never be dropped off-image. The clipboard is kept after the drop:
  // pasting the same region several times is a legitimate composition move, and
  // Reset (or a fresh Cut) clears it.
  function applyPaste() {
    var work = scrapEditor.work;
    if (!work || !scrapEditor.clip) {
      var h2 = document.getElementById('scrapEditorHint');
      if (h2) h2.textContent = 'nothing to paste — Cut a region first';
      return;
    }
    var p = clampPaste(scrapEditor.pasteX, scrapEditor.pasteY);
    work.getContext('2d').drawImage(scrapEditor.clip, p.x, p.y);
    redrawEditor();
  }

  // The tool buttons carry the active class; a programmatic switch (Cut → Paste)
  // must move it too, or the two buttons disagree with the editor's state.
  function setActiveTool() {
    var body = document.getElementById('csModalBody');
    if (!body) return;
    body.querySelectorAll('[data-scrap-tool]').forEach(function (b) {
      b.classList.toggle('active', b.getAttribute('data-scrap-tool') === scrapEditor.tool);
    });
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
      if (scrapEditor.tool === 'crop' || scrapEditor.tool === 'cut') {
        scrapEditor.sx = p.x; scrapEditor.sy = p.y;
        scrapEditor.cx = p.x; scrapEditor.cy = p.y;
        scrapEditor.dragging = true;
      } else if (scrapEditor.tool === 'paste') {
        scrapEditor.pasteX = p.x; scrapEditor.pasteY = p.y;
        applyPaste();
      } else {
        scrapEditor.last = p;
        eraseAt(p, null);
        redrawEditor();
      }
    });
    canvas.addEventListener('pointermove', function (e) {
      var p = editorPoint(e);
      if ((scrapEditor.tool === 'crop' || scrapEditor.tool === 'cut') && scrapEditor.dragging) {
        scrapEditor.cx = p.x; scrapEditor.cy = p.y;
        redrawEditor();
      } else if (scrapEditor.tool === 'paste') {
        scrapEditor.pasteX = p.x; scrapEditor.pasteY = p.y;
        redrawEditor();
      } else if (scrapEditor.tool === 'erase' && scrapEditor.last) {
        eraseAt(p, scrapEditor.last);
        scrapEditor.last = p;
        redrawEditor();
      }
    });
    canvas.addEventListener('pointerup', function () {
      if (scrapEditor.tool === 'crop' && scrapEditor.dragging) applyCrop();
      else if (scrapEditor.tool === 'cut' && scrapEditor.dragging) applyCut();
      scrapEditor.last = null;
    });

    body.addEventListener('click', function (e) {
      var tool = e.target.closest('[data-scrap-tool]');
      if (tool) {
        scrapEditor.tool = tool.getAttribute('data-scrap-tool');
        setActiveTool();
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
      pollRunningJobs();
      wireViewers();
      wireJobActions();
      scrapbookInit();
      typedWelcome();
    }
  });
  // Wire the two core hooks: decorate every opened popup with the preview
  // toolbox, and drop the viewer playlist when the popup closes (the ←/→
  // handler only checks that *a* modal is open).
  core.setPreviewBinder(csBindPreview);
  core.onClose(function () { csView.list = []; csView.i = 0; });
})(core);
