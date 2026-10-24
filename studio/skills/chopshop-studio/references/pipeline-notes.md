> contains HOST-SPECIFIC paths — the venv locations
> (`~/chopshop-svg/.venv`, `~/chopshop-studio-runner-venv`) and the
> 'this box' container decisions. The pipeline anatomy is generic.

## chopshop-svg front pipeline (dev)

`chopshop-svg` holds the real pipeline. Front half = `prep_raster.py` → `trace_sweep.py` →
`compare_candidates.py` (orchestrated by `front_pipeline.sh`), shared helpers in
`scripts/front_common.py`. By-hand side tools (not wired into stages): `scripts/node_reduce.py`
(targeted `geometry_overload` remedy) and `scripts/tune_sweep.py` (trace-setting bench);
`print.invert` adds a prep-time colour-inverted twin. Suite is 342 tests (a host run without
inkscape skips the inkscape/gs/qpdf ones). Run tests from the repo venv, NOT the mock-runner venv:
`~/chopshop-studio-runner-venv` has only Pillow (the mock runner is pure-PIL by design), while
the pipeline needs numpy/vtracer/lxml. Depth — venv setup, sweep-axis anatomy, the checklist
for adding an axis/variant, and the fidelity-against-own-source rule — lives in
`references/front-pipeline-dev.md`.

- The front half gained two by-hand side tools and a spec key (suite is now 342 tests): `scripts/node_reduce.py` (targeted `geometry_overload` remedy — only over-gate paths, `--verify` renders before/after; clearing the node budget ≠ the artwork surviving), `scripts/tune_sweep.py` (batch trace-setting bench that never recommends a cell), and `print.invert` (writes a colour-inverted prepped twin; `{mode:"negative"}` preserves alpha). None is wired into the pipeline stages. The inverse twin is a STANDARD prep output, not pitch-shift-specific: the studio defaults `print.invert: true` in both the new-job spec textarea and the JSON builder's JS, and the mock runner always emits `source.inverse.png` (it used to only on `pitch_shift`).
- `print.invert` (prep-time inverted twin, upstream) overlaps conceptually with the pitch-shift `inverse` variant added earlier in `trace_sweep.py`. Different mechanisms in different stages (prep raster twin vs. sweep variant) and NOT reconciled — do not assume one replaces the other without reading both.
- The `chopshop-svg` image build is slow (~15 min) because the Dockerfile's final step runs `pytest tests/ -q` INSIDE the image, which has inkscape installed — so inkscape-dependent tests (e.g. `test_node_reduce.py`'s `node_reduce.py --verify` benchmark with `timeout=600`) actually execute, unlike the host run which skips them. Run the build in the background (`docker compose build > /tmp/build.log 2>&1 &`) and poll it; a core pegged at ~100% in the pytest step is the benchmark running, NOT a hang. To shorten rebuilds, add a `@pytest.mark.bench` marker to the slow inkscape tests and run `pytest tests/ -q -m 'not bench'` in the Dockerfile — a bare `-m 'not bench'` deselects nothing because no such marker exists yet.

**Packaging + opt-in rule (user-set, applies to every pipeline change).** The pipeline runs
containerised, so the README's `apt-get install inkscape ghostscript …` host instructions are the wrong
answer for this box: bake the tools into the image instead (pngquant, rembg plus its u2net model,
node + svgo; Real-ESRGAN needs a Vulkan device and stays host-only, with the in-container Pillow
LANCZOS fallback). Baking a tool in must NOT change the artwork, so every optional prep step defaults
OFF and runs only when the spec enables it (`print.tools.<step>: true`): "the binary happens to be on
PATH" is not consent to transform someone's art, and it would also make output depend on how a host
was provisioned. A step that is enabled while its tool is missing must fail loudly with the reason
(exit 3, reason recorded in the sidecar) rather than silently skipping the transform that was asked for.
