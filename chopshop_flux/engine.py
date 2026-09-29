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

**The order inside ``load()`` is not a style choice.** Everything that changes a
pipeline's modules — the scheduler, the LoRA adapters, a swapped VAE — happens
BEFORE the pipeline is placed on the device, and ``enable_model_cpu_offload()``
is the last step, always. Measured on this box: assign ``pipe.vae`` on an
already-offloaded pipe and the *next* pipeline call dies with "Expected all
tensors to be on the same device, but found at least two devices, cuda:0 and
cpu!" — because accelerate built the offload map over the ORIGINAL VAE, and the
error surfaces inside the scheduler step, naming everything except the VAE.
Re-applying ``enable_model_cpu_offload()`` after such an assignment is a verified
fix, and the guard below uses it for the case where a pipe arrives already
offloaded; the normal path never needs it because the VAE is part of the load.
The scheduler is NOT in the device map — swapping it after the offload is
measured fine — so its position here is for reading order, not correctness.
"""

from __future__ import annotations

import gc
import hashlib
import os
import sys
import threading
import time
from dataclasses import dataclass, asdict
from datetime import datetime, timezone

from . import config
from .models import ModelSpec, ModelError, resolve, check_usable
from .modifiers import (check_modifier_usable, resolve_modifier, resolve_vae)


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


# A resolved libc handle for the trim below, or False once we know there is none.
_LIBC = None


def _return_freed_pages() -> int:
    """Hand freed pages back to the OS. Best effort, and glibc only.

    #flux-unload-trim -- gc.collect() frees the tensors but the ALLOCATOR keeps
    the arena, and on a 16 GB model that arena is the leak's other half. Measured:
    after an unload that had already freed every weight (28 small tensors left,
    and a further gc.collect() freeing 0 objects), RSS still sat at 16.23 GiB --
    and of two identical runs, one returned it a whole cycle later. `malloc_trim`
    gives ~1.45 GiB back on the spot and makes the release the same shape every
    time. Returns the number of bytes released, 0 when it is not available.

    A missing libc (musl, macOS, Windows) or a libc without malloc_trim is a
    silent no-op: this is a nicety on top of the fix, never a dependency of it.
    """
    global _LIBC
    if _LIBC is None:
        try:
            import ctypes
            libc = ctypes.CDLL("libc.so.6", use_errno=True)
            libc.malloc_trim.argtypes = [ctypes.c_int]
            libc.malloc_trim.restype = ctypes.c_int
            _LIBC = libc
        except Exception:  # noqa: BLE001 - any failure means "not available"
            _LIBC = False
    if _LIBC is False:
        return 0
    try:
        released = _LIBC.malloc_trim(0)
    except Exception:  # noqa: BLE001
        _LIBC = False
        return 0
    # glibc returns 1 if it released anything, 0 if not; the byte count is not
    # what the caller acts on, so report a coarse "did anything move".
    return int(released)


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _reference_list(reference) -> list[bytes]:
    """A reference as a LIST of blobs, whatever the caller handed over.

    ``None`` (no reference), one blob, or a list of blobs. Normalising in one
    place is what lets ``generate`` validate a count and ``_run`` decode without
    either having to guess which of the three shapes it was given — and it keeps
    ``_run``'s existing bytes-accepting contract true for a caller that predates
    multi-reference.
    """
    if reference is None:
        return []
    if isinstance(reference, (bytes, bytearray, memoryview)):
        return [bytes(reference)]
    return [bytes(blob) for blob in reference]


def pipeline_class_for(spec: ModelSpec, *, edit: bool) -> str:
    """The diffusers class a request needs.

    A family that splits text-to-image and image-to-image (SDXL, SD 1.5) names
    its edit class on ``spec.edit_pipeline``: the engine loads that class for a
    request carrying a reference, and ``spec.pipeline`` for one without. Families
    with one unified class (klein) leave ``edit_pipeline`` None and both paths
    resolve to the same class. Pure so the selection is testable without torch.
    """
    if edit and spec.edit_pipeline:
        return spec.edit_pipeline
    return spec.pipeline


# -- the modifier plan, all of it pure -------------------------------------
#
# Resolution, the licence gate, the schedule choice, the weights and the
# warnings are functions rather than loops inside generate() for one reason:
# every one of them is a rule that can be wrong, and a rule that can be wrong
# needs to be testable on a box with no GPU. generate() then does nothing but
# call them and hand the answer to load().


def resolve_modifiers(modifiers, modifier_scales=None):
    """Resolve, licence-gate and de-duplicate a modifier request.

    Returns ``(specs, weights, warnings)`` where ``specs`` preserves the
    caller's order (the first adapter loaded is the one whose scheduler wins)
    and ``weights`` is the effective adapter weight per spec: the caller's
    ``modifier_scales`` entry if there is one, otherwise the spec's own default.
    A scale naming a modifier that was not requested is a warning, not an error
    — the request is still coherent, it just carries dead weight.
    """
    if modifiers is None:
        modifiers = []
    elif isinstance(modifiers, str):
        # A bare string would otherwise be iterated character by character, and
        # "unknown modifier 'l'" is a bad way to learn that.
        modifiers = [modifiers]
    scales = dict(modifier_scales or {})
    warnings: list[str] = []
    specs = []
    seen = {}
    for name in modifiers:
        spec = resolve_modifier(name)
        if spec is None:
            continue
        if spec.key in seen:
            continue
        seen[spec.key] = True
        check_modifier_usable(spec)
        specs.append(spec)

    weights = []
    matched = set()
    for spec in specs:
        wanted = None
        for given, value in scales.items():
            alias = resolve_modifier(given)
            if alias is not None and alias.key == spec.key:
                wanted = value
                matched.add(given)
                break
        if wanted is None:
            weights.append(float(spec.scale))
            continue
        if isinstance(wanted, bool) or not isinstance(wanted, (int, float)):
            raise ModelError(
                "scale for modifier '%s' must be a number, got %r"
                % (spec.key, wanted), exit_code=2)
        weights.append(float(wanted))
    for given in scales:
        if given not in matched:
            warnings.append(
                "modifier_scales names '%s', which is not in the requested "
                "modifiers; the scale was ignored." % given)
    return specs, weights, warnings


def modifier_warnings(spec: ModelSpec, modifier_specs, weights, vae_spec,
                      *, steps: int, guidance: float) -> list[str]:
    """Everything honest there is to say about a modifier request.

    Each of these is a case where the request is accepted and the caller would
    otherwise believe something that is not true:

    * an adapter aimed at a different family still loads and still changes the
      output — it just delivers something other than what its card shows;
    * an adapter that carries its own schedule (LCM, Lightning) is a *distilled*
      adapter, so running it on the base 30-step CFG schedule produces noise,
      and the caller has to be told rather than left guessing which of the two
      numbers to change;
    * a VAE trained on another family decodes the latents it was not built for.
    """
    warnings: list[str] = []
    for mod in modifier_specs:
        if spec.key not in mod.targets:
            warnings.append(
                "modifier %s targets %s, not %s: it will be applied anyway, but "
                "it was not trained for this model, so its output is not what "
                "its own card shows."
                % (mod.key, ", ".join(mod.targets), spec.key))
    if vae_spec is not None and spec.key not in vae_spec.targets:
        warnings.append(
            "vae %s targets %s, not %s: it will be applied anyway, but it was "
            "not trained for this model."
            % (vae_spec.key, ", ".join(vae_spec.targets), spec.key))
    for mod, weight in zip(modifier_specs, weights):
        # "in effect" rather than "requested": the value here may be the model's
        # own default rather than something the caller typed, and claiming the
        # caller asked for a number they never mentioned would be its own small
        # lie. The case the brief cares about — an explicit ask that contradicts
        # the adapter — is a subset of this one.
        if mod.guidance is not None and guidance != mod.guidance:
            warnings.append(
                "guidance %s is in effect but %s was trained at guidance %s; "
                "adapter schedules are not interchangeable, and the adapter's "
                "own number is the one its card documents."
                % (guidance, mod.key, mod.guidance))
        if mod.steps is not None and steps != mod.steps:
            warnings.append(
                "steps %d are in effect but %s is a %d-step distilled adapter; "
                "running it at another step count is not the schedule it was "
                "distilled for."
                % (steps, mod.key, mod.steps))
        if weight == 0:
            warnings.append(
                "modifier %s was requested with scale 0, which disables it: the "
                "weights are loaded but contribute nothing." % mod.key)
    return warnings


def resolve_schedule(modifier_specs) -> tuple[str | None, list[str]]:
    """The scheduler the requested adapters need, and any conflict to report.

    One scheduler can be installed on one pipeline, so two adapters that ask
    for different ones cannot both be honoured. The first requested wins — the
    caller's own order is the only tie-break that does not invent a preference —
    and the conflict is reported rather than resolved in silence.
    """
    chosen: str | None = None
    warnings: list[str] = []
    for mod in modifier_specs:
        if not mod.scheduler:
            continue
        if chosen is None:
            chosen = mod.scheduler
        elif chosen != mod.scheduler:
            warnings.append(
                "modifiers ask for two different schedulers (%s and %s); only "
                "one pipeline scheduler can be installed, so %s is used."
                % (chosen, mod.scheduler, chosen))
    return chosen, warnings


def vae_class_name(spec) -> str:
    """Which diffusers class a VAE swap needs.

    A TAESD is not a smaller AutoencoderKL, it is a different module
    (AutoencoderTiny), so this is a class choice and not a size one.
    """
    return "AutoencoderTiny" if spec.tiny else "AutoencoderKL"


def vae_key_of(vae_spec) -> str | None:
    """The VAE key to echo back, or ``None`` for "the model's own VAE"."""
    return vae_spec.key if vae_spec is not None else None


class FluxEngine:
    """Loads one pipeline at a time and generates images through it.

    Which pipeline is the registry's business, not this class's: ``load()``
    reads ``spec.pipeline`` and looks the class up in diffusers, so the engine
    is family-agnostic. __init__ does no work and imports nothing heavy, so
    constructing an engine is cheap and safe on any machine.
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
        # Monotonic clock of the last successful generation (or load). The idle
        # reaper compares against it to decide when to release the weights.
        self._last_use: float = 0.0
        self._idle_thread: threading.Thread | None = None
        # What the last unload's page-return managed to do (#flux-unload-trim).
        # Reported in status() because "did the release actually take effect" is
        # the first question when the resident set does not drop.
        self._trimmed: int = 0
        # Which class the currently loaded pipe is (txt2img vs img2img). The
        # idempotency check must include it: a family that splits the two needs a
        # re-load when the same model is next asked to edit after generating.
        self._loaded_edit: bool = False
        # What was applied ON TOP of the loaded model. These are part of the
        # idempotency key for the same reason _loaded_edit is, and it is the
        # easiest bug in this file to write: a second request for the same model
        # with different adapters would otherwise be handed the first request's
        # pipeline and quietly generate the wrong thing.
        self._loaded_modifiers: tuple = ()
        self._loaded_vae: str | None = None
        self._loaded_scheduler: str | None = None

    # -- paths -------------------------------------------------------------

    @property
    def out_dir(self) -> str:
        return self._out_dir or config.out_dir()

    @property
    def offload(self) -> str:
        return self._offload or config.offload()

    # -- idle reaping ------------------------------------------------------

    def _start_idle_unload(self) -> None:
        """Start the idle-unload daemon thread when configured.

        Read at first load (not construction) so a service started with the knob
        set sees it, while an engine constructed in a test (default 0) never
        spawns a thread. Idempotent: a second load does not stack threads.
        """
        if self._idle_thread is not None:
            return
        seconds = config.idle_unload_seconds()
        if seconds <= 0:
            return

        def _reap() -> None:
            # Poll a small fraction of the window; a 30s floor keeps a short
            # window from spinning. Frees host RAM (and the warm pipe) only when
            # the service has been quiet past the threshold — re-loading on the
            # next request is the accepted cost.
            interval = max(30, min(seconds // 4, 300))
            while True:
                time.sleep(interval)
                with self._lock:
                    if self._pipe is None:
                        continue
                    if time.monotonic() - self._last_use < seconds:
                        continue
                    self.unload()

        thread = threading.Thread(target=_reap, name="flux-idle-unload", daemon=True)
        thread.start()
        self._idle_thread = thread

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
            # Whether the last unload got any pages back from the allocator. A
            # resident set that will not drop is the first symptom read here.
            "trimmed_on_unload": bool(self._trimmed),
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

    def load(self, model: str | None = None, edit: bool = False,
             modifiers=None, modifier_scales=None, vae: str | None = None
             ) -> ModelSpec:
        """Load a model, replacing whatever was loaded.

        Idempotent per (model, edit, modifier set with weights, VAE): the whole
        of that is what "the pipeline that is already loaded" means, so leaving
        any of it out of the comparison silently serves one request's adapter set
        to the next request.

        The preparation order inside is contractual, not stylistic — see the
        module docstring. Anything that replaces a module on the pipeline goes
        before the device placement, and the device placement is last.
        """
        spec = resolve(model)
        check_usable(spec)
        modifier_specs, weights, _ = resolve_modifiers(modifiers, modifier_scales)
        modifier_key = tuple(sorted(
            (mod.key, round(weight, 6))
            for mod, weight in zip(modifier_specs, weights)))
        vae_spec = resolve_vae(vae)
        # The licence gate belongs HERE, on the load path, not only on the
        # request path in generate(). A VAE is a checkpoint from a licensor and
        # may be non-commercial just as a model or a LoRA may, and this method is
        # reachable directly (a caller, a test, a future route) -- so a gate that
        # only fires in generate() is a hole in the invariant that loading a
        # non-commercial artefact requires the acknowledgement. Measured before
        # this line existed: load(vae=<a non-commercial VAE>) succeeded with no
        # ack while generate(vae=...) correctly refused it.
        if vae_spec is not None:
            check_modifier_usable(vae_spec)
        vae_key = vae_spec.key if vae_spec is not None else None
        scheduler_name, _ = resolve_schedule(modifier_specs)

        if self._pipe is not None and self._spec and self._spec.key == spec.key \
                and self._loaded_offload == self.offload \
                and self._loaded_edit == edit \
                and self._loaded_modifiers == modifier_key \
                and self._loaded_vae == vae_key:
            return spec

        self._start_idle_unload()
        import torch  # local on purpose: see the module docstring
        import diffusers

        # The pipeline class is named by the spec, not hardcoded: the registry
        # spans several families (Flux2KleinPipeline, StableDiffusionXLPipeline,
        # StableDiffusionPipeline, ...). A class the installed diffusers does
        # not have is a model this environment cannot run, not a crash. An edit
        # on a family that splits the two classes selects the img2img one.
        class_name = pipeline_class_for(spec, edit=edit)
        pipe_cls = getattr(diffusers, class_name, None)
        if pipe_cls is None:
            raise GenerationError(
                "diffusers has no %s, which %s (%s) needs; install a diffusers "
                "version that provides it."
                % (class_name, spec.key, spec.repo_id), exit_code=4)

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
            pipe = pipe_cls.from_pretrained(spec.repo_id,
                                            torch_dtype=torch.bfloat16)

            # -- 1. scheduler override -------------------------------------
            # An LCM or Lightning adapter is only an adapter *with* its
            # scheduler: the distilled schedule and the weights are one
            # artefact. Both classes are imported here, inside the method, like
            # everything else that needs diffusers.
            if scheduler_name == "lcm":
                from diffusers import LCMScheduler
                pipe.scheduler = LCMScheduler.from_config(pipe.scheduler.config)
            elif scheduler_name == "trailing-euler":
                from diffusers import EulerDiscreteScheduler
                pipe.scheduler = EulerDiscreteScheduler.from_config(
                    pipe.scheduler.config, timestep_spacing="trailing")

            # -- 2. LoRA adapters ------------------------------------------
            # One load call per modifier, each under its own adapter name, so
            # that set_adapters below can refer to them individually. A single
            # adapter needs no set_adapters call unless it has a scale.
            adapter_names = []
            for index, (mod, _weight) in enumerate(zip(modifier_specs, weights)):
                adapter_name = "modifier_%d_%s" % (index, mod.key)
                try:
                    pipe.load_lora_weights(mod.repo_id,
                                           weight_name=mod.weight_name,
                                           adapter_name=adapter_name)
                except Exception as exc:  # noqa: BLE001 - surface the reason
                    raise GenerationError(
                        "cannot load modifier %s (%s / %s): %s: %s"
                        % (mod.key, mod.repo_id, mod.weight_name,
                           type(exc).__name__, exc), exit_code=4) from exc
                adapter_names.append(adapter_name)

            # -- 3. adapter weights ----------------------------------------
            # Loading several adapters leaves only the last one active, so more
            # than one modifier always needs set_adapters — not just when a
            # scale was given. A single one at its default scale is already
            # active and needs nothing.
            needs_set = len(adapter_names) > 1 or any(w != 1.0 for w in weights)
            if needs_set:
                try:
                    pipe.set_adapters(adapter_names,
                                      adapter_weights=[float(w) for w in weights])
                except Exception as exc:  # noqa: BLE001
                    raise GenerationError(
                        "cannot set adapter weights for %s: %s: %s"
                        % (", ".join(adapter_names), type(exc).__name__, exc),
                        exit_code=4) from exc

            # -- 4. the VAE swap -------------------------------------------
            # BEFORE the offload. This is the ordering the whole comment block
            # in the module docstring is about: a VAE assigned after the offload
            # map was built stays on CPU and blows up inside the scheduler step.
            if vae_spec is not None:
                pipe.vae = self._load_vae(vae_spec, torch)
                if self.offload == "cpu" and getattr(pipe, "hf_device_map", None):
                    # A pipe that arrived already offloaded — not the path this
                    # method takes, since it always starts from a fresh
                    # from_pretrained, but the one a future caller could take.
                    # Re-applying the offload after the assignment is the
                    # verified fix; guessing at a per-module .to() is not.
                    pipe.enable_model_cpu_offload()

            # -- 5. device placement, LAST ---------------------------------
            if self.offload == "cpu":
                # 15.97 GB of weights against a 15.92 GiB card, so paging stages
                # in and out beats trying to hold them all resident. It is last
                # because it builds the device map over whatever modules the
                # pipeline has by now, including a swapped-in VAE.
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
                # what said so. Read off pipe.vae rather than a captured
                # reference, so a swap above is what gets tiled.
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
        except GenerationError:
            # Already a sentence with the right exit code; do not re-wrap it.
            raise
        except Exception as exc:  # noqa: BLE001 - surface the real reason
            raise GenerationError(
                "cannot load %s (%s): %s: %s"
                % (spec.repo_id, spec.key, type(exc).__name__, exc),
                exit_code=4) from exc

        self._pipe = pipe
        self._spec = spec
        self._loaded_offload = self.offload
        self._loaded_edit = edit
        self._loaded_modifiers = modifier_key
        self._loaded_vae = vae_key
        self._loaded_scheduler = scheduler_name
        self._load_seconds = round(time.monotonic() - started, 2)
        return spec

    def _load_vae(self, vae_spec, torch):
        """Load a VAE swap. A failure here is an error, never a fallback.

        Silently keeping the model's own VAE would report a successful request
        that produced the thing the caller was trying to replace — the failure
        would be invisible in every log and every response.
        """
        import diffusers

        class_name = vae_class_name(vae_spec)
        vae_cls = getattr(diffusers, class_name, None)
        if vae_cls is None:
            raise GenerationError(
                "diffusers has no %s, which vae %s (%s) needs; install a "
                "diffusers version that provides it."
                % (class_name, vae_spec.key, vae_spec.repo_id), exit_code=4)
        try:
            if vae_spec.tiny:
                # AutoencoderTiny takes no torch_dtype here: it is already a
                # tiny fp32/fp16 module and the installed diffusers resolves it
                # itself.
                return vae_cls.from_pretrained(vae_spec.repo_id)
            return vae_cls.from_pretrained(vae_spec.repo_id,
                                           torch_dtype=torch.bfloat16)
        except Exception as exc:  # noqa: BLE001 - surface the reason
            raise GenerationError(
                "cannot load vae %s (%s): %s: %s"
                % (vae_spec.key, vae_spec.repo_id, type(exc).__name__, exc),
                exit_code=4) from exc

    def unload(self) -> None:
        """Drop the pipeline and GIVE THE MEMORY BACK.

        #flux-unload-collect -- `del` alone does not release a diffusers pipeline,
        and that was an OOM kill. Measured on this box (klein-4b, offload=cpu):
        one generate + unload cycle leaves RSS at 16.81 GiB, of which **16.20 GiB
        is ANONYMOUS** -- not reclaimable file cache -- because the pipeline's
        modules sit in reference cycles (accelerate's offload hooks keep
        `module._hf_hook` and `module._old_forward` links pointing back into the
        modules), so dropping the last reference only decrements a count and the
        weights wait for the cyclic collector. Every model switch -- or any change
        to the (model, edit, modifiers, vae) key -- therefore added another ~16 GiB
        that never came back: the recorded service peaks of 35.3 / 63.8 / 77.3 GiB
        are 2 / 4 / 5 such cycles, and the fifth one was killed at 77.3 GiB on a
        91 GiB box with no swap.

        `gc.collect()` after the drop takes the same process from 16.20 GiB anon
        to 3.97 GiB, and a second collect frees nothing -- the cycles are broken,
        not deferred. Do not "optimise" this away: without it the leak is back, and
        it is silent until the OOM killer arrives.

        Order matters: collect FIRST (that is what drops the tensors), then
        `empty_cache()` to hand the freed device blocks back to the driver, and
        `_return_freed_pages()` last -- by then the host arena is what is left.
        """
        if self._pipe is not None:
            del self._pipe
            self._pipe = None
        self._spec = None
        self._loaded_offload = None
        self._loaded_edit = False
        self._loaded_modifiers = ()
        self._loaded_vae = None
        self._loaded_scheduler = None
        self._load_seconds = None
        self._load_notes = []
        gc.collect()
        if self._torch is not None:
            try:
                self._torch.cuda.empty_cache()
            except Exception:  # noqa: BLE001 - best effort
                pass
        # #flux-unload-trim -- the tensors are freed by now; this is the allocator
        # giving the pages back, which is the difference between a resident set
        # that settles and one that merely stops growing.
        self._trimmed = _return_freed_pages()

    def release(self) -> None:
        """``unload()`` under the engine lock, for a caller that is not already in it.

        The lock-free ``unload()`` is the internal primitive: ``load()`` calls it
        while already holding the lock, and a lock inside it would deadlock
        (``threading.Lock`` is not reentrant). A route handler has no such
        context, and calling ``unload()`` bare there is a race against whatever
        generation is mid-flight -- it would drop the pipe out from under a running
        ``_run``. So the route takes the lock through here and waits its turn,
        exactly as a generate does.
        """
        with self._lock:
            self.unload()

    # -- generation --------------------------------------------------------

    def generate(self, *, prompt: str, model: str | None = None,
                 width: int = 1024, height: int = 1024,
                 steps: int | None = None, guidance: float | None = None,
                 seed: int | None = None, images: int = 1,
                 reference: bytes | list[bytes] | None = None,
                 negative_prompt: str | None = None,
                 strength: float | None = None,
                 modifiers: list[str] | None = None,
                 modifier_scales: dict[str, float] | None = None,
                 vae: str | None = None) -> dict:
        """Generate (or edit) images. Returns the response body as a dict.

        ``reference`` bytes turn this into an edit, but the two families express
        that differently: klein unifies text-to-image and editing in one pipeline
        (``image=``, where ``None`` means text-to-image), while the SD-style
        pipelines take ``image=`` plus an img2img ``strength``. ``negative_prompt``
        is only meaningful where the pipeline accepts it. ``modifiers`` are LoRA
        keys and ``vae`` a VAE key, both resolved and licence-gated like a model.

        ``reference`` may be ONE blob or a LIST of them. A list conditions on
        every image at once — the prompt is the instruction that says how they
        relate ("the pose from the first, the palette from the second") — and
        only a model whose pipeline declares a list in its ``image=`` accepts
        it, so a second reference on an img2img family is a caller error rather
        than a silently dropped image. How many were really used is echoed back.

        What was requested — and what was actually applied — is echoed back in
        the response rather than silently dropped, including the scale the
        adapter really ran at.
        """
        if not isinstance(prompt, str) or not prompt.strip():
            raise ModelError("prompt must be a non-empty string", exit_code=2)
        if not isinstance(images, int) or images < 1:
            raise ModelError("images must be a positive integer", exit_code=2)

        spec = resolve(model)
        check_usable(spec)

        # A reference is bytes or a LIST of bytes; normalise once, here, so the
        # rest of the method has one shape to reason about. Multi-reference is a
        # property of the checkpoint, so a request carrying several is refused on
        # a family that takes one — before anything is loaded, rather than by the
        # pipeline mid-render, and rather than by dropping the extras quietly.
        references = _reference_list(reference)
        if len(references) > 1 and not spec.multi_reference:
            raise ModelError(
                "%s takes a single reference image, but %d were given. "
                "Multi-reference is a property of the checkpoint: a pipeline "
                "that declares a list for its 'image' conditions on all of them "
                "at once (the FLUX.2 [klein] family does), and an img2img "
                "pipeline takes exactly one."
                % (spec.key, len(references)), exit_code=2)

        # The modifier plan resolves, licence-gates and weights the request
        # before anything expensive happens — the same "reject before the GPU"
        # shape as the checks above.
        modifier_specs, modifier_weights, mod_warnings = resolve_modifiers(
            modifiers, modifier_scales)
        vae_spec = resolve_vae(vae)
        if vae_spec is not None:
            check_modifier_usable(vae_spec)
        scheduler_name, sched_warnings = resolve_schedule(modifier_specs)

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

        warnings = list(mod_warnings) + list(sched_warnings)
        # A distilled checkpoint runs no classifier-free guidance, and CFG is
        # the machinery a negative prompt acts through. Say so when the caller
        # asked for a guidance other than the model's own — true for every
        # distilled entry (klein-4b at 1.0, sdxl-turbo at 0.0), not just klein.
        # `guidance_embedded` is the exception that proves the rule: a distilled
        # pipeline with a guidance EMBEDDING acts on the number without running
        # CFG, so warning about it would be false.
        if spec.distilled and not spec.guidance_embedded \
                and guidance != spec.default_guidance:
            # Not an opinion — the pipeline's own behaviour. For a distilled
            # checkpoint `do_classifier_free_guidance` is
            # `guidance_scale > 1 and not is_distilled`, so it is always False:
            # no CFG runs, and diffusers logs "Guidance scale X is ignored".
            warnings.append(
                "guidance_scale %.3g is ignored: %s is a distilled checkpoint, "
                "so its pipeline never runs classifier-free guidance."
                % (guidance, spec.key))
        # Separate from the above: some families have no negative_prompt
        # parameter at all (Flux2KleinPipeline.__call__ has none), so asking for
        # one is asking for something the model does not have.
        if negative_prompt and not spec.negative_prompt:
            warnings.append(
                "negative prompt ignored: %s has no negative_prompt parameter"
                % spec.key)
        # Same shape as the negative prompt: a strength on a model without
        # SD-style img2img is silently dropped by the pipeline call, so say so
        # rather than pretending it did something. (The klein branch of _run
        # never passes strength, so this is the only place the operator hears.)
        if strength is not None and not spec.img2img_strength:
            warnings.append(
                "strength ignored: %s is not an SD-style img2img model"
                % spec.key)
        # Nor is the size always honoured: a pipeline with resolution binning
        # quietly re-bins to its own buckets, so the PNG can come back at a
        # different resolution than the one asked for.
        if spec.resolution_binning:
            warnings.append(
                "requested %dx%d may not be honoured: %s enables resolution "
                "binning, so the pipeline re-bins the request to its own "
                "buckets. Check the returned image's width and height rather "
                "than assuming they are the ones asked for."
                % (width, height, spec.key))
        warnings.extend(modifier_warnings(spec, modifier_specs, modifier_weights,
                                          vae_spec, steps=steps, guidance=guidance))

        wait_started = time.monotonic()
        with self._lock:
            queue_wait = round(time.monotonic() - wait_started, 2)
            self._busy = True
            self._last_use = time.monotonic()  # idle reaper counts from here
            try:
                # Only pass the modifier keywords when there is something to
                # apply. A request with no adapters and no VAE is exactly the
                # call this method has always made, and keeping that call shape
                # means the engine stays substitutable for anything that wraps
                # or stubs load() with the original two arguments.
                load_kwargs: dict = {"edit": bool(references)}
                if modifiers:
                    load_kwargs["modifiers"] = modifiers
                    load_kwargs["modifier_scales"] = modifier_scales
                if vae:
                    load_kwargs["vae"] = vae
                self.load(spec.key, **load_kwargs)
                results = self._run(spec, prompt=prompt, width=width,
                                    height=height, steps=steps,
                                    guidance=guidance, seed=seed,
                                    images=images, reference=references,
                                    negative_prompt=negative_prompt,
                                    strength=strength)
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
            "negative_prompt": negative_prompt,
            "strength": strength,
            # Echoed so the caller never has to guess what was applied: the
            # resolved modifier keys with the scale each one really ran at, the
            # VAE that ended up on the pipeline, and the scheduler an adapter
            # asked for. Empty/None when nothing was modified.
            "modifiers": [{"key": mod.key, "scale": weight, "repo_id": mod.repo_id,
                           "weight_name": mod.weight_name}
                          for mod, weight in zip(modifier_specs, modifier_weights)],
            "vae": vae_key_of(vae_spec),
            "scheduler": scheduler_name,
            "seed": seed,
            "edited": bool(references),
            # How many references really conditioned this render. A caller that
            # sent a list needs to read back that all of them were used as one
            # conditioning set, rather than that the first one was and the rest
            # were quietly ignored.
            "references": len(references),
            "queue_wait_seconds": queue_wait,
            "load_seconds": load_seconds,
            "images": [r.as_dict() for r in results],
            "total_seconds": round(sum(r.seconds for r in results), 2),
            "warnings": warnings,
        }

    def _run(self, spec: ModelSpec, *, prompt: str, width: int, height: int,
             steps: int, guidance: float, seed: int, images: int,
             reference: bytes | list[bytes] | None,
             negative_prompt: str | None = None,
             strength: float | None = None) -> list[ImageResult]:
        """Call the pipeline and write PNGs. Assumes the lock is held."""
        import io

        from PIL import Image

        torch = self._torch
        if torch is None:
            # _run is only reachable through load(), which sets this; the check
            # exists so the failure is a sentence rather than an AttributeError.
            raise GenerationError("no torch: call load() before generating")
        started = time.monotonic()
        # Accepts one blob or a list (see _reference_list), so a caller that
        # predates multi-reference keeps working unchanged.
        blobs = _reference_list(reference)
        ref_images = []
        for index, blob in enumerate(blobs):
            try:
                ref_images.append(Image.open(io.BytesIO(blob)).convert("RGB"))
            except Exception as exc:  # noqa: BLE001
                # One reference keeps the original sentence — it is the common
                # case, and the message a caller is already reading for.
                described = ("reference image" if len(blobs) == 1
                             else "reference image %d of %d" % (index + 1, len(blobs)))
                raise ModelError("%s is not a readable image: %s: %s"
                                 % (described, type(exc).__name__, exc),
                                 exit_code=2) from exc

        # A CPU generator: deterministic, and identical whether or not the
        # pipeline is paged in and out by CPU offload, which a CUDA-side
        # generator is not.
        generator = torch.Generator().manual_seed(seed)
        # The call shape differs by family. Everything common is passed the
        # same; only the image/strength/negative_prompt handling branches.
        kwargs = {
            "prompt": prompt,
            "width": width,
            "height": height,
            "num_inference_steps": steps,
            "guidance_scale": guidance,
            "num_images_per_prompt": images,
            "generator": generator,
            "output_type": "pil",
        }
        if spec.img2img_strength:
            # SD-style: image= only when there is a reference and strength only
            # when editing, so a text-to-image call carries neither. The
            # negative_prompt is passed only where the pipeline accepts one.
            # One image, always: an img2img pipeline takes exactly one, and
            # generate() refused a second before this ran.
            if ref_images:
                kwargs["image"] = ref_images[0]
                if strength is not None:
                    kwargs["strength"] = strength
            if spec.negative_prompt:
                kwargs["negative_prompt"] = negative_prompt
        else:
            # klein's unified call: image= is always passed (None for
            # text-to-image), and it has neither a negative_prompt nor a
            # strength parameter to pass. A single reference stays a bare image
            # rather than becoming a one-element list, so a one-reference edit
            # is byte-for-byte the call it has always been; two or more go
            # through as the list the pipeline iterates into condition_images.
            if len(ref_images) == 1:
                kwargs["image"] = ref_images[0]
            else:
                kwargs["image"] = ref_images or None
        try:
            with torch.inference_mode():
                out = self._pipe(**kwargs)
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
