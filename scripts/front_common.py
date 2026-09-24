#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Minimal vendored subset of chopshop-svg's ``scripts/front_common.py``.

``swarm_bridge.py`` imports ``front_common`` for exactly two helpers,
``load_json`` and ``write_json``.  This shim carries only those, so the
chopshop-sui repo is self-contained while ``swarm_bridge.py`` stays byte-
identical to the copy in chopshop-svg.  The full helper set (sha256, tool
versioning, parallelism, the D-Bus worker init) lives in chopshop-svg, which
the bridge's ``gen2pipe``/``filter`` modes hand off to.
"""

import json


def load_json(path):
    """Read a JSON file.  Raises the underlying error on failure (the caller
    owns the friendly message)."""
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path, payload):
    """Write a JSON file atomically-ish (write then flush), pretty-printed."""
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
