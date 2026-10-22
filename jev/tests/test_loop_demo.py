#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""The whole automated loop over a BATCH of generative work, demonstrated.

chopshop-jev#11. Every other test file in this suite pins one unit in
isolation: the question sets, the folds, the bucket rule, the ladder. What is
never shown is the loop an automated batch actually runs --

    artifacts in -> question set asked -> answers folded -> loop decision out

-- which is the only claim the default question set has to stand behind. This
file walks a fixture batch through the shipped vocabularies and asserts the
decision each stage hands to the next one.

Three legs, in the order a batch runs them:

  1. GENERATION-SLOP. A batch of artifacts in the studio's run-job output
     shape (image + measurements + prompt/model/seed metadata, optionally a
     caption) goes through the real annotator against a loopback stub of the
     decision service, and `slop_cannon.bucket()` turns each sidecar into
     keep / escalate / drop. The disagreement cases -- a slop signature beside
     a high structure score, the converse (a structured signature beside a
     zero score), an answer under the floor -- must ESCALATE, not resolve:
     that is the property that makes the loop safe to run unattended.

  2. PRINTABILITY (the DEFAULT set). A printability verdict goes through
     `jev_remediate`'s ladder, and the default question set's answers choose
     the next action: the tracer-free rung first, and a refusal when the
     answers are a guess. Two of the four questions are the ones the ladder
     branches on, which is the whole reason the default set can guide a loop.

  3. DATASET-TRANSLATION. An artifact through its own fold records an
     annotation whose shape is pinned here, including what it honestly
     refuses to answer (the image-dependent questions are unevidenced by
     construction, and a caption changes that).

Plus two drift pins that exist because a silent edit is worse than a broken
build:

  * the default question set's CONTRACT -- keys, type per question, choice
    keys, score legend, DEFAULT_CONFIDENCE_FLOOR -- as an explicit artifact,
    so editing `QUESTIONS` fails a test instead of a batch run;
  * every shipped question key declaring the decision path that reads it, so
    a question that guides nothing cannot be added unnoticed.

HERMETIC BY CONSTRUCTION. This box exports LAYA_API_KEY and
CHOPSHOP_OPENROUTER_KEY (see the caveat in CONTEXT.md), and the annotator
resolves a key from the environment or from ~/.hermes/.env. The autouse
fixture in tests/conftest.py scrubs every name the annotator accepts and
empties `DEFAULT_ENV_FILES`, so no test in the suite can pass by picking
up an ambient credential. The only network is a 127.0.0.1 stub server;
no GPU, no weights, no model.

The stub is a DETERMINISTIC STAND-IN for the decision service, not a model:
it derives its answers from the measurements in the state it is handed, by
rules stated in `_stub_answers`. What is under test is the loop around it.
"""

from __future__ import annotations

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

# The PNG encoder lives with the decoder it round-trips against: one encoder,
# pinned in test_slop_cannon.py, rather than a second copy here.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_slop_cannon import png_bytes  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
for _p in (str(ROOT), str(SCRIPTS)):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import jev_annotate as jev  # noqa: E402
import jev_remediate as rem  # noqa: E402
import slop_cannon  # noqa: E402


# --------------------------------------------------------------------------
# Hermeticity: no ambient credential may reach the annotator
# --------------------------------------------------------------------------

# The autouse no_ambient_credentials fixture that scrubs every key/endpoint
# name the annotator resolves (and empties DEFAULT_ENV_FILES) lives in
# tests/conftest.py, so every test file inherits it from one place
# (chopshop-jev#12) instead of a per-file copy.


# --------------------------------------------------------------------------
# The fixture batch: the studio's run-job output shape
# --------------------------------------------------------------------------
#
# What the generative Run Job templates (`generate_only`, `generate_and_trace`,
# `generate_trace_render` in chopshop-studio's PipelineConf) leave behind, as
# `slop_cannon.py` writes it: a prompt, the settings the generator ran with,
# the raster it produced, the measurements taken of that raster, and the
# caption when a captioner supplied one. The measurements here are produced by
# the SHIPPED measurement code over fixture pixels, not hand-typed, so the
# batch exercises the same decoder and the same metric definitions a real run
# does. 32x32 rather than 512x512: the shape is what is pinned, and a fixture
# raster has no reason to cost a second of CPU.

SIZE = 32
STEPS = 12
GUIDANCE = 3.5
JOB = 386

# Four colour blocks: separated regions, edges, a real tonal spread.
_QUAD = (((200, 30, 30), (30, 200, 30)), ((30, 30, 200), (230, 220, 40)))


def _poster_rows():
    return [[_QUAD[y // (SIZE // 2)][x // (SIZE // 2)] for x in range(SIZE)]
            for y in range(SIZE)]


def _flat_rows():
    return [[(90, 100, 110)] * SIZE for _ in range(SIZE)]


def _checker_rows():
    return [[(0, 0, 0) if (x + y) % 2 else (255, 255, 255) for x in range(SIZE)]
            for y in range(SIZE)]


def _washed_rows():
    # Four near-identical greys: low contrast, few levels, no edges.
    levels = [(60, 60, 60), (70, 70, 70), (80, 80, 80), (90, 90, 90)]
    return [[levels[min(3, (x + y) // 16)] for x in range(SIZE)] for y in range(SIZE)]


def _explosion_rows():
    return [[((x * 8) % 256, (y * 8) % 256, ((x + y) * 4) % 256) for x in range(SIZE)]
            for y in range(SIZE)]


def _borderline_rows():
    # Three greys whose spread sits just under the washed/structured boundary,
    # so the answer is genuinely uncertain rather than merely under the floor.
    counts = [40] * 640 + [60] * 260 + [80] * 124
    return [[(counts[(y * SIZE + x) * 37 % (SIZE * SIZE)],) * 3 for x in range(SIZE)]
            for y in range(SIZE)]


def _noisy_regions_rows():
    # Fine checkerboard over three quarters of the frame, solid grey over the
    # rest: high-frequency noise AND real tonal spread, which is exactly the
    # pair the bucket rule refuses to resolve by ordering its two checks.
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            if x < 3 * SIZE // 4:
                row.append((0, 0, 0) if (x + y) % 2 else (255, 255, 255))
            else:
                row.append((128, 128, 128))
        rows.append(row)
    return rows


def _gradient_rows():
    # The other direction of the same disagreement: a smooth gradient whose
    # tonal spread is wide (luma_std well above 15, so the stub reads a
    # STRUCTURED signature) but in which no single colour covers 1% of the
    # frame, so no colour is significant and the score comes back 0. Every
    # pixel is distinct under the 5-bit quantisation, spread across two axes
    # with steps small enough that the gradient reads as continuous rather
    # than as regions -- the ramp is (4x + 2y, 2x + 4y), which keeps the
    # distinct-colour count under the 400 that would make it an explosion.
    return [[(4 * x + 2 * y, 2 * x + 4 * y, 0) for x in range(SIZE)]
            for y in range(SIZE)]


def make_artifact(stem, prompt, model, seed, rows, *, caption=None,
                  caption_model=None, topic=None):
    """One run-job output, measured by the shipped measurement code."""
    measurements = slop_cannon.measure_raster(png_bytes(rows))
    image = {"file": f"{stem}.png"}
    if caption is not None:
        image["caption"] = caption
        image["caption_model"] = caption_model
    return {
        "prompt": prompt,
        "topic": topic,
        "settings": {"seed": seed, "steps": STEPS, "guidance": GUIDANCE,
                     "model": model, "width": SIZE, "height": SIZE},
        "generation": {"model": model, "job": JOB, "raster": f"{stem}.png"},
        "measurements": measurements,
        "image": image,
    }


# The batch. `expect` is the bucket verdict the loop must reach for this
# artifact; `signature`/`score` are the answers the stub will give, asserted
# beside the verdict so a fixture drifting into a different case is visible.
BATCH = [
    {"stem": "blank-frame", "rows": _flat_rows, "expect": "drop",
     "signature": "blank_or_near_blank", "score": 0,
     "prompt": "a single flat grey field, nothing on it",
     "why": "confident slop"},
    {"stem": "colour-blocks", "rows": _poster_rows, "expect": "keep",
     "signature": "structured", "score": 3,
     "prompt": "a flat vector poster of four colour blocks",
     "why": "confident structure"},
    {"stem": "fine-checker", "rows": _checker_rows, "expect": "drop",
     "signature": "uniform_noise", "score": 1,
     "prompt": "high frequency television static, black and white",
     "why": "confident slop"},
    {"stem": "pale-wash", "rows": _washed_rows, "expect": "escalate",
     "signature": "washed_flat", "score": 2,
     "prompt": "a pale watercolour wash, very low contrast",
     "why": "disagrees"},
    {"stem": "near-threshold", "rows": _borderline_rows, "expect": "escalate",
     "signature": "washed_flat", "score": 2,
     "prompt": "a soft grey gradient field, almost no contrast",
     "why": "floor"},
    {"stem": "colour-storm", "rows": _explosion_rows, "expect": "drop",
     "signature": "colour_explosion", "score": 0,
     "prompt": "every colour at once, a dense rainbow noise field",
     "why": "confident slop"},
    {"stem": "noise-over-regions", "rows": _noisy_regions_rows, "expect": "escalate",
     "signature": "uniform_noise", "score": 3,
     "prompt": "television static printed over four flat colour blocks",
     "why": "disagrees"},
    {"stem": "wide-gradient", "rows": _gradient_rows, "expect": "escalate",
     "signature": "structured", "score": 0,
     "prompt": "a smooth gradient sweeping the whole tonal range",
     "why": "disagrees"},
]

CAPTIONED = {"stem": "captioned-blocks", "rows": _poster_rows,
             "prompt": "a flat vector poster of four colour blocks",
             "caption": "four flat colour blocks, red green blue and yellow, "
                        "on a plain background",
             "caption_model": "LiquidAI/LFM2.5-VL-450M"}


def batch_artifacts():
    return [(entry, make_artifact(entry["stem"], entry["prompt"], "klein-4b",
                                  4242, entry["rows"]()))
            for entry in BATCH]


def by_stem_of(stem):
    """(entry, artifact) for one batch stem, measured the same way the loop
    measures it -- so a test can reach for a single artifact without
    re-measuring it by a different path."""
    for entry, artifact in batch_artifacts():
        if entry["stem"] == stem:
            return entry, artifact
    raise AssertionError("no batch artifact named %r" % stem)


# --------------------------------------------------------------------------
# The stub decision service: deterministic, derived from the state it is sent
# --------------------------------------------------------------------------

class _DecisionStub(BaseHTTPRequestHandler):
    """A loopback stand-in for the decision service.

    It answers from the MEASUREMENTS in the state, by the rules below, so the
    loop's inputs drive its outputs the way a real service's would. The rules
    are stated here rather than hidden in a fixture dict precisely so the
    disagreement and below-floor cases are reproducible: the batch is built to
    land on them.
    """

    requests: list = []

    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler's protocol
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.__class__.requests.append(body)
        answers = _stub_answers(body)
        raw = json.dumps({"model": "stub-decision-service", "answers": answers,
                          "usage": {"input_tokens": 128, "output_tokens": 0}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        pass


def _mass(margin):
    """A probability mass from a decision margin, so a near-boundary answer
    lands under the floor instead of every answer being confident."""
    return round(0.5 + 0.4 * min(1.0, max(0.0, margin)), 4)


def _signature_and_score(measurements):
    """Which slop signature the measurements support, and how much structure.

    The thresholds are the vocabulary's own words turned into arithmetic: a
    frame that is one colour everywhere, pixels that differ from their
    neighbours far more than from pixels eight away, more distinct colours
    than a frame can hold, a tonal spread under fifteen, or a real spread.
    """
    background = measurements.get("slop_background_fraction", 0.0)
    std = measurements.get("slop_luma_std", 0.0)
    levels = measurements.get("slop_luma_levels", 0)
    significant = measurements.get("slop_significant_colors", 0)
    distinct = measurements.get("slop_distinct_colors", 0)
    noise = measurements.get("slop_noise_ratio", 0.0)

    if background >= 0.9:
        signature, margin = "blank_or_near_blank", (background - 0.9) / 0.1
    elif noise >= 5:
        signature, margin = "uniform_noise", (noise - 5) / 8.0
    elif distinct >= 400:
        signature, margin = "colour_explosion", (distinct - 400) / 600.0
    elif std < 15:
        signature, margin = "washed_flat", (15 - std) / 5.0
    else:
        signature, margin = "structured", (std - 15) / 40.0

    if significant <= 1:
        score = 0
    elif levels <= 2:
        score = 1
    elif std < 25:
        score = 2
    else:
        score = 3
    return signature, score, _mass(margin)


def _choice(key, mass, question):
    criteria = list(question.get("criteria") or {key: "?"})
    rest = (1.0 - mass) / max(1, len(criteria) - 1)
    return {"type": "choice", "choice": key,
            "probabilities": {k: (mass if k == key else round(rest, 4))
                              for k in criteria},
            "answer_confidence": mass}


def _score(value, mass, question):
    legend = {str(i): text for i, text in enumerate(question.get("criteria") or [])}
    distribution = [round((1.0 - mass) / max(1, len(legend) - 1), 4)] * len(legend)
    if 0 <= value < len(distribution):
        distribution[value] = mass
    return {"type": "score", "score": value, "legend": legend,
            "probabilities": distribution, "answer_confidence": mass}


def _noul(value):
    return {"type": "noul", "noul": value}


def _stub_answers(body):
    """One answer per asked question, shaped the way each type is answered."""
    questions = body.get("questions") or {}
    state = body.get("state") or {}
    measurements = state.get("measurements") or {}

    if "slop_signature" in questions:
        signature, score, mass = _signature_and_score(measurements)
        return {
            "has_structure": _noul(0.9 if score >= 2 else 0.15),
            "dominant_field": _noul(
                0.9 if measurements.get("slop_background_fraction", 0) >= 0.5 else 0.15),
            "structure_score": _score(score, mass, questions["structure_score"]),
            "slop_signature": _choice(signature, mass, questions["slop_signature"]),
            # The one question this vocabulary cannot ask: no pixels here, so
            # the answer is only ever reported when a captioner supplied the
            # picture's description. The stub answers it either way; the FOLD
            # is what decides whether it counts as evidence.
            "prompt_adherence": _noul(0.8),
        }

    if "metaphor_occurrence" in questions:
        prompt = (state.get("prompt") or "").lower()
        metaphorical = " like " in prompt or " as " in prompt
        return {
            "metaphor_occurrence": _choice(
                "metaphorical_meme" if metaphorical else "literal_meme",
                0.85, questions["metaphor_occurrence"]),
            "metaphor_category": _choice("text_dominant", 0.75,
                                         questions["metaphor_category"]),
            "source_modality": _choice("text_dominant", 0.75,
                                       questions["source_modality"]),
            "target_modality": _choice("image_dominant", 0.75,
                                       questions["target_modality"]),
            "sentiment": _choice("sorrow", 0.8, questions["sentiment"]),
            "intention": _choice("expressive", 0.8, questions["intention"]),
            # Deliberately under the floor: the fold must surface it rather
            # than let a plausible-looking label read as settled.
            "offensiveness": _choice("slightly_offensive", 0.5,
                                     questions["offensiveness"]),
            "evidence_is_actionable": _noul(0.8),
        }

    raise AssertionError("the stub was asked a vocabulary it does not stand in for")


@pytest.fixture()
def stub_server():
    """A loopback decision service; the only network any test here touches."""
    _DecisionStub.requests = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), _DecisionStub)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield "http://127.0.0.1:%d/v1/systemone" % server.server_address[1]
    finally:
        server.shutdown()
        server.server_close()


def annotate_artifact(tmp_path, artifact, endpoint, *, profile="generation-slop"):
    """Run the real annotator over one artifact and read the sidecar it wrote."""
    path = tmp_path / f"{artifact['generation']['raster'].replace('.png', '')}.artifact.json"
    path.write_text(json.dumps(artifact))
    out = tmp_path / f"{path.stem}.jev.json"
    code = jev.main([str(path), "--profile", profile, "--output", str(out),
                     "--endpoint", endpoint, "--api-key", "fixture-token"])
    assert code == 0, "the annotator refused the artifact"
    return json.loads(out.read_text())


# --------------------------------------------------------------------------
# 1. the fixture batch is the studio's run-job output shape
# --------------------------------------------------------------------------

def test_the_fixture_batch_is_in_the_studio_run_job_output_shape():
    """The shape a loop reads, pinned so a fixture cannot quietly become a
    different document and still be walked through the loop."""
    for entry, artifact in batch_artifacts():
        assert set(artifact) == {"prompt", "topic", "settings", "generation",
                                 "measurements", "image"}, entry["stem"]
        assert artifact["prompt"].strip(), "a run-job output carries its prompt"
        assert set(artifact["settings"]) >= {
            "seed", "steps", "guidance", "model", "width", "height"}
        assert set(artifact["generation"]) >= {"model", "raster"}
        assert artifact["image"]["file"] == f"{entry['stem']}.png"
        # The measurements are the shipped metric names, from the shipped code.
        assert set(artifact["measurements"]) == set(
            slop_cannon.measure_raster(png_bytes(_flat_rows())))


def test_the_batch_measurements_come_from_the_shipped_measurement_code():
    """Not hand-typed numbers: the batch is measured by `measure_raster`, so
    the loop runs the same decoder and the same definitions a real run does.
    Two artifacts pin the extremes the rest of the batch is built between."""
    blank = make_artifact("blank-frame", "x", "klein-4b", 4242, _flat_rows())
    poster = make_artifact("colour-blocks", "x", "klein-4b", 4242, _poster_rows())
    assert blank["measurements"]["slop_distinct_colors"] == 1
    assert blank["measurements"]["slop_background_fraction"] == 1.0
    assert blank["measurements"]["slop_edge_density"] == 0.0
    assert poster["measurements"]["slop_distinct_colors"] == 4
    assert poster["measurements"]["slop_edge_density"] > 0.0


# --------------------------------------------------------------------------
# 2. the loop over the batch
# --------------------------------------------------------------------------

def test_the_slop_loop_buckets_every_artifact_in_the_batch(tmp_path, stub_server):
    """The loop, end to end, per artifact: run-job output -> annotator ->
    sidecar -> bucket() verdict the loop acts on."""
    verdicts = {}
    for entry, artifact in batch_artifacts():
        sidecar = annotate_artifact(tmp_path, artifact, stub_server)
        assert sidecar["profile"] == "generation-slop"
        assert sidecar["status"] == "ok"
        verdict, why = slop_cannon.bucket(sidecar)
        verdicts[entry["stem"]] = (verdict, why)

        # The answers the verdict was reached from, asserted beside it: a
        # fixture that drifts into a different case is visible as a wrong
        # signature rather than as a mysterious verdict.
        answers = sidecar["answers"]
        assert answers["slop_signature"]["choice"] == entry["signature"], entry["stem"]
        assert answers["structure_score"]["score"] == entry["score"], entry["stem"]
        assert entry["why"] in why, (entry["stem"], why)

    assert {stem: v for stem, (v, _) in verdicts.items()} == {
        entry["stem"]: entry["expect"] for entry in BATCH}


def test_the_disagreement_cases_escalate_rather_than_resolve(tmp_path, stub_server):
    """The property the whole design rests on.

    A slop signature beside a high structure score is not resolved by
    ordering the two rules -- it is handed on, and the converse (a
    STRUCTURED signature beside a zero score) is handed on the same way.
    Four artifacts in the batch land on it, from the two opposite
    directions, and one lands below the floor; all five must escalate,
    each for its own stated reason.
    """
    by_stem = {entry["stem"]: entry for entry in BATCH}
    outcomes = {}
    for entry, artifact in batch_artifacts():
        if entry["stem"] not in ("pale-wash", "noise-over-regions",
                                 "near-threshold", "wide-gradient"):
            continue
        sidecar = annotate_artifact(tmp_path, artifact, stub_server)
        verdict, why = slop_cannon.bucket(sidecar)
        outcomes[entry["stem"]] = (verdict, why)

    for stem in ("pale-wash", "noise-over-regions", "near-threshold",
                 "wide-gradient"):
        verdict, why = outcomes[stem]
        assert verdict == "escalate", (stem, why)
        assert by_stem[stem]["why"] in why, (stem, why)

    # The two opposite directions of the same disagreement, and neither is
    # resolved into a keep or a drop by which check happens to run first:
    # a sloppy signature beside a high score, and a structured signature
    # beside a zero score.
    assert "washed_flat" in outcomes["pale-wash"][1]
    assert outcomes["pale-wash"][1].count("disagrees") == 1
    assert "uniform_noise" in outcomes["noise-over-regions"][1]
    assert "structured" in outcomes["wide-gradient"][1]
    assert outcomes["wide-gradient"][1].count("disagrees") == 1
    # And the below-floor case is escalated for the FLOOR, not for a
    # disagreement -- the two admissions are different and the reason says
    # which one this was.
    assert "floor" in outcomes["near-threshold"][1]
    assert "disagrees" not in outcomes["near-threshold"][1]


def test_the_structured_signature_beside_a_zero_score_escalates(tmp_path, stub_server):
    """The other disagreement direction, pinned on its own reason.

    The batch covers the sloppy-signature/high-score direction twice
    (pale-wash, noise-over-regions); this artifact is the converse the
    reviewer found unpinned: a frame whose wide tonal spread reads
    STRUCTURED while its score comes back 0, because no single colour
    covers 1% of the frame. bucket() must escalate it by name, with the
    reason it states -- deleting that branch and letting the structured
    signature fall through to "confident structure" would turn an
    unresolvable disagreement into a silent KEEP.
    """
    entry = by_stem_of("wide-gradient")
    sidecar = annotate_artifact(tmp_path, entry[1], stub_server)

    # The answers the escalation was reached from, asserted before the
    # verdict: the fixture's measurements, not a hand-typed pair.
    answers = sidecar["answers"]
    assert answers["slop_signature"]["choice"] == "structured"
    assert answers["structure_score"]["score"] == 0
    assert "slop_signature" not in sidecar["verdict"]["low_confidence"], (
        "the escalation is the disagreement, not the confidence floor")

    verdict, why = slop_cannon.bucket(sidecar)
    assert verdict == "escalate"
    assert why == "signature structured disagrees with score 0", (
        "the escalation must state which disagreement this was")


def test_a_captioned_artifact_makes_prompt_adherence_evidenced(tmp_path, stub_server):
    """The captioner seam, inside the loop.

    The one question this vocabulary cannot ask from numbers becomes
    answerable when a captioner's description travels with the artifact -- and
    the recorded row carries the number instead of None.
    """
    artifact = make_artifact(CAPTIONED["stem"], CAPTIONED["prompt"], "klein-4b",
                             4243, CAPTIONED["rows"](),
                             caption=CAPTIONED["caption"],
                             caption_model=CAPTIONED["caption_model"])
    sidecar = annotate_artifact(tmp_path, artifact, stub_server)

    assert sidecar["state"]["evidence"]["image_visible"] is True
    assert "prompt_adherence" not in sidecar["verdict"]["unevidenced"]
    row = slop_cannon.row_from(sidecar)
    assert row["p_prompt_adherence"] == 0.8, (
        "a captioned artifact records the adherence answer as a number")
    assert row["unevidenced"] == []
    # And it does not change the keep/drop decision, which never needed pixels.
    assert slop_cannon.bucket(sidecar)[0] == "keep"


def test_an_uncaptioned_artifact_keeps_prompt_adherence_unevidenced(tmp_path, stub_server):
    """The other half of the seam: without a caption the answer is reported as
    unevidenced and the row records None, never a number a reader could
    mistake for a measurement."""
    entry, artifact = batch_artifacts()[1]  # colour-blocks
    sidecar = annotate_artifact(tmp_path, artifact, stub_server)

    assert sidecar["state"]["evidence"]["image_visible"] is False
    assert sidecar["verdict"]["unevidenced"] == ["prompt_adherence"]
    row = slop_cannon.row_from(sidecar)
    assert row["p_prompt_adherence"] is None
    assert row["unevidenced"] == ["prompt_adherence"]


# --- the default question set choosing the next action ---------------------

# Answers as a confident service gives them for one printability call. The
# masses are above the floor so the ladder's refusal gates do not fire.
#
# WHY FIXTURE ANSWERS HERE AND NOT STUB-DERIVED ONES, as the slop leg does:
# the printability vocabulary's projector is `manifest` -- it reads a
# chopshop preflight manifest (passed / summary / findings / stats), not a
# raster and not the slop_* measurements a stub can do arithmetic on. The
# answers are a judgement about the projected manifest that no shipped code
# in this repo computes, so there is nothing real to derive them from and
# inventing stub rules for them would put the interesting half of the leg
# (the fold, the ladder, the remediation table) behind a second fiction. What
# IS real here is everything downstream of the answers, and that is what the
# tests exercise.
PRINTABILITY_ANSWERS = {
    "failure_mode": {"type": "choice", "choice": "geometry_overload",
                     "confidence": 0.91},
    "print_route": {"type": "choice", "choice": "screen_spot_multi",
                    "confidence": 0.88},
    "tonal_structure": {"type": "score", "score": 2.0, "confidence": 0.82,
                        "legend": {"0": "Broken", "1": "Flat", "2": "Retained",
                                   "3": "Engraving-grade"},
                        "probabilities": {"0": 0.05, "1": 0.08, "2": 0.82, "3": 0.05}},
    "evidence_is_actionable": {"type": "noul", "noul": 0.9},
}

NODE_FINDING = {"rule": "NODE_COUNT", "severity": "advisory",
                "detail": "Path #1 (no id) has 969 nodes, above the limit of 500"}
GEOMETRY_STATS = {"path_nodes_max": 969, "path_nodes_total": 180000,
                  "paths_over_node_limit": 2}
SCREEN_FINDING = {"rule": "COLOR_COUNT_RENDERED", "severity": "hard",
                  "detail": "677 rendered colours against a budget of 6"}
SCREEN_STATS = {"rendered_distinct_colors": 677, "rendered_screens": 8}


def _printability_verdict(answers=None):
    """The verdict the default set produces, by the shipped fold."""
    return jev.compose_verdict(answers or PRINTABILITY_ANSWERS)


def test_a_printability_verdict_selects_the_tracer_free_rung_and_says_why():
    """The default question set's answers choose the next action.

    `failure_mode` names the mode; `evidence_is_actionable` says the
    measurements can be acted on; the ladder then picks the CHEAPEST grounded
    rung, which for geometry_overload is a post-process on the SVG that
    already exists -- no tracer re-run. The plan records why: the rung it
    selected, the rule that grounded it, and the metrics progress will be
    measured on.
    """
    table = rem.load_table(rem.DEFAULT_TABLE)
    verdict = _printability_verdict()
    assert verdict["headline"] == "geometry_overload"
    assert verdict["evidence_actionable"] is True
    assert verdict["low_confidence"] == [], (
        "a confident call must not be gated into a refusal by the floor")

    plan = rem.decide(verdict=verdict, findings=[NODE_FINDING], stats=GEOMETRY_STATS,
                      table=table, chopshop_svg=ROOT)

    assert plan["status"] == rem.TRACE
    assert plan["remedy"]["id"] == "geometry_overload/tolerance"
    assert plan["remedy"]["kind"] == "node_reduce"
    assert plan["remedy"]["needs_tracer"] is False, (
        "the tracer-free rung comes first: a post-process, not a retrace")
    assert plan["grounded_in"] == ["NODE_COUNT"]
    assert plan["invocation"] is not None
    assert "node_reduce.py" in " ".join(plan["invocation"])
    assert plan["sweep"] is None, "a post-process is not a sweep"
    # The ladder trace is the audit of the choice, and the metrics say what
    # "progress" will mean for this mode.
    assert plan["ladder"] == [{"remedy_id": "geometry_overload/tolerance",
                               "outcome": "selected"}]
    assert "path_nodes_max" in plan["metrics"]["names"]


def test_a_screen_explosion_verdict_prefers_the_tracer_free_snap():
    """The same default set, a different answer, a different tracer-free rung.

    The vocabulary is what varies; the policy (cheapest grounded rung first,
    tracer re-run only as an escalation) is what the loop binds to.
    """
    table = rem.load_table(rem.DEFAULT_TABLE)
    verdict = _printability_verdict({
        **PRINTABILITY_ANSWERS,
        "failure_mode": {"type": "choice", "choice": "screen_explosion",
                         "confidence": 0.9},
    })
    plan = rem.decide(verdict=verdict, findings=[SCREEN_FINDING], stats=SCREEN_STATS,
                      table=table, chopshop_svg=ROOT)

    assert plan["status"] == rem.TRACE
    assert plan["remedy"]["id"] == "screen_explosion/force"
    assert plan["remedy"]["needs_tracer"] is False
    assert "--force" in plan["invocation"]
    # And the escalation behind it is a retrace, so the ordering is a real
    # ladder rather than a single remedy with a flag.
    ladder = rem.ladder_for(table, "screen_explosion")
    assert [e["needs_tracer"] for e in ladder] == [False, True]


def test_the_ladder_refuses_rather_than_acting_on_a_guess():
    """The other half of "the answers guide the loop": when they are a guess,
    the loop STOPS.

    Both refusals are driven by the default question set's own answers --
    `failure_mode` under the floor, and `evidence_is_actionable` false -- not
    by a policy someone typed beside the ladder.
    """
    table = rem.load_table(rem.DEFAULT_TABLE)

    unsure = _printability_verdict({
        **PRINTABILITY_ANSWERS,
        "failure_mode": {"type": "choice", "choice": "geometry_overload",
                         "confidence": 0.4},
    })
    assert unsure["low_confidence"] == ["failure_mode"]
    refused = rem.decide(verdict=unsure, findings=[NODE_FINDING],
                         stats=GEOMETRY_STATS, table=table, chopshop_svg=ROOT)
    assert refused["status"] == "refused_low_confidence"
    assert refused["remedy"] is None

    unevidenced = _printability_verdict({
        **PRINTABILITY_ANSWERS,
        "evidence_is_actionable": {"type": "noul", "noul": 0.2},
    })
    assert unevidenced["evidence_actionable"] is False
    refused = rem.decide(verdict=unevidenced, findings=[NODE_FINDING],
                         stats=GEOMETRY_STATS, table=table, chopshop_svg=ROOT)
    assert refused["status"] == "refused_evidence"
    assert refused["remedy"] is None


TRANSLATION_ARTIFACT = {
    "prompt": "a storm cloud shaped like a clenched fist above a sleeping city",
    "topic": "style-moody-atmospheric",
    "settings": {"seed": 777001, "steps": 9, "guidance": 0.0,
                 "model": "sdxl-turbo", "width": SIZE, "height": SIZE},
    "generation": {"model": "sdxl-turbo", "job": JOB, "raster": "storm-fist.png"},
    "measurements": {"slop_distinct_colors": 4311, "slop_edge_density": 0.21},
    "image": {"file": "storm-fist.png"},
}

# The three questions this profile cannot answer without pixels. Their absence
# from the recorded values is the profile being honest, not a gap in it.
IMAGE_DEPENDENT = ("metaphor_category", "source_modality", "target_modality")


def test_a_dataset_translation_artifact_records_its_annotation_shape(tmp_path, stub_server):
    """The recorded annotation, and what it refuses to claim.

    Most of MET-Meme's scheme is about an image, and this annotator is handed
    text and numbers. So the image-dependent questions come back unevidenced
    BY CONSTRUCTION, the answers that do not need pixels are recorded, and an
    answer under the floor is surfaced rather than left to read as settled.
    """
    sidecar = annotate_artifact(tmp_path, TRANSLATION_ARTIFACT, stub_server,
                                profile="dataset-translation")

    assert sidecar["schema"] == jev.ANNOTATION_SCHEMA
    assert sidecar["profile"] == "dataset-translation", (
        "a sidecar is never ambiguous about which vocabulary answered it")
    assert sidecar["status"] == "ok"
    assert sidecar["state"]["evidence"]["image_visible"] is False

    verdict = sidecar["verdict"]
    assert verdict["unevidenced"] == list(IMAGE_DEPENDENT)
    for name in IMAGE_DEPENDENT:
        assert name not in verdict["values"], (
            "an unevidenced answer must not be reported as a value")
    assert verdict["values"]["metaphor_occurrence"] == "metaphorical_meme"
    assert verdict["values"]["evidence_is_actionable"] is True
    # Surfaced, not dropped: the label is recorded AND named as under the floor.
    assert verdict["values"]["offensiveness"] == "slightly_offensive"
    assert verdict["low_confidence"] == ["offensiveness"]
    # The raw mass travels beside it, so a caller can pick its own floor.
    assert verdict["confidence"]["offensiveness"] == 0.5
    assert verdict["confidence_floor_is_advisory"] is True


def test_a_caption_makes_the_translation_profile_answer_its_image_questions(
        tmp_path, stub_server):
    """The seam, on the translation profile: with a caption the same three
    questions stop being unevidenced and are recorded as values."""
    artifact = dict(TRANSLATION_ARTIFACT,
                    image={"file": "storm-fist.png",
                           "caption": "a dark storm cloud curled into a fist "
                                      "above a city skyline at night",
                           "caption_model": "LiquidAI/LFM2.5-VL-450M"})
    sidecar = annotate_artifact(tmp_path, artifact, stub_server,
                                profile="dataset-translation")

    assert sidecar["state"]["evidence"]["image_visible"] is True
    assert sidecar["verdict"]["unevidenced"] == []
    for name in IMAGE_DEPENDENT:
        assert name in sidecar["verdict"]["values"], name


# --------------------------------------------------------------------------
# 3. the drift pin on the default question set's contract
# --------------------------------------------------------------------------
#
# The keys, types and thresholds of the DEFAULT template are the interface an
# automated loop binds to: the studio's JevConf, the remediation table and
# this file's own ladder assertions all read them. A silent edit to QUESTIONS
# must fail a test rather than a batch run, so the contract is written out
# here in full and compared. The legend text is pinned verbatim on purpose --
# a wording edit is a contract change to the service that echoes it back.

DEFAULT_QUESTION_CONTRACT = {
    "profile": "printability",
    "projector": "manifest",
    "fold": "printability",
    "confidence_floor": jev.DEFAULT_CONFIDENCE_FLOOR,
    "questions": {
        "failure_mode": {
            "type": "choice",
            "choice_keys": ["screen_explosion", "continuous_tone", "geometry_overload",
                            "palette_mismatch", "render_or_tool_failure",
                            "no_hard_failure", "unclear"],
        },
        "print_route": {
            "type": "choice",
            "choice_keys": ["screen_spot_low", "screen_spot_multi", "process_halftone",
                            "dtg_or_dtf", "unsuitable", "unclear"],
        },
        "tonal_structure": {
            "type": "score",
            "legend": [
                "Broken: tone collapsed into noise or non-printing blends.",
                "Flat: tonal range reduced to a few hard steps with visible banding.",
                "Retained: a coherent tonal read survives in flat colours.",
                "Engraving-grade: dense, ordered tonal structure suitable as a "
                "deliberate screen/engraving look.",
            ],
        },
        "evidence_is_actionable": {
            "type": "noul",
            "choice_keys": ["true", "false"],
        },
    },
}

# The verdict field each question's answer reaches, and which decision paths
# read it. This is the other half of the contract a loop binds to: the studio
# reads these field NAMES, and the ladder branches on two of them.
PRINTABILITY_VERDICT_FIELD = {
    "failure_mode": ("headline",),
    "print_route": ("print_route",),
    "tonal_structure": ("tonal_score", "tonal_label"),
    "evidence_is_actionable": ("evidence_actionable",),
}


def test_the_default_question_set_contract_is_pinned():
    """The drift pin. `PROFILES["printability"]["questions"]` IS the module's
    `QUESTIONS` object, and this is what every automated caller binds to."""
    default = jev.profile(None)
    questions = default["questions"]

    assert default["questions"] is jev.QUESTIONS, (
        "the default template must BE the module's QUESTIONS object, not a copy")
    assert default["id"] == DEFAULT_QUESTION_CONTRACT["profile"]
    assert default["projector"] == DEFAULT_QUESTION_CONTRACT["projector"]
    assert default["fold"] == DEFAULT_QUESTION_CONTRACT["fold"]
    assert jev.DEFAULT_PROFILE == "printability"

    expected = DEFAULT_QUESTION_CONTRACT["questions"]
    assert list(questions) == list(expected), (
        "the question keys, in order, are the contract: %s" % list(questions))

    for name, want in expected.items():
        question = questions[name]
        assert question["type"] == want["type"], name
        assert question.get("instructions"), f"{name} must state what it asks"
        if want["type"] == "choice":
            assert list(question["criteria"]) == want["choice_keys"], (
                f"{name}: the choice keys are the interface -- "
                f"{list(question['criteria'])}")
        elif want["type"] == "score":
            assert question["criteria"] == want["legend"], (
                f"{name}: the score legend is echoed back by the service and "
                f"rendered by every caller")
        elif want["type"] == "noul":
            assert list(question["criteria"]) == want["choice_keys"], name

    assert jev.DEFAULT_CONFIDENCE_FLOOR == DEFAULT_QUESTION_CONTRACT["confidence_floor"]
    assert jev.DEFAULT_CONFIDENCE_FLOOR == 0.6


def test_the_default_verdict_field_names_are_pinned():
    """Which verdict field each answer reaches. The studio reads these names,
    and the ladder branches on two of them, so a rename is a cross-repo break
    that must fail here first."""
    verdict = _printability_verdict()
    for question, fields in PRINTABILITY_VERDICT_FIELD.items():
        for field in fields:
            assert field in verdict, f"{question} no longer reaches {field}"
    assert verdict["headline"] == "geometry_overload"
    assert verdict["print_route"] == "screen_spot_multi"
    assert verdict["tonal_score"] == 2.0
    assert verdict["tonal_label"] == "Retained"
    assert verdict["evidence_actionable"] is True


# --------------------------------------------------------------------------
# 4. orphan answers: every shipped question key declares its reader
# --------------------------------------------------------------------------
#
# A question whose answer no decision path reads cannot guide anything. The
# classification below is the audit: which shipped key is read by which path.
# A NEW question must be added to it, so a vocabulary cannot grow a question
# that silently guides nothing.

# The bucket rule reads these keys (plus the low_confidence/unevidenced lists,
# which carry question ids).
BUCKET_READS = ("slop_signature", "structure_score")
# The bracket's row projection reads these, and feeds the between/within
# spread report -- the "does this vocabulary separate models" decision.
ROW_FROM_READS = ("slop_signature", "structure_score", "has_structure",
                  "dominant_field", "prompt_adherence")
# The remediation ladder branches on the printability verdict's headline and
# evidence_actionable, i.e. on these two answers, plus the low_confidence list.
LADDER_READS = ("failure_mode", "evidence_is_actionable")
# The printability fold's domain contract reads all four, by the field names
# above; the generic fold reads every key of its own question set.


def _readers_for(profile_id, question_key):
    """Which decision paths read this answer, named.

    The three paths the issue names: the bucket rule, a fold verdict, and the
    remediation ladder. Every shipped key reaches at least a fold verdict --
    that is what makes none of them an orphan -- so the interesting half of
    the audit is which keys reach a *decision* and which only reach a
    *record*.
    """
    readers = []
    if profile_id == "printability":
        readers.append("printability fold -> verdict.%s"
                       % "/".join(PRINTABILITY_VERDICT_FIELD[question_key]))
        if question_key in LADDER_READS:
            readers.append("jev_remediate ladder")
    else:
        # The generic fold records every answer of its own question set, so a
        # template's questions always reach a verdict.
        readers.append("generic fold -> verdict.values")
        if question_key in BUCKET_READS:
            readers.append("slop_cannon.bucket")
        if question_key in ROW_FROM_READS:
            readers.append("slop_cannon.row_from -> spread report")
    return readers


def test_every_shipped_question_key_declares_a_reader():
    """No shipped question may be unclassified.

    A new key in any profile fails here until someone says which decision
    path reads it -- which is the moment the question is either wired in or
    dropped. The classification is asserted per profile rather than guessed,
    because the three profiles hand their answers to different consumers.
    """
    expected_decisions = {
        "printability": {
            "failure_mode": {"printability fold -> verdict.headline",
                             "jev_remediate ladder"},
            "print_route": {"printability fold -> verdict.print_route"},
            "tonal_structure": {"printability fold -> verdict.tonal_score/tonal_label"},
            "evidence_is_actionable": {"printability fold -> verdict.evidence_actionable",
                                       "jev_remediate ladder"},
        },
        "generation-slop": {
            "slop_signature": {"generic fold -> verdict.values",
                               "slop_cannon.bucket", "slop_cannon.row_from -> spread report"},
            "structure_score": {"generic fold -> verdict.values",
                                "slop_cannon.bucket", "slop_cannon.row_from -> spread report"},
            "has_structure": {"generic fold -> verdict.values",
                              "slop_cannon.row_from -> spread report"},
            "dominant_field": {"generic fold -> verdict.values",
                               "slop_cannon.row_from -> spread report"},
            "prompt_adherence": {"generic fold -> verdict.values",
                                 "slop_cannon.row_from -> spread report"},
        },
        # The translation profile's answers are recorded annotations, not
        # loop decisions -- which is what its `why` says it is. Every key
        # still reaches the fold's verdict, so none is an orphan.
        "dataset-translation": {
            key: {"generic fold -> verdict.values"} for key in jev.MEME_QUESTIONS
        },
    }

    for profile_id, profile in jev.PROFILES.items():
        assert profile_id in expected_decisions, (
            f"{profile_id} has no reader classification; add one")
        classified = expected_decisions[profile_id]
        for question_key in profile["questions"]:
            readers = _readers_for(profile_id, question_key)
            assert readers, (
                f"{profile_id}/{question_key}: no decision path reads this answer")
            assert set(readers) == classified.get(question_key), (
                f"{profile_id}/{question_key}: readers drifted -- "
                f"{sorted(set(readers) ^ classified.get(question_key, set()))}")


def test_the_only_keys_no_loop_branches_on_are_the_two_surfaced_fields():
    """The orphan report, as a test.

    Every shipped question key IS read by at least one decision path (a fold
    verdict reads all of them), so there are no orphans by the issue's
    definition. The finding worth recording is narrower, and is pinned here
    so it cannot change unnoticed:

      * within THIS repo, the only printability answers any code BRANCHES on
        are `failure_mode` and `evidence_is_actionable`. `print_route` and
        `tonal_structure` are SURFACED -- published under the verdict field
        names the studio reads, and named in the remediation table's
        operator-facing next_step for `continuous_tone` -- but no loop in
        this repo decides from them. They are not orphans and they are not
        dead: the consumer is cross-repo and by name, which is exactly why
        the field names above are pinned rather than left to be inferred.
      * the translation profile's eight answers reach a verdict and nothing
        else. They are dataset annotations, and the profile says so; there is
        no bucket or ladder for a meme label, and inventing one would be
        this repo deciding something it must not.
      * `prompt_adherence` is the one answered question whose VALUE no
        decision uses: it is recorded as None whenever it is unevidenced,
        which is the honest state of a question nothing can see pixels for.
    """
    branched = {key for key in jev.QUESTIONS
                if "jev_remediate ladder" in _readers_for("printability", key)}
    assert branched == {"failure_mode", "evidence_is_actionable"}

    surfaced = set(jev.QUESTIONS) - branched
    assert surfaced == {"print_route", "tonal_structure"}
    for key in surfaced:
        verdict = _printability_verdict()
        for field in PRINTABILITY_VERDICT_FIELD[key]:
            assert verdict[field] is not None, (
                f"{key} is neither branched on nor surfaced: {field} is empty")

    # The slop vocabulary is fully wired into a decision: every one of its
    # five keys reaches the bucket or the bracket's comparison.
    for key in jev.SLOP_QUESTIONS:
        assert key in BUCKET_READS or key in ROW_FROM_READS, key

    # And the translation profile's answers are recorded, never decided on.
    for key in jev.MEME_QUESTIONS:
        assert _readers_for("dataset-translation", key) == [
            "generic fold -> verdict.values"], key


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
