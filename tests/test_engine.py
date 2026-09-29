"""The engine's guards and pure helpers — all reachable with no torch installed.

Every test here runs in an environment where ``torch`` and ``diffusers`` do not
exist, which is the point: the checks that reject a request must fire *before*
the expensive path, not after it.
"""

import importlib.util
import os
import sys
import threading
import types

import pytest

from chopshop_flux import engine as engine_module
from chopshop_flux.engine import (FluxEngine, GenerationError, ImageResult,
                                  _sha256, _utc_stamp,
                                  offload_unavailable_message)
from chopshop_flux.models import ModelError, resolve


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
        FluxEngine().generate(prompt="a phoenix", model="sdxl-turbo")
    assert "non-commercial" in str(caught.value).lower()
    assert "the model's licensor" in str(caught.value)


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


# -- the pipeline class comes from the spec, not a hardcoded import --------

def test_a_pipeline_class_the_installed_diffusers_lacks_names_itself(monkeypatch):
    """load() looks the class up from spec.pipeline, so a family the local
    diffusers does not provide is a model error (exit 4), not an AttributeError
    deep inside from_pretrained."""
    fake_torch = type("FakeTorch", (), {
        "cuda": type("C", (), {"is_available": staticmethod(lambda: True)})()})()
    monkeypatch.setitem(sys.modules, "torch", fake_torch)
    # diffusers offers klein but no SDXL class.
    monkeypatch.setitem(sys.modules, "diffusers",
                        type("D", (), {"Flux2KleinPipeline": object})())
    with pytest.raises(GenerationError) as caught:
        FluxEngine().load("sdxl-1.0")
    assert "StableDiffusionXLPipeline" in str(caught.value)
    assert caught.value.exit_code == 4


# -- the distilled-guidance and negative-prompt warnings -------------------

def _engine_with_stubbed_run(monkeypatch, results=None):
    """An engine whose load()/ _run() are stubbed, so generate()'s request
    handling runs with no torch, no GPU and no pipeline."""
    engine = FluxEngine()
    monkeypatch.setattr(engine, "load", lambda model=None, edit=False: resolve(model))
    monkeypatch.setattr(engine, "_run", lambda spec, **kwargs: results or [])
    return engine


def test_the_distilled_guidance_warning_is_not_klein_specific(monkeypatch):
    """The warning keys off the model's own default guidance, so it is quiet at
    that default and loud when CFG is asked for. sdxl-turbo's default is 0.0."""
    monkeypatch.setenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", "1")
    engine = _engine_with_stubbed_run(monkeypatch)

    quiet = engine.generate(prompt="x", width=512, height=512, model="sdxl-turbo")
    assert not any("guidance_scale" in w for w in quiet["warnings"])

    loud = engine.generate(prompt="x", width=512, height=512,
                           model="sdxl-turbo", guidance=5.0)
    assert any("guidance_scale" in w for w in loud["warnings"])
    assert any("sdxl-turbo" in w for w in loud["warnings"])
    assert any("classifier-free guidance" in w for w in loud["warnings"])


def test_a_negative_prompt_on_klein_is_reported_as_ignored(monkeypatch):
    """Flux2KleinPipeline has no negative_prompt parameter; the service says so
    rather than quietly dropping it."""
    engine = _engine_with_stubbed_run(monkeypatch)
    body = engine.generate(prompt="a phoenix", width=512, height=512,
                           model="klein-4b", negative_prompt="blurry")
    assert any("negative prompt ignored" in w for w in body["warnings"])
    assert any("klein-4b" in w for w in body["warnings"])


def test_a_negative_prompt_on_sdxl_is_not_reported_as_ignored(monkeypatch):
    engine = _engine_with_stubbed_run(monkeypatch)
    body = engine.generate(prompt="a phoenix", width=512, height=512,
                           model="sdxl-1.0", negative_prompt="blurry")
    assert not any("negative prompt ignored" in w for w in body["warnings"])


def test_a_strength_on_klein_is_reported_as_ignored(monkeypatch):
    """The klein branch of _run never passes strength, so the service says so
    rather than silently dropping it — the JSON textarea bypasses the form's
    gating, so this is the only place the operator hears."""
    engine = _engine_with_stubbed_run(monkeypatch)
    body = engine.generate(prompt="a phoenix", width=512, height=512,
                           model="klein-4b", strength=0.5)
    assert any("strength ignored" in w for w in body["warnings"])
    assert any("klein-4b" in w for w in body["warnings"])


def test_a_strength_on_sdxl_is_not_reported_as_ignored(monkeypatch):
    engine = _engine_with_stubbed_run(monkeypatch)
    body = engine.generate(prompt="a phoenix", width=512, height=512,
                           model="sdxl-1.0", strength=0.5)
    assert not any("strength ignored" in w for w in body["warnings"])


def test_generate_echoes_the_negative_prompt_and_strength(monkeypatch):
    """What was requested is reported back, not silently dropped."""
    engine = _engine_with_stubbed_run(monkeypatch)
    body = engine.generate(prompt="x", width=512, height=512, model="sdxl-1.0",
                           negative_prompt="blurry", strength=0.5)
    assert body["negative_prompt"] == "blurry"
    assert body["strength"] == 0.5


# -- _run's call shape differs by family -----------------------------------
#
# No torch and no PIL here, so both are faked. _run is driven directly, which
# is possible because the branch that matters is the kwargs it builds.

class _RecordingPipe:
    """Stands in for a loaded pipeline and records how it was called."""

    def __init__(self, images):
        self.calls = []
        self._images = images

    def __call__(self, **kwargs):
        self.calls.append(kwargs)
        return type("Out", (), {"images": self._images})()


class _FakeImage:
    width = 8
    height = 8

    def save(self, path, format=None):  # noqa: A002 - PIL's own name
        with open(path, "wb") as handle:
            handle.write(b"PNG")


def _install_fake_pil(monkeypatch):
    """_run does ``from PIL import Image``; this environment has no Pillow."""
    class _Opened:
        def convert(self, mode):
            return "CONVERTED:%s" % mode

    module = types.ModuleType("PIL")
    module.Image = type("Image", (), {"open": staticmethod(lambda _fp: _Opened())})
    monkeypatch.setitem(sys.modules, "PIL", module)


def _install_fake_torch(monkeypatch):
    class _Ctx:
        def __enter__(self):
            return None

        def __exit__(self, *exc):
            return False

    class _Generator:
        def manual_seed(self, seed):
            return self

    monkeypatch.setitem(sys.modules, "torch", type("FakeTorch", (), {
        "inference_mode": staticmethod(lambda: _Ctx()),
        "Generator": staticmethod(lambda: _Generator()),
    })())


def _engine_with_a_recording_pipe(monkeypatch, tmp_path):
    _install_fake_pil(monkeypatch)
    _install_fake_torch(monkeypatch)
    engine = FluxEngine(out_dir=str(tmp_path))
    recorder = _RecordingPipe([_FakeImage()])
    engine._pipe = recorder
    engine._torch = sys.modules["torch"]
    return engine, recorder


def test_klein_passes_image_and_never_a_negative_prompt_or_strength(monkeypatch, tmp_path):
    engine, recorder = _engine_with_a_recording_pipe(monkeypatch, tmp_path)
    engine._run(resolve("klein-4b"), prompt="x", width=512, height=512,
                steps=4, guidance=1.0, seed=1, images=1, reference=None,
                negative_prompt="blurry", strength=0.6)
    kwargs = recorder.calls[-1]
    assert "image" in kwargs and kwargs["image"] is None
    assert "negative_prompt" not in kwargs   # klein has no such parameter
    assert "strength" not in kwargs
    assert kwargs["output_type"] == "pil"


def test_sdxl_text_to_image_omits_image_and_strength(monkeypatch, tmp_path):
    engine, recorder = _engine_with_a_recording_pipe(monkeypatch, tmp_path)
    engine._run(resolve("sdxl-1.0"), prompt="x", width=512, height=512,
                steps=30, guidance=5.0, seed=1, images=1, reference=None,
                negative_prompt="blurry", strength=0.6)
    kwargs = recorder.calls[-1]
    assert "image" not in kwargs
    assert "strength" not in kwargs
    assert kwargs["negative_prompt"] == "blurry"


def test_sdxl_edit_passes_image_and_strength(monkeypatch, tmp_path):
    engine, recorder = _engine_with_a_recording_pipe(monkeypatch, tmp_path)
    engine._run(resolve("sdxl-1.0"), prompt="x", width=512, height=512,
                steps=30, guidance=5.0, seed=1, images=1,
                reference=b"not-really-a-png", negative_prompt="blurry",
                strength=0.6)
    kwargs = recorder.calls[-1]
    assert kwargs["image"] == "CONVERTED:RGB"
    assert kwargs["strength"] == 0.6
    assert kwargs["negative_prompt"] == "blurry"


def test_sdxl_edit_without_a_strength_omits_only_the_strength(monkeypatch, tmp_path):
    engine, recorder = _engine_with_a_recording_pipe(monkeypatch, tmp_path)
    engine._run(resolve("sdxl-1.0"), prompt="x", width=512, height=512,
                steps=30, guidance=5.0, seed=1, images=1,
                reference=b"x", negative_prompt=None, strength=None)
    kwargs = recorder.calls[-1]
    assert "image" in kwargs
    assert "strength" not in kwargs
    assert kwargs["negative_prompt"] is None


# -- idle unloading --------------------------------------------------------

def test_pipeline_class_for_selects_the_edit_class_only_for_a_reference():
    from chopshop_flux.engine import pipeline_class_for

    sdxl = resolve("sdxl-1.0")
    assert pipeline_class_for(sdxl, edit=False) == "StableDiffusionXLPipeline"
    assert pipeline_class_for(sdxl, edit=True) == "StableDiffusionXLImg2ImgPipeline"

    sd15 = resolve("sd-1.5")
    assert pipeline_class_for(sd15, edit=True) == "StableDiffusionImg2ImgPipeline"

    # klein is one unified class: edit or not, the same pipeline loads.
    klein = resolve("klein-4b")
    assert pipeline_class_for(klein, edit=False) == "Flux2KleinPipeline"
    assert pipeline_class_for(klein, edit=True) == "Flux2KleinPipeline"


def test_the_idle_unload_thread_is_gated_on_the_config(monkeypatch):
    """The default engine spawns no thread; a positive knob starts exactly one
    daemon thread, and a second start does not stack a second thread."""
    engine = FluxEngine()

    monkeypatch.delenv("CHOPSHOP_FLUX_IDLE_UNLOAD", raising=False)
    engine._start_idle_unload()
    assert engine._idle_thread is None, "default 0 must keep the engine thread-free"

    monkeypatch.setenv("CHOPSHOP_FLUX_IDLE_UNLOAD", "600")
    engine._start_idle_unload()
    assert engine._idle_thread is not None
    assert engine._idle_thread.daemon is True
    assert engine._idle_thread.name == "flux-idle-unload"

    first = engine._idle_thread
    engine._start_idle_unload()
    assert engine._idle_thread is first, "a second load must not stack a second thread"


def test_idle_unload_seconds_parses_the_environment(monkeypatch):
    from chopshop_flux import config as config_module
    monkeypatch.delenv("CHOPSHOP_FLUX_IDLE_UNLOAD", raising=False)
    assert config_module.idle_unload_seconds() == 0
    monkeypatch.setenv("CHOPSHOP_FLUX_IDLE_UNLOAD", "1800")
    assert config_module.idle_unload_seconds() == 1800
    monkeypatch.setenv("CHOPSHOP_FLUX_IDLE_UNLOAD", "not-a-number")
    with pytest.raises(ValueError):
        config_module.idle_unload_seconds()


# -- releasing the weights -------------------------------------------------
#
# #flux-unload-collect -- the OOM kill. `del self._pipe` alone leaves a diffusers
# pipeline's modules alive, because accelerate's hooks put them in reference
# cycles, so every model switch added another ~16 GiB of ANONYMOUS memory that
# never came back (measured peaks of 35.3 / 63.8 / 77.3 GiB = 2 / 4 / 5 cycles,
# the last one an OOM kill on a 91 GiB box with no swap). The numbers need a GPU
# and 16 GB of weights; the COLLECT is what is pinned here, because it is the
# thing that must not be deleted by a future "cleanup".

def test_unload_collects_the_cycles_or_the_weights_are_never_released(monkeypatch):
    seen = []
    monkeypatch.setattr(engine_module.gc, "collect", lambda: seen.append(True) or 0)

    FluxEngine().unload()
    assert seen, ("unload must run gc.collect(): without it the pipeline's "
                  "reference cycles keep ~16 GiB of weights alive per switch")


def test_unload_collects_before_it_empties_the_device_cache(monkeypatch):
    """Order is load-bearing: the collect is what drops the tensors, and
    empty_cache() only hands the *already freed* blocks back to the driver."""
    order = []
    monkeypatch.setattr(engine_module.gc, "collect", lambda: order.append("collect"))
    engine = FluxEngine()
    # A stand-in for the torch module: only the one call unload() makes.
    engine._torch = types.SimpleNamespace(  # type: ignore[assignment]
        cuda=types.SimpleNamespace(empty_cache=lambda: order.append("empty_cache")))
    engine.unload()
    assert order == ["collect", "empty_cache"]


def test_unload_returns_the_pages_the_allocator_is_holding(monkeypatch):
    """#flux-unload-trim -- freeing is not the same as returning.

    Measured: after an unload that had already freed every weight (28 small
    tensors left, and a further gc.collect() freeing 0 objects) RSS still sat at
    16.23 GiB, because the allocator keeps the arena. malloc_trim gives ~1.45 GiB
    back at once and makes the release the same shape every run.
    """
    called = []
    monkeypatch.setattr(engine_module, "_return_freed_pages",
                        lambda: called.append(True) or 1)
    FluxEngine().unload()
    assert called, "unload must try to return the allocator's pages"


def test_the_page_return_is_a_no_op_without_glibc(monkeypatch):
    """It is a nicety on top of the fix, never a dependency: musl, macOS and
    Windows must get a quiet 0 rather than an exception on the release path."""
    monkeypatch.setattr(engine_module, "_LIBC", False)
    assert engine_module._return_freed_pages() == 0


def test_the_page_return_never_raises(monkeypatch):
    """Whatever libc says, an unload must not fail on it."""
    class Exploding:
        def malloc_trim(self, _):
            raise OSError("no such symbol")

    monkeypatch.setattr(engine_module, "_LIBC", Exploding())
    assert engine_module._return_freed_pages() == 0


def test_unload_is_lock_free_so_load_can_call_it_while_holding_the_lock():
    """WHY release() exists instead of unload() just taking the lock.

    load() calls unload() while already holding the engine lock, and
    threading.Lock is not reentrant -- so a lock inside unload() would deadlock
    the service on the first model switch. This is the regression guard for
    anyone "tidying" the two methods into one.
    """
    engine = FluxEngine()
    engine._lock.acquire()
    try:
        engine.unload()          # must not block: it is the lock-free primitive
    finally:
        engine._lock.release()


def test_release_waits_for_an_in_flight_generation_instead_of_barging_in():
    """A /unload during a generate must not drop the pipe mid-run.

    The route used to call unload() outside the lock, so an unload that landed
    while _run was executing took the pipeline away underneath it.
    """
    engine = FluxEngine()
    engine._lock.acquire()
    worker = threading.Thread(target=engine.release, daemon=True)
    worker.start()
    worker.join(timeout=0.5)
    assert worker.is_alive(), "release() must wait for the lock, not skip it"
    engine._lock.release()
    worker.join(timeout=5)
    assert not worker.is_alive(), "and take it as soon as it is free"

