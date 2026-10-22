# Per-user accounts, queue cap, and plot-runner integration

Shipped 2026-09-28 in one go. See also `references/user-system.md` for the user
model itself.

## Per-user queue cap (5)

`RunJob::MAX_QUEUE_PER_USER = 5` (primary gate) and `RunJob::MAX_QUEUE = 255`
(global backstop). `JobsController#enqueue_run` counts
`Job.unscoped.where(state: "queued", owner: job.owner)` for the per-user gate,
then the global `where(state: "queued")` count. The 6th job for one user is
refused with "the queue is full (5 jobs waiting for you)". Other users are
unaffected. The owner is already stamped by the time `enqueue_run` runs (save
happens first).

## Plot runner (Run Job target)

`Job::JOB_KINDS` now includes `"plot"` alongside `svg`/`flux`. A plot job's
whole request rides in `spec["plot"]` = `{ op, doc, runs? }` where op is
generate/digest/query, doc is the operation's document, and runs (query only) is
the `.run.json` record array. `Job#plot?` / `plot_config` / `plot_op` / `plot_doc`
/ `plot_runs` / `plot_output_file` mirror the flux accessors. Validation
(`plot_job_needs_an_op_and_a_document`) refuses a missing/invalid op, a missing
doc, or a query without runs. `RunJob#run_plot` calls the synchronous PlotClient,
stores the SVG to `storage/uploads/plot_<hex>.svg`, and marks the job done — no
polling, no hand-off, no candidates. `upload_preview` gained `.svg` →
`image/svg+xml`. The Run Job form shows a plot panel (op selector + JSON doc +
query runs textarea) with client-side parse errors; `normalize_plot_documents`
in the controller parses JSON-string doc/runs for agent/HTTP posters.

## Plot service (chopshop-plot)

The service is the canonical `chopshop_plot/server.py` (stdlib
ThreadingHTTPServer) on origin/main — a concurrent agent built the same surface,
and `server.py` is the version that won; a duplicate `serve.py` existed only
locally and was dropped. Run it: `python3 cli.py serve --bind 127.0.0.1 --port
8796` (defaults from `chopshop_plot/config.py`; port 8796, loopback, token from
`CHOPSHOP_PLOT_TOKEN`). Studio wires it via `CHOPSHOP_RUNNER_PLOT_URL` +
`CHOPSHOP_RUNNER_PLOT_KIND=plot` in `~/.chopshop-studio.env`. `GET /health` needs
no token and lists the operations the RUNNING service actually serves (the
`"operations"` array) — check that against the caller's expectations before
assuming a 404 is the caller's fault. `POST /generate|/digest|/query|/tree|/log`
return SVG (`image/svg+xml`) or a JSON refusal `{"error", "kind"}`. The `query`
op reads a top-level `runs` transport field (list or single record), stripped
before the envelope is unwrapped. `/tree` and `/log` are the STATUS page's two
documents (hierarchy + event timeline); they came in one commit with the studio
STATUS page, so a running service that predates that commit 404s on both — pull
chopshop-plot to origin/main and restart before touching the studio side.

## Tree layout: tb vs lr (which way the candidates run)

The tree op takes `layout` = `"tb"` or `"lr"` (spec.py refuses anything else).
`tb` = top-to-bottom: depth runs DOWN the page and leaves spread HORIZONTALLY
side-by-side. `lr` = left-to-right: depth runs ACROSS and leaves stack VERTICALLY
down the page. For the STATUS hierarchy (source → job → candidates) the operator
wants the candidates VERTICAL, so post `"layout": "lr"`. The tree `size` is the
canvas; omit `height` (or send width-only) and the service fits the height to the
node count (`height = size.get("height") or max(…)`), so a width-only spec never
clips a long candidate list — a fixed 900px height would. The log op keeps a
fixed size (one row per event, bounded).

## What bp can and cannot DRAW (the vocabulary ceiling)

Before promising a diagram/graphic through bp, check what the `generate`
vocabulary actually accepts — several things an architecture-style diagram leans
on are REFUSED by name, and a plausible-looking doc that the service rejects
tests nothing:

- **Shapes only, no `text` element.** `generate` accepts `rect`/`circle`/`ellipse`/
  `polygon`/`polyline`/`line`/`path` plus a `canvas`. There is NO labelled-text
  element, even though `svg.text()` exists in the library — it is used internally
  by `tree`/`log`/`digest` but is not exposed through the open contract. A
  free-form diagram that needs per-box labels cannot be a `generate` doc as-is.
- **`stroke_dasharray` is refused** (`unknown field(s) ['stroke_dasharray']`).
  Dashed boundaries — region boxes, security groups — are not expressible.
- **No arrowheads/markers.** Lines and polylines draw; the connector vocabulary
  has no marker support, so arrowed edges are not a `generate` feature.
- **`tree`/`digest`/`log` hardcode a LIGHT background** (`#ffffff`); only
  `generate` carries an arbitrary `background`. A dark-theme drawing is
  expressible through `generate` alone, not through reusing `tree`.
- `tree` forces a top-down (or lr) HIERARCHICAL layout — right for a source→gate→
  candidate tree, wrong for free-form boxes-and-arrows, which is why `tree` is not
  a general architecture engine.

So the honest answer to "render an architecture diagram through bp" was: extend
`generate` (add a `text` element, `stroke_dasharray`, arrowheads — all
contract-respecting, `svg.text` already exists) OR draw the frame studio-side and
compose it. That gap has since been SPECIFIED — three feature issues filed
against `geeeze/chopshop-bp` for exactly these additions (text element,
`stroke_dasharray`, arrowheads), so check the tracker before concluding the
vocabulary is still closed; the shapes-only ceiling above describes the vocabulary
as of filing, not necessarily what has since landed.

When bp outputs are to be shown in the studio, the existing pattern is
`PagesController#status`: POST the doc, inline the returned SVG (`.html_safe`)
into a page carrying the standard layout — the operator sees it inside the
chopshop chrome, not as a bare SVG. (The architecture-diagram path would add a
bp-kind `arch_diagram` template to `PipelineConf::TEMPLATES`, served the same way.)

The studio runs `config.assume_ssl = true` + `force_ssl = true`, so the session
cookie is marked `secure`. A plain-http test client must allow secure cookies
over http: with urllib set `policy.secure_protocols = ("https","wss","socks","http")`
on the CookieJar, and disable redirect-following (a `redirect_to` generates an
`https://` Location that would point at a nonexistent TLS listener). curl's
Netscape cookie jar ignores the secure flag, which is why curl works where a
naive urllib script 422s.

## The `log` operation's column overlap (fixed-width `_T_COL`)

`chopshop_bp/log.py` laid out its timeline with a FIXED `_T_COL = 92` for the
timestamp column, so every row drew its label 40px inside a full ISO8601
timestamp (`2026-10-08T14:57:40Z` = 20 chars × `_ADVANCE` 6.6 = 132px). The
studio's STATUS EVENT LOG panel always renders this operation, and its rows
always overlapped.

- The rule: **a fixed column width for display-only text is only safe when the
  text's format is also fixed.** `t` is contractually a free display string, so
  measure the widest `t` the document actually contains (as the label and `#N`
  columns already do) and keep the constant as a MINIMUM floor, never the width.
- This class of overlap is diagnosable without eyes: render the SVG, parse every
  `<text>`'s x and estimated width (`len × _ADVANCE`), and compute the gap between
  adjacent spans in a row — a negative gap IS the collision. Useful for any bp
  diagram operation, and it turns "the text looks broken" into a number.
- The STATUS page sends an explicit `size {width:1200}`, honoured as given, so a
  column fix must make the columns FIT rather than assume the canvas will grow.
