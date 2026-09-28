"""The three new registry entries, and the fields they introduced.

test_models.py pins the original five and the rules that came with them. This
file pins what was added: Sana Sprint and SSD-1B, the ``guidance_embedded`` and
``resolution_binning`` flags, and the mirror note the studio's copy depends on.
"""

import pytest

from chopshop_flux import models as models_module
from chopshop_flux.models import (APACHE_2, DEFAULT_MODEL_KEY, REGISTRY,
                                  ModelError, as_dict, resolve, validate_size)

NEW_MODELS = ("sana-sprint-0.6b", "sana-sprint-1.6b", "ssd-1b")


def test_the_registry_has_eight_entries_and_the_default_is_unchanged():
    """The count is part of the contract: it is what a client's model picker
    renders and what the studio's hand-mirrored copy has to match."""
    assert len(REGISTRY) == 8
    assert set(REGISTRY) == {
        "klein-4b", "klein-4b-base", "sdxl-1.0", "sdxl-turbo", "sd-1.5",
        "sana-sprint-0.6b", "sana-sprint-1.6b", "ssd-1b",
    }
    assert DEFAULT_MODEL_KEY == "klein-4b"
    assert resolve(None).key == "klein-4b"


def test_the_five_original_entries_are_untouched():
    assert REGISTRY["klein-4b"].default_steps == 4
    assert REGISTRY["klein-4b"].default_guidance == 1.0
    assert REGISTRY["klein-4b-base"].default_steps == 28
    assert REGISTRY["sdxl-1.0"].default_steps == 30
    assert REGISTRY["sdxl-turbo"].default_guidance == 0.0
    assert REGISTRY["sd-1.5"].default_guidance == 7.5


def test_the_mirror_note_is_still_in_the_module_header():
    """chopshop-studio's ``app/models/flux_conf.rb`` transcribes this registry by
    hand and nothing syncs it. The note is the only warning a reader gets, so an
    edit that deletes it makes the studio drift in silence."""
    header = models_module.__doc__ or ""
    assert "chopshop-studio" in header
    assert "flux_conf.rb" in header
    assert "hand-mirror" in header.lower() or "hand-mirrored" in header.lower()


# -- sizes and rules -------------------------------------------------------

def test_the_sana_rows_use_the_32x_autoencoder_rules():
    """Their VAE is a 32x-downsampling AutoencoderDC, not an 8x AutoencoderKL,
    which is the whole reason for a multiple of 32 and a 512 floor."""
    for key in ("sana-sprint-0.6b", "sana-sprint-1.6b"):
        spec = REGISTRY[key]
        assert spec.dim_multiple == 32, key
        assert spec.min_dim == 512, key
        assert spec.max_pixels == 1024 * 1024, key


def test_the_sana_sizes_that_work_and_the_ones_that_cannot():
    spec = resolve("sana-sprint-0.6b")
    validate_size(spec, 512, 512)
    validate_size(spec, 1024, 1024)

    with pytest.raises(ModelError) as caught:
        validate_size(spec, 784, 784)          # 16 x 49, not a multiple of 32
    assert "multiple of 32" in str(caught.value)
    # 768 *is* a multiple of 32 (24 x 32), which is why the rule is stated as a
    # multiple rather than as "one of the sizes we happened to try".
    validate_size(spec, 768, 768)

    with pytest.raises(ModelError) as caught:
        validate_size(spec, 480, 512)          # below the 512 floor
    assert "at least 512" in str(caught.value)

    with pytest.raises(ModelError):
        validate_size(spec, 2048, 2048)        # 4 MP, over Sana's 1 MP cap


def test_the_sana_rows_are_registered_with_their_verified_pipelines():
    for key in ("sana-sprint-0.6b", "sana-sprint-1.6b"):
        spec = REGISTRY[key]
        assert spec.pipeline == "SanaSprintPipeline", key
        assert spec.edit_pipeline == "SanaSprintImg2ImgPipeline", key
        assert spec.default_steps == 2, key
        assert spec.default_guidance == 4.5, key
        assert spec.distilled is True, key
        assert spec.gated is False, key


def test_the_sana_rows_have_no_negative_prompt_parameter():
    """Verified by inspecting __call__'s signature: there is nothing to wire, so
    the service must warn rather than accept the parameter."""
    for key in ("sana-sprint-0.6b", "sana-sprint-1.6b"):
        assert REGISTRY[key].negative_prompt is False, key
        assert REGISTRY[key].img2img_strength is True, key


def test_the_sana_guidance_is_embedded_so_the_number_is_honoured():
    """Distilled but NOT CFG-distilled: SanaSprintPipeline feeds guidance_scale to
    the transformer as a guidance embedding, so warning that it is ignored would
    be false. This flag is what separates it from klein."""
    for key in ("sana-sprint-0.6b", "sana-sprint-1.6b"):
        assert REGISTRY[key].guidance_embedded is True, key
    assert REGISTRY["klein-4b"].guidance_embedded is False
    assert REGISTRY["sdxl-turbo"].guidance_embedded is False
    assert REGISTRY["ssd-1b"].guidance_embedded is False


def test_the_sana_rows_declare_their_resolution_binning():
    """use_resolution_binning defaults to True on this pipeline, so a requested
    size can be silently re-binned. The flag is what makes the service say so."""
    for key in ("sana-sprint-0.6b", "sana-sprint-1.6b"):
        assert REGISTRY[key].resolution_binning is True, key
    assert REGISTRY["klein-4b"].resolution_binning is False
    assert REGISTRY["sdxl-1.0"].resolution_binning is False


def test_the_sana_rows_carry_the_gemma_pass_through_caveat():
    """Apache-2.0 weights, Gemma-2 text encoder: a licence that rides along."""
    for key in ("sana-sprint-0.6b", "sana-sprint-1.6b"):
        notes = REGISTRY[key].notes
        assert "Gemma" in notes, key
        assert "Terms of Use" in notes, key


def test_the_measured_sana_row_reports_both_of_its_call_timings():
    """"~40s first, ~2.5s after" are both true, and a note that quotes only one
    of them reads as the whole story when it is not."""
    notes = REGISTRY["sana-sprint-0.6b"].notes
    assert "40" in notes and "2.5" in notes
    assert "first" in notes.lower()


def test_the_unmeasured_sana_row_says_so():
    assert "NOT run on this card" in REGISTRY["sana-sprint-1.6b"].notes


def test_the_sana_rows_use_their_own_measured_download_sizes():
    assert REGISTRY["sana-sprint-0.6b"].repo_bytes == 7.66e9
    assert REGISTRY["sana-sprint-1.6b"].repo_bytes == 9.70e9
    assert REGISTRY["sana-sprint-0.6b"].params_b == 0.6
    assert REGISTRY["sana-sprint-1.6b"].params_b == 1.6


# -- SSD-1B ---------------------------------------------------------------

def test_ssd_1b_is_registered_with_sdxls_pipeline_and_its_own_defaults():
    spec = resolve("ssd-1b")
    assert spec.repo_id == "segmind/SSD-1B"
    assert spec.license == APACHE_2
    assert spec.commercial_ok is True
    assert spec.gated is False
    assert spec.pipeline == "StableDiffusionXLPipeline"
    assert spec.edit_pipeline == "StableDiffusionXLImg2ImgPipeline"
    assert spec.dim_multiple == 8
    assert spec.min_dim == 128
    assert spec.max_pixels == 2 * 1024 * 1024
    assert spec.negative_prompt is True
    assert spec.img2img_strength is True
    assert spec.default_steps == 25
    assert spec.default_guidance == 7.5
    assert spec.params_b == 1.3


def test_ssd_1b_records_that_its_schedule_was_measured():
    """The card states neither a step count nor a guidance scale, so these
    started as the SDXL entry's numbers -- and then they were RUN on this card at
    1024x1024, which is what turns them into a measurement. The note has to say
    that, because the opposite claim (an estimate presented as a fact) is the
    thing this test used to pin."""
    notes = REGISTRY["ssd-1b"].notes
    assert "MEASURED" in notes.upper()
    assert "6.1s" in notes and "4.4s" in notes, \
        "the measured timings are the evidence; without them 'measured' is a word"
    # The vram/byte figures are still estimates and must stay labelled as such --
    # claiming a measurement for the numbers that were NOT run is the same fault
    # in the other direction.
    assert "ESTIMATES" in notes.upper()


def test_ssd_1b_is_not_a_distilled_checkpoint():
    """The Segmind name says 'distilled' because the checkpoint was pruned from
    SDXL (251k steps); that is not a few-step inference schedule. The registry
    distinguishes them, and an earlier note conflated the two."""
    spec = resolve("ssd-1b")
    assert spec.distilled is False
    assert spec.guidance_embedded is False, \
        "distilled rows with guidance embeddings are the Sana case, not this one"
    assert spec.default_guidance > 1.0, \
        "a CFG model runs at a real guidance; a distilled one runs at ~1.0"


def test_ssd_1b_uses_the_sdxl_resolution_rules():
    spec = resolve("ssd-1b")
    validate_size(spec, 128, 128)
    validate_size(spec, 1000, 1024)          # a multiple of 8, not of 16
    with pytest.raises(ModelError) as caught:
        validate_size(spec, 1004, 1024)
    assert "multiple of 8" in str(caught.value)
    with pytest.raises(ModelError):
        validate_size(spec, 2048, 2048)      # over the 2 MP cap
    with pytest.raises(ModelError) as caught:
        validate_size(spec, 64, 1024)
    assert "at least 128" in str(caught.value)


# -- the fields reach the API ---------------------------------------------

def test_as_dict_reports_the_two_new_flags():
    sana = as_dict(resolve("sana-sprint-0.6b"))
    assert sana["guidance_embedded"] is True
    assert sana["resolution_binning"] is True
    klein = as_dict(resolve("klein-4b"))
    assert klein["guidance_embedded"] is False
    assert klein["resolution_binning"] is False
    assert klein["min_dim"] == 64


def test_every_entry_keeps_the_family_fields_coherent():
    """The rules the whole service depends on holding together."""
    for spec in REGISTRY.values():
        assert spec.layout == "diffusers", spec.key
        assert spec.default_steps >= 1, spec.key
        assert spec.default_guidance >= 0, spec.key
        assert spec.pipeline, spec.key
        assert spec.dim_multiple >= 1, spec.key
        assert spec.min_dim >= spec.dim_multiple, spec.key
        assert spec.max_pixels >= spec.min_dim ** 2, spec.key
        assert spec.pipeline != (spec.edit_pipeline or ""), spec.key


def test_the_new_aliases_resolve():
    assert resolve("sana").key == "sana-sprint-0.6b"
    assert resolve("sana-sprint").key == "sana-sprint-0.6b"
    assert resolve("sana-1.6b").key == "sana-sprint-1.6b"
    assert resolve("SANA-SPRINT-0.6B").key == "sana-sprint-0.6b"
    assert resolve("ssd").key == "ssd-1b"
    assert resolve("ssd1b").key == "ssd-1b"


def test_no_new_alias_collides_with_an_existing_key():
    """An alias that resolves to the wrong model is worse than no alias."""
    for spec in REGISTRY.values():
        for alias in spec.aliases:
            resolved = resolve(alias)
            if alias != spec.key:
                assert resolved.key == spec.key, (spec.key, alias, resolved.key)


def test_the_new_models_do_not_need_an_acknowledgement(monkeypatch):
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    from chopshop_flux.models import check_usable

    for key in NEW_MODELS:
        check_usable(resolve(key))
