"""The HTTP contract, exercised over a real socket with a stub engine.

No torch, no GPU, no models: the engine is injected, which is the property that
makes this suite portable. It is also the contract that matters most, because
everything else in the shop talks to this over HTTP.
"""

import json
import os
import socket
import subprocess
import sys
import threading
import urllib.error
import urllib.request

import pytest

from chopshop_flux import config
from chopshop_flux.models import ModelError, resolve, validate_size
from chopshop_flux.server import build_server

PNG = (b"\x89PNG\r\n\x1a\n" + b"stub-image-bytes")
PNG_BYTES = len(PNG)


class StubEngine:
    """Stands in for FluxEngine, with the same surface and no torch.

    It deliberately calls the REAL ``resolve``/``validate_size``/``check_usable``
    so the validation rules are exercised through HTTP rather than around it —
    a stub that validated nothing would make the 400-path tests vacuous.
    """

    def __init__(self, out_dir):
        self._out_dir = out_dir
        self.loaded = None
        self.unloaded = 0
        self.released = 0
        self.references = []
        # Every generate() the server made, so the new knobs can be checked to
        # have crossed the HTTP boundary rather than being assumed to.
        self.calls = []

    @property
    def out_dir(self):
        return self._out_dir

    def status(self):
        return {"loaded_model": self.loaded, "offload": "cpu", "busy": False,
                "device_name": "stub", "vram_total_gb": 17.06}

    def unload(self):
        self.loaded = None
        self.unloaded += 1

    def release(self):
        """Mirrors FluxEngine: ``unload()`` under the engine lock.

        The server route calls THIS, so the stub has to carry it or the route
        tests would be exercising the legacy fallback instead of the real path.
        """
        self.released += 1
        self.unload()

    def generate(self, *, prompt, model=None, width=1024, height=1024,
                 steps=None, guidance=None, seed=None, images=1, reference=None,
                 negative_prompt=None, strength=None):
        if not isinstance(prompt, str) or not prompt.strip():
            raise ModelError("prompt must be a non-empty string", exit_code=2)
        spec = resolve(model)
        validate_size(spec, width, height)
        self.loaded = spec.key
        self.references.append(reference)
        self.calls.append({"prompt": prompt, "model": spec.key,
                           "negative_prompt": negative_prompt,
                           "strength": strength, "reference": reference})
        os.makedirs(self.out_dir, exist_ok=True)
        names = []
        for index in range(1, int(images) + 1):
            name = "stub-s%d-%02d.png" % (seed or 0, index)
            with open(os.path.join(self.out_dir, name), "wb") as handle:
                handle.write(PNG)
            names.append({"name": name, "path": os.path.join(self.out_dir, name),
                          "width": width, "height": height, "bytes": PNG_BYTES,
                          "sha256": "0" * 64, "seed": seed or 0,
                          "model": spec.key, "seconds": 0.5})
        return {"model": spec.key, "prompt": prompt, "seed": seed or 0,
                "steps": steps or spec.default_steps, "images": names,
                "total_seconds": 0.5, "warnings": []}


@pytest.fixture
def live(tmp_path):
    """A running server on an ephemeral port, plus its stub engine."""
    engine = StubEngine(str(tmp_path / "out"))
    server = build_server(engine, bind="127.0.0.1", port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield "http://127.0.0.1:%d" % server.server_address[1], engine
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_an_explicit_port_zero_binds_somewhere_free(tmp_path, monkeypatch):
    """`port or config.port()` made an explicit 0 mean the configured port.

    So the suite tried to bind the default port, and 21 tests errored with
    OSError whenever a real service happened to be running there. A test suite
    must not depend on the developer not having started the thing being tested.
    """
    # Hold a port of our own and *call it* the configured port, so this test does
    # not care what the machine is already doing on the real default.
    blocker = socket.socket()
    blocker.bind(("127.0.0.1", 0))
    blocker.listen(1)
    held = blocker.getsockname()[1]
    monkeypatch.setenv("CHOPSHOP_FLUX_PORT", str(held))
    try:
        server = build_server(StubEngine(str(tmp_path)), bind="127.0.0.1", port=0)
    finally:
        blocker.close()
    assert server.server_address[1] != held
    server.server_close()


def test_the_configured_port_is_still_used_when_none_is_given(tmp_path, monkeypatch):
    """The other side of the same coin: no port argument means the configured one."""
    monkeypatch.setenv("CHOPSHOP_FLUX_PORT", "8899")
    server = build_server(StubEngine(str(tmp_path)), bind="127.0.0.1")
    try:
        assert server.server_address[1] == 8899
    finally:
        server.server_close()


def _request(url, route, data=None, token=None):
    """Return (status, raw_bytes) for one request, never raising on 4xx/5xx."""
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer %s" % token
    req = urllib.request.Request(url + route, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def call(url, route, payload=None, token=None, raw_body=None) -> tuple[int, dict]:
    """A JSON call. Returns (status, parsed body)."""
    data = raw_body if raw_body is not None else (
        json.dumps(payload).encode() if payload is not None else None)
    status, body = _request(url, route, data=data, token=token)
    return status, json.loads(body)


def call_raw(url, route) -> tuple[int, bytes]:
    """A call whose body is expected to be bytes rather than JSON."""
    return _request(url, route)


# -- read routes -----------------------------------------------------------

def test_health_reports_the_service_and_its_engine(live):
    url, _ = live
    status, body = call(url, "/health")
    assert status == 200
    assert body["ok"] is True
    assert body["service"] == "chopshop-flux"
    assert body["engine"]["device_name"] == "stub"


def test_models_lists_licences_so_a_caller_can_see_what_it_may_sell(live):
    url, _ = live
    status, body = call(url, "/models")
    assert status == 200
    by_key = {m["key"]: m for m in body["models"]}
    assert by_key["klein-4b"]["commercial_ok"] is True
    assert by_key["sdxl-turbo"]["commercial_ok"] is False
    assert by_key["klein-4b"]["default"] is True
    # No model is left in the registry that cannot be loaded.
    assert "unloadable" not in body


def test_an_unknown_route_is_a_404_not_a_500(live):
    url, _ = live
    status, body = call(url, "/nope")
    assert status == 404
    assert body["kind"] == "not_found"


# -- generate --------------------------------------------------------------

def test_generate_returns_an_image_record(live):
    url, engine = live
    status, body = call(url, "/generate",
                        {"prompt": "a phoenix emblem", "width": 512,
                         "height": 512, "seed": 7})
    assert status == 200
    assert body["model"] == "klein-4b"
    assert body["seed"] == 7
    assert len(body["images"]) == 1
    assert body["images"][0]["width"] == 512
    assert engine.loaded == "klein-4b"


def test_generate_rejects_a_bad_resolution_as_a_caller_error(live):
    """1000 is not a multiple of 16, so this is a 400, not a 500.

    A bad request and a failed generation are different problems and must not be
    reported as each other.
    """
    url, _ = live
    status, body = call(url, "/generate",
                        {"prompt": "x", "width": 1000, "height": 1024})
    assert status == 400
    assert body["kind"] == "bad_request"
    assert "multiple of 16" in body["error"]


def test_generate_rejects_a_missing_prompt(live):
    url, _ = live
    status, body = call(url, "/generate", {"width": 512, "height": 512})
    assert status == 400
    assert "prompt" in body["error"]


def test_generate_rejects_an_unknown_model(live):
    url, _ = live
    status, body = call(url, "/generate",
                        {"prompt": "x", "width": 512, "height": 512,
                         "model": "klein-40b"})
    assert status == 400
    assert "unknown model" in body["error"]


def test_generate_can_ask_for_several_images(live):
    url, _ = live
    status, body = call(url, "/generate",
                        {"prompt": "x", "width": 512, "height": 512, "images": 3})
    assert status == 200
    assert len(body["images"]) == 3


def test_a_body_that_is_not_json_is_rejected_cleanly(live):
    url, _ = live
    status, body = call(url, "/generate", raw_body=b"{not json")
    assert status == 400
    assert "not valid JSON" in body["error"]


def test_an_oversized_body_is_refused_before_it_is_read(live, monkeypatch):
    """The cap is checked against Content-Length, not after buffering."""
    url, _ = live
    monkeypatch.setattr(config, "MAX_UPLOAD_BYTES", 128)
    status, body = call(url, "/generate", raw_body=b"x" * 512)
    assert status == 413
    assert body["kind"] == "too_large"


# -- edit ------------------------------------------------------------------

def test_edit_decodes_a_data_url_and_passes_the_bytes_through(live):
    url, engine = live
    import base64
    payload = ("data:image/png;base64,"
               + base64.b64encode(b"reference-bytes").decode())
    status, body = call(url, "/edit",
                        {"prompt": "flatten to 6 flat colours", "image": payload,
                         "width": 512, "height": 512, "seed": 3})
    assert status == 200
    assert engine.references[-1] == b"reference-bytes"


def test_edit_without_an_image_is_a_caller_error(live):
    url, _ = live
    status, body = call(url, "/edit", {"prompt": "x"})
    assert status == 400
    assert "image" in body["error"]


def test_edit_rejects_a_non_data_url(live):
    url, _ = live
    status, body = call(url, "/edit", {"prompt": "x", "image": "not-a-url"})
    assert status == 400
    assert "data:" in body["error"]


def test_edit_rejects_invalid_base64(live):
    url, _ = live
    status, body = call(url, "/edit",
                        {"prompt": "x", "image": "data:image/png;base64,!!!!"})
    assert status == 400
    assert "base64" in body["error"]


# -- the negative prompt and img2img strength ------------------------------

def test_generate_passes_a_negative_prompt_and_strength_to_the_engine(live):
    url, engine = live
    status, body = call(url, "/generate",
                        {"prompt": "x", "width": 512, "height": 512,
                         "negative_prompt": "blurry, low contrast",
                         "strength": 0.62})
    assert status == 200
    assert engine.calls[-1]["negative_prompt"] == "blurry, low contrast"
    assert engine.calls[-1]["strength"] == 0.62


def test_edit_passes_a_negative_prompt_and_strength_to_the_engine(live):
    url, engine = live
    import base64
    payload = ("data:image/png;base64,"
               + base64.b64encode(b"reference-bytes").decode())
    status, body = call(url, "/edit",
                        {"prompt": "x", "image": payload, "width": 512,
                         "height": 512, "negative_prompt": "harsh edges",
                         "strength": 0.4})
    assert status == 200
    assert engine.calls[-1]["negative_prompt"] == "harsh edges"
    assert engine.calls[-1]["strength"] == 0.4


def test_the_new_knobs_default_to_absent_when_not_sent(live):
    """A request that does not mention them must not invent them."""
    url, engine = live
    call(url, "/generate", {"prompt": "x", "width": 512, "height": 512})
    assert engine.calls[-1]["negative_prompt"] is None
    assert engine.calls[-1]["strength"] is None


# -- the new models over HTTP ----------------------------------------------

def test_the_sdxl_and_sd_models_are_listed_over_the_api(live):
    url, _ = live
    status, body = call(url, "/models")
    assert status == 200
    by_key = {m["key"]: m for m in body["models"]}
    assert by_key["sdxl-1.0"]["pipeline"] == "StableDiffusionXLPipeline"
    assert by_key["sdxl-1.0"]["commercial_ok"] is True
    assert by_key["sdxl-turbo"]["commercial_ok"] is False
    assert by_key["sd-1.5"]["pipeline"] == "StableDiffusionPipeline"
    assert by_key["sd-1.5"]["max_pixels"] == 1024 * 1024


def test_sdxl_generate_accepts_a_multiple_of_eight_that_klein_would_reject(live):
    """1024x1024 is fine for both; 1000 is not a multiple of 16 but IS a multiple
    of 8, so it must pass validation for SDXL and fail for klein."""
    url, _ = live
    status, body = call(url, "/generate",
                        {"prompt": "x", "width": 1000, "height": 1024,
                         "model": "sdxl-1.0"})
    assert status == 200
    assert body["model"] == "sdxl-1.0"

    status, body = call(url, "/generate",
                        {"prompt": "x", "width": 1000, "height": 1024})
    assert status == 400
    assert "multiple of 16" in body["error"]


# -- files -----------------------------------------------------------------

def test_files_serves_a_generated_image(live):
    url, engine = live
    call(url, "/generate", {"prompt": "x", "width": 512, "height": 512, "seed": 1})
    status, body = call_raw(url, "/files/stub-s1-01.png")
    assert status == 200
    assert body == PNG
    assert len(body) == PNG_BYTES


def test_files_cannot_escape_the_output_directory(live):
    """The name arrives over the network, so containment is checked, not assumed."""
    url, engine = live
    secret = os.path.join(os.path.dirname(engine.out_dir), "secret.txt")
    with open(secret, "w") as handle:
        handle.write("do not serve me")
    for attempt in ("../secret.txt", "..%2fsecret.txt", "/etc/hostname",
                    "....//secret.txt", os.path.abspath(secret)):
        status, _ = call_raw(url, "/files/%s" % attempt)
        assert status == 404, "served %r" % attempt


def test_files_404s_for_a_name_that_does_not_exist(live):
    url, _ = live
    status, body = call(url, "/files/nope.png")
    assert status == 404
    assert body["kind"] == "not_found"


# -- auth ------------------------------------------------------------------

def test_a_configured_token_is_enforced(live, monkeypatch):
    url, _ = live
    monkeypatch.setenv("CHOPSHOP_FLUX_TOKEN", "s3cret")
    status, _ = call(url, "/generate", {"prompt": "x", "width": 512, "height": 512})
    assert status == 401
    status, _ = call(url, "/generate", {"prompt": "x", "width": 512, "height": 512},
                     token="wrong")
    assert status == 401
    status, _ = call(url, "/generate", {"prompt": "x", "width": 512, "height": 512},
                     token="s3cret")
    assert status == 200


def test_health_stays_reachable_without_the_token(live, monkeypatch):
    """A health check that needs the secret cannot be used to decide whether to
    send the secret."""
    url, _ = live
    monkeypatch.setenv("CHOPSHOP_FLUX_TOKEN", "s3cret")
    status, body = call(url, "/health")
    assert status == 200
    assert body["ok"] is True
    assert body["auth_required"] is True


def test_with_no_token_configured_everything_is_open(live, monkeypatch):
    url, _ = live
    monkeypatch.delenv("CHOPSHOP_FLUX_TOKEN", raising=False)
    status, body = call(url, "/generate", {"prompt": "x", "width": 512, "height": 512})
    assert status == 200


# -- unload ----------------------------------------------------------------

def test_unload_releases_the_model(live):
    url, engine = live
    call(url, "/generate", {"prompt": "x", "width": 512, "height": 512})
    assert engine.loaded == "klein-4b"
    status, body = call(url, "/unload", {})
    assert status == 200
    assert body["unloaded"] is True
    assert engine.loaded is None


def test_unload_goes_through_release_so_it_takes_the_engine_lock(live):
    """#flux-unload-locked -- the route used to call unload() OUTSIDE the lock.

    The engine serialises generation on one lock, so an unload arriving while a
    generate was mid-flight dropped the pipeline out from under the running
    _run. The route now goes through release(), which is unload() under that
    lock and therefore waits its turn. (That the WAIT happens is pinned in
    test_engine.py; what is pinned here is that the route asks for it at all.)
    """
    url, engine = live
    status, body = call(url, "/unload", {})
    assert status == 200
    assert body["unloaded"] is True
    assert engine.released == 1, "the route must use the locked path"
    assert engine.unloaded == 1, "which still unloads"


def test_an_engine_without_release_still_unloads(tmp_path):
    """The same allowance _modifier_kwargs makes: a wrapper or an older stub that
    has only unload() must keep working, it just does not get the lock."""
    class LegacyEngine:
        def __init__(self):
            self.unloaded = 0

        @property
        def out_dir(self):
            return str(tmp_path)

        def status(self):
            return {"loaded_model": None}

        def unload(self):
            self.unloaded += 1

    engine = LegacyEngine()
    server = build_server(engine, bind="127.0.0.1", port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = "http://127.0.0.1:%d" % server.server_address[1]
        status, body = call(url, "/unload", {})
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    assert status == 200
    assert body["unloaded"] is True
    assert engine.unloaded == 1


# -- the portability property ---------------------------------------------

def test_importing_the_server_does_not_import_torch():
    """Pins the property the suite depends on.

    If someone adds a module-level `import torch` to the server, this suite
    silently becomes unrunnable on any machine without a GPU stack — which is
    every machine that is not the GPU box. Checked in a subprocess because the
    test process may already have imported it.
    """
    code = ("import sys, chopshop_flux.server, chopshop_flux.cli, "
            "chopshop_flux.client as c; print('torch' in sys.modules)")
    out = subprocess.run([sys.executable, "-c", code], capture_output=True,
                         text=True, cwd=os.path.dirname(os.path.dirname(__file__)))
    assert out.returncode == 0, out.stderr
    assert out.stdout.strip() == "False", "torch was imported at import time"
