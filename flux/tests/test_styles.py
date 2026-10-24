"""Styles: the built-in three, the merge, and what an unknown name raises.

These run with no torch and no GPU, which is the point — styles are prompt text
and a preset hint, not model code, and they must be usable on a box that cannot
load a model at all.
"""

import json
import re
import os

import pytest

from chopshop_flux import styles as styles_module
from chopshop_flux.models import ModelError
from chopshop_flux.styles import (BUILTIN_STYLES, DEFAULT_STYLES_PATH,
                                  apply_style, load_styles, style_sweep_json)

BUILT_IN_NAMES = {"flat-poster", "mono-line", "photo-halftone"}


def test_the_bundled_styles_file_is_found_next_to_the_module():
    """The path is derived from the module, never a machine's home directory."""
    assert os.path.isabs(DEFAULT_STYLES_PATH)
    assert DEFAULT_STYLES_PATH == os.path.join(
        os.path.dirname(os.path.abspath(styles_module.__file__)), "styles.json")
    assert os.path.basename(DEFAULT_STYLES_PATH) == "styles.json"
    assert os.path.exists(DEFAULT_STYLES_PATH)


def test_the_styles_module_hardcodes_no_machine_path():
    """Naming a machine is how a repo goes stale; the path must be derived.

    The checkout may itself live under any home directory, so this checks the
    *source*, not the resolved path.
    """
    source = open(os.path.abspath(styles_module.__file__), encoding="utf-8").read()
    assert "/home/" not in source
    assert "/Users/" not in source
    # A private-network address, by RANGE -- never by one box's literal.
    assert not re.search(r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.", source)


def test_load_styles_returns_the_three_built_ins():
    styles = load_styles()
    assert BUILT_IN_NAMES <= set(styles)
    assert styles["flat-poster"]["prompt_suffix"].startswith(", flat vector poster")
    assert styles["flat-poster"]["trace_preset"] == "poster"
    assert styles["mono-line"]["trace_preset"] == "bw"
    assert styles["photo-halftone"]["trace_preset"] == "photo"


def test_load_styles_merges_a_file_over_the_built_ins(tmp_path):
    """A file adds a style and may override a built-in; the rest survive."""
    path = tmp_path / "styles.json"
    path.write_text(json.dumps({
        "risograph": {"prompt_suffix": ", two-ink risograph, grainy",
                      "trace_preset": "poster"},
        "mono-line": {"prompt_suffix": ", pure ink lines",
                      "trace_preset": "bw"},
    }))

    styles = load_styles(str(path))

    assert styles["risograph"]["prompt_suffix"] == ", two-ink risograph, grainy"
    assert styles["mono-line"]["prompt_suffix"] == ", pure ink lines"
    # The built-ins the file did not mention are still there.
    assert styles["flat-poster"] == BUILTIN_STYLES["flat-poster"]
    assert styles["photo-halftone"] == BUILTIN_STYLES["photo-halftone"]


def test_load_styles_tolerates_a_missing_file(tmp_path):
    styles = load_styles(str(tmp_path / "does-not-exist.json"))
    assert BUILT_IN_NAMES <= set(styles)


def test_load_styles_tolerates_an_unreadable_or_invalid_file(tmp_path):
    """Invalid JSON, a non-object, and a directory all fall back to built-ins."""
    invalid = tmp_path / "invalid.json"
    invalid.write_text("{not json at all")
    assert BUILT_IN_NAMES <= set(load_styles(str(invalid)))

    # A JSON array is valid JSON but not a styles object.
    array = tmp_path / "array.json"
    array.write_text("[1, 2, 3]")
    assert load_styles(str(array)) == load_styles()

    # A path that exists but cannot be read as a file.
    assert BUILT_IN_NAMES <= set(load_styles(str(tmp_path)))


def test_apply_style_returns_the_suffix_and_preset_for_a_known_style():
    suffix, preset = apply_style("flat-poster")
    assert suffix == BUILTIN_STYLES["flat-poster"]["prompt_suffix"]
    assert preset == "poster"

    suffix, preset = apply_style("mono-line")
    assert "line art" in suffix
    assert preset == "bw"


def test_apply_style_reads_a_supplied_styles_file(tmp_path):
    path = tmp_path / "styles.json"
    path.write_text(json.dumps({
        "zine": {"prompt_suffix": ", photocopied zine", "trace_preset": "bw"},
    }))
    assert apply_style("zine", str(path)) == (", photocopied zine", "bw")


def test_an_unknown_style_is_a_caller_error_that_lists_the_available_names():
    with pytest.raises(ModelError) as caught:
        apply_style("no-such-style")
    assert caught.value.exit_code == 2
    message = str(caught.value)
    assert "no-such-style" in message
    for name in sorted(BUILTIN_STYLES):
        assert name in message


def test_style_sweep_json_writes_a_single_preset_sweep_and_returns_the_path(tmp_path):
    target = tmp_path / "nested" / "sweep.json"
    returned = style_sweep_json("poster", str(target))

    assert returned == str(target)
    assert target.exists()

    payload = json.loads(target.read_text())
    assert payload == {
        "version": 1,
        "presets": ["poster"],
        "filter_speckle": [2, 8],
        "hierarchical": ["cutout", "stacked"],
        "use_palette": [False, True],
        "max_candidates": 8,
    }
    assert set(payload) == {"version", "presets", "filter_speckle",
                            "hierarchical", "use_palette", "max_candidates"}
