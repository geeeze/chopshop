# Pin npm packages by running ./bin/importmap
pin "application"
pin "aether", to: "aether.js"
pin "aether-entropy", to: "aether-entropy.js"
pin "aether-core", to: "aether-core.js"
# The composite builder's constraint/snap engine (Sketchpad's two halves:
# strong conditions + constraints). Pinned and imported by aether.js like the
# entropy module, so the builder page finds it on window.Aether.sketch.
pin "aether-sketch", to: "aether-sketch.js"
pin "login", to: "login.js"
