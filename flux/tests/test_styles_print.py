"""The print-oriented styles, and the compatibility of the two optional fields.

The original three styles are pinned by test_styles.py. This file covers what was
added: six styles whose suffixes exist to remove what a tracer cannot follow, and
the optional ``model``/``modifiers`` suggestions that must stay optional — a
style with no opinion must not be given one by this code.
"""

import json

import pytest

from chopshop_flux.models import ModelError
from chopshop_flux.modifiers import resolve_modifier
from chopshop_flux.styles import (BUILTIN_STYLES, DEFAULT_STYLES_PATH,
                                  apply_style, load_styles, style_recipe,
                                  style_suggestions)

PRINT_STYLES = ("logo-mark", "line-art", "flat-vector", "sticker",
                "colouring-book", "pixel-art")
ORIGINAL_STYLES = ("flat-poster", "mono-line", "photo-halftone")

# Words a style suffix must contain if it is steering a generation toward
# something traceable. Not a style opinion: gradients and antialiased edges are
# the two things that make a trace produce hundreds of near-identical shapes.
TRACE_WORDS = ("no gradient", "hard")


def test_the_original_three_styles_are_untouched():
    for name in ORIGINAL_STYLES:
        assert name in BUILTIN_STYLES
    assert BUILTIN_STYLES["flat-poster"]["trace_preset"] == "poster"
    assert BUILTIN_STYLES["mono-line"]["trace_preset"] == "bw"
    assert BUILTIN_STYLES["photo-halftone"]["trace_preset"] == "photo"


def test_the_six_print_styles_are_registered_with_a_preset():
    for name in PRINT_STYLES:
        assert name in BUILTIN_STYLES, name
        assert BUILTIN_STYLES[name]["trace_preset"] in ("poster", "bw"), name
        assert BUILTIN_STYLES[name]["prompt_suffix"].startswith(","), name
    assert set(PRINT_STYLES) <= set(load_styles())


def test_every_print_style_asks_for_flat_regions_and_no_gradients():
    for name in PRINT_STYLES:
        suffix = BUILTIN_STYLES[name]["prompt_suffix"].lower()
        assert "gradient" in suffix, name
        assert any(word in suffix for word in TRACE_WORDS), name


def test_the_print_styles_are_bundled_in_the_json_file_too():
    """The file is merged over the built-ins, so the two must agree — otherwise
    which suffix you get depends on whether a file happened to be readable."""
    with open(DEFAULT_STYLES_PATH, encoding="utf-8") as handle:
        payload = json.load(handle)
    for name in PRINT_STYLES:
        assert name in payload, name
        assert payload[name]["prompt_suffix"] == BUILTIN_STYLES[name]["prompt_suffix"]
        assert payload[name]["trace_preset"] == BUILTIN_STYLES[name]["trace_preset"]


def test_apply_style_returns_the_two_values_it_always_did():
    """The existing consumers only ever wanted a suffix and a preset, so the new
    fields must not leak into that contract."""
    for name in PRINT_STYLES:
        suffix, preset = apply_style(name)
        assert isinstance(suffix, str) and suffix
        assert preset == BUILTIN_STYLES[name]["trace_preset"]


def test_style_recipe_returns_the_whole_entry_including_the_optional_fields():
    entry = style_recipe("logo-mark")
    assert entry["trace_preset"] == "bw"
    assert entry["model"] == "sdxl-1.0"
    assert entry["modifiers"] == ["logo-redmond"]
    # A copy, so a caller cannot mutate the registry through it.
    entry["model"] = "klein-4b"
    assert style_recipe("logo-mark")["model"] == "sdxl-1.0"


def test_style_suggestions_are_none_where_the_style_has_no_opinion():
    """\"No opinion\" and \"the default model\" are different statements, and
    collapsing them would make the caller's own choice look like the style's."""
    assert style_suggestions("flat-vector") == (None, None)
    assert style_suggestions("photo-halftone") == (None, None)
    assert style_suggestions("line-art") == ("sdxl-1.0", None)


def test_every_suggested_model_and_modifier_actually_resolves():
    """A style that names a model or a LoRA the registries do not have is a style
    that would fail on the first use."""
    from chopshop_flux.models import resolve as resolve_model

    for name in sorted(load_styles()):
        model, modifiers = style_suggestions(name)
        if model is not None:
            assert resolve_model(model).key == model, name
        for modifier in modifiers or []:
            assert resolve_modifier(modifier) is not None, (name, modifier)


def test_every_suggested_modifier_targets_the_suggested_model():
    """Otherwise the style would steer a prompt onto an adapter that was not
    trained for the model it also suggests."""
    from chopshop_flux.models import resolve as resolve_model

    for name in sorted(load_styles()):
        model, modifiers = style_suggestions(name)
        if model is None or not modifiers:
            continue
        spec = resolve_model(model)
        for modifier in modifiers:
            mod = resolve_modifier(modifier)
            assert spec.key in mod.targets, (name, modifier)


def test_an_unknown_style_still_names_the_available_ones():
    with pytest.raises(ModelError) as caught:
        style_recipe("no-such-style")
    message = str(caught.value)
    for name in PRINT_STYLES:
        assert name in message, name


def test_a_styles_file_may_still_add_an_optional_field_or_none(tmp_path):
    path = tmp_path / "styles.json"
    path.write_text(json.dumps({
        "risograph": {"prompt_suffix": ", two-ink risograph",
                      "trace_preset": "poster",
                      "model": "sdxl-1.0",
                      "modifiers": ["papercut-sdxl"]},
    }))
    assert style_suggestions("risograph", str(path)) == ("sdxl-1.0",
                                                        ["papercut-sdxl"])
    # A style with neither field is not an error and means "no opinion".
    path.write_text(json.dumps({
        "bare": {"prompt_suffix": ", ink", "trace_preset": "bw"},
    }))
    assert style_suggestions("bare", str(path)) == (None, None)
