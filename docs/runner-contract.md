# Chopshop Studio runner contract (v1)
#
# The Rails app drives chopshop-svg over HTTP. In mock mode the transport is a
# local Python service; in live mode the same service runs on another host on a
# private network. Both implement THIS contract and call ./front_pipeline.sh and
# ./pipeline.sh unchanged.
#
# Runner base URL is configured per-job via Job#runner ("mock" -> loopback, live
# runners -> their private-network URL). Auth: bearer token in RUNNER_TOKEN env
# on both sides; a missing or wrong token answers 401 {"error": "unauthorized"}.
# The live runner (chopshop-svg runner.py) serves RUNNER_PORT (default 8787)
# bound to RUNNER_BIND.
#
# NAMES ARE CONFIGURATION, NOT FACTS. Nothing here should name a specific host,
# hostname, or VPN: a runner is identified by the label it reports at
# GET /health, and the studio keys its dropdown off that. Add a runner by setting
# CHOPSHOP_RUNNER_<LABEL>_URL; do not add a machine to this document or to
# Job::RUNNER_DEFAULTS.
#
# All responses are JSON. An unrouted request answers 404 {"error": "unknown route"}.
#
# POST /jobs
#   params: { name, source_kind, input_path, spec (JSON) }
#   -> 202 { id, stem }
#   Kicks off front_pipeline.sh <input> on the runner (async). Spec is written
#   to a per-job spec file; front half runs with SPEC=<that file>.
#   -> 400 { error } if input_path is unreadable or outside the runner's shared
#      upload root. The live runner maps the host path through
#      HOST_UPLOAD_ROOT/CONTAINER_UPLOAD_ROOT, then copies and downscales the
#      upload into the JOB DIRECTORY (MAX_INPUT_DIMENSION, 1500), so what the
#      pipeline is handed is that per-job copy, not the caller's original path.
#   source_kind is studio-side bookkeeping; the runner ignores it.
#
# GET  /jobs/:id
#   -> 200 { id, state: queued|running|done|error, log_tail (last ~40 lines),
#            prep_summary, prep_expand, candidate_count,
#            comparison (the parsed 04_validated/<stem>.comparison.json),
#            error }
#   state "done" implies comparison present. prep_expand is the expanded-prep
#   summary (null unless spec.print.prep_expand was asked for); error is null
#   unless the job failed or was cancelled.
#   WHAT THE STUDIO DOES WITH THIS PAIR, because the difference matters to an
#   operator waiting on a bench. prep_summary IS captured
#   (Job#sync_from_runner!) -- it is the activity line the job page shows while a
#   job runs. prep_expand IS captured too: sync_from_runner! stores it in the
#   jobs.prep_expand column (JSON), and the job results page renders it as a
#   block inside the right-hand column of .results-split, after the proofs and
#   before the sources. The block appears only when the runner reported a
#   bench (the job's spec asked for print.prep_expand and the job completed).
#   The runner also copies the flat report files (prep-expand.json,
#   prep-expand.md, tune.json, tune.md, tune-contact-sheet.png, node-reduce.json,
#   filters.json/filters.md/filters-contact-sheet.png) to the JOB ROOT beside the
#   raw tree at prep_expand/, so the archive download still carries the full
#   bench tree for offline analysis.
#
# GET  /jobs/:id/candidates
#   -> 200 { candidates: [ { file, preset, hierarchical, filter_speckle,
#            use_palette, layer_a, layer_b, hard, advisory, fidelity, passed } ] }
#   DOCUMENTED, BUT NOT PART OF THE LIVE SURFACE: runner.py does not implement
#   it (it answers 404 unknown route) and nothing in the studio calls it. The
#   mock runners serve it for older clients, and the studio reads the candidate
#   list out of GET /jobs/:id's "comparison" instead. Do not build against it.
#
# GET  /jobs/:id/archive
#   -> 200 the job's directory as a 7z (application/x-7z-compressed, attachment)
#   -> 409 { error } while the job is not done
#   -> 404 { error } if the job directory is missing
#   -> 507 { error } if the disk is under 1 GiB free (MIN_ARCHIVE_FREE)
#   -> 500 { error } if no 7z binary is present -- building the archive is the
#      expensive step, not writing one. The studio's Download button streams this.
#   THE JOB DIRECTORY IS THE UNIT OF DELIVERY. This archives that directory and
#   DELETE below removes it, so anything a job produces must be written INSIDE
#   it. A per-job artifact written into a shared project tree is missing from
#   the download and survives the delete, leaking into the next job.
#
# GET  /jobs/:id/dataset
#   -> 200 ONE <candidate_stem>.dataset as a 7z (application/x-7z-compressed,
#      attachment), built on demand and unlinked after the response, exactly like
#      the archive above -- the studio gives it the archive's 120s read timeout
#      (RunnerClient::DATASET_READ_TIMEOUT), never the 15s every other call gets.
#   The opt-in behind it: with spec.validation.variants on, the back half runs
#   proof_variants.py AFTER the proof, PDF and manifest are written, and adds a
#   `dataset` block to the manifest ({dir, manifest, sheet, package, count,
#   transforms}). The stage is additive -- a failure in it is appended to the
#   manifest's notes and the proof still settles to done -- so the studio's proof
#   card is driven off that manifest key and is absent when the key is absent.
#   -> 409 { error } while the job is not done
#   -> 404 { error } if the job directory is missing, or the job holds no dataset
#   -> 400 { error } when the job holds SEVERAL datasets and ?candidate= is
#      missing (an ambiguous request is never a guess), or when the candidate
#      name is not [\w.\-]+
#   -> 507 { error } below the 1 GiB free floor (MIN_ARCHIVE_FREE)
#   -> 500 { error } if no 7z binary is present
#   ?candidate=<candidate_file> names WHICH dataset -- the runner derives the
#   stem (<candidate_01.svg> -> <candidate_01>) -- and may be omitted when the job
#   has exactly one. The stream is named after the STEM, `<stem>.dataset.7z`.
#   The studio's Download-dataset control on a proof streams this.
#
# POST /jobs/:id/cancel
#   -> 200 { state: "cancelling" } | { state: "cancelled" }
#   -> 409 { state } once the job is done or errored
#   Cooperative: it raises a flag the worker checks between steps (the live
#   runner also terminates the running stage's process), so the job settles to
#   state "cancelled" with error "cancelled by operator".
#
# DELETE /jobs/:id
#   -> 200 { deleted: <id> } ; drops the job record and removes its directory
#      (the Delete button). A queued/running job is cancelled first.
#
# GET  /files/:job_id/:name        (SVG candidate, proof PNG, print PDF, manifests)
#   -> 200 file bytes (content-type from extension)
#   -> 400 { error } if <name> is not [\w.\-]+ (what rejects path traversal)
#   -> 404 { error } if the job is unknown, or the artifact does not resolve.
#      The live runner also serves the stable names source.png and
#      source.inverse.png, resolving them from the upload or 01_prepped for jobs
#      that predate them; an absent image must 404 so the tile self-hides.
#
#   PUBLISHED NAMES: a job filed with a name publishes its artifacts under it --
#   <name>-candidate-01.svg, <name>-proof-01.png/.pdf/.manifest.json -- so a
#   download says which run it came from. That is a publish-time rename in the
#   runner's JOB DIRECTORY: the pipeline's own names (02_traced/<stem>/
#   candidate_NN.svg, 05_final/<candidate stem>.proof.png) are unchanged, the
#   comparison entry's `file` and the manifest's `proof`/`print_pdf` point at the
#   published spelling, and a job directory published before the rename keeps the
#   OLD spelling. BOTH resolve here, so either may be requested; POST
#   /validations accepts either spelling of candidate_file too. The studio's
#   side of the mapping is ApplicationHelper#proof_name and
#   ScrapbooksController#kind_from_name.
#
# GET  /files/:job_id/<stem>.dataset/<name>
#   -> 200 file bytes (content-type from the extension)
#   THE ONLY ROUTE WHOSE REQUEST MAY CONTAIN A SLASH, and the only /files/ URL
#   with FOUR path segments: <name> is one file INSIDE a dataset directory --
#   raster/<transform>.png, vector/<transform>.svg, dataset.json or dataset.md.
#   The three FLAT dataset names (<stem>.dataset.json, <stem>.dataset.md,
#   <stem>.dataset-contact-sheet.png) sit at the JOB ROOT on purpose, so they go
#   through the three-segment /files/:job_id/<name> route above and the studio
#   requests them by name alone.
#   -> 400 { error } when the RESOLVED path escapes the dataset directory -- a
#      `..` segment, an absolute name, a backslash or a symlink out of the tree.
#      Containment is re-checked on the resolved path precisely because the flat
#      route's [\w.\-]+ name regex cannot see across the extra segment.
#   -> 404 { error } for an unknown job, or a <stem>.dataset that the job does
#      not hold.
#
# POST /validations
#   params: { job_id, candidate_file }
#   -> 202 { id }
#   Runs pipeline.sh 02_traced/<stem>/<candidate_file> on the runner (async).
#   -> 409 { error } if the job is not done; 404 { error } if the candidate is
#      not in the job's list.
#
# GET  /validations/:id
#   -> 200 { id, state, manifest (parsed 05_final manifest.json), log, error }
#
# POST /validations/:id/jev
#   params: { job_id, candidate_file }
#   -> 200 the Jev decision sidecar: { model, endpoint, latency_ms, answers,
#            verdict }
#   The studio's Ask Jev button. ADVISORY ONLY -- Jev never overrides a gate and
#   never picks a candidate; it annotates one the operator already chose. The job
#   and candidate ride along because a runner holds validations in memory only:
#   after a restart it resolves the manifest from disk instead of 404ing a route
#   that works fine.
#   -> 409 { error } while the validation is still running
#   -> 503 { error } when the add-on is not configured on this runner (no
#      annotator, or no API key). NEVER 404 -- a 404 would read as "no such
#      route" and send the operator hunting a wiring bug that is not there.
#   -> 404 { error } only when neither the id nor the job_id/candidate_file
#      fallback resolves a manifest on disk.
#
# POST /recolour
#   params: { job_id, file, map: { "#src": "#dst", ... } }
#   -> 200 the candidate SVG, recoloured in place (image/svg+xml)
#   Recolours one candidate's paint by an explicit source->target map. Only
#   fill/stroke/stop-color are rewritten through the CSS cascade; geometry,
#   node count, viewBox and dimensions are untouched, so the preview is the
#   real vector, never a raster round-trip. The map is validated -- every key
#   and value must be a plain #rrggbb or the request answers 400 rather than
#   silently dropping a typo.
#
#   NO STUDIO CONSUMER YET: the seam exists on the runner side only -- no studio
#   client or view calls /recolour, and there is no colour-cycling control. It is
#   held `unused` in test/lib/runner_contract_test.rb (as is /recolour/colours)
#   so the absence is a decision rather than an oversight, and this endpoint is
#   the surface such a control would be built on when one is wanted.
#
# POST /recolour/colours
#   params: { job_id, file }
#   -> 200 { file, colours: ["#...", ...] }  (distinct declared paints, most-used first)
#   Lists the distinct declared paints of one candidate -- what a colour-cycling
#   picker (not built yet, see above) would offer to replace. Element-count
#   ordering only (instant); rendered-area weighting is palette_variants' job,
#   not this live endpoint's.
#
# POST /compose
#   params: { op, spec }
#   -> 200 the merged SVG, inline (image/svg+xml)
#   -> 422 { error, kind: "invalid_spec" } for a spec that cannot be merged
#   -> 500 only for a merge that fails unexpectedly
#   THE COMPOSITION OPERATION. The pipeline traces one raster into SVG candidates
#   and checks one SVG, so it could not MERGE several pieces into one printable
#   artwork. The obvious implementation -- rasterise the layers, then re-trace the
#   composite -- throws away the vectors the trace stage just produced
#   (re-quantised colours, doubled node counts, lost text and geometry), so
#   /compose merges instead: every `type: "svg"` layer STAYS A VECTOR.
#   `spec` is {width, height, background, palette?, layers: [{type, src, x, y, w,
#   h, opacity, hue, crop?}, ...]}, painted in list order. `src` is ALWAYS inline -- a
#   full SVG document string for a vector layer, a `data:` URI for a raster one --
#   so a compose request never reads the runner's disk. `crop` (raster only) is
#   the builder's manual crop: fractions of the source (0..1) the runner cuts
#   through a nested <svg> viewport, the same rect the canvas preview drew. A vector layer's inline
#   document is parsed and wrapped in a transform group, so a layer with a viewBox
#   lands where the caller placed it; `hue` on a vector layer becomes an
#   feColorMatrix filter (a filter ELEMENT, which a rasteriser honours, never a
#   CSS `filter:` declaration). A `palette` snaps the merged document's paint and
#   reports a colour it did not ask for rather than failing the merge.
#   CALLED BY ComposeClient, NOT RunnerClient: the one caller is
#   CompositesController#flatten, which takes this route whenever a composite
#   holds ANY vector layer, so a traced source is never rasterised and re-traced,
#   and falls back to the browser's canvas PNG (the raster path) when it does not.
#   The recipe that is posted is the composite's own GET /composite/:id/recipe, so
#   an agent can read the exact spec the studio would send.
#   LIVE in test/lib/runner_contract_test.rb -- a real call site, unlike the
#   recolour pair above.
#
# GET  /health
#   -> 200 { ok: true, host: <label>, mode: "real" | "mock",
#            tools: { inkscape: bool, gs: bool, jev: bool } }
#   `host` is a LABEL (CHOPSHOP_RUNNER_LABEL), not a fact about the machine -- it
#   exists so the studio's dropdown has something to show, and so nothing in a
#   published file names a real host. The live runner always reports mode "real";
#   the mock reports "mock". `tools.jev` is false when the decision sidecar is
#   unavailable, which the studio surfaces BEFORE the operator presses Ask Jev
#   rather than after.
#
# Requirements on the runner box:
#   - chopshop-svg checked out with .venv built and system tools present
#   - a work dir writable by the runner for uploads; input_path is absolute
#   - serves ONLY on a private interface (VPN, or a direct bind to the private
#     address) — never on a public one. Set RUNNER_BIND to the specific address;
#     the default 0.0.0.0 is a footgun here, since it listens on every interface.
