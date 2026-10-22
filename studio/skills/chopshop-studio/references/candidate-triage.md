# Candidate triage — gates, buckets, ranker

Pipeline (Python, `~/chopshop-svg`, PUBLIC repo) produces too many
near-identical candidates per job. Plan: a deterministic **gate**
(drop / demote / ok, every verdict carries named `reasons[]`), a **bucket**
key so one verdict collapses a whole family of variants, then an optional
**learned ranker** that only orders survivors. Never delete on a verdict,
never pick a winner — the human still chooses. The Ruby studio reads JSON only
and never runs gate logic. Full handoff verbatim is in the session that
introduced it; the essentials are below.

## Two requirements the operator added (fold into EVERY phase)
1. **Learning metrics survive job deletion.** `events.jsonl` and
   `learned_buckets.json` must NOT live under `06_run/<stem>/` (per-job, swept
   on delete). Keep them at a job-independent path (`06_run/_learning/…`) or in
   the studio DB with no FK — the same pattern `ScrapbookItem` uses.
2. **Checksums at creation/upload/save.** Every file the pipeline or studio
   writes/accepts gets a sha256 recorded at creation time, stored in its
   sidecar/row. `canonical_svg()` already yields `svg_sha` for candidates;
   extend to a general file checksum. Studio: upload, scrapbook create/import,
   composite flatten. Pipeline: prepped/traced/candidate/proof.

## What is already true
- Pipeline scripts in `~/chopshop-svg/scripts/`; repo PUBLIC (no
  hostnames/IPs/VPN/SwarmUI refs — see `references/repo-visibility-and-tagging.md`).
  `snap_colors.py` and `run_batch.py` EXIST (handoff open question resolved).
- `compare_candidates.py` already sorts "fewest hard fails, then advisories";
  fidelity is a separate lens. `run_record.py` already stitches source hash →
  SVG hash → A/B → proof → decision.
- `05_final/<cand>.pick.json` labels `production|style_reference|needs_retrace|discard`
  are the training signal. `requirements.json` already splits hard production
  vs style vs bookkeeping.
- Studio is Rails 8.1, reads JSON only; scrapbook already survives job
  deletion (no FK) — the pattern to copy for the learning metrics.

## Phase plan (handoff §5–§10)
- **P0 (no ml, do first):** `canonical_svg()` (round coords, sort attrs, strip
  ids/comments, fixed floats) → sha; exact-dupe collapse; thumb dhash + 32×32
  gray cosine for near dupes; `bucket_of()` (preset | binned speckle | binned
  colors | prompt family); comparison report groups by bucket, exemplar first,
  `+N similar`; studio group expand with raw-metric sort one click away.
- P1 gates (HARD single-signal drop vs WEAK `>=weak_needed` demote; `spec.json`
  `triage` key, defaults if omitted).
- P2 event log (`06_run/events.jsonl`, append-only; log `shown` with position
  or the ranker learns the sort order back).
- P3 text bigram/tfidf cosine (prompts/filenames/tags/finding text) + optional
  dinov2/clip embeddings.
- P4 preference ranker (pairwise logreg → lightgbm lambdarank; split by job,
  never candidate; cold-start hand score until ~30 picks).
- P5 bucket bandit → `trace_sweep.py` (beta-bernoulli, thompson sample, expiry
  + veto).

## Data contracts (handoff §4)
- verdict (per candidate, `06_run/<stem>.triage.json`):
  `{schema, candidate, svg_sha, stage: pre_trace|post_trace,
    disposition: ok|demote|drop, reasons[], bucket, gate_version}`.
- `rank.json` (per job):
  `{ranker_version, groups:[{bucket, exemplar, members[], score}]}`.
- event line: `{t, job, svg_sha, event:
  shown|star|unstar|proof|pick|discard|delete|open_findings, pos, ranker}`.
  `pos` is **1-based human rank** (first candidate = 1) on BOTH sides — the
  pipeline's `record_shown` and the studio's `Event.position_of` — so a ranker
  joins exposure and action on one scale. Never 0-based.
- `spec.json` `triage` defaults: `max_unique_colors 8, max_speckles 40,
  max_glow_area_pct 8, min_silhouette_iou 0.85, min_luma_delta 12,
  weak_needed 3, bucket_cap 2, learn_min_rejections 3, learn_min_jobs 2`.

## Python skeleton (handoff §6)
`Disp` enum (ok/demote/drop) · `Verdict` dataclass (disposition, reasons,
bucket) · `HARD`/`WEAK` lists of `(name, fn(candidate)->bool)` ·
`gate(c, weak_needed=3)` returns DROP if any hard, DEMOTE if >=weak_needed weak
else OK · `bucket_of(c) -> f"{preset}|s{bin_}|c{bin_}|{prompt_family}"`.
Text sim: `norm(s)` letters+spaces only (iterate runes not bytes), char-bigram
`Counter`, `cosine`. Use rendered thumbs for near-dupes — svg path-command
bigrams carry no signal.

## Pitfalls from the go crawler (handoff §8) — do NOT inherit
substring title matching (`reject all` hit `reject allegations`); one weak
phrase poisoning the negatives list; admission ran twice; map-iteration
non-determinism; byte-vs-rune length; bigram scorer strips digits
(`filter_speckle=8` == `16` → params go to the ranker as numerics); ranker
feedback loop (log position, keep 1–2 random/uncertain slots visible).

## Delegation status
**Phase 0 SHIPPED** — `scripts/triage.py` + `tests/test_triage.py` (47 tests) are
committed and pushed to chopshop-svg (`e5c6949`). Implements `canonical_svg`
(attr sort, id/comment strip, 2dp coord rounding via ElementTree + regex
tokenizer, child order preserved), `svg_sha`, `file_sha256` (1 MiB streamed),
`dhash` (992-bit, 32×32) + `gray_cosine` (clamped [0,1]), `bucket_of`
(`preset|sN|cN|family`; speckle edges 0/5/20/40, color edges 1/3/5/8 — top
edges match the spec defaults), the `Disp`/`Verdict`/`HARD`/`WEAK`/`gate`
skeleton, char-bigram `norm`/`grams`/`cosine`/`text_sim` (digits KEPT),
`triage_defaults`/`load_triage`. Note the one deliberate deviation: `norm`
keeps digits despite the skeleton's "letters+spaces only" comment — §8 of the
handoff and the brief both require it, and it is documented in-code.

Verify: `cd ~/chopshop-svg && ./.venv/bin/python -m pytest tests/test_triage.py`
(47 passed) and full `./.venv/bin/python -m pytest tests/` (437 passed, 45
skipped, 0 failed). `./.venv/bin/python scripts/triage.py --selftest` exits 0.
Note: `.pytest_cache/` in that repo is ROOT-owned (a Sep 25 root run) — pytest
emits a cache-write warning under an unprivileged user; harmless, not a bug.

**P1 + P3 SHIPPED** (`3ec63b2`) — real `gate()`: HARD (artwork_lost, silhouette_lost,
glow_area, colour-cap, geometry hard-fail) → DROP on any hit; WEAK (speckle-heavy,
near-cap colours, low luma, node overload, borderline fidelity) → DEMOTE at
>= weak_needed. Verdict carries named reasons[] + bucket. spec `triage` block
overrides every threshold. P3: tfidf_vectors/tfidf_query/intent_groups (pure
Python, digits kept, deterministic). The four metrics not in the run-record
shape (`speckle_count`, `glow_area_pct`, `luma_delta`, `silhouette_iou`) read
from `comparison['metrics']`; absent → never fires.

**P2 SHIPPED** (`3ec63b2` pipeline + `9987ac3` studio) — pipeline: `scripts/triage_events.py`,
job-independent `06_run/_learning/` (`PIPELINE_LEARNING_DIR`), append-only
`shown` JSONL with 1-based pos, learned_buckets.json skeleton, checksum sidecars,
wired non-fatally into compare_candidates/trace_sweep. Studio: `events` table
(no FK, owner-scoped), `Event.record` star/unstar/pick/delete from the
scrapbook/use/proof/delete surfaces, sha256 at scrapbook create, GET /events.
**pos is 1-based human rank on BOTH sides** (record_shown and Event.position_of).

**P4 (learned ranker) + P5 (bucket bandit) — SHIPPED** (`29c2bd0`) —
`scripts/triage_ranker.py`: pure-Python pairwise logistic scorer (ridge,
batch GD), fit over within-job pairs from the event log, cold-start until
~30 picks across >=2 jobs (hand order fallback), holdout by whole job,
`rank()` reserves deterministic boundary slots (anti-feedback loop).
P5: beta-bernoulli Thompson bandit over bucket keys — `choose_bucket` /
`bucket_decision` (epsilon-explore, TTL expiry, veto), `record_outcome`,
round-trips learned_buckets.json. Not auto-wired into trace_sweep —
`choose_bucket` is the seam a caller uses.
