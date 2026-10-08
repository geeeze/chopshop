#!/usr/bin/env bash
# demo_smoke.sh — ONE sequential demonstration pass over the LIVE Chopshop stack.
#
# What it proves, in order:
#   0. the box answers and every runner it is configured for is reachable
#   1. an operator (the demo user) logs in, uploads a raster, traces it on the
#      REAL svg runner, picks a candidate, gets a proof, asks jev, downloads the bundle
#   2. the bp service draws a geometry document and renders one blender frame
#   3. the flux service generates a raster (klein-4b, 512, 4 steps — the cheap end)
#   4. a prompt drawn from the DiffusionDB library files a second generation job
#   5. a composite of vector layers is composed through the svg runner's /compose
#
# It is a SMOKE pass, not a load test: one job per stage, sequential, the small
# settings throughout. It creates ONE project (named for the run) and files every
# job under it, so a re-run never touches another project's history.
#
# Usage:
#   script/demo_smoke.sh                       # against the local deployment
#   CHOPSHOP_BASE=https://chopshop.geenet.work script/demo_smoke.sh
#   CHOPSHOP_DEMO_PASSWORD=... script/demo_smoke.sh
#
# Env: CHOPSHOP_BASE (default http://127.0.0.1:3001),
#      CHOPSHOP_DEMO_PASSWORD (default the demo account's),
#      ARTIFACT_DIR (where downloads land; default ~/.chopshop-smoke/<stamp>)
set -uo pipefail

BASE="${CHOPSHOP_BASE:-http://127.0.0.1:3001}"
PASSWORD="${CHOPSHOP_DEMO_PASSWORD:-demo-smoke-2026}"
STAMP="$(date +%Y%m%d-%H%M%S)"
PROJECT_NAME="smoke-$STAMP"
ARTIFACTS="${ARTIFACT_DIR:-$HOME/.chopshop-smoke/$STAMP}"
mkdir -p "$ARTIFACTS"
JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT

PASS=0; FAIL=0
declare -a NOTES=()
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); NOTES+=("$*"); }
hdr() { printf '\n\033[1m== %s\033[0m  (%s)\n' "$*" "$(date +%H:%M:%S)"; }
note(){ printf '        %s\n' "$*"; }

# curl with the session cookie and CSRF token. Every argument after the path is
# ONE `key=value` pair, each form-encoded separately — passing a joined
# "a=1&b=2" string to --data-urlencode encodes the whole thing as ONE field
# named "a", which silently drops every parameter after it.
req() { # METHOD PATH KEY=VALUE [KEY=VALUE ...]
  local method="$1" path="$2"; shift 2
  local args=()
  for pair in "$@"; do args+=(--data-urlencode "$pair"); done
  curl -sS -m 300 -c "$JAR" -b "$JAR" -X "$method" "$BASE$path" \
    -H "X-CSRF-Token: $TOKEN" "${args[@]}" \
    -w '\n%{http_code}' -D "$ARTIFACTS/last-headers.txt"
}
# A request whose BODY is JSON (not form-encoded). Writes the headers file so
# loc() can read the redirect off it, like req() does.
req_json() { # METHOD PATH JSON
  curl -sS -m 300 -c "$JAR" -b "$JAR" -X "$1" "$BASE$2" \
    -H "X-CSRF-Token: $TOKEN" -H 'Content-Type: application/json' \
    --data-binary "$3" -w '\n%{http_code}' -D "$ARTIFACTS/last-headers.txt"
}
code() { tail -n1; }        # last line of a req() reply is the status code
body() { sed '$d'; }        # everything before it is the body
# The Location header of the last request, as a PATH (the app answers with an
# absolute https:// URL; follow the path against the base already in use).
loc()  { grep -io '^location: .*' "$ARTIFACTS/last-headers.txt" | tail -n1 \
         | cut -d' ' -f2- | tr -d '\r' | sed 's#^https\?://[^/]*##; s#/$##'; }

# Poll a JSON read route until <key> is true. Echoes the body; non-zero on timeout.
poll() { # PATH KEY DEADLINE_SECONDS
  local path="$1" key="$2" deadline="${3:-900}" reply=""
  local end=$((SECONDS + deadline))
  while :; do
    reply="$(curl -sS -m 60 -c "$JAR" -b "$JAR" "$BASE$path")"
    if [ "$(printf '%s' "$reply" | jq -r "if has(\"$key\") then .\"$key\" else false end" 2>/dev/null)" = "true" ]; then
      printf '%s' "$reply"; return 0
    fi
    if [ "$SECONDS" -ge "$end" ]; then
      printf '%s' "$reply"; return 1
    fi
    sleep 5
  done
}

# ---------------------------------------------------------------- stage 0 -----
hdr "Stage 0 — the box and its runners"

curl -sS -m 30 "$BASE/up" >/dev/null 2>&1 \
  && ok "/up (the app boots)" || bad "/up did not answer"

# The runners the app is configured for, straight from the app itself — a
# deployment that adds a label is seen here without editing this script.
#
# Login: take the SESSION token out of /login's meta tag (the meta token is
# valid for any non-GET in this session; a token lifted from the login FORM is
# only good for that form), then post the password with it. The cookie jar is
# the whole session — there is no bearer token.
LOGIN_PAGE="$(curl -sS -m 60 -c "$JAR" -b "$JAR" "$BASE/login")"
TOKEN="$(printf '%s' "$LOGIN_PAGE" | sed -n 's/.*name="csrf-token" content="\([^"]*\)".*/\1/p' | head -n1)"
[ -n "$TOKEN" ] && ok "CSRF meta token taken from /login" || bad "no csrf-token on the login page"

RUNNERS="$(curl -sS -m 60 -c "$JAR" -b "$JAR" -X POST "$BASE/login" \
  -H "X-CSRF-Token: $TOKEN" -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "password=$PASSWORD" -o /dev/null -w '%{http_code}')"
[ "$RUNNERS" = "302" ] && ok "demo user logged in" || bad "demo login failed ($RUNNERS)"

# A fresh meta token after login: tokens are masked per request, and a reloaded
# page's token is not the one this session started with.
PAGE="$(curl -sS -m 60 -c "$JAR" -b "$JAR" "$BASE/projects")"
TOKEN="$(printf '%s' "$PAGE" | sed -n 's/.*name="csrf-token" content="\([^"]*\)".*/\1/p' | head -n1)"
[ -n "$TOKEN" ] && ok "CSRF meta token taken from the session" || bad "no csrf-token in the page"

ENGINE="$(req GET /engine.json | body)"
[ "$(printf '%s' "$ENGINE" | jq -r '.ok // false' 2>/dev/null)" = "true" ] \
  && ok "/engine.json answers as the demo owner ($(printf '%s' "$ENGINE" | jq -r '.owner'))" \
  || bad "/engine.json did not answer as expected"
note "owner=$(printf '%s' "$ENGINE" | jq -r '.owner')  runners=$(printf '%s' "$ENGINE" | jq -r '[.runners[].label] | join(",")')"

printf '%s' "$ENGINE" | jq -r '.runners[] | "\(.label)\t\(.kind)\t\(.url)\t\(.healthy)"' \
| while IFS=$'\t' read -r label kind url healthy; do
    printf '        runner %-6s %-6s %-28s healthy=%s\n' "$label" "$kind" "$url" "$healthy"
    if [ "$healthy" = "true" ]; then ok "runner $label is healthy"; else bad "runner $label is unhealthy"; fi
  done

# ---------------------------------------------------------------- stage 1 -----
hdr "Stage 1 — upload, trace on the real runner, pick, prove, jev, download"

# The project this run files everything under.
R="$(req POST /projects "project[name]=$PROJECT_NAME")"
LOC="$(loc)"
PROJECT_ID="$(printf '%s' "$LOC" | grep -oE '[0-9]+' | tail -n1)"
[ -n "$PROJECT_ID" ] && ok "project '$PROJECT_NAME' created (id $PROJECT_ID)" \
  || { bad "project create failed"; PROJECT_ID=""; }

# A real raster to trace: the demo render already in storage.
SOURCE="$HOME/chopshop-svg/00_source/00-example.png"
[ -f "$SOURCE" ] || SOURCE="$HOME/chopshop-studio/storage/uploads/demo-composite-render.png"
UP="$(curl -sS -m 120 -c "$JAR" -b "$JAR" -X POST "$BASE/jobs/upload" \
  -H "X-CSRF-Token: $TOKEN" -F "file=@$SOURCE" -w '\n%{http_code}')"
UPLOAD_PATH="$(printf '%s' "$UP" | sed '$d' | jq -r '.path // empty')"
[ -n "$UPLOAD_PATH" ] && ok "raster uploaded -> $UPLOAD_PATH" \
  || { bad "upload failed"; UPLOAD_PATH=""; }

if [ -n "$UPLOAD_PATH" ] && [ -n "$PROJECT_ID" ]; then
  SPEC='{"print_method":"screen_print","max_colors":6,"print":{"sweep":{"max_candidates":6}}}'
  R="$(req POST /jobs "job[name]=smoke-trace-$STAMP" \
                      "job[source_kind]=raster" \
                      "job[input_path]=$UPLOAD_PATH" \
                      "job[runner]=svg" \
                      "job[spec]=$SPEC" \
                      "job[project_id]=$PROJECT_ID")"
  TRACE_ID="$(loc | grep -oE '[0-9]+' | tail -n1)"
  [ -n "$TRACE_ID" ] && ok "trace job filed on runner 'svg' (job $TRACE_ID)" \
    || bad "trace job create failed: $(printf '%s' "$R" | sed '$d' | grep -oE '<[^>]*alert[^>]*>[^<]*' | head -n1)"

  if [ -n "$TRACE_ID" ]; then
    T0=$SECONDS
    if REPLY="$(poll "/jobs/$TRACE_ID.json" done 1500)"; then
      ok "trace finished in $((SECONDS-T0))s (6 candidates, done=true)"
    else
      bad "trace did not finish within 1500s — last: $(printf '%s' "$REPLY" | jq -c '.' 2>/dev/null || printf '%s' "$REPLY")"
    fi

    # The candidate list, read off the job page the way a person would. The
    # runner names them <job-stem>-candidate-NN.svg — a HYPHEN, and the studio
    # prints that stem verbatim into the proof POST, so scrape the page rather
    # than reconstructing the name.
    CAND="$(curl -sS -m 60 -c "$JAR" -b "$JAR" "$BASE/jobs/$TRACE_ID" \
            | grep -oE '[A-Za-z0-9_.-]*candidate-[0-9]+\.svg' | sort -u | head -n1)"
    [ -n "$CAND" ] && ok "candidates came back (first: $CAND)" \
      || bad "no candidate files on the job page"

    if [ -n "$CAND" ]; then
      R="$(req POST /proofs "job_id=$TRACE_ID" \
                            "candidate_file=$CAND")"
      PROOF_ID="$(loc | grep -oE '/proofs/[0-9]+' | grep -oE '[0-9]+')"
      [ -n "$PROOF_ID" ] && ok "proof filed on $CAND (proof $PROOF_ID)" \
        || bad "proof create failed"

      if [ -n "$PROOF_ID" ]; then
        T0=$SECONDS
        if REPLY="$(poll "/proofs/$PROOF_ID.json" done 900)"; then
          ok "proof done in $((SECONDS-T0))s"
        else
          bad "proof did not finish within 900s"
        fi

        # The decision sidecar — advisory, and the one call that takes real time.
        T0=$SECONDS
        JEV="$(curl -sS -m 300 -c "$JAR" -b "$JAR" -X POST "$BASE/proofs/$PROOF_ID/ask_jev" \
                -H "X-CSRF-Token: $TOKEN" -H 'Accept: application/json' -w '\n%{http_code}')"
        JEV_CODE="$(printf '%s' "$JEV" | tail -n1)"
        if [ "$JEV_CODE" = "200" ]; then
          # The answer's own headline, not the whole envelope — the popup shows
          # a sentence and the log should too.
          VERDICT="$(printf '%s' "$JEV" | sed '$d' \
                      | jq -r '.answers.headline // .meta.verdict // "?"' 2>/dev/null)"
          ok "jev answered in $((SECONDS-T0))s (headline: $VERDICT)"
        else
          bad "ask_jev returned $JEV_CODE"
        fi
      fi
    fi

    # The handoff: the job directory as a 7z.
    curl -sS -m 300 -c "$JAR" -b "$JAR" "$BASE/jobs/$TRACE_ID/download" \
      -o "$ARTIFACTS/smoke-trace.7z" -w '%{http_code}' -o /dev/null
    if [ -s "$ARTIFACTS/smoke-trace.7z" ] && 7z l "$ARTIFACTS/smoke-trace.7z" >/dev/null 2>&1; then
      ok "bundle downloaded ($(du -h "$ARTIFACTS/smoke-trace.7z" | cut -f1))"
    else
      bad "download is not a readable 7z"
    fi
  fi
fi

# ---------------------------------------------------------------- stage 2 -----
hdr "Stage 2 — bp: draw a document, render one frame"

if [ -n "$PROJECT_ID" ]; then
  # The spec is one JSON string, built with jq so the nested quotes are the
  # tool's problem rather than the shell's.
  DOC='{"canvas":{"width":400,"height":300,"background":"#ffffff"},"elements":[{"type":"rect","x":20,"y":20,"width":120,"height":80,"fill":"#e63946"},{"type":"circle","cx":280,"cy":180,"r":60,"fill":"#457b9d"}]}'
  DOC_JSON="$(jq -nc --arg doc "$DOC" '{bp:{op:"generate",doc:($doc|fromjson)}}')"
  R="$(req POST /jobs "job[name]=smoke-bp-draw-$STAMP" \
                      "job[runner]=bp" \
                      "job[project_id]=$PROJECT_ID" \
                      "job[input_path]=" \
                      "job[spec]=$DOC_JSON")"
  BP_ID="$(loc | grep -oE '[0-9]+' | tail -n1)"
  [ -n "$BP_ID" ] && ok "bp generate job filed (job $BP_ID)" \
    || bad "bp generate create failed: $(printf '%s' "$R" | sed '$d' | grep -oE 'alert[^<]*' | head -n1)"
  if [ -n "$BP_ID" ]; then
    if REPLY="$(poll "/jobs/$BP_ID.json" done 300)"; then
      ok "bp draw finished (done=true)"
    else bad "bp draw did not finish within 300s"; fi
  fi

  # One blender frame, small: the render is subprocess Blender, seconds not minutes.
  BDOC='{"elements":[{"type":"rect","x":0,"y":0,"width":100,"height":80,"fill":"#e04030"}],"extrude":{"depth":20},"render":{"size":{"width":256,"height":256},"views":1,"background":"#1a1a24","engine":"workbench","elevation":25,"projection":"ortho"}}'
  BLEND_DOC_JSON="$(jq -nc --arg doc "$BDOC" '{bp:{op:"blender",doc:($doc|fromjson)}}')"
  R="$(req POST /jobs "job[name]=smoke-bp-render-$STAMP" \
                      "job[runner]=bp" \
                      "job[project_id]=$PROJECT_ID" \
                      "job[input_path]=" \
                      "job[spec]=$BLEND_DOC_JSON")"
  BLEND_ID="$(loc | grep -oE '[0-9]+' | tail -n1)"
  [ -n "$BLEND_ID" ] && ok "bp blender job filed (job $BLEND_ID)" \
    || bad "bp blender create failed"
  if [ -n "$BLEND_ID" ]; then
    if REPLY="$(poll "/jobs/$BLEND_ID.json" done 600)"; then
      ok "blender frame finished (done=true)"
    else bad "blender did not finish within 600s"; fi
  fi
fi

# ---------------------------------------------------------------- stage 3 -----
hdr "Stage 3 — flux: one generation on the GPU box"

if [ -n "$PROJECT_ID" ]; then
  FSPEC='{"flux":{"prompt":"a flat two-ink circle logo on white, screen print","model":"klein-4b","width":512,"height":512,"steps":4,"guidance":1.0,"mode":"raster"}}'
  R="$(req POST /jobs "job[name]=smoke-flux-$STAMP" \
                      "job[runner]=flux" \
                      "job[project_id]=$PROJECT_ID" \
                      "job[spec]=$FSPEC")"
  FLUX_ID="$(loc | grep -oE '[0-9]+' | tail -n1)"
  [ -n "$FLUX_ID" ] && ok "flux job filed (job $FLUX_ID)" \
    || bad "flux create failed: $(printf '%s' "$R" | sed '$d' | grep -oE 'alert[^<]*' | head -n1)"
  if [ -n "$FLUX_ID" ]; then
    T0=$SECONDS
    if REPLY="$(poll "/jobs/$FLUX_ID.json" done 900)"; then
      ok "flux raster finished in $((SECONDS-T0))s"
    else bad "flux did not finish within 900s"; fi
  fi
fi

# ---------------------------------------------------------------- stage 4 -----
hdr "Stage 4 — datasets: draw a prompt, file a job from it"

if [ -n "$PROJECT_ID" ]; then
  DRAW="$(curl -sS -m 60 -c "$JAR" -b "$JAR" "$BASE/datasets/draw?count=1" | jq -r '.prompts[0].prompt // empty' 2>/dev/null)"
  if [ -n "$DRAW" ]; then
    ok "prompt drawn from the DiffusionDB library (${#DRAW} chars)"
    # prompt_source=random makes the studio draw AGAIN at filing — the point is
    # that a random-draw job files without anybody typing a prompt.
    FSPEC='{"flux":{"model":"klein-4b","width":512,"height":512,"steps":4,"guidance":1.0,"mode":"raster"}}'
    R="$(req POST /jobs "job[name]=smoke-dataset-$STAMP" \
                        "job[runner]=flux" \
                        "job[project_id]=$PROJECT_ID" \
                        "prompt_source=random" \
                        "job[spec]=$FSPEC")"
    DS_ID="$(loc | grep -oE '[0-9]+' | tail -n1)"
    [ -n "$DS_ID" ] && ok "random-prompt generation filed (job $DS_ID)" \
      || bad "dataset-draw job create failed: $(printf '%s' "$R" | sed '$d' | grep -oE 'alert[^<]*' | head -n1)"
    if [ -n "$DS_ID" ]; then
      if REPLY="$(poll "/jobs/$DS_ID.json" done 900)"; then
        ok "random-prompt generation finished"
      else bad "dataset generation did not finish within 900s"; fi
    fi
  else
    bad "the prompt library is empty — ingest it first"
  fi
fi

# ---------------------------------------------------------------- stage 5 -----
hdr "Stage 5 — compose: vector layers merged by the svg runner"

if [ -n "$PROJECT_ID" ]; then
  # Two vector layers as inline SVG text, one raster layer as a 1x1 PNG: the
  # recipe endpoint proves every vector layer goes out as SVG TEXT, never a path.
  V1="data:image/svg+xml;base64,$(printf '%s' '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="150" viewBox="0 0 200 150"><rect width="120" height="90" fill="#e63946"/></svg>' | base64 -w0)"
  V2="data:image/svg+xml;base64,$(printf '%s' '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="120" viewBox="0 0 160 120"><circle cx="80" cy="60" r="50" fill="#457b9d"/></svg>' | base64 -w0)"
  R1="data:image/png;base64,$(printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89' | base64 -w0)"
  LAYERS="$(python3 - "$V1" "$V2" "$R1" <<'PY'
import json, sys
v1, v2, r1 = sys.argv[1:4]
print(json.dumps([
  {"key": "a", "name": "block",  "kind": "vector", "src": v1, "x": 0,   "y": 0,   "w": 200, "h": 150},
  {"key": "b", "name": "orb",    "kind": "vector", "src": v2, "x": 120, "y": 40,  "w": 160, "h": 120},
  {"key": "c", "name": "pixel",  "kind": "raster", "src": r1, "x": 300, "y": 10,  "w": 20,  "h": 20},
]))
PY
)"
  R="$(req_json POST /composite "$(python3 - "$PROJECT_ID" "$LAYERS" <<'PY'
import json, sys
pid, layers = sys.argv[1], json.loads(sys.argv[2])
print(json.dumps({"name": "smoke-composite-$STAMP", "width": 480, "height": 320,
                  "background": "transparent", "layers": layers, "project_id": int(pid)}))
PY
)")"
  # The composite create answers a redirect to /composite?id=N (its show route
  # takes the id as a query param), so the id comes from the Location header.
  COMP_ID="$(loc | grep -oE '[?&]id=[0-9]+' | grep -oE '[0-9]+' | tail -n1)"
  [ -n "$COMP_ID" ] && ok "composite created (id $COMP_ID)" \
    || bad "composite create failed: $(printf '%s' "$R" | sed '$d' | head -c 200)"

  if [ -n "$COMP_ID" ]; then
    RECIPE="$(curl -sS -m 60 -c "$JAR" -b "$JAR" "$BASE/composite/$COMP_ID/recipe" -H "X-CSRF-Token: $TOKEN")"
    NSVG="$(printf '%s' "$RECIPE" | jq -r '[.layers[] | select(.type=="svg")] | length' 2>/dev/null)"
    NPATH="$(printf '%s' "$RECIPE" | jq -r '[.layers[] | select(.src | test("/scrapbook/|/jobs/upload_preview/|^/"))] | length' 2>/dev/null)"
    if [ "${NSVG:-0}" -ge 2 ] && [ "${NPATH:-1}" -eq 0 ]; then
      ok "recipe carries $NSVG vector layers, every src inline (no paths)"
    else
      bad "recipe is wrong: svg=$NSVG path-like=$NPATH"
    fi

    R="$(curl -sS -m 120 -c "$JAR" -b "$JAR" -X POST "$BASE/composite/$COMP_ID/flatten" \
          -H "X-CSRF-Token: $TOKEN" -w '\n%{http_code}')"
    FCODE="$(printf '%s' "$R" | tail -n1)"
    FMODE="$(printf '%s' "$R" | sed '$d' | jq -r '.mode // empty' 2>/dev/null)"
    CJOB="$(printf '%s' "$R" | sed '$d' | jq -r '.job_id // empty' 2>/dev/null)"
    if [ "$FCODE" = "200" ] && [ "$FMODE" = "vector" ]; then
      ok "vector flatten done — merged by the svg runner, mode=$FMODE (job $CJOB)"
    else
      bad "flatten returned $FCODE mode=$FMODE"
    fi
    if [ -n "$CJOB" ]; then
      if REPLY="$(poll "/jobs/$CJOB.json" done 120)"; then
        ok "compose job landed done in the history"
      else bad "compose job not done"; fi
    fi
  fi
fi

# ---------------------------------------------------------------- summary -----
hdr "Summary"
printf '  project %s (id %s)   artefacts %s\n' "$PROJECT_NAME" "${PROJECT_ID:-none}" "$ARTIFACTS"
printf '  PASS %d   FAIL %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n  failures:\n'
  for n in "${NOTES[@]}"; do printf '    - %s\n' "$n"; done
  exit 1
fi
printf '  every stage passed\n'
