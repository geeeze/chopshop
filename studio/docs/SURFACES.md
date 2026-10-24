# Invocable surfaces — what an agent or operator can call

Every surface in the system, in one place: **what it does, what goes in,
what comes out.** Component-level detail lives in each component's own docs (flux's
`docs/API.md`, bp's `docs/contract.md`, the studio's
[`runner-contract.md`](runner-contract.md)); this file is the map so you do not
have to know all six components exist before you can grep them.

Conventions used below:

- **`<label>`** is a runner label from the environment, never a hostname.
- Paths like `05_final/` are relative to a job directory on the runner.
- "Input shape" is the *contract*, not a schema dump: required fields are named,
  everything else is optional or documented where it lives.

| repo | surfaces | protocol |
|---|---|---|
| [chopshop-svg](#chopshop-svg) | 2 shell commands, 22 Python scripts in `scripts/` (+ 3 at the repo root: `runner.py`, `validate_svg.py`, `preflight.py`), 15 HTTP routes | CLI + HTTP (runner contract) |
| [chopshop-flux](#chopshop-flux) | 1 serve command, 5 CLI subcommands, 6 HTTP routes | CLI + HTTP |
| [chopshop-bp](#chopshop-bp) | 1 CLI with 7 subcommands, 8 HTTP routes | CLI + HTTP |
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
| `./front_pipeline.sh <raster>` | the **front half** in one command: prep → trace sweep → compare. It never calls `pipeline.sh`. | one raster path (`PNG`/`JPEG`); flags `--sweep <json>`, `--skip-prep`, `--fix`, `--loop` (then pick interactively); env `SPEC=<spec.json>` | candidate SVGs + a comparison report; prints the paths. Exit `0` = at least one candidate passed both gates, `1` = candidates exist but none passed, `2` = a step failed |
| `./pipeline.sh [art.svg]` | the **back half**: Layer A (`validate_svg.py`) + Layer B (`preflight.py`) on one chosen SVG, and the export. | an SVG path (default `00_source/artwork.svg`); flag `--layer-a-only`; env `SPEC=<spec.json>` | `05_final/` proof PNG + print PDF + `manifest.json`, under the canonical flat names the runner's routes read; the same artefacts are also written attributable to their source — `05_final/<artwork-stem>/<candidate-stem>.manifest.json` / `.proof.png` / `.print.pdf`, plus run-unique `<artwork-stem>.<candidate-stem>.<RUN_ID>.*` copies. Exit `0` = passed, `1` = hard findings, `2` = a step failed |

### HTTP routes (the runner contract)

Base URL comes from the studio's `CHOPSHOP_RUNNER_<LABEL>_URL`. Bearer auth only
when `RUNNER_TOKEN` is set on both sides. All bodies are JSON; an unrouted
request answers `404 {"error": "unknown route"}`. Full semantics:
[`runner-contract.md`](runner-contract.md).

| route | what it does | input shape | output shape |
|---|---|---|---|
| `GET /health` | is it up, and what can it do | — | `{ok, host, mode: "real"\|"mock", tools: {inkscape, gs, jev}}` |
| `POST /jobs` | start a front-half run (async) | `{name, source_kind, input_path, spec}` — `input_path` must be a file under the shared upload root; the runner copies and downscales it into the job directory | `202 {id, stem}`; `400 {error}` if the input is unreadable |
| `GET /jobs/:id` | job state, log tail, candidates | — | `200 {id, state: queued\|running\|done\|error\|cancelled, log_tail, prep_summary, prep_expand, candidate_count, comparison, error}`. The studio stores `state`, `prep_summary`, `prep_expand`, `candidate_count`, `comparison` and `error`; **`prep_expand` (the expanded-prep bench report)** is stored in the `jobs.prep_expand` JSON column and rendered as a block inside the right-hand column of `.results-split` on the job results page, after the proofs and before the sources. The block appears only when the runner reported a bench (the job's spec asked for `print.prep_expand` and the job completed). The runner also copies the flat report files (`prep-expand.md`, `tune.md`, …) to the job root, so the archive download (`GET /jobs/:id/archive` |
| `GET /jobs/:id/archive` | the job directory as a downloadable bundle | — | `200` 7z bytes (`application/x-7z-compressed`); `409` while not done; `507` when the disk is under the floor; `500` if no 7z binary |
| `GET /jobs/:id/dataset` | ONE `<candidate_stem>.dataset` (the proof-variants opt-in, `spec.validation.variants`) as a downloadable 7z, built on demand | `?candidate=<candidate_file>` names which dataset; it may be omitted when the job holds exactly one | `200` 7z bytes, named `<stem>.dataset.7z`; `409` while not done; `404` no dataset for this job; `400` when the job holds several and `?candidate=` is missing (**never** a guess); `507` under the disk floor; `500` if no 7z binary |
| `POST /jobs/:id/cancel` | ask a running job to stop (cooperative) | `{}` | `200 {state: "cancelling"\|"cancelled"}`; `409 {state}` once done/errored |
| `DELETE /jobs/:id` | drop the job and its directory (cancels first) | — | `200 {deleted: "<id>"}` |
| `GET /files/:job_id/:name` | proxy one artefact (candidate SVG, proof PNG, PDF, manifest; also the three FLAT dataset names, which sit at the job root) | `name` must match `[\w.\-]+` — that is what rejects traversal | `200` file bytes with a content type from the extension; `400`/`404` as JSON |
| `GET /files/:job_id/<stem>.dataset/<name>` | proxy ONE file inside a dataset directory — `raster/<transform>.png`, `vector/<transform>.svg`, `dataset.json`, `dataset.md`. **The only route whose request may contain a slash**, and the only `/files/` URL with four segments | a candidate stem + a nested name; containment is re-checked on the RESOLVED path (a `..`, an absolute name, a backslash or a symlink out is `400`) | `200` file bytes; `400` escaping the dataset directory; `404` unknown job or a dataset the job does not hold |
| `POST /validations` | run the **back half** on one candidate (async) | `{job_id, candidate_file}` — the candidate must be in the job's list | `202 {id}`; `409` if the job is not done; `404` if the candidate is unknown |
| `GET /validations/:id` | proof state and the resulting manifest | — | `200 {id, state, manifest, log, error}` |
| `POST /validations/:id/jev` | ask the decision sidecar the four advisory questions about this proof | `{job_id, candidate_file}` (the runner resolves the manifest from disk if it has forgotten the validation after a restart) | `200` the jev sidecar `{model, endpoint, latency_ms, answers, verdict}`; `409` while running; `503` when no decision service is configured (**never** `404`); `404` only when no manifest resolves |
| `POST /recolour` | rewrite one candidate's paint through an explicit `{source: target}` colour map, geometry untouched | `{job_id, file, map: {"#rrggbb": "#rrggbb", …}}` | `200 image/svg+xml` (the recoloured vector); `400` on a malformed map |
| `POST /recolour/colours` | list the distinct declared paints of one candidate, most-used first | `{job_id, file}` | `200 {file, colours: ["#…", …]}` |
| `POST /compose` | **the composition operation**: merge a composite's layers into ONE SVG with the vectors intact, so a traced source is never rasterised and re-traced. Called by `ComposeClient` (not `RunnerClient`) from `CompositesController#flatten` | `{op: "compose", spec: {width, height, background, palette?, layers: [{type: "svg"\|"raster", src, x, y, w, h, opacity, hue}]}}` — every `src` is INLINE (an SVG document string, or a `data:` URI), so a compose request never reads the runner's disk | `200 image/svg+xml` (the merged document); `422 {"error", "kind": "invalid_spec"}`; `500` only for an unexpected merge failure |

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
| `scripts/palette_variants.py` | re-colour one finished SVG onto each palette. **STANDALONE BENCH, UNWIRED AS A STAGE** — no stage in `front_pipeline.sh`/`pipeline.sh` runs it, it has no `prep_expand` key and no spec key of its own, so it looks like the pipeline benches beside `prep_expand.py` and is not one. Unwired as a *stage* is not unused as a *module*: the proof-variant dataset stage (`scripts/proof_variants.py`) imports its colour machinery (`as_hex` / `apply_mapping` / `declared_colours`), and the runner's `/recolour` seam does too, so the colour maths has one tested implementation and several callers | `<svg> [--from-final --palettes --outdir --only --strategy --map --spec --preflight --preflight-dpi --dry-run --list]` | one recoloured SVG per palette, from the CLI — nothing downstream consumes it automatically |
| `scripts/prep_expand.py` | the expanded prep benches (filters, tune sweep, node reduce), spec-gated | `--phase <phase> <target> <spec> [--out-dir --traced-root --json --quiet]` | reports under `06_run/<stem>/prep_expand` (the runner instead sets `PREP_EXPAND_OUT=<job dir>/prep_expand`, so they land inside the job bundle, and copies the flat report names — `prep-expand.json`/`.md`, `tune.json`/`.md`, `tune-contact-sheet.png`, `node-reduce.json`, `filters.*` — to the job root) |
| `scripts/run_record.py` | stitch a run into one provenance record | `[--stem --traced-dir --source --all --out-dir]` | `.run.json` — the archive spine the query engine reads |
| `scripts/closeout.py` | the pass/fail board for a run (never stops at the first failure) | `<run.json> [--requirements --waive --no-gate]` | a per-candidate board against `requirements.json` |
| `scripts/disk_check.py` | disk-capacity gate | — | exit `2` below the floor, `1` below the warn line, `0` otherwise |
| `scripts/orphan_sweep.py` | delete pipeline artefacts left behind by jobs that no longer exist | `[--live-stems-file --root --uploads-dir --runner-root --runner-url --keep --grace-hours --max-delete --apply --json-out]` | a report; deletes only with `--apply` |
| `scripts/triage.py` | candidate-triage primitives (canonical form, hashes, buckets, gates, dedupe) | import as a library | — |
| `scripts/triage_ranker.py` | the preference ranker and the bucket bandit | `python3 scripts/triage_ranker.py train \| choose <bucket…> \| --selftest` | a ranked order — **never a winner**; writes `learned_ranker.json` / `learned_buckets.json` under `PIPELINE_LEARNING_DIR` |
| `scripts/triage_events.py` | the learning store behind the ranker | `python3 scripts/triage_events.py` (manual) | the event log the studio also feeds through `GET /events` |
| `validate_svg.py` | Layer A: source-level validation (the export gate) | `python3 validate_svg.py <file.svg> <spec.json>` | findings on stdout, each naming its rule. Hard gates: `GRADIENT_NOT_ALLOWED` (`geometry.allow_gradients` false and the source declares a `<linearGradient>`/`<radialGradient>` or paints through a `url(#…)` server in `fill`/`stroke`/`stop-color`/`flood-color`/`lighting-color`), `RASTER_EMBED` (`geometry.allow_raster_embed` false and the source pulls in a bitmap or another document — `<image>` (`<pattern>` included), `<feImage>`, `<foreignObject>`, a `<use>`/`<image>` into a non-fragment document or a `data:` URI, a `url(data:image/…)` paint), `COLOR_COUNT` and `MIN_STROKE_WIDTH`, which count only what paints (an implicit black fill and `currentColor` count, `!important` is ranked, and hidden paint, `stroke-opacity="0"` or a stroke inside a container that can never ink inflates neither). Advisories are written to the manifest's `notes`, never to findings, and each says a check did NOT finish: `EFFECT_REFERENCE` (a `filter`/`mask`/`clip-path` reference, whose ink effect Layer A cannot measure), `TRANSLUCENT_PAINT` (a partly transparent paint) and `UNCHECKED_DEFINITION` (definition content nothing references, so colour/stroke coverage is partial). Exit `0` passed, `1` failed, `2` bad usage |
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
`too_large` / `gpu_busy` / `error`. **`503 gpu_busy`** is the one `503`: the
request was well-formed and the CARD was held by another process, so retry
rather than fixing the request. It appears only where the GPU-contention guard is
set to refuse (`CHOPSHOP_FLUX_GUARD=block`, or `wait` after its budget expired);
the default `warn` never returns it.

| route | what it does | input shape | output shape |
|---|---|---|---|
| `GET /health` | up, and what is loaded (cheap, does not touch the model) | — | `{ok, service, version, auth_required, engine: {loaded_model, loaded_repo, load_seconds, offload, busy, out_dir, torch, rocm, device, device_name, vram_total_gb, vram_free_gb, gpu_guard}}` — `gpu_guard` is `{mode, required_free_gb, free_gb, measured, contended, lmstudio, notes, last}`, the gate's own reading, where a busy card is legible without a failed generation |
| `GET /models` | the registry, **with licences** — read this before generating something you intend to sell | — | **three arrays**: `{models: [{key, repo_id, params_b, license, commercial_ok, vram_gb, repo_bytes, layout, default_steps, default_guidance, distilled, gated, default, notes, pipeline, edit_pipeline, dim_multiple, min_dim, max_pixels, negative_prompt, img2img_strength, multi_reference, guidance_embedded, resolution_binning}], modifiers: [{key, repo_id, targets, license, commercial_ok, repo_bytes, aliases, notes, kind: "modifier", weight_name, steps, guidance, scheduler, scale}], vaes: [{key, repo_id, targets, license, commercial_ok, repo_bytes, aliases, notes, kind: "vae", tiny}]}` — `modifiers` and `vaes` are separate keys because a LoRA and a VAE are not interchangeable, and both are new keys beside `models` rather than a restructure of it, so a client that reads only `models` keeps working |
| `POST /generate` | text → image(s) | `{prompt (required), model, width, height, steps, guidance, negative_prompt, strength, seed, images}` | `{model, license, commercial_ok, prompt, width, height, steps, guidance, seed, edited, queue_wait_seconds, load_seconds, total_seconds, images: [{name, path, width, height, bytes, sha256, seed, model, seconds}], warnings}` |
| `POST /edit` | image + text → image(s) | `/generate`'s fields plus `image` (a `data:image/png;base64,…` URL, required) | as `/generate`, with `edited: true` |
| `GET /files/<name>` | one generated image, as bytes | a flat basename inside `CHOPSHOP_FLUX_OUT` | the image bytes; `404` for anything that resolves outside the output directory |
| `POST /unload` | free the model from VRAM | `{}` | `{"unloaded": true, "status": {…}}` |

Other flux configuration: `CHOPSHOP_FLUX_OUT`, `CHOPSHOP_FLUX_MAX_PIXELS`,
`CHOPSHOP_FLUX_OFFLOAD` (`cpu`/`none`), `CHOPSHOP_FLUX_VAE_TILING`,
`CHOPSHOP_FLUX_IDLE_UNLOAD`, `CHOPSHOP_FLUX_IDLE_EXIT`,
`CHOPSHOP_FLUX_ACK_NONCOMMERCIAL`, `CHOPSHOP_FLUX_PIPELINE`, `HF_HOME`, and the
**GPU-contention guard** — the card is shared with LM Studio and anything else on
it, so a load is gated on free VRAM: `CHOPSHOP_FLUX_GUARD`
(`off`/`warn`/`wait`/`block`, default `warn`), `CHOPSHOP_FLUX_GUARD_VRAM_GB`
(default `5.0`; under `offload=cpu` the peak is ONE stage, not the whole model),
`CHOPSHOP_FLUX_GUARD_WAIT` (`120`) and `CHOPSHOP_FLUX_GUARD_POLL` (`5`) for the
`wait` budget and its reading interval, and `CHOPSHOP_FLUX_LMSTUDIO_URL`
(unset; attribution only — it names the holder in a refusal, it is not the gate).

---

## chopshop-bp

The blend-plot service (renamed from `chopshop-plot`): ONE service with two
halves — `plot` draws a document, `blend` renders geometry in 3D. JSON documents
in, SVG (or a rendered frame) out. Six operations, two transport routes. Contract
in the repo's `docs/contract.md`.

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
| `cli.py serve` | run the HTTP service | `[--bind --port --verbose]` (env: `CHOPSHOP_BP_BIND`, `CHOPSHOP_BP_PORT`) | the service on its socket |

### HTTP routes

Bearer `CHOPSHOP_BP_TOKEN` guards everything except `/health` when set.
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
manifest it reads, never ranks candidates and never chooses one. Contract in
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
| `GET /` | the Projects index — every project you own as a card with its latest previews (the workspace root; `GET /projects` is the same view). The old global Jobs page is gone: the jobs list lives on the project workspace | — | HTML |
| `GET /projects/new` | the new-project form | — | HTML |
| `POST /projects` | create a project — the container a job, composite or output belongs to | `project[name]`, `project[is_test]` | `302` to `/projects/:id` with a notice; `422` re-render of the form |
| `GET /projects/:id` | the project workspace: the project's OWN jobs list (List/Grid two-view), composites and outputs | — | HTML |
| `GET /jobs/new` | the Run Job form (fields switch on the runner's kind; opens with the **template picker** — `POST /templates/use` applies one) | query `input_path`, `preview_url`, `name`, `carried_from` | HTML |
| `POST /jobs` | **file a job** | `job[name]`, `job[source_kind]`, `job[input_path]`, `job[runner]` (validated against the configured labels), `job[spec]` (a JSON string), `job[project_id]` (the owning project — `Job belongs_to :project, optional: true`, and a job filed WITHOUT one appears in no workspace, only at its direct URL) | `302` to `/jobs/:id` on success — HTML; `422` with `{"error": …}` when the request carried `Accept: application/json` |
| `POST /jobs/upload` | store a PNG/JPEG (≤ 50 MB, magic-byte checked) and return what the form needs | multipart `file` | JSON `{path, preview_url, name, size}` |
| `GET /jobs/upload_preview/:name` | serve a just-uploaded raster behind the login gate | basename matching `[\w.\-]+` | the image bytes |
| `GET /jobs/:id` | the job page: candidate table, proofs, sweeps, findings | — | HTML |
| `GET /jobs/:id.json` | **poll** a job | query `log=1` for the runner log tail; `candidate=<file>` for that candidate's full detail | `{done, log_html}`; with `log=1`: `{log: […]}`; with `candidate=`: `{file, job, spec, sweep, proof}`. Full shapes: [`jobs-json.md`](jobs-json.md) |
| `GET /jobs/:id/refresh` | force a sync from the runner | — | `302` back to the job |
| `GET /jobs/:id/file/:name` | proxy one runner artefact (candidate SVG, proof PNG, PDF, manifest) | `name` matching `[\w.\-]+`; `?download=1` for an attachment | the file bytes; `400`/`404`/`502` as headers |
| `GET /jobs/:id/download` | the whole job, bundled | the job must be `done` | a 7z attachment (a flux job's bundle is the studio's own provenance archive, carrying the runner's inside it; a bp/plot/blender job has no runner job at all and gets `StudioArchive` — the studio's own 7z of the spec (`job.json`, ask + answer) plus the artefact it holds). A job that holds nothing offers **no Download button** — the row shows a muted mark instead — and the route answers with the `Archive failed: …` alert |
| `POST /jobs/:id/use_inverse` | take the job's colour-inverted prep twin and pre-fill a **new** job form with it | — | `302` to `/jobs/new` pre-filled |
| `POST /jobs/:id/reuse` | "run again" from a source/inverse preview: clone the spec into a new job form | `name` ∈ `source.png`, `source.inverse.png` | `302` to `/jobs/new` pre-filled |
| `POST /jobs/:id/cancel` | cancel a job (discard a queued one, or ask the runner to stop) | — | `302` to the owning project (`/projects/:id`), or `/` when the job has no project; JSON: `200` empty body (`head :ok`) |
| `DELETE /jobs/:id` | delete a job: log the event, tell the runner, drop the record | — | `302` to the owning project, or `/`; JSON: `200` empty body (`head :ok`) |

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
| `POST /scrapbook/:id/artwork` | copy an item into uploads so it can be a job's **artwork** (the Run Job source). Separate from `:use`, which redirects to the form and would discard a form the operator had already filled in | — | JSON `{path, preview_url, name, size, source_kind}`; `404` when the stored file is gone; `422` for an SVG/PDF item, because the trace stage preps its source with PIL |
| `POST /scrapbook/save_upload` | save a **local** upload (a generated variation, which has no runner job behind it) into the scrapbook | `name` (a basename inside `storage/uploads`), optional `job_id` | JSON item, or `302` for an HTML caller |
| `POST /scrapbook/import` | import a raw PNG/JPEG (an edited scrape) as a new item | multipart `file` | `201` the item JSON |
| `GET /composite`, `GET /composite/new`, `GET /composite/list` | the composite builder: the editor, a blank one, the list | — | HTML |
| `GET /composite/layers` | the layers available to assemble a composite | — | JSON `[{id, name, kind, layer_kind, item_kind, vector, url}]` (the 200 most recent scrapbook items) — `kind`/`layer_kind` is `vector` for an SVG item, else `raster` |
| `POST /composite`, `PATCH /composite/:id` | create / update a composite (its layers arrive as a JSON string; a layer's `kind` is `raster` by default and `vector` for an SVG composed as vectors). `palette` is an optional comma-separated list of `#rrggbb` | `composite[...]`, top-level | `302` |
| `GET /composite/:id/recipe` | **the compose spec**: the EXACT document this composite's vector flatten POSTs to the svg runner's `/compose` (`{width, height, background, palette, layers: [{type, src, x, y, w, h, opacity, hue}]}`), with every vector layer's `src` inlined as SVG text and every raster layer's as a data URI. The one JSON contract an agent reads to drive compose → collect | — | JSON; `422 {error}` when a vector layer's source is missing or is not an SVG |
| `POST /composite/:id/chain` | **the one-call compose**: compose the composite's vector layers into the stored SVG artefact and record the compose job in the history, then return the created artefact + job (201). A `palette` query param; optional body `name`/`runner` overrides. Does NOT file a trace job — the composed SVG is the compose deliverable, not a trace source (trace needs a raster) | `palette` (query), `name`/`runner` (body) | JSON `{composite_id, scrapbook_id, path, preview_url, mode, content_type, job, job_url}`; `422` no vector layer / uncomposable spec; `502` runner error envelope |
| `POST /composite/:id/flatten` | flatten a composite into one artefact, stored twice (a scrapbook item + the upload the runner reads). **Raster** (a raster-only composite): the browser posts the composed PNG. **Vector** (any `vector` layer): the studio POSTs the recipe to the svg runner's `/compose` and stores the returned SVG, so a trace is never rasterised and re-traced. `mode: "raster"`/`"vector"` says which ran; `mode=raster` forces the PNG path | multipart `file` (PNG, raster path); optional `palette`; optional `mode` | JSON `{scrapbook_id, path, preview_url, content_type, mode}`; `400` not a PNG; `422` an uncomposable composite; `502` the runner refused |
| `POST /composite/:id/use`, `DELETE /composite/:id` | use a flattened composite for a new job, delete it | — | `302` |
| `POST /composite/template` | **arrange** the layers it is handed — or a stored composite's, when `id` is present — under one template (`grid`/`stack`/`row`/`hero`/`thirds`/`mirror`), and **couple** them. Given no id it touches no database, which is what makes it usable from the unsaved builder page | `layers` (a JSON array; defaults to the stored composite's), `template`, optional `id`, `width`, `height`, `margin`, `gap`, `save` | JSON `{layers, template, constraints, templates, …}` — the layers RE-PLACED AND COUPLED; `400` when `layers` will not parse; `422 {error}` naming the templates for an unknown one |
| `GET /composite/:id/metrics` | **how the pieces SIT**: alignment, even-gap spacing, frame fit, balance, coverage, overlap (reported, never scored) and coupling, under one weight table. Served per composite and aggregated into `EngineMetrics.metrics[:composites]`, so `/engine.json` carries it. It ranks nothing — the pipeline's no-winner rule does not stop applying because the pieces are rectangles | — | JSON `{composite_id, name, width, height, vector, metrics, residual, constraints, vocabulary}` |
| `GET /events` | **the recorded learning signal** — the human actions (`star`/`unstar`/`pick`/`delete`) a later learned ranker trains on. Read-only, owner-scoped | query `event`, `job_id`, `limit` (default 200, max 1000) | JSON `[{id, event, job_id, svg_sha, pos, ranker, payload, created_at}]` |
| `GET /engine.json` | **the system aggregate**: runner health per label, this owner's event counts by kind, job/candidate/scrapbook counts, what the pipeline produced (`use`), the host's newest CPU/memory/swap sample (`host`), and the ranker's cold/live state. The machine-readable twin of the footer's check-engine light | — | JSON (see below) |
| `GET /audit`, `GET /audit.json` | **the data debt, counted** (#95): every structural gap the studio's own tables expose — records with a blank optional-but-expected field, rows whose parent is gone, states that can never settle, and the domain gaps (candidates never proved, projects that never ran, validations that errored). Per class and per project, each with the literal id list behind the count. Read-only and pollable: aggregate counts plus `pluck`ed id lists, never a join of whole tables. `/audit` renders the page; `/audit.json` is the document. Filters are GETs on the same route: `?gap=jobs.missing_source` is the id list behind ONE count, `?project=<id>` the unresolved rows in ONE project | query `gap`, `project` | HTML; JSON (see below) |
| `GET /graph`, `GET /graph.json` | **the studio as one shape** (#96): every project, job, candidate and proof the signed-in owner can see, joined by the containment and pick lines between them, drawn as a force-directed SVG. Read-only, and a NAVIGATION surface — a node's `url` is the record it was drawn from (a project, a job, a proof page, or the job page carrying the candidate's file), and clicking a node focuses it and its neighbourhood. One route, two shapes: `/graph` renders the page, `/graph.json` the document. Node art is a candidate's SVG or a proof's render PNG, served through this app's own login-gated file routes; a node with no artwork gets a placeholder | — | HTML; JSON `{nodes, edges}` (see below) |
| `POST /reports` | **file a report** — the footer's maintenance button (`data-popup="bug-report-popup"`). Any signed-in operator describes what happened, what they expected, or a suggestion, and it becomes a GitHub issue carrying `needs-triage` plus a kind label (`bug` / `expectation` / `suggestion`). The controller adds the facts the reporter cannot see: the page, the account handle, the studio version, the user agent | `report[kind]`, `report[summary]`, `report[happened]`, `report[expected_behaviour]`, `report[details]` | JSON `{ok: true, url, number}`; `422 {ok: false, error}` when the token is unset or GitHub refuses — **and the form keeps every word**, because the popup posts with fetch rather than navigating. `302` + flash for a non-JSON caller. There is no `GET`: a report is filed, not listed |
| `GET /up` | the Rails health check | — | `200` when the app boots, else `500` |
| `GET /login`, `POST /login`, `DELETE /logout` | the password gate. There is no username: the password *is* the identity | `password` | `302` into the app, or `401` with the login page |
| `GET /json`, `POST /json/use` | the spec builder and "use this spec" | a spec document | HTML / `302` |
| `POST /templates/use` | apply a job **template** to the contract — the twin of `json/use` and the reason the Run Job form opens with a template picker. The textarea's current spec is the BASE the template refines (it never replaces a hand-written contract wholesale), and the template's live panel levers override both | `template` (a `PipelineConf::TEMPLATES` key — `standard`, `screenprint`, `photo`, `deep_sweep`, `generate_and_trace`, `generate_only`, `draw_document`, `render_3d`), `spec` (the base JSON string), plus the exposed panel levers | HTML `302` to `/jobs/new?spec_draft_token=…` (the composed draft in `SessionDraft`); JSON `{template, spec}`; `422 {error}` for an unknown key or an unknown lever |
| `GET /about`, `GET /flux`, `GET /bp`, `GET /status`, `GET /jev` | reference pages for the whole system: what each sidecar is, the models and their licences, the geometry/metrics/3D contract, the ML/ranking configuration, the decision sidecar, and a simulated bracket. `GET /plot` and `GET /blender` are the older names for the blend-plot page — both `301` to `/bp` | — | HTML |
| `GET /datasets`, `GET /datasets/surface` | the public corpora the studio draws from: DiffusionDB prompts and MET-Meme's annotation vocabulary. The `surface` form is the cards alone, for the FLUX page's DATASETS popup | query `topic`, `root`, `q`, `page` | HTML |
| `GET /datasets/library` | the prompt library as JSON — the twin an agent reads to pick a prompt without scraping the table | query `topic`, `root`, `q`, `limit` (default 20, max 200) | JSON `{census, filters, count, prompt: [...]}`, each row `PromptSource#to_contract` |
| `GET /datasets/draw` | one prompt (or a few) drawn at random, optionally filtered — what a caller wants when it needs a prompt rather than a list | query `topic`, `root`, `count` (default 1, max 20) | JSON `{count, prompts: [...]}` |
| `GET /datasets/meme-labels` | the MET-Meme scheme as JSON, transcribed into `MemeVocabulary` (pinned against the source's README) | — | JSON (the nine annotation fields and their vocabularies) |
| `POST /datasets/use` | put a prompt (by `id`, else a random draw) onto the Run Job form, as a DRAFT the operator then edits — never as a committed value, and never silently replacing what they had typed | `id` | `302` to `/jobs/new`; `302` back to the library with an alert when it is empty |

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
  "use": { "jobs": 0, "generated": 0, "traced": 0, "proofs": 0, "scrapbooked": 0, "composited": 0 },
  "host": {
    "sampled": true, "sampled_at": "2026-09-29T12:34:00Z", "stale": false,
    "values": { "cpu_pct": 23.4, "mem_pct": 42.3, "mem_used_mb": 1596, "mem_total_mb": 3777,
                "swap_pct": 20.0, "swap_used_mb": 390, "swap_total_mb": 1953, "load1": 0.97 },
    "window": { "window_seconds": 21600, "bucket_seconds": 300, "points": 3,
                "from": "…", "to": "…", "series": ["cpu", "mem", "swap"] }
  },
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

### `GET /audit.json` shape

```json
{
  "owner": "<operator-handle>",
  "generated_at": "2026-10-21T12:00:00Z",
  "total": 48,
  "needs_attention": 9,
  "groups": [
    { "key": "jobs", "label": "Jobs", "model": "Job", "n": 12,
      "states": { "pending": 0, "queued": 0, "running": 0, "done": 9, "error": 2, "cancelled": 1 },
      "empty_state_names": ["pending", "queued", "running"],
      "gaps": { "missing_runner_stem": 1, "missing_finished_at": 1, "missing_project": 0,
                "missing_source": 2, "error_without_message": 0, "orphan_project": 0,
                "orphan_source": 0, "stranded_running": 0 },
      "unresolved_ids": [7, 19, 20] }
  ],
  "by_project": [
    { "id": 3, "name": "hero-print", "jobs": 4, "candidates": 9, "validations": 2,
      "composites": 1, "projects": 1, "unresolved": 3, "unresolved_ids": [7, 19, 20],
      "gaps": { "jobs.missing_source": 2, "candidates.no_proof": 2 } }
  ]
}
```

One group per audited class (`jobs`, `candidates`, `validations`, `projects`,
`composites`). `total` is every row looked at; `needs_attention` is every row
found unresolved — the number to watch shrink.

- **`gaps` is strictly row-backed.** Each value is the size of the exact
  relation `unresolved_ids` is read off (one two-column pluck feeds both — the
  count is `ids.size` off it, deliberately not a SQL COUNT), so a count and the
  list behind it cannot disagree. That is the whole point, and the reason the
  reference this follows (a reference app's `/api/audit`) could not be copied: its
  `no_subtext` join overcounted because it read a derived key set.
- **`states` / `empty_state_names` are deliberately NOT in `gaps`.** A state with
  zero members has no ROWS, so it cannot back an id list; reporting it inside
  `gaps` would break the invariant above. The state vocabulary is still reported,
  with the empty ones named.
- **`by_project` keys its gap counts as `group.key`** (`jobs.missing_source`),
  because `orphan_job` is a real check in two classes and a bare key would let
  one overwrite another. The qualified form is also the `?gap=` filter param.
- **Adding a check is one line** in `AuditGaps::GAPS` (`group`, `key`, `name`,
  `rows`) — no second list to keep in step. The `#107` epistemic-flag checks slot
  in the same way.
- Every count is the **signed-in owner's**: `Candidate` has no owner column, so
  its rows are scoped through the jobs the owner can see.
- `generated_at` is the only key that moves between reads; the counts and id
  lists are stable, so a diff over time reads as "the numbers changed".

### `GET /graph.json` shape

The document behind the GRAPH page (#96): the studio's own records as one shape.
`GET /graph` renders the page; `GET /graph.json` renders the document — one
route, two shapes, the way `/audit` and `/audit.json` are.

```json
{
  "nodes": [
    { "id": "job:37", "type": "job", "tier": "B", "name": "hero-print",
      "url": "/jobs/37", "state": "done", "art": null, "empty": false },
    { "id": "candidate:37:12", "type": "candidate", "tier": "C",
      "name": "candidate_06.svg", "url": "/jobs/37?candidate=candidate_06.svg",
      "state": "pass", "art": "/jobs/37/file?name=candidate_06.svg", "empty": false }
  ],
  "edges": [
    { "from": "project:3", "to": "job:37", "kind": "parent" },
    { "from": "job:37", "to": "proof:51", "kind": "proof" }
  ]
}
```

- **Exactly two keys.** `{nodes, edges}` — a consumer written against this shape
  keeps reading it, and the page and the document are the same route, so neither
  can drift from the other.
- **Every node carries the same eight fields.** `id` is unique and stable for a
  given record (`"job:37"`, `"candidate:37:12"`, `"proof:51"`). `name` is the
  record's own name **verbatim** — it is data, and the page renders it with
  `textContent`, never as markup. `url` is the REAL record the node opens.
- **`type` and `state` are two different questions.** `type` is the entity CLASS
  (project / job / candidate / proof) and it is what the node's colour means.
  `state` is the record's WORK STATE (running / error / pass / fail / pending /
  done / cancelled) and it is drawn as a ring around the class dot — the
  devgraph rule that a class and a state are never the same colour. A project has
  no `state` (it is a container with no run of its own) and `null` is served
  rather than an invented one.
- **`art` is a URL, never bytes.** A candidate's SVG and a proof's render PNG,
  served through this app's own login-gated file routes (`/jobs/:id/file?name=`),
  so the artwork needs a session exactly like the page that shows it. `null` for
  a project and a job, which carry no artwork of their own, and for a proof that
  never finished. The page sets it on an `<image>` with `setAttribute`; the bytes
  are never parsed as markup, and a placeholder data URI stands in for a node
  whose artwork is missing.
- **`empty` is the MISSING/EMPTY marker**, distinguished from a settled node: a
  project that never ran, a job that settled with nothing traced, a candidate
  never proved, a proof with no manifest. It is drawn as a dashed ring — the
  same convention the audit page uses for absent-but-optional data.
- **Edges point parent → child** (`project → job`, `job → candidate`,
  `job → proof`, `candidate → proof`), which is the reverse of the kb's own
  child → parent pointer. Every line runs from the container to the thing it
  contains, so the graph reads as the lineage a reader traces. `kind` is
  `"parent"` (dashed) or `"proof"` (solid), and one edge per unordered pair —
  a job and a candidate are never joined twice.
- **A candidate's record is the job page carrying its file.** Candidates have no
  page of their own, so `url` is `/jobs/:id?candidate=<file>`; the same file is
  what `GET /jobs/:id.json?candidate=<file>` reads.
- **A proof is named for the candidate it proves** (`candidate_06.svg` →
  `proof_06`), never by a database id — the rule the proof page's own title
  follows.
- Every node is the **signed-in owner's**: `Project` and `Job` carry `Owned`'s
  scope, and `Candidate` / `Validation` are read through the owner's own jobs.
- No new tables and no new columns: every field is read off records that already
  exist.

