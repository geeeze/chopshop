#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Configuration for BOTH backends: laya as a first-class alternate, and the
confidence-floor knob the README promised (chopshop-jev#6, and the caller's half
of #1).

Two seams are pinned here, and they exist for the same reason -- a backend that
is "supported" in a docstring but not in the key resolution is not supported:

  * `LAYA_API_KEY` is the local service's own name for the bearer token. The
    runner accepts it, slop_cannon forwards it, and the annotator must READ it,
    or the run dies one level down as "no API key" after the caller passed its
    own check. (That is the bug 875687c fixed in slop_cannon; this is the same
    bug caught before it reaches the runner path.)
  * `--confidence-floor` / `JEV_CONFIDENCE_FLOOR` is the knob README.md:186
    claimed existed. It is advisory: it moves the NOTE, never the masses.
"""

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")
for p in (ROOT, SCRIPTS):
    if p not in sys.path:
        sys.path.insert(0, p)

import jev_annotate as jev  # noqa: E402

KEY_ORDER = ("JEV_API_KEY", "TYPESAFE_API_KEY", "LAYA_API_KEY",
             "CHOPSHOP_OPENROUTER_KEY")

# A full printability response, shaped as the hosted service returns it.
PRINTABILITY_RESPONSE = {
    "model": "jev-1.13.0",
    "answers": {
        "failure_mode": {"type": "choice", "choice": "screen_explosion", "confidence": 0.9},
        "print_route": {"type": "choice", "choice": "process_halftone", "confidence": 0.9},
        "tonal_structure": {"type": "score", "score": 1.0, "confidence": 0.9,
                            "legend": {"0": "a", "1": "b", "2": "c"}},
        "evidence_is_actionable": {"type": "noul", "noul": 0.9},
    },
}


def _isolate(tmp_path, monkeypatch):
    """Empty env files and clear every key, so nothing is resolved by accident."""
    empty = tmp_path / "empty.env"
    empty.write_text("# nothing here on purpose\n")
    monkeypatch.setattr(jev, "DEFAULT_ENV_FILES", (empty,))
    for name in KEY_ORDER + ("JEV_CONFIDENCE_FLOOR", "TYPESAFE_CONFIDENCE_FLOOR"):
        monkeypatch.delenv(name, raising=False)
    return empty


def _run_main(tmp_path, monkeypatch, argv, response=PRINTABILITY_RESPONSE):
    """main() against a stubbed call_jev; returns (exit, payload or None)."""
    manifest = tmp_path / "candidate_03.manifest.json"
    manifest.write_text(json.dumps({"schema": "preflight-manifest"}))
    out = tmp_path / "candidate_03.jev.json"
    captured = {}

    def fake_call_jev(request, *, api_key, endpoint, timeout):
        captured["api_key"] = api_key
        return response

    monkeypatch.setattr(jev, "call_jev", fake_call_jev)
    code = jev.main([str(manifest), "--output", str(out)] + argv)
    payload = json.loads(out.read_text()) if out.exists() else None
    return code, payload, captured


# --- the alternate backend is reachable by its own name ----------------------

def test_laya_key_from_the_environment_reaches_the_call(tmp_path, monkeypatch):
    """The whole of the alternate-backend claim: LAYA_API_KEY alone is enough.

    Without this the runner's own check (which accepts LAYA_API_KEY) passes and
    the annotator then refuses, which is a failure reported as a wiring bug.
    """
    _isolate(tmp_path, monkeypatch)
    monkeypatch.setenv("LAYA_API_KEY", "laya-local-token")

    code, payload, captured = _run_main(tmp_path, monkeypatch, [])

    assert code == 0, payload
    assert captured["api_key"] == "laya-local-token"
    assert payload["status"] == "ok"


def test_laya_key_is_allowed_out_of_the_dotenv_file(tmp_path, monkeypatch):
    """`LAYA_API_KEY` is on the allowlist, and unrelated secrets beside it are not."""
    _isolate(tmp_path, monkeypatch)
    envfile = tmp_path / ".env"
    envfile.write_text(
        "OTHER_PROVIDER_SECRET=must-never-be-read\n"
        "LAYA_API_KEY=from-dotfile\n")
    monkeypatch.setattr(jev, "DEFAULT_ENV_FILES", (envfile,))

    values = jev._env_file_values(envfile)
    assert values["LAYA_API_KEY"] == "from-dotfile"
    assert "OTHER_PROVIDER_SECRET" not in values, (
        "the allowlist is what keeps this file from leaking into the request")


def test_the_documented_key_order_is_jev_then_typesafe_then_laya(tmp_path, monkeypatch):
    """Preference, not accident: the hosted name wins if both are set, so adding
    LAYA_API_KEY cannot silently retarget an existing hosted deployment."""
    _isolate(tmp_path, monkeypatch)
    # The dotenv allowlist has to carry it too, or an operator who stores the
    # local service's token in a dotfile (the documented way) gets nothing.
    assert "LAYA_API_KEY" in jev._JEV_ENV_KEYS
    monkeypatch.setenv("LAYA_API_KEY", "laya-value")
    monkeypatch.setenv("TYPESAFE_API_KEY", "typesafe-value")
    monkeypatch.setenv("JEV_API_KEY", "jev-value")
    assert jev.resolve_env(KEY_ORDER, None, {}) == "jev-value"

    monkeypatch.delenv("JEV_API_KEY")
    assert jev.resolve_env(KEY_ORDER, None, {}) == "typesafe-value"

    monkeypatch.delenv("TYPESAFE_API_KEY")
    assert jev.resolve_env(KEY_ORDER, None, {}) == "laya-value"


def test_a_missing_key_says_which_names_would_fix_it(tmp_path, monkeypatch, capsys):
    """The refusal names every variable that works, so the operator of a local
    deployment is not told to set the hosted service's key."""
    _isolate(tmp_path, monkeypatch)
    code, payload, _ = _run_main(tmp_path, monkeypatch, [])
    assert code == 2
    assert payload is None, "no key means no call, so no sidecar"
    message = capsys.readouterr().err
    assert "JEV_API_KEY" in message
    assert "LAYA_API_KEY" in message


# --- the floor knob ----------------------------------------------------------

def test_the_floor_flag_reaches_the_dry_run_envelope(tmp_path, monkeypatch):
    """README said the floor is configurable; this is the flag that makes it true."""
    _isolate(tmp_path, monkeypatch)
    code, payload, captured = _run_main(tmp_path, monkeypatch,
                                        ["--dry-run", "--confidence-floor", "0.4"])
    assert code == 0, payload
    assert payload["status"] == "dry_run"
    assert payload["confidence_floor"] == 0.4
    assert payload["confidence_floor_is_advisory"] is True
    assert not captured, "a dry run never calls the service"


def test_the_floor_env_is_read_when_no_flag_is_given(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    monkeypatch.setenv("JEV_CONFIDENCE_FLOOR", "0.35")
    code, payload, _ = _run_main(tmp_path, monkeypatch, ["--dry-run"])
    assert code == 0, payload
    assert payload["confidence_floor"] == 0.35


def test_a_floor_outside_the_unit_interval_is_refused_by_name(tmp_path, monkeypatch, capsys):
    """A typo must not become a verdict where every answer is low-confidence --
    that is exactly the silent-constant failure #1 is about."""
    _isolate(tmp_path, monkeypatch)
    code, payload, captured = _run_main(tmp_path, monkeypatch,
                                        ["--confidence-floor", "1.5"])
    assert code == 2
    assert payload is None
    assert "--confidence-floor" in capsys.readouterr().err
    assert not captured


def test_a_custom_floor_moves_the_note_and_never_the_masses(tmp_path, monkeypatch):
    """The advisory contract, through main(): masses identical, gating different."""
    _isolate(tmp_path, monkeypatch)
    answers = {
        # Every mass sits between the two floors: over 0.4, under 0.6. That is
        # the only shape where the two flags can differ, so the assertions below
        # cannot pass by accident.
        "failure_mode": {"type": "choice", "choice": "screen_explosion",
                         "confidence": 0.45},
        "print_route": {"type": "choice", "choice": "process_halftone",
                        "confidence": 0.50},
        "tonal_structure": {"type": "score", "score": 1.0, "confidence": 0.45,
                            "legend": {"0": "a"}},
        "evidence_is_actionable": {"type": "noul", "noul": 0.45},
    }
    response = {"model": "jev-1.13.0", "answers": answers}

    strict = jev.make_annotation(
        tmp_path / "m.json", {}, jev.build_request({}, jev.DEFAULT_MODEL, "printability"),
        response, "printability", confidence_floor=0.6)
    lenient = jev.make_annotation(
        tmp_path / "m.json", {}, jev.build_request({}, jev.DEFAULT_MODEL, "printability"),
        response, "printability", confidence_floor=0.4)

    assert strict["verdict"]["confidence"] == lenient["verdict"]["confidence"], (
        "the masses are the measurement; the floor is the annotation")
    assert set(strict["verdict"]["low_confidence"]) > set(lenient["verdict"]["low_confidence"])

    report = lenient["verdict"]["confidence_range"]
    assert report["floor"] == 0.4
    assert report["default_floor"] == jev.DEFAULT_CONFIDENCE_FLOOR
    # One run's floor is under its masses; the default is over them. Both facts
    # are in the same object, which is the whole point of reporting both.
    assert report["all_below_floor"] is False
    assert report["all_below_default_floor"] is True


def test_the_default_floor_is_still_the_default(tmp_path, monkeypatch):
    """No flag, no env: identical to what shipped before the knob existed."""
    _isolate(tmp_path, monkeypatch)
    # A key is needed to reach the verdict at all (call_jev is stubbed, but the
    # key check runs first and honestly), and it must not come from the real dotfiles.
    monkeypatch.setenv("JEV_API_KEY", "stub-key")
    code, payload, _ = _run_main(tmp_path, monkeypatch, [])
    assert code == 0, payload
    assert payload["verdict"]["confidence_floor"] == jev.DEFAULT_CONFIDENCE_FLOOR
    assert payload["verdict"]["confidence_floor_is_advisory"] is True
    assert payload["verdict"]["confidence_evidence"]["by_backend"], (
        "and the recorded evidence still travels with it")


# --- a key is only ever sent to the backend it authenticates ----------------

OPENROUTER_EP = "https://openrouter.ai/api/v1/systemone"
LAYA_EP = "http://laya:8797/v1/systemone"
KEY_NAMES = ("JEV_API_KEY", "TYPESAFE_API_KEY", "LAYA_API_KEY",
             "CHOPSHOP_OPENROUTER_KEY")


def test_openrouter_endpoint_does_not_take_the_ambient_laya_key(tmp_path, monkeypatch):
    """The 401 that blames the wrong thing, prevented.

    Measured 2026-10-10: this box carries LAYA_API_KEY in its ambient
    environment (the GPU box's laya token), and the flat name list let it shadow
    CHOPSHOP_OPENROUTER_KEY -- so the annotator sent the laya token to
    OpenRouter and got `401 Missing Authentication header`. resolve_api_key
    matches the key to the endpoint's host, so a laya token can never reach
    OpenRouter.
    """
    _isolate(tmp_path, monkeypatch)
    monkeypatch.setenv("LAYA_API_KEY", "ambient-laya-token")
    monkeypatch.setenv("CHOPSHOP_OPENROUTER_KEY", "or-token")
    got = jev.resolve_api_key(OPENROUTER_EP, KEY_NAMES, {})
    assert got == "or-token", (
        "an OpenRouter call must take the OpenRouter key, not the ambient laya one")


def test_laya_endpoint_still_takes_the_laya_key(tmp_path, monkeypatch):
    """The reverse direction: a laya call must still find LAYA_API_KEY.

    The endpoint-aware resolver must not break the alternate backend it was
    added beside -- a laya endpoint resolves LAYA_API_KEY exactly as before.
    """
    _isolate(tmp_path, monkeypatch)
    monkeypatch.setenv("LAYA_API_KEY", "ambient-laya-token")
    monkeypatch.setenv("CHOPSHOP_OPENROUTER_KEY", "or-token")
    got = jev.resolve_api_key(LAYA_EP, KEY_NAMES, {})
    assert got == "ambient-laya-token"


def test_unknown_endpoint_falls_back_to_first_wins(tmp_path, monkeypatch):
    """A self-hosted or unrecognised endpoint is not left keyless.

    When no key name matches the endpoint's host, resolution falls back to the
    historical first-wins order, so an unusual backend still finds a key rather
    than silently finding none.
    """
    _isolate(tmp_path, monkeypatch)
    monkeypatch.setenv("JEV_API_KEY", "hosted-key")
    got = jev.resolve_api_key("https://my-own-box.example/v1/systemone", KEY_NAMES, {})
    assert got == "hosted-key"


def test_openrouter_call_end_to_end_ignores_ambient_laya(tmp_path, monkeypatch):
    """The whole path: an OpenRouter run does not send the ambient laya token.

    The unit test above pins resolve_api_key; this drives main() with a stubbed
    call_jev and asserts the KEY THAT REACHED THE CALL is the OpenRouter one,
    which is the failure that actually bit (a 401 mid-run, not a resolution
    detail).
    """
    _isolate(tmp_path, monkeypatch)
    monkeypatch.setenv("LAYA_API_KEY", "ambient-laya-token")
    monkeypatch.setenv("CHOPSHOP_OPENROUTER_KEY", "or-token")
    code, payload, captured = _run_main(
        tmp_path, monkeypatch, ["--endpoint", OPENROUTER_EP,
                                "--model", "microsoft/microsoft-decision-1"])
    assert code == 0, payload
    assert captured["api_key"] == "or-token", (
        "the call must carry the OpenRouter key, not the ambient laya token")
