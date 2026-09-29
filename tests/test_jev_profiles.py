"""Question-set TEMPLATES: the sane defaults stay one, and a second set exists.

What is pinned here, and why each one matters:

  * the DEFAULT template's questions are the module's own `QUESTIONS` object,
    unchanged — the studio, the remediation table and the help page all read that
    set by name, so "the defaults are now a template" must not have moved them;
  * every profile is internally sound (`check_profile`): a choice carries a
    criteria MAP, a score a LIST, a noul its true/false criteria, and a type the
    service has no head for (`phrase` — measured, HTTP 400) is refused locally
    rather than costing a round trip. A hand-edited template that reaches the
    service malformed is the failure this prevents;
  * an unknown profile is REFUSED, naming the ones that exist — never silently
    answered with the default;
  * the translation profile's fold is type-driven and honest: image-dependent
    questions are reported as `unevidenced` when the state says the image is not
    visible.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import jev_annotate as jev  # noqa: E402


MANIFEST = {
    "passed": False,
    "input": {"kind": "svg", "file": "/home/someone/secret/art.svg", "spec": "/home/someone/secret/spec.json"},
    "summary": {"hard": 2, "advisory": 1, "print_method": "screen_print"},
    "findings": [
        {"rule": "colour_count", "severity": "hard",
         "detail": "declared colours #112233 #445566 #778899 #aabbcc exceed the budget"}
    ],
    "stats": {
        "input_kind": "svg",
        "rendered_distinct_colors": 412,
        "rendered_screens": 9,
        "hard_findings": 2,
        "static": {"paths": 120, "path_nodes_total": 180000, "color_count": 512},
    },
    "notes": ["prepared from a raster"],
}

ARTIFACT = {
    "prompt": "a woodcut phoenix emblem,\n\n  two inks and high contrast",
    "topic": "style-intricate-powerful-solar",
    "phrase_root": "woodcut",
    "settings": {"seed": 3148892874, "steps": 50, "guidance": 7.0, "sampler": "k_lms",
                 "width": 704, "height": 512},
    "generation": {"model": "klein-4b", "job": 386, "raster": "/home/someone/storage/uploads/flux_68bd74b78c9a.png"},
    "measurements": {"distinct_colors": 12043, "width": 704, "height": 512},
}


# --- the sane defaults are a template, and they did not move -----------------

def test_the_default_template_is_the_module_questions_unchanged():
    default = jev.profile(None)
    assert default["id"] == "printability"
    assert default["questions"] is jev.QUESTIONS, (
        "the default template must BE the module's QUESTIONS object, not a copy: "
        "every existing reader (studio JevConf, the remediation table, the help page) "
        "reads that set and must keep seeing the same four questions"
    )
    assert set(jev.QUESTIONS) == {
        "failure_mode", "print_route", "tonal_structure", "evidence_is_actionable"
    }
    assert jev.QUESTIONS["tonal_structure"]["type"] == "score"
    assert jev.QUESTIONS["evidence_is_actionable"]["type"] == "noul"
    assert isinstance(jev.QUESTIONS["failure_mode"]["criteria"], dict)
    assert isinstance(jev.QUESTIONS["tonal_structure"]["criteria"], list)


def test_a_request_with_no_profile_named_is_the_printability_template():
    request = jev.build_request({"passed": True})
    assert request["questions"] == jev.QUESTIONS
    assert request["model"] == jev.DEFAULT_MODEL
    assert "profile" not in request, (
        "which template answered is recorded in the SIDECAR; sending it is what "
        "made the service answer 400 (see ENVELOPE_KEYS)"
    )


# --- every profile is sound --------------------------------------------------

def test_every_profile_passes_its_own_check():
    assert jev.PROFILES, "there is at least the default"
    for name, p in jev.PROFILES.items():
        jev.check_profile(p)
        assert p["id"] == name, "a profile's id matches the key it is filed under"
        assert p["title"] and p["why"], "a profile explains itself to a reader"


def test_check_profile_refuses_a_malformed_template():
    base = dict(jev.PROFILES["printability"])

    broken = dict(base, questions={"q": {"type": "choice", "instructions": "?", "criteria": []}})
    with pytest.raises(ValueError, match="criteria MAP"):
        jev.check_profile(broken)

    broken = dict(base, questions={"q": {"type": "score", "instructions": "?", "criteria": {}}})
    with pytest.raises(ValueError, match="criteria LIST"):
        jev.check_profile(broken)

    # `phrase` is not a type the SERVICE has — measured, HTTP 400 — so a template
    # declaring one is refused here, with the measurement in the reason, rather
    # than costing a round trip to discover.
    broken = dict(base, questions={"q": {"type": "phrase", "instructions": "?",
                                         "shape": "adj + n"}})
    with pytest.raises(ValueError, match="cannot be asked"):
        jev.check_profile(broken)

    broken = dict(base, questions={"q": {"type": "vibe", "instructions": "?"}})
    with pytest.raises(ValueError, match="unknown type"):
        jev.check_profile(broken)

    broken = dict(base, questions={"q": {"type": "choice", "instructions": "?",
                                         "criteria": {"a": "b"}, "requires": ["horoscope"]}})
    with pytest.raises(ValueError, match="unknown requirement"):
        jev.check_profile(broken)

    broken = dict(base, projector="crystal_ball")
    with pytest.raises(ValueError, match="unknown projector"):
        jev.check_profile(broken)


def test_an_unknown_profile_is_refused_and_names_the_ones_that_exist():
    with pytest.raises(ValueError, match="unknown profile"):
        jev.profile("printabilty")  # a typo, which must not become the default

    result = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "jev_annotate.py"),
         str(REPO / "README.md"), "--profile", "nope", "--dry-run"],
        capture_output=True, text=True,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert "unknown profile" in result.stderr
    for name in jev.PROFILES:
        assert name in result.stderr, "the refusal names every template that ships"


def test_list_profiles_names_every_template_that_ships():
    """Every profile in `PROFILES`, not a hand-written pair: a third vocabulary
    that the CLI prints but the test does not know about is how a template goes
    undocumented."""
    result = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "jev_annotate.py"), "--list-profiles"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
    for name, p in jev.PROFILES.items():
        assert name in result.stdout, f"{name} is not listed"
        assert f"{len(p['questions'])} questions" in result.stdout.split(name)[1]
    assert len(result.stdout.strip().splitlines()) == len(jev.PROFILES), (
        "--list-profiles prints one line per template and nothing else"
    )


# --- the artifact projector --------------------------------------------------

def test_the_artifact_projector_reads_the_studio_shape_and_scrubs_paths():
    state = jev.project_artifact(ARTIFACT)
    assert state["artifact_schema"] == "generation-artifact"
    assert state["prompt"] == "a woodcut phoenix emblem, two inks and high contrast", (
        "the prompt is collapsed to one line before it leaves the machine"
    )
    assert state["topic"] == "style-intricate-powerful-solar"
    assert state["settings"]["sampler"] == "k_lms"
    assert state["generation"]["raster"] == "flux_68bd74b78c9a.png", "the path is shortened"
    assert state["measurements"]["distinct_colors"] == 12043

    # The honest bit, and the one the fold depends on.
    assert state["evidence"]["prompt"] is True
    assert state["evidence"]["measurements"] is True
    assert state["evidence"]["image_visible"] is False, (
        "this annotator is given text and numbers, never pixels, and the state must say so"
    )


def test_the_artifact_projector_refuses_a_file_that_is_not_an_artifact():
    with pytest.raises(ValueError, match="needs a 'prompt' string"):
        jev.project_artifact(MANIFEST)


def test_a_manifest_through_the_translation_profile_is_refused_not_misread(tmp_path):
    """The wrong template for the input is a REFUSAL. Reading a manifest as an
    artifact would answer meme questions about a document that has no prompt."""
    manifest = tmp_path / "artwork.manifest.json"
    manifest.write_text(json.dumps(MANIFEST))

    result = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "jev_annotate.py"), str(manifest),
         "--profile", "dataset-translation", "--dry-run"],
        capture_output=True, text=True,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert "prompt" in result.stderr
    assert not (tmp_path / "artwork.jev.json").exists(), (
        "a refused run writes no sidecar: an empty one would look like an answer"
    )


# --- the type-driven fold ----------------------------------------------------

def test_the_generic_fold_answers_each_type_by_its_own_shape():
    verdict = jev.compose_annotation_verdict(
        {
            "sentiment": {"choice": "anger", "confidence": 0.9},
            "offensiveness": {"choice": "moderately_offensive", "confidence": 0.3},
            "evidence_is_actionable": {"noul": 0.81},
        },
        jev.MEME_QUESTIONS,
        {"evidence": {"prompt": True, "image_visible": False}},
    )

    assert verdict["values"]["sentiment"] == "anger"
    assert "source_domain" not in verdict["values"], (
        "a name the question set does not contain is not invented into the verdict"
    )
    assert verdict["values"]["evidence_is_actionable"] is True, "a noul >= 0.5 is true"
    assert verdict["low_confidence"] == ["offensiveness"], "0.3 is under the 0.6 floor"


def test_the_fold_reports_a_question_whose_evidence_is_absent():
    """The reason `requires` exists: most of MET-Meme's scheme is about an image,
    and an answer to an image question with no image in the state is not settled
    fact. It is reported, not silently trusted."""
    verdict = jev.compose_annotation_verdict(
        {"metaphor_category": {"choice": "image_dominant", "confidence": 0.99},
         "sentiment": {"choice": "happiness", "confidence": 0.99}},
        jev.MEME_QUESTIONS,
        {"evidence": {"prompt": True, "image_visible": False}},
    )

    assert verdict["unevidenced"] == ["metaphor_category"]
    assert verdict["values"]["sentiment"] == "happiness", "an answer that needs no image stands"
    assert "metaphor_category" not in verdict["low_confidence"], (
        "confident but unevidenced is a different admission from unsure, and the "
        "verdict keeps them apart"
    )


def test_the_negative_answer_on_the_artifact_is_recorded_not_dropped():
    verdict = jev.compose_annotation_verdict(
        {"offensiveness": {"choice": "non_offensive", "confidence": 0.95},
         "evidence_is_actionable": {"noul": 0.1}},
        jev.MEME_QUESTIONS,
        {"evidence": {"prompt": True}},
    )
    assert verdict["values"]["offensiveness"] == "non_offensive"
    assert verdict["values"]["evidence_is_actionable"] is False, (
        "P(true) of 0.1 is a false, and a false is an answer"
    )


# --- the templates through the CLI, end to end -------------------------------

def test_a_dry_run_carries_the_named_template_and_not_the_other(tmp_path):
    artifact = tmp_path / "artifact.json"
    artifact.write_text(json.dumps(ARTIFACT))

    result = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "jev_annotate.py"), str(artifact),
         "--profile", "dataset-translation", "--dry-run"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr

    sidecar = json.loads((tmp_path / "artifact.jev.json").read_text())
    assert sidecar["status"] == "dry_run"
    assert sidecar["profile"] == "dataset-translation"
    questions = sidecar["request"]["questions"]
    assert set(questions) == set(jev.MEME_QUESTIONS)
    assert len(questions) == 8
    assert set(questions) & set(jev.QUESTIONS) == {"evidence_is_actionable"}, (
        "the two templates share exactly the one question that is about evidence"
    )
    assert sidecar["request"]["state"]["evidence"]["image_visible"] is False


def test_the_envelope_carries_exactly_the_keys_the_service_accepts(tmp_path):
    """Pinned because it was MEASURED: an extra key beside model/state/questions
    turned a 200 into a 400, and it broke every request in the repo — including
    the printability one — until it was found. What this repo knows about a
    request (which template answered) goes in the sidecar, not on the wire."""
    for name in jev.PROFILES:
        request = jev.build_request({"passed": True}, profile_name=name)
        assert tuple(sorted(request)) == tuple(sorted(jev.ENVELOPE_KEYS)), (
            f"the {name} request carries a key the envelope does not define"
        )
        assert "profile" not in request, "the profile is recorded locally, never sent"


def test_no_shipped_question_declares_a_type_the_service_refuses():
    for name, p in jev.PROFILES.items():
        for qname, question in p["questions"].items():
            assert question["type"] in jev.QUESTION_TYPES, (
                f"{name}/{qname}: {question['type']} is not a type this service answers"
            )
            assert question["type"] not in jev.UNSUPPORTED_QUESTION_TYPES, (
                f"{name}/{qname}: {question['type']} is a known refusable type"
            )


def test_the_two_shape_constrained_domain_fields_are_absent_on_purpose():
    """A measured gap, not an oversight: MET-Meme constrains `source_domain` and
    `target_domain` by SHAPE, so they need free text, and the service has no such
    answer type. The template asks the eight questions it CAN ask."""
    assert "source_domain" not in jev.MEME_QUESTIONS
    assert "target_domain" not in jev.MEME_QUESTIONS
    assert "phrase" in jev.UNSUPPORTED_QUESTION_TYPES
    assert "400" in jev.UNSUPPORTED_QUESTION_TYPES["phrase"], (
        "the reason names the measurement, so the next reader does not retry it"
    )


def test_the_printability_dry_run_is_byte_for_byte_what_it_always_was(tmp_path):
    manifest = tmp_path / "artwork.manifest.json"
    manifest.write_text(json.dumps(MANIFEST))

    result = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "jev_annotate.py"), str(manifest), "--dry-run"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr

    sidecar = json.loads((tmp_path / "artwork.jev.json").read_text())
    assert sidecar["profile"] == "printability"
    assert sidecar["request"]["questions"] == jev.QUESTIONS
    assert sidecar["request"]["state"] == jev.project_manifest(MANIFEST), (
        "the manifest projection is untouched by the template work"
    )
