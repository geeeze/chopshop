"""The GPU-contention guard: do not start a load onto an occupied card.

Measured on the dev box (Radeon RX 9070 XT, torch reports 17.10 GB): with LM
Studio's local server resident, `llama-server` held **16.21 GB** of VRAM, leaving
~0.8 GB free, while this service's klein-4b wants ~5 GB of headroom for a single
`offload=cpu` stage. Two processes that each want the whole card do not share it
— one of them gets an `OutOfMemoryError`, and on ROCm the loser is not
necessarily the process that asked second.

WHAT LM STUDIO WILL AND WILL NOT TELL YOU (LM Studio 0.4.24, measured):

* `GET /api/v0/models` reports a per-model ``state``: ``loaded`` /
  ``not-loaded`` (and ``loading``). That answers *is LM Studio holding the card*,
  and it is what this guard uses.
* It does **NOT** report activity. Sampled every 2 s across an active
  generation, the loaded model stayed ``state: "loaded"`` and the endpoint kept
  answering in ~1 ms. There is no queue-depth or busy field anywhere in the REST
  surface — ``/api/v0/stats``, ``/api/v0/queue``, ``/metrics`` are 404 — so
  **"is LM Studio queuing" is not answerable over HTTP on this version.**
* The one place the busy state does appear is the CLI: `lms ps` prints STATUS
  ``IDLE`` -> ``GENERATING`` at the same moment the REST API still says
  ``loaded``. Shelling out to a host-specific binary is not something this repo
  does, so the guard does not use it; free VRAM is the honest substitute.
* Therefore the load-bearing test is **free VRAM**, which is
  implementation-agnostic: it catches LM Studio, ollama, another generation of
  this service, or anything else on the card. LM Studio's loaded list is used to
  NAME the holder in the message, never as the gate itself.
"""

from __future__ import annotations

import json
import time
import urllib.request
from dataclasses import dataclass

# Modes, weakest first.
#
# "off"   — a deployment whose card is dedicated to this service. Off, not
#           "somehow safer": every check here costs a VRAM read, and on a
#           dedicated card it can only ever say the card is free.
# "warn"  — the default. Record what the guard found and generate anyway: a
#           box with a small model resident can still fit a load, and a
#           contentious-by-default service that refuses would be worse than
#           one that is merely loud.
# "wait"  — hold the request until the card clears, up to a budget, then refuse.
#           For a transient holder (a generation that is about to finish).
# "block" — refuse immediately and let the caller retry.
OFF = "off"
WARN = "warn"
WAIT = "wait"
BLOCK = "block"
MODES = (OFF, WARN, WAIT, BLOCK)


class GpuContention(Exception):
    """The card is occupied and this service is configured not to share it."""

    def __init__(self, message: str, exit_code: int = 5):
        super().__init__(message)
        self.exit_code = exit_code


@dataclass(frozen=True)
class LmStudio:
    """What LM Studio's local server says, when it is configured and up."""

    url: str
    reachable: bool
    loaded: tuple = ()
    error: str | None = None

    @property
    def holding(self) -> bool:
        return bool(self.loaded)

    def as_dict(self) -> dict:
        return {"url": self.url, "reachable": self.reachable,
                "loaded": list(self.loaded), "error": self.error}


def _get_json(url: str, timeout: float, opener=None, token: str | None = None):
    """A GET that returns parsed JSON. ``opener`` is the test seam.

    ``token`` becomes a Bearer header, and it is only applied when the caller
    named one: with no token the argument to ``opener`` stays a plain URL
    string, which is both what urllib wants and what every existing test seam
    records. A token-protected LM Studio answers 401 to a bare GET, so without
    this the guard could measure the card but never name what was holding it.
    """
    open_fn = opener or urllib.request.urlopen
    target = url
    if token:
        target = urllib.request.Request(
            url, headers={"Authorization": "Bearer %s" % token})
    with open_fn(target, timeout=timeout) as response:
        return json.loads(response.read())


def probe_lmstudio(url: str | None, timeout: float = 1.0,
                   opener=None, token: str | None = None) -> LmStudio | None:
    """Which models LM Studio has LOADED, or ``None`` when not configured.

    An unreachable server is a normal answer, not an error: LM Studio not
    running means it is not holding the card, and the VRAM test still runs.

    ``token`` is for an LM Studio that requires one (its local server can be
    keyed). Attribution only: the gate is free VRAM and catches every holder,
    with or without a name.
    """
    if not url:
        return None
    base = url.rstrip("/")
    try:
        document = _get_json(base + "/api/v0/models", timeout, opener, token)
    except Exception as exc:  # noqa: BLE001 - an unreachable holder is a fact
        return LmStudio(url=base, reachable=False,
                        error="%s: %s" % (type(exc).__name__, exc))
    models = document.get("data") if isinstance(document, dict) else None
    loaded = tuple(entry.get("id") for entry in (models or ())
                   if isinstance(entry, dict)
                   and entry.get("state") in ("loaded", "loading"))
    return LmStudio(url=base, reachable=True, loaded=loaded)


def contended(free_gb: float | None, required_gb: float) -> bool | None:
    """Is the card too full to load? ``None`` when free VRAM is unreadable.

    ``None`` is deliberately not ``False``: a box where the reading cannot be
    taken (no torch, no ROCm device) has not been shown to be free, and the
    caller reports the difference rather than claiming the card is clear.
    """
    if free_gb is None:
        return None
    return free_gb < required_gb


def wait_for_headroom(read_free_gb, required_gb: float, timeout: float,
                      poll: float, *, sleep=time.sleep,
                      clock=time.monotonic) -> tuple:
    """Poll free VRAM until it clears the threshold or the budget runs out.

    Returns ``(free_gb, waited_seconds)``. A holder that is *generating* frees
    the card when it stops, which is the case this exists for; a holder with a
    model merely RESIDENT does not, and no amount of waiting fixes it (measured:
    ~16 GB held at IDLE by a 262144-context llama-server) — that is why the
    caller refuses after the budget instead of waiting forever.
    """
    started = clock()
    free = read_free_gb()
    if free is None or free >= required_gb:
        return free, 0.0
    while True:
        remaining = timeout - (clock() - started)
        if remaining <= 0:
            return free, round(clock() - started, 2)
        sleep(min(poll, remaining))
        free = read_free_gb()
        if free is not None and free >= required_gb:
            return free, round(clock() - started, 2)


def _holder_clause(lm: LmStudio | None) -> str:
    """Name who is holding the card, and what releases it."""
    if lm is None:
        return ("No holder is configured for attribution "
                "(set CHOPSHOP_FLUX_LMSTUDIO_URL to name one), so check for a "
                "resident model elsewhere: `lms ps`, `ollama ps`, or a second "
                "generation of this service.")
    if not lm.reachable:
        return ("LM Studio is not answering at %s (%s), so it is not the "
                "holder; look for another process on the card."
                % (lm.url, lm.error or "unreachable"))
    if not lm.holding:
        return ("LM Studio at %s has no model loaded, so it is not the holder; "
                "look for another process on the card." % lm.url)
    names = ", ".join(lm.loaded)
    return ("LM Studio is holding it: %s at %s. Its llama-server keeps the card "
            "while a model is resident — generating or idle — so release it "
            "with `lms unload %s` (or lower that model's context length) before "
            "generating here." % (names, lm.url, lm.loaded[0]))


def contention_message(free_gb: float | None, required_gb: float,
                       lm: LmStudio | None, mode: str,
                       waited: float = 0.0) -> str:
    """The refusal/warning text: the numbers, the holder, and the consequence."""
    if free_gb is None:
        head = ("free VRAM could not be read (no torch device view), so this "
                "service cannot tell whether the card is clear")
    else:
        head = ("the GPU has %.2f GB free and this service wants %.2f GB free "
                "before loading (CHOPSHOP_FLUX_GUARD_VRAM_GB)"
                % (free_gb, required_gb))
    if mode == BLOCK:
        tail = " Refusing the load: CHOPSHOP_FLUX_GUARD=block."
    elif mode == WAIT:
        tail = (" Waited %.0fs and it never cleared, so the load is refused: "
                "CHOPSHOP_FLUX_GUARD=wait." % waited)
    else:
        tail = (" Loading anyway: CHOPSHOP_FLUX_GUARD=warn — expect an "
                "OutOfMemoryError, or a slower card than the numbers suggest.")
    return "%s. %s%s" % (head, _holder_clause(lm), tail)
