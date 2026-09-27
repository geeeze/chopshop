"""The engine's guards and pure helpers — all reachable with no torch installed.

Every test here runs in an environment where ``torch`` and ``diffusers`` do not
exist, which is the point: the checks that reject a request must fire *before*
the expensive path, not after it.
"""

import importlib.util
import os
import sys

import pytest

from chopshop_flux import engine as engine_module
from chopshop_flux.engine import (FluxEngine, GenerationError, ImageResult,
                                  _sha256, _utc_stamp,
                                  offload_unavailable_message)
from chopshop_flux.models import ModelError


def test_this_environment_has_no_torch_so_these_tests_mean_something():
    """If torch were importable here, the guards below could be passing for the
    wrong reason. This suite is supposed to run on any machine."""
    assert importlib.util.find_spec("torch") is None or os.environ.get("CHOPSHOP_FLUX_TEST_WITH_TORCH")


# -- pure helpers ----------------------------------------------------------

def test_the_offload_message_names_the_interpreter_and_the_alternative():
    """diffusers raises `ImportError: requires accelerate v0.17.0 or higher`,
    which does not say which interpreter or what else you could do."""
    message = offload_unavailable_message(
        ImportError("`enable_model_cpu_offload` requires `accelerate v0.17.0`"),
        "/opt/gpu-venv/bin/python")
    assert "accelerate" in message
    assert "/opt/gpu-venv/bin/python" in message
    assert "CHOPSHOP_FLUX_OFFLOAD=none" in message
    assert "/opt/gpu-venv/bin/python -m pip install accelerate" in message


def test_the_timestamp_is_utc_and_filename_safe():
    stamp = _utc_stamp()
    assert stamp.endswith("Z")
    assert ":" not in stamp and " " not in stamp
    assert len(stamp) == len("20060102T150405Z")


def test_sha256_is_the_plain_digest():
    assert _sha256(b"") == ("e3b0c44298fc1c149afbf4c8996fb924"
                            "27ae41e4649b934ca495991b7852b855")


def test_an_image_result_serialises_itself():
    result = ImageResult(name="a.png", path="/out/a.png", width=8, height=8,
                         bytes=3, sha256="abc", seed=7, model="klein-4b",
                         seconds=1.25)
    assert result.as_dict()["name"] == "a.png"
    assert result.as_dict()["seed"] == 7


# -- guards fire before torch is ever imported ----------------------------

def test_an_empty_prompt_is_rejected_without_touching_torch(monkeypatch):
    monkeypatch.setitem(sys.modules, "torch", None)  # any import would explode
    with pytest.raises(ModelError) as caught:
        FluxEngine().generate(prompt="   ")
    assert caught.value.exit_code == 2


def test_a_non_commercial_model_is_refused_before_loading(monkeypatch):
    """The licence gate must hold on the generate path, not just in the view."""
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    with pytest.raises(ModelError) as caught:
        FluxEngine().generate(prompt="a phoenix", model="klein-9b")
    assert "non-commercial" in str(caught.value).lower()
    assert "Black Forest Labs" in str(caught.value)


def test_an_unusable_resolution_is_rejected_before_loading(monkeypatch):
    with pytest.raises(ModelError) as caught:
        FluxEngine().generate(prompt="a phoenix", width=1000, height=512)
    assert "multiple of" in str(caught.value)


def test_a_zero_image_batch_is_rejected():
    with pytest.raises(ModelError):
        FluxEngine().generate(prompt="a phoenix", images=0)


def test_generating_without_a_gpu_says_so_rather_than_dying(monkeypatch):
    """With torch present but no accelerator, the message must name the check."""
    fake = type("FakeTorch", (), {"cuda": type("C", (), {
        "is_available": staticmethod(lambda: False)})()})()
    monkeypatch.setitem(sys.modules, "torch", fake)
    monkeypatch.setitem(sys.modules, "diffusers", type("D", (), {
        "Flux2KleinPipeline": object})())
    with pytest.raises(GenerationError) as caught:
        FluxEngine().generate(prompt="a phoenix", width=512, height=512)
    assert "no accelerator" in str(caught.value)
    assert caught.value.exit_code == 4


def test_no_load_seconds_before_a_load():
    assert FluxEngine().status()["load_seconds"] is None


def test_the_status_reports_the_vram_policy_it_is_using(monkeypatch):
    """'Which mode was it in?' is the first question about a timing, so the
    answer travels with the timings rather than living in someone's shell."""
    monkeypatch.delenv("CHOPSHOP_FLUX_OFFLOAD", raising=False)
    assert FluxEngine().status()["offload"] == "cpu"
    assert FluxEngine(offload="none").status()["offload"] == "none"


def test_load_notes_start_empty_and_are_reported(monkeypatch):
    engine = FluxEngine()
    assert engine.status()["load_notes"] == []


def test_vae_tiling_is_off_until_something_measured_asks_for_it(monkeypatch):
    monkeypatch.delenv("CHOPSHOP_FLUX_VAE_TILING", raising=False)
    assert FluxEngine().status()["vae_tiling"] is False
    monkeypatch.setenv("CHOPSHOP_FLUX_VAE_TILING", "1")
    assert FluxEngine().status()["vae_tiling"] is True

