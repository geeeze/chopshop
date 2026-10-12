"""Shared hermeticity for the whole suite (chopshop-jev#12).

The annotator resolves its decision key, endpoint, model, HTTP timeout
and confidence floor from the environment and from dotenv files, so a
shell that has sourced ``~/.chopshop-studio.env`` -- which ``set -a``
exports and ``set +a`` does NOT un-export -- leaks those names into
every test that resolves them: a test then passes or fails because of
the developer's box, not because of the code. The autouse fixture
below scrubs every name the annotator accepts (``jev_annotate
._JEV_ENV_KEYS`` -- the same twelve names the per-file fixture used to
hardcode) and empties ``DEFAULT_ENV_FILES``, so no test in any file can
pass by picking up an ambient credential, and none can fail because of
one either.

Lifted from test_loop_demo.py's per-file autouse fixture so every test
file inherits it from one place.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
for _p in (str(ROOT), str(SCRIPTS)):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import jev_annotate as jev  # noqa: E402


@pytest.fixture(autouse=True)
def no_ambient_credentials(monkeypatch):
    """Scrub every key/endpoint name the annotator resolves, and the dotenv."""
    for name in jev._JEV_ENV_KEYS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(jev, "DEFAULT_ENV_FILES", ())
