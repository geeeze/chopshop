"""The diffusers seam — the only module that touches torch.

``torch`` and ``diffusers`` are imported *inside* the methods, never at module
scope. That is deliberate and it is the property the whole test suite rests on:
``import chopshop_flux.server`` works on a machine with no GPU, no torch and no
models, so the HTTP contract, the registry and the client can all be tested
anywhere. chopshop-sui's bridge keeps the same discipline for the same reason
(its 21 tests run with no server and no models).

Concurrency is ONE. There is one GPU, so a second concurrent generate waits on a
lock instead of over-subscribing VRAM — a 17 GB card running one 13 GB pipeline
does not have room to be clever. Asking for several images in one request is
genuinely batched (``num_images_per_prompt``), which is the cheap kind of
parallelism; separate requests are not.
"""

from __future__ import annotations

import hashlib
import os
import sys
import threading
import time
from dataclasses import dataclass, asdict
from datetime import datetime, timezone

from . import config
from .models import ModelSpec, ModelError, resolve, check_usable


@dataclass
class ImageResult:
    name: str
    path: str
    width: int
    height: int
    bytes: int
    sha256: str
    seed: int
    model: str
    seconds: float

    def as_dict(self) -> dict:
        return asdict(self)


class GenerationError(Exception):
    """Generation was attempted and failed."""

    def __init__(self, message: str, exit_code: int = 5):
        super().__init__(message)
        self.exit_code = exit_code


def offload_unavailable_message(error: object, interpreter: str) -> str:
    """The actionable sentence for "CPU offload needs accelerate".

    Split out as a pure function so the wording is testable without torch:
    diffusers raises a bare ImportError naming only a version number, which
    tells you nothing about *which* interpreter is missing the package or what
    your alternative is. Both are in the message instead.
    """
    return (
        "CPU offload needs `accelerate`, and it is not installed in %s (%s). "
        "Either install it there (`%s -m pip install accelerate`), or set "
        "CHOPSHOP_FLUX_OFFLOAD=none if the model fits in VRAM on this card."
        % (interpreter, error, interpreter))


def _utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class FluxEngine:
    """Loads one klein pipeline at a time and generates images through it.

    __init__ does no work and imports nothing heavy, so constructing an engine is
    cheap and safe on any machine.
    """

    def __init__(self, out_dir: str | None = None, offload: str | None = None):
        self._out_dir = out_dir
        self._offload = offload
        self._lock = threading.Lock()
        self._pipe = None
        self._spec: ModelSpec | None = None
        self._loaded_offload: str | None = None
        self._load_seconds: float | None = None
        self._device: str | None = None
        self._torch = None
        self._busy = False
        # Non-fatal things that happened during load. Recorded rather than
        # swallowed: "decode peak memory was not reduced" is the missing half of
        # the next OutOfMemoryError, and the caller can only act if it is told.
        self._load_notes: list[str] = []

    # -- paths -------------------------------------------------------------

    @property
    def out_dir(self) -> str:
        return self._out_dir or config.out_dir()

    @property
    def offload(self) -> str:
        return self._offload or config.offload()

    # -- status ------------------------------------------------------------

    def status(self) -> dict:
        info = {
            "loaded_model": self._spec.key if self._spec else None,
            "loaded_repo": self._spec.repo_id if self._spec else None,
            "load_seconds": self._load_seconds,
            "offload": self.offload,
            "busy": self._busy,
            "out_dir": self.out_dir,
            "vae_tiling": config.vae_tiling(),
            "load_notes": list(self._load_notes),
        }
        info.update(self._device_status())
        return info

    def _device_status(self) -> dict:
        """Device facts, without importing torch just to answer.

        Reports the device NAME as well as the memory: torch on ROCm presents the
        GPU as ``cuda``, and an integrated GPU can enumerate as a device with
        less VRAM than the card you meant. chopshop-sui's plan hit exactly that
        and its note is the reason this field exists — never assume device 0 is
        the big card, look at what it says it is.
        """
        if self._torch is None:
            return {"torch": None, "device": None, "device_name": None,
                    "vram_total_gb": None, "vram_free_gb": None, "rocm": None}
        torch = self._torch
        try:
            name = torch.cuda.get_device_name(0)
            free, total = torch.cuda.mem_get_info(0)
            return {
                "torch": torch.__version__,
                "rocm": getattr(torch.version, "hip", None),
                "device": self._device,
                "device_name": name,
                "vram_total_gb": round(total / 1e9, 2),
                "vram_free_gb": round(free / 1e9, 2),
            }
        except Exception as exc:  # noqa: BLE001 - a status probe must not raise
            return {"torch": torch.__version__, "device": None,
                    "device_name": None, "vram_total_gb": None,
                    "vram_free_gb": None, "rocm": None,
                    "device_error": "%s: %s" % (type(exc).__name__, exc)}

    # -- loading -----------------------------------------------------------

    def load(self, model: str | None = None) -> ModelSpec:
        """Load a model, replacing whatever was loaded. Idempotent per model."""
        spec = resolve(model)
        check_usable(spec)
        if self._pipe is not None and self._spec and self._spec.key == spec.key \
                and self._loaded_offload == self.offload:
            return spec

        import torch  # local on purpose: see the module docstring
        from diffusers import Flux2KleinPipeline

        self._torch = torch
        if not torch.cuda.is_available():
            raise GenerationError(
                "no accelerator available to torch. On ROCm check "
                "torch.version.hip; the pipeline is unusable on CPU.",
                exit_code=4)

        self.unload()
        self._device = "cuda"
        started = time.monotonic()
        try:
            pipe = Flux2KleinPipeline.from_pretrained(spec.repo_id,
                                                     torch_dtype=torch.bfloat16)
            if self.offload == "cpu":
                # 15.97 GB of weights against a 15.92 GiB card, so paging stages
                # in and out beats trying to hold them all resident.
                try:
                    pipe.enable_model_cpu_offload()
                except ImportError as exc:
                    # Not fatal-looking in diffusers' own words, and it is the
                    # difference between "install one package" and "this box
                    # cannot run it", so say which.
                    raise GenerationError(
                        offload_unavailable_message(exc, sys.executable),
                        exit_code=4) from exc
            else:
                pipe.to(self._device)

            # NOTE: the VAE's config declares force_upcast (fp32 decode), and
            # `pipe.vae.to(torch.float32)` here does NOT work: the latents leave
            # the denoise loop as bf16 and Flux2KleinPipeline never casts them,
            # so decode fails with "Input type (c10::BFloat16) and bias type
            # (float) should be the same". Doing it properly means taking over
            # the decode (generate with output_type="latent", cast, decode), which
            # is only worth it if bf16 decode is shown to be the NaN source.
            if config.vae_tiling():
                # The switch is on the VAE, not the pipeline: Flux2KleinPipeline
                # has no enable_vae_tiling(), so calling it there raises
                # AttributeError and tiling silently never happens. That is what
                # caused this branch to be rewritten, and the load note below is
                # what said so.
                enable_tiling = getattr(pipe.vae, "enable_tiling", None)
                if enable_tiling is None:
                    self._load_notes.append(
                        "VAE tiling was requested but this VAE offers no "
                        "enable_tiling(); decode peak memory is not reduced")
                else:
                    try:
                        enable_tiling()
                    except Exception as exc:  # noqa: BLE001
                        self._load_notes.append(
                            "could not enable VAE tiling (%s: %s); decode peak "
                            "memory is not reduced" % (type(exc).__name__, exc))
        except Exception as exc:  # noqa: BLE001 - surface the real reason
            raise GenerationError(
                "cannot load %s (%s): %s: %s"
                % (spec.repo_id, spec.key, type(exc).__name__, exc),
                exit_code=4) from exc

        self._pipe = pipe
        self._spec = spec
        self._loaded_offload = self.offload
        self._load_seconds = round(time.monotonic() - started, 2)
        return spec

    def unload(self) -> None:
        if self._pipe is not None:
            del self._pipe
            self._pipe = None
        self._spec = None
        self._loaded_offload = None
        self._load_seconds = None
        self._load_notes = []
        if self._torch is not None:
            try:
                self._torch.cuda.empty_cache()
            except Exception:  # noqa: BLE001 - best effort
                pass

    # -- generation --------------------------------------------------------

    def generate(self, *, prompt: str, model: str | None = None,
                 width: int = 1024, height: int = 1024,
                 steps: int | None = None, guidance: float | None = None,
                 seed: int | None = None, images: int = 1,
                 reference: bytes | None = None) -> dict:
        """Generate (or edit) images. Returns the response body as a dict.

        ``reference`` bytes turn this into an edit: klein unifies text-to-image
        and editing in one pipeline, and ``image=`` is the only difference.
        """
        if not isinstance(prompt, str) or not prompt.strip():
            raise ModelError("prompt must be a non-empty string", exit_code=2)
        if not isinstance(images, int) or images < 1:
            raise ModelError("images must be a positive integer", exit_code=2)

        spec = resolve(model)
        check_usable(spec)

        # Defaults come from the registry, never from the pipeline class: its own
        # defaults (50 steps, guidance 4.0) are the base model's schedule and
        # would quietly run a distilled checkpoint wrong.
        steps = spec.default_steps if steps is None else int(steps)
        guidance = spec.default_guidance if guidance is None else float(guidance)
        if steps < 1:
            raise ModelError("steps must be >= 1", exit_code=2)

        from .models import validate_size
        validate_size(spec, width, height)

        if seed is None:
            seed = int.from_bytes(os.urandom(4), "big")
        seed = int(seed)

        warnings = []
        if spec.distilled and guidance != 1.0:
            # Not an opinion — the pipeline's own behaviour. For a distilled
            # checkpoint `do_classifier_free_guidance` is
            # `guidance_scale > 1 and not is_distilled`, so it is always False:
            # no CFG runs, and diffusers logs "Guidance scale X is ignored".
            # CFG is the machinery a negative prompt acts through, which is the
            # whole reason one cannot act here.
            warnings.append(
                "guidance_scale %.3g is ignored: %s is step-wise distilled, so "
                "the pipeline never runs classifier-free guidance. That is also "
                "why a negative prompt has no effect on it — put the steering in "
                "the prompt and the reference image."
                % (guidance, spec.key))
        wait_started = time.monotonic()
        with self._lock:
            queue_wait = round(time.monotonic() - wait_started, 2)
            self._busy = True
            try:
                self.load(spec.key)
                results = self._run(spec, prompt=prompt, width=width,
                                    height=height, steps=steps,
                                    guidance=guidance, seed=seed,
                                    images=images, reference=reference)
                load_seconds = self._load_seconds
            finally:
                self._busy = False

        return {
            "model": spec.key,
            "repo_id": spec.repo_id,
            "license": spec.license,
            "commercial_ok": spec.commercial_ok,
            "prompt": prompt,
            "width": width,
            "height": height,
            "steps": steps,
            "guidance": guidance,
            "seed": seed,
            "edited": reference is not None,
            "queue_wait_seconds": queue_wait,
            "load_seconds": load_seconds,
            "images": [r.as_dict() for r in results],
            "total_seconds": round(sum(r.seconds for r in results), 2),
            "warnings": warnings,
        }

    def _run(self, spec: ModelSpec, *, prompt: str, width: int, height: int,
             steps: int, guidance: float, seed: int, images: int,
             reference: bytes | None) -> list[ImageResult]:
        """Call the pipeline and write PNGs. Assumes the lock is held."""
        import io

        from PIL import Image

        torch = self._torch
        if torch is None:
            # _run is only reachable through load(), which sets this; the check
            # exists so the failure is a sentence rather than an AttributeError.
            raise GenerationError("no torch: call load() before generating")
        started = time.monotonic()
        ref_image = None
        if reference is not None:
            try:
                ref_image = Image.open(io.BytesIO(reference)).convert("RGB")
            except Exception as exc:  # noqa: BLE001
                raise ModelError("reference image is not a readable image: %s: %s"
                                 % (type(exc).__name__, exc), exit_code=2) from exc

        # A CPU generator: deterministic, and identical whether or not the
        # pipeline is paged in and out by CPU offload, which a CUDA-side
        # generator is not.
        generator = torch.Generator().manual_seed(seed)
        try:
            with torch.inference_mode():
                out = self._pipe(
                    image=ref_image,
                    prompt=prompt,
                    width=width,
                    height=height,
                    num_inference_steps=steps,
                    guidance_scale=guidance,
                    num_images_per_prompt=images,
                    generator=generator,
                    output_type="pil",
                )
        except Exception as exc:  # noqa: BLE001 - the caller needs the reason
            raise GenerationError("generation failed: %s: %s"
                                  % (type(exc).__name__, exc)) from exc

        produced = getattr(out, "images", None) or []
        if not produced:
            raise GenerationError("pipeline returned no images")

        elapsed = time.monotonic() - started
        per_image = elapsed / len(produced)
        os.makedirs(self.out_dir, exist_ok=True)
        stamp = _utc_stamp()
        results = []
        for index, image in enumerate(produced, start=1):
            # We name our own files, so the name is ours to make safe. (The
            # SwarmUI bridge named files after the prompt, which meant every
            # download URL needed percent-encoding. Not a problem you have to
            # have.)
            name = "%s-%s-s%d-%02d.png" % (stamp, spec.key, seed, index)
            path = os.path.join(self.out_dir, name)
            image.save(path, format="PNG")
            with open(path, "rb") as handle:
                raw = handle.read()
            results.append(ImageResult(
                name=name, path=path,
                width=int(image.width), height=int(image.height),
                bytes=len(raw), sha256=_sha256(raw), seed=seed,
                model=spec.key, seconds=round(per_image, 2)))
        return results
