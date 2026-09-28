"""Applying LoRAs and swapping the VAE, driven through a fake pipeline.

No torch, no diffusers, no GPU: ``diffusers`` and ``torch`` are replaced with
recording stand-ins, so what these tests observe is the *sequence of calls* the
engine makes on a real pipeline object. That sequence is the whole point — a VAE
assigned after ``enable_model_cpu_offload()`` has been measured to stay on CPU
and blow up inside the scheduler step, naming everything except the VAE — so the
order is pinned here rather than described in a comment.
"""

import sys
import types

import pytest

from chopshop_flux.engine import (FluxEngine, GenerationError, modifier_warnings,
                                  resolve_modifiers, resolve_schedule,
                                  vae_class_name)
from chopshop_flux.models import ModelError, resolve
from chopshop_flux.modifiers import (MODIFIERS, VAES, ModifierSpec, VAESpec,
                                     check_modifier_usable)

SCRATCH = "/nonexistent/for/this/test"


class OriginalScheduler:
    """What a freshly loaded pipeline's `scheduler` looks like: it has a
    `.config` the engine passes to the replacement class's from_config."""

    config = {"num_train_timesteps": 1000, "sigma_data": 0.5}


class RecordingPipeline:
    """A pipeline that writes down what the engine did to it, in order."""

    def __init__(self, events, repo_id, **kwargs):
        self.events = events
        events.append(("from_pretrained", repo_id, kwargs.get("torch_dtype")))
        self._vae = "the-model-own-vae"
        self._scheduler = OriginalScheduler()
        # None means "not offloaded", which is what a fresh from_pretrained
        # returns; the engine must not think it can skip the device placement.
        self.hf_device_map = None
        self.offloaded = 0

    # Assignment is recorded through properties: `pipe.vae = x` and
    # `pipe.scheduler = y` are two of the five steps being pinned.
    @property
    def vae(self):
        return self._vae

    @vae.setter
    def vae(self, value):
        self.events.append(("vae-assign", value))
        self._vae = value

    @property
    def scheduler(self):
        return self._scheduler

    @scheduler.setter
    def scheduler(self, value):
        self.events.append(("scheduler-assign", value))
        self._scheduler = value

    def load_lora_weights(self, repo_id, weight_name=None, adapter_name=None):
        self.events.append(("load_lora_weights", repo_id, weight_name, adapter_name))

    def set_adapters(self, names, adapter_weights=None):
        self.events.append(("set_adapters", list(names), list(adapter_weights or [])))

    def enable_model_cpu_offload(self):
        self.events.append(("enable_model_cpu_offload",))
        self.offloaded += 1
        self.hf_device_map = {"vae": "cpu"}

    def to(self, device):
        self.events.append(("to", device))


class FakeScheduler:
    """Stands in for LCMScheduler / EulerDiscreteScheduler."""

    def __init__(self, name, config, **kwargs):
        self.name = name
        self.config = config
        self.kwargs = kwargs

    @classmethod
    def from_config(cls, config, **kwargs):
        return cls(cls.__name__, config, **kwargs)

    def __repr__(self):
        return "FakeScheduler(%s, %r)" % (self.name, self.kwargs)


class FakeVAE:
    load_calls = []

    @classmethod
    def from_pretrained(cls, repo_id, **kwargs):
        cls.load_calls.append((repo_id, kwargs))
        return "VAE:%s" % repo_id

    def __repr__(self):
        return "FakeVAE"


class TinyVAE(FakeVAE):
    pass


def install_fakes(monkeypatch, events):
    """A fake torch + diffusers, and the engine built against them."""
    monkeypatch.setitem(sys.modules, "torch", types.ModuleType("torch"))
    torch = sys.modules["torch"]
    torch.bfloat16 = "torch.bfloat16"
    torch.cuda = type("C", (), {"is_available": staticmethod(lambda: True),
                                "empty_cache": staticmethod(lambda: None)})()
    torch.inference_mode = staticmethod(lambda: types.SimpleNamespace(
        __enter__=lambda s: None, __exit__=lambda s, *a: False))

    diffusers = types.ModuleType("diffusers")
    for name in ("Flux2KleinPipeline", "StableDiffusionXLPipeline",
                 "StableDiffusionXLImg2ImgPipeline", "StableDiffusionPipeline",
                 "StableDiffusionImg2ImgPipeline", "SanaSprintPipeline",
                 "SanaSprintImg2ImgPipeline"):
        setattr(diffusers, name, type(name, (RecordingPipeline,), {
            "from_pretrained": classmethod(
                lambda cls, repo_id, _events=events, **kwargs: cls(_events, repo_id,
                                                                   **kwargs))}))
    diffusers.LCMScheduler = type("LCMScheduler", (FakeScheduler,), {})
    diffusers.EulerDiscreteScheduler = type("EulerDiscreteScheduler",
                                            (FakeScheduler,), {})
    diffusers.AutoencoderKL = FakeVAE
    diffusers.AutoencoderTiny = TinyVAE
    monkeypatch.setitem(sys.modules, "diffusers", diffusers)
    FakeVAE.load_calls = []
    return torch


@pytest.fixture
def loaded(monkeypatch):
    """``(engine, events)`` — an engine whose fakes record every call."""
    events = []
    install_fakes(monkeypatch, events)
    engine = FluxEngine(out_dir=SCRATCH, offload="cpu")
    return engine, events


def names(events):
    return [event[0] for event in events]


# -- the ordering rule -----------------------------------------------------

def test_the_offload_is_the_very_last_step_of_a_full_load(loaded):
    """The measured bug, pinned.

    On real weights: build the offload map over the original VAE, then assign a
    new one, and the NEXT pipeline call dies with "Expected all tensors to be on
    the same device" inside the LCM scheduler step. Nothing about that message
    names the VAE. So the order is contractual:

        from_pretrained -> scheduler -> lora -> set_adapters -> vae -> offload

    and the assertion below is what stops it regressing.
    """
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["lcm-lora-sdxl", "pixel-art-xl"],
                vae="sdxl-vae-fp16-fix")

    order = names(events)
    assert order[0] == "from_pretrained"
    assert order[-1] == "enable_model_cpu_offload", order
    assert order.index("scheduler-assign") < order.index("load_lora_weights")
    assert order.index("load_lora_weights") < order.index("set_adapters")
    assert order.index("set_adapters") < order.index("vae-assign")
    assert order.index("vae-assign") < order.index("enable_model_cpu_offload")
    assert order.count("enable_model_cpu_offload") == 1


def test_a_vae_swap_at_default_offload_still_ends_with_the_offload(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", vae="taesdxl")
    assert names(events) == ["from_pretrained", "vae-assign", "enable_model_cpu_offload"]


def test_an_already_offloaded_pipe_gets_the_offload_reapplied(monkeypatch):
    """The verified fix for the case the normal path never takes: if a pipe
    arrives already offloaded, the assignment invalidates its device map, so the
    offload is re-applied after it."""
    events = []

    class AlreadyOffloaded(RecordingPipeline):
        def __init__(self, events, repo_id, **kwargs):
            super().__init__(events, repo_id, **kwargs)
            self.hf_device_map = {"vae": "cpu"}

    install_fakes(monkeypatch, events)
    diffusers = sys.modules["diffusers"]
    diffusers.StableDiffusionXLPipeline = type("StableDiffusionXLPipeline",
                                               (AlreadyOffloaded,), {
        "from_pretrained": classmethod(
            lambda cls, repo_id, _events=events, **kwargs: cls(_events, repo_id,
                                                               **kwargs))})
    engine = FluxEngine(out_dir=SCRATCH, offload="cpu")
    engine.load("sdxl-1.0", vae="sdxl-vae")

    order = names(events)
    assert order.count("enable_model_cpu_offload") == 2, order
    assert order.index("vae-assign") < len(order) - 1
    assert order[-1] == "enable_model_cpu_offload"


def test_a_fresh_pipe_is_never_offloaded_twice(loaded):
    """The re-apply exists for a pipe that is already offloaded. The normal path
    starts from from_pretrained with no device map, so it must not pay for a
    second one."""
    engine, events = loaded
    engine.load("sdxl-1.0", vae="sdxl-vae")
    assert names(events).count("enable_model_cpu_offload") == 1


# -- the call shape --------------------------------------------------------

def test_each_modifier_is_loaded_once_with_its_exact_weight_file(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["sdxl-lightning-4step", "pixel-art-xl"])

    loads = [event for event in events if event[0] == "load_lora_weights"]
    assert len(loads) == 2
    assert (loads[0][1], loads[0][2]) == (
        "ByteDance/SDXL-Lightning", "sdxl_lightning_4step_lora.safetensors")
    assert (loads[1][1], loads[1][2]) == ("nerijs/pixel-art-xl",
                                          "pixel-art-xl.safetensors")
    # Separate adapter names, or set_adapters could not address them apart.
    assert loads[0][3] != loads[1][3]


def test_the_requested_scales_reach_set_adapters(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["lcm-lora-sdxl", "pixel-art-xl"],
                modifier_scales={"lcm-lora-sdxl": 0.8, "pixel-art-xl": 0.25})

    sets = [event for event in events if event[0] == "set_adapters"]
    assert len(sets) == 1
    assert sets[0][2] == [0.8, 0.25]


def test_two_modifiers_always_get_set_adapters(loaded):
    """Loading a second adapter leaves only the last one active, so more than one
    needs set_adapters even at the default scale."""
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["sdxl-lightning-4step", "pixel-art-xl"])
    sets = [event for event in events if event[0] == "set_adapters"]
    assert len(sets) == 1
    assert sets[0][2] == [1.0, 1.0]


def test_one_modifier_at_its_default_scale_needs_no_set_adapters(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["pixel-art-xl"])
    assert "set_adapters" not in names(events)


def test_one_modifier_with_a_scale_still_gets_set_adapters(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["pixel-art-xl"],
                modifier_scales={"pixel-art-xl": 0.5})
    sets = [event for event in events if event[0] == "set_adapters"]
    assert len(sets) == 1
    assert sets[0][2] == [0.5]


def test_a_scale_can_be_given_by_alias(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["pixel-art-xl"],
                modifier_scales={"pixel-art": 0.4})
    sets = [event for event in events if event[0] == "set_adapters"]
    assert sets[0][2] == [0.4]


# -- the scheduler ---------------------------------------------------------

def test_the_lcm_adapter_installs_lcm_scheduler(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["lcm-lora-sdxl"])
    assigned = [event[1] for event in events if event[0] == "scheduler-assign"]
    assert len(assigned) == 1
    assert assigned[0].name == "LCMScheduler"


def test_the_lightning_adapter_installs_euler_with_trailing_spacing(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["sdxl-lightning-4step"])
    assigned = [event[1] for event in events if event[0] == "scheduler-assign"]
    assert len(assigned) == 1
    assert assigned[0].name == "EulerDiscreteScheduler"
    assert assigned[0].kwargs == {"timestep_spacing": "trailing"}


def test_a_style_adapter_with_no_schedule_leaves_the_scheduler_alone(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["pixel-art-xl"])
    assert "scheduler-assign" not in names(events)


def test_two_adapters_wanting_one_scheduler_assign_it_once(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["sdxl-lightning-4step", "sdxl-lightning-2step"])
    assert names(events).count("scheduler-assign") == 1


def test_resolve_schedule_reports_a_conflict_rather_than_picking_silently():
    specs, _weights, _warnings = resolve_modifiers(
        ["sdxl-lightning-4step", "lcm-lora-sdxl"])
    chosen, warnings = resolve_schedule(specs)
    assert chosen == "trailing-euler"        # the first requested wins
    assert any("different schedulers" in w for w in warnings)


# -- the VAE ---------------------------------------------------------------

def test_a_normal_vae_loads_through_autoencoder_kl_at_bf16(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", vae="sdxl-vae-fp16-fix")
    assert FakeVAE.load_calls == [("madebyollin/sdxl-vae-fp16-fix",
                                   {"torch_dtype": "torch.bfloat16"})]
    assert events[-2] == ("vae-assign", "VAE:madebyollin/sdxl-vae-fp16-fix")


def test_a_tiny_vae_loads_through_autoencoder_tiny(loaded):
    """A different class, not a smaller file: AutoencoderTiny is not an
    AutoencoderKL, so the flag chooses the class."""
    engine, events = loaded
    engine.load("sdxl-1.0", vae="taesdxl")
    assert TinyVAE.load_calls == [("madebyollin/taesdxl", {})]
    assert vae_class_name(VAES["taesdxl"]) == "AutoencoderTiny"
    assert vae_class_name(VAES["sdxl-vae"]) == "AutoencoderKL"


def test_a_vae_that_cannot_load_is_an_error_not_a_fallback(loaded):
    """Silently keeping the model's own VAE would report a success that produced
    the thing the caller asked to replace."""
    engine, events = loaded

    def explode(repo_id, **kwargs):
        raise OSError("no such repo")

    monkeyed = type("Broken", (FakeVAE,), {"from_pretrained": classmethod(
        lambda cls, repo_id, **kwargs: explode(repo_id, **kwargs))})
    sys.modules["diffusers"].AutoencoderKL = monkeyed
    with pytest.raises(GenerationError) as caught:
        engine.load("sdxl-1.0", vae="sdxl-vae")
    assert "cannot load vae sdxl-vae" in str(caught.value)
    assert caught.value.exit_code == 4
    assert engine._pipe is None


def test_a_modifier_that_cannot_load_is_an_error_not_a_fallback(loaded):
    engine, events = loaded
    diffusers = sys.modules["diffusers"]

    def explode(repo_id, weight_name=None, adapter_name=None):
        raise OSError("no such adapter")

    class Broken(RecordingPipeline):
        def load_lora_weights(self, repo_id, weight_name=None, adapter_name=None):
            explode(repo_id)

    diffusers.StableDiffusionXLPipeline = type("StableDiffusionXLPipeline",
                                               (Broken,), {
        "from_pretrained": classmethod(
            lambda cls, repo_id, _events=events, **kwargs: cls(_events, repo_id,
                                                               **kwargs))})
    with pytest.raises(GenerationError) as caught:
        engine.load("sdxl-1.0", modifiers=["pixel-art-xl"])
    assert "cannot load modifier pixel-art-xl" in str(caught.value)
    assert caught.value.exit_code == 4


# -- idempotency: the easiest bug in this file ----------------------------

def test_the_same_model_and_modifiers_do_not_reload(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["pixel-art-xl"])
    before = len(events)
    engine.load("sdxl-1.0", modifiers=["pixel-art-xl"])
    assert len(events) == before, "an identical request must reuse the pipeline"


def test_a_different_modifier_set_reloads(loaded):
    """Without the modifier set in the idempotency key, the second request gets
    the first request's pipeline and quietly generates the wrong thing."""
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["pixel-art-xl"])
    engine.load("sdxl-1.0", modifiers=["lcm-lora-sdxl"])
    assert names(events).count("from_pretrained") == 2


def test_the_same_modifiers_at_a_different_scale_reload(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["pixel-art-xl"],
                modifier_scales={"pixel-art-xl": 0.5})
    engine.load("sdxl-1.0", modifiers=["pixel-art-xl"],
                modifier_scales={"pixel-art-xl": 0.9})
    assert names(events).count("from_pretrained") == 2


def test_adding_a_vae_reloads_and_removing_it_reloads_back(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0")
    engine.load("sdxl-1.0", vae="taesdxl")
    engine.load("sdxl-1.0")
    assert names(events).count("from_pretrained") == 3


def test_no_modifiers_twice_does_not_reload(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0")
    engine.load("sdxl-1.0")
    assert names(events).count("from_pretrained") == 1


def test_the_same_modifiers_in_a_different_order_do_not_reload(monkeypatch):
    """The key is a sorted set: asking for the same two adapters in a different
    order is the same pipeline and must not pay for a second load."""
    events = []
    install_fakes(monkeypatch, events)
    engine = FluxEngine(out_dir=SCRATCH, offload="cpu")
    engine.load("sdxl-1.0", modifiers=["pixel-art-xl", "lcm-lora-sdxl"])
    before = len(events)
    engine.load("sdxl-1.0", modifiers=["lcm-lora-sdxl", "pixel-art-xl"])
    assert len(events) == before


def test_unload_forgets_what_was_applied(loaded):
    engine, events = loaded
    engine.load("sdxl-1.0", modifiers=["pixel-art-xl"])
    engine.unload()
    assert engine._loaded_modifiers == ()
    assert engine._loaded_vae is None
    engine.load("sdxl-1.0")
    assert names(events).count("from_pretrained") == 2


# -- the gate fires before anything is loaded -----------------------------

def test_a_non_commercial_modifier_is_refused_before_torch_is_touched(monkeypatch):
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    monkeypatch.setitem(MODIFIERS, "nc-test", ModifierSpec(
        key="nc-test", repo_id="example/nc", weight_name="nc.safetensors",
        targets=("sdxl-1.0",), license="Stability AI Non-Commercial Research "
                                       "Community License",
        commercial_ok=False, repo_bytes=1.0))
    # Any import of torch would explode, so reaching the gate proves the order.
    monkeypatch.setitem(sys.modules, "torch", None)
    with pytest.raises(ModelError) as caught:
        FluxEngine().generate(prompt="x", width=512, height=512,
                              model="sdxl-1.0", modifiers=["nc-test"])
    assert "non-commercial" in str(caught.value).lower()
    assert "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL" in str(caught.value)


def test_a_non_commercial_vae_is_allowed_with_the_ack(monkeypatch):
    """One acknowledgement clears a VAE too -- the same business decision whoever
    published the checkpoint.

    The previous version of this test set the ack and then asserted only that a
    COMMERCIAL modifier resolved, which passes whether or not the ack is read at
    all: it could not fail. This one exercises the gate in both directions.
    """
    monkeypatch.setitem(VAES, "nc-vae", VAESpec(
        key="nc-vae", repo_id="example/nc", targets=("sdxl-1.0",),
        license="Stability AI Non-Commercial Research Community License",
        commercial_ok=False, repo_bytes=1.0))

    monkeypatch.setenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", "1")
    check_modifier_usable(VAES["nc-vae"])          # silent with the ack

    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL")
    with pytest.raises(ModelError) as caught:
        check_modifier_usable(VAES["nc-vae"])
    assert "non-commercial" in str(caught.value).lower()
    assert "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL" in str(caught.value)


def test_a_non_commercial_vae_is_refused_on_the_LOAD_path(monkeypatch):
    """The gate must hold on every path that LOADS an artefact, not only in
    generate().

    Measured before this test existed: `FluxEngine().load(vae=<non-commercial>)`
    succeeded with no acknowledgement, while `generate(vae=<the same>)` correctly
    refused it -- the VAE gate lived only in generate(), so a caller reaching
    `load()` directly could put a non-commercial decoder on a commercial job.
    Deleting the load-path gate left the entire suite green, which is why this
    test exists and why it is written to fail if the gate goes away.
    """
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    monkeypatch.setitem(VAES, "nc-vae", VAESpec(
        key="nc-vae", repo_id="example/nc", targets=("sdxl-1.0",),
        license="Stability AI Non-Commercial Research Community License",
        commercial_ok=False, repo_bytes=1.0))
    # torch is set to None: reaching the gate BEFORE the import is the proof that
    # the refusal happens on resolution, not after a GPU has been touched.
    monkeypatch.setitem(sys.modules, "torch", None)
    with pytest.raises(ModelError) as caught:
        FluxEngine().load(model="sdxl-1.0", vae="nc-vae")
    assert "non-commercial" in str(caught.value).lower()
    assert "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL" in str(caught.value)


def test_an_unknown_modifier_is_a_caller_error():
    with pytest.raises(ModelError) as caught:
        resolve_modifiers(["no-such-lora"])
    assert caught.value.exit_code == 2
    assert "no-such-lora" in str(caught.value)


def test_a_bare_string_is_not_iterated_per_character():
    """`modifiers="lcm-lora-sdxl"` must not resolve 'l', 'c', 'm', ..."""
    specs, _weights, _warnings = resolve_modifiers("lcm-lora-sdxl")
    assert [spec.key for spec in specs] == ["lcm-lora-sdxl"]


def test_a_duplicate_modifier_is_applied_once():
    specs, weights, _warnings = resolve_modifiers(["pixel-art-xl", "pixel-art-xl"])
    assert [spec.key for spec in specs] == ["pixel-art-xl"]
    assert weights == [1.0]


def test_a_scale_that_names_nothing_requested_is_reported():
    _specs, _weights, warnings = resolve_modifiers(
        ["pixel-art-xl"], {"lcm-lora-sdxl": 0.5})
    assert any("not in the requested modifiers" in w for w in warnings)


def test_a_non_numeric_scale_is_a_caller_error():
    with pytest.raises(ModelError):
        resolve_modifiers(["pixel-art-xl"], {"pixel-art-xl": "very"})
    with pytest.raises(ModelError):
        resolve_modifiers(["pixel-art-xl"], {"pixel-art-xl": True})


# -- the warnings ----------------------------------------------------------

def test_a_modifier_for_another_model_is_reported():
    """An adapter aimed at another family still loads and still changes the
    output — it just delivers something other than what its card shows."""
    specs, weights, _ = resolve_modifiers(["lcm-lora-sd15", "sdxl-lightning-4step"])
    warnings = modifier_warnings(resolve("sdxl-1.0"), specs, weights, None,
                                 steps=4, guidance=0.0)
    assert any("targets sd-1.5" in w for w in warnings)


def test_a_vae_for_another_model_is_reported():
    specs, weights, _ = resolve_modifiers([])
    warnings = modifier_warnings(resolve("klein-4b"), specs, weights,
                                 VAES["sdxl-vae"], steps=4, guidance=1.0)
    assert any("vae sdxl-vae targets" in w for w in warnings)


def test_a_guidance_the_adapter_was_not_trained_for_is_reported():
    specs, weights, _ = resolve_modifiers(["lcm-lora-sdxl"])
    warnings = modifier_warnings(resolve("sdxl-1.0"), specs, weights, None,
                                steps=4, guidance=5.0)
    assert any("trained at guidance 1.0" in w for w in warnings)
    quiet = modifier_warnings(resolve("sdxl-1.0"), specs, weights, None,
                              steps=4, guidance=1.0)
    assert quiet == []


def test_a_step_count_the_adapter_was_not_distilled_for_is_reported():
    specs, weights, _ = resolve_modifiers(["sdxl-lightning-4step"])
    warnings = modifier_warnings(resolve("sdxl-1.0"), specs, weights, None,
                                steps=30, guidance=0.0)
    assert any("4-step distilled adapter" in w for w in warnings)


def test_a_zero_scale_is_reported_as_disabling_the_adapter():
    specs, weights, _ = resolve_modifiers(["pixel-art-xl"], {"pixel-art-xl": 0.0})
    warnings = modifier_warnings(resolve("sdxl-1.0"), specs, weights, None,
                                steps=20, guidance=6.0)
    assert any("scale 0" in w for w in warnings)


# -- what generate() echoes back ------------------------------------------

def _engine_with_stubbed_run(monkeypatch, results=None):
    engine = FluxEngine()
    monkeypatch.setattr(engine, "load",
                        lambda model=None, edit=False, **kwargs: resolve(model))
    monkeypatch.setattr(engine, "_run", lambda spec, **kwargs: results or [])
    return engine


def test_generate_echoes_the_modifiers_with_the_scale_actually_used(monkeypatch):
    engine = _engine_with_stubbed_run(monkeypatch)
    body = engine.generate(prompt="x", width=768, height=768, model="sdxl-1.0",
                           modifiers=["pixel-art-xl"],
                           modifier_scales={"pixel-art-xl": 0.75})
    assert body["modifiers"] == [{"key": "pixel-art-xl", "scale": 0.75,
                                  "repo_id": "nerijs/pixel-art-xl",
                                  "weight_name": "pixel-art-xl.safetensors"}]
    assert body["scheduler"] is None
    assert body["vae"] is None


def test_generate_echoes_the_scheduler_an_adapter_asked_for(monkeypatch):
    engine = _engine_with_stubbed_run(monkeypatch)
    body = engine.generate(prompt="x", width=768, height=768, model="sdxl-1.0",
                           modifiers=["lcm-lora-sdxl"],
                           modifier_scales={"lcm-lora-sdxl": 0.8})
    assert body["scheduler"] == "lcm"
    # The scale in effect is the one that was asked for, not the default.
    assert body["modifiers"][0]["scale"] == 0.8


def test_generate_echoes_the_vae(monkeypatch):
    engine = _engine_with_stubbed_run(monkeypatch)
    body = engine.generate(prompt="x", width=768, height=768, model="sdxl-1.0",
                           vae="taesdxl")
    assert body["vae"] == "taesdxl"


def test_generate_reports_nothing_applied_when_nothing_was_asked_for(monkeypatch):
    engine = _engine_with_stubbed_run(monkeypatch)
    body = engine.generate(prompt="x", width=512, height=512, model="klein-4b")
    assert body["modifiers"] == []
    assert body["vae"] is None
    assert body["scheduler"] is None


def test_generate_warns_when_an_adapter_is_not_on_schedule(monkeypatch):
    engine = _engine_with_stubbed_run(monkeypatch)
    body = engine.generate(prompt="x", width=768, height=768, model="sdxl-1.0",
                           modifiers=["sdxl-lightning-4step"],
                           steps=30, guidance=0.0)
    assert any("4-step distilled adapter" in w for w in body["warnings"])
    assert body["steps"] == 30


def test_generate_warns_when_a_modifier_was_not_trained_for_the_model(monkeypatch):
    engine = _engine_with_stubbed_run(monkeypatch)
    body = engine.generate(prompt="x", width=512, height=512, model="sd-1.5",
                           modifiers=["pixel-art-xl"])
    assert any("not trained for this model" in w for w in body["warnings"])


def test_generate_asks_load_for_the_modifiers(monkeypatch):
    """The modifier set has to reach load(), or the idempotency rule has nothing
    to compare against."""
    calls = {}

    def fake_load(model=None, edit=False, **kwargs):
        calls.update(kwargs)
        calls["model"] = model
        return resolve(model)

    engine = FluxEngine()
    monkeypatch.setattr(engine, "load", fake_load)
    monkeypatch.setattr(engine, "_run", lambda spec, **kwargs: [])
    engine.generate(prompt="x", width=768, height=768, model="sdxl-1.0",
                    modifiers=["pixel-art-xl"], vae="taesdxl",
                    modifier_scales={"pixel-art-xl": 0.3})
    assert calls["model"] == "sdxl-1.0"
    assert calls["modifiers"] == ["pixel-art-xl"]
    assert calls["vae"] == "taesdxl"
    assert calls["modifier_scales"] == {"pixel-art-xl": 0.3}


def test_generate_does_not_pass_modifier_keywords_when_there_are_none(monkeypatch):
    """A request with no adapters is the call shape this method always made, so
    an engine wrapper that predates the keywords keeps working."""
    seen = {}

    def fake_load(model=None, edit=False):
        seen["called"] = True
        return resolve(model)

    engine = FluxEngine()
    monkeypatch.setattr(engine, "load", fake_load)
    monkeypatch.setattr(engine, "_run", lambda spec, **kwargs: [])
    engine.generate(prompt="x", width=512, height=512, model="klein-4b")
    assert seen["called"] is True
