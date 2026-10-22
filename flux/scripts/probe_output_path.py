#!/usr/bin/env python3
"""The no-GPU before/after capture for the output path (`hires`, `ink_cap`, ...).

Not a test — and it must not become one. It runs the engine's request path with a
stubbed pipeline and a fake PIL, prints the response plus the sha256 of the bytes
that were written, and is what produced the golden values pinned in
``tests/test_output_features.py``. Run it against the build BEFORE a change and
against the build AFTER it: for a request that uses none of the new keys the two
outputs must be identical, line for line.

    python3 scripts/probe_output_path.py

It needs neither torch nor Pillow, which is the point: byte-identity of the
*engine path* (the kwargs the pipeline is called with, the bytes written, the
response body) is checkable on any machine. Whether the GPU pipeline itself is
bit-identical for a seed is not checkable here and is not claimed by it.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tempfile
import types

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from chopshop_flux.engine import FluxEngine  # noqa: E402
from chopshop_flux.models import resolve  # noqa: E402


class _FakeImage:
    """A deterministic stand-in for a decoded frame (no Pillow here)."""

    def __init__(self, seed):
        self.mode = "RGB"
        self.width = 8
        self.height = 8
        self._data = b"FRAME-seed%d" % seed

    def save(self, path, format=None):  # noqa: A002 - PIL's own name
        with open(path, "wb") as handle:
            handle.write(self._data)


class _RecordingPipe:
    def __init__(self, seed):
        self.calls = []
        self._seed = seed

    def __call__(self, **kwargs):
        self.calls.append(kwargs)
        return types.SimpleNamespace(images=[_FakeImage(self._seed)])


def _install_fake_torch():
    class _Ctx:
        def __enter__(self):
            return None

        def __exit__(self, *exc):
            return False

    class _Generator:
        def manual_seed(self, seed):
            return self

    module = types.ModuleType("torch")
    module.inference_mode = staticmethod(lambda: _Ctx())
    module.Generator = staticmethod(lambda: _Generator())
    sys.modules["torch"] = module
    return module


def _install_fake_pil():
    """`_run` does ``from PIL import Image``; this box has no Pillow."""
    module = types.ModuleType("PIL")
    module.Image = type("Image", (), {"open": staticmethod(lambda fp: None)})
    sys.modules["PIL"] = module


def _jsonable(value):
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, (list, tuple)):
        return [_jsonable(v) for v in value]
    return "<%s>" % type(value).__name__


def main() -> int:
    seed = 4242
    fake_torch = _install_fake_torch()
    _install_fake_pil()
    with tempfile.TemporaryDirectory() as out_dir:
        engine = FluxEngine(out_dir=out_dir)
        recorder = _RecordingPipe(seed)
        engine._pipe = recorder
        engine._torch = fake_torch
        engine.load = lambda *a, **k: resolve("klein-4b")  # request path only
        body = engine.generate(prompt="a phoenix emblem", width=512, height=512,
                               seed=seed)
        call = recorder.calls[-1]
        written = sorted(os.listdir(out_dir))
        digest = hashlib.sha256(
            open(os.path.join(out_dir, written[0]), "rb").read()).hexdigest()

    # The name and path carry a UTC stamp and a temp directory, so normalise them
    # out: what is being compared is the request path, not the clock.
    normalised = json.loads(json.dumps(body))
    for entry in normalised["images"]:
        entry["name"] = re.sub(r"^\d{8}T\d{6}Z-", "<STAMP>-", entry["name"])
        entry["path"] = "<OUT>/" + os.path.basename(entry["path"])
    text = "response = %s" % json.dumps(normalised, indent=2, sort_keys=True)
    text += "\npipeline_kwargs = %s" % json.dumps(
        {k: _jsonable(v) for k, v in sorted(call.items())}, sort_keys=True)
    text += "\nwritten = %s" % written
    text += "\npng_sha256 = %s" % digest
    # Belt and braces: any stamp still in the text is the clock, not the change.
    print(re.sub(r"\d{8}T\d{6}Z", "<STAMP>", text))
    return 0


if __name__ == "__main__":
    sys.exit(main())
