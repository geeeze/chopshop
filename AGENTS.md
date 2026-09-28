# chopshop-plot — agent notes

- **stdlib-only.** No dependency beyond the Python standard library. Do not
  import `matplotlib`, `shapely`, `numpy`, or any third-party package. The
  package writes SVG directly; SVG is the pipeline's native vector format.
- **The contract is the interface.** `docs/contract.md` defines the JSON spec
  and the SVG output. Any change to either MUST update the contract and the
  tests in the same commit. A Julia (`Makie`) or R (`ggplot2`) backend would
  implement this same contract — they are named in the contract as rich
  backends, not required to run this package.
- **Tests:** `python3 -m unittest discover -s tests`. No torch, no GPU, no
  network, no fixtures. Every emitted SVG must be well-formed XML and carry
  `width`/`height`/`viewBox` on the root.
- **Invalid specs raise `SpecError`** (exit code 3 in the CLI), never a partial
  document. Validation lives in `chopshop_plot/spec.py`.
- **Host-agnostic.** No absolute paths, no hostnames, no secrets in code or docs.
