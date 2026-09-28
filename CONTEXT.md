# CONTEXT.md — chopshop-plot

Working state for agents and humans: what is in flight, what is blocked, and the
caveats that are not obvious from the code. Update this as work lands.

**Repo visibility: private.**

## What this repo is

The geometry source and metrics engine for the chopshop pipeline — an optional
sidecar. It turns pipeline measurements into something you can *compare*: it ranks
and visualises, and never picks a winner. Three operations over one
language-agnostic JSON contract (`docs/contract.md`):

1. **generate** — a JSON geometry spec → SVG. A programmatic *source* for the front
   half, alongside a raster or a prompt.
2. **digest** — a metrics spec → chart SVG. A post-hoc *reporter* on one run.
3. **query** — `.run.json` records + a chart spec → SVG. The *engine*: cross-run
   scatter, a Pareto trade-off frontier, and a two-way diff.

The Python package is the reference implementation and is **stdlib-only** — it
writes SVG directly, because SVG is the pipeline's native vector format. A Julia
(Makie) or R (ggplot2) backend would read the same JSON spec and emit the same SVG;
they are named in the contract as richer backends, not required to run this package.

## Work in progress

- No tracked in-flight feature. The three operations, the geometry demo gallery,
  the fractals, and the animated time-series demo (`demo/make_animation.py` →
  mp4/gif) have all landed.
- Named but not built: the Julia / R backends. They exist in the contract as
  intended implementers, not as pending work here.

## Blockers

- None known.

## Caveats / known issues

- **stdlib-only, with exactly ONE exception: `chopshop_plot/fractals.py` may import
  numpy** (Mandelbrot/Julia/fern rasterise on a complex grid; pure Python is far too
  slow). `chopshop_plot/png.py` writes PNG with stdlib `zlib`/`struct` — no Pillow —
  and Sierpinski stays stdlib SVG. The numpy-backed cases are guarded with
  `skipUnless(HAVE_NUMPY)` so the suite runs without it. Import no other third-party
  package anywhere.
- **The metrics schema is flat and versioned (`metrics_version: 1`).**
  `chopshop_plot/metrics.py` is the foundation; field names stay boring
  (`node_count_max`, never `static.path_nodes_max`). Bump `METRICS_VERSION` when a
  field is renamed/added/removed — a reader refuses an unknown version. Never
  hardcode a chart's axis; the user picks the field.
- **Runs are keyed by `source_sha256` + `recipe_hash`**, so "recipe A vs recipe B on
  one source" and "one recipe across sources" are directly comparable. `recipe_hash()`
  hashes the sweep params (preset, filter_speckle, hierarchical, use_palette).
- **Missing data is a state, not a zero.** A skipped gate renders as absent (`None`),
  never `0`. `flatten_candidate` must emit `None` for absent fields; renderers must
  skip `None` rather than plot a lie.
- **Non-domination is computed on DATA values, not screen pixels.** Screen y is
  inverted, so running the Pareto test on pixels maximises y. The test that pins this
  checks *which* candidates are on the frontier (fill colour + position), not just
  counts.
- **The contract is the interface.** Any change to a chart type, a metric field or the
  schema MUST update `docs/contract.md` and the tests in the same commit.
- **Invalid specs raise `SpecError` / `QueryError`** (CLI exit `3`), never a partial
  document. Validation lives in `chopshop_plot/spec.py` and `chopshop_plot/query.py`.
  Exit codes: `0` success, `2` usage error, `3` invalid spec.
- **59 tests, stdlib only** (`python3 -m unittest discover -s tests`): no torch, no
  GPU, no network. Every emitted SVG must be well-formed XML and carry
  `width`/`height`/`viewBox` on the root.
- **`demo/*.png` is gitignored** (regenerable via `demo/make_fractals.py`); the SVG
  demos are tracked. The animation demo needs Inkscape + ffmpeg — external tools for
  the demo script, not dependencies of the package.
- **Host-agnostic.** No absolute paths, no hostnames, no secrets in code or docs.
