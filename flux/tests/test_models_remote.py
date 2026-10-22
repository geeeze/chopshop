"""The novita remote backend registry entries, and the ``backend`` field.

test_models.py and test_models_new.py pin the nine local diffusers entries.
This file pins what the remote foundation adds: the ``backend`` field on
ModelSpec and the two hosted entries that set it.
"""

from chopshop_flux.models import REGISTRY, ModelSpec, as_dict, resolve


def _local_spec():
    """A minimal local spec, to pin the default."""
    return ModelSpec(
        key="x", repo_id="y", params_b=1, license="l",
        commercial_ok=True, vram_gb=1, repo_bytes=1,
        layout="diffusers", default_steps=1, default_guidance=1.0,
        distilled=False,
    )


def test_backend_defaults_to_local():
    assert _local_spec().backend == "local"


def test_every_existing_entry_is_local():
    for key in ("klein-4b", "klein-4b-base", "sdxl-1.0", "sdxl-turbo",
                "sd-1.5", "sana-sprint-0.6b", "sana-sprint-1.6b", "ssd-1b",
                "z-image-turbo"):
        assert REGISTRY[key].backend == "local", key


def test_the_design_model_is_registered_as_remote():
    spec = resolve("ming-image-0.1-design")
    assert spec.backend == "novita"
    assert spec.layout == "remote"


def test_the_layer_model_is_registered_as_remote():
    spec = resolve("ming-image-0.1-design-layer")
    assert spec.backend == "novita"
    assert spec.layout == "remote"


def test_the_remote_entries_say_their_facts_are_unverified():
    for key in ("ming-image-0.1-design", "ming-image-0.1-design-layer"):
        notes = REGISTRY[key].notes.upper()
        assert "UNVERIFIED" in notes, key


def test_the_remote_entries_have_no_local_footprint():
    for key in ("ming-image-0.1-design", "ming-image-0.1-design-layer"):
        spec = REGISTRY[key]
        assert spec.vram_gb == 0.0, key
        assert spec.repo_bytes == 0.0, key


def test_as_dict_reports_the_backend():
    entry = as_dict(resolve("ming-image-0.1-design"))
    assert entry["backend"] == "novita"
    local = as_dict(resolve("klein-4b"))
    assert local["backend"] == "local"


def test_the_remote_models_are_not_the_default():
    assert resolve("ming-image-0.1-design").is_default is False
    assert resolve("ming-image-0.1-design-layer").is_default is False
