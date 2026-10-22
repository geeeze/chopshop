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


def test_the_registry_has_eleven_entries_and_the_default_is_unchanged():
    """The count is part of the contract: it is what a client's model picker
    renders and what the studio's hand-mirrored copy has to match."""
    assert len(REGISTRY) == 11
    assert set(REGISTRY) == {
        "klein-4b", "klein-4b-base", "sdxl-1.0", "sdxl-turbo", "sd-1.5",
        "sana-sprint-0.6b", "sana-sprint-1.6b", "ssd-1b", "z-image-turbo",
        "ming-image-0.1-design", "ming-image-0.1-design-layer",
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
    """The rules the whole service depends on holding together.

    Remote entries (backend='novita') have no diffusers layout or pipeline
    class — that is correct. They are checked separately in
    test_models_remote.py.
    """
    for spec in REGISTRY.values():
        if spec.backend != "local":
            continue
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


# -- Z-Image-Turbo ---------------------------------------------------------

def test_z_image_turbo_is_registered_with_its_own_pipeline_and_schedule():
    spec = resolve("z-image-turbo")
    assert spec.repo_id == "Tongyi-MAI/Z-Image-Turbo"
    assert spec.license == APACHE_2
    assert spec.commercial_ok is True
    assert spec.gated is False
    assert spec.params_b == 6
    assert spec.layout == "diffusers"
    assert spec.pipeline == "ZImagePipeline"
    assert spec.edit_pipeline == "ZImageImg2ImgPipeline"
    assert spec.distilled is True


def test_z_image_turbos_schedule_is_not_the_pipeline_classs_default():
    """ZImagePipeline defaults to 50 steps / guidance 5.0 — its BASE model's
    schedule. An entry that let those through would run the 8-NFE Turbo
    checkpoint on the wrong one, which is the same trap Flux2KleinPipeline's
    50 / 4.0 sets in the klein family."""
    spec = resolve("z-image-turbo")
    assert (spec.default_steps, spec.default_guidance) == (9, 0.0)
    assert spec.default_steps != 50 and spec.default_guidance != 5.0


def test_z_image_turbos_dim_multiple_is_the_classs_own_rule():
    """ZImagePipeline.__call__ raises unless each side is divisible by
    ``vae_scale_factor * 2``, and vae_scale_factor is diffusers' own
    ``2 ** (len(vae.config.block_out_channels) - 1)`` = 8 for this repo's 4-entry
    AutoencoderKL, so 16 is READ OFF THE CLASS rather than copied from klein
    (16, different reason) or SDXL (8)."""
    spec = resolve("z-image-turbo")
    assert spec.dim_multiple == 16
    validate_size(spec, 512, 1024)
    validate_size(spec, 1024, 1024)
    with pytest.raises(ModelError) as caught:
        validate_size(spec, 1004, 1024)          # a multiple of 4, not of 16
    assert "multiple of 16" in str(caught.value)
    with pytest.raises(ModelError) as caught:
        validate_size(spec, 64, 1024)            # under the policy floor
    assert "at least 128" in str(caught.value)
    with pytest.raises(ModelError):
        validate_size(spec, 2048, 2048)          # over the 1 MP policy cap


def test_z_image_turbos_flags_are_what_its_class_actually_has():
    """Read from ZImagePipeline.__call__'s own signature: negative_prompt IS a
    parameter (so the engine passes it rather than warning), there is no
    image=/strength= there (the family's separate ZImageImg2ImgPipeline carries
    those), no use_resolution_binning (so nothing is silently re-binned), and a
    single image only — the multi-reference List[PIL] convention is klein's."""
    spec = resolve("z-image-turbo")
    assert spec.negative_prompt is True
    assert spec.img2img_strength is True
    assert spec.resolution_binning is False
    assert spec.multi_reference is False


def test_z_image_turbos_guidance_is_honoured_so_it_is_not_called_ignored():
    """ZImagePipeline.do_classifier_free_guidance is ``guidance_scale > 0``, so
    above 0 a REAL CFG pass runs even though the checkpoint is 8-NFE distilled.
    The service's "guidance is ignored" warning would then be false, and
    ``guidance_embedded`` is the flag whose whole effect is to suppress it — so
    the note has to carry the measurement that shows the number matters."""
    spec = resolve("z-image-turbo")
    assert spec.guidance_embedded is True, \
        "a distilled checkpoint that DOES act on guidance must not warn it ignores it"
    assert "do_classifier_free_guidance" in spec.notes
    assert "mean absolute pixel difference" in spec.notes


def test_z_image_turbos_note_quotes_cold_and_warm_together():
    """Both numbers are true and one alone reads as the whole story — the same
    rule the Sana row is held to. The load time is quoted with them because
    'VERIFIED RUNNING' is a claim about the machine, not about the card."""
    notes = resolve("z-image-turbo").notes
    assert "55.8s" in notes, "the load is part of the measurement"
    assert "41.3s" in notes and "17.0s" in notes, \
        "the cold and warm generate times are the evidence for 'VERIFIED RUNNING'"
    assert "first" in notes.lower()
    assert "MEASURED" in notes.upper()
    assert "ESTIMATE" in notes.upper(), \
        "the policy floor and cap were not measured and must say so"
    assert "non-blank" in notes.lower()


def test_z_image_turbos_note_quotes_the_guidance_difference_it_measured():
    """A sentence that says guidance 'is honoured' is an opinion; the number is
    the measurement (klein-4b-base's 34.38 is the same claim in the klein row)."""
    notes = resolve("z-image-turbo").notes
    assert "mean absolute pixel difference of 25.11" in notes
    assert "guidance 0.0 vs 4.0" in notes


def test_z_image_turbos_note_records_that_the_edit_class_was_run():
    """edit_pipeline is only worth naming if the class was exercised: the entry
    claims the family's img2img class answers /edit, and the note carries the
    run that shows it (49.3s, non-blank, at the class's own strength 0.6)."""
    notes = resolve("z-image-turbo").notes
    assert "ZImageImg2ImgPipeline" in notes
    assert "49.3s" in notes
    assert "86281" in notes


def test_z_image_turbo_declares_its_download_and_its_derived_module_size():
    spec = resolve("z-image-turbo")
    assert spec.repo_bytes == 32.8e9
    # The fp32 download is the disk figure; the bf16 module is the card figure.
    assert spec.vram_gb < spec.repo_bytes / 1e9, \
        "the resident module is roughly half the fp32 download, not the download"
    assert "fp32" in spec.notes


def test_z_image_turbo_is_not_the_default_and_needs_no_acknowledgement(monkeypatch):
    """Apache-2.0: it must never become the default by accident, and it must
    load with no acknowledgement set."""
    import os
    from chopshop_flux.models import check_usable

    spec = resolve("z-image-turbo")
    assert spec.is_default is False
    assert DEFAULT_MODEL_KEY == "klein-4b"
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    check_usable(spec)
    assert os.environ.get("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL") is None


def test_the_z_image_aliases_resolve():
    assert resolve("zimage").key == "z-image-turbo"
    assert resolve("z-image").key == "z-image-turbo"
    assert resolve("ZIMAGE-TURBO").key == "z-image-turbo"


def test_as_dict_reports_z_image_turbo_without_changing_the_shape():
    """/models keeps its shape: the same keys on every entry, three arrays on the
    payload — a client that reads the existing ones keeps working."""
    entry = as_dict(resolve("z-image-turbo"))
    assert set(entry) == set(as_dict(resolve("klein-4b")))
    assert entry["pipeline"] == "ZImagePipeline"
    assert entry["edit_pipeline"] == "ZImageImg2ImgPipeline"
    assert entry["dim_multiple"] == 16
    assert entry["guidance_embedded"] is True
    assert entry["resolution_binning"] is False
    assert entry["default"] is False


def test_the_registry_still_has_no_machine_of_its_own():
    """The new entry must not smuggle in a host, a path or an address."""
    import chopshop_flux.models as module

    source = open(module.__file__, encoding="utf-8").read()
    for forbidden in ("/home/", "/Users/", "monop", "100.125", "127.0.0.1", "8795"):
        assert forbidden not in source, forbidden


def test_the_refused_candidates_are_recorded_in_the_docs():
    """Silence is a failed task: every candidate this wave did not register has to
    be in docs/MODELS.md §5 with a reason, so the next person does not re-derive
    it. This pins the doc against a later edit that quietly drops one."""
    import os

    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        "docs", "MODELS.md")
    text = open(path, encoding="utf-8").read()
    section = text.split("## 5.", 1)[1]
    for repo_id in ("lodestones/Chroma1-HD", "lodestones/Chroma1-Flash",
                    "Qwen/Qwen-Image-2.1", "black-forest-labs/FLUX.2-klein-9B",
                    "stabilityai/stable-diffusion-3.5-medium"):
        assert repo_id in section, repo_id
    assert "refused" in section.lower()
    assert "Tongyi-MAI/Z-Image-Turbo" in section

