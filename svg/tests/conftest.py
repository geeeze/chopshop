"""Make the project root importable from the test suite.

The tests live in tests/ per the v4.0 layout, but validate_svg.py and
preflight.py sit at the project root next to the pipeline, so the root has to
be on sys.path.
"""

import importlib.util
import os
import shutil
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

# -------------------------------------------------------------------------- #
# Fail fast: this suite needs CPython 3.13 and the pinned dependencies.       #
# -------------------------------------------------------------------------- #
# `requirements.txt` pins vtracer==0.6.15, whose wheel is built for CPython
# 3.13, and several test modules import `svgpathtools` at module scope.  Run
# the suite in an environment without them and collection dies on a bare
# `ModuleNotFoundError` from the first such module, which reads as a broken
# checkout rather than a missing venv.  So the check runs in
# `pytest_configure` -- before collection touches a single test module -- and
# aborts with one paragraph that names the exact fix.

REQUIRED_PYTHON = (3, 13)
REQUIRED_MODULE = "svgpathtools"


def environment_problem():
    """``None`` when this interpreter can run the suite, else why it cannot.

    Deliberately pure: no I/O beyond an ``importlib.util.find_spec`` probe, so
    the suite's own tests can call it under a monkeypatched version tuple and a
    monkeypatched ``find_spec`` and assert on the message it produces.
    """
    version = sys.version_info[:2]
    missing = [REQUIRED_MODULE] if importlib.util.find_spec(REQUIRED_MODULE) is None else []
    if version == REQUIRED_PYTHON and not missing:
        return None

    wrong = ["this interpreter is %d.%d, not 3.13" % version] if version != REQUIRED_PYTHON else []
    if missing:
        wrong.append("%s is not importable here" % ", ".join(missing))
    return (
        "The svg test suite needs CPython 3.13 and the dependencies pinned in "
        "svg/requirements.txt, and this environment does not have them: %s. "
        "Collection is aborted rather than failing later on a bare "
        "ModuleNotFoundError from a test module that imports svgpathtools at "
        "module scope. Fix: create the venv the README documents -- "
        "`python3.13 -m venv .venv` in the svg/ directory -- then "
        "`.venv/bin/pip install -r requirements.txt`, and run the suite with "
        "`.venv/bin/python -m pytest` from svg/. (requirements.txt pins "
        "vtracer 0.6.15 because its wheel is built for CPython 3.13: the cp314 "
        "wheel segfaults inside the extension, and on any other version pip "
        "builds that C extension from source. On a host whose `python3` is not "
        "3.13, a plain `python3 -m venv .venv` therefore gives a red suite.)"
        % "; ".join(wrong)
    )


def pytest_configure(config):
    problem = environment_problem()
    if problem is not None:
        # UsageError, not an exception of our own: pytest prints the message and
        # exits with its usage code, and no test module is ever imported.
        raise pytest.UsageError(problem)


# -------------------------------------------------------------------------- #
# Skip markers for system tools the tests shell out to.                       #
# -------------------------------------------------------------------------- #
# Without these, a fresh checkout without inkscape/gs/qpdf/poppler looks       #
# broken (23 fail, 5 error).  Tests that need a tool skip cleanly instead.    #

_TOOLS = ("inkscape", "gs", "qpdf", "pdfinfo", "pdfimages")
_missing = [t for t in _TOOLS if shutil.which(t) is None]

needs_render = pytest.mark.skipif(
    bool(_missing),
    reason="missing render tools: " + ", ".join(_missing))


# -------------------------------------------------------------------------- #
# Learning-store isolation                                                    #
# -------------------------------------------------------------------------- #
# The Phase 2 shown-event log and the learned-bucket store live at a
# JOB-INDEPENDENT path on purpose -- they must survive deletion of the job they
# describe (see scripts/triage_events.py). That is right in production and
# wrong under test: without this, every run of the suite that exercises the
# comparison stage appends "shown" events for synthetic candidates into the
# developer's real learning store, and a future learner would be training on
# that noise. Point the store at a throwaway dir; a test that wants a specific
# location overrides the env var itself with monkeypatch.

@pytest.fixture(autouse=True)
def _isolated_learning_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("PIPELINE_LEARNING_DIR", str(tmp_path / "learning"))

