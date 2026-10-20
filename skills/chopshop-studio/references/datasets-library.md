# The datasets library — prompt sources, corpora, mashups

The DATASETS feature (prompt libraries, dataset draws, mashups) lives **in the
studio**, not in `chopshop-flux` or `dmpool`. Before planning or promising
anything in this area, read this file and check the live app — the foundation is
built and populated.

## Where the data actually lives (verified against the boxes)

Three different homes, and the split is deliberate:

| What | Where | Why |
|---|---|---|
| Bulk corpora (DiffusionDB's 4 input files, incl. the 159MB zstd slice) | **<gpu-box>**, `~/datasets/<corpus>/` | build inputs, read once per ingest; documented in `~/datasets/README.md` with a `sync-to-vps.sh` that stages them onto the VPS just for an ingest, then removes them |
| Ingested rows (`prompt_sources`, 60k DiffusionDB prompts, all topic-tagged) | **VPS production sqlite** (`storage/production.sqlite3`) | runtime data a page reads on every request — must be local to be fast. <gpu-box>'s rule: "if a page reads it on a request it is not a corpus" |
| MET-Meme | **schema only** — `MemeVocabulary` (a pinned transcription of the annotation scheme), images/labels stay on Kaggle | never held data; the boundary is stated on the DATASETS page |
| dmpool (<gpu-box> store) | holds NONE of the site datasets — its catalog is 538/MDN/GDD/HF only | dmpool was never the home for prompt corpora |

Read the production row count without booting Rails:
`python3 -c "import sqlite3; c=sqlite3.connect('storage/production.sqlite3'); print(c.execute('select count(*) from prompt_sources').fetchone())[0]"`
(dev sqlite has no such table; the studio service is `chopshop-rails`, and there
is no `podman` on the VPS — it is native Rails there, the container is the
AUTHORING-box topology on <gpu-box> only).

## What already exists (do not re-plan it)

- `PromptSource` model + `prompt_sources` table: prompt, licence, attribution,
  part, seed/steps/guidance/sampler/width/height, nsfw, topic, phrase_root,
  x/y (DiffusionDB's own UMAP projection), `prompt_sha`. CC0-1.0; provenance is
  columns because a prompt is somebody's work.
- `bin/rails datasets:ingest_diffusiondb` (`lib/tasks/datasets.rake`) — joins
  coords/topics/phrase-tree on prompt text; re-runs replace, never append.
  Takes `SOURCE_DIR=<path>`, so the VPS needs the corpus staged or mounted.
- Single-job dataset draw — DONE: the `dataset_draw` pipeline template
  (`pipeline_conf.rb`) flips the Run Job form to "Random from DiffusionDB" and
  draws **at filing**, server-side, recording `spec["prompt_source"]`;
  `datasets#draw` (1–20 prompts, filterable by topic/root), `datasets#use`
  (drops a prompt onto the form as an editable draft), the LIBRARY page,
  `/library.json`, `/meme-labels`.
- `PromptSource#to_contract` is the existing seam — the JSON contract every
  consumer (agent, UI, future driver) already speaks. Extend it; do not invent
  a parallel prompt-source contract in another repo.

## Status: the layer LANDED; the OPERATOR UI did not (verified 2026-10-11)

All five issues shipped to `main` on 2026-10-10 — `3aa875a` (batch driver #46),
`915bab9` (LLM mashup #47 + composer #50 + iterative UX #51), `9409784` (#49
MET-Meme), plus `DatasetView` (#48). 105 tests, all green, and the code IS in the
running container.

**What is missing is every way an operator can reach it.** Grep `app/`: "mash"
appears only in `session_draft.rb`, `mashup_chain.rb`, `mashups_controller.rb`,
`mashup_client.rb`; `PromptComposer` is referenced only by `jobs_controller`; NO
view mentions `DatasetBatch` or `dataset_views`. So:

- `POST /mashup` (+ `/remash`, `/revert`, `/use`) — no button anywhere. Reached
  only by POSTing the endpoint by hand.
- `compose_prompt!` reads `params[:prompt_slots]` and **no control posts it** —
  the composer is unreachable from the form.
- `POST /datasets/batch` — no button; `datasets:batch` (rake) is the only door,
  and it needs `PROJECT_ID`.
- `dataset_views` — **0 rows built in production**; views are CLI-only
  (`datasets:view build NAME`).

So "the work is gone" is really "the work has no UI". Check this before
re-planning: the models, endpoints and tests exist and pass.

### Go-live config (measured 2026-10-11)

The mashup client refuses to guess a host: with `CHOPSHOP_STUDIO_LMSTUDIO_URL`
unset, `POST /mashup` is a **502** naming the variable. Both lines are required,
in `~/.chopshop-studio.env` (untracked), then `docker compose up -d`:

```
CHOPSHOP_STUDIO_LMSTUDIO_URL=http://<tailnet-ip>:1234
CHOPSHOP_STUDIO_LMSTUDIO_MODEL=<model-alias>
```

**`<model-alias>` is an LM Studio ALIAS + load identifier, not a model file — and
it only resolves while a model is LOADED under it.** It was `chopshop-flash`
until the operator rebranded it. The legacy preset file
`~/.lmstudio/config-presets/chopshop flash.preset.json` still declares
`@local:chopshop-flash`, so **reloading FROM THAT PRESET resurrects the old, dead
name** — load with an explicit `--identifier <model-alias>` instead. **Never
hard-code the checkpoint: the operator swaps the underlying weights (today a
MiniCPM5-2B thinking-agentic GGUF) and the studio keeps calling the same alias.**
Read the live one with `lms ps` (identifier, model file, residency, TTL); the
app's own `MashupClient.chosen_model` should stay on the alias.

**An alias RENAME is a SILENT break — and it has happened.** The old name
resolves to nothing, so every mashup fails until the env is updated, and it
appears in FOUR places that must move together: `~/.chopshop-studio.env` (the
live one), `MashupClient::DEFAULT_MODEL`, the wire-answer fixture in
`test/lib/mashup_client_test.rb`, and this doc. The env value is read at
container START, so a rename needs a RECREATE, not a restart:
`docker compose up -d --force-recreate studio` (`docker-compose.override.yml`
feeds it via `env_file`). Verify where it MATTERS — the container's own env and
its own network path, never the host's:
`docker exec chopshop-studio-studio-1 bin/rails runner 'puts MashupClient.chosen_model(nil)'`,
then a live `MashupClient.synthesize` inside the container. With the old alias
gone from the box, a successful mash proves the new name is the one in use.
Consequences, all measured:

- While unloaded, the model id does not exist: `/v1/models` omits it and a
  request answers `No models loaded`. **`justInTimeModelLoading: true` does NOT
  rescue it** — JIT loads a DOWNLOADED model key, not a preset identifier.
- So the 10-minute TTL the operator wants (`--ttl 600`, freeing VRAM between
  mashups) means **a mashup filed more than 10 minutes after the last one fails
  with "No models loaded"** until something reloads it. Reload with:
  `~/.lmstudio/bin/lms load "mradermacher/minicpm/minicpm5-2b-claude-fable5-1-thinking-agentic.i1-q6_k.gguf" --identifier <model-alias> --ttl 600 -y`
  (`lms` lives at `~/.lmstudio/bin/lms`; `lms ps` shows the identifier and TTL).
- The app sends its OWN system prompt and temperature, so the preset's copy of
  those is redundant for our calls — the identifier is load-state, not behaviour.

## Mashup design (as agreed with the user)

- **Arity N ≥ 1** source prompts; 2 is the common case.
- **LLM endpoint: LM Studio's OpenAI-compatible API** on the box running it
  (`/v1/chat/completions`). On this fleet LM Studio runs on <gpu-box>
  (`127.0.0.1:1234` there) alongside laya-serve (`8797`). laya-serve is NOT the
  right seam — it returns typed decision answers, not prompt synthesis. The
  env-var seam is the fleet convention (`CHOPSHOP_FLUX_LMSTUDIO_URL` already
  names an LM Studio URL in `flux_conf.rb` for attribution); the mashup client
  sits beside it.
- **Strict JSON contract**: request exactly `{"prompt": "...", "rationale":
  "..."}`; validate and REFUSE anything that does not parse — no regex salvage,
  no guessing. A malformed answer is a failed mashup, not a mangled prompt.
- **Verified wire contract** (tested live on <gpu-box>): use LM Studio's
  OpenAI-compatible **`POST /v1/chat/completions`** — the native `/api/v1/chat`
  endpoint does NOT accept `response_format` and every structured-output key
  is rejected. Put the schema in `response_format.json_schema`
  (`strict: true`, `additionalProperties: false`) on the REQUEST — no
  server-side configuration is needed. The answer comes back as an escaped
  JSON string in `choices[0].message.content` (not `output[0].content`; that is
  the native endpoint), so `json.loads` it, then validate and refuse on
  failure. Full recipe in the hermes-agent skill,
  `references/compartment-memory.md` → "LM Studio local model server".
- **Synthesis, not addition**: the model merges the shared concrete subject and
  the descriptors; it adds no new subject matter.
- **Deterministic template combinator as the offline fallback** so batch
  production never hard-fails on the LLM being unreachable.
- **Model**: `<model-alias>` (an LM Studio alias on <gpu-box>; the operator sets it,
  so pin the alias, not the raw checkpoint id). A fast small model
  (~2B-class, MiniCPM5-2B thinking-agentic); good enough for synthesis at temp ~0.2.
- **Temperature discipline**: keep the FIRST mashup at temp ~0.2 with a fixed
  seed for determinism/reproducibility. **Elaboration grows with temperature**
  (measured: at temp 0.66 the model expands a terse source line into a full
  narrative scene around it; the facts stayed faithful but the elaboration
  amplified the input). Retry/escalation is the opt-in way to escape
  determinism — that is the whole reason the iterative UX re-mash boosts temp
  (base 0.2, +0.15 per advance, cap ~1.0).

### What the runner checks vs must NOT (live-tested, hard-won)

The mashup may elaborate descriptors but must NOT introduce subjects absent from
the inputs, and must retain + display the source prompts as provenance. It does
NOT police names or content — a faithful merge of two prompts that both name
real people is legitimate, and sanitizing what the operator typed is not the
tool's job.

- **Check (hard refusal → template fallback):** (1) parse + schema-validate the
  `{prompt, rationale}` object; (2) **no-new-subject** — a subject/object diff
  against the inputs catches real invention ("Manhattan Harbor", "a person
  reading"), NOT a proper-noun diff; (3) **first-person narration** in
  `rationale` (backstop to the server system prompt).
- **Do NOT** refuse on named entities or "sensitive" content, and do NOT
  sanitize the operator's source prompts. A vague/edge input gets *elaborated*,
  not just merged — so the real control for edge content is **provenance**
  (retain + show the source prompts beside the result), not scrubbing. The
  runner cannot tell a faithful named-subject merge from a fabrication by names
  alone, so don't try.

### Testing the mashup live (no stubs)

Two throwaway harnesses (put them in the scratch dir — neither is a repo change):

- **Client-level** — a `bin/rails runner` script calling
  `MashupClient.synthesize(sources, model:, temperature:)` directly. Fastest way
  to sweep sources × models × temperatures, and it exercises the SHIPPED
  request + validator, so it tests the real contract. Bypasses login entirely.
- **HTTP-level** — an `ActionDispatch::Integration::Session.new(Rails.application)`
  inside `rails runner`: `s.post "/login", params: {password:}` then
  `POST /mashup` → `/remash` → `/revert` → `/use`, asserting each status and the
  `prompt_draft_token` in the `use` redirect. Proves controller + chain + draft +
  client + server together, with no browser.

Run either with the env sourced and on the HOST (the container cannot run tests):

```sh
cd ~/chopshop-studio && set -a && . ~/.chopshop-studio.env && set +a \
  && RAILS_ENV=test bin/rails runner <script.rb>
```

- **`rails runner` trap**: a top-level `def` cannot see a top-level LOCAL — use
  `$globals` (or wrap in a class) or the script dies `undefined local variable`.
- **The studio DB is SQLite**: `ILIKE` is a syntax error — use `LIKE`. Pull real
  sources with `PromptSource.where("prompt LIKE ?", "%word%")`; prefer running
  the runner on the host over `docker exec` + `docker cp`.
- Test with **REAL `prompt_sources` rows**, not invented strings — see the
  structured-llm-output skill for why terse inputs hide the failures.

## Pitfalls

- **The `rationale` is shown as PROVENANCE but the model fabricates it.**
  Measured live: a rationale claiming "retained the dragon/tiger from prompt 1"
  beside a prompt containing neither, and "both sources share the subject" when
  input 2's distinctive tokens are wholly absent. The prompt was often fine while
  its own account of itself was false — so never display the rationale as record
  without diffing its claimed elements against the emitted prompt. With real
  library rows the same model also DROPPED input 2 entirely in 5 of 8 pairs at
  the pinned temp 0.2 (merging both inputs only from ~0.5 up): always check that
  every source survives, and treat the narrative as the model's claim, not
  evidence.
- **A stub at the wrong seam agrees with the bug.** `MashupClient#post` called
  `parse_response` and returned a Hash while `synthesize` parsed that Hash again
  (`undefined method 'body' for an instance of Hash`) — every live mashup a 500,
  all 105 tests green, because the tests stub `post` to return a raw
  `Net::HTTP` response, the shape the real `post` never produced. `post` is now
  TRANSPORT ONLY and two tests run the shipped `post` + `parse_response` over a
  loopback socket. General rule: when the method under test is the seam the
  tests replace, the suite pins the contract and proves nothing about the
  implementation — run the real path at least once (`TCPServer.new("127.0.0.1",
  0)`, one canned response per connection).
- **A nil draw has three causes; report the one that happened.**
  `jobs#apply_prompt_source!` reported every nil as "The prompt library is
  empty" — so an operator with 60,000 loaded rows who typed a human word into a
  filter that is an EXACT match against descriptive slugs
  (`artstation-art-detailed-trending`) was told nothing was loaded and went to
  re-ingest. Measured: `draw(topic: "portrait")` → nil on a full library. Check
  `PromptSource.count.zero?` for the empty case, and NAME the topic (and the way
  out) otherwise. `DatasetBatch.draw` had the same shape.
- **`bin/rails test` cannot run in the studio container**: boot dies with
  `cannot load such file -- debug/prelude` (the `debug` gem is dev-group only).
  Run the suite on the HOST (ruby 3.3.8) — `RAILS_ENV=test bin/rails test`.
- **Before planning any feature, grep the studio `app/` tree and the live
  production DB first.** A "new feature" that reads as absent from the service
  repos (`flux`, `dmpool`) is often fully built in the app, and the plan names
  the wrong repo and the wrong seam. The tell: a feature request about prompts,
  datasets, or job filing whose grep of `app/models`, `app/controllers`,
  `lib/tasks` comes back with hits.
- **`podman` exists only on the authoring box (<gpu-box>); the VPS runs native Rails
  behind `chopshop-rails.service`.** Probe the VPS DB with sqlite3 directly
  instead of `podman exec chopshop-app`.
- <gpu-box> SSH is `ssh -p 22822 <gpu-handle>@<tailnet-ip>` (Tailnet; plain port 22
  refuses). **mDNS names like `<gpu-box>.local` do NOT resolve from this agent host —
  use the Tailnet IP for web ports too** (a probe of the `.local` name returns
  status 000, not a refusal, which reads like a dead service). When pulling a
  directory tree off <gpu-box>, `scp -r` can time out mid-copy leaving a partial
  tree; `rsync -a -e 'ssh -p 22822 …'` skips what already landed and is the
  safer default for anything large — compare `du -sh` against the source to
  confirm completeness.
- **Filing to the chopshop-studio tracker: the fine-grained PAT can read and
  create issues on `geeeze/chopshop-studio` via the REST API, but `gh repo list`
  cannot list the org's private repos and `gh issue create --repo` fails with
  "Could not resolve to a Repository".** When `gh` refuses but the repo is
  known to exist, verify it with
  `curl -s -H "Authorization: token $TOKEN" https://api.github.com/repos/OWNER/REPO`
  and file via the REST API
  (`POST /repos/OWNER/REPO/issues` with `{title, body, labels:[ids]}`) instead
  of trusting the gh error as a missing repo. Get label IDs from
  `/repos/OWNER/REPO/labels` first, then verify by listing the issues back.
- Sampler codes in DiffusionDB are numeric; the studio keeps the code and maps
  to names via a PINNED fixture (`bin/generate-sampler-fixture`) — never retype
  the mapping by hand.
