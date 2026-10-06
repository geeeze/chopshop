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

**The output-side passes (`hires`, `ink_cap`, `background`, `seeds`) are named
after what they change, not after an opinion about the frame.** #flux-ink-cap: a
cap is a colour REDUCTION — the count actually present is measured from the
buffer that is written, and a frame already at the cap says "nothing was
reduced" rather than implying work. #flux-background: a key is a 4-connected
flood from a UNIFORM border; a border that is not one colour is left completely
alone and says so. #flux-hires: a second pass whose per-pass seconds are
reported, because a slow route has to be visible. None of them ranks anything,
and each is opt-in: a request that uses none of them takes the request path it
always took, which ``scripts/probe_output_path.py`` captures before and after a
change and ``tests/test_output_features.py`` pins.

**The order of the passes is fixed: hires, then ink_cap, then background.** The
cap must see the frame that will be judged (so, after the refining pass) and the
key must see the final palette (so, after the reduction) — a key before the cap
would put a colour into the histogram that is not part of the artwork.

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
import json
import os
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone

from . import config
from . import guard
from .guard import GpuContention
from .models import ModelSpec, ModelError, resolve, check_usable
from .modifiers import (check_modifier_usable, resolve_modifier, resolve_vae)
from .postprocess import (Frame, hires_target, hires_warnings, isolate_background,
                          parse_background, parse_hires, parse_ink_cap,
                          parse_provenance, parse_seeds, records_provenance,
                          reduce_colors)


# The image record's always-present fields, in the order they are reported. The
# output-side keys are added by `ImageResult.as_dict` only when a pass actually
# ran, so an ordinary request's record is the record it has always been.
IMAGE_BASE_FIELDS = ("name", "path", "width", "height", "bytes", "sha256",
                     "seed", "model", "seconds")
IMAGE_PASS_FIELDS = ("ink_cap", "background", "hires", "provenance", "sidecar")


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
    # What the output-side passes measured on THIS frame: the cap and the count
    # actually present, what was keyed and how many pixels moved, each hires
    # pass's seconds and the target size. None means the pass did not run.
    ink_cap: dict | None = None
    background: dict | None = None
    hires: dict | None = None
    # The fields a later trace comparison needs, per frame (#flux-provenance).
    provenance: dict | None = None
    sidecar: str | None = None

    def as_dict(self) -> dict:
        out = {key: getattr(self, key) for key in IMAGE_BASE_FIELDS}
        for key in IMAGE_PASS_FIELDS:
            value = getattr(self, key)
            if value is not None:
                out[key] = value
        return out


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
    gave ~1.45 GiB back on the spot in that run; in the 2026-10-06 re-measurement
    it returned 0 bytes in every sampled cycle, so treat it as best effort rather
    than a number to plan around. It still makes the release the same shape every
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


# The resident set below which a post-unload exit is NOT worth it. 1 GiB: an
# empty interpreter with torch imported is a few hundred MB, so anything above
# this after an unload is weights that did not go back.
_IDLE_EXIT_FLOOR_BYTES = 1024 ** 3


def resident_anon_bytes() -> int | None:
    """THIS process's anonymous resident memory, from /proc/self/status.

    Anonymous, not total: the weights' page cache is charged to the process too,
    and counting it would report a leak where there is reclaimable cache. This is
    the same distinction ``chopshop-flux``'s own notes draw (``RssAnon`` versus
    ``RssFile``), and getting it wrong inverts the conclusion. ``None`` when the
    platform has no /proc (the check is then skipped rather than guessed).
    """
    try:
        with open("/proc/self/status", "r", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("RssAnon:"):
                    return int(line.split()[1]) * 1024
    except (OSError, ValueError, IndexError):
        return None
    return None


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


def effective_negative_prompt(spec: ModelSpec, negative_prompt):
    """The negative prompt this request actually sends, and where it came from.

    Returns ``(value, source)``. ``source`` is ``"request"`` when the caller gave
    one (including ``""``, which is a deliberate "send none"), ``"default"`` when
    the registry's print default was substituted, and ``None`` when nothing is
    sent at all.

    #flux-negative-defaults -- the substitution happens only for entries whose
    pipeline HAS a ``negative_prompt`` parameter, it is reported as the default
    rather than as something the caller sent, and it is overridable. A negative
    prompt is a real knob on SDXL/SSD/SD 1.5 and a knob that does nothing
    elsewhere; the service's existing behaviour of answering "ignored, with a
    warning" for the entries that cannot use one is kept exactly.
    """
    if negative_prompt is not None:
        # An empty string is a choice, not an absence: it says "send no negative
        # prompt even though you have a default", which is how a caller gets
        # byte-for-byte the request this service made before defaults existed.
        return negative_prompt, "request"
    if not spec.negative_prompt:
        return None, None
    return spec.default_negative_prompt, "default"


def hires_target_for(spec: ModelSpec, width: int, height: int, hires: dict
                     ) -> tuple[int, int]:
    """The second pass's size, or a 400 naming ``hires`` that refuses it.

    #flux-hires -- the upscale target is checked against the model's OWN rules
    before anything is loaded, because the img2img pass runs at that size: a
    scale that lands off the model's grid, or over its ``max_pixels``, is a
    caller error and not something to clamp into range. The message names
    ``hires.scale`` and quotes the model's rule, so the fix is obvious.
    """
    from .models import validate_size
    target_width, target_height = hires_target(width, height, hires["scale"])
    try:
        validate_size(spec, target_width, target_height)
    except ModelError as exc:
        raise ModelError(
            "hires.scale %s on %dx%d gives %dx%d, which %s refuses: %s (the "
            "second pass runs at the target size, so the target has to satisfy "
            "the model's own resolution rules)"
            % (hires["scale"], width, height, target_width, target_height,
               spec.key, exc), exit_code=2) from exc
    return target_width, target_height


def _frame_of(image) -> Frame:
    """A decoded PIL frame as a raw buffer the postprocess passes can read."""
    if getattr(image, "mode", "RGB") not in ("RGB", "RGBA"):
        image = image.convert("RGB")
    return Frame(image.mode, image.width, image.height, image.tobytes())


def _image_of(frame: Frame):
    """A raw buffer back as a PIL frame. Local import: PIL is this module's seam."""
    from PIL import Image
    return Image.frombytes(frame.mode, (frame.width, frame.height), frame.data)


def _resampling_flag(Image, name: str):
    """PIL's resampling flag by name, across the two spellings Pillow has used."""
    table = getattr(Image, "Resampling", Image)
    return getattr(table, name.upper())


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
        #flux-idle-restart -- a callable the HTTP layer installs so the idle
        # exit can drain before ending the process. None in every other context
        # (a test engine, an embedding), and the exit then behaves exactly as it
        # did before: there is no socket to drain when there is no server.
        self._drain_hook = None
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
        # The last GPU-contention decision (#flux-gpu-guard), and this load
        # attempt's findings. A separate list from _load_notes on purpose:
        # unload() resets _load_notes, and the guard runs BEFORE the unload a
        # load performs, so a note kept there would be wiped before anyone read
        # it. Reported in status() as gpu_guard.
        self._guard_last: dict | None = None
        self._guard_notes: list[str] = []
        # #flux-gpu-guard -- true for exactly as long as a request is being HELD
        # by CHOPSHOP_FLUX_GUARD=wait (#5). `busy` covers that whole window too
        # (generate sets it before load runs the gate), and the two situations
        # want opposite answers from whoever is polling: generating finishes on
        # its own, a resident holder never lets go. Reported as
        # gpu_guard.waiting.
        self._guard_waiting = False
        # Whether the STARTUP probe took a reading (#14). Separate from
        # `_free_vram_seen`: the gate can produce that reading too, and the
        # refresh in `_guard_status` should only run when we know a re-read is
        # free because torch is already imported.
        self._guard_probed = False
        # The last free-VRAM figure this process actually MEASURED. Reported by
        # status() when the device block has no reading, which is the normal
        # state before the first load: _device_status deliberately does not
        # import torch to answer, but the guard has already imported it to make
        # its decision — so during a contention wait this is the live number,
        # and without it /health showed "not measured" while the guard was
        # holding the request for exactly that reason.
        self._free_vram_seen: float | None = None

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
                    self._exit_if_still_holding()

        thread = threading.Thread(target=_reap, name="flux-idle-unload", daemon=True)
        thread.start()
        self._idle_thread = thread

    def _exit_if_still_holding(self) -> None:
        """End the process when an idle unload did NOT give the memory back.

        MEASURED, and the fix for a fault that repeated: ``unload()`` frees the
        tensors and the resident set does not follow. After a *successful* unload
        this process still held **16.2 GB of anonymous memory** — so an idle
        timer that only unloaded released the weights while the box stayed short
        by the weights' worth of RAM, and with NO SWAP on the box that is how the
        desktop gets killed while ``free`` still shows memory "available".

        So this MEASURES rather than assumes: it exits only if the resident set is
        genuinely still large after the unload. A torch or libc that does return
        the pages in future leaves the service up, which is what makes this a fix
        rather than a ritual. The exit is a FAILURE code, so a unit with the
        ordinary ``Restart=on-failure`` brings the service straight back; the next
        request pays one load's latency (1.3 s measured), which is far cheaper
        than a dead desktop.

        Called with the engine lock held and only when the service has been quiet
        past the threshold, so no request can be mid-flight.
        """
        if not config.idle_exit_enabled():
            return
        holding = resident_anon_bytes()
        if holding is None or holding < _IDLE_EXIT_FLOOR_BYTES:
            return
        print("flux-idle-exit: unloading left %.2f GB resident (RssAnon); exiting "
              "so the unit restarts the service with the memory actually returned"
              % (holding / 1024 ** 3), flush=True)
        #flux-idle-restart -- DRAIN before the exit, not after. The port is open
        # right up until `os._exit`, so a step that posts in the ~5s the unit
        # takes to come back gets a refused TCP connect — which is how a chain
        # of seven green steps came back reported as an error. Draining first
        # turns that into a 503 that names the wait, which the client already
        # retries; the client's own retry then covers the gap after the process
        # is really gone. Both halves, because either alone leaves a window.
        #
        # The drain is a callback rather than a server import: `engine.py` is
        # imported by the tests on a machine with no torch and must not know what
        # an HTTP server is. `serve()` installs it; a test engine that never had
        # one simply exits, which is the old behaviour and still correct.
        drain = getattr(self, "_drain_hook", None)
        if drain is not None:
            try:
                drain()
            except Exception as exc:  # noqa: BLE001 - a drain must not block the exit
                print("flux-idle-exit: drain failed (%s: %s); exiting anyway"
                      % (type(exc).__name__, exc), flush=True)
        # A NON-ZERO exit, deliberately. This is a clean, intended end — but
        # exit(0) is "success", and a unit whose policy is the common
        # Restart=on-failure would then leave the service DEAD rather than bring
        # it back. Signalling it as a failure means the fix works with the policy
        # a deployment already has, and it is not a lie: the service failed to
        # release the memory its configuration asked it to.
        os._exit(1)

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
        info["gpu_guard"] = self._guard_status(info.get("vram_free_gb"))
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

    # -- GPU contention (#flux-gpu-guard) ----------------------------------

    def free_vram_gb(self) -> float | None:
        """Free VRAM in decimal GB as the DEVICE sees it, or None if unreadable.

        Device-wide, not this process's: ``torch.cuda.mem_get_info`` reports the
        whole card, so another process's allocation appears here — verified
        before this guard existed, when LM Studio's resident model showed up in
        /health's ``vram_free_gb``. That is the property the guard needs, and it
        is why the gate catches holders other than the one it can name.

        None is a real answer — no torch, or no ROCm device — and callers must
        not read it as "the card is free". A box with no torch cannot load a
        model at all, so it is not a case to guess about.
        """
        torch = self._torch
        if torch is None:
            try:
                import torch  # local on purpose: see the module docstring
            except Exception:  # noqa: BLE001 - a missing torch is a fact here
                return None
        try:
            free, _total = torch.cuda.mem_get_info(0)
        except Exception:  # noqa: BLE001 - a probe must not raise
            return None
        self._free_vram_seen = free / 1e9
        return self._free_vram_seen

    def probe_guard(self) -> float | None:
        """Read free VRAM once at STARTUP, so /health answers before any load.

        #14: the device block deliberately does not import torch and only the
        load path did, so right after a start (or an idle-exit restart) /health
        reported ``measured: false`` for a card that could already be full from
        another tenant — and a generation submitted into that window OOM'd at
        load instead of being refused with ``503 gpu_busy``, which is the whole
        thing the guard exists to do. One reading here makes contention visible
        from the moment the process is up.

        ``guard=off`` skips it: a dedicated card has nothing to report,
        ``contended`` is null there by definition, and importing torch to say
        so would be a cost with no answer attached. A misconfigured guard value
        is skipped too — /health reports that (`mode: null, error: ...`) and a
        service that refused to start because of it would take the reporting
        route with it.

        Returns the reading, or None when there is none. Never raises.
        """
        try:
            if config.guard_mode() == guard.OFF:
                return None
        except ValueError:
            return None
        reading = self.free_vram_gb()
        if reading is not None:
            self._guard_probed = True
        return reading

    def _guard_status(self, free_gb: float | None) -> dict:
        """The guard's live view, for /health.

        Live rather than last-decision because the question a human arrives with
        is "is something else on the card RIGHT NOW".

        ``free_gb`` prefers the device block (which deliberately does NOT import
        torch to answer) and falls back to the last figure the guard MEASURED.
        Before this process has loaded a model or run the guard once both are
        absent, and ``measured`` is ``false`` — which is not the same as "the
        card is clear": the load path always measures, importing torch if it has
        to. Do not read a null here as agreement that there is room.

        Never raises: a status probe that can 500 the route is worse than one
        that reports the failure, and a misconfigured guard must still leave
        /health answerable.
        """
        try:
            mode = config.guard_mode()
            required = config.guard_vram_gb()
            lm = None
            if mode != guard.OFF:
                lm = guard.probe_lmstudio(config.guard_lmstudio_url())
            reading = free_gb if free_gb is not None else self._free_vram_seen
            if free_gb is None and self._guard_probed:
                # Nothing is loaded, so the device block has no reading — but
                # this process imported torch at startup, so a re-read costs
                # one mem_get_info. Serving the number the process STARTED with
                # under `measured: true` would be a stale reading claiming to
                # be live, which is the same category of lie as `measured:
                # false` meaning "not read yet" (#5).
                live = self.free_vram_gb()
                reading = live if live is not None else reading
            return {
                "mode": mode,
                "required_free_gb": required,
                "free_gb": reading,
                "measured": reading is not None,
                "waiting": self._guard_waiting,
                "contended": (None if mode == guard.OFF
                              else guard.contended(reading, required)),
                "lmstudio": lm.as_dict() if lm is not None else None,
                "notes": list(self._guard_notes),
                "last": self._guard_last,
            }
        except Exception as exc:  # noqa: BLE001 - status must not raise
            return {"mode": None, "error": "%s: %s" % (type(exc).__name__, exc),
                    "waiting": self._guard_waiting,
                    "notes": list(self._guard_notes), "last": self._guard_last}

    # -- loading -----------------------------------------------------------

    def _guard_gate(self) -> None:
        """Refuse, wait, or note that another process is holding the GPU.

        Takes no model argument on purpose: the threshold is one global number
        (CHOPSHOP_FLUX_GUARD_VRAM_GB) because under ``offload=cpu`` the peak is a
        single stage rather than the model's total, so a per-model table would
        be four unverified numbers pretending to be precise.

        Runs on the LOAD path, before torch is imported and before anything is
        moved onto the card, for the same reason the licence gate lives in
        ``models.check_usable``: a guard that only fires in one route is a hole.
        Every generate goes through here, because generate calls load.

        Deliberately does NOT take the engine lock. The engine serialises one
        generation; a second request waiting on the lock is already doing the
        right thing, and taking a lock here would make ``/health`` wait behind a
        contended load just to report that the card is contended.

        Raises ``GpuContention`` when the mode is ``block`` (immediately) or
        ``wait`` (after the budget expires with the card still full).
        """
        mode = config.guard_mode()
        self._guard_notes = []
        self._guard_last = None
        if mode == guard.OFF:
            return
        required = config.guard_vram_gb()
        lm = guard.probe_lmstudio(config.guard_lmstudio_url())
        free = self.free_vram_gb()
        state = guard.contended(free, required)
        waited = 0.0
        if state and mode == guard.WAIT:
            # Flag the hold for its whole duration, because /health answers
            # DURING it: `busy` alone cannot distinguish "generating" from
            # "held by the guard" (#5). `finally` so an expired budget — which
            # leaves here by exception — cannot strand the flag at true.
            self._guard_waiting = True
            try:
                free, waited = guard.wait_for_headroom(
                    self.free_vram_gb, required,
                    config.guard_wait_seconds(), config.guard_poll_seconds())
            finally:
                self._guard_waiting = False
            state = guard.contended(free, required)
        action = "clear"
        if state:
            self._guard_notes.append(
                guard.contention_message(free, required, lm, mode, waited))
            action = "refused" if mode in (guard.BLOCK, guard.WAIT) else "warned"
        elif state is None and lm is not None and lm.holding:
            # No device view to compare against, but the configured holder says
            # it has a model resident. Recorded, never gated: an unreadable
            # reading is not evidence of contention.
            self._guard_notes.append(
                guard.contention_message(None, required, lm, guard.WARN))
            action = "unmeasurable"
        self._guard_last = {
            "contended": state,
            "free_gb": None if free is None else round(free, 2),
            "required_free_gb": required,
            "waited_seconds": waited,
            "action": action,
            "holder": lm.as_dict() if lm is not None else None,
        }
        if action == "refused":
            raise GpuContention(self._guard_notes[-1])

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

        # Before anything expensive is imported or placed on the card: is
        # another process holding the GPU? (#flux-gpu-guard)
        self._guard_gate()
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

        `gc.collect()` after the drop is what keeps a CYCLE from adding another
        16 GB to the floor (measured on the second cycle: 31.17 GiB anon ->
        16.24 GiB). It does NOT return the process to a small one, and an
        earlier record claiming 16.20 -> 3.97 GiB did not reproduce (two runs,
        2026-10-06: the first cycle's collect freed 0.00 GB, and the floor after
        every unload was ~16.2 GB -- the table lives in docs/API.md under
        "giving the memory back"). Do not "optimise" this away: without it the
        leak is back, and it is silent until the OOM killer arrives.

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
                 vae: str | None = None,
                 ink_cap: int | None = None, ink_cap_mode: str | None = None,
                 background: str | None = None, hires: dict | None = None,
                 seeds: list | None = None, provenance: bool | None = None
                 ) -> dict:
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

        ``ink_cap``/``ink_cap_mode``, ``background``, ``hires``, ``seeds`` and
        ``provenance`` are the output-side passes; each is optional and none of
        them ranks anything. ``seeds`` is a sweep: one frame per seed, in the
        order given, returned with the seed→file mapping. ``provenance`` records
        the fields a later trace comparison needs, per frame, and is implied by
        any of the other four (a comparison needs those numbers written down).
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

        # The output-side keys are validated HERE, next to the rest of the
        # "reject before the GPU" checks: a bad value is a 400 naming the key it
        # came from, never a silent default and never a clamp.
        cap = parse_ink_cap(ink_cap, ink_cap_mode)          # #flux-ink-cap
        background_mode = parse_background(background)      # #flux-background
        hires_spec = parse_hires(hires)                     # #flux-hires
        seed_list = parse_seeds(seeds)                      # #flux-seeds
        want_provenance = parse_provenance(provenance)      # #flux-provenance
        if seed_list is not None and seed is not None:
            raise ModelError(
                "seeds was given together with seed: `seeds` is the sweep and "
                "`seed` is the single seed, so a request carrying both does not "
                "say which one it means. Send one or the other.", exit_code=2)
        if hires_spec is not None and not spec.img2img_strength:
            raise ModelError(
                "hires needs an img2img pass that takes a strength, and %s does "
                "not have one: its pipeline is %s, which has no `strength` "
                "parameter, so a second pass could not say how far from the "
                "first frame it may move. Hires is available on the entries "
                "whose `img2img_strength` flag is true in /models."
                % (spec.key, spec.pipeline), exit_code=2)

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

        # #flux-hires -- the second pass runs at the UPSCALED size, so the target
        # has to satisfy the model's own resolution rules and stay under its
        # max_pixels. Checked here, before anything is loaded, and refused rather
        # than clamped into range.
        if hires_spec is not None:
            hires_target_for(spec, width, height, hires_spec)

        if seed_list is not None:
            # A sweep: one frame per seed, in the caller's order (#flux-seeds).
            run_seeds = list(seed_list)
        else:
            if seed is None:
                seed = int.from_bytes(os.urandom(4), "big")
            seed = int(seed)
            run_seeds = [seed]
        # `seed` describes ONE seed; a sweep is described by `seeds`. Reporting
        # the first seed of a sweep as "the seed" would be a half-truth.
        reported_seed = None if seed_list is not None else seed

        # #flux-negative-defaults -- the negative prompt this request actually
        # sends, and whether the caller sent it or the entry's print default was
        # substituted. The substitution only happens for an entry whose pipeline
        # HAS the parameter, and `""` from the caller means "send none".
        negative_effective, negative_source = effective_negative_prompt(
            spec, negative_prompt)

        warnings = list(mod_warnings) + list(sched_warnings)
        if hires_spec is not None:
            # A strength inside the safe band is silent; above it the second pass
            # is allowed (<= 0.5) but the caller is told what it means.
            warnings.extend(hires_warnings(spec.key, hires_spec))
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
        if negative_effective and not spec.negative_prompt:
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
                results = []
                for run_seed in run_seeds:
                    # A sweep is the same request run once per seed, in the
                    # caller's order, one frame each time (#flux-seeds). Nothing
                    # is ranked; the mapping is the whole of the answer.
                    results.extend(self._run(
                        spec, prompt=prompt, width=width, height=height,
                        steps=steps, guidance=guidance, seed=run_seed,
                        images=images, reference=references,
                        negative_prompt=negative_effective,
                        strength=strength, ink_cap=cap,
                        background=background_mode, hires=hires_spec))
                record_provenance = records_provenance(
                    want_provenance, ink_cap=cap, hires=hires_spec,
                    seeds=seed_list, background=background_mode)
                if record_provenance:
                    # #flux-provenance -- what a later trace comparison needs,
                    # per frame, in the response and in a sidecar beside the PNG.
                    # No score and no ordering is written: the comparison lives
                    # in the pipeline, and this side records only the inputs.
                    for result in results:
                        self._record_provenance(
                            result, spec, prompt=prompt, steps=steps,
                            guidance=guidance, negative_prompt=negative_effective,
                            negative_source=negative_source,
                            background=background_mode,
                            requested=(width, height),
                            modifiers=[{"key": mod.key, "scale": weight,
                                        "repo_id": mod.repo_id,
                                        "weight_name": mod.weight_name}
                                       for mod, weight in zip(modifier_specs,
                                                              modifier_weights)],
                            vae=vae_key_of(vae_spec), scheduler=scheduler_name)
                load_seconds = self._load_seconds
            finally:
                self._busy = False

        # #flux-provenance -- the requested/produced pair rides every recorded
        # frame, but a number nobody is TOLD is how a re-binned size reaches a
        # print (#11). Say it where a caller already looks: the response. Gated
        # on the registry's `resolution_binning` because that is the only thing
        # here that silently changes a size, and `hires` is excluded because
        # changing the size is the entire point of that pass — its own report
        # already carries the target.
        if hires_spec is None and spec.resolution_binning:
            re_binned = [r for r in results
                         if (r.width, r.height) != (width, height)]
            if re_binned:
                sizes = ", ".join("%dx%d" % (r.width, r.height)
                                  for r in re_binned)
                warnings.append(
                    "%d of %d frame(s) came back at a different size than "
                    "asked: requested %dx%d, produced %s — %s re-binned it "
                    "(resolution binning). Check the frame's real size before "
                    "using it; with provenance on, each frame records both as "
                    "requested_width/requested_height."
                    % (len(re_binned), len(results), width, height, sizes,
                       spec.key))

        body = {
            "model": spec.key,
            "repo_id": spec.repo_id,
            "license": spec.license,
            "commercial_ok": spec.commercial_ok,
            "prompt": prompt,
            "width": width,
            "height": height,
            "steps": steps,
            "guidance": guidance,
            # The negative prompt that was SENT, not the one that was typed: on an
            # entry with a print default the two differ, and
            # negative_prompt_source says which it is. An empty string is echoed
            # as an empty string (the caller's deliberate "send none").
            "negative_prompt": negative_effective,
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
            "seed": reported_seed,
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
        # The output-side keys are echoed ONLY when they were used, so a request
        # that uses none of them answers with the body it always did (the same
        # rule `server._modifier_kwargs` follows for the adapter knobs).
        if negative_source == "default":
            body["negative_prompt_source"] = "default"
        if cap is not None:
            body["ink_cap"] = dict(cap)
        if background is not None:
            body["background"] = background_mode
        if hires_spec is not None:
            hires_echo = dict(hires_spec)
            hires_echo["target"] = list(hires_target(width, height,
                                                     hires_spec["scale"]))
            per_image = [r.hires for r in results if r.hires]
            if per_image:
                # Per-pass seconds, summed over the frames this request wrote, so
                # a slow route is visible in the response rather than inferred
                # from total_seconds (#flux-hires).
                hires_echo["target"] = list(per_image[0]["target"])
                hires_echo["pass_seconds"] = [
                    round(sum(entry["pass_seconds"][0] for entry in per_image), 2),
                    round(sum(entry["pass_seconds"][1] for entry in per_image), 2)]
            body["hires"] = hires_echo
        if seed_list is not None:
            body["seeds"] = list(seed_list)
            mapping: dict = {}
            for result in results:
                mapping.setdefault(str(result.seed), []).append(result.name)
            # The seed -> file mapping, in the order the seeds were given. This
            # is not a ranking: nothing says which frame is better.
            body["seed_files"] = {str(seed): mapping[str(seed)]
                                  for seed in seed_list if str(seed) in mapping}
        if any(r.provenance for r in results):
            body["provenance"] = True
        return body

    def _call(self, spec: ModelSpec, *, prompt: str, width: int, height: int,
              steps: int, guidance: float, generator, images: int,
              ref_images: list, strength: float | None,
              negative_prompt: str | None,
              label: str = "generation") -> list:
        """Run ONE pipeline pass and return the frames it produced.

        The call shape differs by family, and only the
        image/strength/negative_prompt handling branches. Both passes of a
        ``hires`` request go through HERE, which is what makes the second pass
        the same request at a larger size rather than a second, subtly different
        call — and what keeps a text-to-image call carrying neither ``image`` nor
        ``strength`` exactly as it always did.
        """
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
            with self._torch.inference_mode():
                out = self._pipe(**kwargs)
        except Exception as exc:  # noqa: BLE001 - the caller needs the reason
            raise GenerationError("%s failed: %s: %s"
                                  % (label, type(exc).__name__, exc)) from exc
        return list(getattr(out, "images", None) or [])

    def _hires_frame(self, image, spec: ModelSpec, *, prompt: str, guidance: float,
                     generator, negative_prompt: str | None, hires: dict,
                     request_steps: int, first_pass_seconds: float):
        """Upscale one decoded frame, then run the img2img pass over it.

        #flux-hires -- the target size is computed from the frame that ACTUALLY
        came back rather than from the requested one, so a pipeline that re-bins
        a size (`resolution_binning`) is reported at the size it really used, and
        the target is re-checked against the model's own rules there. Both
        passes' seconds are returned: a slow second pass is the thing to look at
        when a hires request feels wrong, and it cannot be inferred from the
        total.

        Steps INHERIT the request's own count unless ``hires.steps`` says
        otherwise (#13). Before this, pass 2 ran ``hires.steps or
        spec.default_steps`` — so ``--steps 20`` produced a cheaper pass 1 and a
        full-price pass 2 at the model's default 30, and the record reported 30
        with no sign that 20 had been asked for. Pass 2 is dearer than pass 1
        (MEASURED: SDXL 512 -> 1024, 4.21 s then 7.80 s), so a caller lowering
        steps to bring the bill down was lowering half of it. A caller who really
        wants a different second pass sets ``hires.steps`` explicitly, and the
        report carries BOTH numbers either way, the way ``requested_width`` and
        ``width`` are paired.
        """
        from PIL import Image  # local on purpose: this module is the PIL seam

        target_width, target_height = hires_target_for(
            spec, image.width, image.height, hires)
        upscaled = image.resize((target_width, target_height),
                                _resampling_flag(Image, hires["upscaler"]))
        # `is not None`, not `or`: an explicit 0 is refused by parse_hires long
        # before here, and `x or default` is the pattern this repo has already
        # been bitten by on a legitimate falsy value.
        steps = hires["steps"] if hires["steps"] is not None else request_steps
        started = time.monotonic()
        refined = self._call(spec, prompt=prompt, width=target_width,
                             height=target_height, steps=steps,
                             guidance=guidance, generator=generator, images=1,
                             ref_images=[upscaled], strength=hires["strength"],
                             negative_prompt=negative_prompt,
                             label="hires second pass")
        seconds = round(time.monotonic() - started, 2)
        if not refined:
            raise GenerationError("hires second pass returned no images")
        report = {"scale": hires["scale"], "strength": hires["strength"],
                  "steps": steps,
                  # What the request itself ran, so the pair is readable: equal
                  # when the second pass inherited, different when hires.steps
                  # was set on purpose (#13).
                  "requested_steps": request_steps,
                  "upscaler": hires["upscaler"],
                  "target": [target_width, target_height],
                  "pass_seconds": [round(first_pass_seconds, 2), seconds]}
        return refined[0], report

    def _record_provenance(self, result: ImageResult, spec: ModelSpec, *,
                           prompt: str, steps: int, guidance: float,
                           negative_prompt: str | None,
                           negative_source: str | None, background: str,
                           requested: tuple, modifiers: list,
                           vae: str | None, scheduler: str | None) -> dict:
        """Write one frame's provenance: in the response, and in a sidecar.

        #flux-provenance -- the fields a later "which generation traced best"
        comparison needs, and nothing more: which model, which seed, which
        prompt, what the passes measured, what size came out. There is no score,
        no rank and no verdict here, deliberately — the comparison lives in the
        pipeline (chopshop-svg's tournament), and this side only records the
        inputs it would read.

        The sidecar is ``<name>.json`` beside the PNG, so `/files/<name>.json`
        serves a frame's record next to the frame.
        """
        provenance = {
            "model": spec.key,
            "repo_id": spec.repo_id,
            "license": spec.license,
            "commercial_ok": spec.commercial_ok,
            "seed": result.seed,
            "prompt": prompt,
            "steps": steps,
            "guidance": guidance,
            "negative_prompt": negative_prompt,
            "negative_prompt_source": negative_source,
            # What was asked for and what came out, both: they differ under
            # `hires` and under a resolution-binning pipeline, and a comparison
            # that only knows one of them cannot tell which frame is which.
            "requested_width": requested[0],
            "requested_height": requested[1],
            "width": result.width,
            "height": result.height,
            "background": background,
            "ink_cap": result.ink_cap,
            "hires": result.hires,
            "modifiers": modifiers,
            "vae": vae,
            "scheduler": scheduler,
            "name": result.name,
            "sha256": result.sha256,
            "bytes": result.bytes,
            "seconds": result.seconds,
            "generated_utc": _utc_stamp(),
        }
        sidecar = result.name + ".json"
        with open(os.path.join(self.out_dir, sidecar), "w", encoding="utf-8") as handle:
            handle.write(json.dumps(provenance, indent=2, sort_keys=True))
        result.provenance = provenance
        result.sidecar = sidecar
        return provenance

    def _run(self, spec: ModelSpec, *, prompt: str, width: int, height: int,
             steps: int, guidance: float, seed: int, images: int,
             reference: bytes | list[bytes] | None,
             negative_prompt: str | None = None,
             strength: float | None = None,
             ink_cap: dict | None = None,
             background: str = "keep",
             hires: dict | None = None) -> list[ImageResult]:
        """Call the pipeline and write PNGs. Assumes the lock is held.

        The output-side passes run in a fixed order — hires, then the ink cap,
        then the background — and each one records its own numbers on the frame
        it wrote rather than on the frame it hoped for (#flux-hires,
        #flux-ink-cap, #flux-background).
        """
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
        # generator is not. A hires request reuses it for the second pass, so
        # "same seed" means the same sequence of draws for both passes.
        generator = torch.Generator().manual_seed(seed)
        produced = self._call(spec, prompt=prompt, width=width, height=height,
                              steps=steps, guidance=guidance,
                              generator=generator, images=images,
                              ref_images=ref_images, strength=strength,
                              negative_prompt=negative_prompt)
        if not produced:
            raise GenerationError("pipeline returned no images")

        elapsed = time.monotonic() - started
        per_image = elapsed / len(produced)
        os.makedirs(self.out_dir, exist_ok=True)
        stamp = _utc_stamp()
        results = []
        for index, image in enumerate(produced, start=1):
            passes: dict = {}
            if hires is not None:
                image, passes["hires"] = self._hires_frame(
                    image, spec, prompt=prompt, guidance=guidance,
                    generator=generator, negative_prompt=negative_prompt,
                    hires=hires, request_steps=steps,
                    first_pass_seconds=per_image)
            if ink_cap is not None:
                # The cap is applied to the frame that will be judged, so after
                # the refining pass and before the key.
                reduced, passes["ink_cap"] = reduce_colors(
                    _frame_of(image), ink_cap["max_colors"], ink_cap["mode"])
                image = _image_of(reduced)
            if background != "keep":
                isolated, passes["background"] = isolate_background(
                    _frame_of(image), background)
                image = _image_of(isolated)
            # We name our own files, so the name is ours to make safe. (The
            # SwarmUI bridge named files after the prompt, which meant every
            # download URL needed percent-encoding. Not a problem you have to
            # have.)
            name = "%s-%s-s%d-%02d.png" % (stamp, spec.key, seed, index)
            path = os.path.join(self.out_dir, name)
            image.save(path, format="PNG")
            with open(path, "rb") as handle:
                raw = handle.read()
            # Both passes are this frame's cost when there was a second one.
            seconds = per_image + passes.get("hires", {}).get("pass_seconds", [0, 0])[1]
            results.append(ImageResult(
                name=name, path=path,
                width=int(image.width), height=int(image.height),
                bytes=len(raw), sha256=_sha256(raw), seed=seed,
                model=spec.key, seconds=round(seconds, 2), **passes))
        return results
