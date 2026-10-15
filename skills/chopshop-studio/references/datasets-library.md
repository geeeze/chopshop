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

## The gap (and what is now filed)

The volume/synthesis features were the gap; the plan below is now filed on the
studio tracker (`geeeze/chopshop-studio`), so check the issues before
re-planning:

- **Batch driver** — walk the library and file N jobs. (filed: enhancement)
- **Mashup** — the LLM combinator. (filed: enhancement)
- **Curated/abridged views** — a saved subset of the library that regenerates on
  ingest. (filed: enhancement)
- **Structured prompt composer** — dynamic composable slots (text / boilerplate
  dropdown / dataset-in block), NOT three hardcoded fields; the thing/location/
  style trio is only the default starting layout. A slot can be filled by a
  dataset draw or a mashup. (filed: enhancement)
- **Iterative mashup UX** — re-mash with temperature escalation, revert, and
  "use this", over a `SessionDraft` mashup chain. (filed: enhancement)
- **MET-Meme as a data path** — labels are available as JSON
  (`/meme-labels`) and usable as a descriptor axis without any Kaggle data;
  whether images are ever ingested is an operator decision (needs-info), not a
  code blocker.

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
- **Model**: `geenet-flash` (an LM Studio alias on <gpu-box>; the operator sets it,
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

## Pitfalls

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
  refuses).
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
