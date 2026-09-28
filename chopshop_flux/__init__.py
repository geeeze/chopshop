"""chopshop-flux — the generation layer's own image service for chopshop.

This is the *generation layer's* narrow replacement for the SwarmUI/ComfyUI
integration in chopshop-sui: a small registry of diffusers image models (FLUX.2
[klein], Stable Diffusion XL, Stable Diffusion 1.5), one HTTP service, own small
JSON API, no SwarmUI, no ComfyUI graph, no workflow wrapper.

Two hard rules carried over from chopshop-sui, because they are the rules that
keep this layer opt-in:

1. **This layer calls the pipeline; the pipeline never calls it.**
   ``front_pipeline.sh`` / ``pipeline.sh`` live in chopshop-svg and know nothing
   about this service.
2. **It never judges the art.** It produces sources; a human picks the winner.
   Nothing here traces, scores or ranks anything.
"""

__version__ = "0.1.0"

SERVICE_NAME = "chopshop-flux"

__all__ = ["__version__", "SERVICE_NAME"]
