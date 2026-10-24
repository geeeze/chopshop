"""Pin the fail-fast guard that `conftest.py` installs.

`conftest.environment_problem()` is what `pytest_configure` aborts collection
with, so it has to do two opposite things correctly: stay SILENT in an
environment that can run the suite, and produce a message that names the exact
fix in one that cannot.  Without these tests the guard is an untested string,
and the failure mode it exists to prevent -- a bare `ModuleNotFoundError` --
would come back unnoticed.

Run with:  python3 -m pytest tests/test_environment_guard.py -v
"""

import importlib.util
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import conftest  # noqa: E402


class _WrongPython:
    """Stands in for the `sys` module: only `version_info` is read."""

    version_info = (3, 14, 4, "final", 0)


def _missing_svgpathtools(monkeypatch):
    real = importlib.util.find_spec

    def fake(name):
        return None if name == conftest.REQUIRED_MODULE else real(name)

    monkeypatch.setattr(conftest.importlib.util, "find_spec", fake)


# --------------------------------------------------------------------------- #
# Silent when the environment is right                                        #
# --------------------------------------------------------------------------- #

def test_the_guard_is_silent_when_the_dependencies_are_present():
    """The common case: 3.13 + svgpathtools, so nothing is reported at all."""
    assert conftest.environment_problem() is None


def test_the_hook_does_not_raise_when_the_dependencies_are_present():
    conftest.pytest_configure(config=None)          # must not raise


# --------------------------------------------------------------------------- #
# Loud, with the fix named, when they are not                                 #
# --------------------------------------------------------------------------- #

def test_a_wrong_interpreter_produces_the_message(monkeypatch):
    monkeypatch.setattr(conftest, "sys", _WrongPython)
    message = conftest.environment_problem()
    assert message is not None
    assert "3.14" in message
    assert "python3.13 -m venv .venv" in message
    assert "pip install -r requirements.txt" in message


def test_a_missing_dependency_produces_the_message(monkeypatch):
    _missing_svgpathtools(monkeypatch)
    message = conftest.environment_problem()
    assert message is not None
    assert conftest.REQUIRED_MODULE in message
    assert "python3.13 -m venv .venv" in message
    assert "pip install -r requirements.txt" in message


def test_both_problems_are_named_together(monkeypatch):
    monkeypatch.setattr(conftest, "sys", _WrongPython)
    _missing_svgpathtools(monkeypatch)
    message = conftest.environment_problem()
    assert "3.14" in message and conftest.REQUIRED_MODULE in message


def test_the_message_is_one_paragraph():
    """It is printed as a single block by pytest; newlines would shred it."""
    monkeypatch = pytest.MonkeyPatch()
    try:
        monkeypatch.setattr(conftest, "sys", _WrongPython)
        _missing_svgpathtools(monkeypatch)
        message = conftest.environment_problem()
    finally:
        monkeypatch.undo()
    assert message is not None and "\n" not in message


# --------------------------------------------------------------------------- #
# The hook wiring                                                              #
# --------------------------------------------------------------------------- #

def test_pytest_configure_raises_usage_error_when_the_environment_is_wrong(
        monkeypatch):
    """`pytest.UsageError` is what makes pytest print the message and exit."""
    monkeypatch.setattr(conftest, "sys", _WrongPython)
    with pytest.raises(pytest.UsageError) as caught:
        conftest.pytest_configure(config=None)
    assert "python3.13 -m venv .venv" in str(caught.value)
