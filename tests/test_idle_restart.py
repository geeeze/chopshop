"""The idle-exit restart window, from both ends. (#flux-idle-restart)

The fault this file exists for: the idle path deliberately ends the process when
an unload did not return the memory, systemd restarts it about five seconds
later, and a chain step that posted in that window got a refused TCP connect. A
chained job fails its whole chain on its first failing step, so seven green
steps came back reported as an error over a five-second gap in a service that
was coming back on its own.

Both halves of the fix are here, and the point of testing them TOGETHER is that
either alone leaves a window:

* the service DRAINS before it exits — a 503 carrying ``retry_after`` — so a
  request arriving in the window is told the wait instead of being dropped;
* the client WAITS OUT both that 503 and a refused connect, so the gap after the
  process is really gone is also survivable.

No GPU, no torch, no service: the engine is a stub, the server is a real socket
on an ephemeral port, and the client's network is stubbed at `_urlopen`.
"""

import errno
import io
import json
import socket
import threading
import urllib.error
import urllib.request

import pytest

from chopshop_flux import client as client_module
from chopshop_flux import config, server as server_module
from chopshop_flux.client import FluxClient, FluxError
from chopshop_flux.engine import FluxEngine
from chopshop_flux.server import build_server


class StubEngine:
    """The engine surface the routes use, and nothing else."""

    def __init__(self):
        self.generated = 0

    def generate(self, **kwargs):
        self.generated += 1
        return {"images": [{"name": "image-01.png"}], "seed": 1}

    def status(self):
        return {"loaded_model": None}

    def unload(self):
        pass

    def release(self):
        pass


@pytest.fixture
def live(tmp_path):
    """A running server on an ephemeral port, plus its stub engine."""
    engine = StubEngine()
    server = build_server(engine, bind="127.0.0.1", port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield "http://127.0.0.1:%d" % server.server_address[1], engine, server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def _get(url):
    request = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(request, timeout=5) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8"))


def _post(url, payload=None):
    request = urllib.request.Request(
        url, data=json.dumps(payload or {}).encode("utf-8"),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=5) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8"))


# -- the service side: drain before exiting --------------------------------

def test_a_draining_service_answers_503_with_the_wait_it_asked_for(live, monkeypatch):
    """The whole point of draining rather than just exiting: the request that
    arrives in the window gets an ANSWER, and the answer says how long to wait."""
    base, engine, server = live
    monkeypatch.setenv("CHOPSHOP_FLUX_DRAIN_SECONDS", "5")
    server.drain(reason="the idle unload did not return the memory")

    status, body = _post(base + "/generate", {"prompt": "a phoenix"})
    assert status == 503
    assert body["kind"] == "restarting", "the kind is the client's cue to wait"
    assert body["retry_after"] > 0
    assert body["retry_after"] <= 5.0
    # And nothing was generated: a 503 that still ran the pipeline would be a
    # generation the client never sees the answer to.
    assert engine.generated == 0


def test_the_drain_answers_a_health_probe_too(live, monkeypatch):
    """A health check that gets a bare 503 during a restart is what makes an
    orchestrator decide the service is broken, so /health is inside the drain."""
    base, _engine, server = live
    monkeypatch.setenv("CHOPSHOP_FLUX_DRAIN_SECONDS", "5")
    server.drain()
    status, body = _get(base + "/health")
    assert status == 503
    assert body["kind"] == "restarting"


def test_the_drain_answers_a_download_too(live, monkeypatch):
    base, _engine, server = live
    monkeypatch.setenv("CHOPSHOP_FLUX_DRAIN_SECONDS", "5")
    server.drain()
    status, body = _get(base + "/files/image-01.png")
    assert status == 503
    assert body["kind"] == "restarting"


def test_the_drain_expires_and_the_service_answers_again(live, monkeypatch):
    """A drain that outlived its window would 503 a service that is perfectly
    able to answer — a fault invented by the fix. The deadline is monotonic and
    finite for exactly this reason."""
    base, engine, server = live
    server.drain(seconds=0.05)
    assert _post(base + "/generate", {"prompt": "x"})[0] == 503
    import time
    time.sleep(0.1)
    assert _post(base + "/generate", {"prompt": "x"})[0] == 200
    assert engine.generated == 1


def test_a_server_that_never_drained_answers_normally(live):
    """The default path must be byte-for-byte what it was. A service that never
    uses CHOPSHOP_FLUX_IDLE_EXIT has no reason to 503 anything."""
    base, engine, _server = live
    assert _post(base + "/generate", {"prompt": "a phoenix"})[0] == 200
    assert _get(base + "/health")[0] == 200
    assert engine.generated == 1


def test_a_server_with_no_drain_at_all_still_answers(live):
    """A plain ThreadingHTTPServer has no `drain_status`, and a handler on one
    must answer normally rather than raise on an attribute it never had."""
    base, _engine, server = live
    del server.__class__.drain_status
    try:
        assert _post(base + "/generate", {"prompt": "x"})[0] == 200
    finally:
        # Restored so the fixture's teardown (and any later test) is unaffected.
        server.__class__.drain_status = _original_drain_status


_original_drain_status = server_module.FluxHTTPServer.drain_status


def test_the_drain_window_comes_from_the_environment(monkeypatch):
    monkeypatch.delenv("CHOPSHOP_FLUX_DRAIN_SECONDS", raising=False)
    assert config.drain_seconds() == 5.0, \
        "the drain must cover the same ~5s window the client retry is sized for"
    monkeypatch.setenv("CHOPSHOP_FLUX_DRAIN_SECONDS", "12")
    assert config.drain_seconds() == 12.0
    monkeypatch.setenv("CHOPSHOP_FLUX_DRAIN_SECONDS", "0")
    assert config.drain_seconds() == 0.0


def test_serve_installs_the_drain_hook_on_the_engine(monkeypatch, tmp_path):
    """The engine knows nothing about HTTP, so the hook is installed from the
    one place that has both. Without it the drain would be dead code."""
    from chopshop_flux import server as module

    engine = FluxEngine(out_dir=str(tmp_path))
    assert engine._drain_hook is None, "an engine alone has nothing to drain"
    built = {}

    class FakeServer:
        def __init__(self, address):
            self.server_address = ("127.0.0.1", 1234)

        def drain(self, *args, **kwargs):
            return 5.0

        def serve_forever(self):
            raise KeyboardInterrupt

        def server_close(self):
            built["closed"] = True

    monkeypatch.setattr(module, "build_server",
                        lambda *a, **k: FakeServer(("127.0.0.1", 1234)))
    module.serve(engine=engine)
    assert callable(engine._drain_hook), "serve() must hand the engine the drain"
    assert engine._drain_hook() == 5.0
    assert built.get("closed") is True


def test_the_idle_exit_drains_before_it_exits(monkeypatch, tmp_path):
    """The engine calls the hook, and calls it BEFORE the exit.

    Order is the entire claim: a drain after `os._exit` is a drain that never
    runs, and the fault returns exactly as it was.
    """
    engine = FluxEngine(out_dir=str(tmp_path))
    order = []
    engine._drain_hook = lambda: order.append("drain")
    monkeypatch.setenv("CHOPSHOP_FLUX_IDLE_EXIT", "1")
    monkeypatch.setattr("chopshop_flux.engine.resident_anon_bytes",
                        lambda: 20 * 1024 ** 3)
    monkeypatch.setattr("chopshop_flux.engine.os._exit",
                        lambda code: order.append(("exit", code)))
    engine._exit_if_still_holding()
    assert order == ["drain", ("exit", 1)]


def test_a_failing_drain_does_not_block_the_exit(monkeypatch, tmp_path):
    """The exit is the fix for a box going short on memory; a drain that throws
    must not turn that into a service that stays up holding 16 GB."""
    engine = FluxEngine(out_dir=str(tmp_path))
    exited = []

    def boom():
        raise RuntimeError("socket already closed")

    engine._drain_hook = boom
    monkeypatch.setenv("CHOPSHOP_FLUX_IDLE_EXIT", "1")
    monkeypatch.setattr("chopshop_flux.engine.resident_anon_bytes",
                        lambda: 20 * 1024 ** 3)
    monkeypatch.setattr("chopshop_flux.engine.os._exit",
                        lambda code: exited.append(code))
    engine._exit_if_still_holding()
    assert exited == [1]


def test_an_engine_with_no_hook_still_exits(live, monkeypatch, tmp_path):
    """Every other context — a test engine, an embedding — has no server, so
    there is nothing to drain and the old behaviour must be unchanged."""
    engine = FluxEngine(out_dir=str(tmp_path))
    assert engine._drain_hook is None
    # Nothing to drain, so the exit proceeds exactly as it did before the drain
    # existed: os._exit(1), reached without touching a socket.
    exited = []
    monkeypatch.setenv("CHOPSHOP_FLUX_IDLE_EXIT", "1")
    monkeypatch.setattr("chopshop_flux.engine.resident_anon_bytes",
                        lambda: 20 * 1024 ** 3)
    monkeypatch.setattr("chopshop_flux.engine.os._exit",
                        lambda code: exited.append(code))
    engine._exit_if_still_holding()
    assert exited == [1]


# -- the client side: waiting the window out --------------------------------

def _refused():
    return urllib.error.URLError(
        socket.error(errno.ECONNREFUSED, "Connection refused"))


def _drain_error(retry_after, headers=None):
    body = json.dumps({
        "error": "the service is restarting; no generation was started. "
                 "Come back in %.1fs." % retry_after,
        "kind": "restarting",
        "retry_after": retry_after,
    }).encode()
    return urllib.error.HTTPError("http://x/generate", 503, "unavailable",
                                  headers or {}, io.BytesIO(body))


def _no_sleep(monkeypatch):
    slept = []
    monkeypatch.setattr(client_module.time, "sleep", slept.append)
    return slept


def test_the_client_waits_out_a_drain_503(monkeypatch):
    """The service-side half, from the client's side: a 503 that says
    `restarting` with a `retry_after` is waited out, and the retry gets the
    real answer. Without this the drain would only have turned a refused connect
    into a polite refusal."""
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", "4")
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_BACKOFF", "2")
    slept = _no_sleep(monkeypatch)
    attempts = []

    def draining(req, timeout=None):
        attempts.append(1)
        if len(attempts) < 3:
            raise _drain_error(1.0)
        return _FakeResponse(json.dumps({"images": []}).encode())

    monkeypatch.setattr(client_module.urllib.request, "urlopen", draining)
    FluxClient("http://x").generate("a phoenix")
    assert len(attempts) == 3
    # The wait is the service's `retry_after`, not our own backoff: it knows when
    # it is actually going away. Capped by our backoff step (2s, 4s) so one drain
    # cannot eat the caller's whole timeout budget — here the cap is not what
    # binds, so both waits are the 1.0s the service asked for.
    assert slept == [1.0, 1.0]


def test_a_long_drain_wait_is_capped_by_our_own_backoff(monkeypatch):
    """A service that asks for 300s does not get 300s of the caller's budget —
    the cap is what keeps a slow drain from looking like a hang."""
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", "3")
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_BACKOFF", "2")
    slept = _no_sleep(monkeypatch)
    attempts = []

    def slow_drain(req, timeout=None):
        attempts.append(1)
        if len(attempts) < 3:
            raise _drain_error(300.0)
        return _FakeResponse(json.dumps({"images": []}).encode())

    monkeypatch.setattr(client_module.urllib.request, "urlopen", slow_drain)
    FluxClient("http://x").generate("a phoenix")
    assert slept == [2.0, 4.0]


def test_a_drain_that_never_ends_reports_RESTARTING(monkeypatch):
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", "2")
    _no_sleep(monkeypatch)

    def always_draining(req, timeout=None):
        raise _drain_error(1.0)

    monkeypatch.setattr(client_module.urllib.request, "urlopen", always_draining)
    with pytest.raises(FluxError) as caught:
        FluxClient("http://x").generate("a phoenix")
    assert caught.value.exit_code == 3
    assert caught.value.restarting is True
    assert "RESTARTING" in str(caught.value)


def test_a_gpu_busy_503_is_not_retried(monkeypatch):
    """The guard's 503 is a different event and deliberately not this client's
    to retry: `guard_mode=block` is the operator's decision, and the guard has
    its own wait. Retrying it on this client's schedule would double up on it."""
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", "4")
    _no_sleep(monkeypatch)
    attempts = []

    def busy(req, timeout=None):
        attempts.append(1)
        body = json.dumps({"error": "another process is holding the GPU",
                           "kind": "gpu_busy"}).encode()
        raise urllib.error.HTTPError("http://x/generate", 503, "busy", {},
                                     io.BytesIO(body))

    monkeypatch.setattr(client_module.urllib.request, "urlopen", busy)
    with pytest.raises(FluxError) as caught:
        FluxClient("http://x").generate("a phoenix")
    assert len(attempts) == 1
    assert caught.value.restarting is False
    assert caught.value.exit_code == 5, "a 5xx is still generation-failed"


def test_a_drain_503_without_a_retry_after_is_not_a_drain(monkeypatch):
    """`kind: restarting` with no usable `retry_after` is a malformed drain, and
    guessing a wait for it would be inventing a number. Treated as an ordinary
    error, which is the safe direction."""
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", "4")
    _no_sleep(monkeypatch)
    attempts = []

    def malformed(req, timeout=None):
        attempts.append(1)
        body = json.dumps({"error": "restarting", "kind": "restarting"}).encode()
        raise urllib.error.HTTPError("http://x/generate", 503, "x", {},
                                     io.BytesIO(body))

    monkeypatch.setattr(client_module.urllib.request, "urlopen", malformed)
    with pytest.raises(FluxError):
        FluxClient("http://x").generate("a phoenix")
    assert len(attempts) == 1


def test_the_service_error_message_still_surfaces_after_a_drain(monkeypatch):
    """The drain check reads the error body, so the body must survive it — a
    stream can only be read once, and a 400 that turned into a bare
    'HTTP 400' would be a real regression in what a caller is told."""
    _no_sleep(monkeypatch)
    body = json.dumps({"error": "width must be a multiple of 16, got 1000",
                       "kind": "bad_request"}).encode()

    def bad(req, timeout=None):
        raise urllib.error.HTTPError("http://x/generate", 400, "bad", {},
                                     io.BytesIO(body))

    monkeypatch.setattr(client_module.urllib.request, "urlopen", bad)
    with pytest.raises(FluxError) as caught:
        FluxClient("http://x").generate("x", width=1000)
    assert "multiple of 16" in str(caught.value)
    assert caught.value.exit_code == 2


def test_a_non_json_error_body_is_still_an_error(monkeypatch):
    """A proxy's HTML 502 is not JSON. It must not crash the client, and it must
    not be read as a drain."""
    _no_sleep(monkeypatch)

    def html(req, timeout=None):
        raise urllib.error.HTTPError("http://x/generate", 502, "bad gateway", {},
                                     io.BytesIO(b"<html>502</html>"))

    monkeypatch.setattr(client_module.urllib.request, "urlopen", html)
    with pytest.raises(FluxError) as caught:
        FluxClient("http://x").generate("x")
    assert caught.value.exit_code == 5
    assert caught.value.restarting is False


def test_the_two_halves_are_sized_against_the_same_window(monkeypatch):
    """The drain and the retry cover different moments of the same gap: the
    drain covers "up, deciding to go", the retry covers "gone, coming back".
    So the retry's total sleep must exceed the drain's window, or a client could
    exhaust its budget inside the drain and never reach the part that matters."""
    monkeypatch.delenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", raising=False)
    monkeypatch.delenv("CHOPSHOP_FLUX_RECONNECT_BACKOFF", raising=False)
    monkeypatch.delenv("CHOPSHOP_FLUX_DRAIN_SECONDS", raising=False)
    total = sum(config.reconnect_backoff() * n
                for n in range(1, config.reconnect_attempts()))
    assert total > config.drain_seconds(), (
        "the retry budget (%.1fs) must outlast the drain (%.1fs)"
        % (total, config.drain_seconds()))


class _FakeResponse:
    def __init__(self, body=b"{}"):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False
