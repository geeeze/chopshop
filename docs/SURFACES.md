# Invocable surfaces — what an agent or operator can call

Every surface in the six-repo system, in one place: **what it does, what goes in,
what comes out.** Repo-level detail lives in each repo's own docs (flux's
`docs/API.md`, plot's `docs/contract.md`, the studio's
[`runner-contract.md`](runner-contract.md)); this file is the map so you do not
have to know all six repos exist before you can grep them.

Conventions used below:

- **`<label>`** is a runner label from the environment, never a hostname.
- Paths like `05_final/` are relative to a job directory on the runner.
- "Input shape" is the *contract*, not a schema dump: required fields are named,
  everything else is optional or documented where it lives.

| repo | surfaces | protocol |
|---|---|---|
| [chopshop-svg](#chopshop-svg) | 2 shell commands, 20 Python scripts, 13 HTTP routes | CLI + HTTP (runner contract) |
| [chopshop-flux](#chopshop-flux) | 1 serve command, 5 CLI subcommands, 6 HTTP routes | CLI + HTTP |
| [chopshop-plot](#chopshop-plot) | 1 CLI with 7 subcommands, 8 HTTP routes | CLI + HTTP |
| [chopshop-jev](#chopshop-jev) | 2 Python scripts | CLI |
| [chopshop-sui](#chopshop-sui) | 1 bridge with 3 subcommands, 1 converter | CLI |
| [chopshop-studio](#chopshop-studio) | the app's HTTP surface (HTML + JSON) | browser HTTP / JSON |

---

## chopshop-svg

The pipeline and the runner. Everything here runs **on the runner box**, against
a job directory. The HTTP routes are the runner contract the studio speaks; the
shell commands and scripts are what a human runs by hand — and, for the two
`*.sh` entry points, what the runner itself shells out to.

### Shell entry points

| surface | what it does | input shape | output shape |
|---|---|---|---|
| `./front_pipeline.sh <raster>` | the **front half** in one command: prep → trace sweep → compare. Never picks a winner and never calls `pipeline.sh`. | one raster path (`PNG`/`JPEG`); flags `--sweep <json>`, `--skip-prep`, `--fix`, `--loop` (then pick interactively); env `SPEC=<spec.json>` | candidate SVGs + a comparison report; prints the paths. Exit `0` = at least one candidate passed both gates, `1` = candidates exist but none passed, `2` = a step failed |
| `./pipeline.sh [art.svg]` | the **back half**: Layer A (`validate_svg.py`) + Layer B (`preflight.py`) on one chosen SVG, and the export. | an SVG path (default `00_source/artwork.svg`); flag `--layer-a-only`; env `SPEC=<spec.json>` | `05_final/` proof PNG + print PDF + `manifest.json`. Exit `0` = passed, `1` = hard findings, `2` = a step failed |

### HTTP routes (the runner contract)

Base URL comes from the studio's `CHOPSHOP_RUNNER_<LABEL>_URL`. Bearer auth only
when `RUNNER_TOKEN` is set on both sides. All bodies are JSON; an unrouted
request answers `404 {"error": "unknown route"}`. Full semantics:
[`runner-contract.md`](runner-contract.md).

| route | what it does | input shape | output shape |
|---|---|---|---|
| `GET /health` | is it up, and what can it do | — | `{ok, host, mode: "real"\|"mock", tools: {inkscape, gs, jev}}` |
| `POST /jobs` | start a front-half run (async) | `{name, source_kind, input_path, spec}` — `input_path` must be a file under the shared upload root; the runner copies and downscales it into the job directory | `202 {id, stem}`; `400 {error}` if the input is unreadable |
| `GET /jobs/:id` | job state, log tail, candidates | — | `200 {id, state: queued\|running\|done\|error\|cancelled, log_tail, prep_summary, prep_expand, candidate_count, comparison, error}` |
| `GET /jobs/:id/archive` | the job directory as a downloadable bundle | — | `200` 7z bytes (`application/x-7z-compressed`); `409` while not done; `507` when the disk is under the floor; `500` if no 7z binary |
| `POST /jobs/:id/cancel` | ask a running job to stop (cooperative) | `{}` | `200 {state: "cancelling"\|"cancelled"}`; `409 {state}` once done/errored |
| `DELETE /jobs/:id` | drop the job and its directory (cancels first) | — | `200 {deleted: "<id>"}` |
| `GET /files/:job_id/:name` | proxy one artefact (candidate SVG, proof PNG, PDF, manifest) | `name` must match `[\w.\-]+` — that is what rejects traversal | `200` file bytes with a content type from the extension; `400`/`404` as JSON |
| `POST /validations` | run the **back half** on one candidate (async) | `{job_id, candidate_file}` — the candidate must be in the job's list | `202 {id}`; `409` if the job is not done; `404` if the candidate is unknown |
| `GET /validations/:id` | proof state and the resulting manifest | — | `200 {id, state, manifest, log, error}` |
| `POST /validations/:id/jev` | ask the decision sidecar the four advisory questions about this proof | `{job_id, candidate_file}` (the runner resolves the manifest from disk if it has forgotten the validation after a restart) | `200` the jev sidecar `{model, endpoint, latency_ms, answers, verdict}`; `409` while running; `503` when no decision service is configured (**never** `404`); `404` only when no manifest resolves |
| `POST /recolour` | rewrite one candidate's paint through an explicit `{source: target}` colour map, geometry untouched | `{job_id, file, map: {"#rrggbb": "#rrggbb", …}}` | `200 image/svg+xml` (the recoloured vector); `400` on a malformed map |
| `POST /recolour/colours` | list the distinct declared paints of one candidate, most-used first | `{job_id, file}` | `200 {file, colours: ["#…", …]}` |

### The scripts (run by hand, or by the stages above)

| script | what it does | input shape | output shape |
|---|---|---|---|
| `scripts/prep_raster.py` | check a raster for tracing suitability and normalise it (stage 1) | `<input> <spec> [--out-dir --fix --invert/--no-invert --invert-mode]` | the prepped PNG (+ `source.inverse.png`) and a prep report |
| `scripts/trace_sweep.py` | multi-pass VTracer tracing (stage 2) | `<prepped.png> <spec> [--sweep s.json --out-dir --workers]` | N candidate SVGs in `02_traced/<stem>/` |
| `scripts/compare_candidates.py` | run every candidate through Layer A **and** Layer B | `<traced_dir> <spec> [--out-dir --source --workers]` | `comparison.json` — per-candidate sweep parameters, gate findings, fidelity numbers, pass/fail |
| `scripts/pick_finish.py` | the semi-interactive "choose a candidate" loop | `<traced_dir> <spec>` | a chosen candidate, taken forward |
| `scripts/snap_colors.py` | snap every fill/stroke/stop-color to the spec palette (stage 3) | `<svg> <spec> [-o/--out --tolerance --force --dry-run]` | the snapped SVG (pure Python — no Node needed) |
| `scripts/node_reduce.py` | deterministic, targeted node reduction for flat-colour print | `<svg> [--out --max-nodes --tolerance --tolerance-cap --all-paths --verify --json --dry-run]` | the reduced SVG + a report |
| `scripts/tune_sweep.py` | run a matrix of trace settings against one prepped raster and rank them | `<source> [--spec --out-dir --preset --filter-speckle --hierarchical --splice --length --color-precision --layer-difference --max-cells --fidelity --no-fidelity --with-node-reduce --contact-sheet --render-size --json]` | one ranked report + the variants |
| `scripts/im_filters.py` | ImageMagick filter benches before the tracer | `<raster> [--presets --outdir --spec --keep-alpha --workers --contact-sheet --list]` | filtered rasters, each a candidate *input* |
| `scripts/palette_variants.py` | re-colour one finished SVG onto each palette | `<svg> [--from-final --palettes --outdir --only --strategy --map --spec --preflight --preflight-dpi --dry-run --list]` | one recoloured SVG per palette |
| `scripts/prep_expand.py` | the expanded prep benches (filters, tune sweep, node reduce), spec-gated | `--phase <phase> <target> <spec> [--out-dir --traced-root --json --quiet]` | reports under `06_run/<stem>/prep_expand` |
| `scripts/run_record.py` | stitch a run into one provenance record | `[--stem --traced-dir --source --all --out-dir]` | `.run.json` — the archive spine the query engine reads |
| `scripts/closeout.py` | the pass/fail board for a run (never stops at the first failure) | `<run.json> [--requirements --waive --no-gate]` | a per-candidate board against `requirements.json` |
| `scripts/disk_check.py` | disk-capacity gate | — | exit `2` below the floor, `1` below the warn line, `0` otherwise |
| `scripts/orphan_sweep.py` | delete pipeline artefacts left behind by jobs that no longer exist | `[--live-stems-file --root --uploads-dir --runner-root --runner-url --keep --grace-hours --max-delete --apply --json-out]` | a report; deletes only with `--apply` |
| `scripts/triage.py` | candidate-triage primitives (canonical form, hashes, buckets, gates, dedupe) | import as a library | — |
| `scripts/triage_ranker.py` | the preference ranker and the bucket bandit | `python3 scripts/triage_ranker.py train \| choose <bucket…> \| --selftest` | a ranked order — **never a winner**; writes `learned_ranker.json` / `learned_buckets.json` under `PIPELINE_LEARNING_DIR` |
| `scripts/triage_events.py` | the learning store behind the ranker | `python3 scripts/triage_events.py` (manual) | the event log the studio also feeds through `GET /events` |
| `validate_svg.py` | Layer A: source-level validation (the export gate) | `python3 validate_svg.py <file.svg> <spec.json>` | findings on stdout; exit `0` passed, `1` failed, `2` bad usage |
| `preflight.py` | Layer B: renders the artwork and measures it | `python3 preflight.py <input> <spec> [--dpi --workdir --json]` | `<stem>.manifest.json` (the document jev annotates) |

---

## chopshop-flux

The generator. It holds **one** GPU, so it serialises generation behind a lock;
batch several images in one call instead. Contract in the repo's `docs/API.md`.

### CLI

| surface | what it does | input shape | output shape |
|---|---|---|---|
| `chopshop_flux serve` | run the HTTP service | `[--bind --port --verbose]` (env: `CHOPSHOP_FLUX_BIND`, `CHOPSHOP_FLUX_PORT`) | the service on its socket |
| `chopshop_flux health` | is it up, what is loaded | `[--url]` | the `/health` object |
| `chopshop_flux models` | list the models and their licences | `[--url]` | the `/models` object |
| `chopshop_flux generate <prompt>` | text → image(s) | `--model --width --height --steps --guidance --seed --images --negative --style --styles --url --out --json` | PNG(s) on disk, or the JSON envelope with `--json` |
| `chopshop_flux edit <source> <prompt>` | image + text → image(s) | the same flags as `generate` | as `generate` |
| `chopshop_flux gen2pipe <prompt>` | text → image → `front_pipeline.sh` | `--sweep <json> --skip-prep`, plus the generation flags | generated source + the pipeline's comparison |

### HTTP routes

Bearer `CHOPSHOP_FLUX_TOKEN` guards every route except `/health` when set. All
responses are JSON except `GET /files/<name>`. Errors are
`{"error", "kind"}` with `kind` in `bad_request` / `unauthorised` / `not_found` /
`too_large` / `error`.

| route | what it does | input shape | output shape |
|---|---|---|---|
| `GET /health` | up, and what is loaded (cheap, does not touch the model) | — | `{ok, service, version, auth_required, engine: {loaded_model, loaded_repo, load_seconds, offload, busy, out_dir, torch, rocm, device, device_name, vram_total_gb, vram_free_gb}}` |
| `GET /models` | the registry, **with licences** — read this before generating something you intend to sell | — | `{models: [{key, repo_id, params_b, license, commercial_ok, vram_gb, default_steps, default_guidance, distilled, gated, default, notes, pipeline, dim_multiple, min_dim, max_pixels, negative_prompt, img2img_strength, edit_pipeline}]}` |
| `POST /generate` | text → image(s) | `{prompt (required), model, width, height, steps, guidance, negative_prompt, strength, seed, images}` | `{model, license, commercial_ok, prompt, width, height, steps, guidance, seed, edited, queue_wait_seconds, load_seconds, total_seconds, images: [{name, path, width, height, bytes, sha256, seed, model, seconds}], warnings}` |
| `POST /edit` | image + text → image(s) | `/generate`'s fields plus `image` (a `data:image/png;base64,…` URL, required) | as `/generate`, with `edited: true` |
| `GET /files/<name>` | one generated image, as bytes | a flat basename inside `CHOPSHOP_FLUX_OUT` | the image bytes; `404` for anything that resolves outside the output directory |
| `POST /unload` | free the model from VRAM | `{}` | `{"unloaded": true, "status": {…}}` |

Other flux configuration: `CHOPSHOP_FLUX_OUT`, `CHOPSHOP_FLUX_MAX_PIXELS`,
`CHOPSHOP_FLUX_OFFLOAD` (`cpu`/`none`), `CHOPSHOP_FLUX_VAE_TILING`,
`CHOPSHOP_FLUX_IDLE_UNLOAD`, `CHOPSHOP_FLUX_ACK_NONCOMMERCIAL`,
`CHOPSHOP_FLUX_PIPELINE`, `HF_HOME`.

---

## chopshop-plot

The geometry, metrics and rendering engine: JSON documents in, SVG (or a rendered
frame) out. Six operations, two transport routes. Contract in the repo's
`docs/contract.md`.

### CLI

`python3 cli.py <command> [args]` — `out` defaults to stdout; `-` means
stdin/stdout. Exit codes: `0` success, `2` usage, `3` invalid spec,
`4` the renderer (Blender) is missing.

| surface | what it does | input shape | output shape |
|---|---|---|---|
| `cli.py generate <spec.json> [out.svg]` | draw a geometry document | `{"op": "generate", "spec": {canvas, elements[], tiling?}}` — element types `rect`, `circle`, `ellipse`, `polygon`, `polyline`, `line`, `path` | one SVG |
| `cli.py digest <metrics.json> [out.svg]` | draw a metrics chart | `{"op": "digest", "spec": {chart: bar\|line\|scatter, title?, size?, data}}` | one SVG |
| `cli.py query <runs/> <chart.json> [out.svg]` | draw across run records | `{"runs": <record or list>, "spec": {chart: scatter\|pareto\|diff, x, y, color?, title?}}` | one SVG |
| `cli.py tree <hierarchy.json> [out.svg]` | draw a hierarchy | `{"op": "tree", "spec": {nodes: [{id, label?, kind?, status?, metrics?}], edges?, layout?, title?, size?}}` | one SVG |
| `cli.py log <events.json> [out.svg]` | draw an event timeline | `{"op": "log", "spec": {events: [{t?, kind?, label?, pos?}], title?, size?}}` — **spec order is time order; it is never sorted** | one SVG |
| `cli.py blender <spec.json> [out_dir]` | render geometry in 3D (headless Blender) | `{"op": "blender", "spec": {elements: […], title?, tiling?, extrude?, render? {size, views, background, engine: workbench\|eevee}, export? {glb}}}` | `<stem>_NNN.png` frames and `<stem>.glb`; the file names printed, one per line |
| `cli.py serve` | run the HTTP service | `[--bind --port --verbose]` (env: `CHOPSHOP_PLOT_BIND`, `CHOPSHOP_PLOT_PORT`) | the service on its socket |

### HTTP routes

Bearer `CHOPSHOP_PLOT_TOKEN` guards everything except `/health` when set.
**Success is one SVG document** (`image/svg+xml`) — or rendered bytes for
`blender` — and **every refusal is JSON** `{"error", "kind"}`, so a caller
branches on the content type.

| route | what it does | input shape | output shape |
|---|---|---|---|
| `POST /generate` | draw a geometry document | a generate spec, or its `{"op", "spec"}` envelope | the SVG |
| `POST /digest` | draw a metrics chart | a digest spec, or its envelope | the SVG |
| `POST /query` | draw across run records | `{"runs": <record or list>, "spec": <chart spec>}` | the SVG |
| `POST /tree` | draw a hierarchy | a tree spec, or its envelope | the SVG |
| `POST /log` | draw an event timeline | a log spec, or its envelope | the SVG |
| `POST /blender` | render geometry in 3D | a blender spec, or its envelope | `200 image/png` for one view with no GLB export; otherwise `200` a frames manifest `{frames: [names], glb: name or null}`; `503 blender_unavailable` when there is no Blender binary |
| `GET /files/<name>` | one rendered file | a basename matching `[A-Za-z0-9][A-Za-z0-9._-]*` inside `CHOPSHOP_BLENDER_OUT_DIR` | `image/png`, else `application/octet-stream`; `404` otherwise |
| `GET /health` | up, and which operations this backend can draw | — | `{ok, service, auth_required, engine}` — `engine.operations` is the list of routes it answers |

Other plot configuration: `CHOPSHOP_BLENDER_BINARY` (default `blender`),
`CHOPSHOP_BLENDER_OUT_DIR`.

---

## chopshop-jev

The advisory decision sidecar. Standard library only; it never modifies the
manifest it reads, never ranks candidates and never picks a winner. Contract in
the repo's `README.md` and `docs/remediation-loop.md`.

| surface | what it does | input shape | output shape |
|---|---|---|---|
| `scripts/jev_annotate.py <manifest>` | ask an external decision service four narrow questions about a preflight manifest and fold the typed answers into a thresholded verdict | `<manifest.json>` (from `preflight.py`); `--output <path>` (default `<stem>.jev.json`), `--endpoint`, `--model`, `--timeout`, `--dry-run` (write the request envelope, call nothing), `--optional` (write `status=skipped` and exit `0` when no key/service is available) | `<stem>.jev.json` — `{model, endpoint, latency_ms, answers, verdict, status}` — alongside the manifest. Any answer below the confidence floor is reported as `low_confidence`, never as settled fact |
| `scripts/jev_remediate.py <target>` | plan the remediation for a verdict. **Planning only** — `--remediate` is refused because execution is not implemented | `<target>` = a `.jev.json` sidecar, a raw response JSON, or a directory of sidecars; `--table`, `--iteration`, `--limit`, `--history`, `--parent-sweep`, `--manifest` (required when the input is a runner envelope, which carries no findings), `--chopshop-svg`, `--json <path>`, `--dry-run`, `--optional` | the decision printed (and written with `--json`); nothing is executed |

The runner shells out to the annotator for `POST /validations/:id/jev`; a box
with no key or no annotator answers `503`, so "the add-on is not configured here"
never gets mistaken for a broken route.

---

## chopshop-sui

**Superseded by chopshop-flux** and kept for the record. It is the original
seam: SwarmUI as a *source* of rasters for the pipeline and as a *filter* on
existing ones. It never modifies SwarmUI, never judges art and never traces.

| surface | what it does | input shape | output shape |
|---|---|---|---|
| `scripts/swarm_bridge.py generate <prompt>` | text → image(s), saved to disk | `--base-url` (default loopback), `--model --images --negative --steps --cfg --seed --width --height --style --styles --out-dir` | PNG(s) written to the output directory |
| `scripts/swarm_bridge.py filter <source> <prompt>` | img2img: restyle an existing raster | the source raster + `--creativity --width --height --out-dir` | the restyled PNG(s) |
| `scripts/swarm_bridge.py gen2pipe <prompt>` | text → image → `front_pipeline.sh` | `--style --styles --sweep --skip-prep --source-dir` | a generated source plus the pipeline's comparison |
| `scripts/comfy_to_swarmui.py <prompt_json>` | convert a ComfyUI API-format prompt into a SwarmUI example workflow | a ComfyUI prompt JSON; `--object-info --out --description` | the SwarmUI workflow wrapper `{workflow, prompt, custom_params, param_values, description, enable_in_simple, image}` |

Exit codes: `0` success, `2` bad usage, `3` SwarmUI unreachable, `4` no models
available, `5` generation failed. Styles live in `scripts/swarm_styles.json` so
new ones need no code change.

---

## chopshop-studio

The control surface and the only orchestrator. Two audiences on one surface: the
operator's browser (HTML) and an agent or script (JSON). The agent path — login,
CSRF, the JSON branches and their gotchas — is
[`agent-api.md`](agent-api.md); the outbound runner contract is
[`runner-contract.md`](runner-contract.md).

### Pages and job routes

| surface | what it does | input shape | output shape |
|---|---|---|---|
| `GET /` | the jobs index (newest first, in-flight jobs re-synced while listing) | — | HTML |
| `GET /jobs` | the job history | — | HTML |
| `GET /jobs/new` | the Run Job form (fields switch on the runner's kind) | query `input_path`, `preview_url`, `name`, `carried_from` | HTML |
| `POST /jobs` | **file a job** | `job[name]`, `job[source_kind]`, `job[input_path]`, `job[runner]` (validated against the configured labels), `job[spec]` (a JSON string) | `302` to `/jobs/:id` on success — HTML; `422` with `{"error": …}` when the request carried `Accept: application/json` |
| `POST /jobs/upload` | store a PNG/JPEG (≤ 50 MB, magic-byte checked) and return what the form needs | multipart `file` | JSON `{path, preview_url, name, size}` |
| `GET /jobs/upload_preview/:name` | serve a just-uploaded raster behind the login gate | basename matching `[\w.\-]+` | the image bytes |
| `GET /jobs/:id` | the job page: candidate table, proofs, sweeps, findings | — | HTML |
| `GET /jobs/:id.json` | **poll** a job | query `log=1` for the runner log tail; `candidate=<file>` for that candidate's full detail | `{done, log_html}`; with `log=1`: `{log: […]}`; with `candidate=`: `{file, job, spec, sweep, proof}` |
| `GET /jobs/:id/refresh` | force a sync from the runner | — | `302` back to the job |
| `GET /jobs/:id/file/:name` | proxy one runner artefact (candidate SVG, proof PNG, PDF, manifest) | `name` matching `[\w.\-]+`; `?download=1` for an attachment | the file bytes; `400`/`404`/`502` as headers |
| `GET /jobs/:id/download` | the whole job, bundled | the job must be `done` | a 7z attachment (a flux job's bundle is the studio's own provenance archive, carrying the runner's inside it) |
| `POST /jobs/:id/use_inverse` | take the job's colour-inverted prep twin and pre-fill a **new** job form with it | — | `302` to `/jobs/new` pre-filled |
| `POST /jobs/:id/reuse` | "run again" from a source/inverse preview: clone the spec into a new job form | `name` ∈ `source.png`, `source.inverse.png` | `302` to `/jobs/new` pre-filled |
| `POST /jobs/:id/cancel` | cancel a job (discard a queued one, or ask the runner to stop) | — | `302` to `/jobs`; `{ok}` as JSON |
| `DELETE /jobs/:id` | delete a job: log the event, tell the runner, drop the record | — | `302` to `/jobs` |

### Proofs (URL says `proofs`, model says `Validation`)

| surface | what it does | input shape | output shape |
|---|---|---|---|
| `GET /proofs/:id` | a proof page | — | HTML |
| `GET /proofs/:id.json` | poll a proof | — | JSON `{done: bool}` |
| `POST /proofs` | **run the back half** on a chosen candidate (records a `pick` event at the candidate's position) | top-level `job_id`, `candidate_file` — the candidate must belong to a `done` job | `302` to the proof page |
| `POST /proofs/:id/ask_jev` | ask the decision sidecar about this proof. Answered **once**: a stored answer is replayed, never re-asked | — | JSON (the popup's format) or `302`; `422` while the proof is still running; `502 {error}` when the call fails |
| `GET /proofs/:id/refresh` | re-read the proof's state from the runner | — | `302` |

### Scrapbook, composite, events, pages

The scrapbook is JSON-first: its sidebar consumes these responses, so the shapes
are stable.

| surface | what it does | input shape | output shape |
|---|---|---|---|
| `GET /scrapbook` | the operator's own store of favourites (most recent 200) | — | JSON `[{id, name, kind, url, job_id, sha256, vector, size, created_at}]` — `vector` (bool) says the stored bytes are an SVG |
| `POST /scrapbook` | favourite a runner artefact: fetch its bytes through the job's file proxy and **copy** them into the scrapbook (a copy, so the favourite outlives the job). Records a `star` event at the candidate's position | `job_id`, `name` (a flat basename); `override=1` to force a second copy | `201` the item JSON; `200 {…, duplicate: true}` when the bytes are already stored; `400`/`404`/`502` as JSON |
| `DELETE /scrapbook/:id` | remove a favourite | — | `302` (records an `unstar` event) |
| `GET /scrapbook/:id/file` | the item's stored file | — | the file bytes |
| `POST /scrapbook/:id/use` | hand a favourite to a new job ("trace it") | — | `302` to `/jobs/new` pre-filled (records a `pick` event) |
| `POST /scrapbook/:id/reference` | copy an item into uploads so it can be a generator's reference image (raster only) | — | JSON `{path, preview_url, name, size}` — the same shape as `POST /jobs/upload`; `422` for a non-raster |
| `POST /scrapbook/save_upload` | save a **local** upload (a generated variation, which has no runner job behind it) into the scrapbook | `name` (a basename inside `storage/uploads`), optional `job_id` | JSON item, or `302` for an HTML caller |
| `POST /scrapbook/import` | import a raw PNG/JPEG (an edited scrape) as a new item | multipart `file` | `201` the item JSON |
| `GET /composite`, `GET /composite/new`, `GET /composite/list` | the composite builder: the editor, a blank one, the list | — | HTML |
| `GET /composite/layers` | the layers available to assemble a composite | — | JSON `[{id, name, kind, layer_kind, item_kind, vector, url}]` (the 200 most recent scrapbook items) — `kind`/`layer_kind` is `vector` for an SVG item, else `raster` |
| `POST /composite`, `PATCH /composite/:id` | create / update a composite (its layers arrive as a JSON string; a layer's `kind` is `raster` by default and `vector` for an SVG composed as vectors). `palette` is an optional comma-separated list of `#rrggbb` | `composite[...]`, top-level | `302` |
| `GET /composite/:id/recipe` | **the compose spec**: the EXACT document this composite's vector flatten POSTs to the svg runner's `/compose` (`{width, height, background, palette, layers: [{type, src, x, y, w, h, opacity, hue}]}`), with every vector layer's `src` inlined as SVG text and every raster layer's as a data URI. The one JSON contract an agent reads to drive compose → collect | — | JSON; `422 {error}` when a vector layer's source is missing or is not an SVG |
| `POST /composite/:id/flatten` | flatten a composite into one artefact, stored twice (a scrapbook item + the upload the runner reads). **Raster** (a raster-only composite): the browser posts the composed PNG. **Vector** (any `vector` layer): the studio POSTs the recipe to the svg runner's `/compose` and stores the returned SVG, so a trace is never rasterised and re-traced. `mode: "raster"`/`"vector"` says which ran; `mode=raster` forces the PNG path | multipart `file` (PNG, raster path); optional `palette`; optional `mode` | JSON `{scrapbook_id, path, preview_url, content_type, mode}`; `400` not a PNG; `422` an uncomposable composite; `502` the runner refused |
| `POST /composite/:id/use`, `DELETE /composite/:id` | use a flattened composite for a new job, delete it | — | `302` |
| `GET /events` | **the recorded learning signal** — the human actions (`star`/`unstar`/`pick`/`delete`) a later learned ranker trains on. Read-only, owner-scoped | query `event`, `job_id`, `limit` (default 200, max 1000) | JSON `[{id, event, job_id, svg_sha, pos, ranker, payload, created_at}]` |
| `GET /engine.json` | **the system aggregate**: runner health per label, this owner's event counts by kind, job/candidate/scrapbook counts and the ranker's cold/live state. The machine-readable twin of the footer's check-engine light | — | JSON (see below) |
| `GET /up` | the Rails health check | — | `200` when the app boots, else `500` |
| `GET /login`, `POST /login`, `DELETE /logout` | the password gate. There is no username: the password *is* the identity | `password` | `302` into the app, or `401` with the login page |
| `GET /json`, `POST /json/use` | the spec builder and "use this spec" | a spec document | HTML / `302` |
| `GET /about`, `GET /flux`, `GET /plot`, `GET /blender`, `GET /status`, `GET /jev` | reference pages for the whole system: what each sidecar is, the models and their licences, the geometry/metrics contract, the 3D operation, the ML/ranking configuration, and the decision sidecar | — | HTML |

### `GET /engine.json` shape

```json
{
  "ok": true,
  "generated_at": "2026-09-28T12:00:00Z",
  "cold": true,
  "runners": [
    { "label": "mock", "kind": "svg", "url": "http://127.0.0.1:8790",
      "healthy": true, "health": { "ok": true, "mode": "mock" },
      "error": null }
  ],
  "events": { "total": 0, "by_kind": { "star": 0, "unstar": 0, "pick": 0, "delete": 0 } },
  "counts": { "jobs": 0, "candidates": 0, "scrapbook": 0 },
  "ranker": {
    "state": "cold",
    "recorded_events": 0,
    "picks": 0,
    "jobs_with_picks": 0,
    "thresholds": { "min_picks": 30, "min_jobs": 2 },
    "learned_files": ["learned_ranker.json", "learned_buckets.json"],
    "learning_dir_env": "PIPELINE_LEARNING_DIR",
    "config": [ { "title": "Ranker", "note": "chopshop-svg · scripts/triage_ranker.py",
                  "entries": [ { "title": "Cold start", "body": "…" } ] } ]
  }
}
```

Every count is the **signed-in owner's** and nothing else's: the models carry an
owner-scoped `default_scope`, so another operator's jobs, candidates, events and
scrapbook rows are invisible here by construction. `healthy` is false when the
label's `/health` call fails (`error` then carries the reason), so a cold
aggregate never reads as a healthy system.
