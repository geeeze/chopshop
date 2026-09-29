"""ComfyUI node: ChopShop Trace (VTracer).

Traces a raster IMAGE tensor to SVG using the exact same tracer as the
chopshop-svg pipeline (the ``vtracer`` PyPI wheel, ``convert_image_to_svg_py``).
The SVG is written to the ComfyUI output directory and the saved filename is
returned as a STRING for downstream routing.

This is the "trace" step in the trace -> generate -> trace workflow. It does
NOT judge art and does NOT generate or edit SVG paths with an LLM — tracing is
VTracer only, matching the pipeline's hard rule.

The node is flagged ``is_output_node=True`` so ComfyUI always executes it even
when nothing downstream consumes the SVG filename (lazy evaluation would
otherwise prune the trace step).

Hardening (why the try/except and nan_to_num are here):
  - VTracer is a Rust binary behind a pyo3 shim. A Rust panic (e.g. "overflow"
    when a noisy fp8-decoded image makes its internal Vec allocation blow up)
    surfaces as ``pyo3_runtime.PanicException``, which is a *BaseException*.
    ComfyUI's prompt worker only catches ``Exception``, so an uncaught panic
    kills the worker thread and the queue entry hangs as "running" forever.
    We therefore catch ``BaseException`` around the tracer and re-raise a
    normal ``RuntimeError`` so the node fails cleanly and the queue advances.
  - fp8 diffusion decode (FLUX.2 on ROCm) can emit NaN/Inf pixels, which
    ``np.clip`` does NOT remove. Those corrupt the PNG handed to VTracer, which
    is the most common trigger for the overflow panic. ``np.nan_to_num`` strips
    them before the uint8 cast.
"""

from __future__ import annotations

import os
import tempfile

import numpy as np
from PIL import Image

from comfy_api.latest import ComfyExtension, io

import folder_paths  # noqa: E402


def _trace_one(image_tensor, *, colormode, hierarchical, mode, filter_speckle,
               color_precision):
    """[H, W, C] float tensor -> SVG string.

    Raises RuntimeError on any tracer failure (including a Rust panic) so the
    calling node fails cleanly instead of hanging the queue.
    """
    import torch
    import vtracer

    if hasattr(image_tensor, "cpu") and hasattr(image_tensor, "numpy"):
        arr = image_tensor.detach().cpu().numpy()
    else:
        arr = np.asarray(image_tensor)
    # Strip NaN/Inf first (np.clip leaves NaN alone), then clamp to [0, 1].
    arr = np.nan_to_num(arr, nan=0.0, posinf=1.0, neginf=0.0)
    arr = np.clip(arr, 0.0, 1.0)
    arr = (arr * 255.0 + 0.5).astype(np.uint8)
    if arr.ndim == 3 and arr.shape[-1] == 4:
        pil = Image.fromarray(arr, "RGBA").convert("RGB")
    elif arr.ndim == 3 and arr.shape[-1] == 1:
        pil = Image.fromarray(arr[:, :, 0], "L").convert("RGB")
    else:
        pil = Image.fromarray(arr, "RGB")

    in_fd, in_path = tempfile.mkstemp(suffix=".png")
    out_fd, out_path = tempfile.mkstemp(suffix=".svg")
    os.close(in_fd)
    os.close(out_fd)
    try:
        pil.save(in_path)
        # #sui-trace-node-vtracer: the in-graph trace call site -- the same
        # convert_image_to_svg_py the pipeline uses, run on the backend's wheel.
        try:
            vtracer.convert_image_to_svg_py(
                in_path,
                out_path,
                colormode=colormode,
                hierarchical=hierarchical,
                mode=mode,
                filter_speckle=filter_speckle,
                color_precision=color_precision,
            )
        except BaseException as exc:  # noqa: BLE001 — catch Rust panics too
            raise RuntimeError(
                f"vtracer trace failed ({type(exc).__name__}: {exc}); "
                f"params colormode={colormode} hierarchical={hierarchical} "
                f"mode={mode} filter_speckle={filter_speckle} "
                f"color_precision={color_precision}"
            ) from exc
        with open(out_path, "r", encoding="utf-8") as handle:
            return handle.read()
    finally:
        for path in (in_path, out_path):
            try:
                os.remove(path)
            except OSError:
                pass


class ChopShopTrace(io.ComfyNode):
    @classmethod
    def define_schema(cls) -> io.Schema:
        return io.Schema(
            node_id="ChopShopTrace",
            display_name="ChopShop Trace (VTracer)",
            category="chopshop",
            description=(
                "Trace a raster to SVG with VTracer (the chopshop-svg tracer). "
                "Writes the SVG to the output dir and returns its filename."
            ),
            inputs=[
                io.Image.Input("image"),
                io.Combo.Input("colormode", options=["color", "binary"]),
                io.Combo.Input("hierarchical", options=["stacked", "cutout"]),
                io.Combo.Input("mode", options=["spline", "polygon", "none"]),
                io.Int.Input("filter_speckle", default=4, min=0, max=100, step=1),
                # VTracer's valid color_precision range is 1..8; higher values
                # can panic the Rust tracer ("overflow").
                io.Int.Input("color_precision", default=6, min=1, max=8, step=1),
                io.String.Input(
                    "filename_prefix",
                    default="chopshop_trace",
                    multiline=False,
                ),
            ],
            is_output_node=True,
            outputs=[
                io.String.Output(display_name="svg_filename"),
            ],
        )

    @classmethod
    def execute(cls, image, colormode, hierarchical, mode, filter_speckle,
                color_precision, filename_prefix) -> io.NodeOutput:
        out_dir = folder_paths.get_output_directory()
        filenames = []
        for index in range(image.shape[0]):
            svg = _trace_one(
                image[index],
                colormode=colormode,
                hierarchical=hierarchical,
                mode=mode,
                filter_speckle=filter_speckle,
                color_precision=color_precision,
            )
            name = "%s_%05d.svg" % (filename_prefix, index)
            with open(os.path.join(out_dir, name), "w", encoding="utf-8") as handle:
                handle.write(svg)
            filenames.append(name)

        result = filenames[0] if len(filenames) == 1 else filenames
        return io.NodeOutput(result, ui={"filenames": filenames})


class ChopShopExtension(ComfyExtension):
    async def get_node_list(self) -> list[type[io.ComfyNode]]:
        return [ChopShopTrace]


async def comfy_entrypoint() -> ChopShopExtension:
    return ChopShopExtension()
