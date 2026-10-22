"""The modifier registry: the licence gate, the exact weight files, the targets.

These are the assertions that stop a LoRA's licence, its weight filename or the
model it was trained for from being "fixed" later by someone who did not know
why they were there. No network, no torch: the registry is data plus one gate.
"""

import pytest

from chopshop_flux import config
from chopshop_flux.models import (APACHE_2, MIT, REGISTRY, SD15_OPENRAIL_M,
                                  SDXL_OPENRAIL_PP, ModelError)
from chopshop_flux.modifiers import (MODIFIERS, SCHEDULERS, VAES, ModifierSpec,
                                     VAESpec, all_as_dict, as_dict,
                                     check_modifier_usable, resolve_modifier,
                                     resolve_vae)

# The exact weight filename inside each repo, verified against the HuggingFace
# tree API. A repo can hold several adapters (SDXL-Lightning holds three) and
# several precisions of the same adapter, so the filename is part of the
# identity — guessing it is how a LoRA silently loads the wrong thing, or
# nothing at all.
EXPECTED_MODIFIERS = {
    "klein-background-remove": (
        "fal/flux-2-klein-4B-background-remove-lora",
        "flux-background-remove-lora.safetensors",
        ("klein-4b", "klein-4b-base"), APACHE_2,
    ),
    "klein-object-remove": (
        "fal/flux-2-klein-4B-object-remove-lora",
        "flux-object-remove-lora.safetensors",
        ("klein-4b", "klein-4b-base"), APACHE_2,
    ),
    "klein-outpaint": (
        "fal/flux-2-klein-4B-outpaint-lora",
        "flux-outpaint-lora.safetensors",
        ("klein-4b", "klein-4b-base"), APACHE_2,
    ),
    "klein-spritesheet": (
        "fal/flux-2-klein-4b-spritesheet-lora",
        "flux-spritesheet-lora.safetensors",
        ("klein-4b", "klein-4b-base"), APACHE_2,
    ),
    "sdxl-lightning-4step": (
        "ByteDance/SDXL-Lightning",
        "sdxl_lightning_4step_lora.safetensors",
        ("sdxl-1.0", "ssd-1b"), SDXL_OPENRAIL_PP,
    ),
    "sdxl-lightning-2step": (
        "ByteDance/SDXL-Lightning",
        "sdxl_lightning_2step_lora.safetensors",
        ("sdxl-1.0", "ssd-1b"), SDXL_OPENRAIL_PP,
    ),
    "sdxl-lightning-8step": (
        "ByteDance/SDXL-Lightning",
        "sdxl_lightning_8step_lora.safetensors",
        ("sdxl-1.0", "ssd-1b"), SDXL_OPENRAIL_PP,
    ),
    "lcm-lora-sdxl": (
        "latent-consistency/lcm-lora-sdxl",
        "pytorch_lora_weights.safetensors",
        ("sdxl-1.0", "ssd-1b"), SDXL_OPENRAIL_PP,
    ),
    "lcm-lora-sd15": (
        "latent-consistency/lcm-lora-sdv1-5",
        "pytorch_lora_weights.safetensors",
        ("sd-1.5",), SD15_OPENRAIL_M,
    ),
    "pixel-art-xl": (
        "nerijs/pixel-art-xl", "pixel-art-xl.safetensors",
        ("sdxl-1.0", "ssd-1b"), SD15_OPENRAIL_M,
    ),
    "logo-redmond": (
        "artificialguybr/LogoRedmond-LogoLoraForSDXL-V2",
        "LogoRedmondV2-Logo-LogoRedmAF.safetensors",
        ("sdxl-1.0", "ssd-1b"), SD15_OPENRAIL_M,
    ),
    "colouring-book": (
        "artificialguybr/ColoringBookRedmond-V2",
        "ColoringBookRedmond-ColoringBook-ColoringBookAF.safetensors",
        ("sdxl-1.0", "ssd-1b", "sd-1.5"), SD15_OPENRAIL_M,
    ),
    "stickers": (
        "artificialguybr/StickersRedmond", "StickersRedmond.safetensors",
        ("sdxl-1.0", "ssd-1b", "sd-1.5"), SD15_OPENRAIL_M,
    ),
    "papercut-sdxl": (
        "TheLastBen/Papercut_SDXL", "papercut.safetensors",
        ("sdxl-1.0", "ssd-1b"), SD15_OPENRAIL_M,
    ),
}

EXPECTED_VAES = {
    "sdxl-vae-fp16-fix": ("madebyollin/sdxl-vae-fp16-fix",
                          ("sdxl-1.0", "ssd-1b"), MIT, False),
    "sdxl-vae": ("stabilityai/sdxl-vae", ("sdxl-1.0", "ssd-1b"), MIT, False),
    "sd-vae-ft-mse": ("stabilityai/sd-vae-ft-mse", ("sd-1.5",), MIT, False),
    "taesdxl": ("madebyollin/taesdxl", ("sdxl-1.0", "ssd-1b"), MIT, True),
    "taesd": ("madebyollin/taesd", ("sd-1.5",), MIT, True),
}


# -- the exact repos and files ---------------------------------------------

def test_every_modifier_is_registered_with_its_repo_file_targets_and_licence():
    assert set(MODIFIERS) == set(EXPECTED_MODIFIERS)
    for key, (repo_id, weight_name, targets, licence) in EXPECTED_MODIFIERS.items():
        spec = MODIFIERS[key]
        assert spec.key == key
        assert spec.repo_id == repo_id, key
        assert spec.weight_name == weight_name, key
        assert spec.targets == targets, key
        assert spec.license == licence, key
        assert spec.repo_bytes > 0, key


def test_every_target_names_a_model_that_exists():
    """A typo here would only ever show up as \"that adapter did nothing\"."""
    for spec in MODIFIERS.values():
        assert spec.targets, spec.key
        for target in spec.targets:
            assert target in REGISTRY, "%s targets unknown model %s" % (spec.key, target)


def test_every_vae_is_registered_with_its_repo_targets_and_licence():
    assert set(VAES) == set(EXPECTED_VAES)
    for key, (repo_id, targets, licence, tiny) in EXPECTED_VAES.items():
        spec = VAES[key]
        assert spec.key == key
        assert spec.repo_id == repo_id, key
        assert spec.targets == targets, key
        assert spec.license == licence, key
        assert spec.tiny is tiny, key
        for target in targets:
            assert target in REGISTRY, "%s targets unknown model %s" % (key, target)


def test_the_tiny_vaes_are_the_autotiny_ones_and_the_rest_are_kl():
    """`tiny` is a class choice, not a size one: AutoencoderTiny is a different
    module, and the engine picks the class from this flag."""
    for key in ("taesdxl", "taesd"):
        assert VAES[key].tiny is True, key
        assert VAES[key].repo_bytes < 20e6, key
    for key in ("sdxl-vae-fp16-fix", "sdxl-vae", "sd-vae-ft-mse"):
        assert VAES[key].tiny is False, key


def test_the_speed_adapters_carry_the_scheduler_they_require():
    """LCM and Lightning are their distilled schedule: loading the adapter
    without installing the scheduler produces noise, not a cheaper image."""
    assert MODIFIERS["lcm-lora-sdxl"].scheduler == "lcm"
    assert MODIFIERS["lcm-lora-sd15"].scheduler == "lcm"
    for key in ("sdxl-lightning-2step", "sdxl-lightning-4step", "sdxl-lightning-8step"):
        assert MODIFIERS[key].scheduler == "trailing-euler", key
        assert MODIFIERS[key].guidance == 0.0, key
    for spec in MODIFIERS.values():
        assert spec.scheduler is None or spec.scheduler in SCHEDULERS, spec.key


def test_the_lightning_adapters_are_registered_at_their_own_step_counts():
    for key, steps in (("sdxl-lightning-2step", 2), ("sdxl-lightning-4step", 4),
                       ("sdxl-lightning-8step", 8)):
        assert MODIFIERS[key].steps == steps, key


def test_the_lcm_adapters_keep_guidance_off_cfg():
    """LCM is trained without classifier-free guidance, so its registry numbers
    are 1.0 rather than the SDXL base model's 5.0."""
    for key in ("lcm-lora-sdxl", "lcm-lora-sd15"):
        assert MODIFIERS[key].guidance == 1.0, key
        assert MODIFIERS[key].steps == 4, key


def test_pixel_art_uses_the_schedule_its_own_card_states():
    spec = MODIFIERS["pixel-art-xl"]
    assert (spec.steps, spec.guidance) == (8, 1.5)


def test_the_three_lightning_repos_share_one_repo_id():
    """Two entries may share a repo_id — the file name is what differs — so the
    registry must not be keyed by repo."""
    repos = {MODIFIERS[k].repo_id for k in
             ("sdxl-lightning-2step", "sdxl-lightning-4step", "sdxl-lightning-8step")}
    assert repos == {"ByteDance/SDXL-Lightning"}
    names = {MODIFIERS[k].weight_name for k in
             ("sdxl-lightning-2step", "sdxl-lightning-4step", "sdxl-lightning-8step")}
    assert len(names) == 3


def test_the_vae_byte_figures_are_downloads_not_repo_totals():
    """`sdxl-vae-fp16-fix` is a 1.34 GB repo whose useful download is one
    334.7 MB file; quoting the repo total would make every swap look unaffordable."""
    assert VAES["sdxl-vae-fp16-fix"].repo_bytes == 334.7e6
    assert VAES["sdxl-vae"].repo_bytes == 334.7e6
    assert VAES["taesdxl"].repo_bytes == 9.8e6


def test_no_modifier_or_vae_is_non_commercial_today():
    """None of these needs the acknowledgement — and if one is ever added that
    does, this assertion fails so the change is a decision rather than a drift."""
    assert all(spec.commercial_ok for spec in MODIFIERS.values())
    assert all(spec.commercial_ok for spec in VAES.values())


# -- the gate --------------------------------------------------------------

def _noncommercial_modifier():
    return ModifierSpec(key="nc-lora", repo_id="example/nc-lora",
                        weight_name="nc.safetensors", targets=("klein-4b",),
                        license="Stability AI Non-Commercial Research Community License",
                        commercial_ok=False, repo_bytes=1.0)


def _noncommercial_vae():
    return VAESpec(key="nc-vae", repo_id="example/nc-vae", targets=("sdxl-1.0",),
                   license="Stability AI Non-Commercial Research Community License",
                   commercial_ok=False, repo_bytes=1.0)


def test_a_non_commercial_modifier_is_refused_without_the_ack(monkeypatch):
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    with pytest.raises(ModelError) as caught:
        check_modifier_usable(_noncommercial_modifier())
    message = str(caught.value)
    assert "non-commercial" in message.lower()
    assert "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL" in message
    assert caught.value.exit_code == 2


def test_a_non_commercial_vae_is_refused_without_the_ack(monkeypatch):
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    with pytest.raises(ModelError):
        check_modifier_usable(_noncommercial_vae())


def test_the_ack_allows_a_non_commercial_modifier(monkeypatch):
    monkeypatch.setenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", "1")
    check_modifier_usable(_noncommercial_modifier())
    check_modifier_usable(_noncommercial_vae())
    # An explicit argument wins over the environment, the same as models.check_usable.
    check_modifier_usable(_noncommercial_modifier(), ack=True)
    with pytest.raises(ModelError):
        check_modifier_usable(_noncommercial_modifier(), ack=False)


def test_a_commercial_modifier_never_needs_an_ack(monkeypatch):
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    for spec in MODIFIERS.values():
        check_modifier_usable(spec)
    for spec in VAES.values():
        check_modifier_usable(spec)


def test_the_gate_reads_the_same_environment_variable_as_the_model_gate(monkeypatch):
    """One gate, not two: an operator who acknowledged non-commercial use has
    acknowledged it for the whole request."""
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    assert config.ack_noncommercial() is False
    monkeypatch.setenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", "yes")
    assert config.ack_noncommercial() is True
    check_modifier_usable(_noncommercial_vae())


# -- resolution ------------------------------------------------------------

def test_resolve_modifier_looks_up_keys_and_aliases_case_insensitively():
    assert resolve_modifier("lcm-lora-sdxl") is MODIFIERS["lcm-lora-sdxl"]
    assert resolve_modifier("lcm-sdxl") is MODIFIERS["lcm-lora-sdxl"]
    assert resolve_modifier("LCM-LORA-SDXL") is MODIFIERS["lcm-lora-sdxl"]
    assert resolve_modifier("lightning-4") is MODIFIERS["sdxl-lightning-4step"]
    assert resolve_modifier("coloring-book") is MODIFIERS["colouring-book"]
    assert resolve_modifier("papercut") is MODIFIERS["papercut-sdxl"]


def test_none_and_empty_mean_no_modifier():
    """There is deliberately no default modifier: a default would silently change
    every existing request's output."""
    assert resolve_modifier(None) is None
    assert resolve_modifier("") is None
    assert resolve_vae(None) is None
    assert resolve_vae("   ") is None


def test_resolve_vae_looks_up_keys_and_aliases():
    assert resolve_vae("taesdxl") is VAES["taesdxl"]
    assert resolve_vae("fp16-fix") is VAES["sdxl-vae-fp16-fix"]
    assert resolve_vae("TAESDXL") is VAES["taesdxl"]


def test_an_unknown_modifier_names_the_ones_that_exist():
    with pytest.raises(ModelError) as caught:
        resolve_modifier("no-such-lora")
    message = str(caught.value)
    assert "no-such-lora" in message
    assert "lcm-lora-sdxl" in message
    assert caught.value.exit_code == 2


def test_an_unknown_vae_names_the_ones_that_exist():
    with pytest.raises(ModelError) as caught:
        resolve_vae("no-such-vae")
    assert "no-such-vae" in str(caught.value)
    assert "taesdxl" in str(caught.value)


# -- the API shapes --------------------------------------------------------

def test_as_dict_reports_a_modifiers_scheduler_and_weight_file():
    entry = as_dict(MODIFIERS["sdxl-lightning-4step"])
    assert entry["kind"] == "modifier"
    assert entry["weight_name"] == "sdxl_lightning_4step_lora.safetensors"
    assert entry["scheduler"] == "trailing-euler"
    assert entry["steps"] == 4
    assert entry["guidance"] == 0.0
    assert entry["targets"] == ["sdxl-1.0", "ssd-1b"]
    assert entry["commercial_ok"] is True


def test_as_dict_reports_a_vaes_tiny_flag():
    entry = as_dict(VAES["taesdxl"])
    assert entry["kind"] == "vae"
    assert entry["tiny"] is True
    assert "weight_name" not in entry
    assert entry["license"] == "MIT"


def test_as_dict_serialises_a_plain_style_spec_too():
    """Every field of a ModifierSpec reaches the API: a knob a client cannot see
    is a knob a client cannot use."""
    entry = as_dict(MODIFIERS["pixel-art-xl"])
    assert set(entry) == {"key", "repo_id", "targets", "license", "commercial_ok",
                          "repo_bytes", "aliases", "notes", "kind", "weight_name",
                          "steps", "guidance", "scheduler", "scale"}


def test_all_as_dict_returns_both_registries_under_separate_keys():
    payload = all_as_dict()
    assert set(payload) == {"modifiers", "vaes"}
    assert len(payload["modifiers"]) == len(MODIFIERS)
    assert len(payload["vaes"]) == len(VAES)
    # Sorted, so a client diffing two responses sees a real change rather than a
    # dict-ordering wobble.
    assert [e["key"] for e in payload["modifiers"]] == sorted(MODIFIERS)
    assert [e["key"] for e in payload["vaes"]] == sorted(VAES)


def test_the_modifiers_module_hardcodes_no_machine_path():
    """A path or host belonging to one machine goes stale the moment it moves."""
    import chopshop_flux.modifiers as module

    source = open(module.__file__, encoding="utf-8").read()
    assert "/home/" not in source
    assert "/Users/" not in source
    assert "monop" not in source
    assert "100.125" not in source
