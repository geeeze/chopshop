# Pin npm packages by running ./bin/importmap
pin "application"
pin "aether", to: "aether.js"
pin "aether-entropy", to: "aether-entropy.js"
pin "aether-core", to: "aether-core.js"
# The composite builder's constraint/snap engine (Sketchpad's two halves:
# strong conditions + constraints). Pinned and imported by aether.js like the
# entropy module, so the builder page finds it on window.Aether.sketch.
pin "aether-sketch", to: "aether-sketch.js"
# The graph view's force-directed SVG engine (issue #96). A side-effect import:
# the file is a self-contained IIFE (no imports, no exports) that boots itself on
# `[data-graph-root]` and exposes a read-only diagnostic on window.GraphView, so
# `node --check` can gate it as a plain script.
pin "graph", to: "graph.js"
pin "login", to: "login.js"
# The datasets filter selects' tail: a search over the FULL ranked vocabulary,
# read from the library JSON. Boots on [data-dataset-vocabulary].
pin "dataset-vocabulary", to: "dataset_vocabulary.js"
