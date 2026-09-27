"""The registry's facts, and the rules that depend on them.

These are the assertions that stop a licence or a resolution rule from being
"fixed" later by someone who did not know why it was there.
"""

import pytest

from chopshop_flux import config
from chopshop_flux.models import (DEFAULT_MODEL_KEY, REGISTRY, UNLOADABLE,
                                  ModelError, check_usable, resolve, validate_size)


def test_the_default_model_is_the_commercially_usable_one():
    """The default must be the Apache 2.0 model.

    If the default were the 9B, every casual use of this service would be
    non-commercial use of a non-commercial model, and the licence problem would
    be created by the default rather than chosen by a person.
    """
    spec = resolve(None)
    assert spec.key == DEFAULT_MODEL_KEY == "klein-4b"
    assert spec.commercial_ok is True
    assert spec.license == "Apache-2.0"


def test_the_9b_is_marked_non_commercial_and_needs_an_explicit_acknowledgement():
    nine = resolve("klein-9b")
    assert nine.commercial_ok is False
    assert "Non-Commercial" in nine.license

    # Refused by default...
    with pytest.raises(ModelError) as caught:
        check_usable(nine, ack=False)
    assert "non-commercial" in str(caught.value).lower()
    assert "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL" in str(caught.value)

    # ...allowed once acknowledged. The point is that it cannot happen by
    # accident, not that it cannot happen.
    check_usable(nine, ack=True)


def test_the_acknowledgement_can_come_from_the_environment(monkeypatch):
    nine = resolve("9b")
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    with pytest.raises(ModelError):
        check_usable(nine)
    monkeypatch.setenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", "1")
    check_usable(nine)


def test_an_apache_model_never_needs_an_acknowledgement(monkeypatch):
    monkeypatch.delenv("CHOPSHOP_FLUX_ACK_NONCOMMERCIAL", raising=False)
    check_usable(resolve("klein-4b"))
    check_usable(resolve("klein-4b-base"))


def test_aliases_resolve_and_are_case_insensitive():
    assert resolve("4b").key == "klein-4b"
    assert resolve("klein").key == "klein-4b"
    assert resolve("KLEIN-4B").key == "klein-4b"
    assert resolve("9B").key == "klein-9b"


def test_an_unknown_model_names_the_ones_that_exist():
    with pytest.raises(ModelError) as caught:
        resolve("klein-40b")
    message = str(caught.value)
    assert "klein-40b" in message
    assert "klein-4b" in message


def test_the_single_file_quantised_builds_are_refused_with_the_reason():
    """They exist on HF and look attractive; they cannot be loaded.

    Both are single-file builds with no model_index.json, so from_pretrained
    cannot load them. Refusing them with the reason is the difference between a
    five-second answer and an afternoon.
    """
    for key in ("klein-9b-fp8", "klein-9b-nvfp4"):
        assert key in UNLOADABLE
        with pytest.raises(ModelError) as caught:
            resolve(key)
        assert "model_index.json" in str(caught.value) or "NVIDIA" in str(caught.value)


def test_every_registered_model_has_a_diffusers_layout():
    """A model in the registry must be loadable by from_pretrained."""
    for spec in REGISTRY.values():
        assert spec.layout == "diffusers", spec.key
        assert spec.default_steps >= 1
        assert spec.default_guidance > 0


def test_the_distilled_models_use_four_steps_at_guidance_one():
    """The registered defaults are the distilled schedule, not the class default.

    Flux2KleinPipeline.__call__ defaults to 50 steps and guidance 4.0 because
    that is what a *base* model wants. Running a distilled checkpoint at those
    values is not "using the defaults", it is running the wrong schedule.
    """
    for key in ("klein-4b", "klein-9b"):
        spec = REGISTRY[key]
        assert spec.distilled is True
        assert spec.default_steps == 4
        assert spec.default_guidance == 1.0


def test_the_base_model_is_the_one_that_allows_real_guidance():
    base = resolve("klein-4b-base")
    assert base.distilled is False
    assert base.default_guidance > 1.0
    assert base.commercial_ok is True


def test_the_9b_is_flagged_as_gated_because_huggingface_gates_it():
    assert resolve("klein-9b").gated is True
    assert resolve("klein-4b").gated is False


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
    entry = as_dict(resolve("klein-9b"))
    assert entry["commercial_ok"] is False
    assert entry["license"] == "FLUX Non-Commercial License v2.1"
    assert entry["default"] is False
