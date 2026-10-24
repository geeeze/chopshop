#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tests for scripts/jev_annotate.py.

The annotator is an OPTIONAL add-on: it needs TYPESAFE_API_KEY and a network
round-trip to a decision service, so the default suite must run without either.
Everything here exercises the pure projection/validation/verdict functions
against a real-shaped preflight manifest; the network seam (``call_jev``) is
never hit.
"""

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")
for p in (ROOT, SCRIPTS):
    if p not in sys.path:
        sys.path.insert(0, p)

import jev_annotate as jev  # noqa: E402


# A manifest shaped like the real preflight.py output (findings use ``detail``,
# node counts live under stats.static, colour lists are long strings, and the
# static block carries an off-palette colour list that must never leak).
REAL_SHAPED_MANIFEST = {
    "passed": False,
    "input": {
        "file": "/repo/02_traced/00-example/candidate_03.svg",
        "kind": "svg",
        "spec": "/repo/spec.json",
    },
    "summary": {
        "hard": 3, "advisory": 3, "print_method": "screen_print",
        "require_cmyk": False, "tac_exact": False,
        "by_layer": {
            "source_validation": {"hard": 1, "advisory": 3},
            "render_preflight": {"hard": 2, "advisory": 0},
        },
    },
    "findings": [
        {"rule": "COLOR_COUNT", "severity": "hard", "layer": "source_validation",
         "detail": "Color count 3748 exceeds max 6 (used: " + ", ".join("#%06x" % i for i in range(2000)) + ")"},
        {"rule": "NODE_COUNT", "severity": "advisory", "layer": "source_validation",
         "detail": "Path #1 (no id) has 969 nodes, above the limit of 500"},
    ],
    "notes": [
        "TAC is an ESTIMATE: source is not CMYK, Ghostscript built separations on the fly.",
    ],
    "stats": {
        "input_kind": "svg",
        "dpi": 300,
        "hard_findings": 3,
        "advisory_findings": 3,
        "rendered_distinct_colors": 64110,
        "rendered_ink_colors": 8,
        "rendered_screens": 8,
        "rendered_continuous_tone": True,
        "rendered_top_inks": [{"hex": "#000000", "percent": 41.2}] * 20,
        "ink_tac_max_percent": 256.5,
        "ink_tac_limit_percent": 300.0,
        "tac_exact": False,
        "tac_is_estimate": True,
        "dark_garment_underbase": True,
        "pdf_pages": 1,
        "pdf_images": [],
        "pdf_fonts": [],
        "proof_path": "/repo/.preflight-work/candidate_03.proof.png",
        "pdf_path": "/repo/.preflight-work/candidate_03.print.pdf",
        "static": {
            "paths": 5042,
            "path_nodes_total": 92259,
            "path_nodes_max": 969,
            "paths_over_node_limit": 2,
            "color_count": 3748,
            "palette_conformance": "3748 of 3748 declared colours off palette",
            # The leak risk: a huge colour list that must NOT be copied whole.
            "off_palette_colors": ["#%06x" % i for i in range(3748)],
            "palette": ["#%06x" % i for i in range(6)],
        },
    },
}


def test_project_manifest_matches_real_schema():
    state = jev.project_manifest(REAL_SHAPED_MANIFEST)
    assert state["passed"] is False
    assert state["manifest_schema"] == "preflight-manifest"
    # Input file is shortened to its basename.
    assert state["input"]["file"] == "candidate_03.svg"
    assert state["input"]["kind"] == "svg"
    # summary carries the real keys.
    assert state["summary"]["hard"] == 3
    assert state["summary"]["by_layer"]["render_preflight"]["hard"] == 2
    # notes are scrubbed and projected.
    assert state["notes"][0].startswith("TAC is an ESTIMATE")


def test_finding_text_is_scrubbed_and_bounded():
    state = jev.project_manifest(REAL_SHAPED_MANIFEST)
    findings = state["findings"]
    # The human-readable ``detail`` survives (it is the decision content).
    assert findings[0]["rule"] == "COLOR_COUNT"
    assert findings[0]["detail"].startswith("Color count 3748 exceeds max 6")
    # The giant embedded colour list is collapsed to a gist, not sent verbatim.
    assert len(findings[0]["detail"]) <= 400
    assert "more omitted" in findings[0]["detail"]
    assert findings[1]["detail"] == "Path #1 (no id) has 969 nodes, above the limit of 500"


def test_stats_lift_node_counts_and_drop_lists():
    state = jev.project_manifest(REAL_SHAPED_MANIFEST)
    stats = state["stats"]
    # Node/geometry figures come from stats.static.
    assert stats["paths"] == 5042
    assert stats["path_nodes_total"] == 92259
    assert stats["path_nodes_max"] == 969
    assert stats["color_count"] == 3748
    assert stats["palette_conformance"].startswith("3748 of 3748")
    # Rendered metrics present.
    assert stats["rendered_distinct_colors"] == 64110
    assert stats["rendered_ink_colors"] == 8
    # Lists are reduced to counts, not sent whole.
    assert stats["pdf_images"] == {"count": 0}
    assert stats["pdf_fonts"] == {"count": 0, "embedded": 0}
    # rendered_top_inks is capped.
    assert len(stats["rendered_top_inks"]) <= 12
    # Paths are shortened.
    assert stats["proof_path"] == "candidate_03.proof.png"
    # No giant colour list leaks into the projection (regression: v0.3 copied
    # the whole stats.static dict, including off_palette_colors, verbatim).
    assert "static" not in stats
    assert "off_palette_colors" not in stats
    assert "declared_colors" not in stats


def test_projection_is_compact_vs_manifest():
    state = jev.project_manifest(REAL_SHAPED_MANIFEST)
    assert len(json.dumps(state)) < len(json.dumps(REAL_SHAPED_MANIFEST))


def test_build_request_shapes_the_four_questions():
    state = jev.project_manifest(REAL_SHAPED_MANIFEST)
    request = jev.build_request(state)
    assert request["model"] == "jev-latest"
    assert set(request["questions"]) == {
        "failure_mode", "print_route", "tonal_structure", "evidence_is_actionable"
    }
    assert request["questions"]["tonal_structure"]["type"] == "score"
    assert request["questions"]["evidence_is_actionable"]["type"] == "noul"


def test_validate_response_rejects_missing_answers():
    response = {"model": "jev-1.13.0", "answers": {"failure_mode": {"choice": "screen_explosion"}}}
    with pytest.raises(RuntimeError, match="missing answers"):
        jev.validate_response(response)


def test_compose_verdict_thresholds_confidence():
    answers = {
        "failure_mode": {"type": "choice", "choice": "screen_explosion", "confidence": 0.97},
        "print_route": {"type": "choice", "choice": "process_halftone", "confidence": 0.55},
        "tonal_structure": {"type": "score", "score": 2.1, "confidence": 0.7,
                            "legend": {"0": "Broken", "1": "Flat", "2": "Retained", "3": "Engraving-grade"}},
        "evidence_is_actionable": {"type": "noul", "noul": 0.2},
    }
    verdict = jev.compose_verdict(answers, confidence_floor=0.6)
    assert verdict["headline"] == "screen_explosion"
    assert verdict["tonal_label"] == "Retained"
    assert verdict["tonal_score"] == 2.1
    assert verdict["evidence_actionable"] is False
    # print_route was below the floor -> surfaced, not settled.
    assert "print_route" in verdict["low_confidence"]
    assert "failure_mode" not in verdict["low_confidence"]


def test_make_annotation_ok(tmp_path):
    state = jev.project_manifest(REAL_SHAPED_MANIFEST)
    request = jev.build_request(state)
    response = {
        "model": "jev-1.13.0",
        "answers": {
            "failure_mode": {"type": "choice", "choice": "screen_explosion", "confidence": 0.98},
            "print_route": {"type": "choice", "choice": "process_halftone", "confidence": 0.95},
            "tonal_structure": {"type": "score", "score": 1.2, "confidence": 0.8,
                                "legend": {"0": "Broken", "1": "Flat", "2": "Retained", "3": "Engraving-grade"}},
            "evidence_is_actionable": {"type": "noul", "noul": 0.99},
        },
        "usage": {"input_tokens": 400, "output_tokens": 50},
    }
    manifest_path = tmp_path / "candidate_03.manifest.json"
    annotation = jev.make_annotation(manifest_path, state, request, response)
    assert annotation["status"] == "ok"
    assert annotation["schema"] == "chopshop-jev-annotation-0.4"
    assert annotation["answers"]["failure_mode"]["choice"] == "screen_explosion"
    assert annotation["verdict"]["headline"] == "screen_explosion"
    assert annotation["usage"]["input_tokens"] == 400


def test_optional_without_key_is_non_blocking(tmp_path, monkeypatch):
    manifest_path = tmp_path / "candidate_03.manifest.json"
    jev._write_json(manifest_path, REAL_SHAPED_MANIFEST)
    # Hermetic: no exported key AND no dotenv files, so the suite never reads
    # the real Hermes env file or touches the network.
    monkeypatch.delenv("JEV_API_KEY", raising=False)
    monkeypatch.delenv("TYPESAFE_API_KEY", raising=False)
    monkeypatch.setattr(jev, "DEFAULT_ENV_FILES", ())
    out = tmp_path / "candidate_03.jev.json"
    assert jev.main([str(manifest_path), "--optional", "--output", str(out)]) == 0
    payload = json.loads(out.read_text())
    assert payload["status"] == "skipped"
    assert "verdict" not in payload


def test_env_file_values_extracts_only_jev_keys(tmp_path):
    envfile = tmp_path / ".env"
    envfile.write_text(
        "JEV_API_KEY=test-key-123\n"
        "TYPESAFE_MODEL=jev-custom\n"
        "DEEPSEEK_API_KEY=must-not-leak\n"
        "OPENROUTER_API_KEY=must-not-leak\n"
    )
    vals = jev._env_file_values(envfile)
    assert vals == {"JEV_API_KEY": "test-key-123", "TYPESAFE_MODEL": "jev-custom"}
    assert "DEEPSEEK_API_KEY" not in vals
    assert "OPENROUTER_API_KEY" not in vals


def test_resolve_env_prefers_environment_then_jev_name(tmp_path, monkeypatch):
    envfile = tmp_path / ".env"
    envfile.write_text("JEV_API_KEY=from-file\nTYPESAFE_API_KEY=from-file-legacy\n")
    vals = jev._env_file_values(envfile)

    # Exported JEV_API_KEY wins over the file.
    monkeypatch.setenv("JEV_API_KEY", "from-env")
    assert jev.resolve_env(("JEV_API_KEY", "TYPESAFE_API_KEY"), None, vals) == "from-env"

    # Without an exported JEV key, the file's JEV key is used before the legacy name.
    monkeypatch.delenv("JEV_API_KEY", raising=False)
    assert jev.resolve_env(("JEV_API_KEY", "TYPESAFE_API_KEY"), None, vals) == "from-file"

    # Legacy TYPESAFE_API_KEY still resolves when nothing else is present.
    assert jev.resolve_env(("TYPESAFE_API_KEY",), None, vals) == "from-file-legacy"

    # Missing everything falls back to the default.
    assert jev.resolve_env(("JEV_MODEL",), "jev-default", {}) == "jev-default"


def test_http_timeout_resolves_from_env_and_survives_a_typo(capsys):
    # The caller's subprocess budget (the runner allows 180s) does NOT reach
    # this: the runner does not pass --timeout, so the annotator's own HTTP
    # budget was the binding constraint and was hard-coded. A local service
    # loading a checkpoint it has not loaded yet spends tens of seconds doing it
    # and then failed as a timeout, which reaches the operator as "Jev call
    # failed" -- measured, not hypothetical.
    assert jev._env_float(("JEV_HTTP_TIMEOUT",), 20.0, {}) == 20.0
    assert jev._env_float(("JEV_HTTP_TIMEOUT",), 20.0, {"JEV_HTTP_TIMEOUT": "90"}) == 90.0
    assert jev._env_float(("JEV_HTTP_TIMEOUT", "TYPESAFE_HTTP_TIMEOUT"), 20.0,
                          {"TYPESAFE_HTTP_TIMEOUT": "45"}) == 45.0
    # A typo warns and falls back rather than raising: this runs inside the
    # caller's subprocess, and a bad number in a dotfile is a configuration
    # mistake, not evidence that the decision service is down.
    assert jev._env_float(("JEV_HTTP_TIMEOUT",), 20.0, {"JEV_HTTP_TIMEOUT": "soon"}) == 20.0
    assert "not a number" in capsys.readouterr().err


def test_main_honours_the_env_timeout(tmp_path, monkeypatch):
    envfile = tmp_path / ".env"
    envfile.write_text("JEV_API_KEY=test-key-123\nJEV_HTTP_TIMEOUT=75\n")
    monkeypatch.setattr(jev, "DEFAULT_ENV_FILES", (envfile,))
    monkeypatch.delenv("JEV_API_KEY", raising=False)
    monkeypatch.delenv("JEV_HTTP_TIMEOUT", raising=False)

    manifest = tmp_path / "candidate_03.manifest.json"
    jev._write_json(manifest, REAL_SHAPED_MANIFEST)
    captured = {}

    def fake_call_jev(request, *, api_key, endpoint, timeout):
        captured["timeout"] = timeout
        return {"model": "m", "answers": {
            "failure_mode": {"type": "choice", "choice": "unclear", "confidence": 0.9},
            "print_route": {"type": "choice", "choice": "unclear", "confidence": 0.9},
            "tonal_structure": {"type": "score", "score": 1.0, "confidence": 0.9,
                                "legend": {"0": "a", "1": "b"}},
            "evidence_is_actionable": {"type": "noul", "noul": 0.9}}}

    monkeypatch.setattr(jev, "call_jev", fake_call_jev)

    assert jev.main([str(manifest), "--output", str(tmp_path / "o.json")]) == 0
    assert captured["timeout"] == 75.0

    # An explicit flag still wins over the environment.
    assert jev.main([str(manifest), "--output", str(tmp_path / "o2.json"),
                     "--timeout", "5"]) == 0
    assert captured["timeout"] == 5.0


def test_compose_verdict_real_score_confidence_is_zero():
    # Live Jev responses report confidence: 0.0 for score answers; the real
    # certainty is the probabilities distribution. Regression guard: the floor
    # check must use probabilities, not the bogus 0.0 confidence, otherwise
    # every tonal score would be wrongly flagged low-confidence.
    answers = {
        "failure_mode": {"type": "choice", "choice": "screen_explosion", "confidence": 0.74},
        "print_route": {"type": "choice", "choice": "process_halftone", "confidence": 0.97},
        "tonal_structure": {"type": "score", "score": 1.15, "confidence": 0.0,
                            "legend": {"0": "Broken", "1": "Flat", "2": "Retained", "3": "Engraving-grade"},
                            "probabilities": {"0": 0.39, "1": 0.25, "2": 0.17, "3": 0.19}},
        "evidence_is_actionable": {"type": "noul", "noul": 0.14},
    }
    verdict = jev.compose_verdict(answers, confidence_floor=0.6)
    assert verdict["headline"] == "screen_explosion"
    assert verdict["print_route"] == "process_halftone"
    assert verdict["tonal_score"] == 1.15
    assert verdict["tonal_label"] == "Flat"
    # score's max probability is 0.39 (< 0.6) -> genuinely uncertain, flagged.
    assert "tonal_structure" in verdict["low_confidence"]
    # choice answers above the floor are settled.
    assert "failure_mode" not in verdict["low_confidence"]
    assert "print_route" not in verdict["low_confidence"]
    # noul 0.14 -> actionable False; certainty 0.72 -> not flagged.
    assert verdict["evidence_actionable"] is False
    assert "evidence_is_actionable" not in verdict["low_confidence"]


def test_compose_verdict_noul_near_coinflip_is_low_confidence():
    answers = {
        "failure_mode": {"type": "choice", "choice": "unclear", "confidence": 0.9},
        "print_route": {"type": "choice", "choice": "unclear", "confidence": 0.9},
        "tonal_structure": {"type": "score", "score": 2.0, "confidence": 0.9,
                            "legend": {"0": "a", "1": "b", "2": "c"}},
        "evidence_is_actionable": {"type": "noul", "noul": 0.55},
    }
    verdict = jev.compose_verdict(answers, confidence_floor=0.6)
    # noul 0.55 is a coin-flip: certainty 0.1 < 0.6 -> flagged, not settled.
    assert verdict["evidence_actionable"] is True
    assert "evidence_is_actionable" in verdict["low_confidence"]


def test_main_resolves_key_from_dotenv_and_calls_jev(tmp_path, monkeypatch):
    envfile = tmp_path / ".env"
    envfile.write_text("JEV_API_KEY=test-key-123\n")
    monkeypatch.setattr(jev, "DEFAULT_ENV_FILES", (envfile,))
    # Scrub every key name the annotator accepts: the developer's own
    # CHOPSHOP_OPENROUTER_KEY in the shell would otherwise outrank the dotenv's
    # JEV_API_KEY and this would test the developer's box, not the dotenv path.
    for name in ("JEV_API_KEY", "TYPESAFE_API_KEY", "LAYA_API_KEY",
                 "CHOPSHOP_OPENROUTER_KEY"):
        monkeypatch.delenv(name, raising=False)

    manifest = tmp_path / "candidate_03.manifest.json"
    jev._write_json(manifest, REAL_SHAPED_MANIFEST)
    out = tmp_path / "candidate_03.jev.json"

    captured = {}

    def fake_call_jev(request, *, api_key, endpoint, timeout):
        captured["api_key"] = api_key
        captured["endpoint"] = endpoint
        return {
            "model": "jev-1.13.0",
            "answers": {
                "failure_mode": {"type": "choice", "choice": "screen_explosion", "confidence": 0.9},
                "print_route": {"type": "choice", "choice": "process_halftone", "confidence": 0.9},
                "tonal_structure": {"type": "score", "score": 1.0, "confidence": 0.9,
                                    "legend": {"0": "a", "1": "b", "2": "c"}},
                "evidence_is_actionable": {"type": "noul", "noul": 0.9},
            },
        }

    monkeypatch.setattr(jev, "call_jev", fake_call_jev)
    assert jev.main([str(manifest), "--output", str(out)]) == 0

    assert captured["api_key"] == "test-key-123"
    assert captured["endpoint"] == jev.DEFAULT_ENDPOINT
    payload = json.loads(out.read_text())
    assert payload["status"] == "ok"
    assert payload["verdict"]["headline"] == "screen_explosion"


def test_main_resolves_openrouter_key_from_environment(tmp_path, monkeypatch):
    """CHOPSHOP_OPENROUTER_KEY is the workflow's name for the hosted Decisions-API
    key (Upstage Solar Decide Flash). It resolves like the others, so pointing
    JEV_ENDPOINT at OpenRouter needs no code change. Plain OPENROUTER_API_KEY is
    NOT accepted -- on this box that is the chat/LLM provider key, a different
    credential for a different API."""
    monkeypatch.setattr(jev, "DEFAULT_ENV_FILES", (tmp_path / "absent.env",))
    for name in ("JEV_API_KEY", "TYPESAFE_API_KEY", "LAYA_API_KEY"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("CHOPSHOP_OPENROUTER_KEY", "or-key-456")

    manifest = tmp_path / "candidate_03.manifest.json"
    jev._write_json(manifest, REAL_SHAPED_MANIFEST)
    out = tmp_path / "candidate_03.jev.json"

    captured = {}

    def fake_call_jev(request, *, api_key, endpoint, timeout):
        captured["api_key"] = api_key
        captured["endpoint"] = endpoint
        return {
            "model": "upstage/solar-decide-flash-20261008",
            "answers": {
                "failure_mode": {"type": "choice", "choice": "screen_explosion", "confidence": 0.9},
                "print_route": {"type": "choice", "choice": "process_halftone", "confidence": 0.9},
                "tonal_structure": {"type": "score", "score": 1.0, "confidence": 0.9,
                                    "legend": {"0": "a", "1": "b", "2": "c"}},
                "evidence_is_actionable": {"type": "noul", "noul": 0.9},
            },
        }

    monkeypatch.setattr(jev, "call_jev", fake_call_jev)
    assert jev.main([str(manifest), "--output", str(out)]) == 0
    assert captured["api_key"] == "or-key-456"
    assert captured["endpoint"] == jev.DEFAULT_ENDPOINT


def test_openrouter_chat_key_is_not_read_as_a_decision_key(tmp_path, monkeypatch):
    """The chat/LLM OPENROUTER_API_KEY must never be resolved as the decision key:
    sending it to a decision service is a 401 that blames the wrong thing."""
    monkeypatch.setattr(jev, "DEFAULT_ENV_FILES", (tmp_path / "absent.env",))
    for name in ("JEV_API_KEY", "TYPESAFE_API_KEY", "LAYA_API_KEY",
                 "CHOPSHOP_OPENROUTER_KEY"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("OPENROUTER_API_KEY", "chat-key-should-not-leak")

    manifest = tmp_path / "candidate_03.manifest.json"
    jev._write_json(manifest, REAL_SHAPED_MANIFEST)
    out = tmp_path / "candidate_03.jev.json"
    # --optional: no key resolves, so it must SKIP, not call the service with the
    # chat key or crash.
    assert jev.main([str(manifest), "--output", str(out), "--optional"]) == 0
    payload = json.loads(out.read_text())
    assert payload["status"] == "skipped"
    assert "no API key" in payload["reason"]


# --- the local backend ------------------------------------------------------
#
# The backend is chosen by JEV_ENDPOINT alone, so ``main`` is the same code on
# both. Two things differ underneath, and both are pinned here:
#
# LAYA-ANSWER-CONFIDENCE. A local decision service that speaks the Jev wire
# protocol sends the probability mass on the reported answer as
# ``answer_confidence`` and an entropy-based ``confidence`` beside it. They are
# different functions of the same distribution, so a floor applied to the wrong
# one gates a different set of answers. The verdict must gate on the mass.
#
# LAYA-REQUEST-SHAPE. The projection is what goes over the wire; asserting the
# state arrives as a bounded object (never the manifest, never the colour lists)
# keeps the scrub honest on a service that is not the one it was written for.


def test_answer_confidence_is_preferred_over_entropy_confidence():
    # Shaped as laya-serve returns: a peaked distribution (mass 0.93) reported
    # with a LOW entropy confidence, which is the pair that would otherwise be
    # flagged as uncertain even though the answer is settled.
    peaked = {
        "type": "choice", "choice": "screen_explosion",
        "probabilities": {"screen_explosion": 0.93, "continuous_tone": 0.04, "unclear": 0.03},
        "confidence": 0.12, "answer_confidence": 0.93,
    }
    # And the inverse: a high entropy confidence over a flat distribution whose
    # mass is under the floor, which must still be surfaced.
    flat = {
        "type": "choice", "choice": "process_halftone",
        "probabilities": {"process_halftone": 0.41, "dtg_or_dtf": 0.31, "unclear": 0.28},
        "confidence": 0.88, "answer_confidence": 0.41,
    }
    answers = {
        "failure_mode": peaked,
        "print_route": flat,
        "tonal_structure": {"type": "score", "score": 2.0, "confidence": 0.99,
                            "answer_confidence": 0.55,
                            "legend": {"0": "a", "1": "b", "2": "c", "3": "d"}},
        "evidence_is_actionable": {"type": "noul", "noul": 0.87,
                                   "confidence": 0.87, "answer_confidence": 0.87},
    }
    verdict = jev.compose_verdict(answers, confidence_floor=0.6)

    assert verdict["headline"] == "screen_explosion"
    assert "failure_mode" not in verdict["low_confidence"]      # mass 0.93
    assert "print_route" in verdict["low_confidence"]           # mass 0.41
    assert "tonal_structure" in verdict["low_confidence"]       # mass 0.55
    assert verdict["evidence_actionable"] is True
    assert "evidence_is_actionable" not in verdict["low_confidence"]  # 0.87

    # The same answers WITHOUT the mass field keep the pre-existing behaviour,
    # which is what a live TypeSafe response looks like: the floor reads
    # `confidence` for a choice and `max(probabilities)` for a score.
    jev_shaped = dict(answers)
    jev_shaped["failure_mode"] = {"type": "choice", "choice": "screen_explosion", "confidence": 0.12}
    jev_shaped["print_route"] = {"type": "choice", "choice": "process_halftone", "confidence": 0.88}
    jev_shaped["tonal_structure"] = {"type": "score", "score": 2.0, "confidence": 0.0,
                                     "legend": {"0": "a", "1": "b", "2": "c", "3": "d"},
                                     "probabilities": {"0": 0.1, "1": 0.2, "2": 0.6, "3": 0.1}}
    fallback = jev.compose_verdict(jev_shaped, confidence_floor=0.6)
    assert "failure_mode" in fallback["low_confidence"]
    assert "print_route" not in fallback["low_confidence"]
    assert "tonal_structure" not in fallback["low_confidence"]   # max(p) = 0.6


class _LayaStub(BaseHTTPRequestHandler):
    """A stand-in for ``laya-serve``, enforcing ITS documented request limits.

    The limits are transcribed from laya's ``docs/http-api.md`` and its
    ``_check_request_limits``: they are checked before tokenization there, so an
    annotator that steps outside them gets a 413 from the real server and
    nothing useful here either.
    """

    requests: list = []

    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler's protocol
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.__class__.requests.append((self.path, dict(self.headers), body))

        assert body.get("state") is not None, "a null state is a 400 on the real server"
        assert isinstance(body.get("questions"), dict)
        assert len(body["questions"]) <= 64
        for qid, question in body["questions"].items():
            if question.get("type") == "choice":
                assert len(question.get("criteria") or []) <= 100, qid
            if question.get("type") == "score":
                assert len(question.get("criteria") or []) <= 32, qid
        assert len(str(body["state"])) <= 50_000

        raw = json.dumps({
            "model": "laya-rl-agent",
            "answers": {
                "failure_mode": {
                    "type": "choice", "choice": "screen_explosion",
                    "probabilities": {"screen_explosion": 0.9281, "continuous_tone": 0.0412,
                                      "no_hard_failure": 0.0307},
                    "confidence": 0.4534, "answer_confidence": 0.9281,
                    "action": {"act_probability": 1.0},
                },
                "print_route": {
                    "type": "choice", "choice": "process_halftone",
                    "probabilities": {"process_halftone": 0.31, "dtg_or_dtf": 0.38, "unclear": 0.31},
                    "confidence": 0.71, "answer_confidence": 0.38,
                },
                "tonal_structure": {
                    "type": "score", "score": 2.6389,
                    "legend": {"0": "Broken", "1": "Flat", "2": "Retained", "3": "Engraving-grade"},
                    "probabilities": {"0": 0.0099, "1": 0.0713, "2": 0.536, "3": 0.3828},
                    "confidence": 0.3542, "answer_confidence": 0.536,
                },
                "evidence_is_actionable": {"type": "noul", "noul": 0.87,
                                           "confidence": 0.87, "answer_confidence": 0.87},
            },
            "usage": {"input_tokens": 74, "output_tokens": 0},
            "routing": {"model": "english", "repo": "convaiinnovations/laya",
                        "reason": "English Latin text"},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        pass


def test_laya_endpoint_answers_end_to_end(tmp_path):
    # A REAL HTTP round trip through jev.main against a server that speaks the
    # Jev wire protocol the way the local backend does — the deployed shape of
    # this integration, minus the model weights.
    _LayaStub.requests = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), _LayaStub)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        endpoint = "http://127.0.0.1:%d/v1/systemone" % server.server_address[1]
        manifest = tmp_path / "candidate_03.manifest.json"
        jev._write_json(manifest, REAL_SHAPED_MANIFEST)
        out = tmp_path / "candidate_03.jev.json"

        assert jev.main([str(manifest), "--output", str(out),
                         "--endpoint", endpoint, "--api-key", "local-token"]) == 0

        payload = json.loads(out.read_text())
        assert payload["status"] == "ok"
        # The service names itself; the annotator reports what answered.
        assert payload["model"] == "laya-rl-agent"
        assert payload["verdict"]["headline"] == "screen_explosion"
        assert payload["verdict"]["print_route"] == "process_halftone"
        assert payload["verdict"]["tonal_label"] == "Engraving-grade"  # 2.6389 rounds to 3
        assert payload["verdict"]["evidence_actionable"] is True
        # The floor reads the probability mass, not the entropy confidence.
        assert payload["verdict"]["low_confidence"] == ["print_route", "tonal_structure"]
        assert payload["usage"] == {"input_tokens": 74, "output_tokens": 0}

        # What actually went over the wire. The envelope is EXACTLY these three
        # keys, and that is a measured boundary, not a preference: the hosted
        # service answers `400 api_usage_error: Invalid request` to a request
        # carrying an extra key beside them — including the printability request
        # that had worked for a year. Which template answered is recorded in the
        # SIDECAR. See jev.ENVELOPE_KEYS.
        path, headers, body = _LayaStub.requests[0]
        assert path == "/v1/systemone"
        assert headers["Authorization"] == "Bearer local-token"
        assert set(body) == {"model", "state", "questions"}, (
            "an extra envelope key is refused by the hosted service"
        )
        assert tuple(sorted(body)) == tuple(sorted(jev.ENVELOPE_KEYS))
        assert isinstance(body["state"], dict), "laya serializes an object state itself"
        assert body["state"]["stats"]["path_nodes_max"] == 969
        assert body["state"]["summary"]["hard"] == 3
        # The projection, not the manifest: the off-palette colour list and the
        # full finding text never leave the machine.
        assert "off_palette_colors" not in json.dumps(body)
        assert len(str(body["state"])) < 50_000
        assert {k: v["type"] for k, v in body["questions"].items()} == {
            "failure_mode": "choice", "print_route": "choice",
            "tonal_structure": "score", "evidence_is_actionable": "noul",
        }
        # The local backend's vocabulary is choice/score/noul, and so is the
        # HOSTED one's: a set containing a `phrase` question is refused by the
        # local service with
        #   422 "unknown type 'phrase'; use one of ['choice', 'noul', 'score']"
        # and by the hosted service with
        #   400 api_usage_error: Invalid request
        # Both measured. So a phrase-using profile is not "TypeSafe-only" — it is
        # unsupported on EITHER backend, which is why no shipped profile asks one
        # (see jev.UNSUPPORTED_QUESTION_TYPES and docs/dataset-translation.md).
        local_vocabulary = {"choice", "score", "noul"}
        assert {v["type"] for v in body["questions"].values()} <= local_vocabulary
        assert jev.PROFILES["printability"]["questions"]["failure_mode"]["type"] in local_vocabulary
        assert "phrase" not in jev.QUESTION_TYPES
        assert "phrase" in jev.UNSUPPORTED_QUESTION_TYPES
    finally:
        server.shutdown()
        server.server_close()

