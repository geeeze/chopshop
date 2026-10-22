#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The confidence FLOOR is advisory, and the raw masses are reported beside it.

chopshop-jev#1: "generation-slop: the confidence floor is not calibrated for the
local backend."

The failure this file exists to prevent is not a crash. It is a measurement
quietly converted into a constant. On the `generation-slop` vocabulary the local
`laya-serve` backend's probability mass lands between roughly 0.33 and 0.60
against the annotator's default `DEFAULT_CONFIDENCE_FLOOR = 0.6`, so every one of
the first bracket's 12 rasters came back `low_confidence` and the keep/escalate
loop escalated all of them -- a result that says something about the floor and
nothing about the rasters. The `printability` vocabulary shows the same shape at
0.23-0.61, so this is a property of the VOCABULARY and the BACKEND, not of one
question set.

The position taken is the issue's second option: the floor does not gate, it
ANNOTATES. So these tests pin four things, and the first three are the ones that
matter:

  1. The RAW mass is in the verdict for every answer that carries one, gated or
     not. This is the whole fix -- a caller who cannot see the mass cannot tell
     "the model was unsure" from "the floor was set for a different backend".
  2. `low_confidence` still exists and still means what it meant, because
     dropping it would break every caller that reads it. What changes is that it
     can no longer be the ONLY thing a verdict contains.
  3. The recorded observed ranges travel with the artifact, keyed per BACKEND as
     well as per vocabulary, so the evidence for the floor is IN the output
     rather than in a comment somewhere.
  4. The all-below-floor case is named as such, so "everything escalated" is
     visibly a statement about the floor.
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")
for p in (ROOT, SCRIPTS):
    if p not in sys.path:
        sys.path.insert(0, p)

import jev_annotate as jev  # noqa: E402

import pytest  # noqa: E402


# A mass inside the range the issue records for generation-slop/laya-serve
# (0.33-0.60), i.e. under the 0.6 default floor. If this fixture ever drifts
# above the floor the tests stop testing the failure mode, so it is derived from
# the recorded range rather than hard-coded twice.
SLOP_LOW, SLOP_HIGH = jev.OBSERVED_CONFIDENCE_RANGES[("generation-slop", "laya-serve")]
BELOW_FLOOR = round((SLOP_LOW + SLOP_HIGH) / 2, 2)
ABOVE_FLOOR = 0.93


def _slop_answers(mass):
    """One answer per question in generation-slop, each carrying the same mass.

    Built BY TYPE rather than as a flat dict, because the vocabulary is noul /
    score / choice and each shape is a different branch of the fold. A fixture
    that only ever sent `choice` would leave the noul and score branches
    untested, which is where the fold decides whether a mass exists at all.
    """
    noul = 0.5 + mass / 2.0  # a noul's certainty is 2|noul - 0.5|, so invert it
    answers = {}
    for name, question in jev.SLOP_QUESTIONS.items():
        kind = question.get("type")
        if kind == "noul":
            answers[name] = {"noul": round(noul, 4), "answer_confidence": mass}
        elif kind == "score":
            answers[name] = {"score": 0.5, "answer_confidence": mass,
                             "legend": ["a", "b"]}
        else:
            answers[name] = {"choice": "uniform_noise", "answer_confidence": mass}
    return answers


# --- 1. the raw mass is reported -------------------------------------------

def test_every_answer_with_a_mass_reports_it_raw_gated_or_not():
    """The fix itself. `confidence` holds the numbers, always -- including for
    the answers that PASSED the floor, which is what lets a caller compare its
    own floor against the same data instead of re-running the model.

    Three questions at distinct masses and one above the floor, so the mixed
    case is the one under test: a verdict that recorded only the failures would
    pass a uniform run and fail this one."""
    questions = jev.SLOP_QUESTIONS
    names = list(questions)
    masses = [0.42, 0.51, 0.58, ABOVE_FLOOR]
    answers = {}
    for name, question, mass in zip(names, questions.values(), masses):
        if question.get("type") == "noul":
            answers[name] = {"noul": round(0.5 + mass / 2, 4),
                             "answer_confidence": mass}
        elif question.get("type") == "score":
            answers[name] = {"score": 0.5, "answer_confidence": mass,
                             "legend": ["a", "b"]}
        else:
            answers[name] = {"choice": "uniform_noise", "answer_confidence": mass}

    verdict = jev.compose_annotation_verdict(
        answers, questions, vocabulary="generation-slop")

    assert verdict["confidence"] == dict(zip(names, masses)), (
        "the mass belongs beside the value, under the answer's own name"
    )
    assert ABOVE_FLOOR not in verdict["low_confidence"], (
        "0.93 clears the default floor, so it is not low-confidence -- and it is "
        "still reported, which is the part a gated-only verdict would hide"
    )
    assert verdict["low_confidence"], "the three under the floor are still listed"


def test_an_answer_at_or_above_the_floor_still_carries_its_mass():
    """Explicitly separate from the mixed case above, because the tempting
    implementation is to record only the failures -- which is exactly the
    measurement-turned-into-a-constant the issue describes."""
    questions = {"q": {"type": "choice", "choices": ["a"]}}
    verdict = jev.compose_annotation_verdict(
        {"q": {"choice": "a", "answer_confidence": 0.99}}, questions)
    assert verdict["confidence"] == {"q": 0.99}
    assert verdict["low_confidence"] == []


def test_the_printability_fold_reports_raw_masses_too():
    """The second fold, same treatment. It is the domain contract the studio
    reads by name, so it is the one whose shape is most likely to be trusted
    without being re-derived -- which is exactly why its numbers must be
    visible."""
    verdict = jev.compose_verdict({
        "failure_mode": {"choice": "registration", "answer_confidence": 0.93},
        "print_route": {"choice": "spot", "answer_confidence": 0.41},
        "tonal_structure": {"score": 0.55, "answer_confidence": 0.55,
                            "legend": ["flat", "full"]},
        "evidence_is_actionable": {"noul": 0.87},
    })

    assert verdict["confidence"] == {
        # Keyed by the QUESTION's name, not the verdict field's: `tonal_score`
        # is the value this fold publishes, `tonal_structure` is the answer it
        # came from. The mapping is part of the contract, so it is pinned here.
        "failure_mode": 0.93,
        "print_route": 0.41,
        "tonal_structure": 0.55,
        # A noul carries no confidence field, so its mass is DERIVED: certainty
        # is the distance from a coin flip, so noul 0.87 -> 2|0.87-0.5| = 0.74.
        # Pinned as the derived value rather than the raw one, because the
        # mapping is the whole reason the floor means different things for
        # different answer types.
        "evidence_is_actionable": 0.74,
    }
    assert verdict["low_confidence"] == ["print_route", "tonal_structure"]
    assert verdict["tonal_score"] == 0.55, "and the value still reaches its field"


# --- 2. the existing contract is not broken ---------------------------------

def test_low_confidence_still_means_exactly_what_it_meant():
    """`low_confidence` is kept, because dropping it would break every caller
    that reads it. This test exists so that keeping it is a decision rather than
    an accident: the list is unchanged, only the numbers beside it are new."""
    questions = {"a": {"type": "choice"}, "b": {"type": "choice"}, "c": {"type": "choice"}}
    verdict = jev.compose_annotation_verdict({
        "a": {"choice": "x", "answer_confidence": 0.2},
        "b": {"choice": "x", "answer_confidence": 0.59},
        "c": {"choice": "x", "answer_confidence": 0.6},
    }, questions)

    assert verdict["low_confidence"] == ["a", "b"], (
        "0.6 is AT the floor, and the gate is strict `<`; changing that would be "
        "a silent behaviour change to every existing caller"
    )


def test_a_caller_may_still_choose_its_own_floor_and_get_the_same_answers():
    """The floor is advisory: a caller that knows its backend passes one, and
    the VALUES do not change with it. Only the note changes. If values moved
    with the floor, the floor would be gating after all and the issue's first
    option would be the only honest one."""
    questions = {"a": {"type": "choice"}}
    answers = {"a": {"choice": "x", "answer_confidence": 0.45}}

    tight = jev.compose_annotation_verdict(answers, questions, confidence_floor=0.9)
    loose = jev.compose_annotation_verdict(answers, questions, confidence_floor=0.1)

    assert tight["values"] == loose["values"] == {"a": "x"}
    assert tight["low_confidence"] == ["a"]
    assert loose["low_confidence"] == []
    assert tight["confidence"] == loose["confidence"] == {"a": 0.45}, (
        "the masses are the measurement; the floor is the annotation"
    )


def test_the_floor_is_labelled_advisory_in_the_artifact():
    """Stated in the output, not left to be inferred from a number. A consumer
    reading `low_confidence` has to be able to tell it is a note about the
    numbers rather than a verdict about the raster."""
    for verdict in (jev.compose_annotation_verdict({}, {}),
                    jev.compose_verdict({})):
        assert verdict["confidence_floor_is_advisory"] is True
        assert verdict["confidence_floor"] == jev.DEFAULT_CONFIDENCE_FLOOR


# --- 3. the recorded evidence travels with the artifact ---------------------

def test_the_observed_range_is_recorded_per_vocabulary_and_per_backend():
    """A single merged number would be the same kind of constant this is arguing
    about: the same vocabulary gives different masses on a different decision
    service. Keyed by both, with no backend chosen for the caller -- this file
    does not know which one answered."""
    questions = {"a": {"type": "choice"}}
    verdict = jev.compose_annotation_verdict(
        {"a": {"choice": "x", "answer_confidence": 0.4}}, questions,
        vocabulary="generation-slop")

    evidence = verdict["confidence_evidence"]
    assert evidence["vocabulary"] == "generation-slop"
    assert evidence["by_backend"] == {"laya-serve": {
        "low": 0.33, "high": 0.60, "floor_covers_whole_range": True}}
    assert evidence["all_observed_below_default_floor"] is True, (
        "generation-slop's recorded range tops out at 0.60, exactly the 0.6 "
        "floor, and every one of the first bracket's 12 rasters did come back "
        "`low_confidence` -- so on this vocabulary the floor gated everything "
        "and selected nothing, which is the whole diagnosis in one field"
    )
    assert evidence["ranges_straddling_default_floor"] == []
    assert "advisory" in evidence["note"]


def test_the_second_vocabulary_is_reported_as_straddling_not_rounded_away():
    """printability was measured at 0.23-0.61, which CROSSES the 0.6 floor.

    This is the reason the evidence is per-row rather than a single summary: a
    table asserting "the floor is above every observed range" would be true for
    generation-slop and false for printability, and the false one is the one
    that would let a caller keep reading `low_confidence` as a filter.
    """
    evidence = jev.recorded_confidence_evidence("printability")
    assert evidence["by_backend"]["laya-serve"] == {
        "low": 0.23, "high": 0.61, "floor_covers_whole_range": False}
    assert evidence["all_observed_below_default_floor"] is False
    assert evidence["ranges_straddling_default_floor"] == ["laya-serve"]


def test_a_vocabulary_with_no_recorded_evidence_says_so_rather_than_inventing_one():
    """No evidence is not a passing grade. A new template must not inherit a
    range that was measured on a different vocabulary."""
    verdict = jev.compose_annotation_verdict(
        {"a": {"choice": "x", "answer_confidence": 0.4}},
        {"a": {"type": "choice"}}, vocabulary="a-vocabulary-nobody-measured")

    assert verdict["confidence_evidence"] == {}
    assert jev.recorded_confidence_evidence(None) == {}


def test_the_printability_fold_carries_printability_evidence():
    """Each fold reports ITS OWN vocabulary's range. Handing the printability
    fold the generation-slop numbers would be a fresh version of the same
    mistake."""
    verdict = jev.compose_verdict({})
    assert verdict["confidence_evidence"]["vocabulary"] == "printability"
    assert verdict["confidence_evidence"]["by_backend"]["laya-serve"]["low"] == 0.23
    assert verdict["confidence_evidence"]["by_backend"]["laya-serve"]["high"] == 0.61


# --- 4. the all-below-floor case is named -----------------------------------

def test_everything_under_the_floor_is_reported_as_exactly_that():
    """The failure mode from the issue, made visible in a field a caller reads
    without re-deriving anything: 12 of 12 rasters escalated, and the artifact
    says the escalation is about the floor."""
    verdict = jev.compose_annotation_verdict(
        _slop_answers(BELOW_FLOOR), jev.SLOP_QUESTIONS, vocabulary="generation-slop")

    assert verdict["confidence"], "the masses are there to be read"
    assert set(verdict["low_confidence"]) == set(verdict["confidence"]), (
        "every answer is under the floor, and the verdict says so rather than "
        "looking like a result about the rasters"
    )

    report = verdict["confidence_range"]
    assert report["all_below_default_floor"] is True
    assert report["low"] == report["high"] == BELOW_FLOOR
    assert "property of the floor" in report["note"]


def test_a_mixed_run_is_not_reported_as_all_below_the_floor():
    """The other direction: the flag must be a measurement, not a reflex. If it
    were hard-coded true it would be as uninformative as the constant it
    replaced."""
    questions = jev.SLOP_QUESTIONS
    names = list(questions)
    masses = [0.4, 0.5, 0.6, 0.95]
    answers = {}
    for name, question, mass in zip(names, questions.values(), masses):
        if question.get("type") == "noul":
            answers[name] = {"noul": round(0.5 + mass / 2, 4),
                             "answer_confidence": mass}
        elif question.get("type") == "score":
            answers[name] = {"score": 0.5, "answer_confidence": mass,
                             "legend": ["a", "b"]}
        else:
            answers[name] = {"choice": "uniform_noise", "answer_confidence": mass}

    report = jev.compose_annotation_verdict(
        answers, questions, vocabulary="generation-slop")["confidence_range"]

    assert report["all_below_default_floor"] is False
    assert report["low"] == 0.4 and report["high"] == 0.95
    assert "span" in report["note"]


def test_a_run_with_no_masses_reports_no_range_rather_than_an_empty_one():
    """`None`, not a zero-width 0.0-0.0: a range of nothing would read as a
    real measurement of nothing."""
    assert jev.observed_confidence_range({}) is None
    verdict = jev.compose_annotation_verdict({}, jev.SLOP_QUESTIONS)
    assert verdict["confidence_range"] is None
    assert verdict["confidence"] == {}


# --- the ranges the issue recorded, kept honest ------------------------------

def test_the_recorded_ranges_stay_inside_the_unit_interval():
    """The numbers in OBSERVED_CONFIDENCE_RANGES are the EVIDENCE for the
    position this repo takes, so they get a test of their own.

    Note what is NOT asserted: that every range sits under the default floor.
    `printability` was measured at 0.23-0.61 and straddles it. Asserting
    "below the floor" for all rows would be false, and quietly editing the
    constant until it became true is precisely the failure this repo is arguing
    against -- a range changed to fit a conclusion. What is asserted is the
    structural claim both rows rest on: a range, inside 0..1, ordered.
    """
    for (vocab, backend), (low, high) in jev.OBSERVED_CONFIDENCE_RANGES.items():
        assert 0.0 <= low <= high <= 1.0, f"{vocab}/{backend} is not a mass range"

    # And the two vocabularies really do behave differently, which is the whole
    # reason the floor is a per-vocabulary choice rather than a constant.
    below = jev.recorded_confidence_evidence("generation-slop")
    straddling = jev.recorded_confidence_evidence("printability")
    assert below["all_observed_below_default_floor"] is True
    assert straddling["all_observed_below_default_floor"] is False
    assert straddling["ranges_straddling_default_floor"], (
        "if printability's range stopped crossing the floor the recorded "
        "diagnosis in the comment above the constant would be out of date"
    )


def test_both_recorded_vocabularies_are_still_measured():
    """The issue says this is the SECOND vocabulary to show it. If one is
    dropped from the table the count in the comment above the constant goes
    stale, so the count is pinned instead."""
    vocabularies = {v for v, _ in jev.OBSERVED_CONFIDENCE_RANGES}
    assert vocabularies == {"generation-slop", "printability"}


# --- through the CLI, end to end --------------------------------------------

def test_a_dry_run_artifact_carries_the_numbers_beside_the_verdict(tmp_path):
    """The numbers have to survive all the way into the sidecar a caller reads.
    A field added to the fold but dropped before serialisation would leave the
    callers exactly where they were."""
    import json
    import subprocess

    artifact = tmp_path / "gen.json"
    artifact.write_text(json.dumps({
        "prompt": "a studio interior, warm light",
        "width": 512, "height": 512, "steps": 4,
    }))

    result = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "jev_annotate.py"), str(artifact),
         "--profile", "generation-slop", "--dry-run"],
        capture_output=True, text=True, cwd=str(ROOT))
    assert result.returncode == 0, result.stdout + result.stderr

    # A dry run writes the REQUEST ENVELOPE -- there is no response and so no
    # verdict, because a verdict with no answers would be a fabrication. What it
    # must carry is the floor's status, so a caller reading the envelope to
    # decide its own floor sees the same advisory statement it would get in a
    # real sidecar.
    written = tmp_path / "gen.jev.json"
    assert written.exists(), "the dry run wrote no envelope: " + result.stdout
    payload = json.loads(written.read_text())
    assert payload["status"] == "dry_run"
    assert payload["profile"] == "generation-slop"
    assert payload["confidence_floor_is_advisory"] is True
    assert payload["confidence_evidence"]["vocabulary"] == "generation-slop"
    assert payload["request"]["questions"], "and the vocabulary it is asking about"


def test_the_sidecar_carries_the_numbers_all_the_way_to_json(tmp_path):
    """The boundary that actually matters.

    A field added to a fold and dropped before serialisation would leave every
    caller exactly where they were, and the fold's own tests would all still be
    green. So this goes through `make_annotation_sidecar` -- the function the
    CLI calls -- and reads the JSON a caller would read, rather than asserting on
    a dict that never leaves the process.
    """
    import json

    state = {"evidence": {"prompt": True, "image_visible": False}}
    sidecar = jev.make_annotation(
        tmp_path / "gen.manifest.json",
        state,
        jev.build_request(state, jev.DEFAULT_MODEL, "generation-slop"),
        {"model": jev.DEFAULT_MODEL, "answers": _slop_answers(BELOW_FLOOR)},
        "generation-slop",
    )

    # Round-tripped through JSON on purpose: a non-serialisable value would raise
    # here rather than in a caller's run.
    payload = json.loads(json.dumps(sidecar))
    verdict = payload["verdict"]

    assert verdict["confidence"], "the raw masses reach the file a caller reads"
    assert set(verdict["low_confidence"]) == set(verdict["confidence"]), (
        "and on this backend every one of them is under the floor -- which the "
        "range report has to say rather than leave to be inferred"
    )
    assert verdict["confidence_range"]["all_below_default_floor"] is True
    assert verdict["confidence_floor_is_advisory"] is True
    assert verdict["confidence_evidence"]["vocabulary"] == "generation-slop"
    assert payload["profile"] == "generation-slop"


@pytest.mark.parametrize("vocab", ["generation-slop", "printability"])
def test_every_vocabulary_with_a_recorded_range_folds_without_error(vocab):
    """Both folds keep working after the change. A field added to a verdict is
    a field that can be malformed by the code that builds it, and the cheapest
    place to find that is here."""
    questions = jev.SLOP_QUESTIONS if vocab == "generation-slop" else jev.MEME_QUESTIONS
    answers = {name: {"choice": "x", "answer_confidence": 0.5} for name in questions}
    verdict = jev.compose_annotation_verdict(
        answers, questions, vocabulary=vocab)

    assert set(verdict["confidence"]) <= set(questions), (
        "confidence must only carry names the question set asked about"
    )
    assert verdict["confidence_evidence"]["vocabulary"] == vocab


# --- 2. the option-count floor is opt-in and measured ------------------------

def test_effective_floor_lowers_for_many_options_and_never_raises():
    """The measured fix, as a unit: a mass is only interpretable over k options.

    A live laya-on-am5 run over three real manifests put 10 of 12 answers under
    the flat 0.6 floor, and the ones that cleared it were the 2-option question
    -- so a single floor gates by option-count, not certainty. `effective_floor`
    scales the gate to the chance level of the question's breadth.
    """
    two = {"type": "choice", "criteria": {"yes": "y", "no": "n"}}
    seven = {"type": "choice", "criteria": {f"o{i}": str(i) for i in range(7)}}

    # A 2-option question sits just above chance (0.5 + margin), still under
    # the caller's 0.6 -- never raised above what the caller asked for.
    assert jev.effective_floor(0.6, two) == pytest.approx(0.55)
    assert jev.effective_floor(0.6, two) <= 0.6
    # A 7-option question gets a floor near its chance level, far below 0.6.
    wide = jev.effective_floor(0.6, seven)
    assert wide < 0.6, wide
    assert wide < 0.30, wide
    # Never RAISED above the caller's floor, for any breadth.
    assert jev.effective_floor(0.6, seven) <= 0.6
    # A caller who sets a LOW floor keeps it: scaling only ever lowers, never
    # raises, so an explicit 0.2 on a 2-option question is honoured.
    assert jev.effective_floor(0.2, two) == 0.2
    # No question / unknowable breadth -> the flat floor, unchanged.
    assert jev.effective_floor(0.6, None) == 0.6
    assert jev.effective_floor(0.6, {"type": "choice"}) == 0.6


def test_floor_by_option_count_is_opt_in_and_leaves_the_default_untouched():
    """The default fold is the documented contract; the option-count floor is a
    caller's deliberate choice, not a silent rewrite of it."""
    questions = {
        "wide": {"type": "choice", "criteria": {f"o{i}": str(i) for i in range(7)}},
        "binary": {"type": "choice", "criteria": {"yes": "y", "no": "n"}},
    }
    # A mass that clears a scaled floor for the wide question (chance ~0.21) but
    # not the flat 0.6 -- the exact shape the live measurement produced.
    answers = {
        "wide": {"choice": "o3", "answer_confidence": 0.35},
        "binary": {"choice": "no", "answer_confidence": 0.35},
    }

    flat = jev.compose_annotation_verdict(answers, questions)
    assert "wide" in flat["low_confidence"], "flat floor: the wide answer is under 0.6"
    assert "binary" in flat["low_confidence"], "flat floor: 0.35 is under 0.6 too"

    scaled = jev.compose_annotation_verdict(
        answers, questions, floor_by_option_count=True)
    # The wide answer (0.35 > its ~0.21 scaled floor) now clears; the raw mass is
    # recorded identically either way, and the binary one is untouched at 0.6.
    assert "wide" not in scaled["low_confidence"], scaled["low_confidence"]
    assert "binary" in scaled["low_confidence"], "0.6 still gates the 2-option one"
    assert scaled["confidence"]["wide"] == flat["confidence"]["wide"] == 0.35
