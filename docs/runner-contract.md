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
