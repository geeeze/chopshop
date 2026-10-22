"""The flat metrics schema — a shared DATA CONTRACT, not a scoring engine.

This module is the shape of the run records chopshop-studio and the chopshop-svg
pipeline hand to the chart operations: it defines the fields and flattens them
into rows. It computes no score, ranks nothing and judges nothing.

The pipeline emits measurements at several stages (comparison.json, the back-half
manifest, the run record). This module flattens those into ONE boring, flat,
versioned row per candidate, keyed by source hash + recipe hash, so every chart
is drawn from the same schema and no chart hardcodes a field.

Design rules (from the contract):

- ``metrics_version`` is the schema version. Bump it when a field is renamed,
  added, or removed. Downstream readers check it and refuse unknown versions.
- Field names are flat and boring: ``node_count_max``, not ``static.path_nodes_max``.
- Missing data is a state, not a zero. A gate that was skipped (e.g. the size
  gate with no dimensions block) appears as ``None``/absent, so a chart renders
  it as absent rather than plotting a lie.
- The recipe is the sweep parameters (preset, filter_speckle, hierarchical,
  use_palette). ``recipe_hash`` is a stable hash of them, so the same recipe on
  different sources, or different recipes on one source, are directly comparable.

The chart operations read run records (``.run.json``, the archive spine), which
already carry source hash + sweep recipe + comparison + manifest + decision per
candidate. This module is stdlib-only.
"""

from __future__ import annotations

import hashlib
import json

METRICS_VERSION = 1

# ---------------------------------------------------------------------------
# Field registry.  Numeric fields are selectable chart axes; categorical fields
# are usable for colouring/filtering/grouping.  "boring and flat" -- no nesting.
# ---------------------------------------------------------------------------

NUMERIC_FIELDS = {
    # gates
    "hard": "hard gates failed (both layers)",
    "advisory": "advisories (both layers)",
    "layer_a_hard": "Layer A (source validation) hard gates",
    "layer_a_advisory": "Layer A advisories",
    "layer_b_hard": "Layer B (render preflight) hard gates",
    "layer_b_advisory": "Layer B advisories",
    # static / metrics
    "declared_colors": "colours declared in the spec/SVG",
    "rendered_ink_colors": "distinct inks in the rendered output",
    "rendered_distinct_colors": "distinct colours in the render (manifest)",
    "node_count_total": "total path nodes",
    "node_count_max": "max path nodes on one path",
    "file_size": "SVG file size in bytes",
    # fidelity (raster-diff vs source)
    "mae": "mean absolute error, all pixels",
    "mae_art": "mean absolute error, artwork pixels only",
    "p95": "95th-percentile pixel error",
    "within10": "fraction of pixels within 10 units",
    # back-half manifest
    "tac_exact": "thread-alike colour (TAC) match flag",
    "rendered_continuous_tone": "continuous tone detected",
    "hard_findings": "manifest hard findings",
    "advisory_findings": "manifest advisory findings",
    "color_count": "static colour count (manifest)",
}

CATEGORICAL_FIELDS = {
    "preset": "trace preset name",
    "variant": "sweep variant (source/inverse/pitch/...)",
    "passed": "both layers passed (bool)",
    "fidelity_verdict": "faithful|drift|colour_dropped|artwork_lost",
    "label": "human decision label",
    "selected": "human decision selected (bool)",
}

IDENTITY_FIELDS = ("candidate_id", "run_stem", "source_sha256", "recipe_hash")

ALL_FIELDS = tuple(IDENTITY_FIELDS) + tuple(NUMERIC_FIELDS) + tuple(CATEGORICAL_FIELDS)


def recipe_hash(preset, filter_speckle, hierarchical, use_palette):
    """Stable hash of the sweep recipe, so the same recipe is comparable across
    runs and sources.  Inputs are JSON-normalised first so bool/int don't
    matter."""
    payload = {
        "preset": preset,
        "filter_speckle": filter_speckle,
        "hierarchical": hierarchical,
        "use_palette": use_palette,
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16]


def _get(mapping, *path, default=None):
    cur = mapping
    for key in path:
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur


def flatten_candidate(run, candidate):
    """Flatten one run-record candidate into a flat metrics row.

    ``run`` is a parsed ``.run.json`` dict; ``candidate`` is one entry of its
    ``candidates`` list.  Returns a dict with every field in ``ALL_FIELDS``,
    missing values set to ``None`` (absent, not zero).
    """
    stem = run.get("stem")
    sweep = candidate.get("sweep") or {}
    comparison = candidate.get("comparison") or {}
    back = candidate.get("back_half") or {}
    manifest = back.get("manifest") or {}
    manifest_stats = manifest.get("stats") or {}
    decision = candidate.get("human_decision") or {}

    source_sha256 = _get(run, "run", "source", "sha256") or sweep.get("source_sha256")

    preset = sweep.get("preset")
    filter_speckle = sweep.get("filter_speckle")
    hierarchical = sweep.get("hierarchical")
    use_palette = sweep.get("use_palette")

    layer_a = comparison.get("layer_a") or {}
    layer_b = comparison.get("layer_b") or {}
    fidelity = comparison.get("fidelity") or {}

    return {
        # identity
        "candidate_id": candidate.get("id"),
        "run_stem": stem,
        "source_sha256": source_sha256,
        "recipe_hash": recipe_hash(preset, filter_speckle, hierarchical, use_palette),
        # gates
        "hard": comparison.get("hard"),
        "advisory": comparison.get("advisory"),
        "layer_a_hard": layer_a.get("hard"),
        "layer_a_advisory": layer_a.get("advisory"),
        "layer_b_hard": layer_b.get("hard"),
        "layer_b_advisory": layer_b.get("advisory"),
        # static / metrics
        "declared_colors": comparison.get("declared_colors"),
        "rendered_ink_colors": comparison.get("rendered_ink_colors"),
        "rendered_distinct_colors": _get(manifest_stats, "rendered_distinct_colors"),
        "node_count_total": comparison.get("node_count_total"),
        "node_count_max": comparison.get("node_count_max"),
        "file_size": candidate.get("file_size"),
        # fidelity
        "mae": fidelity.get("mae"),
        "mae_art": fidelity.get("mae_art"),
        "p95": fidelity.get("p95"),
        "within10": fidelity.get("within10"),
        # manifest
        "tac_exact": _get(manifest_stats, "tac_exact"),
        "rendered_continuous_tone": _get(manifest_stats, "rendered_continuous_tone"),
        "hard_findings": _get(manifest_stats, "hard_findings"),
        "advisory_findings": _get(manifest_stats, "advisory_findings"),
        "color_count": _get(manifest_stats, "color_count"),
        # categorical
        "preset": preset,
        "variant": sweep.get("variant"),
        "passed": comparison.get("passed"),
        "fidelity_verdict": comparison.get("fidelity_verdict"),
        "label": decision.get("label"),
        "selected": decision.get("selected"),
    }


def flatten_run(run):
    """Flatten every candidate in a run record into a list of flat rows.

    Returns ``(rows, meta)`` where ``meta`` carries the run identity (stem,
    source hash, candidate count).  A run with zero candidates yields no rows.
    """
    candidates = run.get("candidates") or []
    rows = [flatten_candidate(run, c) for c in candidates
            if isinstance(c, dict)]
    meta = {
        "stem": run.get("stem"),
        "source_sha256": _get(run, "run", "source", "sha256"),
        "candidate_count": len(rows),
    }
    return rows, meta


def is_numeric_field(name):
    return name in NUMERIC_FIELDS


def is_categorical_field(name):
    return name in CATEGORICAL_FIELDS


def known_field(name):
    return name in NUMERIC_FIELDS or name in CATEGORICAL_FIELDS or name in IDENTITY_FIELDS
