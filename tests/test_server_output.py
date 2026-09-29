"""The output-side keys over HTTP, with a stub engine that validates for REAL.

Two properties are being pinned, and neither is about the stub:

* every new key crosses the wire (``ink_cap``, ``ink_cap_mode``, ``background``,
  ``hires``, ``seeds``, ``provenance``) and is echoed back, and a bad value is
  the SERVICE's own 400 naming the key — the stub calls the same ``parse_*``
  functions the real engine does, so the refusal is real rather than the stub's
  opinion;
* a request that uses none of them travels as the request it always did, so an
  engine that predates them (a wrapper, a test stub) still works — the same
  allowance ``_modifier_kwargs`` makes for the adapter knobs.
"""

import base64
import json
import os
import threading
import urllib.error
import urllib.request

import pytest

from chopshop_flux.models import ModelError, resolve, validate_size
from chopshop_flux.postprocess import (parse_background, parse_hires,
                                       parse_ink_cap, parse_provenance,
                                       parse_seeds)
from chopshop_flux.server import build_server

PNG = b"\x89PNG\r\n\x1a\nstub-image-bytes"


class OutputStubEngine:
    """A stub whose validation is the real thing, and which records the call."""

    def __init__(self, out_dir):
        self._out_dir = out_dir
        self.loaded = None
        self.calls = []

    @property
    def out_dir(self):
        return self._out_dir

    def status(self):
        return {"loaded_model": self.loaded, "busy": False}

    def unload(self):
        self.loaded = None

    def release(self):
        self.unload()

    def generate(self, *, prompt, model=None, width=1024, height=1024,
                 steps=None, guidance=None, seed=None, images=1, reference=None,
                 negative_prompt=None, strength=None, ink_cap=None,
                 ink_cap_mode=None, background=None, hires=None, seeds=None,
                 provenance=None):
        if not isinstance(prompt, str) or not prompt.strip():
            raise ModelError("prompt must be a non-empty string", exit_code=2)
        spec = resolve(model)
        # The REAL validators, so a bad value is refused by the service's own
        # rules with the service's own message.
        parse_ink_cap(ink_cap, ink_cap_mode)
        background_mode = parse_background(background)
        parse_hires(hires)
        seed_list = parse_seeds(seeds)
        parse_provenance(provenance)
        validate_size(spec, width, height)
        self.loaded = spec.key
        self.calls.append({
            "prompt": prompt, "model": spec.key, "reference": reference,
            "negative_prompt": negative_prompt, "strength": strength,
            "ink_cap": ink_cap, "ink_cap_mode": ink_cap_mode,
            "background": background, "hires": hires, "seeds": seeds,
            "provenance": provenance})

        os.makedirs(self.out_dir, exist_ok=True)
        run_seeds = seed_list if seed_list is not None else [seed or 0]
        images_out = []
        mapping = {}
        for run_seed in run_seeds:
            name = "stub-s%d-01.png" % run_seed
            with open(os.path.join(self.out_dir, name), "wb") as handle:
                handle.write(PNG)
            images_out.append({"name": name, "path": os.path.join(self.out_dir, name),
                               "width": width, "height": height, "bytes": len(PNG),
                               "sha256": "0" * 64, "seed": run_seed,
                               "model": spec.key, "seconds": 0.5})
            mapping.setdefault(str(run_seed), []).append(name)

        body = {"model": spec.key, "prompt": prompt,
                "seed": None if seed_list is not None else (seed or 0),
                "steps": steps or spec.default_steps, "images": images_out,
                "total_seconds": 0.5, "warnings": []}
        if ink_cap is not None:
            body["ink_cap"] = parse_ink_cap(ink_cap, ink_cap_mode)
        if background is not None:
            body["background"] = background_mode
        if hires is not None:
            body["hires"] = parse_hires(hires)
        if seed_list is not None:
            body["seeds"] = seed_list
            body["seed_files"] = mapping
        if provenance:
            body["provenance"] = True
        return body


class LegacyEngine:
    """An engine from BEFORE the output-side keys existed."""

    def __init__(self, out_dir):
        self._out_dir = out_dir
        self.calls = []

    @property
    def out_dir(self):
        return self._out_dir

    def status(self):
        return {"loaded_model": None}

    def unload(self):
        pass

    def generate(self, *, prompt, model=None, width=1024, height=1024,
                 steps=None, guidance=None, seed=None, images=1, reference=None,
                 negative_prompt=None, strength=None):
        # No **kwargs, deliberately: a keyword it never accepted is a TypeError,
        # which the route would turn into a 500.
        self.calls.append({"prompt": prompt})
        return {"model": model or "klein-4b", "images": [], "warnings": []}


def _request(url, route, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url + route, data=data,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def serve(engine):
    server = build_server(engine, bind="127.0.0.1", port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, "http://127.0.0.1:%d" % server.server_address[1], thread


@pytest.fixture
def live(tmp_path):
    engine = OutputStubEngine(str(tmp_path / "out"))
    server, url, thread = serve(engine)
    try:
        yield url, engine
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_every_output_key_crosses_the_wire_and_is_echoed(live):
    url, engine = live
    status, body = _request(url, "/generate", {
        "prompt": "a phoenix emblem", "width": 512, "height": 512,
        "ink_cap": 3, "ink_cap_mode": "quantize", "background": "key",
        "hires": {"scale": 1.5, "strength": 0.3, "steps": 12,
                  "upscaler": "bicubic"},
        "seeds": [5, 6], "provenance": True})
    assert status == 200
    call = engine.calls[-1]
    assert call["ink_cap"] == 3 and call["ink_cap_mode"] == "quantize"
    assert call["background"] == "key"
    assert call["hires"] == {"scale": 1.5, "strength": 0.3, "steps": 12,
                             "upscaler": "bicubic"}
    assert call["seeds"] == [5, 6] and call["provenance"] is True
    # ...and the response echoes what the engine answered with.
    assert body["ink_cap"] == {"max_colors": 3, "mode": "quantize"}
    assert body["background"] == "key"
    assert body["hires"]["scale"] == 1.5
    assert body["seeds"] == [5, 6]
    assert body["seed_files"] == {"5": ["stub-s5-01.png"],
                                  "6": ["stub-s6-01.png"]}
    assert body["provenance"] is True
    assert len(body["images"]) == 2


def test_edit_forwards_the_output_keys_too(live):
    url, engine = live
    payload = {"prompt": "flatten to three inks", "width": 512, "height": 512,
               "image": "data:image/png;base64,"
                        + base64.b64encode(b"reference-bytes").decode(),
               "ink_cap": 3, "background": "white", "provenance": True}
    status, body = _request(url, "/edit", payload)
    assert status == 200
    assert engine.calls[-1]["ink_cap"] == 3
    assert engine.calls[-1]["background"] == "white"
    assert engine.calls[-1]["provenance"] is True
    assert body["ink_cap"]["max_colors"] == 3


@pytest.mark.parametrize("payload,expected", [
    ({"ink_cap": 1}, "ink_cap"),
    ({"ink_cap": "three"}, "ink_cap"),
    ({"ink_cap": 3, "ink_cap_mode": "kmeans"}, "ink_cap_mode"),
    ({"ink_cap_mode": "quantize"}, "ink_cap_mode"),
    ({"ink_cap": 3, "ink_cap_mode": "posterize"}, "ink_cap"),
    ({"background": "chroma"}, "background"),
    ({"hires": 2.0}, "hires"),
    ({"hires": {"scale": 1.2}}, "hires.scale"),
    ({"hires": {"strength": 0.6}}, "hires.strength"),
    ({"seeds": "7"}, "seeds"),
    ({"provenance": "yes"}, "provenance"),
])
def test_a_bad_output_key_is_a_400_naming_the_key(live, payload, expected):
    url, engine = live
    body = {"prompt": "x", "width": 512, "height": 512}
    body.update(payload)
    status, answer = _request(url, "/generate", body)
    assert status == 400, answer
    assert answer["kind"] == "bad_request"
    assert expected in answer["error"]
    # Refused before the engine was asked to generate anything.
    assert engine.calls == []


def test_a_request_with_no_output_keys_sends_none_of_them(live):
    url, engine = live
    status, body = _request(url, "/generate",
                            {"prompt": "x", "width": 512, "height": 512})
    assert status == 200
    call = engine.calls[-1]
    for key in ("ink_cap", "ink_cap_mode", "background", "hires", "seeds",
                "provenance"):
        assert call[key] is None, key
    for key in ("ink_cap", "background", "hires", "seeds", "seed_files",
                "provenance"):
        assert key not in body, key


def test_an_engine_that_predates_the_output_keys_still_generates(tmp_path):
    """The keys are only passed when they were sent — the _modifier_kwargs rule.

    A wrapper or a stub whose ``generate`` has never heard of them must keep
    working for a request that does not use them; if the route passed them
    unconditionally this would be a TypeError and a 500.
    """
    engine = LegacyEngine(str(tmp_path / "out"))
    server, url, thread = serve(engine)
    try:
        status, body = _request(url, "/generate",
                                {"prompt": "x", "width": 512, "height": 512})
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    assert status == 200, body
    assert engine.calls and engine.calls[-1]["prompt"] == "x"
