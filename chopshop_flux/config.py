"""All configuration comes from the environment.

Nothing here names a host, a port or a directory that belongs to one machine.
That is the same rule chopshop-studio states for its runner map — a repo that
hardcodes a machine's topology goes stale the moment the machine moves — and it
is what lets this same code run on the GPU box that hosts the model and on a
runner somewhere else.

Read at CALL time, not at import time, so a test (or a long-lived service) can
change the environment and get the new value without reloading the module.
"""

from __future__ import annotations

import os

SERVICE_NAME = "chopshop-flux"

# Loopback, deliberately. A service that generates images and streams them back
# has no business on every interface by default; chopshop-svg's runner.py ships
# 0.0.0.0 and its own contract doc calls that a footgun. Reaching this box from
# elsewhere is an explicit act: set CHOPSHOP_FLUX_BIND to the tailnet address.
DEFAULT_BIND = "127.0.0.1"

# chopshop-svg's runner is 8791 and the studio's mock runner is 8790, so stay in
# that range but off both.
DEFAULT_PORT = 8795

# The FLUX.2 [klein] family's own resolution rules, used as the per-model
# defaults in the registry. They are NOT global rules anymore: each ModelSpec
# carries its own dim_multiple / min_dim / max_pixels, and SDXL / SD 1.5 set
# theirs explicitly. These constants remain so the klein entries can fall back
# to them without repeating the numbers.
DEFAULT_MAX_PIXELS = 4 * 1024 * 1024
DIMENSION_MULTIPLE = 16
MIN_DIMENSION = 64

# An /edit request carries a reference image inline, so the body is large but
# bounded. Read no more than this, whatever the client claims.
MAX_UPLOAD_BYTES = 32 * 1024 * 1024


def _int_env(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ValueError("%s must be an integer, got %r" % (name, raw)) from exc


def bind() -> str:
    """Address to listen on. Default: loopback only."""
    return os.environ.get("CHOPSHOP_FLUX_BIND") or DEFAULT_BIND


def port() -> int:
    return _int_env("CHOPSHOP_FLUX_PORT", DEFAULT_PORT)


def out_dir() -> str:
    """Where generated images are written, and the only tree /files/ serves from."""
    return os.environ.get("CHOPSHOP_FLUX_OUT") or os.path.join(os.getcwd(), "out")


def max_pixels() -> int | None:
    """An optional GLOBAL ceiling, applied on top of each model's own cap.

    Unset (the default) means each model keeps its own ``max_pixels``. Set it to
    force a lower ceiling on every model at once — a small card that wants to
    refuse the 4 MP klein asks can set one number instead of editing the
    registry. It can only lower a cap, never raise one above the model's own.
    """
    raw = os.environ.get("CHOPSHOP_FLUX_MAX_PIXELS")
    if raw is None or raw.strip() == "":
        return None
    return _int_env("CHOPSHOP_FLUX_MAX_PIXELS", DEFAULT_MAX_PIXELS)


def token() -> str | None:
    """Shared bearer token, enforced only when set.

    The service is meant to be reached over a private network, but "private"
    and "authenticated" are different claims — same shape as the studio's
    RUNNER_TOKEN contract.
    """
    return os.environ.get("CHOPSHOP_FLUX_TOKEN") or None


def offload() -> str:
    """VRAM policy: "cpu" (default) or "none".

    Measured: the 4B weights are 15.97 GB (7.75 GB transformer + 8.05 GB
    Qwen3-4B text encoder + 0.17 GB VAE) against a card torch reports as
    15.92 GiB = 17.10 GB. Resident, the 4 denoise steps complete with 15.01 GiB
    allocated and the VAE decode then has 174 MiB left. CPU offload pages each
    stage in and out instead. "none" is there to measure the difference against
    a card that can afford it, not because it is the good default here.
    """
    value = (os.environ.get("CHOPSHOP_FLUX_OFFLOAD") or "cpu").strip().lower()
    if value not in ("cpu", "none"):
        raise ValueError("CHOPSHOP_FLUX_OFFLOAD must be 'cpu' or 'none', got %r"
                         % value)
    return value


def vae_tiling() -> bool:
    """Whether to decode the VAE in tiles. OFF by default.

    Kept for large decodes, not because it is currently needed: the memory
    failure that prompted it was in *resident* mode, and CPU offload removes it,
    because the decode is then the only thing on the card. It is off until
    something measured says otherwise — an unverified mitigation left on is just
    a second variable.

    Note the switch lives on the VAE (``pipe.vae.enable_tiling()``), not on the
    pipeline: Flux2KleinPipeline has no ``enable_vae_tiling()``, so the obvious
    call raises AttributeError and tiling silently never happens.
    """
    raw = (os.environ.get("CHOPSHOP_FLUX_VAE_TILING") or "").strip().lower()
    return raw in ("1", "true", "yes", "on")


def idle_exit_enabled() -> bool:
    """Whether an idle unload that did NOT return the memory should end the
    process (default false, i.e. off).

    MEASURED, and the whole reason this knob exists: on this deployment
    ``unload()`` frees the tensors but the resident set does not follow — after a
    successful unload the process still held **16.2 GB of ANONYMOUS memory**
    (``RssAnon``, not reclaimable page cache). So ``CHOPSHOP_FLUX_IDLE_UNLOAD``
    released the weights while the box stayed short by the weights' worth of RAM,
    and on a box with NO SWAP that is how a desktop dies while ``free`` still
    reports memory "available".

    Only ending the process returns that memory. With this on, the idle thread
    MEASURES the resident set after unloading and exits only if the memory is
    genuinely still held — so a future torch/libc that does return the pages
    leaves the service running rather than restarting it for nothing. The exit is
    a failure code, so a unit with the ordinary ``Restart=on-failure`` brings the
    service back without any policy change.

    Off by default because it changes the service's lifecycle and is only correct
    where the process's RAM is contended for; a generic deployment that expects a
    long-lived warm process should leave it off.
    """
    raw = (os.environ.get("CHOPSHOP_FLUX_IDLE_EXIT") or "").strip().lower()
    return raw in ("1", "true", "yes", "on")


def idle_unload_seconds() -> int:
    return _int_env("CHOPSHOP_FLUX_IDLE_UNLOAD", 0)


def ack_noncommercial() -> bool:
    """Whether the operator has acknowledged loading a non-commercial model.

    FLUX.2 [klein] 4B is Apache 2.0. `sdxl-turbo` is Stability AI's
    non-commercial research licence: local, non-commercial use only, and
    commercial use requires a licence from the licensor. Rather than trust that
    everyone remembers, loading a non-commercial model requires this to be set
    explicitly, so a commercial deployment cannot happen by accident.
    """
    raw = (os.environ.get("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL") or "").strip().lower()
    return raw in ("1", "true", "yes", "on")


def hf_home() -> str | None:
    """Optional HF cache location, passed through to huggingface_hub."""
    return os.environ.get("HF_HOME") or None


def pipeline_root() -> str | None:
    """A chopshop-svg checkout, for the optional gen2pipe hand-off.

    Only the hand-off needs it. Discovery is deliberate: the service never
    guesses where the pipeline lives, because guessing across a network is how
    you trace the wrong tree.
    """
    return os.environ.get("CHOPSHOP_FLUX_PIPELINE") or None
