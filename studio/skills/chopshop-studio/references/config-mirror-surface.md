# Config-mirror surface — the mirrored constants, their pins, and consolidation

## The pattern

The studio hand-mirrors every sibling service's config into a separate Ruby constant,
each with its own drift-pin test and its own page. There is **no config table in the
database** — all service config lives in Ruby constants under `app/models/*_conf.rb`,
`telemetry.rb`, `bp_examples.rb`, and `config/palettes.json`. This is the "logic from
separate services" the consolidation work targets.

## The inventory (read before touching any mirror or claiming it is pinned)

| Constant | File | Mirrors | Pin test | Strength | Frontend surface |
|---|---|---|---|---|---|
| `FluxConf` | `flux_conf.rb` (~1736 ln) | chopshop-flux `config.py`/`models.py`/`modifiers.py`/`docs/MODELS.md` | `flux_conf_registry_test.rb` (self-consistency) + `runner_conf_drift_test.rb` (fixture) + `flux_repo_parity_test.rb` (live ast parse) | strong for MODELS/MODIFIERS/VAES/config/guard; unpinned CARDS prose + hand-written HTML popup rows | `/flux` page + `jobs/new` flux settings + `/engine.json` |
| `BpConf` | `bp_conf.rb` | chopshop-bp `config.py`/`spec.py`/`metrics.py`/`blender.py`/`server.py`/`query.py`/`contract.md` — ONE module, TWO namespaces (`BpConf::Plot` draws, `BpConf::Blender` renders 3D), the service-wide constants and the element table stated once at `BpConf`'s level | `runner_conf_drift_test.rb` (fixture, BOTH halves) + live re-check of `config.py`/`spec.py`/`metrics.py`/`blender.py`/`server.py`/`contract.md` | strong for config/ops/routes/elements + the blender defaults (the merge ended the half that was unpinned) | `/bp` page (both halves) |
| `JevConf` | `jev_conf.rb` | chopshop-jev `jev_annotate.py` + `remediation_table.json` | `jev_help_test.rb` reads the annotator live for manifest/stats/verdict but NEVER compares QUESTIONS | partial | `/jev` page |
| `PipelineConf` | `pipeline_conf.rb` (~872 ln) | chopshop-svg `trace_sweep.py`/`front_common.py`/`spec.example.json` + flux + bp | `pipeline_conf_test.rb` (internal, pins against named constants) — svg bounds NOT fixture-pinned | medium | `jobs/new` guided choice + `POST /templates/use` (the one operator-editable surface) |
| `Telemetry` | `telemetry.rb` | chopshop-svg `triage_ranker.py`/`triage.py` constants | `runner_conf_drift_test.rb` mono-span + live re-check | strong (config half); also does owner-scoped data aggregation (mixed concern) | `/status` + `/engine.json` |
| `BpExamples` | `bp_examples.rb` | chopshop-bp `examples/*.json` | `bp_page_test.rb` renders only — no compare to the sibling | weak | `/bp` page examples |
| `PaletteLibrary` | `lib/palette_library.rb` + `config/palettes.json` | chopshop-svg `scripts/palettes.json` | `bin/sync-palettes --check` exists but no test/CI runs it | weak | `/json` page |

## Pin-strength grades (read the test, don't trust its name)

A mirror is only as pinned as what its test actually COMPARES. Four grades, weakest to
strongest:

1. **self/view** — compares the constant to the page that renders it; both can drift
together, pins nothing external.
2. **form agreement** — compares the constant to its own form fields; same trap.
3. **fixture + live sibling re-check** — compares against a committed fixture
(`runner_conf_drift.json`) and, when `CHOPSHOP_SIBLING_ROOT`/repo is readable, re-parses
the sibling source.
4. **key-for-key live parse** — parses the sibling file and compares each entry
(`flux_repo_parity_test`, `jev_help_test`'s live reads).

Before asserting "X is pinned", open the test and list what it actually reads from the
sibling. A test that only asserts the view renders the constant proves nothing about drift.

## The parity-test skip trap

A parity test that SKIPS whenever any compared field is "unreadable" from the sibling is
silently a no-op if even ONE field exists on only one side. Mechanism: the compared field
list includes a key that only the STUDIO's extension carries (e.g. a hosted-backend field
the real service has none of), so that field is always absent from the sibling → the whole
comparison skips → zero real rows are ever compared, while the run still reports "1 skip"
and looks healthy. Before trusting a parity test, grep the compared FIELD LIST against the
sibling source for keys that appear on only one side; such a key disables the whole
comparison, not one row.

## Registry duplication

The model registry is represented 4+ times inside the studio alone (`FluxConf::MODELS`, the
`/flux` popup's hand-written HTML rows, `jobs/new`'s hardcoded `<option>`s, a hardcoded
`DatasetBatch` default, and `CARDS` prose) plus copies in flux/svg/jev/sui. Rule: render every
option list / popup from the ONE pinned constant; never hand-write a second HTML list. Same
for the bp operation list (`Job::BP_OPS` vs `BpConf::Plot::OPERATIONS` vs a hardcoded `<select>`).

## The consumable-endpoint gap

- flux exposes **`GET /models`** (full registry incl. modifiers/VAEs/`targets`), and
  `FluxClient.models` exists — but it has ZERO callers; the page renders from the mirror.
- bp exposes `operations` + `metrics_version` on `/health` (no config/limits).
- svg and jev expose no config endpoint at all.

Consolidation direction: add a config endpoint to each service and make the studio consume
it (keep the mirror only as an offline default), one page per service + one fixture + one
drift test — the pattern `/bp` already established by merging `plot`+`blender`.

## The per-model-defaults trap

The "defaults don't change with the model" symptom is usually this: per-model readers
EXIST (e.g. `FluxConf.limits(model)`, `modifiers_for(model)`, `vaes_for(model)`) but have
zero callers, so a form renders static defaults keyed to one model. Rule: before adding any
defaults logic, grep for callers of the per-model accessor — if there are none, the fix is
wiring the form to it, not writing new defaults.
