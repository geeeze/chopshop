#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Minimal vendored subset of chopshop-svg's ``scripts/front_common.py``.

``swarm_bridge.py`` imports ``front_common`` for exactly two helpers,
``load_json`` and ``write_json``.  This shim carries only those, so the
chopshop-sui repo can import and run the bridge with no chopshop-svg checkout
present.  The full helper set -- sha256, tool versioning, parallelism, the
D-Bus worker init; 12 functions in all -- lives in chopshop-svg, and only the
bridge's ``gen2pipe`` mode hands off to it (``generate`` and ``filter`` never
leave this repo).

This file is a subset, not a mirror: never copy it over a chopshop-svg
checkout's ``scripts/front_common.py``, which would strip the helpers that
repo's own pipeline scripts import.
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
