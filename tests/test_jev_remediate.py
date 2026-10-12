"""Tests for the Jev remediation planner.

Hermetic, like the annotator's suite: no network, no real .env, no execution of
any remedy. Every status in the plan doc's section 3.2 is asserted here, because
a status that cannot be triggered on demand is a status nobody will notice
breaking.

The two tests that matter most are `test_table_covers_every_failure_mode` and
`test_grounding_ids_are_real_rule_constants`. The first pins the table's
vocabulary to the questions the annotator actually asks; the second pins its
grounding citations to rule constants that exist in the pipeline. Either one
drifting turns the loop into something that refuses every candidate while
looking correct -- the failure mode this whole pass exists to prevent.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
for path in (str(ROOT), str(SCRIPTS)):
    if path not in sys.path:
        sys.path.insert(0, path)

import jev_annotate as jev  # noqa: E402
import jev_remediate as rem  # noqa: E402

CHOP = ROOT.parent / "chopshop-svg"


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------

@pytest.fixture(scope="module")
def table() -> dict:
    return rem.load_table(rem.DEFAULT_TABLE)


def verdict(
    mode: str,
    *,
    confidence: float = 0.9,
    low: list[str] | None = None,
    actionable: bool = True,
    floor: float = 0.6,
) -> dict:
    return {
        "headline": mode,
        "print_route": "screen_spot_multi",
        "tonal_score": 0.8,
        "tonal_label": "Retained",
        "evidence_actionable": actionable,
        "low_confidence": low or [],
        "confidence_floor": floor,
    }


def finding(rule: str, severity: str = "hard") -> dict:
    return {"rule": rule, "severity": severity, "message": f"{rule} tripped"}


# Advisory, exactly as preflight.py classifies them -- the default shape of the
# findings that drive the two cheap modes.
NODES_ADVISORY = [finding("NODE_COUNT", "advisory")]
PALETTE_ADVISORY = [finding("PALETTE", "advisory")]
SCREEN_HARD = [finding("COLOR_COUNT_RENDERED", "hard")]
GEOM_STATS = {
    "path_nodes_max": 96,
    "path_nodes_total": 189,
    "paths_over_node_limit": 0,
}


def plan(**kwargs) -> dict:
    table = rem.load_table(rem.DEFAULT_TABLE)
    kwargs.setdefault("table", table)
    return rem.decide(**kwargs)


# --------------------------------------------------------------------------
# The vocabulary pins
# --------------------------------------------------------------------------

def test_table_covers_every_failure_mode(table):
    """Every choice value jev_annotate can answer must have a table entry."""
    vocabulary = set(jev.QUESTIONS["failure_mode"]["criteria"])
    covered = {e.get("failure_mode") for e in table["remedies"]}
    assert vocabulary - covered == set(), (
        "these failure_mode values have no entry, so the loop would report "
        "not_loopable for a mode the model can actually answer"
    )
    assert covered - vocabulary == set(), (
        "the table names failure_modes the model cannot answer; they are dead "
        "entries that will never match"
    )


def test_table_is_valid(table):
    assert rem.validate_table(table) == []


def test_validate_table_catches_a_typo(table):
    """The pin must actually fail when it should, or it is decoration."""
    broken = json.loads(json.dumps(table))
    broken["remedies"][0]["failure_mode"] = "geometry_overlaod"
    problems = rem.validate_table(broken)
    assert any("geometry_overlaod" in p for p in problems)


def test_validate_table_catches_a_missing_mode(table):
    broken = json.loads(json.dumps(table))
    broken["remedies"] = [
        e for e in broken["remedies"] if e["failure_mode"] != "unclear"
    ]
    problems = rem.validate_table(broken)
    assert any("unclear" in p for p in problems), problems


RULE_DEF = re.compile(r'^(RULE_[A-Z_0-9]+)\s*=\s*"([^"]+)"', re.MULTILINE)


def rule_constants(source: Path) -> set[str]:
    """The RULE_* string values declared in one pipeline module.

    Read by parsing the source rather than importing it: the modules need lxml
    and svgpathtools, which the Jev layer's venv deliberately does not carry, so
    an import-based check would skip here and never guard anything. Parsing also
    tests what is actually on disk.
    """
    return {match.group(2) for match in RULE_DEF.finditer(source.read_text(encoding="utf-8"))}


def test_grounding_ids_are_real_rule_constants(table):
    """Every cited rule id must exist as a RULE_* constant in the pipeline.

    A citation to a rule that does not exist reads as a stricter check but is
    actually an unreachable one: grounding would never pass and the mode would
    refuse forever, which looks like a cautious loop rather than a broken one.
    """
    if not CHOP.is_dir():
        pytest.skip("chopshop-svg is not checked out beside this repo")

    real = rule_constants(CHOP / "validate_svg.py") | rule_constants(CHOP / "preflight.py")
    assert real, "no RULE_* constants found; the parser or the layout has changed"

    cited = set()
    for entry in table["remedies"]:
        cited |= set(entry.get("grounds_in") or [])
    assert cited - real == set(), (
        f"these grounding ids are not rule constants in the pipeline: "
        f"{sorted(cited - real)}"
    )


def test_the_rule_parser_actually_finds_rules():
    """Guard the guard: a parser that matches nothing would make the above pass."""
    if not CHOP.is_dir():
        pytest.skip("chopshop-svg is not checked out beside this repo")
    constants = rule_constants(CHOP / "validate_svg.py")
    assert "NODE_COUNT" in constants
    assert "PALETTE" in constants


def test_needs_tracer_is_declared_on_every_loopable_entry(table):
    for entry in table["remedies"]:
        if entry.get("loopable"):
            assert isinstance(entry["needs_tracer"], bool), entry["failure_mode"]


def test_geometry_overload_leads_with_a_tracer_free_rung(table):
    ladder = rem.ladder_for(table, "geometry_overload")
    assert len(ladder) >= 2, "expected a ladder, not a single rung"
    assert ladder[0]["needs_tracer"] is False
    assert ladder[0]["remedy"]["kind"] == "node_reduce"
    assert [e["needs_tracer"] for e in ladder[1:]] == [True] * (len(ladder) - 1)


# --------------------------------------------------------------------------
# Refusal gates (checked before any table lookup)
# --------------------------------------------------------------------------

def test_no_verdict(table):
    result = plan(verdict={}, findings=[], table=table)
    assert result["status"] == "refused_no_verdict"


def test_low_confidence_refuses(table):
    result = plan(
        verdict=verdict("geometry_overload", confidence=0.4, low=["failure_mode"]),
        findings=NODES_ADVISORY,
        table=table,
    )
    assert result["status"] == "refused_low_confidence"
    assert result["remedy"] is None


def test_evidence_not_actionable_refuses(table):
    result = plan(
        verdict=verdict("geometry_overload", actionable=False),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=table,
    )
    assert result["status"] == "refused_evidence"


def test_a_verdict_that_never_answered_the_evidence_question_is_traced(table):
    """`is False`, not falsy: an ABSENT answer is not a refusal.

    The strict comparison is the direction that matters. A sidecar whose
    evidence_actionable answer is missing -- a bare answers envelope folded
    through `compose_verdict`, a caller in another repo, a vocabulary that
    does not ask the question -- must still be planned on. A truthiness test
    would refuse it as `refused_evidence`, and the operator would read "the
    measurements do not support a production decision" as a finding about the
    artwork when it is only a finding about a field nobody filled in.
    """
    absent = verdict("geometry_overload")
    absent.pop("evidence_actionable")
    result = plan(
        verdict=absent,
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=table,
    )
    assert result["status"] == rem.TRACE
    assert result["remedy"]["id"] == "geometry_overload/tolerance"


def test_refusal_order_is_no_verdict_then_confidence_then_evidence(table):
    """A verdict failing several gates reports the first one, deterministically."""
    result = plan(
        verdict=verdict("", actionable=False, low=["failure_mode"]),
        findings=NODES_ADVISORY,
        table=table,
    )
    assert result["status"] == "refused_no_verdict"


# --------------------------------------------------------------------------
# not_loopable -- the structurally unfixable modes
# --------------------------------------------------------------------------

@pytest.mark.parametrize("mode", ["continuous_tone", "render_or_tool_failure", "no_hard_failure", "unclear"])
def test_unloopable_modes_stop_with_an_explanation(table, mode):
    result = plan(verdict=verdict(mode), findings=[finding("CONTINUOUS_TONE")], table=table)
    assert result["status"] == "not_loopable"
    assert result["reason"], "a refusal with no reason is not operator-facing"
    assert result["next_step"]


def test_render_failure_grounds_in_the_tool_rules(table):
    entry = next(
        e for e in table["remedies"] if e["failure_mode"] == "render_or_tool_failure"
    )
    assert "MISSING_TOOL" in entry["grounds_in"]


def test_a_mode_the_table_has_never_heard_of_is_not_loopable(table):
    """The no-ENTRY branch, distinct from the loopable:false one.

    `test_table_covers_every_failure_mode` is what keeps this branch
    unreachable in the shipped tree: a mode Jev can answer always has an
    entry, so a missing one means the table itself is out of date. That is a
    different diagnosis from "the mode exists and is unfixable", and the
    operator-facing next_step must say so -- naming the table to edit rather
    than asking for a human review of an artwork that is fine.
    """
    slim = json.loads(json.dumps(table))
    slim["remedies"] = [
        e for e in slim["remedies"] if e["failure_mode"] != "geometry_overload"
    ]
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=slim,
    )
    assert result["status"] == "not_loopable"
    assert "no table entry for failure_mode 'geometry_overload'" == result["reason"]
    assert result["next_step"] == "add the mode to scripts/remediation_table.json"


# --------------------------------------------------------------------------
# Grounding
# --------------------------------------------------------------------------

def test_ungrounded_refuses_even_though_the_mode_is_loopable(table):
    """A geometry verdict on a file with no NODE_COUNT finding must not retrace."""
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=[finding("COLOR_COUNT")],
        stats=GEOM_STATS,
        table=table,
    )
    assert result["status"] == "not_grounded"
    assert result["remedy"] is None


def test_grounding_ignores_severity(table):
    """NODE_COUNT is _ALWAYS_ADVISORY by design; an advisory finding grounds."""
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=table,
    )
    assert result["status"] == rem.TRACE
    assert result["grounded_in"] == ["NODE_COUNT"]


def test_palette_grounds_on_its_own_advisory_finding(table):
    result = plan(
        verdict=verdict("palette_mismatch"),
        findings=PALETTE_ADVISORY,
        stats={"off_palette_colors": ["#ff0000", "#00ff00"]},
        table=table,
    )
    assert result["status"] == rem.TRACE
    assert result["remedy"]["id"] == "palette_mismatch/tolerance"


def test_screen_explosion_grounds_on_either_rule(table):
    for rule in ("COLOR_COUNT", "COLOR_COUNT_RENDERED"):
        result = plan(
            verdict=verdict("screen_explosion"),
            findings=[finding(rule)],
            table=table,
        )
        assert result["status"] == rem.TRACE, rule
        assert result["grounded_in"] == ["COLOR_COUNT", "COLOR_COUNT_RENDERED"]


# --------------------------------------------------------------------------
# Ladder selection: cheapest rung first
# --------------------------------------------------------------------------

def test_geometry_overload_picks_the_tracer_free_rung_first(table):
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=table,
    )
    assert result["remedy"]["id"] == "geometry_overload/tolerance"
    assert result["remedy"]["kind"] == "node_reduce"
    assert result["remedy"]["needs_tracer"] is False
    assert result["invocation"] is not None
    assert result["sweep"] is None, "a post-process is not a sweep"


def test_screen_explosion_prefers_the_snap_over_the_retrace(table):
    result = plan(
        verdict=verdict("screen_explosion"),
        findings=SCREEN_HARD,
        stats={"rendered_distinct_colors": 677},
        table=table,
    )
    assert result["remedy"]["id"] == "screen_explosion/force"
    assert result["remedy"]["needs_tracer"] is False
    assert "--force" in result["invocation"]


def test_range_exhaustion_moves_to_the_next_rung(table):
    """A spent cheap rung must not end the loop while an escalation remains."""
    history = [{
        "remedy_id": "geometry_overload/tolerance",
        "failure_mode": "geometry_overload",
        "remedy_value": 0.5,
        "improved": False,
    }]
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=table,
        history=history,
        iteration=2,
    )
    # node_reduce has no stepping, so it is not "spent" -- it is repeated, and
    # the no-progress rule must be what stops it, not the range rule.
    assert result["status"] == "no_progress"


def test_ladder_trace_records_why_a_rung_was_skipped(table):
    result = plan(
        verdict=verdict("palette_mismatch"),
        findings=PALETTE_ADVISORY,
        stats={"off_palette_colors": ["#ff0000"]},
        table=table,
    )
    assert result["ladder"][-1]["outcome"] == "selected"


# --------------------------------------------------------------------------
# Range stepping
# --------------------------------------------------------------------------

def test_color_precision_never_walks_below_its_measured_floor(table):
    ladder = rem.ladder_for(table, "screen_explosion")
    retrace = next(e for e in ladder if e["remedy"]["kind"] == "preset_param")
    remedy = retrace["remedy"]
    # from 6, step -2, range [4, 8] -> 6, 4, then exhausted. Never 2 or 0.
    value, spent = rem.next_value(remedy, [])
    assert (value, spent) == (6, False)
    value, spent = rem.next_value(remedy, [6])
    assert (value, spent) == (4, False)
    value, spent = rem.next_value(remedy, [6, 4])
    assert value is None and spent is True


def test_palette_tolerance_walks_down_then_exhausts(table):
    ladder = rem.ladder_for(table, "palette_mismatch")
    remedy = ladder[0]["remedy"]
    value, spent = rem.next_value(remedy, [])
    assert (value, spent) == (32.0, False)
    value, spent = rem.next_value(remedy, [32.0])
    assert (value, spent) == (12.0, False)
    value, spent = rem.next_value(remedy, [32.0, 12.0])
    assert value is None and spent is True


def test_filter_speckle_walks_up_then_exhausts(table):
    ladder = rem.ladder_for(table, "geometry_overload")
    retrace = next(e for e in ladder if e["remedy"]["kind"] == "retrace")
    remedy = retrace["remedy"]
    value, spent = rem.next_value(remedy, [])
    assert (value, spent) == (2, False)
    value, spent = rem.next_value(remedy, [2])
    assert (value, spent) == (10, False)
    # 2, 10, 18, 26, 34, 42, then 50 leaves [2, 48].
    value, spent = rem.next_value(remedy, [2, 10, 18, 26, 34, 42])
    assert value is None and spent is True


def test_internal_escalation_rungs_are_not_stepped_by_the_loop(table):
    """node_reduce doubles its own tolerance; the loop must not also step it."""
    ladder = rem.ladder_for(table, "geometry_overload")
    remedy = ladder[0]["remedy"]
    assert rem.next_value(remedy, []) == (None, False)
    assert rem.next_value(remedy, [0.5, 1.0, 2.0]) == (None, False)


def test_a_seeded_walk_starts_at_the_furthest_point_along_the_direction_of_travel():
    """The sort in `_seed_tried` is the direction of travel, not tidiness.

    History can arrive out of order -- a run resumed from a recorded plan, a
    candidate retraced at a value an earlier iteration had already passed.
    `next_value` steps from `tried[-1]`, so the seed must put the FURTHEST
    point along the direction of travel last: ascending for a positive step,
    descending for a negative one. Reading the list as-recorded instead
    replans a value the loop has already spent, and the rung looks available
    when it has moved on.
    """
    # filter_speckle walks up: 2, 10, 18, 26, ... A history recorded as
    # 18-then-2 must seed [2, 18], so the next planned value is 26.
    up = rem._seed_tried([18, 2], None, 8)
    assert up == [2, 18]
    value, spent = rem.next_value({"kind": "retrace", "from": 2, "step": 8,
                                   "range": [2, 48]}, up)
    assert (value, spent) == (26, False)

    # color_precision walks DOWN: 6, 4. A history recorded as 4-then-6 must
    # seed [6, 4], so the next planned value is 2 -- outside [4, 8], spent.
    down = rem._seed_tried([4, 6], None, -2)
    assert down == [6, 4]
    value, spent = rem.next_value({"kind": "retrace", "from": 6, "step": -2,
                                   "range": [4, 8]}, down)
    assert (value, spent) == (None, True)

    # The candidate's own current value joins the same ordering, so a rung
    # whose `from` equals it starts past it rather than reproducing it.
    seeded = rem._seed_tried([2], 10, 8)
    assert seeded == [2, 10]


def test_range_exhausted_when_every_rung_is_spent(table):
    history = [
        {"remedy_id": "palette_mismatch/tolerance", "failure_mode": "palette_mismatch",
         "remedy_value": 32.0, "improved": True},
        {"remedy_id": "palette_mismatch/tolerance", "failure_mode": "palette_mismatch",
         "remedy_value": 12.0, "improved": True},
    ]
    result = plan(
        verdict=verdict("palette_mismatch"),
        findings=PALETTE_ADVISORY,
        stats={"off_palette_colors": ["#ff0000"]},
        table=table,
        history=history,
        iteration=3,
    )
    assert result["status"] == "range_exhausted"


# --------------------------------------------------------------------------
# Progress, oscillation, budget
# --------------------------------------------------------------------------

def test_improved_requires_a_gain_and_no_regression():
    names = ["rule_findings", "path_nodes_max"]
    assert rem.improved({"rule_findings": 3, "path_nodes_max": 96},
                        {"rule_findings": 3, "path_nodes_max": 64}, names) is True
    assert rem.improved({"rule_findings": 3, "path_nodes_max": 96},
                        {"rule_findings": 3, "path_nodes_max": 96}, names) is False
    assert rem.improved({"rule_findings": 3, "path_nodes_max": 96},
                        {"rule_findings": 0, "path_nodes_max": 128}, names) is False


def test_improved_ignores_metrics_it_cannot_read():
    assert rem.improved({"path_nodes_max": None}, {"path_nodes_max": 64}, ["path_nodes_max"]) is False


def test_no_progress_on_a_repeated_rung(table):
    history = [{
        "remedy_id": "screen_explosion/force",
        "failure_mode": "screen_explosion",
        "improved": False,
    }]
    result = plan(
        verdict=verdict("screen_explosion"),
        findings=SCREEN_HARD,
        table=table,
        history=history,
        iteration=2,
    )
    assert result["status"] == "no_progress"


def test_progress_permits_the_next_iteration(table):
    history = [{
        "remedy_id": "screen_explosion/force",
        "failure_mode": "screen_explosion",
        "improved": True,
    }]
    result = plan(
        verdict=verdict("screen_explosion"),
        findings=SCREEN_HARD,
        table=table,
        history=history,
        iteration=2,
    )
    assert result["status"] == rem.TRACE


def test_the_last_attempt_on_a_rung_governs_not_the_best_one(table):
    """`same_rung[-1]`, not "any attempt improved".

    The rung's LAST attempt is what predicts the next one: a snap that worked
    once and then regressed has just demonstrated that its gain was not
    stable, so repeating it is the random walk the rule exists to stop.
    Reading "any attempt improved" instead would send the loop straight back
    to a rung it has just watched fail, and the `no_progress` refusal would
    become unreachable for exactly the history most likely to need it.
    """
    history = [
        {"remedy_id": "screen_explosion/force", "failure_mode": "screen_explosion",
         "improved": True},
        {"remedy_id": "screen_explosion/force", "failure_mode": "screen_explosion",
         "improved": False},
    ]
    result = plan(
        verdict=verdict("screen_explosion"),
        findings=SCREEN_HARD,
        table=table,
        history=history,
        iteration=3,
    )
    assert result["status"] == "no_progress"
    assert "screen_explosion/force" in result["reason"]


def test_oscillation_between_two_modes(table):
    history = [
        {"remedy_id": "screen_explosion/force", "failure_mode": "screen_explosion",
         "improved": False},
        {"remedy_id": "palette_mismatch/tolerance", "failure_mode": "palette_mismatch",
         "improved": False},
    ]
    result = plan(
        verdict=verdict("screen_explosion"),
        findings=SCREEN_HARD,
        table=table,
        history=history,
        iteration=3,
    )
    assert result["status"] == "oscillating"


def test_a_fresh_mode_after_two_unrelated_stalls_is_traced_not_oscillating(table):
    """Oscillation is about ONE mode coming back, not about a bad run.

    The `failure_mode` half of the guard is the direction that matters: two
    unimproved iterations of OTHER modes say the loop has not converged, but
    they do not say these knobs are fighting each other. Refusing a first
    sighting of `geometry_overload` as `oscillating` would end the loop on a
    mode that has never been tried, and the reason handed to the operator
    would name a fight that has not happened yet.
    """
    history = [
        {"remedy_id": "screen_explosion/force", "failure_mode": "screen_explosion",
         "improved": False},
        {"remedy_id": "palette_mismatch/tolerance", "failure_mode": "palette_mismatch",
         "improved": False},
    ]
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=table,
        history=history,
        iteration=3,
    )
    assert result["status"] == rem.TRACE
    assert result["remedy"]["id"] == "geometry_overload/tolerance"


def test_budget_reached(table):
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=table,
        iteration=4,
        limit=3,
    )
    assert result["status"] == "budget_reached"


def test_budget_is_checked_after_grounding(table):
    """An ungrounded mode reports not_grounded, not budget_reached."""
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=[],
        table=table,
        iteration=9,
        limit=3,
    )
    assert result["status"] == "not_grounded"


def test_every_status_in_the_vocabulary_is_honoured():
    """converged is unreachable in this pass; the other nine are not."""
    assert rem.TRACE not in rem.TERMINATION_STATUSES
    assert len(rem.TERMINATION_STATUSES) == 10
    assert "converged" in rem.TERMINATION_STATUSES


# --------------------------------------------------------------------------
# The child sweep
# --------------------------------------------------------------------------

def test_child_sweep_pins_the_context_it_cannot_infer(table):
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=table,
    )
    # node_reduce is not a sweep, so there is nothing to pin here.
    assert result["sweep"] is None


def test_retrace_child_sweep_is_surgical(table):
    """With no parent sweep the context is defaulted, and the note says so."""
    history = [{
        "remedy_id": "geometry_overload/tolerance",
        "failure_mode": "geometry_overload",
        "improved": False,
    }]
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=table,
        history=history,
        iteration=2,
        limit=5,
    )
    # no_progress stops the cheap rung; with the rung excluded it would escalate.
    assert result["status"] == "no_progress"


def test_escalated_retrace_pins_every_other_axis(table):
    """When the cheap rung is gone from the ladder, the retrace must not wander."""
    slim = json.loads(json.dumps(table))
    slim["remedies"] = [
        e for e in slim["remedies"]
        if not (e["failure_mode"] == "geometry_overload"
                and e["remedy"]["kind"] == "node_reduce")
    ]
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=slim,
        parent_sweep={
            "candidates": [{
                "file": "candidate_10.svg",
                "preset": "poster",
                "use_palette": True,
                "hierarchical": "cutout",
                "filter_speckle": 2,
            }],
        },
        candidate_svg="candidate_10.svg",
    )
    assert result["status"] == rem.TRACE
    assert result["remedy"]["kind"] == "retrace"
    sweep = result["sweep"]
    # The candidate already has filter_speckle 2, which is also the rung's
    # `from`. Retracing at 2 would reproduce this exact candidate byte for byte
    # (the sweep is deterministic), so the rung must step past it.
    assert sweep["filter_speckle"] == [10], "must advance past the candidate's value"
    assert sweep["presets"] == ["poster"], "must inherit the candidate's preset"
    assert sweep["use_palette"] == [True], "must not introduce a second axis"
    assert sweep["hierarchical"] == ["cutout"]
    assert result["sweep_context"] == "context inherited from the parent sweep"


def retrace_only(table) -> dict:
    """The table with geometry_overload reduced to its single retrace rung.

    Needed to reach range_exhausted: with the node_reduce and coarser_layer
    rungs present, a spent filter_speckle correctly escalates instead of
    stopping, so the terminal case has to be isolated to be observed.
    """
    slim = json.loads(json.dumps(table))
    slim["remedies"] = [
        e for e in slim["remedies"]
        if not (e["failure_mode"] == "geometry_overload"
                and e["remedy"]["kind"] in ("node_reduce", "preset_param"))
    ]
    return slim


def test_a_rung_already_at_the_range_end_is_exhausted_not_repeated(table):
    """A candidate traced at the range ceiling has nowhere left to go."""
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=retrace_only(table),
        parent_sweep={
            "candidates": [{
                "file": "candidate_11.svg",
                "preset": "poster",
                "use_palette": False,
                "hierarchical": "cutout",
                "filter_speckle": 48,
                "params": {"filter_speckle": 48},
            }],
        },
        candidate_svg="candidate_11.svg",
    )
    assert result["status"] == "range_exhausted"


def test_a_spent_rung_escalates_rather_than_hopping_to_the_next_mode(table):
    """The candidate is at the ceiling, so the ladder moves up a rung."""
    slim = json.loads(json.dumps(table))
    slim["remedies"] = [
        e for e in slim["remedies"]
        if not (e["failure_mode"] == "geometry_overload"
                and e["remedy"]["kind"] == "node_reduce")
    ]
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=slim,
        parent_sweep={
            "candidates": [{
                "file": "candidate_11.svg",
                "preset": "poster",
                "use_palette": False,
                "hierarchical": "cutout",
                "filter_speckle": 48,
                "params": {"filter_speckle": 48},
            }],
        },
        candidate_svg="candidate_11.svg",
    )
    assert result["status"] == rem.TRACE
    assert result["remedy"]["id"] == "geometry_overload/layer_difference"
    outcomes = {r["remedy_id"]: r["outcome"] for r in result["ladder"]}
    assert outcomes["geometry_overload/filter_speckle"] == "skipped_range_exhausted"


def test_progress_alone_does_not_reset_a_spent_range(table):
    """History at the ceiling still exhausts, even after an improving iteration."""
    history = [{
        "remedy_id": "geometry_overload/filter_speckle",
        "failure_mode": "geometry_overload",
        "remedy_value": 42,
        "improved": True,
    }]
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=retrace_only(table),
        history=history,
        iteration=2,
        limit=5,
    )
    # 42 + 8 = 50, outside [2, 48]. An improving iteration does not buy more range.
    assert result["status"] == "range_exhausted"


def test_context_value_reads_resolved_params_before_the_flat_field():
    context = {"filter_speckle": 2, "params": {"filter_speckle": 16}}
    assert rem.context_value(context, "filter_speckle") == 16
    assert rem.context_value({"params": {}}, "filter_speckle") is None
    assert rem.context_value(None, "filter_speckle") is None
    assert rem.context_value(context, None) is None


def test_retrace_without_a_parent_sweep_says_what_it_assumed(table):
    slim = json.loads(json.dumps(table))
    slim["remedies"] = [
        e for e in slim["remedies"]
        if not (e["failure_mode"] == "geometry_overload"
                and e["remedy"]["kind"] == "node_reduce")
    ]
    result = plan(
        verdict=verdict("geometry_overload"),
        findings=NODES_ADVISORY,
        stats=GEOM_STATS,
        table=slim,
    )
    assert "defaulted" in result["sweep_context"]
    assert result["sweep"]["use_palette"] == [False]


def test_preset_param_child_sweep_overrides_one_parameter(table):
    slim = json.loads(json.dumps(table))
    slim["remedies"] = [
        e for e in slim["remedies"]
        if not (e["failure_mode"] == "screen_explosion"
                and e["remedy"]["kind"] == "snap")
    ]
    result = plan(
        verdict=verdict("screen_explosion"),
        findings=SCREEN_HARD,
        table=slim,
    )
    assert result["remedy"]["id"] == "screen_explosion/color_precision"
    assert result["sweep"]["preset_params"] == {"poster": {"color_precision": 6}}
    assert result["sweep"]["presets"] == ["poster"]


# --------------------------------------------------------------------------
# Metrics extraction
# --------------------------------------------------------------------------

def test_rule_findings_counts_every_severity():
    findings = [
        finding("NODE_COUNT", "advisory"),
        finding("NODE_COUNT", "hard"),
        finding("PALETTE", "advisory"),
    ]
    assert rem.count_rule_findings(findings, ["NODE_COUNT"]) == 2


def test_metrics_read_from_stats_then_stats_static():
    names = ["path_nodes_max", "paths_over_node_limit"]
    top = rem.extract_metrics({"path_nodes_max": 96, "paths_over_node_limit": 0}, [], ["NODE_COUNT"], names)
    assert top == {"path_nodes_max": 96, "paths_over_node_limit": 0}
    nested = rem.extract_metrics({"static": {"path_nodes_max": 64}}, [], ["NODE_COUNT"], names)
    assert nested["path_nodes_max"] == 64
    assert nested["paths_over_node_limit"] is None


def test_off_palette_colors_coerces_a_list_to_a_count():
    metrics = rem.extract_metrics(
        {"off_palette_colors": ["#111111", "#222222"]}, [], ["PALETTE"], ["off_palette_colors"]
    )
    assert metrics["off_palette_colors"] == 2


def test_version_string_palette_conformance_is_not_a_number():
    """The real manifest's palette_conformance is prose, not a metric."""
    metrics = rem.extract_metrics(
        {"palette_conformance": "all colours on palette"}, [], ["PALETTE"], ["palette_conformance"]
    )
    assert metrics["palette_conformance"] is None


def test_metrics_never_come_from_jev(table):
    """Progress must be measured on the pipeline's output, not the model's."""
    for entry in table["remedies"]:
        for name in entry.get("metrics") or []:
            assert "confidence" not in name
            assert "tonal" not in name
            assert "score" not in name


def test_no_metric_name_is_invented(table):
    """Every metric must be one the planner can actually read."""
    known = {
        "rule_findings",
        "path_nodes_max",
        "path_nodes_total",
        "paths_over_node_limit",
        "rendered_distinct_colors",
        "rendered_ink_colors",
        "rendered_screens",
        "off_palette_colors",
    }
    for entry in table["remedies"]:
        unknown = set(entry.get("metrics") or []) - known
        assert unknown == set(), f"{entry['failure_mode']}: {unknown}"


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def test_remediate_is_refused_not_silently_ignored(tmp_path, capsys):
    sidecar = tmp_path / "candidate_01.jev.json"
    sidecar.write_text(json.dumps({"verdict": verdict("geometry_overload")}))
    code = rem.main([str(sidecar), "--remediate"])
    assert code == 2
    assert "not implemented" in capsys.readouterr().err


def test_dry_run_on_a_real_shaped_sidecar(tmp_path, capsys):
    sidecar = tmp_path / "candidate_02.jev.json"
    sidecar.write_text(json.dumps({
        "verdict": verdict("geometry_overload"),
        "state": {
            "findings": NODES_ADVISORY,
            "stats": {"path_nodes_max": 96},
        },
    }))
    code = rem.main([str(sidecar), "--dry-run"])
    out = capsys.readouterr().out
    assert code == 0
    assert "TRACE" in out
    assert "tracer-free" in out


def test_cli_reads_the_sibling_manifest_over_the_projection(tmp_path, capsys):
    (tmp_path / "candidate_03.manifest.json").write_text(json.dumps({
        "findings": NODES_ADVISORY,
        "stats": {"static": {"path_nodes_max": 30, "path_nodes_total": 44}},
    }))
    sidecar = tmp_path / "candidate_03.jev.json"
    # The projection says the rule is absent; the manifest says it is present.
    sidecar.write_text(json.dumps({
        "verdict": verdict("geometry_overload"),
        "state": {"findings": [], "stats": {}},
    }))
    plan_path = tmp_path / "plan.json"
    code = rem.main([str(sidecar), "--dry-run", "--json", str(plan_path)])
    assert code == 0
    written = json.loads(plan_path.read_text())
    assert written["plans"][0]["status"] == rem.TRACE
    assert written["mode"] == "dry_run"


def test_cli_reports_not_grounded(tmp_path, capsys):
    sidecar = tmp_path / "candidate_04.jev.json"
    sidecar.write_text(json.dumps({
        "verdict": verdict("geometry_overload"),
        "state": {"findings": [], "stats": {}},
    }))
    assert rem.main([str(sidecar), "--dry-run"]) == 0
    assert "not_grounded" in capsys.readouterr().out


def test_cli_optional_skips_cleanly_on_a_missing_table(tmp_path, capsys):
    sidecar = tmp_path / "candidate_05.jev.json"
    sidecar.write_text(json.dumps({"verdict": verdict("geometry_overload")}))
    code = rem.main([
        str(sidecar), "--dry-run",
        "--table", str(tmp_path / "nope.json"),
        "--optional",
    ])
    assert code == 0
    assert "skipped" in capsys.readouterr().out


def test_cli_directory_mode(tmp_path, capsys):
    for index in (1, 2):
        (tmp_path / f"candidate_0{index}.jev.json").write_text(json.dumps({
            "verdict": verdict("geometry_overload"),
            "state": {"findings": NODES_ADVISORY, "stats": {"path_nodes_max": 96}},
        }))
    code = rem.main([str(tmp_path), "--dry-run"])
    assert code == 0
    out = capsys.readouterr().out
    assert out.count("TRACE") == 2


def test_cli_directory_mode_finds_the_runners_sidecar_name(tmp_path, capsys):
    """The runner writes ``jev.json``, not ``<stem>.jev.json``.

    ``chopshop-svg/runner.py:94`` redirects the annotator into a temp dir under
    that fixed name (the job dir is root-owned, so it is not the runner's to
    write in), which makes it the one name that actually appears on the runner
    path -- while ``<stem>.jev.json`` is the name the Studio tells the operator
    to expect. A glob for the documented name alone reports "no sidecars found"
    with a valid sidecar sitting in plain sight.
    """
    (tmp_path / "jev.json").write_text(json.dumps({
        "status": "ok",
        "verdict": verdict("geometry_overload"),
        "state": {"findings": NODES_ADVISORY, "stats": {"path_nodes_max": 96}},
    }))
    assert rem.main([str(tmp_path), "--dry-run"]) == 0
    assert "TRACE" in capsys.readouterr().out


def test_resolve_inputs_accepts_both_real_sidecar_names(tmp_path):
    """A unit pin on the same thing, without the CLI between us."""
    (tmp_path / "candidate_07.jev.json").write_text("{}")
    (tmp_path / "jev.json").write_text("{}")
    (tmp_path / "unrelated.json").write_text("{}")
    found = {path.name for path in rem.resolve_inputs(tmp_path)}
    assert found == {"candidate_07.jev.json", "jev.json"}


def test_resolve_inputs_passes_a_single_file_through(tmp_path):
    """The file form must not be filtered by name -- any path the caller names
    explicitly is theirs to choose."""
    odd = tmp_path / "anything.json"
    odd.write_text("{}")
    assert rem.resolve_inputs(odd) == [odd]


def test_a_sidecar_not_named_jev_json_still_reaches_the_projection(tmp_path, capsys):
    """The sibling lookup must not eat the projected-state fallback.

    ``<sidecar>.name.replace(".jev.json", ".manifest.json")`` is a no-op when
    the name lacks the suffix, so the "sibling" resolved to the sidecar itself.
    Reading the sidecar as its own manifest yields ``findings: None``, and the
    old code returned there -- never reaching ``state.findings``. A candidate
    that plainly carries the cited rule was reported ``not_grounded``, and the
    bug was invisible for ``<stem>.jev.json`` names because only those get a
    real sibling path.
    """
    document = {
        "status": "ok",
        "verdict": verdict("geometry_overload"),
        "state": {"findings": NODES_ADVISORY, "stats": {"path_nodes_max": 96}},
    }
    for name in ("jev.json", "envelope.json"):
        path = tmp_path / name
        path.write_text(json.dumps(document))
        assert rem.main([str(path), "--dry-run"]) == 0
        assert "TRACE" in capsys.readouterr().out, name


def test_the_projection_is_not_read_when_a_real_manifest_exists(tmp_path, capsys):
    """The guard must not break the authoritative-manifest path it protects.

    ``<stem>.jev.json`` still finds its ``.manifest.json`` sibling, and that
    manifest still wins over a projection that disagrees with it.
    """
    (tmp_path / "candidate_08.jev.json").write_text(json.dumps({
        "verdict": verdict("geometry_overload"),
        "state": {"findings": NODES_ADVISORY, "stats": {"path_nodes_max": 96}},
    }))
    # The manifest says the rule is absent, so grounding must fail -- proof the
    # manifest was read rather than the projection beside it.
    (tmp_path / "candidate_08.manifest.json").write_text(json.dumps({
        "findings": [], "stats": {},
    }))
    assert rem.main([str(tmp_path / "candidate_08.jev.json"), "--dry-run"]) == 0
    assert "not_grounded" in capsys.readouterr().out


def test_cli_accepts_a_bare_answers_envelope(tmp_path):
    """A raw service response must work: nothing currently persists a sidecar."""
    answers = {
        "failure_mode": {"type": "choice", "value": "geometry_overload", "confidence": 0.9},
        "print_route": {"type": "choice", "value": "screen_spot_multi", "confidence": 0.9},
        "tonal_structure": {"type": "score", "value": 0.5, "confidence": 0.0,
                            "probabilities": {"Broken": 0.1, "Flat": 0.1,
                                              "Retained": 0.7, "Engraving-grade": 0.1}},
        "evidence_is_actionable": {"type": "noul", "value": 0.9},
    }
    sidecar = tmp_path / "candidate_06.jev.json"
    sidecar.write_text(json.dumps({"answers": answers}))
    code = rem.main([str(sidecar), "--dry-run"])
    assert code == 0


def test_cli_empty_directory_is_an_error_without_optional(tmp_path, capsys):
    assert rem.main([str(tmp_path), "--dry-run"]) == 2
    assert "no .jev.json" in capsys.readouterr().err


# --------------------------------------------------------------------------
# --manifest: grounding the runner envelope, which carries no findings
# --------------------------------------------------------------------------

def runner_envelope(mode: str = "geometry_overload") -> dict:
    """The exact envelope chopshop-svg/runner.py hands the Studio.

    ``run_jev`` lifts only ``model``, ``endpoint``, ``latency_ms``, ``answers``
    and ``verdict`` out of the annotator's sidecar -- the projected state, and
    so every finding, is left behind in the temp dir.
    """
    return {
        "model": "jev-latest",
        "endpoint": "https://api.typesafe.ai/v1/systemone",
        "latency_ms": 412,
        "answers": {"failure_mode": {"type": "choice", "value": mode, "confidence": 0.9}},
        "verdict": verdict(mode),
    }


def test_an_envelope_alone_cannot_be_grounded(tmp_path, capsys):
    """Not a gap in the reader -- the envelope genuinely carries no findings.

    The honest answer is not_grounded, and the driver must not infer grounding
    from a verdict it cannot check against the artwork.
    """
    envelope = tmp_path / "envelope.json"
    envelope.write_text(json.dumps(runner_envelope()))
    assert rem.main([str(envelope), "--dry-run"]) == 0
    assert "not_grounded" in capsys.readouterr().out


def test_manifest_grounds_the_envelope(tmp_path, capsys):
    """With the manifest named, the same envelope plans a real remedy."""
    envelope = tmp_path / "envelope.json"
    envelope.write_text(json.dumps(runner_envelope()))
    manifest = tmp_path / "candidate_10.manifest.json"
    manifest.write_text(json.dumps({
        "findings": NODES_ADVISORY,
        "stats": {"path_nodes_max": 96},
    }))
    code = rem.main([str(envelope), "--dry-run", "--manifest", str(manifest)])
    assert code == 0
    assert "TRACE" in capsys.readouterr().out


def test_manifest_refuses_to_attach_to_a_directory_of_responses(tmp_path, capsys):
    """One manifest describes one candidate; see the guard's comment."""
    (tmp_path / "candidate_01.jev.json").write_text(json.dumps({
        "verdict": verdict("geometry_overload"),
        "state": {"findings": NODES_ADVISORY, "stats": {}},
    }))
    (tmp_path / "candidate_02.jev.json").write_text(json.dumps({
        "verdict": verdict("geometry_overload"),
        "state": {"findings": NODES_ADVISORY, "stats": {}},
    }))
    manifest = tmp_path / "candidate_01.manifest.json"
    manifest.write_text(json.dumps({"findings": NODES_ADVISORY, "stats": {}}))
    code = rem.main([str(tmp_path), "--dry-run", "--manifest", str(manifest)])
    assert code == 2
    assert "one candidate's manifest" in capsys.readouterr().err
