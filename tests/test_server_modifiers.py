"""The modifier and VAE knobs over HTTP, against a stub engine.

The point of these tests is the boundary, not the pipeline: that the body's
``modifiers`` / ``modifier_scales`` / ``vae`` reach the engine, that `/models`
grew two new arrays without disturbing the one that was there, and that a
request which does not mention them still sends exactly the call it always did.
"""

import json
import os
import threading

import pytest

from chopshop_flux.models import ModelError, resolve, validate_size
from chopshop_flux.modifiers import MODIFIERS, VAES
from chopshop_flux.server import build_server


class ModifierStubEngine:
    """A stub with the modifier-bearing signature, recording every call."""

    def __init__(self, out_dir):
        self._out_dir = out_dir
        self.calls = []

    @property
    def out_dir(self):
        return self._out_dir

    def status(self):
        return {"loaded_model": None, "offload": "cpu", "busy": False}

    def unload(self):
        return None

    def generate(self, *, prompt, model=None, width=1024, height=1024,
                 steps=None, guidance=None, seed=None, images=1, reference=None,
                 negative_prompt=None, strength=None, modifiers=None,
                 modifier_scales=None, vae=None):
        if not isinstance(prompt, str) or not prompt.strip():
            raise ModelError("prompt must be a non-empty string", exit_code=2)
        spec = resolve(model)
        validate_size(spec, width, height)
        # Captured before resolution, so a test can assert what the ROUTE sent
        # rather than what the resolver made of it.
        raw = {"modifiers": modifiers, "modifier_scales": modifier_scales,
               "vae": vae}
        # The REAL resolver and gate, the same way this suite's older stub calls
        # the real resolve/validate_size: an unknown modifier key must be a 400
        # through HTTP, and a stub that resolved nothing would make that vacuous.
        from chopshop_flux.engine import resolve_modifiers
        from chopshop_flux.modifiers import check_modifier_usable, resolve_vae

        modifier_specs, weights, _warnings = resolve_modifiers(modifiers,
                                                               modifier_scales)
        vae_spec = resolve_vae(vae)
        if vae_spec is not None:
            check_modifier_usable(vae_spec)
        resolved_modifiers = [entry.key for entry in modifier_specs]
        resolved_vae = vae_spec.key if vae_spec is not None else None
        self.calls.append({
            "raw": raw,
            "model": spec.key, "prompt": prompt, "negative_prompt": negative_prompt,
            "strength": strength, "modifiers": resolved_modifiers,
            "vae": resolved_vae, "modifier_scales": modifier_scales,
            "reference": reference, "weights": weights,
        })
        return {"model": spec.key, "prompt": prompt, "seed": seed or 0,
                "steps": steps or spec.default_steps, "images": [],
                "total_seconds": 0.0, "warnings": [],
                "modifiers": [{"key": mod.key, "scale": weight}
                              for mod, weight in zip(modifier_specs, weights)],
                "vae": resolved_vae, "scheduler": None}


class LegacyStubEngine:
    """A stub whose generate() predates the modifier keywords.

    A request that carries no modifiers must still work against it — that is the
    compatibility rule the server's conditional kwargs exist for.
    """

    def __init__(self):
        self.calls = []

    @property
    def out_dir(self):
        return "/nonexistent"

    def status(self):
        return {"loaded_model": None}

    def unload(self):
        return None

    def generate(self, *, prompt, model=None, width=1024, height=1024,
                 steps=None, guidance=None, seed=None, images=1, reference=None,
                 negative_prompt=None, strength=None):
        self.calls.append({"model": resolve(model).key})
        return {"model": resolve(model).key, "images": [], "warnings": []}


@pytest.fixture
def live(tmp_path):
    engine = ModifierStubEngine(str(tmp_path / "out"))
    server = build_server(engine, bind="127.0.0.1", port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield "http://127.0.0.1:%d" % server.server_address[1], engine
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def call(url, route, payload):
    import urllib.error
    import urllib.request

    data = json.dumps(payload).encode()
    req = urllib.request.Request(url + route, data=data,
                                headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def get(url, route):
    import urllib.error
    import urllib.request

    req = urllib.request.Request(url + route)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


# -- /models gains two arrays, and keeps its old one ----------------------

def test_models_reports_the_modifier_and_vae_registries(live):
    url, _ = live
    status, body = get(url, "/models")
    assert status == 200
    assert len(body["modifiers"]) == len(MODIFIERS)
    assert len(body["vaes"]) == len(VAES)
    assert {entry["kind"] for entry in body["modifiers"]} == {"modifier"}
    assert {entry["kind"] for entry in body["vaes"]} == {"vae"}


def test_models_still_reports_the_models_array_unchanged(live):
    """A new key beside the existing array, not a restructure of it."""
    url, _ = live
    _status, body = get(url, "/models")
    by_key = {entry["key"]: entry for entry in body["models"]}
    assert by_key["klein-4b"]["default"] is True
    assert by_key["klein-4b"]["license"] == "Apache-2.0"
    assert by_key["sdxl-turbo"]["commercial_ok"] is False


def test_a_modifier_entry_carries_its_weight_filename_over_the_wire(live):
    url, _ = live
    _status, body = get(url, "/models")
    by_key = {entry["key"]: entry for entry in body["modifiers"]}
    assert by_key["sdxl-lightning-4step"]["weight_name"] == \
        "sdxl_lightning_4step_lora.safetensors"
    assert by_key["sdxl-lightning-4step"]["scheduler"] == "trailing-euler"


def test_a_vae_entry_carries_its_tiny_flag_over_the_wire(live):
    url, _ = live
    _status, body = get(url, "/models")
    by_key = {entry["key"]: entry for entry in body["vaes"]}
    assert by_key["taesdxl"]["tiny"] is True
    assert by_key["taesdxl"]["targets"] == ["sdxl-1.0", "ssd-1b"]


# -- the request path -----------------------------------------------------

def test_generate_passes_modifiers_and_a_vae_to_the_engine(live):
    url, engine = live
    status, body = call(url, "/generate",
                        {"prompt": "x", "width": 768, "height": 768,
                         "model": "sdxl-1.0", "modifiers": ["pixel-art-xl"],
                         "modifier_scales": {"pixel-art-xl": 0.5},
                         "vae": "taesdxl"})
    assert status == 200
    assert engine.calls[-1]["modifiers"] == ["pixel-art-xl"]
    assert engine.calls[-1]["modifier_scales"] == {"pixel-art-xl": 0.5}
    assert engine.calls[-1]["vae"] == "taesdxl"


def test_edit_passes_modifiers_and_a_vae_to_the_engine(live):
    import base64

    url, engine = live
    payload = "data:image/png;base64," + base64.b64encode(b"ref").decode()
    status, _body = call(url, "/edit",
                         {"prompt": "x", "image": payload, "width": 768,
                          "height": 768, "model": "sdxl-1.0",
                          "modifiers": ["colouring-book"],
                          "vae": "sdxl-vae-fp16-fix"})
    assert status == 200
    assert engine.calls[-1]["modifiers"] == ["colouring-book"]
    assert engine.calls[-1]["vae"] == "sdxl-vae-fp16-fix"
    assert engine.calls[-1]["reference"] == b"ref"


def test_the_modifier_knobs_default_to_absent_when_not_sent(live):
    """A request that does not mention them must not invent them."""
    url, engine = live
    call(url, "/generate", {"prompt": "x", "width": 512, "height": 512})
    assert engine.calls[-1]["raw"]["modifiers"] is None
    assert engine.calls[-1]["raw"]["vae"] is None
    assert engine.calls[-1]["raw"]["modifier_scales"] is None


def test_the_response_echoes_the_scale_that_was_applied(live):
    url, _ = live
    _status, body = call(url, "/generate",
                         {"prompt": "x", "width": 768, "height": 768,
                          "model": "sdxl-1.0", "modifiers": ["pixel-art-xl"],
                          "modifier_scales": {"pixel-art-xl": 0.25}})
    assert body["modifiers"][0]["key"] == "pixel-art-xl"
    assert body["modifiers"][0]["scale"] == 0.25


def test_an_unknown_modifier_comes_back_as_a_400(live):
    url, _ = live
    status, body = call(url, "/generate",
                        {"prompt": "x", "width": 512, "height": 512,
                         "modifiers": ["no-such-lora"]})
    assert status == 400
    assert body["kind"] == "bad_request"


def test_health_is_unchanged(live):
    url, _ = live
    status, body = get(url, "/health")
    assert status == 200
    assert body["ok"] is True
    assert "modifiers" not in body


# -- the compatibility rule ----------------------------------------------

def test_a_request_without_modifiers_still_works_on_an_older_engine(tmp_path):
    """The keywords are only sent when the request carries them, so an engine
    whose generate() predates them is not handed keywords it never accepted."""
    engine = LegacyStubEngine()
    server = build_server(engine, bind="127.0.0.1", port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = "http://127.0.0.1:%d" % server.server_address[1]
        status, _body = call(url, "/generate",
                             {"prompt": "x", "width": 512, "height": 512})
        assert status == 200
        assert engine.calls[-1]["model"] == "klein-4b"
        # ... and a request that DOES carry them fails loudly rather than
        # silently dropping them, which is the honest failure.
        status, _body = call(url, "/generate",
                             {"prompt": "x", "width": 512, "height": 512,
                              "modifiers": ["pixel-art-xl"]})
        assert status == 500
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_importing_the_server_still_does_not_import_torch():
    """The modifier registry must not drag torch in through the back door."""
    import subprocess
    import sys

    code = ("import sys, chopshop_flux.server, chopshop_flux.cli, "
            "chopshop_flux.modifiers, chopshop_flux.examples as e; "
            "print('torch' in sys.modules)")
    out = subprocess.run([sys.executable, "-c", code], capture_output=True,
                         text=True, cwd=os.path.dirname(os.path.dirname(__file__)))
    assert out.returncode == 0, out.stderr
    assert out.stdout.strip() == "False", "torch was imported at import time"
