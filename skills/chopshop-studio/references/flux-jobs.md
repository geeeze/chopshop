# Flux jobs and the model registry

## Two shapes of a flux job

A flux job is `Job#flux?` (runner kind "flux"). After generation it is one of two
shapes, and they differ in everything downstream — previews, archive, inverse twin:

- **trace mode** (`spec.flux.mode` != "raster"): the generated raster is handed to a pipeline
  runner (the handoff runner), `runner_job_id` is set, and the runner produces `source.png` +
  `source.inverse.png` and its own 7z archive. Preview / proof / archive all come through the
  runner proxy (`file_job_path`).
- **raster-only** (`spec.flux.mode` == "raster"): `runner_job_id` is nil — NO runner, NO
  `source.png`/inverse, NO archive. The generated raster(s) live only in `storage/uploads` as
  `flux_<hex>.png`; the img2img reference and full config live in `spec.flux`. Preview via
  `upload_preview`, not `file_job_path`. `JobsController#download` (runner archive proxy) 404s
  for these unless the archive is built locally.

Useful accessors: `Job#flux_config` = `spec["flux"]`; `flux_prompt`; `flux_variations` (list of
`{file, seed, model, width, height, seconds}`); `input_path` (full path to the stored raster);
`plot_output_file` (plot only); `preview_file` + `preview_from_upload?` route the Jobs-index
thumbnail per kind.

## The studio is a HAND-MIRROR of the flux registry — three things enforce it now

`FluxConf` cannot import the Python registry, so it transcribes it. After the
registry grew to **eight models** (`klein-4b`, `klein-4b-base`, `sdxl-1.0`,
`sdxl-turbo`, `sd-1.5`, `sana-sprint-0.6b`, `sana-sprint-1.6b`, `ssd-1b`) plus
**14 LoRA modifiers** and **5 VAE swaps**, three mechanisms keep the copy honest —
update all three when the registry changes:

1. `test/lib/flux_repo_parity_test.rb` parses `~/chopshop-flux`'s `models.py` +
   `modifiers.py` with Python `ast` (path from `CHOPSHOP_FLUX_REPO`, default
   `~/chopshop-flux`) and compares 18 model fields, 9 modifier fields, 5 VAE
   fields, the key sets and the target sets. It is itself exercised against
   corrupted copies, so a licence differing by one character fails.
2. `test/models/runner_conf_drift_test.rb` + `test/fixtures/runner_conf_drift.json`
   pin the **notes, aliases, licences and per-model dim rules VERBATIM**. A registry
   change means REGENERATING the fixture — read the sibling's registry by importing
   it (`cwd=~/chopshop-flux`, `from chopshop_flux import models`) rather than
   regexing the source.
3. `FluxConf.limits(model_key)` is the ONE reader of `min_dim`/`dim_multiple`/
   `max_pixels`. Every entry carries its own — klein 16/64/4 MP, SDXL and sd-1.5
   8/128/2 MP, Sana 32/512/1 MP. Applying one family's rules to another is a bug
   that was fixed TWICE independently; do not reintroduce a global constant.

**Two fields beyond `distilled` decide what the operator is TOLD**, and they must
be mirrored + guarded on BOTH sides (server `validate` AND the `/flux` page's
JavaScript, which is a second copy of the rules and is where a fix goes missing):
`guidance_embedded` — a distilled pipeline that EMBEDS guidance acts on the number
without running CFG (Sana Sprint), so calling it "ignored" contradicts the service;
`resolution_binning` — the pipeline re-bins a size it has no bucket for, so the PNG
can come back at a different resolution than the one asked for.

## The proof training-set card: FLAT names vs NESTED variants

The runner publishes a proof's dataset as THREE FLAT names at the JOB ROOT
(`<stem>.dataset.json`, `<stem>.dataset.md`,
`<stem>.dataset-contact-sheet.png`) so the existing THREE-segment file route serves
them, and only the per-transform variants live deeper in
`<stem>.dataset/raster|vector/<name>`, which need the FOUR-segment route via
`candidate:`.

**This shipped broken and the test agreed with it.** The card asked for the contact
sheet through the nested route — a 404 on a real runner and a broken `<img>` on the
card's headline element — because the test pinned `candidate:` on a file that does
not need it. Request the three flat names by NAME ALONE. The 7z package is the one
thing that does take `candidate` (`/jobs/:id/dataset?candidate=…`).

## Two traps that cost real time here

- **Never run two Rails test invocations concurrently.** They collide on the SQLite
test DB and produce `SQLite3::BusyException: database is locked` errors that look
exactly like real failures. A whole round was wasted diagnosing a "regression" that
was two suites fighting.
- **Do not rewrite Ruby string literals with regex character spans.** An
`app/models/flux_conf.rb` notes/aliases pass written that way crossed a hash
boundary and swallowed the `MODIFIERS = {` line, and a later attempt dropped a
trailing comma from every `aliases` line. Do it LINE-BASED, bounded to the MODELS
block, and let Ruby quote the value: `String#dump` produces a literal that parses
back to exactly the intended string, escapes and em-dashes included.

## Model registry (mirrored in FluxConf)

`chopshop-flux/chopshop_flux/models.py` and studio `FluxConf::MODELS` hold the SAME models, in the
SAME order, and **nothing syncs them** — `models.py` carries a header note saying exactly that, and
a test asserts the parity. Changing the registry means editing BOTH sides plus every place that
renders the list, in one commit: the `jobs/new.html.erb` model `<select>` and its settings popup,
the `pages/flux.html.erb` panel, and the `FluxConf.validate` licence gate. The studio restates the
service's rules in the operator's words, so its sentences must match the service's own or the page
lies about what a run will do.

`klein-9b` was removed (non-commercial + HF-gated + ~24 GB VRAM against a 17 GB card) — do not
reintroduce it. The only non-commercial model is **sdxl-turbo** (Stability AI Non-Commercial
Research Community License); keep its `check_usable` / `FluxConf.validate` ack gate working. The
Apache and OpenRAIL families are commercial-OK.

**Do not quote a fixed model COUNT in docs or comments** — "the five-model registry" went stale the
moment the registry grew. Derive it from `FluxConf::MODELS.keys` / the registry so it cannot drift.

**The card is not always the licence, and neither is guessable from outside.** `sdxl-turbo` is the
clearest case: its HF card says `license: other` / `license_name: sai-nc-community`, while the
`LICENSE.md` in the same repo serves the Stability AI Community License, which permits commercial
use below a revenue threshold. When card and licence file disagree, stay CONSERVATIVE, keep the ack
gate, and record the discrepancy in the entry's `notes` rather than picking a side — reclassifying a
licence is a business decision, not an agent's. Other cards carry **no decidable licence at all**
(`sd-turbo`, `ByteDance/Hyper-SD`); the rule that follows is: do not register what you cannot name.

Adding models, LoRA adapters or VAE swaps — the research and licence-triage procedure, the diffusers
call ORDER that makes a VAE swap work at all, the vendored-`peft` step LoRA loading depends on, and
the measured per-model numbers: `references/model-registry-recipes.md`.

## The service can serve a registry it no longer has

A running `chopshop-flux` process does NOT pick up registry edits, and `GET /models` answers from the
process's in-memory copy. After a pull that changes the registry, the box advertises models the
source no longer contains (it listed the removed `klein-9b` long after that commit landed) while its
own checkout is clean. So: **restart the flux service as part of any registry deploy, and verify by
diffing `GET /models` against the registry in the checkout** — reading the source file proves nothing
about what is being served. Same reasoning for any runner whose advertised operations come from a
live process (`GET /health`) rather than from disk.

## Guidance warning needs TWO conditions, not one

`FluxConf.validate` warns "guidance ignored" only when the request guidance differs from
`spec["default_guidance"]` AND the model does not embed guidance. Compare against the model's own
default, never a hardcoded 1.0 — klein-4b defaults to 1.0, sdxl-turbo to 0.0, so a hardcoded
`!= 1.0` missed sdxl-turbo at guidance 1.0.

**`distilled` alone is NOT sufficient, and keying the warning off it alone makes the page lie.** A
distilled pipeline can carry a guidance EMBEDDING, which acts on the number without running CFG — so
guidance IS honoured there, and warning would contradict the service, which deliberately stays
silent. That is why `ModelSpec` carries **`guidance_embedded`** and the warning condition is
`spec.distilled and not spec.guidance_embedded and guidance != spec.default_guidance`. The Sana rows
are the case: `distilled=True` with `guidance_embedded=True`.

`ModelSpec` also carries **`resolution_binning`**, which is a different kind of honesty problem: a
pipeline that re-bins a size it has no bucket for returns a PNG at a resolution the caller did not
ask for. The service warns when that flag is set, and the studio must too.

Both fields are LOAD-BEARING for what the operator is told, so the studio mirror has to carry them.
The general rule for any hand-mirrored field: **if a field changes a sentence the page prints, its
absence from the mirror is a LIE, not a gap.** When one is added to the source, add it to the mirror
AND to the parity test's compared-field list in the same change.

## Prove the mirror test can actually FAIL

The parity test reads the sibling repo's source and compares field by field (Python `ast` over the
frozen-dataclass registry — no dependency, no execution). A comparison like this fails in the worst
possible way: it agrees with everything because it stopped reading something.

So verify it is real before trusting it, without touching either repo:

```bash
TMP=$(mktemp -d); mkdir -p "$TMP/chopshop_flux"
cp ~/chopshop-flux/chopshop_flux/{config.py,models.py,modifiers.py} "$TMP/chopshop_flux/"
CHOPSHOP_FLUX_REPO="$TMP" bin/rails test test/lib/flux_repo_parity_test.rb   # control: 0 failures
# then corrupt ONE field in the COPY and re-run — it MUST fail, naming that field
```

Corrupt at least a licence string, a `weight_name`, and a boolean like `guidance_embedded`. Any
corruption that still passes means that field is not compared, whatever the test's name claims.
Assert the edit LANDED before re-running (`grep` for the new value) — a `sed` whose pattern does not
match leaves the control case intact and reports a perfect score.
