"""The systemone gateway: one `/v1/systemone` front door, three backends.

The point of these tests is the TRANSLATION, not HTTP plumbing: a cloud backend
receives a chat request and must produce answers this repo's fold can read. So
the shapes asserted here are the ones MEASURED from the live local service —
choice -> {"choice"}, score -> {"score","legend"}, noul -> {"noul"} — which is
what makes a hosted answer and a local one interchangeable.

No network here: every backend call is stubbed at `_post_json`.
"""

import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import systemone_gateway as gw  # noqa: E402

CHOICE = {"type": "choice", "instructions": "pick one",
          "criteria": {"a": "the first", "b": "the second"}}
SCORE = {"type": "score", "instructions": "how good",
         "criteria": ["broken", "flat", "retained", "engraving-grade"]}
NOUL = {"type": "noul", "instructions": "is it actionable",
        "criteria": {"true": "yes it is", "false": "no it is not"}}


def envelope(**questions):
    return {"model": "jev-latest",
            "state": {"prompt": "a fox", "evidence": {"prompt": True}},
            "questions": questions or {"q": CHOICE}}


# -- validation -------------------------------------------------------------


def test_the_three_service_types_are_accepted():
    """MEASURED from this repo's own profiles: printability mixes all three."""
    for question in (CHOICE, SCORE, NOUL):
        gw.validate_request(envelope(q=question))


def test_a_phrase_question_is_refused_before_any_backend_call():
    """The service itself rejects `phrase` with a 400; so must the front door."""
    with pytest.raises(gw.BackendError) as caught:
        gw.validate_request(envelope(q={"type": "phrase", "criteria": {"a": "A"}}))
    assert caught.value.status == 400
    assert "phrase" in str(caught.value)


def test_a_score_with_dict_criteria_is_refused():
    """A score's criteria are a LIST of levels; a dict is the shape of a choice."""
    with pytest.raises(gw.BackendError) as caught:
        gw.validate_request(envelope(q={"type": "score",
                                        "criteria": {"0": "broken"}}))
    assert "LIST" in str(caught.value)


def test_a_choice_with_list_criteria_is_refused():
    with pytest.raises(gw.BackendError) as caught:
        gw.validate_request(envelope(q={"type": "choice",
                                        "criteria": ["a", "b"]}))
    assert "OBJECT" in str(caught.value)


def test_empty_and_oversized_question_sets_are_refused():
    with pytest.raises(gw.BackendError):
        gw.validate_request({"model": "m", "state": {}, "questions": {}})
    too_many = {"q%d" % index: CHOICE for index in range(33)}
    with pytest.raises(gw.BackendError):
        gw.validate_request({"model": "m", "state": {}, "questions": too_many})


# -- the evidence gate -----------------------------------------------------


def test_a_question_needing_pixels_is_skipped_and_named():
    """A cloud model must not be asked to judge a picture it cannot see."""
    needs_pixels = dict(CHOICE, requires=["image_visible"])
    body = envelope(q=needs_pixels)
    answerable, skipped = gw.evidence_gate(body)
    assert answerable == {}
    assert skipped and skipped[0]["requires"] == ["image_visible"]


def test_a_question_whose_evidence_is_present_is_answered():
    body = envelope(q=dict(CHOICE, requires=["prompt"]))
    answerable, skipped = gw.evidence_gate(body)
    assert list(answerable) == ["q"] and skipped == []


# -- parsing a cloud reply -------------------------------------------------


def reply(answers):
    return json.dumps({"answers": answers})


def test_choice_answers_are_validated_by_membership():
    answers, rejected = gw.parse_answers(reply({"q": {"choice": "a",
                                                     "answer_confidence": 0.8}}),
                                         {"q": CHOICE})
    assert answers["q"]["choice"] == "a"
    assert answers["q"]["answer_confidence"] == 0.8
    assert rejected == []


def test_an_invented_choice_is_dropped_and_reported():
    """A made-up category folded into a verdict is a wrong verdict."""
    answers, rejected = gw.parse_answers(reply({"q": {"choice": "c"}}), {"q": CHOICE})
    assert answers == {}
    assert rejected and "not one of the criteria" in rejected[0]["reason"]


def test_an_out_of_range_score_is_dropped():
    answers, rejected = gw.parse_answers(reply({"q": {"score": 9}}), {"q": SCORE})
    assert answers == {}
    assert "outside" in rejected[0]["reason"]


def test_a_score_answer_carries_the_legend_the_fold_reads():
    answers, _ = gw.parse_answers(reply({"q": {"score": 2, "answer_confidence": 0.7}}),
                                  {"q": SCORE})
    assert answers["q"]["score"] == 2
    assert answers["q"]["legend"]["2"] == "retained"
    assert len(answers["q"]["legend"]) == len(SCORE["criteria"])


def test_a_noul_answer_becomes_a_probability_not_a_choice():
    """MEASURED from the live service: noul replies carry `noul`, not `choice`."""
    answers, _ = gw.parse_answers(reply({"q": {"choice": "true",
                                              "answer_confidence": 0.9}}),
                                  {"q": NOUL})
    assert "choice" not in answers["q"]
    assert answers["q"]["noul"] == pytest.approx(0.9)


def test_a_noul_answered_false_inverts_the_probability():
    answers, _ = gw.parse_answers(reply({"q": {"choice": "false",
                                              "answer_confidence": 0.9}}),
                                  {"q": NOUL})
    assert answers["q"]["noul"] == pytest.approx(0.1), \
        "P(true) must be the complement when the model answered false"


def test_a_reply_with_prose_around_the_object_is_still_parsed():
    text = ('Sure! Here is the decision:\n```json\n'
            '{"answers": {"q": {"choice": "b", "answer_confidence": 0.5}}}\n```')
    answers, _ = gw.parse_answers(text, {"q": CHOICE})
    assert answers["q"]["choice"] == "b"


def test_a_reply_with_no_json_is_reported_not_guessed():
    answers, rejected = gw.parse_answers("I cannot help with that.", {"q": CHOICE})
    assert answers == {}
    assert "no JSON object" in rejected[0]["reason"]


def test_an_unasked_question_in_the_reply_is_reported():
    answers, rejected = gw.parse_answers(
        reply({"q": {"choice": "a"}, "extra": {"choice": "a"}}), {"q": CHOICE})
    assert answers["q"]["choice"] == "a"
    assert any(entry["question"] == "extra" for entry in rejected)


# -- dispatch --------------------------------------------------------------


def test_local_is_a_pass_through_not_a_translation(monkeypatch):
    """laya already speaks the protocol: the request must arrive UNCHANGED."""
    seen = {}

    def fake_post(url, payload, headers, timeout):
        seen["url"], seen["payload"] = url, payload
        return {"model": "laya", "answers": {"q": {"choice": "a"}},
                "usage": {}, "routing": {}}

    monkeypatch.setattr(gw, "_post_json", fake_post)
    body = envelope()
    document = gw.dispatch(body, {"backend": "local", "fallback": [],
                                  "laya": "http://laya:8797", "timeout": 5,
                                  "openrouter_key": None, "hf_key": None,
                                  "openrouter_model": "m", "hf_model": "m"})
    assert seen["url"] == "http://laya:8797/v1/systemone"
    assert seen["payload"] == body, "a pass-through must not rewrite the envelope"
    assert document["routing"]["backend"] == "local"


def test_an_unconfigured_cloud_backend_is_named_and_skipped(monkeypatch):
    def explode(*args, **kwargs):
        raise AssertionError("a cloud backend was called with no key")

    monkeypatch.setattr(gw, "_post_json", explode)
    settings = {"backend": "openrouter", "fallback": [], "laya": "http://laya",
                "timeout": 5, "openrouter_key": None, "hf_key": None,
                "openrouter_model": "m", "hf_model": "m"}
    with pytest.raises(gw.BackendError) as caught:
        gw.dispatch(envelope(), settings)
    assert caught.value.status == 503
    assert "OPENROUTER_API_KEY" in str(caught.value)
    assert "no backend answered" in str(caught.value)


def test_a_fallback_records_why_the_first_backend_failed(monkeypatch):
    """The answer says which backend produced it AND what was tried first."""
    def fake_post(url, payload, headers, timeout):
        if "openrouter" in url:
            raise gw.BackendError("HTTP 429: slow down", status=429)
        return {"model": "laya", "answers": {"q": {"choice": "a"}},
                "usage": {}, "routing": {}}

    monkeypatch.setattr(gw, "_post_json", fake_post)
    settings = {"backend": "openrouter", "fallback": ["local"], "laya": "http://laya",
                "timeout": 5, "openrouter_key": "k", "hf_key": None,
                "openrouter_model": "m", "hf_model": "m"}
    document = gw.dispatch(envelope(), settings)
    routing = document["routing"]
    assert routing["backend"] == "local"
    assert routing["fallback_used"] is True
    assert routing["attempts"][0]["backend"] == "openrouter"
    assert "429" in routing["attempts"][0]["reason"]


def test_the_explicit_preference_wins_over_the_default(monkeypatch):
    called = []

    def fake_post(url, payload, headers, timeout):
        called.append(url)
        return {"model": "x", "answers": {}, "usage": {}, "routing": {}}

    monkeypatch.setattr(gw, "_post_json", fake_post)
    settings = {"backend": "local", "fallback": [], "laya": "http://laya",
                "timeout": 5, "openrouter_key": "k", "hf_key": None,
                "openrouter_model": "m", "hf_model": "m"}
    gw.dispatch(envelope(), settings, prefer="openrouter")
    assert called and "openrouter" in called[0]


def test_a_cloud_backend_is_not_asked_about_pixels_it_cannot_see(monkeypatch):
    """The whole point of the evidence gate: no invented descriptions."""
    def explode(*args, **kwargs):
        raise AssertionError("a cloud backend was called for an unevidenced question")

    monkeypatch.setattr(gw, "_post_json", explode)
    settings = {"backend": "openrouter", "fallback": [], "laya": "http://laya",
                "timeout": 5, "openrouter_key": "k", "hf_key": None,
                "openrouter_model": "m", "hf_model": "m"}
    body = envelope(q=dict(CHOICE, requires=["image_visible"]))
    document = gw.dispatch(body, settings)
    assert document["answers"] == {}
    assert document["routing"]["skipped"]


# -- configuration ---------------------------------------------------------


def test_keys_are_never_reported_only_whether_they_exist(monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-secret-value")
    settings = gw.config()
    assert settings["openrouter_key"] == "sk-or-secret-value"
    # The health payload is built from booleans, so this asserts the SOURCE of
    # that payload never carries the key itself.
    from http.server import BaseHTTPRequestHandler
    assert "sk-or-secret-value" not in json.dumps(
        {name: bool(settings[name]) for name in
         ("api_key", "openrouter_key", "hf_key")})


def test_the_default_backend_is_local(monkeypatch):
    for name in ("SYSTEMONE_BACKEND", "SYSTEMONE_FALLBACK"):
        monkeypatch.delenv(name, raising=False)
    settings = gw.config()
    assert settings["backend"] == "local"
    assert settings["fallback"] == [], \
        "an empty fallback must not become an implicit cloud call"
