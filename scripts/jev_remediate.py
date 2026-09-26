#!/usr/bin/env python3
"""Plan a deterministic remediation from a Jev verdict.  DRY-RUN ONLY.

Step 2 of ``docs/remediation-loop.md``: the grounding and refusal logic.

This script decides *whether* a Jev ``failure_mode`` may trigger a
deterministic remedy, and *which* remedy the table maps it to. It executes
nothing -- there is no trace, no snap, no node reduction. ``--remediate`` is
refused with an explicit error rather than silently doing nothing, because an
operator who believes a retrace ran when it did not is worse off than one who
sees the refusal.

The shape it follows, from the plan doc:

    verdict -> refusal gates -> table lookup -> grounding -> budget -> range
            -> progress/oscillation -> TRACE (plan only)

Three deliberate departures from the plan doc, each recorded in
``scripts/remediation_table.json`` as well:

1. **Grounding ignores severity.** ``preflight.py`` marks ``NODE_COUNT`` and
   ``PALETTE`` as ``_ALWAYS_ADVISORY`` ("production quality, not printability";
   "a stray colour may be deliberate"). A grounding check filtered to hard
   findings would refuse both of the two cheap, loopable modes forever.

2. **Progress is measured on mode-specific metrics.** The plan's primary metric
   -- "count of hard findings for the grounded rule, want 0" -- is structurally
   0 both before and after for ``geometry_overload`` and ``palette_mismatch``,
   because those rules are advisory by design. It cannot detect progress, and
   ``converged`` defined that way would be satisfied by a file that never
   changed. The table names the metrics that actually move.

3. **Remedies form a ladder.** ``failure_mode`` may have several entries,
   cheapest rung first. The first rung that is grounded, still inside its range,
   and not already known to make no progress is selected. This is what lets
   ``node_reduce`` be tried before an expensive retrace, and it mirrors the
   colour ladder the plan already describes.

Usage::

    python3 scripts/jev_remediate.py candidate_03.jev.json --dry-run
    python3 scripts/jev_remediate.py 05_final/ --dry-run --json plan.json
    python3 scripts/jev_remediate.py verdict.json --dry-run --limit 2

Never ranks candidates, never picks a winner, never modifies a manifest.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import jev_annotate as jev  # noqa: E402

ROOT = SCRIPTS.parent
DEFAULT_TABLE = SCRIPTS / "remediation_table.json"
DEFAULT_LIMIT = 3  # mirrors spec.json validation.auto_retry_limit
DEFAULT_CHOPSHOP_SVG = ROOT.parent / "chopshop-svg"

# The decision to proceed. Every other value below is a termination status: a
# normal, expected end that must be reported as such, not as an error.
TRACE = "trace"

# The ten termination statuses from the plan doc, section 3.2. `converged` is
# only reachable after a trace has run, so this pass never emits it -- it is
# listed so the vocabulary is complete and stable for the steps that follow.
TERMINATION_STATUSES = (
    "converged",
    "budget_reached",
    "no_progress",
    "oscillating",
    "range_exhausted",
    "not_loopable",
    "not_grounded",
    "refused_low_confidence",
    "refused_evidence",
    "refused_no_verdict",
)


# --------------------------------------------------------------------------
# Table loading and validation
# --------------------------------------------------------------------------

def load_table(path: Path = DEFAULT_TABLE) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        table = json.load(handle)
    if not isinstance(table, dict):
        raise ValueError(f"expected a JSON object in {path}")
    if not isinstance(table.get("remedies"), list):
        raise ValueError(f"{path} has no 'remedies' array")
    return table


def validate_table(table: dict[str, Any]) -> list[str]:
    """Return the problems that make this table unusable, if any.

    Pins the table's vocabulary to the code that produces the values, so the
    two cannot drift silently. The failure_mode keys are the ones Jev can
    actually answer; a typo here would make the loop refuse every candidate as
    ``not_loopable`` while looking entirely correct.
    """
    problems: list[str] = []
    vocabulary = set(jev.QUESTIONS["failure_mode"]["criteria"])
    seen: dict[str, int] = {}

    for index, entry in enumerate(table["remedies"]):
        where = f"remedies[{index}]"
        if not isinstance(entry, dict):
            problems.append(f"{where}: not an object")
            continue

        mode = entry.get("failure_mode")
        if mode not in vocabulary:
            problems.append(
                f"{where}: failure_mode {mode!r} is not a choice value in "
                f"jev_annotate.QUESTIONS.failure_mode"
            )
        seen[mode] = seen.get(mode, 0) + 1

        if not isinstance(entry.get("loopable"), bool):
            problems.append(f"{where}: 'loopable' must be a boolean")

        if entry.get("loopable"):
            if not entry.get("grounds_in"):
                problems.append(
                    f"{where}: a loopable entry must cite at least one "
                    f"grounding rule in 'grounds_in'"
                )
            if not entry.get("metrics"):
                problems.append(
                    f"{where}: a loopable entry must name its progress "
                    f"metrics in 'metrics'"
                )
            remedy = entry.get("remedy")
            if not isinstance(remedy, dict) or not remedy.get("kind"):
                problems.append(f"{where}: a loopable entry needs remedy.kind")
            else:
                kind = remedy["kind"]
                if kind in ("retrace", "preset_param") and "range" not in remedy:
                    problems.append(
                        f"{where}: remedy kind {kind!r} needs a 'range' so the "
                        f"loop can terminate as range_exhausted"
                    )
                if not isinstance(entry.get("needs_tracer"), bool):
                    problems.append(
                        f"{where}: a loopable entry must state needs_tracer"
                    )
        else:
            # A non-loopable mode must explain itself: the refusals are the
            # operator-facing output, so a bare loopable:false is a bug.
            if not entry.get("reason"):
                problems.append(f"{where}: a non-loopable entry needs a 'reason'")
            if not entry.get("next_step"):
                problems.append(f"{where}: a non-loopable entry needs 'next_step'")

    for mode in sorted(vocabulary - set(seen)):
        problems.append(
            f"failure_mode {mode!r} has no table entry at all -- every choice "
            f"value must have either a remedy or an explicit loopable:false"
        )
    return problems


def ladder_for(table: dict[str, Any], failure_mode: str) -> list[dict[str, Any]]:
    """The entries for one mode, in table order (cheapest rung first)."""
    return [e for e in table["remedies"] if e.get("failure_mode") == failure_mode]


def remedy_id(failure_mode: str, entry: dict[str, Any]) -> str:
    """A stable name for one rung, so history can refer to it across runs.

    The name is the knob being turned, not the mechanism: node_reduce's knob is
    ``tolerance``, so its id is ``geometry_overload/tolerance`` even though the
    remedy kind is ``node_reduce``. History keyed on the mechanism would fail to
    recognise the same rung if it were ever reimplemented.
    """
    remedy = entry["remedy"]
    kind = remedy["kind"]
    if kind == "retrace":
        tail = remedy["axis"]
    elif kind == "preset_param":
        tail = remedy["param"]
    elif kind == "snap":
        tail = remedy["op"]
    else:
        tail = remedy.get("axis", kind)
    return f"{failure_mode}/{tail}"


# --------------------------------------------------------------------------
# Deterministic metrics
# --------------------------------------------------------------------------

def _stat(stats: dict[str, Any], key: str) -> Any:
    """Read a stat from the top level, else from stats.static.

    The annotator lifts the static figures to the top level, but the raw
    manifest nests them, and a metric read from the wrong level reads as None
    and silently disables the progress check.
    """
    if key in stats:
        return stats[key]
    static = stats.get("static")
    if isinstance(static, dict):
        return static.get(key)
    return None


def count_rule_findings(findings: list[Any], rules: list[str]) -> int:
    """Findings for the cited rules, at ANY severity (see module docstring)."""
    wanted = set(rules)
    return sum(
        1 for f in findings
        if isinstance(f, dict) and f.get("rule") in wanted
    )


def extract_metrics(
    stats: dict[str, Any],
    findings: list[Any],
    rules: list[str],
    names: list[str],
) -> dict[str, Any]:
    """Project the deterministic progress metrics for one mode.

    Never includes a Jev number: the judgement is advisory and its confidence
    can move on identical input as the model is versioned, so progress must be
    measured on the pipeline's own output.
    """
    measured: dict[str, Any] = {}
    for name in names:
        if name == "rule_findings":
            measured[name] = count_rule_findings(findings, rules)
            continue
        value = _stat(stats, name)
        # off_palette_colors is a list of hexes in the real manifest.
        if isinstance(value, list):
            value = len(value)
        measured[name] = value if isinstance(value, (int, float)) else None
    return measured


def improved(before: dict[str, Any], after: dict[str, Any], names: list[str]) -> bool:
    """True when any cited metric improves and none regresses.

    The anti-random-walk rule: without it the loop is free to wander while
    reporting activity. Lower is better for every metric in the table.
    """
    better = False
    for name in names:
        old, new = before.get(name), after.get(name)
        if old is None or new is None:
            continue
        if new < old:
            better = True
        elif new > old:
            return False
    return better


# --------------------------------------------------------------------------
# Range stepping
# --------------------------------------------------------------------------

def next_value(remedy: dict[str, Any], tried: list[float]) -> tuple[float | None, bool]:
    """The value to try on this rung, and whether the range is spent.

    Returns (None, False) for rungs that carry their own internal escalation
    (``node_reduce`` doubles its own tolerance to ``tolerance_cap``) or that
    have no knob at all (``snap --force``). Returns (None, True) when the next
    step would leave the range: the plan is explicit that a remedy which would
    leave its range must terminate as ``range_exhausted`` rather than clamp and
    continue.
    """
    if remedy["kind"] == "node_reduce":
        return None, False
    if remedy["kind"] == "snap" and remedy.get("op") == "force":
        return None, False

    low, high = remedy["range"]
    value = remedy["from"] if not tried else tried[-1] + remedy["step"]
    if value < min(low, high) or value > max(low, high):
        return None, True
    return value, False


# --------------------------------------------------------------------------
# The decision
# --------------------------------------------------------------------------

def _refuse(status: str, failure_mode: Any, *, reason: str, next_step: str | None = None) -> dict[str, Any]:
    return {
        "status": status,
        "failure_mode": failure_mode,
        "reason": reason,
        "next_step": next_step,
        "remedy": None,
        "sweep": None,
        "invocation": None,
    }


def parent_context(parent_sweep: dict[str, Any] | None, svg_name: str) -> dict[str, Any] | None:
    """The traced context of one candidate, from the sweep that produced it.

    A surgical retrace has to vary *one* axis and hold every other axis where
    the candidate already had it. Without this, trace_sweep's own defaults
    reintroduce a second varying axis (``use_palette`` defaults to
    ``[False, True]``), and the loop would spend its budget on a difference
    that has nothing to do with the failure it is trying to fix.
    """
    if not isinstance(parent_sweep, dict):
        return None
    for candidate in parent_sweep.get("candidates") or []:
        if isinstance(candidate, dict) and candidate.get("file") == svg_name:
            return {
                "preset": candidate.get("preset"),
                "use_palette": candidate.get("use_palette"),
                "hierarchical": candidate.get("hierarchical"),
                "filter_speckle": candidate.get("filter_speckle"),
                # ``params`` is the tracer's fully resolved parameter set, so it
                # is the authority on what this candidate already is -- which is
                # what tells a rung where to start stepping from.
                "params": candidate.get("params") or {},
            }
    return None


def context_value(context: dict[str, Any] | None, axis: str | None) -> Any:
    """What value this candidate already has on the axis a rung would turn."""
    if not context or not axis:
        return None
    params = context.get("params") or {}
    if axis in params:
        return params[axis]
    return context.get(axis)


def _seed_tried(history_values: list[Any], current: Any, step: Any) -> list[Any]:
    """Seed a rung's ``tried`` list so the next step starts where this candidate is.

    Without this, a rung whose ``from`` happens to equal the candidate's current
    value emits a byte-identical retrace (the sweep is deterministic, so the
    same parameters produce the same output_sha256) and burns a budget slot to
    learn nothing, then reports it as "no progress".
    """
    values = [v for v in history_values if v is not None]
    if current is not None and current not in values:
        values.append(current)
    if values and isinstance(step, (int, float)):
        # The furthest point along the direction of travel.
        values.sort(reverse=step < 0)
    return values


def _child_sweep(
    entry: dict[str, Any],
    value: float | None,
    context: dict[str, Any] | None = None,
) -> tuple[dict[str, Any], str]:
    """The targeted retrace for this rung, and a note on what it assumed.

    Every axis is pinned to a single value so only the remediated parameter
    moves. Returns ``(sweep, note)``: the note is reported *beside* the sweep
    rather than embedded in it, so the sweep object stays exactly the schema
    trace_sweep.py reads and remains a valid input to it.
    """
    remedy = entry["remedy"]
    kind = remedy["kind"]
    context = context or {}

    # node_reduce and snap post-process an SVG that already exists; they are
    # not traces, so there is no sweep to emit and no tracer context to hold
    # fixed. Returning a sweep here would misdescribe a file edit as a retrace.
    if kind not in ("retrace", "preset_param"):
        return None, None

    assumed: list[str] = []

    def inherit(key: str, fallback: Any) -> Any:
        if context.get(key) is not None:
            return context[key]
        assumed.append(key)
        return fallback

    sweep: dict[str, Any] = {
        "version": 1,
        "hierarchical": [inherit("hierarchical", "cutout")],
        "use_palette": [inherit("use_palette", False)],
        "filter_speckle": [inherit("filter_speckle", 2)],
        "max_candidates": 2,
    }

    if kind == "retrace":
        sweep["presets"] = [inherit("preset", "poster")]
        sweep["filter_speckle"] = [value]
    elif kind == "preset_param":
        preset = remedy["preset"]
        # A partial dict is correct: trace_sweep merges preset_params over its
        # own PRESETS, so this is a delta on the preset's built-in value.
        sweep["presets"] = [preset]
        sweep["preset_params"] = {preset: {remedy["param"]: value}}

    if assumed:
        note = (
            "context defaulted (no parent sweep) for "
            + ", ".join(sorted(assumed))
            + "; pass --parent-sweep to inherit them from the candidate"
        )
    else:
        note = "context inherited from the parent sweep"
    return sweep, note


def _invocation(
    entry: dict[str, Any],
    value: float | None,
    chopshop_svg: Path,
) -> list[str] | None:
    """The argv this rung would run, with paths left as explicit placeholders.

    Rungs that post-process an existing SVG (node_reduce, snap) are not sweeps,
    so they get an invocation instead. The placeholder SVG path is deliberate:
    the plan stage does not know which candidate a future iteration would pick,
    and inventing one here would look like a decision the loop has not made.
    """
    remedy = entry["remedy"]
    scripts = chopshop_svg / "scripts"
    kind = remedy["kind"]
    if kind == "node_reduce":
        return [
            sys.executable, str(scripts / "node_reduce.py"), "<candidate.svg>",
            "--max-nodes", "<spec.geometry.max_nodes_per_path>",
            "--tolerance", str(remedy["tolerance"]),
            "--tolerance-cap", str(remedy["tolerance_cap"]),
            "--json", "<remedy-result.json>",
        ]
    if kind == "snap":
        argv = [
            sys.executable, str(scripts / "snap_colors.py"), "<candidate.svg>",
            "<spec.json>",
        ]
        if remedy["op"] == "force":
            argv.append("--force")
        else:
            argv += ["--tolerance", str(value)]
        return argv
    return None


def decide(
    *,
    verdict: dict[str, Any],
    findings: list[Any],
    table: dict[str, Any],
    stats: dict[str, Any] | None = None,
    iteration: int = 1,
    limit: int = DEFAULT_LIMIT,
    history: list[dict[str, Any]] | None = None,
    parent_sweep: dict[str, Any] | None = None,
    candidate_svg: str | None = None,
    chopshop_svg: Path = DEFAULT_CHOPSHOP_SVG,
) -> dict[str, Any]:
    """Decide what, if anything, this verdict may trigger.

    Pure: takes the verdict, the candidate's findings, the table, and the
    iteration history, and returns a plan. No I/O, no network, no execution --
    which is what makes every status below testable without a service.
    """
    stats = stats or {}
    history = history or []

    # --- refusal gates, before any table is consulted ---------------------
    failure_mode = verdict.get("headline")
    if not failure_mode:
        return _refuse(
            "refused_no_verdict", failure_mode,
            reason="no failure_mode/headline in the verdict",
            next_step="re-run jev_annotate.py for this candidate",
        )

    # low_confidence lists *question ids*, not failure_mode values: the verdict
    # is {"low_confidence": ["tonal_structure"], ...}. Testing the value against
    # it would never match and this gate would never fire, so the loop would act
    # on a guess while appearing to have checked.
    if "failure_mode" in (verdict.get("low_confidence") or []):
        return _refuse(
            "refused_low_confidence", failure_mode,
            reason=(
                f"failure_mode {failure_mode!r} fell below the confidence floor "
                f"({verdict.get('confidence_floor')}); acting on it would turn a "
                f"guess into a retrace that looks principled because a table was "
                f"consulted"
            ),
            next_step="ask for human review, or improve measurement fidelity",
        )

    if verdict.get("evidence_actionable") is False:
        return _refuse(
            "refused_evidence", failure_mode,
            reason=(
                "evidence_is_actionable is false: the measurements do not "
                "support a production decision, so no remedy is justified"
            ),
            next_step="supply the missing or failed measurement",
        )

    # --- table lookup ------------------------------------------------------
    ladder = ladder_for(table, failure_mode)
    if not ladder:
        return _refuse(
            "not_loopable", failure_mode,
            reason=f"no table entry for failure_mode {failure_mode!r}",
            next_step="add the mode to scripts/remediation_table.json",
        )

    # The candidate's own traced parameters, which say where each rung must
    # start stepping from. Resolved once; used by the walk and the child sweep.
    ctx = parent_context(parent_sweep, candidate_svg) if candidate_svg else None

    # --- ladder walk: first grounded rung still inside its range -----------
    trace_trace: list[dict[str, Any]] = []
    selected: dict[str, Any] | None = None
    selected_value: float | None = None
    selected_id: str | None = None
    exhausted_any = False
    ungrounded_any = False

    for entry in ladder:
        # Loopability is branch zero: a mode that is structurally unfixable by
        # retracing stops the loop before any grounding or budget arithmetic.
        # Checked before remedy_id(), which reads entry["remedy"] -- a
        # non-loopable entry has no remedy to name.
        if not entry.get("loopable"):
            trace_trace.append({
                "remedy_id": f"{failure_mode}/not_loopable",
                "outcome": "not_loopable",
            })
            return _refuse(
                "not_loopable", failure_mode,
                reason=entry.get("reason", "mode is not remediable by retracing"),
                next_step=entry.get("next_step"),
            )

        entry_id = remedy_id(failure_mode, entry)

        grounded = count_rule_findings(findings, entry.get("grounds_in") or []) > 0
        if not grounded:
            ungrounded_any = True
            trace_trace.append({
                "remedy_id": entry_id,
                "outcome": "skipped_not_grounded",
                "grounds_in": entry.get("grounds_in"),
            })
            continue

        tried = _seed_tried(
            [
                h["remedy_value"] for h in history
                if h.get("remedy_id") == entry_id and h.get("remedy_value") is not None
            ],
            context_value(ctx, entry["remedy"].get("axis")),
            entry["remedy"].get("step"),
        )
        value, spent = next_value(entry["remedy"], tried)
        if spent:
            exhausted_any = True
            trace_trace.append({"remedy_id": entry_id, "outcome": "skipped_range_exhausted"})
            continue

        selected = entry
        selected_value = value
        selected_id = entry_id
        trace_trace.append({"remedy_id": entry_id, "outcome": "selected"})
        break

    if selected is None:
        if ungrounded_any:
            return {
                **_refuse(
                    "not_grounded", failure_mode,
                    reason=(
                        "the cited rule is absent from this candidate's findings, "
                        "so no remedy may be applied -- this stops a mode from "
                        "triggering a parameter change on a file with no such defect"
                    ),
                    next_step="re-annotate after the measurement changes",
                ),
                "ladder": trace_trace,
            }
        return {
            **_refuse(
                "range_exhausted", failure_mode,
                reason="every grounded rung for this mode is at the end of its permitted range",
                next_step="loosen the range in the table, or hand back to the human pick",
            ),
            "ladder": trace_trace,
        }

    # --- budget ------------------------------------------------------------
    if iteration > limit:
        return {
            **_refuse(
                "budget_reached", failure_mode,
                reason=(
                    f"iteration {iteration} exceeds the retry budget of {limit} "
                    f"(spec.json validation.auto_retry_limit)"
                ),
                next_step="hand the run back to the human pick",
            ),
            "ladder": trace_trace,
        }

    # --- progress and oscillation -----------------------------------------
    metrics = selected.get("metrics") or []
    rules = selected.get("grounds_in") or []
    measured = extract_metrics(stats, findings, rules, metrics)

    # Oscillation is checked before no_progress because it is the more specific
    # diagnosis: when two modes alternate without movement, "this rung made no
    # progress" is true but unhelpful -- the finding is that the knobs are
    # fighting each other, and escalating the rung cannot fix that.
    if (
        len(history) >= 2
        and history[-2].get("failure_mode") == failure_mode
        and not history[-1].get("improved", False)
        and not history[-2].get("improved", False)
    ):
        return {
            **_refuse(
                "oscillating", failure_mode,
                reason=(
                    f"{failure_mode!r} is back after two iterations without metric "
                    f"movement -- the two modes are alternating, not converging"
                ),
                next_step="hand back to the human pick; the knobs are fighting",
            ),
            "ladder": trace_trace,
            "metrics": {"before": measured, "names": metrics},
        }

    same_rung = [h for h in history if h.get("remedy_id") == selected_id]
    if same_rung and not same_rung[-1].get("improved", False):
        return {
            **_refuse(
                "no_progress", failure_mode,
                reason=(
                    f"{selected_id} was already tried and the cited metrics did "
                    f"not improve; repeating it would be a random walk"
                ),
                next_step="escalate to the next rung, or hand back to the human pick",
            ),
            "ladder": trace_trace,
            "metrics": {"before": measured, "names": metrics},
        }

    # --- TRACE (plan only) -------------------------------------------------
    sweep, sweep_note = _child_sweep(selected, selected_value, ctx)
    return {
        "status": TRACE,
        "failure_mode": failure_mode,
        "reason": None,
        "next_step": None,
        "remedy": {
            "id": selected_id,
            "kind": selected["remedy"]["kind"],
            "needs_tracer": selected.get("needs_tracer", False),
            "variant": selected.get("variant"),
            "axes": selected["remedy"],
            "value": selected_value,
        },
        "grounded_in": rules,
        "metrics": {"before": measured, "names": metrics, "after": None},
        "sweep": sweep,
        "sweep_context": sweep_note,
        "invocation": _invocation(selected, selected_value, chopshop_svg),
        "iteration": iteration,
        "limit": limit,
        "ladder": trace_trace,
    }


# --------------------------------------------------------------------------
# Input resolution
# --------------------------------------------------------------------------

def _verdict_from(document: dict[str, Any]) -> dict[str, Any]:
    """Accept a jev sidecar, or a bare Jev response, and return a verdict.

    Both shapes are real: the annotator writes a sidecar, but the runner hands
    the Studio a bare ``{answers: ...}`` envelope, and nothing currently
    persists the sidecar to disk (runner.py writes it to a temp dir). Reusing
    ``compose_verdict`` keeps the thresholds identical to the annotator's.
    """
    verdict = document.get("verdict")
    if isinstance(verdict, dict) and verdict.get("headline"):
        return verdict
    answers = document.get("answers")
    if isinstance(answers, dict):
        return jev.compose_verdict(answers)
    return verdict if isinstance(verdict, dict) else {}


def _findings_for(
    document: dict[str, Any],
    sidecar_path: Path,
    manifest_path: Path | None,
) -> tuple[list[Any], dict[str, Any]]:
    """Findings and stats, preferring the manifest over the projection.

    The manifest is authoritative and carries fields the projection drops
    (notably ``off_palette_colors``, which jev_annotate does not lift). The
    sidecar's projected state is the fallback so a plan is still possible when
    the manifest has moved on.

    The sibling lookup is guarded on the ``.jev.json`` suffix rather than run
    unconditionally. ``str.replace`` on a name that lacks the suffix is a no-op,
    so for any other name -- ``jev.json`` from the runner's temp dir, or a raw
    response saved as ``envelope.json`` -- the "sibling" came out as the sidecar
    path itself. The sidecar was then read as its own manifest, ``findings``
    came back ``None``, and the function returned early with an empty list: the
    projected-state fallback below was never reached, and a candidate with the
    cited rule present was reported ``not_grounded``.
    """
    candidate = manifest_path
    if candidate is None and sidecar_path.name.endswith(".jev.json"):
        sibling = sidecar_path.with_name(
            sidecar_path.name.replace(".jev.json", ".manifest.json")
        )
        candidate = sibling if sibling.is_file() else None

    if candidate is not None and candidate.is_file():
        try:
            manifest = jev._read_json(candidate)
        except (OSError, ValueError, json.JSONDecodeError):
            manifest = None
        if isinstance(manifest, dict):
            findings = manifest.get("findings")
            stats = manifest.get("stats")
            return (
                findings if isinstance(findings, list) else [],
                stats if isinstance(stats, dict) else {},
            )

    state = document.get("state")
    if isinstance(state, dict):
        findings = state.get("findings")
        stats = state.get("stats")
        return (
            findings if isinstance(findings, list) else [],
            stats if isinstance(stats, dict) else {},
        )
    return [], {}


def resolve_inputs(target: Path) -> list[Path]:
    """A single sidecar/response file, or every sidecar in a directory.

    Two filenames are real, and a glob for either one alone silently misses a
    valid sidecar sitting in plain sight:

    * ``<stem>.jev.json`` -- the annotator's ``default_output``, and the name
      the Studio tells the operator to expect (jev.html.erb:124).
    * ``jev.json`` -- what the runner actually writes. ``chopshop-svg/runner.py``
      redirects the annotator into a temp dir under that fixed name (the job
      directory is root-owned on a bind mount, so it is not the runner's to
      write in), then deletes the dir and lifts answers/verdict into the HTTP
      envelope. So the documented name is the one that, on the runner path,
      never exists.
    """
    if target.is_dir():
        found = set(target.glob("*.jev.json")) | set(target.glob("jev.json"))
        return sorted(found)
    return [target]


def plan_for_sidecar(
    sidecar_path: Path,
    *,
    table: dict[str, Any],
    iteration: int,
    limit: int,
    history: list[dict[str, Any]],
    chopshop_svg: Path,
    parent_sweep: dict[str, Any] | None = None,
    manifest_path: Path | None = None,
) -> dict[str, Any]:
    document = jev._read_json(sidecar_path)
    verdict = _verdict_from(document)
    findings, stats = _findings_for(document, sidecar_path, manifest_path)
    # candidate_10.jev.json -> candidate_10.svg, the name sweep.json indexes on.
    candidate_svg = sidecar_path.name.replace(".jev.json", ".svg")
    plan = decide(
        verdict=verdict,
        findings=findings,
        table=table,
        stats=stats,
        iteration=iteration,
        limit=limit,
        history=history,
        parent_sweep=parent_sweep,
        candidate_svg=candidate_svg,
        chopshop_svg=chopshop_svg,
    )
    plan["source"] = sidecar_path.name
    return plan


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "target", type=Path,
        help="a .jev.json sidecar, a raw Jev response JSON, or a directory of sidecars",
    )
    parser.add_argument("--table", type=Path, default=DEFAULT_TABLE)
    parser.add_argument("--iteration", type=int, default=1)
    parser.add_argument(
        "--limit", type=int, default=None,
        help=f"retry budget; defaults to spec validation.auto_retry_limit, else {DEFAULT_LIMIT}",
    )
    parser.add_argument(
        "--history", type=Path, default=None,
        help="a remediation log (06_run/<stem>.remediation.json) to test progress against",
    )
    parser.add_argument(
        "--parent-sweep", type=Path, default=None,
        help=(
            "the sweep.json that produced this candidate; its candidate entry "
            "supplies the context the child sweep must hold fixed"
        ),
    )
    parser.add_argument(
        "--manifest", type=Path, default=None,
        help=(
            "the manifest.json this response describes; needed when the input "
            "is a runner envelope, which carries answers and verdict but no "
            "findings, so grounding has nothing to read otherwise"
        ),
    )
    parser.add_argument("--chopshop-svg", type=Path, default=DEFAULT_CHOPSHOP_SVG)
    parser.add_argument("--json", dest="json_path", type=Path, default=None)
    parser.add_argument(
        "--dry-run", action="store_true",
        help="print the plan; this is the only supported mode today",
    )
    parser.add_argument(
        "--remediate", action="store_true",
        help="refused: execution is not implemented (steps 3+)",
    )
    parser.add_argument(
        "--optional", action="store_true",
        help="exit 0 with a skip note when the input or table is unavailable",
    )
    args = parser.parse_args(argv)

    if args.remediate:
        # Deliberately not a silent no-op: an operator must never believe a
        # retrace ran when nothing was executed.
        print(
            "error: --remediate is not implemented yet; this pass is dry-run "
            "only (docs/remediation-loop.md steps 1-2)",
            file=sys.stderr,
        )
        return 2

    try:
        table = load_table(args.table)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        if args.optional:
            print(f"Jev remediation skipped: {exc}")
            return 0
        print(f"error: {exc}", file=sys.stderr)
        return 2

    problems = validate_table(table)
    if problems:
        print("error: the remediation table is not usable:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 2

    history: list[dict[str, Any]] = []
    if args.history is not None:
        try:
            log = jev._read_json(args.history)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        entries = log.get("iterations")
        history = entries if isinstance(entries, list) else []

    parent_sweep: dict[str, Any] | None = None
    if args.parent_sweep is not None:
        try:
            parent_sweep = jev._read_json(args.parent_sweep)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            if args.optional:
                print(f"Jev remediation skipped: {exc}")
                return 0
            print(f"error: {exc}", file=sys.stderr)
            return 2

    limit = args.limit if args.limit is not None else DEFAULT_LIMIT

    try:
        targets = resolve_inputs(args.target)
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if not targets:
        reason = f"no .jev.json sidecars found in {args.target}"
        if args.optional:
            print(f"Jev remediation skipped: {reason}")
            return 0
        print(f"error: {reason}", file=sys.stderr)
        return 2

    if args.manifest is not None and len(targets) != 1:
        # One manifest describes one candidate. Attaching it to a directory of
        # responses would ground every plan on whichever file it happened to be,
        # which is exactly the silent mismatch the grounding check exists to stop.
        print(
            f"error: --manifest names one candidate's manifest, but {len(targets)} "
            "responses were given; pass a single response file",
            file=sys.stderr,
        )
        return 2

    plans = []
    for target in targets:
        try:
            plans.append(plan_for_sidecar(
                target,
                table=table,
                iteration=args.iteration,
                limit=limit,
                history=history,
                chopshop_svg=args.chopshop_svg,
                parent_sweep=parent_sweep,
                manifest_path=args.manifest,
            ))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            if not args.optional:
                print(f"error: {target}: {exc}", file=sys.stderr)
                return 2
            plans.append({"source": target.name, "status": "skipped", "reason": str(exc)})

    document = {
        "schema": "chopshop-jev-remediation-plan-0.1",
        "mode": "dry_run",
        "iteration": args.iteration,
        "limit": limit,
        "plans": plans,
    }

    if args.json_path is not None:
        jev._write_json(args.json_path, document)

    for plan in plans:
        status = plan.get("status")
        source = plan.get("source", "?")
        if status == TRACE:
            remedy = plan["remedy"]
            print(
                f"{source}: TRACE {remedy['id']} "
                f"({'retrace' if remedy['needs_tracer'] else 'tracer-free'})"
            )
            if plan.get("sweep"):
                print("  sweep: " + json.dumps(plan["sweep"], sort_keys=True))
                print("  " + plan.get("sweep_context", ""))
            if plan.get("invocation"):
                print("  invocation: " + " ".join(plan["invocation"]))
        else:
            print(f"{source}: {status} -- {plan.get('reason')}")
            if plan.get("next_step"):
                print(f"  next: {plan['next_step']}")
        for rung in plan.get("ladder") or []:
            if rung.get("outcome") != "selected":
                print(f"  ({rung['remedy_id']}: {rung['outcome']})")

    if args.json_path is not None:
        print(f"plan written: {args.json_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
