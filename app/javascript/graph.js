// Force-directed view of the studio's own records (#96, facelift 4/4).
// No dependencies, no imports, no exports -- a self-contained IIFE that boots on
// `[data-graph-root]` and exposes a read-only diagnostic on window.GraphView.
//
// Data: GET /graph.json
//   { nodes: [{ id, type, tier, name, url, state, art, empty }],
//     edges: [{ from, to, kind }] }
//
// WHERE THIS COMES FROM: the vatican-kb's kbgraph.js -- a zero-dependency SVG
// force layout over that kb's own entities, served at /graph. The studio's graph
// is a PORT of it, not a copy of its content: the entities are projects, jobs,
// candidates and proofs, the colours are the studio's phase-1 semantic tokens,
// and the node art is the studio's OWN artwork.
//
// THE LIFETIME CONTRACT, and why it is not optional. The decorative particle
// field behind every page may loop forever by design; this must not:
//
//   * the simulation STOPS when alpha settles -- decay x0.975 a frame, the loop
//     exits below 0.02, and it re-arms via kick() on any interaction. There is no
//     permanent animation loop of any kind.
//   * the loop EXITS if the SVG leaves the document (a Turbo body swap
//     mid-simulation) -- a detached loop runs forever.
//   * the repulsion force AND the per-tick displacement are BOTH capped, or
//     near-coincident nodes compute a huge 1/d^2 kick, everything flies apart, and
//     the settle-then-fit() zooms out to a dot in empty space. A force cap alone
//     is not enough.
//   * only VISIBLE (type- and hop-filtered) nodes join the O(n^2) pair pass -- the
//     filter must make the frame cheaper, not just the picture smaller.
//   * node radii and stroke widths are viewBox units, so they are rescaled on
//     every fit/pan/zoom -- a fitted ~2000-unit world otherwise shrinks every dot
//     to 2px.
//   * re-fit ONCE at rest when the layout contracts during settling, behind an
//     autoFit flag the user's own pan/zoom permanently disables.
//
// LABELS ARE textContent, NEVER markup. A record's name is DATA: the studio's
// records are named by their operators, and a name is not markup. Nodes carry
// tabindex=0 with Enter opening the record, so the graph is not mouse-only.
//
// NODE ART: an <image> whose href is either the artwork URL the server published
// (a candidate's SVG or a proof's render PNG, both through this app's own
// login-gated file routes) or a PLACEHOLDER data URI when the record carries no
// artwork. The artwork BYTES are never parsed as markup -- the URL is set with
// setAttribute, and a file that is gone (a job that never ran) fires `error` and
// drops the image rather than showing a broken one.
(function () {
  "use strict";

  var NS = "http://www.w3.org/2000/svg";
  var root = document.querySelector("[data-graph-root]");
  if (!root) return;

  var svg = document.getElementById("gsvg");
  var gEdges = document.getElementById("gedges");
  var gNodes = document.getElementById("gnodes");
  if (!svg || !gEdges || !gNodes) return;
  var $ = function (s) { return document.querySelector(s); };

  // The entity classes and their radii. MIRRORS GraphData::TYPES / ::RADIUS in
  // app/models/graph_data.rb -- the test asserts the two agree, because a radius
  // the server and the view disagree about is a node that draws at the wrong size.
  var TYPES = ["project", "job", "candidate", "proof"];
  var RADIUS = { project: 9, job: 7, candidate: 5, proof: 4 };

  // The fallback placeholder for a node whose record carries no artwork: an
  // inline SVG data URI built at runtime. It is a constant the view owns -- the
  // server never sends a placeholder, so no server string can reach an href.
  var PLACEHOLDER = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">' +
    '<circle cx="12" cy="12" r="10" fill="none" stroke="#64748b" ' +
    'stroke-width="1.5" stroke-dasharray="3 3"/></svg>');

  // Which entity classes CARRY artwork. A project and a job are containers: they
  // get the class dot. A candidate and a proof carry their own SVG/PNG.
  var ART_TYPES = { candidate: true, proof: true };

  var state = {
    nodes: [],
    edges: [],
    byId: {},
    adj: {},
    typeOn: { project: true, job: true, candidate: true, proof: true },
    sel: null,
    hopSet: null,
    alpha: 1,
    running: false,
    autoFit: true,
    view: [-500, -400, 1000, 800],
    drag: null,
    pan: null,
    // Diagnostics for the probe, and the sim-stop proof. `raf` counts every frame
    // request the loop ever made, so "the sim is still running" is answerable
    // separately from "alpha is low": after settle, raf must stop growing.
    raf: 0,
    ticks: 0
  };

  var visible = function (n) { return n.on; };
  var setView = function () { svg.setAttribute("viewBox", state.view.join(" ")); };
  var toWorld = function (ev) {
    var r = svg.getBoundingClientRect();
    return [
      state.view[0] + ((ev.clientX - r.left) / r.width) * state.view[2],
      state.view[1] + ((ev.clientY - r.top) / r.height) * state.view[3]
    ];
  };

  // ---------------------------------------------------------------- the data

  function build(data) {
    state.nodes = (data.nodes || []).map(function (n, i) {
      return Object.assign({}, n, {
        // A deterministic, readable starting position: a spiral, so two nodes
        // never start coincident (the cap below exists for the mid-sim case).
        x: Math.cos(i * 2.4) * (60 + i * 1.6),
        y: Math.sin(i * 2.4) * (60 + i * 1.6),
        vx: 0,
        vy: 0,
        pin: false,
        on: true
      });
    });
    state.byId = {};
    state.adj = {};
    state.nodes.forEach(function (n) {
      state.byId[n.id] = n;
      state.adj[n.id] = {};
    });

    var seen = {};
    state.edges = [];
    var add = function (a, b, kind) {
      if (!a || !b || a.id === b.id) return;
      var key = a.id < b.id ? a.id + "|" + b.id : b.id + "|" + a.id;
      if (seen[key]) return;
      seen[key] = true;
      state.edges.push({ a: a, b: b, kind: kind });
      state.adj[a.id][b.id] = true;
      state.adj[b.id][a.id] = true;
    };
    (data.edges || []).forEach(function (e) {
      add(state.byId[e.from], state.byId[e.to], e.kind || "parent");
    });
  }

  // ------------------------------------------------------------------ drawing

  function draw() {
    var fragE = document.createDocumentFragment();
    var fragN = document.createDocumentFragment();

    state.edges.forEach(function (e) {
      var line = document.createElementNS(NS, "line");
      line.setAttribute("class", "g-edge g-edge--" + e.kind);
      line.setAttribute("stroke", "currentColor");
      e.el = line;
      fragE.appendChild(line);
    });

    state.nodes.forEach(function (n) {
      var g = document.createElementNS(NS, "g");
      g.setAttribute("class", "g-node g-node--" + n.type);
      g.setAttribute("tabindex", "0");
      g.setAttribute("role", "link");
      g.setAttribute("data-state", n.state || "none");
      g.setAttribute("data-empty", n.empty ? "true" : "false");
      g.setAttribute("aria-label", n.name);
      g.style.cursor = "pointer";

      // The art disc, clipped to the node's circle. A clipPath lives INSIDE the
      // translated group, so its userSpaceOnUse circle is in the node's own
      // coordinates -- the clip follows the node wherever it is dragged.
      var r = RADIUS[n.type] || 5;
      var clip = document.createElementNS(NS, "clipPath");
      clip.setAttribute("id", "gclip-" + n.id);
      var clipCircle = document.createElementNS(NS, "circle");
      clipCircle.setAttribute("r", r);
      clip.appendChild(clipCircle);

      // The class dot: the fill the entity class owns, and the backdrop for the
      // artwork when the artwork is absent or has not loaded.
      var body = document.createElementNS(NS, "circle");
      body.setAttribute("class", "g-body");
      body.setAttribute("r", r);

      g.appendChild(clip);
      g.appendChild(body);

      // Artwork, or the placeholder. setAttribute, never markup: the href is a
      // URL the server published, and the bytes are never parsed.
      if (ART_TYPES[n.type]) {
        var img = document.createElementNS(NS, "image");
        img.setAttribute("class", "g-art");
        img.setAttribute("clip-path", "url(#gclip-" + n.id + ")");
        img.setAttribute("preserveAspectRatio", "xMidYMid slice");
        img.setAttribute("href", n.art || PLACEHOLDER);
        // A file that is gone (a job that never ran, a proof that never
        // finished) drops the image rather than leaving a broken one in the node.
        img.addEventListener("error", function () {
          if (img.parentNode) img.parentNode.removeChild(img);
        });
        g.appendChild(img);
        n.artEl = img;
      }

      // The state ring -- the WORK STATE, drawn as a separate ring around the
      // class dot so a state is never confused with an entity class (the
      // devgraph rule). Its colour is the stylesheet's, from data-state.
      var ring = document.createElementNS(NS, "circle");
      ring.setAttribute("class", "g-halo");
      ring.setAttribute("r", r + 3.5);
      g.appendChild(ring);

      // The MISSING/EMPTY marker: a dashed ring, the studio's `.chip.miss`
      // convention (see the semantic layer of application.css) -- the same shape
      // the audit page uses for absent-but-optional data.
      if (n.empty) {
        var miss = document.createElementNS(NS, "circle");
        miss.setAttribute("class", "g-miss");
        miss.setAttribute("r", r + 6.5);
        g.appendChild(miss);
      }

      var title = document.createElementNS(NS, "title");
      title.textContent = n.name;
      var label = document.createElementNS(NS, "text");
      // textContent, ALWAYS. A record's name is data, and a name carrying a tag
      // renders as text rather than executing.
      label.setAttribute("class", "g-label");
      label.setAttribute("x", r + 4);
      label.setAttribute("y", "4");
      label.setAttribute("fill", "currentColor");
      label.style.display = "none";
      label.textContent = n.name;

      g.appendChild(title);
      g.appendChild(label);
      g._node = n;
      n.el = g;
      n.label = label;
      fragN.appendChild(g);
    });

    gEdges.appendChild(fragE);
    gNodes.appendChild(fragN);

    // The find box's datalist: every node, sorted, so a name can be typed.
    var list = $("#gnode-list");
    if (list) {
      var opts = document.createDocumentFragment();
      state.nodes.slice().sort(function (a, b) {
        return a.name.localeCompare(b.name);
      }).forEach(function (n) {
        var o = document.createElement("option");
        o.value = n.name;
        opts.appendChild(o);
      });
      list.appendChild(opts);
    }
  }

  // ------------------------------------------------------------ the filter

  function recompute() {
    state.nodes.forEach(function (n) {
      n.on = !!state.typeOn[n.type] && (!state.hopSet || state.hopSet[n.id]);
      n.el.style.display = n.on ? "" : "none";
    });
    state.edges.forEach(function (e) {
      e.el.style.display = e.a.on && e.b.on ? "" : "none";
    });
    var shown = state.nodes.filter(visible).length;
    var box = $("#gcount");
    if (box) {
      box.textContent = state.nodes.length + " nodes · " + state.edges.length +
        " edges · " + shown + " shown";
    }
  }

  // The hop set around a selected node: the node, its neighbours, their
  // neighbours, and so on out to `h`. A hop limit is what keeps a large graph
  // legible, and because it feeds recompute() it also makes the O(n^2) pass
  // cheaper -- not merely the picture smaller.
  function hops(node, h) {
    var seen = {};
    seen[node.id] = true;
    var frontier = [node.id];
    for (var i = 0; i < h; i++) {
      var next = [];
      frontier.forEach(function (id) {
        Object.keys(state.adj[id]).forEach(function (m) {
          if (!seen[m]) {
            seen[m] = true;
            next.push(m);
          }
        });
      });
      frontier = next;
    }
    return seen;
  }

  // ------------------------------------------------------------------- the sim

  function tick() {
    var live = state.nodes.filter(visible);
    var K = 11000;
    var FMAX = 6; // cap: near-coincident nodes otherwise get a huge kick and the
    //                layout explodes, which then makes fit() zoom out to nothing
    var STEP_MAX = 30; // AND the per-tick displacement needs its own clamp: a
    //                    force cap alone lets a velocity accumulate and a node
    //                    still jump off the layout in one frame
    var i, j, a, b, dx, dy, d2, d, f;
    for (i = 0; i < live.length; i++) {
      a = live[i];
      for (j = i + 1; j < live.length; j++) {
        b = live[j];
        dx = a.x - b.x;
        dy = a.y - b.y;
        d2 = Math.max(64, dx * dx + dy * dy);
        if (d2 > 360000) continue;
        d = Math.sqrt(d2);
        f = Math.min(FMAX, K / d2);
        dx /= d;
        dy /= d;
        a.vx += dx * f;
        a.vy += dy * f;
        b.vx -= dx * f;
        b.vy -= dy * f;
      }
    }
    state.edges.forEach(function (e) {
      if (!e.a.on || !e.b.on) return;
      var ex = e.b.x - e.a.x;
      var ey = e.b.y - e.a.y;
      var ed = Math.sqrt(ex * ex + ey * ey) + 0.01;
      var rest = e.kind === "parent" ? 40 : 85;
      var ef = (ed - rest) * 0.025;
      e.a.vx += (ex / ed) * ef;
      e.a.vy += (ey / ed) * ef;
      e.b.vx -= (ex / ed) * ef;
      e.b.vy -= (ey / ed) * ef;
    });
    live.forEach(function (n) {
      n.vx -= n.x * 0.0012;
      n.vy -= n.y * 0.0012;
      if (n.pin || n === state.drag) {
        n.vx = n.vy = 0;
        return;
      }
      n.x += Math.max(-STEP_MAX, Math.min(STEP_MAX, n.vx * state.alpha));
      n.y += Math.max(-STEP_MAX, Math.min(STEP_MAX, n.vy * state.alpha));
      n.vx *= 0.55;
      n.vy *= 0.55;
    });
    state.alpha *= 0.975;
    state.ticks += 1;
  }

  function paint() {
    state.edges.forEach(function (e) {
      if (!e.a.on || !e.b.on) return;
      e.el.setAttribute("x1", e.a.x);
      e.el.setAttribute("y1", e.a.y);
      e.el.setAttribute("x2", e.b.x);
      e.el.setAttribute("y2", e.b.y);
    });
    state.nodes.forEach(function (n) {
      if (n.on) n.el.setAttribute("transform", "translate(" + n.x + "," + n.y + ")");
    });
  }

  // kick() is the ONLY door into the animation loop, and the loop it starts is
  // the ONLY one. alpha is the gate: while it is above 0.02 the loop re-arms
  // itself, and the moment it drops below that the loop stops -- no timer, no
  // interval, nothing left running.
  function kick(a) {
    state.alpha = Math.max(state.alpha, a === undefined ? 0.6 : a);
    if (state.running) return;
    state.running = true;
    var loop = function () {
      // A Turbo swap removes the SVG from the document. Without this the loop
      // keeps requesting frames against a detached node forever.
      if (!document.body.contains(svg)) {
        state.running = false;
        return;
      }
      state.raf += 1;
      tick();
      tick();
      paint();
      if (state.alpha > 0.02 || state.drag) {
        window.requestAnimationFrame(loop);
      } else {
        state.running = false;
        labels();
        // The layout contracts as it settles; re-fit once at rest so the graph
        // does not end up as a small cluster in the middle of empty space.
        if (state.autoFit) fit();
      }
    };
    window.requestAnimationFrame(loop);
  }

  // Label density follows the zoom: a zoomed-in graph (perPx small) shows every
  // label, a zoomed-out one shows the hubs -- the high-degree project and job
  // nodes -- and the selection's own neighbourhood. Not everything, ever.
  function labels() {
    var mode = $("#glabels") ? $("#glabels").value : "auto";
    var perPx = state.view[2] / (svg.clientWidth || 1000);
    var close = perPx < 0.55;
    var keep = state.sel ? state.adj[state.sel.id] : null;
    var size = Math.max(7, Math.min(16, 11 * perPx * 1.6));
    state.nodes.forEach(function (n) {
      var links = Object.keys(state.adj[n.id]).length;
      var show = n.on && (
        mode === "all" ||
        (mode === "auto" && (
          (keep && keep[n.id]) ||
          (!keep && (
            (n.type === "project" && links >= (close ? 2 : 9)) ||
            (close && n.type === "job" && links >= 4) ||
            perPx < 0.3
          ))
        ))
      );
      n.label.style.display = show ? "" : "none";
      if (show) n.label.setAttribute("font-size", size);
    });
  }

  // ---------------------------------------------------------------- selection

  function select(node) {
    state.sel = node;
    if (node) state.autoFit = false;
    var keep = node ? state.adj[node.id] : null;
    state.nodes.forEach(function (n) {
      n.el.style.opacity = !keep || keep[n.id] ? 1 : 0.15;
    });
    state.edges.forEach(function (e) {
      e.el.style.opacity = !keep || e.a === node || e.b === node ? 1 : 0.04;
    });
    renderDetails(node);
    applyHops();
    labels();
  }

  // The details panel. Built from DOM nodes with textContent -- the record's name
  // and state are data, and nothing here re-parses a server string as markup.
  // `open record` goes to the REAL record, which is what makes the graph a
  // navigation surface rather than a picture.
  //
  // No markup assembly anywhere in this file, and the test pins that: a record's
  // name reaches the DOM only through textContent, so a name carrying a tag
  // renders as the text it is.
  function renderDetails(node) {
    var box = $("#gdetails-body");
    if (!box) return;
    box.textContent = "";
    if (!node) {
      var hint = document.createElement("p");
      hint.className = "g-hint";
      hint.textContent = "Select a node to see its record. Every node opens the record it was drawn from.";
      box.appendChild(hint);
      return;
    }

    var name = document.createElement("strong");
    name.className = "g-detail-name";
    name.textContent = node.name;
    var meta = document.createElement("small");
    meta.className = "g-detail-meta";
    meta.textContent = node.type + " · tier " + node.tier + " · " +
      Object.keys(state.adj[node.id]).length + " links" +
      (node.state ? " · " + node.state : "");

    box.appendChild(name);
    box.appendChild(meta);

    if (node.state && node.state !== "none") {
      var pill = document.createElement("span");
      pill.className = "status-pill status-" + node.state;
      pill.textContent = node.state;
      box.appendChild(pill);
    }
    if (node.empty) {
      var miss = document.createElement("span");
      miss.className = "chip miss";
      miss.textContent = "empty";
      box.appendChild(miss);
    }
    if (node.art) {
      var img = document.createElement("img");
      img.className = "g-detail-art";
      img.alt = node.name + " artwork";
      img.src = node.art;
      img.addEventListener("error", function () { img.remove(); });
      box.appendChild(img);
    }

    var link = document.createElement("a");
    link.className = "btn btn-secondary btn-sm g-detail-open";
    link.href = node.url;
    link.textContent = "open record →";
    box.appendChild(link);
  }

  function applyHops() {
    var h = Number($("#ghops").value);
    state.hopSet = state.sel && h ? hops(state.sel, h) : null;
    recompute();
    kick(0.5);
    paint();
    if (h && state.sel) window.setTimeout(fit, 900);
  }

  // Node radius and edge width are in viewBox units, so a fitted world of ~2000
  // units would shrink every dot to 2px. Scale them with the current zoom instead
  // so marks stay legible whatever the layout size.
  function rescale() {
    var k = Math.max(0.55, Math.min(3.2, state.view[2] / 1100));
    state.nodes.forEach(function (n) {
      var base = RADIUS[n.type] || 5;
      var r = (base * k).toFixed(2);
      n.el.querySelector(".g-body").setAttribute("r", r);
      n.el.querySelector(".g-halo").setAttribute("r", (base * k + 3.5).toFixed(2));
      var miss = n.el.querySelector(".g-miss");
      if (miss) miss.setAttribute("r", (base * k + 6.5).toFixed(2));
      n.el.querySelector("clipPath circle").setAttribute("r", r);
      if (n.artEl) {
        n.artEl.setAttribute("x", (-base * k).toFixed(2));
        n.artEl.setAttribute("y", (-base * k).toFixed(2));
        n.artEl.setAttribute("width", (2 * base * k).toFixed(2));
        n.artEl.setAttribute("height", (2 * base * k).toFixed(2));
      }
      n.label.setAttribute("x", (base * k + 4).toFixed(2));
    });
    state.edges.forEach(function (e) {
      e.el.setAttribute("stroke-width", (0.9 * k).toFixed(2));
    });
  }

  function fit() {
    var live = state.nodes.filter(visible);
    if (!live.length) return;
    var x0 = Infinity;
    var y0 = Infinity;
    var x1 = -Infinity;
    var y1 = -Infinity;
    live.forEach(function (n) {
      x0 = Math.min(x0, n.x);
      x1 = Math.max(x1, n.x);
      y0 = Math.min(y0, n.y);
      y1 = Math.max(y1, n.y);
    });
    var w = Math.max(200, x1 - x0 + 60);
    var h = Math.max(160, y1 - y0 + 60);
    var ratio = (svg.clientWidth || 1000) / (svg.clientHeight || 800);
    var W = Math.max(w, h * ratio);
    var H = W / ratio;
    state.view = [(x0 + x1) / 2 - W / 2, (y0 + y1) / 2 - H / 2, W, H];
    setView();
    rescale();
    labels();
  }

  // ------------------------------------------------------------------ events

  function bindEvents() {
    document.querySelectorAll("[data-gtype]").forEach(function (box) {
      box.addEventListener("change", function () {
        state.typeOn[box.getAttribute("data-gtype")] = box.checked;
        recompute();
        kick(0.4);
        labels();
      });
    });
    $("#ghops").addEventListener("change", applyHops);
    $("#glabels").addEventListener("change", labels);
    $("#grelax").addEventListener("click", function () {
      state.nodes.forEach(function (n) { n.pin = false; });
      kick(1);
    });
    $("#gfit").addEventListener("click", function () {
      state.autoFit = true;
      fit();
    });
    $("#gfind").addEventListener("change", function (ev) {
      var n = null;
      var want = ev.target.value.trim();
      state.nodes.forEach(function (c) { if (!n && c.name === want) n = c; });
      if (!n) return;
      if (!n.on) {
        state.typeOn[n.type] = true;
        var box = document.querySelector('[data-gtype="' + n.type + '"]');
        if (box) box.checked = true;
        recompute();
      }
      select(n);
      state.view = [n.x - 250, n.y - 200, 500, 400];
      setView();
      labels();
    });

    svg.addEventListener("pointerdown", function (ev) {
      var g = ev.target.closest ? ev.target.closest("g.g-node") : null;
      state.drag = g && g._node ? g._node : null;
      if (!state.drag) state.pan = { x: ev.clientX, y: ev.clientY };
      svg.setPointerCapture(ev.pointerId);
    });
    svg.addEventListener("pointermove", function (ev) {
      if (state.drag) {
        var w = toWorld(ev);
        state.drag.x = w[0];
        state.drag.y = w[1];
        state.drag.pin = true;
        kick(0.5);
        paint();
      } else if (state.pan) {
        state.autoFit = false;
        var scale = state.view[2] / svg.clientWidth;
        state.view[0] -= (ev.clientX - state.pan.x) * scale;
        state.view[1] -= (ev.clientY - state.pan.y) * scale;
        state.pan = { x: ev.clientX, y: ev.clientY };
        setView();
        rescale();
        labels();
      }
    });
    svg.addEventListener("pointerup", function () {
      if (state.drag) select(state.drag);
      state.drag = null;
      state.pan = null;
      labels();
    });
    svg.addEventListener("dblclick", function (ev) {
      var g = ev.target.closest ? ev.target.closest("g.g-node") : null;
      if (g && g._node) {
        g._node.pin = false;
        kick(0.6);
      }
    });
    svg.addEventListener("wheel", function (ev) {
      ev.preventDefault();
      state.autoFit = false;
      var f = ev.deltaY > 0 ? 1.12 : 0.89;
      var m = toWorld(ev);
      state.view = [
        m[0] - (m[0] - state.view[0]) * f,
        m[1] - (m[1] - state.view[1]) * f,
        state.view[2] * f,
        state.view[3] * f
      ];
      setView();
      rescale();
      labels();
    }, { passive: false });

    // Keyboard: Enter on a focused node opens the record; arrows pan. The node is
    // a real <g tabindex=0 role=link>, so it is reachable by Tab like any control.
    gNodes.addEventListener("keydown", function (ev) {
      var g = ev.target.closest ? ev.target.closest("g.g-node") : null;
      if (!g || !g._node) return;
      if (ev.key === "Enter" || ev.key === " ") {
        ev.preventDefault();
        window.location.href = g._node.url;
      }
    });
    gNodes.addEventListener("click", function (ev) {
      var g = ev.target.closest ? ev.target.closest("g.g-node") : null;
      if (g && g._node) select(g._node);
    });
  }

  // ------------------------------------------------------------------- start

  function start() {
    fetch("/graph.json", { headers: { Accept: "application/json" } })
      .then(function (r) {
        if (!r.ok) throw new Error("graph fetch failed: " + r.status);
        return r.json();
      })
      .then(function (data) {
        build(data);
        draw();
        bindEvents();
        renderDetails(null);
        recompute();
        paint();
        rescale();
        kick(1);
        window.setTimeout(fit, 1200);
      })
      .catch(function (err) {
        var box = $("#gcount");
        if (box) box.textContent = "graph unavailable: " + err.message;
      });
  }

  // A read-only diagnostic for the probe (and for anyone reading the console):
  // the counts, the live alpha, whether the loop is running, and the cumulative
  // frame count. The sim-stop proof is "alpha is below the threshold AND raf
  // stopped growing", which this is the only way to answer from outside the
  // closure.
  window.GraphView = {
    state: function () {
      return {
        nodes: state.nodes.length,
        edges: state.edges.length,
        shown: state.nodes.filter(visible).length,
        alpha: state.alpha,
        running: state.running,
        raf: state.raf,
        ticks: state.ticks,
        settled: state.alpha <= 0.02 && !state.running
      };
    },
    kick: kick
  };

  start();
})();
