"""The HTTP service: our own small JSON API, stdlib only.

Deliberately not SwarmUI's API and deliberately not the studio's runner contract.
Generation is not the same job as trace-and-validate: the runner contract's
``POST /jobs`` means "run the pipeline", and bending it to also mean "make me an
image" would make one contract mean two things. So this service is its own small
surface, and a client that wants a raster goes here and then hands the raster to
the pipeline itself (see ``client.gen2pipe``).

``http.server`` rather than a framework: this is six routes over one process
holding one GPU. The dependency that matters is torch, and adding a web
framework to serve six routes does not buy anything the stdlib lacks — the same
reason chopshop-sui's bridge is stdlib-only.

Import-safe without torch: the engine is injected, and nothing here imports it.
"""

from __future__ import annotations

import json
import os
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import SERVICE_NAME, __version__, config
from .guard import GpuContention
from .models import ModelError, all_as_dict
from .modifiers import all_as_dict as modifiers_as_dict

# Routes that do not require the bearer token even when one is configured:
# a health check that itself needs a secret cannot be used to decide whether to
# send the secret.
PUBLIC_ROUTES = {"/health"}


def _json_bytes(payload: dict) -> bytes:
    return json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")


def _modifier_kwargs(payload: dict) -> dict:
    """The modifier knobs, and only when the request actually carries them.

    A request with no adapters is asking for the call shape that has always
    existed, so the keywords stay out of the call entirely. That keeps this
    route working against an engine whose ``generate()`` predates them — a
    wrapper, or a test stub — instead of handing it keywords it never accepted.
    """
    kwargs = {}
    for key in ("modifiers", "modifier_scales", "vae"):
        if payload.get(key) is not None:
            kwargs[key] = payload[key]
    return kwargs


def _output_kwargs(payload: dict) -> dict:
    """The output-side knobs, and only when the request actually carries them.

    #flux-ink-cap #flux-background #flux-hires #flux-seeds #flux-provenance --
    exactly the rule ``_modifier_kwargs`` follows, for exactly the same reason:
    a request that uses none of these travels as the call it always did, so an
    engine that predates them (a wrapper, a test stub) still works and the
    default path stays byte-for-byte what it was.
    """
    kwargs = {}
    for key in ("ink_cap", "ink_cap_mode", "background", "hires", "seeds",
                "provenance"):
        if payload.get(key) is not None:
            kwargs[key] = payload[key]
    return kwargs


def _release(engine) -> None:
    """Release the loaded model, taking the engine's lock when it has one.

    #flux-unload-locked -- the engine serialises generation on ONE lock, and
    ``/unload`` used to call ``unload()`` bare, i.e. outside it. That is a race:
    an unload arriving while a generate is mid-flight dropped the pipeline out
    from under the running ``_run``. ``release()`` is ``unload()`` under that same
    lock, so an unload now waits its turn like any other request. The getattr
    fallback is the same allowance ``_modifier_kwargs`` makes: an engine that
    predates ``release()`` (a wrapper, a test stub) still unloads.
    """
    release = getattr(engine, "release", None)
    if release is not None:
        return release()
    return engine.unload()


class FluxHandler(BaseHTTPRequestHandler):
    server_version = "%s/%s" % (SERVICE_NAME, __version__)

    # -- plumbing ----------------------------------------------------------

    def log_message(self, format, *args):  # noqa: A002 - the base class's name
        # Silent unless asked: a generation service logging every /health poll
        # buries the one line you actually want.
        if self.server.verbose:
            super().log_message(format, *args)

    @property
    def engine(self):
        return self.server.engine

    def _send(self, status: int, payload: dict) -> None:
        body = _json_bytes(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_bytes(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int, message: str, kind: str = "error") -> None:
        self._send(status, {"error": message, "kind": kind})

    def _authorised(self) -> bool:
        expected = config.token()
        if not expected:
            return True
        if self.path.split("?", 1)[0] in PUBLIC_ROUTES:
            return True
        header = self.headers.get("Authorization") or ""
        return header == "Bearer %s" % expected

    def _read_json(self) -> dict:
        """Read and parse a bounded JSON body."""
        raw_len = self.headers.get("Content-Length")
        try:
            length = int(raw_len or 0)
        except ValueError:
            raise ModelError("invalid Content-Length", exit_code=2)
        if length > config.MAX_UPLOAD_BYTES:
            raise _TooLarge("body is %d bytes, over the %d cap"
                            % (length, config.MAX_UPLOAD_BYTES))
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ModelError("body is not valid JSON: %s" % exc, exit_code=2) from exc
        if not isinstance(payload, dict):
            raise ModelError("body must be a JSON object", exit_code=2)
        return payload

    # -- routes ------------------------------------------------------------

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler's naming
        path = self.path.split("?", 1)[0]
        if not self._authorised():
            return self._error(HTTPStatus.UNAUTHORIZED, "missing or bad bearer token",
                               "unauthorised")
        try:
            if path == "/health":
                return self._send(HTTPStatus.OK, self._health())
            if path == "/models":
                payload = {"models": all_as_dict()}
                # A new key beside the existing array, not a restructure of it:
                # a client that only reads "models" keeps working unchanged.
                payload.update(modifiers_as_dict())
                return self._send(HTTPStatus.OK, payload)
            if path.startswith("/files/"):
                return self._file(path[len("/files/"):])
        except ModelError as exc:
            return self._error(HTTPStatus.BAD_REQUEST, str(exc), "bad_request")
        except Exception as exc:  # noqa: BLE001
            return self._error(HTTPStatus.INTERNAL_SERVER_ERROR,
                               "%s: %s" % (type(exc).__name__, exc))
        return self._error(HTTPStatus.NOT_FOUND, "no route %s" % path, "not_found")

    def do_POST(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if not self._authorised():
            return self._error(HTTPStatus.UNAUTHORIZED, "missing or bad bearer token",
                               "unauthorised")
        try:
            if path == "/generate":
                payload = self._read_json()
                return self._send(HTTPStatus.OK, self.engine.generate(
                    prompt=payload.get("prompt"),
                    model=payload.get("model"),
                    width=payload.get("width", 1024),
                    height=payload.get("height", 1024),
                    steps=payload.get("steps"),
                    guidance=payload.get("guidance"),
                    seed=payload.get("seed"),
                    images=payload.get("images", 1),
                    negative_prompt=payload.get("negative_prompt"),
                    strength=payload.get("strength"),
                    **_modifier_kwargs(payload),
                    **_output_kwargs(payload),
                ))
            if path == "/edit":
                payload = self._read_json()
                return self._send(HTTPStatus.OK, self.engine.generate(
                    prompt=payload.get("prompt"),
                    model=payload.get("model"),
                    width=payload.get("width", 1024),
                    height=payload.get("height", 1024),
                    steps=payload.get("steps"),
                    guidance=payload.get("guidance"),
                    seed=payload.get("seed"),
                    images=payload.get("images", 1),
                    reference=_decode_reference(payload.get("image")),
                    negative_prompt=payload.get("negative_prompt"),
                    strength=payload.get("strength"),
                    **_modifier_kwargs(payload),
                    **_output_kwargs(payload),
                ))
            if path == "/unload":
                _release(self.engine)
                return self._send(HTTPStatus.OK, {"unloaded": True,
                                                  "status": self.engine.status()})
        except _TooLarge as exc:
            return self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, str(exc),
                               "too_large")
        except GpuContention as exc:
            # Not the caller's fault and not a bad request: the card is
            # occupied. 503, so a queueing caller treats it as "try later"
            # instead of "my request was wrong". (#flux-gpu-guard)
            return self._error(HTTPStatus.SERVICE_UNAVAILABLE, str(exc),
                               "gpu_busy")
        except ModelError as exc:
            # A caller error: bad model name, bad size, unreadable reference.
            return self._error(HTTPStatus.BAD_REQUEST, str(exc), "bad_request")
        except Exception as exc:  # noqa: BLE001
            return self._error(HTTPStatus.INTERNAL_SERVER_ERROR,
                               "%s: %s" % (type(exc).__name__, exc))
        return self._error(HTTPStatus.NOT_FOUND, "no route %s" % path, "not_found")

    # -- handlers ----------------------------------------------------------

    def _health(self) -> dict:
        return {
            "ok": True,
            "service": SERVICE_NAME,
            "version": __version__,
            "auth_required": bool(config.token()),
            "engine": self.engine.status(),
        }

    def _file(self, name: str) -> None:
        """Serve a generated image from the output directory, and nowhere else.

        Containment is checked, not assumed: the name arrives from the network,
        so ``..`` and absolute paths must not be able to read the filesystem.
        Only the basename is ever considered, and the resolved path must still
        be inside the output directory.
        """
        safe = os.path.basename(name)
        root = os.path.realpath(self.engine.out_dir)
        target = os.path.realpath(os.path.join(root, safe))
        if safe != name or not target.startswith(root + os.sep) or not os.path.isfile(target):
            return self._error(HTTPStatus.NOT_FOUND, "no such file %s" % name,
                               "not_found")
        with open(target, "rb") as handle:
            body = handle.read()
        ctype = "image/png" if target.endswith(".png") else "application/octet-stream"
        return self._send_bytes(HTTPStatus.OK, body, ctype)


class _TooLarge(Exception):
    """The request body exceeded the configured cap."""


def _decode_image(value) -> bytes:
    """Decode a ``data:image/...;base64,`` URL (the format both this and
    chopshop-sui use for passing a raster in a JSON body)."""
    import base64

    if value is None:
        raise ModelError("edit requires an 'image' field", exit_code=2)
    if not isinstance(value, str):
        raise ModelError("'image' must be a data URL string", exit_code=2)
    if not value.startswith("data:"):
        raise ModelError("'image' must be a data: URL "
                         "(data:image/png;base64,...)", exit_code=2)
    try:
        header, encoded = value.split(",", 1)
    except ValueError as exc:
        raise ModelError("malformed data URL", exit_code=2) from exc
    if "base64" not in header:
        raise ModelError("data URL must be base64 encoded", exit_code=2)
    try:
        return base64.b64decode(encoded, validate=True)
    except Exception as exc:  # noqa: BLE001
        raise ModelError("data URL payload is not valid base64", exit_code=2) from exc


def _decode_reference(value):
    """The ``image`` field in the shape the caller sent it: one blob, or a list.

    An edit may be conditioned on more than one reference — the prompt is what
    says how they relate — so ``image`` accepts a bare data URL (unchanged, and
    the shape every existing caller sends) or a list of them. The list keeps the
    caller's order, because "the first is the pose and the second is the
    palette" is a distinction only the caller can make and the order is the
    whole of it.

    The SHAPE is preserved rather than normalised to a list of one: a
    one-reference edit then travels the identical path it always has, so nothing
    downstream of this function changes behaviour for the common case. The
    engine accepts both and normalises internally.

    The COUNT is not validated here: whether this model may be conditioned on
    several is a property of its checkpoint, and the engine owns that check — so
    a second reference on an img2img family is refused with a sentence that
    names the model rather than a message about JSON shapes.
    """
    if value is None:
        raise ModelError("edit requires an 'image' field", exit_code=2)
    if isinstance(value, str):
        return _decode_image(value)
    if isinstance(value, (list, tuple)):
        if not value:
            raise ModelError("'image' is an empty list: an edit needs at least "
                             "one reference image", exit_code=2)
        return [_decode_image(entry) for entry in value]
    raise ModelError("'image' must be a data URL string or a list of them, got %s"
                     % type(value).__name__, exit_code=2)


class FluxHTTPServer(ThreadingHTTPServer):
    """The engine and verbosity ride on the server, not on a global.

    A subclass rather than attributes stapled onto the base class at runtime:
    the handler reads them on every request, and a missing attribute should be a
    construction-time mistake you can see, not a 500 at request time.
    """

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, engine, verbose=False):
        super().__init__(address, handler)
        self.engine = engine
        self.verbose = verbose


def build_server(engine, bind: str | None = None, port: int | None = None,
                 verbose: bool = False) -> FluxHTTPServer:
    """Create (but do not start) the server. Tests pass a stub engine.

    ``is None`` rather than ``or``: port 0 is a valid and useful request — "bind
    me any free port" — and ``port or config.port()`` silently turned it into the
    configured port, so the test suite collided with a real service running on the
    default port instead of binding somewhere free.
    """
    return FluxHTTPServer((config.bind() if bind is None else bind,
                           config.port() if port is None else port),
                          FluxHandler, engine, verbose)


def serve(engine=None, bind: str | None = None, port: int | None = None,
          verbose: bool = False) -> None:
    """Run the service until interrupted."""
    if engine is None:
        from .engine import FluxEngine
        engine = FluxEngine()
    server = build_server(engine, bind=bind, port=port, verbose=verbose)
    host, actual = server.server_address[:2]
    print("%s: listening on http://%s:%d (auth %s)"
          % (SERVICE_NAME, host, actual,
             "on" if config.token() else "off"))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n%s: stopping" % SERVICE_NAME)
    finally:
        server.server_close()
