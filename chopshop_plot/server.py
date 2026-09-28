"""The HTTP service: our own small JSON API, stdlib only.

The contract (docs/contract.md) says a backend is "a function from these JSON
documents to SVG, so it slots into a shell pipeline ... or a service wrapper
identically". This is that service wrapper — and deliberately NOT the studio's
runner contract: ``POST /jobs`` means "run the pipeline" (prep, trace, gate),
and bending it to also mean "draw me a chart" would make one contract mean two
things. So this is its own small surface over the operations the contract
already defines, and the studio is one client of it.

``http.server`` rather than a framework: this is a handful of routes over one
process that holds no model, no GPU and no state. The dependency that matters
here is that there is NO dependency — the package is stdlib-only by rule — and a
web framework for a handful of routes does not buy anything the stdlib lacks,
the same reason chopshop-flux's service and chopshop-sui's bridge are
stdlib-only.

Import-safe and GPU-free: the engine is injected, and the default engine IS the
operation functions the CLI already calls, so the service and the CLI cannot
drift — one implementation, two entry points.

One route is different in kind and says so: ``POST /blender`` shells out to a
Blender process and answers with PNG frames (and, at several views, a manifest
naming them) rather than a document, and ``GET /files/<name>`` serves what it
wrote from the configured output directory and nowhere else. Nothing here
imports ``bpy``: the renderer is a subprocess, so a machine with no Blender
answers 503 on that one route and every other operation keeps working.
"""

from __future__ import annotations

import json
import os
import re
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import config
from .blender import BlenderUnavailable, manifest, render_blender, validate_blender
from .digest import digest
from .generate import generate
from .log import log
from .metrics import METRICS_VERSION
from .query import QueryError, query
from .spec import SpecError, unwrap_payload
from .tree import tree

SVG_CONTENT_TYPE = "image/svg+xml; charset=utf-8"

# The operations the service exposes, in the order the status page lists them —
# and the engine's method names, because the route, the operation and the method
# are one name. ONE list rather than three that can drift: the route table, the
# engine surface and `GET /health`'s `operations` all read it.
OPERATIONS = ("generate", "digest", "query", "tree", "log", "blender")

_ROUTES = {"/%s" % op for op in OPERATIONS}

# Routes that skip the bearer token even when one is configured: a health check
# that itself needs a secret cannot be used to decide whether to send the
# secret.
PUBLIC_ROUTES = {"/health"}

FILE_ROUTE = "/files/"

# What a file name may look like. A name arrives from the network, so it is
# checked against this BEFORE it is joined to the output directory: no `..` (a
# leading `.` is not allowed either), no `/` or `\`, no percent-encoding, no
# absolute path. Strict on purpose — every file the blender operation writes is
# a slug, an index and an extension, so nothing legitimate is lost.
FILE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class _BadBody(Exception):
    """The request body is not a document the service can read."""


class _TooLarge(Exception):
    """The request body exceeded the configured cap."""


def _json_bytes(payload: dict) -> bytes:
    return json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")


class PlotEngine:
    """The contract's operations, as one injected object.

    A class rather than bare module calls so a test — or a richer backend
    (Makie, ggplot2) implementing the same contract — can stand in with the same
    surface and without touching the server. The default is the reference
    implementation itself. The method names ARE the operation names (see
    ``OPERATIONS``): the route, the operation and the method are one name, so
    the router does not need a table of its own.
    """

    def __init__(self, generate_fn=generate, digest_fn=digest, query_fn=query,
                 tree_fn=tree, log_fn=log, blender_fn=render_blender):
        self._generate = generate_fn
        self._digest = digest_fn
        self._query = query_fn
        self._tree = tree_fn
        self._log = log_fn
        self._blender = blender_fn

    def generate(self, spec):
        return self._generate(spec)

    def digest(self, spec):
        return self._digest(spec)

    def query(self, runs, spec):
        return self._query(runs, spec)

    def tree(self, spec):
        return self._tree(spec)

    def log(self, spec):
        return self._log(spec)

    def blender(self, spec):
        """Render a blender spec and report the artifacts, not the bytes.

        The one operation that produces FILES rather than a document, so it is
        the one whose answer is a manifest: the frames in view order and the GLB
        name (or ``None``), which is exactly what a client needs to fetch them
        from ``GET /files/<name>``. The output directory is read at call time
        (config.py's rule), so the engine's render and the route that serves the
        files cannot point at different places.
        """
        names = self._blender(spec, config.blender_out_dir())
        return manifest(names)

    def status(self) -> dict:
        return {
            "operations": list(OPERATIONS),
            "metrics_version": METRICS_VERSION,
        }


class PlotHandler(BaseHTTPRequestHandler):
    server_version = config.SERVICE_NAME

    # -- plumbing ----------------------------------------------------------

    def log_message(self, format, *args):  # noqa: A002 - the base class's name
        # Silent unless asked: a service logging every /health poll buries the
        # one line you actually want.
        if self.server.verbose:
            super().log_message(format, *args)

    @property
    def engine(self):
        return self.server.engine

    def _send_bytes(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, status: int, payload: dict) -> None:
        self._send_bytes(status, _json_bytes(payload), "application/json; charset=utf-8")

    def _error(self, status: int, message: str, kind: str = "error") -> None:
        self._send_json(status, {"error": message, "kind": kind})

    def _unauthorised(self) -> None:
        self._error(HTTPStatus.UNAUTHORIZED, "missing or bad bearer token", "unauthorised")

    def _authorised(self) -> bool:
        expected = config.token()
        if not expected:
            return True
        if self.path.split("?", 1)[0] in PUBLIC_ROUTES:
            return True
        return (self.headers.get("Authorization") or "") == "Bearer %s" % expected

    def _read_json(self) -> dict:
        """Read and parse a bounded JSON object body."""
        raw_len = self.headers.get("Content-Length")
        try:
            length = int(raw_len or 0)
        except ValueError:
            raise _BadBody("invalid Content-Length") from None
        if length > config.MAX_BODY_BYTES:
            raise _TooLarge("body is %d bytes, over the %d cap"
                            % (length, config.MAX_BODY_BYTES))
        if length == 0:
            raise _BadBody("an empty body is not a spec")
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise _BadBody("body is not valid JSON: %s" % exc) from exc
        if not isinstance(payload, dict):
            raise _BadBody("body must be a JSON object")
        return payload

    # -- routes ------------------------------------------------------------

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler's naming
        path = self.path.split("?", 1)[0]
        if not self._authorised():
            return self._unauthorised()
        if path == "/health":
            return self._send_json(HTTPStatus.OK, self._health())
        if path.startswith(FILE_ROUTE):
            # The rendered files the blender operation reported. One tree only —
            # the configured output directory — and one guard, `_file`, which the
            # operation's own views==1 answer goes through too.
            return self._file(path[len(FILE_ROUTE):])
        return self._error(HTTPStatus.NOT_FOUND, "no route %s" % path, "not_found")

    def do_POST(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if not self._authorised():
            return self._unauthorised()
        try:
            if path in _ROUTES:
                return self._operation(path.lstrip("/"))
        except _TooLarge as exc:
            return self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, str(exc), "too_large")
        except _BadBody as exc:
            return self._error(HTTPStatus.BAD_REQUEST, str(exc), "bad_request")
        except (SpecError, QueryError) as exc:
            # An invalid spec is a CALLER error and must not be reported as a
            # failure to draw: the contract says a backend rejects an invalid
            # spec rather than emitting a wrong SVG, and the CLI exits 3 for the
            # same reason. This is that 3, over HTTP.
            return self._error(HTTPStatus.BAD_REQUEST, str(exc), "invalid_spec")
        except BlenderUnavailable as exc:
            # 503, never 404 and never a 500: the spec was fine and this machine
            # cannot render it right now (no Blender, or the render failed), which
            # is a different problem with a different fix. A caller that cannot
            # tell those apart retries the wrong thing.
            return self._error(HTTPStatus.SERVICE_UNAVAILABLE, str(exc),
                               "blender_unavailable")
        except Exception as exc:  # noqa: BLE001
            return self._error(HTTPStatus.INTERNAL_SERVER_ERROR,
                               "%s: %s" % (type(exc).__name__, exc))
        return self._error(HTTPStatus.NOT_FOUND, "no route %s" % path, "not_found")

    # -- handlers ----------------------------------------------------------

    def _health(self) -> dict:
        return {
            "ok": True,
            "service": config.SERVICE_NAME,
            "auth_required": bool(config.token()),
            "engine": self.engine.status(),
        }

    def _operation(self, op: str) -> None:
        """Run one operation and answer with the SVG it drew.

        Success is the SVG document itself (``image/svg+xml``), which is what a
        caller wants and what the contract defines; every refusal is a JSON
        envelope with the operation's own message, so a caller can branch on the
        content type rather than guess.

        ``blender`` is the one operation whose answer is not a document, so it
        has its own branch and its own two shapes (see ``_blender``).
        """
        payload = self._read_json()
        if op == "query":
            runs = payload.get("runs")
            if runs is None:
                raise _BadBody("query needs a 'runs' field: a run record, or a list of them")
            runs = runs if isinstance(runs, list) else [runs]
            # `runs` is transport, not spec: it is stripped before the envelope
            # rule is applied so a bare chart spec works with it present.
            spec = unwrap_payload({k: v for k, v in payload.items() if k != "runs"}, op)
            svg = self.engine.query(runs, spec)
        elif op == "blender":
            spec = unwrap_payload(payload, op)
            # Validated HERE, not only inside the renderer: the answer's shape
            # depends on the spec (one frame is the image, several are a
            # manifest), and an injected engine must not be able to accept a spec
            # the contract refuses — a stub engine that skipped this would turn
            # invalid_spec into whatever it felt like.
            validate_blender(spec)
            return self._blender(self.engine.blender(spec))
        else:
            spec = unwrap_payload(payload, op)
            # The operation IS the engine's method (see OPERATIONS): every
            # operation but query takes one spec, so the router stays a lookup
            # rather than a branch per operation.
            svg = getattr(self.engine, op)(spec)
        return self._send_bytes(HTTPStatus.OK, svg.encode("utf-8"), SVG_CONTENT_TYPE)

    def _blender(self, rendered: dict) -> None:
        """Answer a blender run: the image for one view, the manifest otherwise.

        One view with no GLB export is a single picture and a caller asked for a
        picture, so it is served as ``image/png`` through the same ``_file`` the
        ``/files/<name>`` route uses. Anything that produced a SECOND artifact —
        several views, or an exported GLB — is a set of names, so the answer is
        the manifest (``frames`` and ``glb``) and the files are fetched from
        ``GET /files/<name>``. The GLB case is the one that must NOT collapse to
        the single frame: the frame bytes cannot carry the GLB's name, and a
        caller that asked for an export needs to learn that name. Both are 200:
        the render happened, and which shape came back is readable from the
        content type.
        """
        frames = list(rendered.get("frames") or [])
        if len(frames) == 1 and not rendered.get("glb"):
            return self._file(frames[0])
        return self._send_json(HTTPStatus.OK,
                               {"frames": frames, "glb": rendered.get("glb")})

    def _file(self, name: str) -> None:
        """Serve one rendered file — from the output directory and nowhere else.

        Containment is checked, not assumed: the name arrives from the network,
        so ``..``, an absolute path and a percent-encoded traversal must all fail
        before anything is joined. The name must be a plain basename that matches
        ``FILE_NAME``, and the resolved path must still be inside the output
        directory — the same double check chopshop-flux's ``/files/`` route uses.
        A name that fails either test is a 404 ``not_found``, so a traversal
        attempt reads exactly like a file that is not there.
        """
        root = os.path.realpath(config.blender_out_dir())
        target = os.path.realpath(os.path.join(root, name))
        if (
            not FILE_NAME.match(name)
            or name != os.path.basename(name)
            or not target.startswith(root + os.sep)
            or not os.path.isfile(target)
        ):
            return self._error(HTTPStatus.NOT_FOUND, "no such file %s" % name, "not_found")
        with open(target, "rb") as handle:
            body = handle.read()
        ctype = "image/png" if target.endswith(".png") else "application/octet-stream"
        return self._send_bytes(HTTPStatus.OK, body, ctype)


class PlotHTTPServer(ThreadingHTTPServer):
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


def build_server(engine=None, bind: str | None = None, port: int | None = None,
                 verbose: bool = False) -> PlotHTTPServer:
    """Create (but do not start) the server. Tests pass a stub engine.

    ``is None`` rather than ``or``: port 0 is a valid and useful request — "bind
    me any free port" — and ``port or config.port()`` would silently turn an
    explicit 0 into the configured port, so the suite would collide with a real
    service running on the default port instead of binding somewhere free.
    """
    if engine is None:
        engine = PlotEngine()
    return PlotHTTPServer((config.bind() if bind is None else bind,
                           config.port() if port is None else port),
                          PlotHandler, engine, verbose)


def serve(engine=None, bind: str | None = None, port: int | None = None,
          verbose: bool = False) -> None:
    """Run the service until interrupted."""
    server = build_server(engine, bind=bind, port=port, verbose=verbose)
    host, actual = server.server_address[:2]
    # flush=True: the banner is how a supervisor (and the serve test) learns the
    # port it actually bound, which is not the port it was asked for when that
    # request was 0.
    print("%s: listening on http://%s:%d (auth %s)"
          % (config.SERVICE_NAME, host, actual,
             "on" if config.token() else "off"), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n%s: stopping" % config.SERVICE_NAME, flush=True)
    finally:
        server.server_close()
