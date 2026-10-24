// The datasets filter selects ship a BOUNDED window: the top-N topic / phrase-
// root values by row count, so the first paint is small. This module is the
// door to the rest — the FULL ranked vocabulary, read from the library JSON
// (`/datasets/library`, which carries every value with its count) rather than
// duplicated in the page's markup.
//
// The button beside each select opens the site's own glass modal with a search
// box; typing filters the fetched list, and clicking a hit applies the filter
// (navigating with it, preserving the text search). No full <option> list is
// ever shipped, and none is ever appended: the modal shows a small, filtered
// window of the JSON, exactly the vatican-kb "search over a small rendered
// window" shape.
//
// Self-contained: boots on `[data-dataset-vocabulary]` and degrades to nothing
// when the modal is unavailable (the login page, or a build without it) — the
// selects still render, just bounded.
(function () {
  "use strict";

  var root = document.querySelector("[data-dataset-vocabulary]");
  if (!root) return;

  // The results window the modal shows at once. The vocabulary is thousands of
  // entries; a filtered slice keeps the dialog's own DOM small.
  var RESULTS_WINDOW = 200;

  function groupFor(kind) {
    return kind === "root" ? "roots" : "topics";
  }

  function paramFor(kind) {
    return kind === "root" ? "root" : "topic";
  }

  // Render the filtered hits into the modal body. DOM APIs, not innerHTML: the
  // names are DATA (the dataset's own slugs, which an operator typed), and a
  // name is never markup.
  function renderResults(input, results, entries, kind, loaded) {
    var needle = input.value.trim().toLowerCase();
    var hits = entries.filter(function (e) {
      return !needle || String(e.name).toLowerCase().indexOf(needle) !== -1;
    }).slice(0, RESULTS_WINDOW);

    results.innerHTML = "";
    if (!hits.length) {
      var empty = document.createElement("p");
      empty.className = "results-side-note";
      if (needle) {
        empty.textContent = "no " + kind + " matches “" + input.value.trim() + "”.";
      } else if (!loaded) {
        empty.textContent = "loading…";
      } else {
        empty.textContent = "the library carries no " + kind + "s yet.";
      }
      results.appendChild(empty);
      return;
    }

    hits.forEach(function (e) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "btn btn-secondary btn-sm dv-hit";
      b.appendChild(document.createTextNode(String(e.name) + " "));
      var count = document.createElement("span");
      count.className = "mono";
      count.textContent = "(" + e.count + ")";
      b.appendChild(count);
      b.addEventListener("click", function () {
        var url = new URL(window.location.href);
        url.searchParams.set(paramFor(kind), e.name);
        url.searchParams.delete("page");
        window.location.href = url.toString();
      });
      results.appendChild(b);
    });
  }

  function openSearch(btn) {
    var modal = window.CsModal;
    if (!modal || typeof modal.open !== "function") return;

    var kind = btn.getAttribute("data-vocab-kind") || "topic";
    var endpoint = btn.getAttribute("data-vocab-endpoint");
    var total = parseInt(btn.getAttribute("data-vocab-total") || "0", 10);
    if (!endpoint) return;

    var html =
      '<p class="results-side-note">Search all ' + total.toLocaleString() + " " + kind +
      "s in the library — the select ships only the most common ones; this is the full " +
      "ranked list, read from the library JSON.</p>" +
      '<input type="search" id="dv-input" class="mono" placeholder="type to filter…" ' +
      'autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" ' +
      'style="width:100%;margin-bottom:0.5rem;">' +
      '<div id="dv-results" class="dv-results" role="listbox"></div>';

    modal.open("Search " + kind + "s", html);

    var input = document.getElementById("dv-input");
    var results = document.getElementById("dv-results");
    if (!input || !results) return;

    var entries = [];
    var loaded = false;

    function draw() { renderResults(input, results, entries, kind, loaded); }

    input.addEventListener("input", draw);
    input.focus();

    renderResults(input, results, entries, kind, loaded); // "loading…"

    fetch(endpoint, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (data) {
        entries = (data && data[groupFor(kind)]) || [];
        loaded = true;
        draw();
      })
      .catch(function (err) {
        results.innerHTML = "";
        var p = document.createElement("p");
        p.className = "results-side-note";
        p.style.color = "var(--danger)";
        p.textContent = "Could not load the vocabulary (" + err + ").";
        results.appendChild(p);
      });
  }

  // Delegated, so it survives a Turbo body swap without rebinding.
  document.addEventListener("click", function (ev) {
    var btn = ev.target.closest("[data-vocab-more]");
    if (!btn) return;
    ev.preventDefault();
    openSearch(btn);
  });
})();
