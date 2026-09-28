"""The registry's facts, and the rules that depend on them.

These are the assertions that stop a licence or a resolution rule from being
"fixed" later by someone who did not know why it was there.
"""

import pytest

from chopshop_flux import config
from chopshop_flux.models import (DEFAULT_MODEL_KEY, REGISTRY,
                                  ModelError, check_usable, resolve, validate_size)


def test_the_default_model_is_the_commercially_usable_one():
    """The default must be the Apache 2.0 model.

    If the default were a non-commercial model, every casual use of this service
    would be non-commercial use, and the licence problem would be created by the
    default rather than chosen by a person.
    """
    spec = resolve(None)
    assert spec.key == DEFAULT_MODEL_KEY == "klein-4b"
    assert spec.commercial_ok is True
    assert spec.license == "Apache-2.0"


def test_the_acknowledgement_can_come_from_the_environment(monkeypatch):
    turbo = resolve("sdxl-turbo")
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    with pytest.raises(ModelError):
        check_usable(turbo)
    monkeypatch.setenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", "1")
    check_usable(turbo)


def test_an_apache_model_never_needs_an_acknowledgement(monkeypatch):
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    check_usable(resolve("klein-4b"))
    check_usable(resolve("klein-4b-base"))


def test_aliases_resolve_and_are_case_insensitive():
    assert resolve("4b").key == "klein-4b"
    assert resolve("klein").key == "klein-4b"
    assert resolve("KLEIN-4B").key == "klein-4b"


def test_the_9b_aliases_no_longer_resolve():
    """The 9B is gone from the registry, so nothing may still answer to it."""
    for gone in ("9b", "9B", "klein9b", "klein-9B"):
        with pytest.raises(ModelError) as caught:
            resolve(gone)
        assert "9b" in str(caught.value).lower()


def test_an_unknown_model_names_the_ones_that_exist():
    with pytest.raises(ModelError) as caught:
        resolve("klein-40b")
    message = str(caught.value)
    assert "klein-40b" in message
    assert "klein-4b" in message


def test_every_registered_model_has_a_diffusers_layout():
    """A model in the registry must be loadable by from_pretrained, and its
    family-specific rules must be internally coherent."""
    for spec in REGISTRY.values():
        assert spec.layout == "diffusers", spec.key
        assert spec.default_steps >= 1
        # >= 0, not > 0: sdxl-turbo's distilled schedule is 2 steps at guidance 0.
        assert spec.default_guidance >= 0, spec.key
        assert spec.pipeline, spec.key
        assert spec.dim_multiple >= 1, spec.key
        assert spec.min_dim >= spec.dim_multiple, spec.key
        assert spec.max_pixels >= spec.min_dim ** 2, spec.key


def test_the_distilled_checkpoint_uses_four_steps_at_guidance_one():
    """The registered defaults are the distilled schedule, not the class default.

    Flux2KleinPipeline.__call__ defaults to 50 steps and guidance 4.0 because
    that is what a *base* model wants. Running a distilled checkpoint at those
    values is not "using the defaults", it is running the wrong schedule.
    """
    spec = REGISTRY["klein-4b"]
    assert spec.distilled is True
    assert spec.default_steps == 4
    assert spec.default_guidance == 1.0


def test_the_base_model_is_the_one_that_allows_real_guidance():
    base = resolve("klein-4b-base")
    assert base.distilled is False
    assert base.default_guidance > 1.0
    assert base.commercial_ok is True


def test_no_registered_model_is_gated():
    """Nothing left in the registry needs an HF token to fetch.

    The flag is still reported over the API, because it is a fact about a model
    rather than about any one entry; today every entry answers false.
    """
    assert not any(spec.gated for spec in REGISTRY.values())


# -- resolution rules ------------------------------------------------------

def test_dimensions_must_be_multiples_of_sixteen():
    spec = resolve("klein-4b")
    with pytest.raises(ModelError) as caught:
        validate_size(spec, 1000, 1000)
    assert "multiple of 16" in str(caught.value)
    validate_size(spec, 1024, 1024)
    validate_size(spec, 64, 64)


def test_dimensions_have_a_floor():
    spec = resolve("klein-4b")
    with pytest.raises(ModelError) as caught:
        validate_size(spec, 48, 1024)
    assert "at least 64" in str(caught.value)


def test_the_pixel_cap_is_enforced_and_is_configurable():
    """The cap is inclusive: 2048x2048 IS 4 MP exactly (4194304 px).

    Both sides of the boundary, because the first version of this test asserted
    2048x2048 was over the cap and it is not — 4 * 1024 * 1024 is exactly
    2048 * 2048.
    """
    spec = resolve("klein-4b")
    validate_size(spec, 2048, 2048)              # exactly at the cap: allowed

    # One row of 16 past it: over.
    with pytest.raises(ModelError) as caught:
        validate_size(spec, 2048, 2064)
    assert "over the" in str(caught.value)

    validate_size(spec, 2048, 2064, max_pixels=8 * 1024 * 1024)


def test_a_non_integer_dimension_is_a_caller_error_not_a_crash():
    """A float width is what a JSON body with 1024.0 in it produces."""
    spec = resolve("klein-4b")
    with pytest.raises(ModelError) as caught:
        validate_size(spec, 1024.0, 1024)  # type: ignore[arg-type]
    assert "integer" in str(caught.value)


def test_the_registry_reports_licences_over_the_api():
    from chopshop_flux.models import as_dict
    entry = as_dict(resolve("sdxl-turbo"))
    assert entry["commercial_ok"] is False
    assert entry["license"] == "Stability AI Non-Commercial Research Community License"
    assert entry["default"] is False


# -- the SDXL and SD 1.5 families ------------------------------------------
#
# Licences below are the human-readable names on the model cards / LICENSE
# files, verified against the HuggingFace API (cardData.license is only a slug:
# ``openrail++``, ``other``, ``creativeml-openrail-m``).

def test_sdxl_1_0_is_registered_with_its_verified_licence_and_pipeline():
    spec = resolve("sdxl-1.0")
    assert spec.repo_id == "stabilityai/stable-diffusion-xl-base-1.0"
    assert spec.license == "CreativeML Open RAIL++-M License"
    assert spec.commercial_ok is True
    assert spec.gated is False
    assert spec.pipeline == "StableDiffusionXLPipeline"
    assert spec.dim_multiple == 8
    assert spec.min_dim == 128
    assert spec.max_pixels == 2 * 1024 * 1024
    assert spec.negative_prompt is True
    assert spec.img2img_strength is True
    assert spec.default_steps == 30
    assert spec.default_guidance == 5.0


def test_sdxl_turbo_is_the_fast_non_commercial_one():
    spec = resolve("sdxl-turbo")
    assert spec.repo_id == "stabilityai/sdxl-turbo"
    assert spec.license == "Stability AI Non-Commercial Research Community License"
    assert spec.commercial_ok is False
    assert spec.gated is False
    assert spec.distilled is True
    assert spec.default_steps == 2
    assert spec.default_guidance == 0.0
    assert spec.pipeline == "StableDiffusionXLPipeline"
    assert spec.dim_multiple == 8
    assert spec.min_dim == 128
    assert spec.max_pixels == 1024 * 1024
    assert spec.negative_prompt is True
    assert spec.img2img_strength is True


def test_sd_1_5_is_registered_with_its_verified_licence_and_pipeline():
    spec = resolve("sd-1.5")
    assert spec.repo_id == "stable-diffusion-v1-5/stable-diffusion-v1-5"
    assert spec.license == "CreativeML Open RAIL-M License"
    assert spec.commercial_ok is True
    assert spec.gated is False
    assert spec.pipeline == "StableDiffusionPipeline"
    assert spec.dim_multiple == 8
    assert spec.min_dim == 128
    assert spec.max_pixels == 1024 * 1024
    assert spec.negative_prompt is True
    assert spec.img2img_strength is True
    assert spec.default_steps == 30
    assert spec.default_guidance == 7.5


def test_sdxl_turbo_needs_an_ack_but_sdxl_1_0_and_sd_1_5_do_not(monkeypatch):
    """The licence gate holds for the new non-commercial model too."""
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    with pytest.raises(ModelError) as caught:
        check_usable(resolve("sdxl-turbo"))
    assert "non-commercial" in str(caught.value).lower()
    assert "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL" in str(caught.value)

    check_usable(resolve("sdxl-turbo"), ack=True)
    # The two commercial ones never need an acknowledgement.
    check_usable(resolve("sdxl-1.0"))
    check_usable(resolve("sd-1.5"))


def test_the_new_aliases_resolve():
    assert resolve("sdxl").key == "sdxl-1.0"
    assert resolve("xl").key == "sdxl-1.0"
    assert resolve("sdxl-base").key == "sdxl-1.0"
    assert resolve("turbo").key == "sdxl-turbo"
    assert resolve("SDXL-TURBO").key == "sdxl-turbo"
    assert resolve("sd15").key == "sd-1.5"
    assert resolve("sd1.5").key == "sd-1.5"
    assert resolve("sd").key == "sd-1.5"


def test_the_klein_entries_keep_the_default_family_fields():
    """The defaults reproduce klein's old behaviour: an entry that does not name
    the new fields must still be multiple-of-16, floor 64, 4 MP, image= only."""
    for key in ("klein-4b", "klein-4b-base"):
        spec = REGISTRY[key]
        assert spec.pipeline == "Flux2KleinPipeline", key
        assert spec.edit_pipeline is None, key
        assert spec.dim_multiple == 16, key
        assert spec.min_dim == 64, key
        assert spec.max_pixels == 4 * 1024 * 1024, key
        assert spec.negative_prompt is False, key
        assert spec.img2img_strength is False, key


def test_the_sd_families_name_their_edit_pipeline():
    """SDXL and SD 1.5 split text-to-image and image-to-image across two diffusers
    classes, so each names the img2img one — without it, a reference-bearing
    request would call the txt2img pipeline with image=/strength= and raise."""
    assert resolve("sdxl-1.0").edit_pipeline == "StableDiffusionXLImg2ImgPipeline"
    assert resolve("sdxl-turbo").edit_pipeline == "StableDiffusionXLImg2ImgPipeline"
    assert resolve("sd-1.5").edit_pipeline == "StableDiffusionImg2ImgPipeline"


def test_the_sd_families_use_their_own_resolution_rules():
    """dim_multiple/min_dim/max_pixels come from the spec, not global constants."""
    spec = resolve("sdxl-1.0")
    validate_size(spec, 1024, 1024)              # multiple of 8, over the 128 floor
    validate_size(spec, 128, 128)

    with pytest.raises(ModelError) as caught:
        validate_size(spec, 1004, 1024)          # not a multiple of 8
    assert "multiple of 8" in str(caught.value)

    with pytest.raises(ModelError) as caught:
        validate_size(spec, 64, 1024)            # below the 128 floor
    assert "at least 128" in str(caught.value)

    with pytest.raises(ModelError) as caught:
        validate_size(spec, 2048, 2048)          # 4 MP, over SDXL's 2 MP cap
    assert "over the" in str(caught.value)


def test_sd_1_5_caps_at_one_megapixel():
    spec = resolve("sd-1.5")
    validate_size(spec, 1024, 1024)
    with pytest.raises(ModelError):
        validate_size(spec, 1536, 1024)


def test_the_new_models_say_their_sizes_are_estimates():
    """repo_bytes/vram_gb for the new models are heuristics, and the notes say so
    rather than implying a measurement nobody took."""
    for key in ("sdxl-1.0", "sdxl-turbo", "sd-1.5"):
        assert "ESTIMATE" in REGISTRY[key].notes.upper(), key


def test_as_dict_reports_the_family_fields():
    from chopshop_flux.models import as_dict
    entry = as_dict(resolve("sdxl-1.0"))
    assert entry["pipeline"] == "StableDiffusionXLPipeline"
    assert entry["dim_multiple"] == 8
    assert entry["min_dim"] == 128
    assert entry["max_pixels"] == 2 * 1024 * 1024
    assert entry["negative_prompt"] is True
    assert entry["img2img_strength"] is True
    klein = as_dict(resolve("klein-4b"))
    assert klein["pipeline"] == "Flux2KleinPipeline"
    assert klein["negative_prompt"] is False
