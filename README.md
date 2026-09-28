# chopshop-plot — a geometry source and a run reporter

An **optional sidecar** for the chopshop pipeline with two capabilities:

1. **generate** — turn a JSON geometry spec into SVG (shapes, tiling, patterns).
   A programmatic *source* for the front half, the same way a raster or a prompt is.
2. **digest** — turn run metrics into chart SVG (bar / scatter / line).
   A post-hoc *reporter* on pipeline output.

The interface is a **language-agnostic JSON contract** (see `docs/contract.md`),
not a Python API. The Python package here is the reference implementation and is
**stdlib-only** — it writes SVG directly, because SVG is the pipeline's native
vector format. A Julia (Makie) or R (ggplot2) backend would read the same JSON
spec and emit the same SVG; see the contract for how backends slot in.

## Why stdlib-only

SVG is text. Shapes map one-to-one onto `<rect>`, `<circle>`, `<polygon>`,
`<path>` and a chart is a handful of rectangles, lines and text. Round-tripping
through a plotting library adds a dependency (and its own SVG wrapper) for no
gain at this stage. `matplotlib`+`shapely` (Python), `Makie` (Julia) and
`ggplot2` (R) are richer backends that can implement the same contract later —
they are named in the contract, not required to run this package.

## Usage

```
python3 cli.py generate spec.json out.svg   # geometry -> SVG
python3 cli.py digest   metrics.json out.svg # metrics  -> chart SVG
python3 cli.py generate - < spec.json > out.svg   # stdio
```

Exit codes: `0` success, `2` usage error, `3` invalid spec.

## Tests

```
python3 -m unittest discover -s tests -v
```

Stdlib only — no torch, no GPU, no absolute paths, no host identity.
