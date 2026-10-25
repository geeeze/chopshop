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

from . import guard

SERVICE_NAME = "chopshop-flux"

# Loopback, deliberately. A service that generates images and streams them back
# has no business on every interface by default; chopshop-svg's runner.py ships
# 0.0.0.0 and its own contract doc calls that a footgun. Reaching this box from
# elsewhere is an explicit act: set CHOPSHOP_FLUX_BIND to the tailnet address.
DEFAULT_BIND = "127.0.0.1"

# chopshop-svg's runner is 8787 (RUNNER_PORT, its own runner.py) and the
# studio's mock runner is 8790, so stay in that range but off both.
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


def _float_env(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        return float(raw)
    except ValueError as exc:
        raise ValueError("%s must be a number, got %r" % (name, raw)) from exc


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


def compute_dtype() -> str:
    """The dtype the pipeline loads in: ``bfloat16`` (default) | ``float16`` | ``float32``.

    WHY THIS IS A KNOB AND NOT A CONSTANT. ``bfloat16`` was hardcoded, and on a
    card with no native bf16 arithmetic that is not a neutral choice — it is a
    slow one that still *works*, so nothing reports a fault:

        MEASURED, 4096x4096 GEMM on a Tesla T4 (sm_75), torch 2.14.1+cu130
            float16    5.55 ms    24.76 TFLOP/s
            bfloat16  54.94 ms     2.50 TFLOP/s      <- 9.90x fp16
            float32   32.42 ms     4.24 TFLOP/s

    bf16 is nearly 10x slower than fp16 there and *slower than fp32*, because
    Turing has no bf16 GEMM and the op is executed by upcasting. A klein-4b
    frame that should cost seconds cost 1050 s. On the card this was written
    for (gfx1201, native bf16) the default is right and nothing changes.

    It is also a CORRECTNESS knob on Turing, not only a speed one: Sana Sprint's
    DC-AE autoencoder raises ``RuntimeError: GET was unable to find an engine to
    execute this computation`` from a plain conv2d in bf16 on sm_75 — cuDNN has
    no engine for that shape. The same model in fp16 generates normally.

    Leave it unset on a card with native bf16; set ``CHOPSHOP_FLUX_DTYPE=float16``
    on Turing (sm_75) and anything older.
    """
    value = (os.environ.get("CHOPSHOP_FLUX_DTYPE") or "bfloat16").strip().lower()
    if value not in ("bfloat16", "float16", "float32"):
        raise ValueError(
            "CHOPSHOP_FLUX_DTYPE must be 'bfloat16', 'float16' or 'float32', "
            "got %r" % value)
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


def guard_mode() -> str:
    """How to treat a GPU another process is holding: off | warn | wait | block.

    Default ``warn``. The card here is shared with LM Studio (and ollama), and
    the arithmetic is unforgiving: a resident 262144-context LM Studio model had
    its ``llama-server`` holding 16.21 GB of 17.10 GB, while one klein-4b
    ``offload=cpu`` stage wants ~5 GB. Both cannot be true at once.

    ``warn`` is the default because a service that refuses by default breaks a
    pipeline on a box that only *looks* full; ``block`` and ``wait`` are for an
    operator who has decided sharing is not acceptable. ``off`` is for a card
    dedicated to this service. See ``guard.py`` for what LM Studio does and does
    not expose — in particular there is no way to ask it whether it is queuing.
    """
    value = (os.environ.get("CHOPSHOP_FLUX_GUARD") or "warn").strip().lower()
    if value not in guard.MODES:
        raise ValueError("CHOPSHOP_FLUX_GUARD must be one of %s, got %r"
                         % ("/".join(guard.MODES), value))
    return value


def guard_vram_gb() -> float:
    """Free VRAM, in decimal GB, required before a load is attempted.

    Default 5.0. Under ``offload=cpu`` the peak is ONE stage, not the whole
    model, so this is not the model's total size: the recorded datapoint is an
    SDXL 4-image batch at 1024px that tried to allocate 4.83 GB with 4.47 GB
    free (logged as an OOM warning, recoverable on HIP). Below that, a
    generation is a coin flip, so 5.0 is the line.
    """
    return _float_env("CHOPSHOP_FLUX_GUARD_VRAM_GB", 5.0)


def guard_wait_seconds() -> float:
    """How long CHOPSHOP_FLUX_GUARD=wait holds a request before refusing.

    Default 120s. A generation in flight frees the card when it ends; a model
    merely RESIDENT does not, which is why this is a budget and not a loop.
    """
    return _float_env("CHOPSHOP_FLUX_GUARD_WAIT", 120.0)


def guard_poll_seconds() -> float:
    """Seconds between VRAM readings while waiting. Default 5."""
    return _float_env("CHOPSHOP_FLUX_GUARD_POLL", 5.0)


def guard_lmstudio_url() -> str | None:
    """LM Studio's local server, for NAMING the holder of the card. Unset by
    default, like every other address in this file.

    This one is only attribution: the gate itself is free VRAM, which catches
    every holder, not just LM Studio. Set it and a refusal can say *what* to
    release instead of only how much memory is missing.
    """
    return os.environ.get("CHOPSHOP_FLUX_LMSTUDIO_URL") or None


def guard_lmstudio_token() -> str | None:
    """The key an LM Studio's local server may demand. Unset by default.

    Attribution only, same as the URL: the gate is free VRAM. But a keyed LM
    Studio answers ``401`` to a bare ``GET /api/v0/models``, so the probe
    recorded ``reachable: false`` and the guard could refuse correctly while
    being unable to say what it was refusing for (MEASURED: a local LM Studio
    with an API key set). Set this and the name comes back.
    """
    return os.environ.get("CHOPSHOP_FLUX_LMSTUDIO_TOKEN") or None


#flux-idle-restart -- how hard a client tries to ride out the service's own
# idle-exit restart. The idle path deliberately ends the process when an unload
# did NOT return the memory (see `idle_exit_enabled`), and systemd brings it
# back ~5s later. A step that posts inside that window gets a refused TCP
# connect, which is not the same event as a generation error and must not be
# reported as one. These two knobs are the fix, and they live here rather than
# in the client so the client stays a two-seam module and this stays with every
# other environment variable.
RECONNECT_ATTEMPTS_DEFAULT = 4
RECONNECT_BACKOFF_DEFAULT = 2.0


def reconnect_attempts() -> int:
    """How many times a request is tried when the connect is REFUSED.

    Default 4: the first try, then three retries at the backoff below, which
    spans ~12s of sleeping — longer than the measured ~5s restart window with
    room to spare. 1 disables the retry, which is what a caller wants when the
    service is known to be down rather than restarting.
    """
    return max(1, _int_env("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS",
                           RECONNECT_ATTEMPTS_DEFAULT))


def reconnect_backoff() -> float:
    """Seconds before the Nth retry, multiplied by N (linear, not exponential).

    Linear rather than exponential because the window is BOUNDED and known: the
    service either comes back within seconds or it is not coming back at all, and
    a 4-attempt exponential schedule would spend most of its budget asleep long
    after that question was settled. Read at call time, so a test or a
    long-lived client can change it.
    """
    return max(0.0, _float_env("CHOPSHOP_FLUX_RECONNECT_BACKOFF",
                               RECONNECT_BACKOFF_DEFAULT))


#flux-idle-restart -- the drain the service performs before that exit. The
# client retry above is the preferred half of the fix; this is the other half,
# and it is here because "drain before exiting" is only correct if the drain
# actually has a length. 0 disables it, which is right for a deployment that
# does not use CHOPSHOP_FLUX_IDLE_EXIT at all: with no exit coming there is
# nothing to drain for, and a 503 on every request would be a fault invented by
# the fix.
DRAIN_SECONDS_DEFAULT = 5.0


def drain_seconds() -> float:
    """How long the service keeps answering 503 after deciding to exit.

    Default 5s, which is the MEASURED systemd restart delay the client retry is
    also sized against — so the two halves agree: the drain covers requests that
    arrive right after the decision, and the retry covers the gap after the
    process is really gone.

    During the window every request gets a 503 with ``retry_after`` set to the
    remaining seconds, so a client is told when to come back instead of being
    left to guess or to retry blindly.
    """
    return max(0.0, _float_env("CHOPSHOP_FLUX_DRAIN_SECONDS",
                               DRAIN_SECONDS_DEFAULT))


def idle_exit_enabled() -> bool:
    """Whether an idle unload that did NOT return the memory should end the
    process (default false, i.e. off).

    MEASURED, and the whole reason this knob exists: on this deployment
    ``unload()`` frees the tensors but the resident set does not follow — after a
    successful unload the process still held **16.2 GB of ANONYMOUS memory**
    (``RssAnon``, not reclaimable page cache). Re-confirmed twice on 2026-10-06
    (klein-4b, offload=cpu, with and without the service's ``MALLOC_*`` env):
    16.22 GB after unload, flat 20 s later, so this record stands and the
    competing "collect takes it to 3.97 GiB" record was the wrong one — the
    table is in ``docs/API.md`` under "giving the memory back". So ``CHOPSHOP_FLUX_IDLE_UNLOAD``
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


# -- the novita remote backend -----------------------------------------------
#
# Two hosted models (ming-image-0.1-design and ming-image-0.1-design-layer)
# are offered as registry entries whose ``backend`` is ``"novita"`` rather
# than ``"local"``.  They need a handful of knobs that are irrelevant to the
# local diffusers entries, so they live here alongside every other env var.

# Vendor default for the hosted endpoint.  A deployment that routes through a
# proxy or a mirror sets CHOPSHOP_FLUX_NOVITA_BASE_URL to its own address.
DEFAULT_NOVITA_BASE_URL = "https://api.novita.ai/openai/v1"

# Generations are the slowest thing the service does: a 1024x1024 ming-image
# can take tens of seconds.  The default is therefore far above the local
# service's 600s, which is sized for a GPU generation rather than a hosted one.
DEFAULT_NOVITA_TIMEOUT = 120.0


def novita_api_key() -> str | None:
    """The API key for the novita endpoint.

    None (the default) means the backend is not configured; the client raises
    RemoteError before the first request rather than sending a 401.
    """
    return os.environ.get("CHOPSHOP_FLUX_NOVITA_API_KEY") or None


def novita_base_url() -> str:
    """Base URL for the novita API, without a trailing slash."""
    explicit = os.environ.get("CHOPSHOP_FLUX_NOVITA_BASE_URL")
    if explicit:
        return explicit.rstrip("/")
    return DEFAULT_NOVITA_BASE_URL


def novita_timeout() -> float:
    """Per-request timeout in seconds for the remote backend."""
    return _float_env("CHOPSHOP_FLUX_NOVITA_TIMEOUT", DEFAULT_NOVITA_TIMEOUT)


def novita_user_agent() -> str:
    """User-Agent sent with every remote request.

    Cloudflare sits in front of api.novita.ai and returns HTTP 403 for
    urllib's default UA (``Python-urllib/3.x``); any non-empty UA works.
    This is a hard requirement, not a preference.
    """
    explicit = os.environ.get("CHOPSHOP_FLUX_NOVITA_USER_AGENT")
    if explicit:
        return explicit
    return "%s/%s" % (SERVICE_NAME, _version())


def _version() -> str:
    from . import __version__
    return __version__
