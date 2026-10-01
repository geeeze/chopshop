"""The example/test prompt set: validity and coverage, as tests rather than hops.

Coverage is asserted here on purpose. An example set that stops exercising a
modifier is a set that will not notice when that modifier breaks, and "we have
examples for everything" is exactly the kind of claim that quietly stops being
true the next time someone edits a list.
"""

import copy
import json
import os

import pytest

from chopshop_flux import examples as examples_module
from chopshop_flux.examples import (DEFAULT_EXAMPLES_PATH, REQUIRED_FIELDS,
                                    coverage, load_examples, reference_ids,
                                    validate_examples)
from chopshop_flux.models import REGISTRY, ModelError, resolve
from chopshop_flux.modifiers import MODIFIERS, VAES
from chopshop_flux.styles import load_styles


@pytest.fixture
def entries():
    return load_examples()


# -- the file itself -------------------------------------------------------

def test_the_bundled_set_is_found_from_the_repo_root_not_a_home_directory():
    assert os.path.isabs(DEFAULT_EXAMPLES_PATH)
    assert DEFAULT_EXAMPLES_PATH.endswith(os.path.join("examples", "prompts.json"))
    assert os.path.isfile(DEFAULT_EXAMPLES_PATH)
    source = open(examples_module.__file__, encoding="utf-8").read()
    assert "/home/" not in source
    assert "monop" not in source


def test_the_bundled_set_is_valid(entries):
    report = validate_examples(entries)
    assert report["models"]["missing"] == []
    assert report["modifiers"]["missing"] == []
    assert report["vaes"]["missing"] == []


def test_every_example_carries_every_required_field(entries):
    for entry in entries:
        for field in REQUIRED_FIELDS:
            assert field in entry, (entry.get("id"), field)


def test_example_ids_are_unique(entries):
    ids = [entry["id"] for entry in entries]
    assert len(ids) == len(set(ids))


def test_every_example_says_what_it_proves_in_one_sentence(entries):
    for entry in entries:
        statement = entry["what_it_proves"].strip()
        assert statement, entry["id"]
        assert statement.endswith("."), entry["id"]


# -- coverage --------------------------------------------------------------

def test_every_registered_model_is_exercised(entries):
    report = coverage(entries)
    assert report["models"]["missing"] == []
    assert set(report["models"]["covered"]) == set(REGISTRY)


def test_every_registered_modifier_is_exercised(entries):
    report = coverage(entries)
    assert report["modifiers"]["missing"] == []
    assert set(report["modifiers"]["covered"]) == set(MODIFIERS)


def test_every_registered_vae_is_exercised(entries):
    report = coverage(entries)
    assert report["vaes"]["missing"] == []
    assert set(report["vaes"]["covered"]) == set(VAES)


def test_every_print_style_is_exercised_by_an_example(entries):
    used = {entry["style"] for entry in entries if entry["style"]}
    print_styles = {"logo-mark", "line-art", "flat-vector", "sticker",
                    "colouring-book", "pixel-art"}
    assert print_styles <= used


def test_the_set_covers_the_print_subjects_and_both_edit_paths(entries):
    """The ask named these subjects; each one is checked by a predicate rather
    than by hoping it appears in a prompt string."""
    from chopshop_flux.examples import REQUIRED_SUBJECTS

    for name, predicate in REQUIRED_SUBJECTS.items():
        assert any(predicate(entry) for entry in entries), name


def test_the_speed_adapters_are_all_three_exercised_at_one_seed(entries):
    """The three Lightning adapters are one comparison, so they must run at the
    same prompt and seed or the comparison is not one."""
    lightning = [entry for entry in entries
                 if any(m.startswith("sdxl-lightning") for m in entry["modifiers"])]
    assert len(lightning) == 3
    assert len({entry["prompt"] for entry in lightning}) == 1
    assert len({entry["seed"] for entry in lightning}) == 1


def test_an_edit_example_references_another_example(entries):
    by_id = {entry["id"]: entry for entry in entries}
    edits = [entry for entry in entries if entry.get("reference")]
    assert edits, "the set must contain edits, and an edit needs a reference"
    for entry in edits:
        for target in reference_ids(entry):
            assert target in by_id
            assert by_id[target].get("reference") is None, \
                "a reference chain must terminate"


# -- multi-reference: the capability the set now has to be able to express ---

def test_the_set_carries_a_multi_reference_edit(entries):
    """The issue's "done looks like", as a test.

    Without this the set can express multi-reference in the schema and nothing
    uses it, and the capability goes on being argued for from a signature
    instead of demonstrated. Asserted on the BUNDLED set, not on a fixture: a
    demonstration that only exists in a test is not a demonstration.
    """
    multi = [entry for entry in entries if len(reference_ids(entry)) > 1]
    assert multi, "the set must contain a multi-reference edit"
    for entry in multi:
        # On a checkpoint that actually declares it. An example aimed at a
        # single-reference family is a 400 waiting to happen.
        assert resolve(entry["model"]).multi_reference, \
            "%s sends several references to %s, which does not declare it" % (
                entry["id"], entry["model"])


def test_reference_ids_normalises_both_shapes():
    assert reference_ids({"reference": None}) == []
    assert reference_ids({}) == []
    assert reference_ids({"reference": "a"}) == ["a"]
    assert reference_ids({"reference": ["a", "b"]}) == ["a", "b"]


def test_reference_ids_preserves_order():
    """Order is the whole of the caller's claim ("the pose from the first, the
    palette from the second") and nothing downstream can recover it, so a set
    that sorts them would silently change what the example asks for."""
    assert reference_ids({"reference": ["z", "a", "m"]}) == ["z", "a", "m"]


def test_a_multi_reference_edit_must_be_on_a_multi_reference_model():
    entry = _valid()
    entry["model"] = "sdxl-1.0"
    other = _valid()
    other["id"] = "other"
    other["model"] = "sdxl-1.0"
    other["reference"] = None
    third = _valid()
    third["id"] = "third"
    third["model"] = "sdxl-1.0"
    third["reference"] = None
    entry["reference"] = ["other", "third"]
    with pytest.raises(ModelError) as caught:
        validate_examples([entry, other, third])
    assert "single reference" in str(caught.value)


def test_the_same_reference_twice_is_refused():
    """Two copies of one frame is not two conditioning inputs, and sending it
    would produce a frame that looks like a multi-reference demonstration."""
    entry = _valid()
    other = _valid()
    other["id"] = "other"
    other["reference"] = None
    entry["reference"] = ["other", "other"]
    with pytest.raises(ModelError) as caught:
        validate_examples([entry, other])
    assert "twice" in str(caught.value)


def test_an_empty_reference_list_is_refused():
    entry = _valid()
    entry["reference"] = []
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "empty list" in str(caught.value)


def test_a_multi_reference_pointing_at_an_edit_is_refused(entries):
    """A chain must terminate, in the new shape as well as the old one. The
    bundle's own single-reference edits already keep that rule; a two-element
    list that quietly reintroduced it would be the same fault one field over."""
    by_id = {entry["id"]: entry for entry in entries}
    # klein-object-remove-edit edits klein-emblem-t2i, so pointing a
    # multi-reference entry at the former is a two-step chain.
    with pytest.raises(ModelError) as caught:
        validate_examples([
            dict(by_id["klein-object-remove-edit"],
                 reference=["klein-emblem-t2i", "klein-bg-remove-edit"]),
            by_id["klein-emblem-t2i"],
            by_id["klein-bg-remove-edit"],
        ])
    assert "itself an edit" in str(caught.value)


def test_coverage_reports_a_missing_modifier_rather_than_hiding_it(entries):
    trimmed = [entry for entry in entries
               if "pixel-art-xl" not in entry["modifiers"]]
    assert "pixel-art-xl" in coverage(trimmed)["modifiers"]["missing"]


# -- what the validator refuses -------------------------------------------

def _valid():
    return copy.deepcopy(load_examples()[0])


def test_an_unknown_model_is_refused():
    entry = _valid()
    entry["model"] = "klein-40b"
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "klein-40b" in str(caught.value)


def test_an_unknown_modifier_is_refused():
    entry = _valid()
    entry["modifiers"] = ["no-such-lora"]
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "no-such-lora" in str(caught.value)


def test_an_unknown_vae_is_refused():
    entry = _valid()
    entry["vae"] = "no-such-vae"
    with pytest.raises(ModelError):
        validate_examples([entry])


def test_an_unknown_style_is_refused():
    entry = _valid()
    entry["style"] = "no-such-style"
    with pytest.raises(ModelError):
        validate_examples([entry])


def test_a_size_the_model_forbids_is_refused():
    """1000 is not a multiple of 16, so klein would answer 400 to this."""
    entry = _valid()
    entry["width"], entry["height"] = 1000, 1024
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "multiple of 16" in str(caught.value)


def test_a_size_below_the_models_floor_is_refused():
    entry = _valid()
    entry["width"], entry["height"] = 512, 512
    entry["model"] = "sana-sprint-0.6b"
    entry["steps"], entry["guidance"] = 2, 4.5
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "at least 512" not in str(caught.value)  # 512 IS the floor
    entry["width"] = 256
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "at least 512" in str(caught.value)


def test_an_off_schedule_step_count_on_a_distilled_model_is_refused():
    entry = _valid()
    assert entry["model"] == "klein-4b"
    entry["steps"] = 30
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "distilled schedule" in str(caught.value)


def test_an_off_schedule_guidance_on_a_distilled_model_is_refused():
    entry = _valid()
    entry["guidance"] = 5.0
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "distilled schedule" in str(caught.value)


def test_an_adapter_run_off_its_own_schedule_is_refused():
    """LCM and Lightning ARE their distilled schedule, so an example that loads
    one at other numbers proves nothing about the adapter."""
    entry = _valid()
    entry["model"], entry["width"], entry["height"] = "sdxl-1.0", 768, 768
    entry["modifiers"] = ["sdxl-lightning-4step"]
    entry["steps"], entry["guidance"] = 30, 0.0
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "own schedule" in str(caught.value)
    assert "4 steps" in str(caught.value)


def test_an_adapter_run_at_the_wrong_guidance_is_refused():
    entry = _valid()
    entry["model"], entry["width"], entry["height"] = "sdxl-1.0", 768, 768
    entry["modifiers"] = ["lcm-lora-sdxl"]
    entry["steps"], entry["guidance"] = 4, 6.0
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "own schedule" in str(caught.value)


def test_a_modifier_aimed_at_another_model_is_refused():
    """The service would warn and generate anyway; an example that silently
    generates something other than what it claims is not an example."""
    entry = _valid()
    entry["model"], entry["width"], entry["height"] = "sd-1.5", 512, 512
    entry["modifiers"] = ["pixel-art-xl"]
    # On the adapter's own schedule, so the target check is the one under test.
    entry["steps"], entry["guidance"] = 8, 1.5
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "does not target" in str(caught.value)


def test_a_vae_aimed_at_another_model_is_refused():
    entry = _valid()
    entry["model"] = "sd-1.5"
    entry["width"] = entry["height"] = 512
    entry["vae"] = "taesdxl"
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "does not target" in str(caught.value)


def test_two_modifiers_wanting_two_schedulers_is_refused():
    entry = _valid()
    entry["model"], entry["width"], entry["height"] = "sdxl-1.0", 768, 768
    entry["modifiers"] = ["sdxl-lightning-4step", "lcm-lora-sdxl"]
    # On the first adapter's own schedule: no numbering satisfies both, which is
    # exactly what the conflict check is for.
    entry["steps"], entry["guidance"] = 4, 0.0
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "conflicting schedulers" in str(caught.value)


def test_a_style_suggestion_that_is_ignored_is_refused():
    entry = _valid()
    entry["model"], entry["width"], entry["height"] = "sd-1.5", 512, 512
    entry["style"] = "sticker"          # suggests sdxl-1.0 and the stickers LoRA
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "suggests" in str(caught.value)


def test_a_styles_suggested_modifier_must_be_requested():
    entry = _valid()
    entry["model"] = "sdxl-1.0"
    entry["style"] = "sticker"          # suggests the stickers LoRA
    entry["modifiers"] = []
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "suggests modifier" in str(caught.value)


def test_a_dangling_reference_is_refused():
    entry = _valid()
    entry["reference"] = "no-such-example"
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "not in this set" in str(caught.value)


def test_a_self_reference_is_refused():
    entry = _valid()
    entry["reference"] = entry["id"]
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "itself" in str(caught.value)


def test_a_duplicate_id_is_refused():
    entry = _valid()
    with pytest.raises(ModelError) as caught:
        validate_examples([entry, copy.deepcopy(entry)])
    assert "duplicate id" in str(caught.value)


def test_a_missing_field_is_refused():
    entry = _valid()
    del entry["seed"]
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "missing field 'seed'" in str(caught.value)


def test_an_unknown_field_is_refused():
    """A typo'd field silently does nothing, and a set that silently does nothing
    is worse than one that fails loudly."""
    entry = _valid()
    entry["negative-prompt"] = "typo"
    with pytest.raises(ModelError) as caught:
        validate_examples([entry])
    assert "unknown field" in str(caught.value)


def test_a_non_integer_seed_is_refused():
    """A seed is the only thing that makes a run reproducible, so it must be
    reportable exactly."""
    entry = _valid()
    entry["seed"] = "1234"
    with pytest.raises(ModelError):
        validate_examples([entry])


def test_an_empty_set_is_refused():
    with pytest.raises(ModelError):
        validate_examples([])


def test_a_missing_file_is_an_error_not_an_empty_set(tmp_path):
    """Unlike a styles file, an example set IS the deliverable: falling back to
    nothing would make every check downstream vacuous."""
    with pytest.raises(ModelError) as caught:
        load_examples(str(tmp_path / "nope.json"))
    assert "no example set" in str(caught.value)


def test_a_non_array_example_file_is_refused(tmp_path):
    path = tmp_path / "prompts.json"
    path.write_text(json.dumps({"id": "x"}))
    with pytest.raises(ModelError) as caught:
        load_examples(str(path))
    assert "JSON array" in str(caught.value)


def test_malformed_json_is_refused(tmp_path):
    path = tmp_path / "prompts.json"
    path.write_text("{not json")
    with pytest.raises(ModelError):
        load_examples(str(path))


def test_an_alias_resolves_and_counts_towards_coverage():
    """An example may name an alias; reporting the target as missing because the
    set said 'sdxl' would be a false alarm."""
    entry = _valid()
    entry["model"] = "sdxl"          # an alias for sdxl-1.0
    entry["width"] = entry["height"] = 768
    report = coverage([entry])
    assert "sdxl-1.0" in report["models"]["covered"]
    assert "sdxl-1.0" not in report["models"]["missing"]


def test_the_validator_does_not_gate_licences(entries):
    """The validator answers "is this example coherent", not "may you run it".
    The licence gate lives on the load path, and duplicating it here would give
    two places to weaken."""
    turbo = [entry for entry in entries if entry["model"] == "sdxl-turbo"]
    assert turbo, "the non-commercial entry should be in the set"
    validate_examples(entries)  # does not raise without the ack env var


def test_every_style_an_example_names_exists():
    styles = load_styles()
    for entry in load_examples():
        if entry["style"]:
            assert entry["style"] in styles, entry["id"]
