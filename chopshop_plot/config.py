"""All configuration comes from the environment.

Nothing here names a host, a port or a directory that belongs to one machine.
That is the same rule chopshop-studio states for its runner map — a repo that
hardcodes a machine's topology goes stale the moment the machine moves — and it
is what lets this same code run beside the studio or on a box somewhere else.

Read at CALL time, not at import time, so a test (or a long-lived service) can
change the environment and get the new value without reloading the module.
"""

from __future__ import annotations

import os

SERVICE_NAME = "chopshop-plot"

# Loopback, deliberately. A service that renders SVGs from specs and reads run
# records has no business on every interface by default; chopshop-svg's
# runner.py ships 0.0.0.0 and its own contract doc calls that a footgun.
# Reaching this box from elsewhere is an explicit act: set CHOPSHOP_PLOT_BIND to
# the private address.
DEFAULT_BIND = "127.0.0.1"

# The studio's mock runner is 8790, chopshop-svg's runner is 8791 and
# chopshop-flux's service is 8795, so stay in that range but clear of all three:
# a collision here would look like the wrong service answering.
DEFAULT_PORT = 8796

# A spec is small — a geometry or chart document — but a query body carries run
# records, which are not. Bounded anyway, so a caller cannot make the service
# buffer an unbounded body; the cap is checked against Content-Length, before
# the bytes are read.
MAX_BODY_BYTES = 8 * 1024 * 1024

# The blender operation shells out to a real renderer, which is installed or it
# is not: the binary is a name on PATH (or a path), so a box that keeps Blender
# somewhere unusual does not need the package edited.
BLENDER_BINARY_ENV = "CHOPSHOP_BLENDER_BINARY"
DEFAULT_BLENDER_BINARY = "blender"

# Where the blender operation writes its frames and GLB — and the ONLY tree
# `GET /files/<name>` serves from. The default is a directory inside this repo,
# derived from this file's location rather than written down as an absolute path
# (the host-agnostic rule above), and it is gitignored.
BLENDER_OUT_DIR_ENV = "CHOPSHOP_BLENDER_OUT_DIR"
DEFAULT_BLENDER_OUT_DIR = "blender_out"


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
    return os.environ.get("CHOPSHOP_PLOT_BIND") or DEFAULT_BIND


def port() -> int:
    return _int_env("CHOPSHOP_PLOT_PORT", DEFAULT_PORT)


def token() -> str | None:
    """Shared bearer token, enforced only when set.

    The service is meant to be reached over a private network, but "private" and
    "authenticated" are different claims — the same shape as the studio's
    RUNNER_TOKEN contract and chopshop-flux's CHOPSHOP_FLUX_TOKEN.
    """
    return os.environ.get("CHOPSHOP_PLOT_TOKEN") or None


def blender_binary() -> str:
    """The Blender to run: a name on PATH, or a path. Default: ``blender``."""
    return os.environ.get(BLENDER_BINARY_ENV) or DEFAULT_BLENDER_BINARY


def blender_out_dir() -> str:
    """Where rendered frames and GLBs are written, and all ``/files/`` serves.

    The default is ``blender_out/`` beside this package's repo root, derived from
    this file's own location so no machine path is written down. Read at call
    time like everything else here, so one service can be pointed at a scratch
    directory without a restart.
    """
    configured = os.environ.get(BLENDER_OUT_DIR_ENV)
    if configured:
        return configured
    return os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), DEFAULT_BLENDER_OUT_DIR
    )
