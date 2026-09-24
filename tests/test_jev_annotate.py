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
    # the real ~/.hermes/.env or touches the network.
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
    monkeypatch.delenv("JEV_API_KEY", raising=False)
    monkeypatch.delenv("TYPESAFE_API_KEY", raising=False)

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
