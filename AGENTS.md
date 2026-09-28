# chopshop-plot — agent notes

- **stdlib-only.** No dependency beyond the Python standard library. Do not
  import `matplotlib`, `shapely`, `numpy`, or any third-party package. The
  package writes SVG directly; SVG is the pipeline's native vector format.
- **The contract is the interface.** `docs/contract.md` defines the JSON spec,
  the metrics schema, and the SVG output. Any change to a chart type, a metric
  field, or the schema MUST update the contract and the tests in the same
  commit. A Julia (`Makie`) or R (`ggplot2`) backend would implement this same
  contract — they are named in the contract as rich backends, not required to
  run this package.
- **The metrics schema is versioned and flat.** `chopshop_plot/metrics.py` is
  the foundation. Field names stay boring (`node_count_max`, not nested). Bump
  `METRICS_VERSION` when a field is renamed/added/removed; a reader refuses an
  unknown version. Never hardcode a chart's axis — the user picks the field.
- **Missing data is a state, not a zero.** A skipped gate renders as absent
  (`None`), never `0`. `flatten_candidate` must emit `None` for absent fields;
  renderers must skip `None` rather than plot a lie.
- **Runs are keyed by source hash + recipe hash.** `recipe_hash()` hashes the
  sweep params (preset, filter_speckle, hierarchical, use_palette) so recipes
  are comparable across sources and runs.
- **Non-domination is computed on DATA values, not screen pixels.** Screen y is
  inverted; running the Pareto test on pixels maximises y. The test that pins
  this checks WHICH candidates are on the frontier (fill colour + position),
  not just counts.
- **Tests:** `python3 -m unittest discover -s tests`. No torch, no GPU, no
  network. Every emitted SVG must be well-formed XML and carry
  `width`/`height`/`viewBox` on the root.
- **Invalid specs raise `SpecError` / `QueryError`** (exit code 3 in the CLI),
  never a partial document. Validation lives in `chopshop_plot/spec.py` and
  `chopshop_plot/query.py`.
- **Host-agnostic.** No absolute paths, no hostnames, no secrets in code or docs.
- **Fractals are the one numpy exception.** `chopshop_plot/fractals.py` may
  import numpy (Mandelbrot/Julia/fern rasterise on a complex grid — pure Python
  is far too slow). `chopshop_plot/png.py` writes PNG with stdlib
  `zlib`/`struct`, no Pillow. Sierpinski stays stdlib SVG. The tests guard the
  numpy cases with `skipUnless(HAVE_NUMPY)` so the suite runs without it.
- **`demo/*.png` is gitignored** (regenerable via `demo/make_fractals.py`);
  the SVG demos are tracked. The generators live in `demo/`.
