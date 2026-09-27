"""chopshop-flux — a narrow FLUX.2 [klein] generation service for chopshop.

This is the *generation layer's* narrow replacement for the SwarmUI/ComfyUI
integration in chopshop-sui: one model family (FLUX.2 [klein], 4B and 9B), one
HTTP service, own small JSON API, no SwarmUI, no ComfyUI graph, no workflow
wrapper.

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
