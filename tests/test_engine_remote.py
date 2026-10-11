"""The novita remote backend engine dispatch: routing, warnings, and refusal.

These tests prove that a remote model routes to _run_remote and NOT to load(),
that a local model still uses the local path, that non-default steps/guidance
produce a warning, and that hires is refused on a remote model.
"""

import pytest

from chopshop_flux.engine import FluxEngine, ImageResult
from chopshop_flux.models import ModelError, resolve


def _fake_result(name="test.png", width=1024, height=1024):
    return ImageResult(
        name=name, path="/tmp/" + name,
        width=width, height=height,
        bytes=100, sha256="abc", seed=1234,
        model="ming-image-0.1-design", seconds=1.0,
    )


@pytest.fixture(autouse=True)
def _ack_noncommercial(monkeypatch):
    """The ming models are non-commercial; set the ack so the licence gate
    does not fire before the remote dispatch under test."""
    monkeypatch.setenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", "1")


# -- remote dispatch -------------------------------------------------------


def test_a_remote_model_routes_to_run_remote_and_does_not_call_load(
        monkeypatch, tmp_path):
    """A remote model must NOT call load() — there is no torch, no diffusers,
    no pipeline to load. The remote client talks HTTP instead."""
    engine = FluxEngine(out_dir=str(tmp_path))
    load_called = []
    remote_called = []

    def fake_load(self, *args, **kwargs):
        load_called.append(True)
        raise AssertionError("load() must not be called for a remote model")

    def fake_run_remote(self, spec, **kwargs):
        remote_called.append(True)
        return [_fake_result()]

    monkeypatch.setattr(FluxEngine, "load", fake_load)
    monkeypatch.setattr(FluxEngine, "_run_remote", fake_run_remote)

    body = engine.generate(prompt="test", model="ming-image-0.1-design")
    assert load_called == []
    assert remote_called == [True]
    assert body["model"] == "ming-image-0.1-design"


def test_a_local_model_still_uses_the_local_path(monkeypatch, tmp_path):
    """A local model must call load() and _run(), NOT _run_remote()."""
    engine = FluxEngine(out_dir=str(tmp_path))
    load_called = []
    run_called = []
    remote_called = []

    def fake_load(self, *args, **kwargs):
        load_called.append(True)
        self._load_seconds = 1.0
        return resolve("klein-4b")

    def fake_run(self, spec, **kwargs):
        run_called.append(True)
        return [_fake_result()]

    def fake_run_remote(self, spec, **kwargs):
        remote_called.append(True)
        raise AssertionError("_run_remote must not be called for a local model")

    monkeypatch.setattr(FluxEngine, "load", fake_load)
    monkeypatch.setattr(FluxEngine, "_run", fake_run)
    monkeypatch.setattr(FluxEngine, "_run_remote", fake_run_remote)

    body = engine.generate(prompt="test", model="klein-4b")
    assert load_called == [True]
    assert run_called == [True]
    assert remote_called == []
    assert body["model"] == "klein-4b"


# -- steps/guidance warnings ------------------------------------------------


def test_non_default_steps_on_a_remote_model_produce_a_warning(
        monkeypatch, tmp_path):
    """The remote API has no step control; a non-default steps value must
    produce a warning so the caller knows it was ignored."""
    engine = FluxEngine(out_dir=str(tmp_path))
    monkeypatch.setattr(FluxEngine, "_run_remote",
                        lambda self, spec, **kw: [_fake_result()])

    body = engine.generate(
        prompt="test", model="ming-image-0.1-design", steps=5)
    warnings = body["warnings"]
    assert any("steps ignored" in w for w in warnings), warnings


def test_non_default_guidance_on_a_remote_model_produces_a_warning(
        monkeypatch, tmp_path):
    """The remote API has no guidance control; a non-default guidance value
    must produce a warning so the caller knows it was ignored."""
    engine = FluxEngine(out_dir=str(tmp_path))
    monkeypatch.setattr(FluxEngine, "_run_remote",
                        lambda self, spec, **kw: [_fake_result()])

    body = engine.generate(
        prompt="test", model="ming-image-0.1-design", guidance=3.0)
    warnings = body["warnings"]
    assert any("guidance ignored" in w for w in warnings), warnings


def test_default_steps_and_guidance_on_a_remote_model_produce_no_warning(
        monkeypatch, tmp_path):
    """When the caller does not override steps/guidance, no warning is
    produced — the defaults are inert placeholders, not a real schedule."""
    engine = FluxEngine(out_dir=str(tmp_path))
    monkeypatch.setattr(FluxEngine, "_run_remote",
                        lambda self, spec, **kw: [_fake_result()])

    body = engine.generate(prompt="test", model="ming-image-0.1-design")
    warnings = body["warnings"]
    assert not any("steps ignored" in w for w in warnings), warnings
    assert not any("guidance ignored" in w for w in warnings), warnings


# -- hires refusal ---------------------------------------------------------


def test_hires_is_refused_on_a_remote_model(monkeypatch, tmp_path):
    """There is no local second pass on a remote model, so hires must be
    refused with a named ModelError."""
    engine = FluxEngine(out_dir=str(tmp_path))
    monkeypatch.setattr(FluxEngine, "_run_remote",
                        lambda self, spec, **kw: [_fake_result()])

    with pytest.raises(ModelError) as caught:
        engine.generate(
            prompt="test", model="ming-image-0.1-design",
            hires={"scale": 2.0})
    assert "hires" in str(caught.value).lower()
    assert "remote" in str(caught.value).lower() or "second pass" in str(caught.value).lower()
