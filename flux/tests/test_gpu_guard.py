"""The GPU-contention guard (#flux-gpu-guard) — no torch, no GPU, no network.

The guard's whole job is to decide something before the expensive path runs, so
these tests are only meaningful if they run where the expensive path cannot: a
fake opener stands in for LM Studio, and the free-VRAM reading is injected. The
one thing borrowed from the real world is the LANDSCAPE — LM Studio 0.4.24's
actual JSON shape, and whether it exposes activity at all — because a guard
written against invented fields would pass here and fail on the box.
"""

import json
import threading
import urllib.error
import urllib.request

import pytest

from chopshop_flux import config, guard
from chopshop_flux.engine import FluxEngine
from chopshop_flux.guard import GpuContention, LmStudio
from chopshop_flux.server import build_server

# The real payload, trimmed to what the guard reads. Captured from LM Studio
# 0.4.24 with one model resident; ``state`` is the only field that says anything
# about the card, and it does NOT change while a generation runs (measured, and
# the reason the gate cannot be "is LM Studio busy").
LMSTUDIO_MODELS = {
    "data": [
        {"id": "prism-ml/bonsai-27b", "object": "model", "type": "vlm",
         "quantization": "Q1_0", "state": "loaded",
         "max_context_length": 262144, "loaded_context_length": 262144},
        {"id": "mimo-ornith-9b", "object": "model", "type": "llm",
         "state": "not-loaded"},
        {"id": "google/gemma-4-e4b", "object": "model", "type": "vlm",
         "state": "loading"},
    ],
    "object": "list",
}


class FakeResponse:
    def __init__(self, payload: bytes):
        self._payload = payload

    def read(self):
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def opener_for(payload, seen=None, error=None):
    """A urlopen stand-in, recording the URLs it was asked for."""
    def open_fn(url, timeout=None):
        if seen is not None:
            seen.append((url, timeout))
        if error is not None:
            raise error
        return FakeResponse(json.dumps(payload).encode())
    return open_fn


# -- what LM Studio will tell us -------------------------------------------

def test_a_loaded_model_is_reported_and_the_url_is_built_from_the_base():
    seen = []
    probe = guard.probe_lmstudio("http://127.0.0.1:1234/", opener=opener_for(
        LMSTUDIO_MODELS, seen))
    assert probe is not None
    assert probe.reachable is True
    assert probe.loaded == ("prism-ml/bonsai-27b", "google/gemma-4-e4b")
    assert probe.holding is True
    # A trailing slash must not become a double slash: an app that 404s on
    # //api/v0/models would look like "no holder" and silently disable the
    # attribution half of the guard.
    assert seen[0][0] == "http://127.0.0.1:1234/api/v0/models"


def test_an_unreachable_server_is_a_normal_answer_not_an_error():
    """LM Studio not running means it is not holding the card. The VRAM test
    still runs, so this must not raise."""
    probe = guard.probe_lmstudio("http://127.0.0.1:1234",
                                 opener=opener_for(None, error=urllib.error.URLError(
                                     "Connection refused")))
    assert probe is not None
    assert probe.reachable is False
    assert probe.loaded == ()
    assert probe.holding is False
    assert probe.error and "URLError" in probe.error


def test_no_configured_url_means_no_probe_at_all():
    """Unset is the default, and it must not become a connection attempt to
    some guessed local port."""
    def explode(url, timeout=None):
        raise AssertionError("probed %s with no URL configured" % url)

    assert guard.probe_lmstudio(None, opener=explode) is None
    assert guard.probe_lmstudio("", opener=explode) is None


def test_a_configured_key_is_sent_as_a_bearer_header():
    """A KEYED LM Studio answers 401 to a bare GET, which used to erase the name.

    MEASURED on a box whose local LM Studio has an API key set: `/health`
    reported `lmstudio.reachable: false` with
    `HTTPError: HTTP Error 401: Unauthorized` while `llama-server` held
    9.10 GiB of a 15.36 GB card. The refusal was still correct — it is a VRAM
    gate — but it could not say WHAT to release, which is the whole point of
    configuring the URL.

    Attribution must not regress the URL into something a request-less opener
    cannot read, so the assertion on `full_url` matters as much as the header.
    """
    seen = []

    def open_fn(request, timeout=None):
        seen.append(request)
        return FakeResponse(json.dumps(LMSTUDIO_MODELS).encode())

    probe = guard.probe_lmstudio("http://127.0.0.1:1234", opener=open_fn,
                                 token="sk-local")
    assert probe is not None
    assert probe.reachable is True, "a keyed probe must not look unreachable"
    assert probe.loaded == ("prism-ml/bonsai-27b", "google/gemma-4-e4b")
    assert probe.holding is True

    request = seen[0]
    assert isinstance(request, urllib.request.Request), \
        "a token has to travel as a Request, not as a URL string"
    assert request.full_url == "http://127.0.0.1:1234/api/v0/models"
    assert request.headers.get("Authorization") == "Bearer sk-local"


def test_no_key_keeps_the_argument_a_plain_url():
    """Compatibility, stated as a test: an unkeyed LM Studio sees byte-identical
    traffic to before this knob existed, and a test seam keeps receiving a str."""
    seen = []
    guard.probe_lmstudio("http://127.0.0.1:1234",
                         opener=opener_for(LMSTUDIO_MODELS, seen))
    assert isinstance(seen[0][0], str)
    for empty in ("", None):
        other = []
        guard.probe_lmstudio("http://127.0.0.1:1234",
                             opener=opener_for(LMSTUDIO_MODELS, other),
                             token=empty)
        assert isinstance(other[0][0], str), \
            "an empty key must not build an Authorization header"


def test_the_key_is_read_from_its_own_variable(monkeypatch):
    monkeypatch.delenv("CHOPSHOP_FLUX_LMSTUDIO_TOKEN", raising=False)
    assert config.guard_lmstudio_token() is None
    monkeypatch.setenv("CHOPSHOP_FLUX_LMSTUDIO_TOKEN", "")
    assert config.guard_lmstudio_token() is None, "empty means unset"
    monkeypatch.setenv("CHOPSHOP_FLUX_LMSTUDIO_TOKEN", "sk-local")
    assert config.guard_lmstudio_token() == "sk-local"


def test_the_gate_passes_the_configured_key_through(tmp_path, monkeypatch):
    """Wired, not merely defined: the gate is the only caller on the load path."""
    engine = make_engine(tmp_path, monkeypatch, mode="warn", free_gb=15.0)
    monkeypatch.setenv("CHOPSHOP_FLUX_LMSTUDIO_TOKEN", "sk-local")
    captured = {}

    def probe(url, timeout=1.0, opener=None, token=None):
        captured["token"] = token
        return LmStudio(url=url, reachable=True, loaded=())

    monkeypatch.setattr(guard, "probe_lmstudio", probe)
    engine._guard_gate()
    assert captured["token"] == "sk-local"


# -- the decision ----------------------------------------------------------

def test_contention_needs_a_reading_and_an_unreadable_card_is_not_a_verdict():
    assert guard.contended(0.8, 5.0) is True
    assert guard.contended(9.9, 5.0) is False
    assert guard.contended(None, 5.0) is None


def test_waiting_stops_the_moment_the_card_clears():
    readings = iter([0.5, 0.5, 7.0])
    now = [0.0]

    free, waited = guard.wait_for_headroom(
        lambda: next(readings), 5.0, 120.0, 5.0,
        sleep=lambda s: now.__setitem__(0, now[0] + s), clock=lambda: now[0])
    assert free == 7.0
    assert waited == 10.0


def test_waiting_gives_up_at_the_budget_rather_than_forever():
    """A model merely RESIDENT never frees the card, so an unbounded wait is a
    hang. The caller turns this into a refusal."""
    now = [0.0]

    free, waited = guard.wait_for_headroom(
        lambda: 0.5, 5.0, 12.0, 5.0,
        sleep=lambda s: now.__setitem__(0, now[0] + s), clock=lambda: now[0])
    assert free == 0.5
    assert waited == 12.0


def test_an_unreadable_reading_does_not_spin_the_waiter():
    free, waited = guard.wait_for_headroom(
        lambda: None, 5.0, 120.0, 5.0,
        sleep=lambda s: pytest.fail("slept on an unreadable reading"),
        clock=lambda: 0.0)
    assert free is None
    assert waited == 0.0


def test_the_message_says_how_much_is_missing_and_how_to_release_the_card():
    lm = LmStudio(url="http://127.0.0.1:1234", reachable=True,
                  loaded=("prism-ml/bonsai-27b",))
    text = guard.contention_message(0.83, 5.0, lm, guard.BLOCK)
    assert "0.83" in text and "5.00" in text
    assert "prism-ml/bonsai-27b" in text
    assert "lms unload prism-ml/bonsai-27b" in text
    assert "block" in text
    # The warn form must not read like a refusal, or a warning in a log is a
    # false alarm for whoever reads it next.
    warn = guard.contention_message(0.83, 5.0, lm, guard.WARN)
    assert "OutOfMemoryError" in warn


def test_an_unreadable_card_says_so_rather_than_claiming_the_card_is_free():
    text = guard.contention_message(None, 5.0, None, guard.WARN)
    assert "could not be read" in text


# -- the engine's gate -----------------------------------------------------

def make_engine(tmp_path, monkeypatch, *, mode, free_gb, loaded=None):
    monkeypatch.setenv("CHOPSHOP_FLUX_GUARD", mode)
    monkeypatch.setenv("CHOPSHOP_FLUX_GUARD_VRAM_GB", "5.0")
    monkeypatch.setenv("CHOPSHOP_FLUX_LMSTUDIO_URL", "http://127.0.0.1:1234")
    engine = FluxEngine(out_dir=str(tmp_path))
    monkeypatch.setattr(engine, "free_vram_gb",
                        lambda: (setattr(engine, "_free_vram_seen", free_gb)
                                 or free_gb))
    monkeypatch.setattr(guard, "probe_lmstudio", lambda url, timeout=1.0,
                        opener=None, token=None: LmStudio(
                            url=url, reachable=True,
                            loaded=tuple(loaded or ())))
    return engine


def test_off_never_probes_and_never_notes(tmp_path, monkeypatch):
    def explode(*a, **k):
        raise AssertionError("probed while the guard was off")

    engine = make_engine(tmp_path, monkeypatch, mode="off", free_gb=0.1)
    monkeypatch.setattr(guard, "probe_lmstudio", explode)
    engine._guard_gate()
    assert engine._guard_last is None
    assert engine._guard_notes == []


def test_warn_records_what_it_found_and_lets_the_load_continue(tmp_path, monkeypatch):
    engine = make_engine(tmp_path, monkeypatch, mode="warn", free_gb=0.83,
                         loaded=("prism-ml/bonsai-27b",))
    engine._guard_gate()
    last = engine._guard_last or {}
    assert engine._guard_notes and "bonsai-27b" in engine._guard_notes[0]
    assert last["action"] == "warned"
    assert last["contended"] is True
    assert last["free_gb"] == 0.83
    assert last["holder"]["loaded"] == ["prism-ml/bonsai-27b"]


def test_block_refuses_before_torch_is_ever_imported(tmp_path, monkeypatch):
    """The refusal has to come before the expensive path — in this environment
    that means before the torch import, which does not exist here."""
    engine = make_engine(tmp_path, monkeypatch, mode="block", free_gb=0.83)
    with pytest.raises(GpuContention) as caught:
        engine.load("klein-4b")
    assert caught.value.exit_code == 5
    assert "0.83" in str(caught.value)


def test_wait_refuses_only_after_the_budget_expires(tmp_path, monkeypatch):
    engine = make_engine(tmp_path, monkeypatch, mode="wait", free_gb=0.5)
    monkeypatch.setattr(guard, "wait_for_headroom",
                        lambda *a, **k: (0.6, 120.0))
    with pytest.raises(GpuContention) as caught:
        engine._guard_gate()
    last = engine._guard_last or {}
    assert last["action"] == "refused"
    assert last["waited_seconds"] == 120.0
    assert "120" in str(caught.value)


def test_wait_proceeds_once_the_card_clears(tmp_path, monkeypatch):
    engine = make_engine(tmp_path, monkeypatch, mode="wait", free_gb=0.5)
    monkeypatch.setattr(guard, "wait_for_headroom", lambda *a, **k: (6.0, 4.0))
    engine._guard_gate()
    last = engine._guard_last or {}
    assert engine._guard_notes == []
    assert last["action"] == "clear"
    assert last["waited_seconds"] == 4.0


def test_an_unreadable_card_cannot_refuse_a_load_even_in_block_mode(tmp_path, monkeypatch):
    """No torch device view = no verdict. Refusing on a reading that could not
    be taken would break a box for a reason the operator cannot see."""
    engine = make_engine(tmp_path, monkeypatch, mode="block", free_gb=None,
                         loaded=("prism-ml/bonsai-27b",))
    engine._guard_gate()
    last = engine._guard_last or {}
    assert last["action"] == "unmeasurable"
    assert last["contended"] is None
    assert "could not be read" in engine._guard_notes[0]


def test_status_reports_the_guard_without_a_gpu(tmp_path, monkeypatch):
    engine = make_engine(tmp_path, monkeypatch, mode="warn", free_gb=None)
    report = engine.status()["gpu_guard"]
    assert report["mode"] == "warn"
    assert report["required_free_gb"] == 5.0
    assert report["lmstudio"]["url"] == "http://127.0.0.1:1234"
    assert report["contended"] is None


def test_status_shows_the_number_the_guard_measured(tmp_path, monkeypatch):
    """Before any load, the device block has no reading (it will not import torch
    to answer). The guard HAS imported it to decide, so its last measurement is
    the live number — without this, /health said "not measured" for the whole of
    a contention wait, which is the one moment it matters."""
    engine = make_engine(tmp_path, monkeypatch, mode="warn", free_gb=0.83,
                         loaded=("prism-ml/bonsai-27b",))
    engine._guard_gate()
    monkeypatch.setattr(engine, "free_vram_gb", lambda: None)
    report = engine.status()["gpu_guard"]
    assert report["measured"] is True
    assert report["free_gb"] == 0.83
    assert report["contended"] is True


def test_a_misconfigured_guard_leaves_health_answerable(tmp_path, monkeypatch):
    """A status probe that can 500 the route is worse than one that reports the
    failure — the route is how an operator finds out. (#flux-gpu-guard)"""
    monkeypatch.setenv("CHOPSHOP_FLUX_GUARD", "sometimes")
    with pytest.raises(ValueError):
        config.guard_mode()
    report = FluxEngine(out_dir=str(tmp_path)).status()["gpu_guard"]
    assert report["mode"] is None
    assert "ValueError" in report["error"]


def test_the_vram_threshold_is_a_number_and_a_bad_one_is_not_silently_ignored(monkeypatch):
    monkeypatch.setenv("CHOPSHOP_FLUX_GUARD_VRAM_GB", "5.0")
    assert config.guard_vram_gb() == 5.0
    monkeypatch.setenv("CHOPSHOP_FLUX_GUARD_VRAM_GB", "lots")
    with pytest.raises(ValueError):
        config.guard_vram_gb()


# -- the HTTP consequence --------------------------------------------------

class ContendedEngine:
    """An engine whose card is occupied and whose guard mode is block."""

    def __init__(self):
        self.out_dir = "."

    def status(self):
        return {"loaded_model": None, "busy": False,
                "gpu_guard": {"mode": "block", "contended": True}}

    def generate(self, **kwargs):
        raise GpuContention("the GPU has 0.83 GB free and this service wants "
                            "5.00 GB free before loading: LM Studio is holding "
                            "it. Refusing the load: CHOPSHOP_FLUX_GUARD=block.")

    def unload(self):
        pass

    def release(self):
        pass


def test_a_contended_card_is_503_gpu_busy_not_400(tmp_path):
    """503, not 400: the request was fine and the card was not. A caller that
    reads 400 retries nothing; one that reads 503 queues."""
    server = build_server(ContendedEngine(), bind="127.0.0.1", port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    import urllib.request
    url = "http://127.0.0.1:%d/generate" % server.server_address[1]
    try:
        request = urllib.request.Request(
            url, data=json.dumps({"prompt": "x"}).encode(),
            headers={"Content-Type": "application/json"})
        with pytest.raises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request, timeout=10)
        assert caught.value.code == 503
        body = json.loads(caught.value.read())
        assert body["kind"] == "gpu_busy"
        assert "0.83" in body["error"]
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


# -- what a poller can see: a hold, and a card never read (#5, #14) ----------

def test_a_guard_hold_is_visible_while_it_is_happening(tmp_path, monkeypatch):
    """`busy` is true for the WHOLE window — generate sets it before load() runs
    the gate — so on its own it cannot tell "generating, be patient" from "held
    by another process, which may never let go". Those want opposite answers
    from whoever is polling (#5)."""
    engine = make_engine(tmp_path, monkeypatch, mode="wait", free_gb=0.5)
    engine._busy = True  # generate() does this before load() reaches the gate
    seen = {}

    def the_card_clears_inside_the_budget(*args, **kwargs):
        report = engine.status()["gpu_guard"]
        seen["waiting"] = report["waiting"]
        seen["busy"] = engine.status()["busy"]
        return (6.0, 4.0)

    monkeypatch.setattr(guard, "wait_for_headroom",
                        the_card_clears_inside_the_budget)
    engine._guard_gate()
    assert seen == {"waiting": True, "busy": True}
    engine._busy = False
    assert engine.status()["gpu_guard"]["waiting"] is False


def test_an_expired_budget_does_not_strand_the_waiting_flag(tmp_path, monkeypatch):
    """The refusal leaves the gate by exception, so `finally` is what clears
    this — without it every later /health claims a request is still held."""
    engine = make_engine(tmp_path, monkeypatch, mode="wait", free_gb=0.5)
    monkeypatch.setattr(guard, "wait_for_headroom", lambda *a, **k: (0.5, 120.0))
    with pytest.raises(GpuContention):
        engine._guard_gate()
    assert engine.status()["gpu_guard"]["waiting"] is False


def test_the_startup_probe_puts_a_reading_in_health_before_any_load(tmp_path, monkeypatch):
    """#14: until the first load, /health said `measured: false` for a card
    that could already be full from another tenant — and a generation submitted
    into that window OOM'd at load instead of being refused `503 gpu_busy`."""
    engine = make_engine(tmp_path, monkeypatch, mode="warn", free_gb=0.83,
                         loaded=("prism-ml/bonsai-27b",))
    assert engine.status()["gpu_guard"]["measured"] is False   # the pre-#14 state
    assert engine.probe_guard() == 0.83
    report = engine.status()["gpu_guard"]
    assert report["measured"] is True
    assert report["free_gb"] == 0.83
    assert report["contended"] is True


def test_a_probed_reading_is_refreshed_instead_of_served_stale(tmp_path, monkeypatch):
    """After the probe the device block still has no reading (nothing is
    loaded), so without a refresh every /health would repeat the number the
    process started with while wearing `measured: true` — a stale reading
    claiming to be live is the same category of lie #5 is about."""
    engine = make_engine(tmp_path, monkeypatch, mode="warn", free_gb=0.83)
    engine.probe_guard()
    assert engine.status()["gpu_guard"]["free_gb"] == 0.83
    monkeypatch.setattr(engine, "free_vram_gb",
                        lambda: (setattr(engine, "_free_vram_seen", 7.5) or 7.5))
    report = engine.status()["gpu_guard"]
    assert report["free_gb"] == 7.5
    assert report["contended"] is False


def test_the_startup_probe_stays_out_of_the_way_when_the_guard_is_off(tmp_path, monkeypatch):
    """`guard=off` means a dedicated card: `contended` is null by definition,
    so importing torch to say so would be a cost with no answer attached."""
    engine = make_engine(tmp_path, monkeypatch, mode="off", free_gb=0.1)
    monkeypatch.setattr(engine, "free_vram_gb",
                        lambda: pytest.fail("read the card with the guard off"))
    assert engine.probe_guard() is None
    assert engine.status()["gpu_guard"]["measured"] is False


def test_a_misconfigured_guard_does_not_take_the_service_down_at_startup(tmp_path, monkeypatch):
    """/health reports `mode: null, error: ...` for a bad guard value; a
    startup that died on the same value would remove the route that explains
    it, taking the service with it."""
    monkeypatch.setenv("CHOPSHOP_FLUX_GUARD", "sometimes")
    engine = FluxEngine(out_dir=str(tmp_path))
    assert engine.probe_guard() is None


def test_serve_measures_the_card_before_the_socket_exists(monkeypatch, tmp_path):
    """#14 has to happen inside serve(), before the first request can arrive:
    a reading taken once the socket is open is one the first /health can miss."""
    from chopshop_flux import server as server_module
    order = []

    class Engine:
        out_dir = str(tmp_path)
        _drain_hook = None

        def probe_guard(self):
            order.append("probe")

        def status(self):
            return {}

    class StopServing(Exception):
        pass

    def stop(self):
        order.append("serve")
        raise StopServing()

    monkeypatch.setattr(server_module.FluxHTTPServer, "serve_forever", stop)
    with pytest.raises(StopServing):
        server_module.serve(engine=Engine(), bind="127.0.0.1", port=0)
    assert order == ["probe", "serve"]


def test_serve_still_serves_an_engine_that_has_no_probe(monkeypatch, tmp_path):
    """hasattr, like the drain hook: a stub written before #14 keeps working,
    and a missing probe is the pre-#14 behaviour rather than an error."""
    from chopshop_flux import server as server_module

    class Engine:
        out_dir = str(tmp_path)
        _drain_hook = None

        def status(self):
            return {}

    class StopServing(Exception):
        pass

    monkeypatch.setattr(server_module.FluxHTTPServer, "serve_forever",
                        lambda self: (_ for _ in ()).throw(StopServing()))
    with pytest.raises(StopServing):
        server_module.serve(engine=Engine(), bind="127.0.0.1", port=0)
