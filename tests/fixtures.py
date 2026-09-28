"""Shared fixtures: build realistic run records in the chopshop-run-record shape."""


def make_candidate(cid, *, preset="flat-poster", speckle=2, hier=False, palette=False,
                   hard=0, advisory=0, passed=True, declared=5, inks=5,
                   nodes_total=1234, nodes_max=87, size=45678,
                   mae=0.12, mae_art=0.005, p95=2.0, within10=0.98,
                   verdict="faithful", selected=None, label=None,
                   manifest=None):
    """One candidate in the run-record shape."""
    comp = {
        "passed": passed,
        "hard": hard,
        "advisory": advisory,
        "node_count_max": nodes_max,
        "node_count_total": nodes_total,
        "rendered_ink_colors": inks,
        "declared_colors": declared,
        "layer_a": {"status": "pass" if not hard else "fail", "hard": hard,
                    "advisory": 0, "findings": []},
        "layer_b": {"status": "pass" if not hard else "fail", "hard": 0,
                    "advisory": advisory, "findings": []},
        "fidelity": {"measured": True, "mae": mae, "mae_art": mae_art,
                     "p95": p95, "within10": within10},
        "fidelity_verdict": verdict,
    }
    back_half = {"run": True, "manifest": None}
    if manifest is not None:
        back_half["manifest"] = manifest
    return {
        "id": cid,
        "file": f"{cid}.svg",
        "svg_sha256": "a" * 16 + cid,
        "file_size": size,
        "sweep": {
            "preset": preset,
            "filter_speckle": speckle,
            "hierarchical": hier,
            "use_palette": palette,
            "source_sha256": None,
        },
        "comparison": comp,
        "back_half": back_half,
        "human_decision": {"found": selected is not None,
                           "selected": selected, "label": label, "reason": None},
        "duplicate_of": None,
        "missing_links": [],
        "open_items": [],
    }


def make_run(stem, source_sha256, candidates):
    return {
        "schema": "chopshop-run-record-0.1",
        "generated": "2026-09-28T00:00:00+00:00",
        "tool": "run_record.py",
        "stem": stem,
        "run": {"source": {"sha256": source_sha256, "found": True,
                           "path": None, "size_px": None}},
        "candidates": candidates,
    }


def two_source_two_recipe_runs():
    """Two sources x two recipes, giving a cross-run scatter with 4 points."""
    src_a = "s" * 64
    src_b = "t" * 64
    runs = [
        make_run("run-a1", src_a, [
            make_candidate("a1", preset="flat-poster", speckle=2, hier=False,
                           hard=0, mae_art=0.004, nodes_max=80),
        ]),
        make_run("run-a2", src_a, [
            make_candidate("a2", preset="mono-line", speckle=4, hier=True,
                           hard=1, mae_art=0.03, nodes_max=150),
        ]),
        make_run("run-b1", src_b, [
            make_candidate("b1", preset="flat-poster", speckle=2, hier=False,
                           hard=0, mae_art=0.006, nodes_max=95),
        ]),
        make_run("run-b2", src_b, [
            make_candidate("b2", preset="photo-halftone", speckle=8, hier=True,
                           hard=2, mae_art=0.10, nodes_max=220),
        ]),
    ]
    return runs
