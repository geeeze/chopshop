# Chopshop Studio runner contract (v1)
#
# The Rails app drives chopshop-svg over HTTP. In mock mode the transport is a
# local Python service; in live mode the same service runs on am5 over
# Tailscale. Both implement THIS contract and call ./front_pipeline.sh and
# ./pipeline.sh unchanged.
#
# Runner base URL is configured per-job via Job#runner ("mock" -> local, "am5"
# -> https://...:8787). Auth: bearer token in RUNNER_TOKEN env on both sides.
#
# All responses are JSON.
#
# POST /jobs
#   params: { name, source_kind, input_path, spec (JSON) }
#   -> 202 { id, stem }
#   Kicks off front_pipeline.sh <input> on the runner (async). Spec is written
#   to a per-job spec file; front half runs with SPEC=<that file>.
#
# GET  /jobs/:id
#   -> 200 { id, state: queued|running|done|error, log_tail (last ~40 lines),
#            prep_summary, candidate_count,
#            comparison (the parsed 04_validated/<stem>.comparison.json) }
#   state "done" implies comparison present.
#
# GET  /jobs/:id/candidates
#   -> 200 { candidates: [ { file, preset, hierarchical, filter_speckle,
#            use_palette, layer_a, layer_b, hard, advisory, fidelity, passed } ] }
#
# GET  /files/:job_id/:name        (SVG candidate, proof PNG, print PDF, manifests)
#   -> 200 file bytes (content-type from extension)
#
# POST /validations
#   params: { job_id, candidate_file }
#   -> 202 { id }
#   Runs pipeline.sh 02_traced/<stem>/<candidate_file> on the runner (async).
#
# GET  /validations/:id
#   -> 200 { id, state, manifest (parsed 05_final manifest.json), error }
#
# GET  /health
#   -> 200 { ok: true, host: <hostname>, tools: { inkscape: bool, gs: bool } }
#
# Requirements on the runner box:
#   - chopshop-svg checked out with .venv built and system tools present
#   - a work dir writable by the runner for uploads; input_path is absolute
#   - serves ONLY on the tailnet interface (tailscale serve / direct bind to
#     the tailscale IP) — never public
