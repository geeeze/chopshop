#!/usr/bin/env python3
"""Annotate a chopshop preflight manifest with a Jev decision sidecar.

OPTIONAL ADD-ON.  This is not part of the deterministic pipeline and it is
never run by default: it calls an external decision service that needs an API
key, so it is opt-in only.  `pipeline.sh`, `compare_candidates.py`, and the
other stages do not invoke it.

It is deliberately additive: it does not modify the manifest produced by
preflight.py and it does not choose a winning candidate.  It asks a TEMPLATE's
worth of narrow, advisory questions, folds the answers into a thresholded
verdict, and writes a separate `<stem>.jev.json` sidecar.

QUESTION-SET TEMPLATES.  The default is `printability` -- four questions about
the printability signature of a preflight manifest, which is what this annotator
has always asked and what every existing caller gets.  `--profile
dataset-translation` instead asks MET-Meme's meme-annotation vocabulary about a
generation artifact (a prompt plus the measurements of what it produced).  A
template is DATA: it names its projector, its questions and its fold, so a third
vocabulary is a dict and not a second annotator.  `--list-profiles` prints them.

The wire contract is {model, state, questions} and NOTHING else: an extra
envelope key was measured to turn a 200 into a 400, so what this repo knows about
a request is written to the SIDECAR rather than sent. The answer types the service
implements are choice/score/noul — a free-text type is not among them, which is
why MET-Meme's two SHAPE-constrained `*_domain` fields are not asked (see
UNSUPPORTED_QUESTION_TYPES for the measurement).

Usage:
    python3 scripts/jev_annotate.py 05_final/artwork.manifest.json --dry-run
    python3 scripts/jev_annotate.py manifest.json --optional   # skip w/o a key
    JEV_API_KEY=... python3 scripts/jev_annotate.py manifest.json
    python3 scripts/jev_annotate.py artifact.json --profile dataset-translation --dry-run

The live call reads the bearer key from ``JEV_API_KEY``, then the historical
``TYPESAFE_API_KEY``, then ``LAYA_API_KEY`` -- the local service's own name,
accepted so the alternate backend needs no renaming -- and finally from
``~/.hermes/.env`` and the repo ``.env`` when no variable is exported. Only the
Jev-relevant keys are read from those files; unrelated secrets in them are
never touched. The API request contains only the compact
projection created by project_manifest(); it never sends the full manifest,
and long colour lists are collapsed to a gist before they leave the machine.

``JEV_ENDPOINT`` is the whole of the backend choice, so a locally hosted
decision service that speaks the same wire protocol stands in for the hosted
one with no code change — see ``docs/local-decision-service.md``. Nothing in
this file knows which backend answered.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_ENDPOINT = "https://api.typesafe.ai/v1/systemone"
DEFAULT_MODEL = "jev-latest"
ANNOTATION_SCHEMA = "chopshop-jev-annotation-0.4"
DEFAULT_CONFIDENCE_FLOOR = 0.6

# chopshop-jev#1 — the floor is ADVISORY, and these are the numbers that say so.
#
# The problem this records: an uncalibrated floor does not fail. It silently
# converts a measurement into a constant. On the `generation-slop` vocabulary the
# local `laya-serve` backend's probability mass lands between roughly 0.33 and
# 0.60 against this 0.6 default, so all 12 rasters of the first bracket came back
# `low_confidence` and the keep/escalate loop escalated every one of them — a
# result that says something about the floor and nothing about the rasters. The
# `printability` vocabulary shows the same shape at 0.23-0.61 -- though note it
# STRADDLES the 0.6 floor, where generation-slop's whole range sits under it. So
# the floor is not a property of one question set; it depends on the VOCABULARY
# and the BACKEND, and a single global constant is a number with no evidence
# behind it. `recorded_confidence_evidence` reports that difference per row
# rather than rounding it away, because a table that said "the floor is above
# everything" would be false for the second vocabulary.
#
# The position this repo takes, which is the second option the issue offers: the
# floor does not gate, it ANNOTATES. `confidence` (the raw mass, every time) is
# reported beside the gated verdict for every answer, so a caller sees the numbers
# and can apply whatever floor their backend and vocabulary justify. The default
# stays 0.6 and the `low_confidence` list still exists, because dropping it would
# break every caller that reads it — but it no longer claims to be a verdict.
# The knob the README promised now exists: `--confidence-floor` /
# `JEV_CONFIDENCE_FLOOR` (chopshop-jev#6), so a caller whose own measurement
# justifies 0.4 sets 0.4 instead of reading "configurable" and finding a
# constant. It still only moves the NOTE — `confidence` is written either way.
#
# These are the observed ranges, written down with the vocabulary and the backend
# they were measured on. A range is evidence; a constant is an assumption.
OBSERVED_CONFIDENCE_RANGES = {
    # vocabulary -> backend -> (low, high) of the mass actually seen.
    ("generation-slop", "laya-serve"): (0.33, 0.60),
    ("printability", "laya-serve"): (0.23, 0.61),
}


def recorded_confidence_evidence(vocabulary: str | None) -> dict[str, Any]:
    """What mass has actually been seen for `vocabulary`, per backend.

    chopshop-jev#1 asks for "the value and the evidence for it recorded rather
    than assumed". This is the recorded half: the sidecar carries it beside the
    floor, so a reader can see that the floor sits at or above the top of the
    observed range and is therefore gating everything, not selecting anything.

    Keyed by BACKEND as well as vocabulary, because the same vocabulary gives
    different masses on a different decision service and a merged number would be
    exactly the kind of constant this is arguing against. ``JEV_ENDPOINT`` is the
    whole of the backend choice and this file deliberately does not know which
    one answered, so every recorded backend is listed rather than one being
    picked -- a caller that knows its own backend can pick its own row.

    ``None``/empty when nothing has been measured for that vocabulary, which is
    the honest answer for a new template: no evidence is not a passing grade.
    """
    rows = {
        backend: {
            "low": low,
            "high": high,
            # Whether the default floor COVERS this backend's whole observed
            # range -- i.e. sits at or above the top of it, so every mass seen
            # was gated and `low_confidence` selected nothing.
            #
            # Inclusive on purpose. The gate is a strict `<`, and the recorded
            # top for generation-slop is 0.60 against a 0.60 floor: every one of
            # the 12 rasters in the first bracket did come back `low_confidence`,
            # so the empirical claim is that the floor covers the range, not
            # that it sits above it. The recorded figures are rounded to two
            # decimals and the boundary case belongs to the covering side.
            "floor_covers_whole_range": high <= DEFAULT_CONFIDENCE_FLOOR,
        }
        for (vocab, backend), (low, high) in OBSERVED_CONFIDENCE_RANGES.items()
        if vocab == vocabulary
    }
    if not rows:
        return {}
    straddle = sorted(
        backend for backend, row in rows.items()
        if row["low"] < DEFAULT_CONFIDENCE_FLOOR < row["high"]
    )
    return {
        "vocabulary": vocabulary,
        "by_backend": rows,
        # True when the floor covers EVERY recorded backend's whole range -- i.e.
        # on that vocabulary `low_confidence` gated everything and selected
        # nothing. False for printability, correctly, because its range runs to
        # 0.61 and something genuinely clears the floor there.
        "all_observed_below_default_floor": all(
            row["floor_covers_whole_range"] for row in rows.values()
        ),
        # The backends whose range crosses the floor, named. A caller on one of
        # these cannot read `low_confidence` as a filter at all.
        "ranges_straddling_default_floor": straddle,
        "note": (
            "observed probability mass for this vocabulary, per backend; the "
            "default floor is %s. `confidence` carries the raw masses and "
            "`confidence_floor` is advisory -- a caller picks its own floor from "
            "these numbers. See DEFAULT_CONFIDENCE_FLOOR."
            % DEFAULT_CONFIDENCE_FLOOR
        ),
    }

# The HTTP call's own budget, distinct from the caller's subprocess budget (the
# runner allows 180s but does not pass --timeout, so this was the binding
# constraint). 20s is right for the hosted service and too tight for a local one
# whose checkpoint is not resident yet: the first request that names a
# not-yet-loaded checkpoint spends tens of seconds loading it and then fails as
# a timeout, which reaches the operator as "Jev call failed". Overridable so a
# local deployment can widen it without touching code.
DEFAULT_HTTP_TIMEOUT = 20.0

# Long runs of hex codes appear verbatim inside preflight finding details and
# inside declared_colors. They are meaningless to a decision and would blow the
# token budget, so they are collapsed before the state is sent.
_HEX = re.compile(r"#[0-9a-fA-F]{6}\b")
_DETAIL_LIMIT = 400
_NOTE_LIMIT = 400
_TOP_INKS_LIMIT = 12

# Env-var names the annotator resolves, in preference order. JEV_* matches the
# key the user stores in ~/.hermes/.env; TYPESAFE_* is the historical name kept
# for backward compatibility; LAYA_API_KEY is the LOCAL service's own name and
# is accepted as a first-class alternate (the runner validates it, so the
# annotator must be able to read it too -- a check that accepts a key the caller
# then cannot pass down is the bug 875687c fixed in slop_cannon).
_JEV_ENV_KEYS = (
    "JEV_API_KEY", "TYPESAFE_API_KEY", "LAYA_API_KEY",
    "JEV_ENDPOINT", "TYPESAFE_ENDPOINT",
    "JEV_MODEL", "TYPESAFE_MODEL",
    "JEV_HTTP_TIMEOUT", "TYPESAFE_HTTP_TIMEOUT",
    "JEV_CONFIDENCE_FLOOR", "TYPESAFE_CONFIDENCE_FLOOR",
)

DEFAULT_ENV_FILES = (
    Path.home() / ".hermes" / ".env",
    Path(__file__).resolve().parent.parent / ".env",
)


def _env_file_values(*paths: Path) -> dict[str, str]:
    """Extract ONLY the Jev-relevant keys from dotenv files.

    ``~/.hermes/.env`` holds unrelated secrets (other providers' keys); this
    reads only the keys named in ``_JEV_ENV_KEYS`` and never
    keeps the rest in memory, so an unrelated credential cannot leak into this
    process.
    """
    wanted = set(_JEV_ENV_KEYS)
    found: dict[str, str] = {}
    for path in paths:
        if not path.is_file():
            continue
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            if key in wanted:
                found[key] = value.strip().strip('"').strip("'")
    return found


def resolve_env(
    names: tuple[str, ...],
    default: str | None,
    file_values: dict[str, str] | None = None,
) -> str | None:
    """Resolve a setting from os.environ, then the dotenv files, then default."""
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    if file_values is None:
        file_values = _env_file_values(*DEFAULT_ENV_FILES)
    for name in names:
        if file_values.get(name):
            return file_values[name]
    return default


def _env_float(names: tuple[str, ...], default: float, file_values: dict[str, str]) -> float:
    """Resolve a numeric setting, refusing to die on a typo in a dotfile.

    A bad value warns and falls back rather than refusing to annotate: this runs
    inside a caller's subprocess, and a number that cannot be parsed is a
    configuration mistake, not a reason to report the decision service as down.
    """
    raw = resolve_env(names, None, file_values)
    if raw is None:
        return default
    try:
        return float(raw)
    except (TypeError, ValueError):
        print(f"warning: {'/'.join(names)} is not a number ({raw!r}); using {default}",
              file=sys.stderr)
        return default

# These are intentionally narrow, atomic questions. Each asks one bounded
# judgment; the surrounding code decides what to do with it. No question asks
# Jev to rank or select a candidate.
QUESTIONS: dict[str, dict[str, Any]] = {
    "failure_mode": {
        "type": "choice",
        "instructions": (
            "Based only on the supplied preflight measurements and finding "
            "details, which failure signature best describes this candidate?"
        ),
        "criteria": {
            "screen_explosion": "The rendered or declared artwork needs far more distinct colours or screens than the contract allows.",
            "continuous_tone": "A smooth tonal transition or photographic ramp was traced, which flat-colour printing cannot reproduce.",
            "geometry_overload": "Paths carry far more nodes than the limit, making the file slow to RIP and hard to hand-edit.",
            "palette_mismatch": "Declared colours fall outside the contract palette.",
            "render_or_tool_failure": "The proof or PDF could not be produced, or a tool was missing.",
            "no_hard_failure": "No hard finding is present in the supplied measurements.",
            "unclear": "The supplied measurements do not identify one clear failure signature.",
        },
    },
    "print_route": {
        "type": "choice",
        "instructions": "Which production route best fits this artwork as measured?",
        "criteria": {
            "screen_spot_low": "Spot-colour screen printing within the contract colour budget.",
            "screen_spot_multi": "Spot-colour screen printing, but above the contract budget and needing more screens or a redesign.",
            "process_halftone": "Four-colour process or simulated-process printing is required because tone must be reproduced.",
            "dtg_or_dtf": "Direct-to-garment or direct-to-film fits better than screen printing for this artwork.",
            "unsuitable": "No route reproduces this artwork as measured without rework.",
            "unclear": "The measurements do not determine a production route.",
        },
    },
    "tonal_structure": {
        "type": "score",
        "instructions": (
            "How faithfully did the trace preserve the source's tonal structure, "
            "judging only from the measured colour count, ramp and coverage numbers?"
        ),
        "criteria": [
            "Broken: tone collapsed into noise or non-printing blends.",
            "Flat: tonal range reduced to a few hard steps with visible banding.",
            "Retained: a coherent tonal read survives in flat colours.",
            "Engraving-grade: dense, ordered tonal structure suitable as a deliberate screen/engraving look.",
        ],
    },
    "evidence_is_actionable": {
        "type": "noul",
        "instructions": (
            "Do the supplied measurements contain enough reliable evidence to act "
            "on a production decision, given the stated limitations?"
        ),
        "criteria": {
            "true": "The source, render and PDF evidence are present and their stated limitations do not block a production decision.",
            "false": "A required measurement is missing, failed, or is an estimate whose limitation blocks a production decision.",
        },
    },
}


# ------------------------------------------------------------------ profiles
#
# A PROFILE is a question set plus the three things a question set needs to be
# usable: which projector reads the input, the questions themselves, and how the
# answers fold. They are DATA on purpose — adding a vocabulary is adding a dict,
# never a second annotator. (`chopshop-jev/AGENTS.md` forbids reimplementing this
# module elsewhere precisely so that one place holds the projection, the
# questions and the fold.)
#
# WHY TEMPLATES AT ALL: the four printability questions are a good, narrow set
# for a preflight manifest, and they are also only one of the vocabularies this
# system could ask about. Making them the DEFAULT template keeps every existing
# caller working unchanged while letting a second vocabulary exist beside them
# rather than instead of them.
#
# WHAT A PROFILE MUST NOT DO: decide anything. Same rule as the default set —
# a profile never ranks candidates, never picks a winner and never overrides the
# deterministic gates. A template is a vocabulary, not an authority.

# The types the SERVICE accepts, measured against the live endpoint rather than
# read off a card:
#
#   choice  — the answer carries `choice` plus a confidence.
#   score   — `score` plus `legend`; certainty is the top of `probabilities`
#             (a score answer reports confidence 0.0, which is not a certainty).
#   noul    — the value IS a calibrated P(true); certainty is its distance from
#             a coin flip.
#
# A free-text type was written for this repo and REFUSED IN USE: a question set
# containing one comes back `HTTP 400 api_usage_error: Invalid request`, while the
# same set without it is answered. So it is not a type this service has, and
# nothing here may declare one.
QUESTION_TYPES = ("choice", "score", "noul")

# Types a vocabulary may want and this service does not implement, each with the
# measurement that established it. They are refused LOCALLY, naming the evidence,
# so the next person to reach for one learns it in a millisecond rather than after
# a round trip. Delete an entry the day the service starts accepting it.
UNSUPPORTED_QUESTION_TYPES = {
    "phrase": "the service answers choice/score/noul only — a set containing a phrase "
              "question returns HTTP 400 api_usage_error: Invalid request",
}

# The envelope keys the service accepts. EXACTLY these: an extra key beside them
# was measured to turn a 200 into a 400, which is how a `profile` field added for
# bookkeeping broke every request in the repo including the one that had worked
# for a year. Anything this repo wants to record about a request goes in the
# SIDECAR, never in the envelope.
ENVELOPE_KEYS = ("model", "state", "questions")


# MET-Meme's annotation scheme, as a question set.
#
# The vocabulary is MET-Meme's (liaolianfoka, "A Multi-modal Meme Dataset Rich in
# Metaphors"): the criteria KEYS here are identifiers, and the studio's
# `app/lib/meme_vocabulary.rb` holds the display words and the dataset's own
# ordinals. Two renderings of one vocabulary — the studio module is pinned
# against the source README, and keeping the identifiers here in the same order
# is what lets a drift test be written between them later rather than guessed at
# now.
#
# `requires` names the evidence a question cannot be answered without. It exists
# because most of MET-Meme's scheme is about an IMAGE and this annotator is not
# given one: the state says so, and the fold reports a question whose evidence is
# absent in `unevidenced` instead of letting a plausible answer read as settled.
MEME_QUESTIONS: dict[str, dict[str, Any]] = {
    "metaphor_occurrence": {
        "type": "choice",
        "instructions": (
            "Judging only from the supplied prompt and measurements, is this "
            "artifact literal or metaphorical?"
        ),
        "criteria": {
            "literal_meme": "The prompt describes what it depicts, with no second thing meant.",
            "metaphorical_meme": "The prompt asks one thing to stand in for another.",
        },
    },
    "metaphor_category": {
        "type": "choice",
        "instructions": "Which modality carries the metaphor, as far as the supplied evidence shows?",
        "requires": ["image_visible"],
        "criteria": {
            "complementary": "Text and image each carry part of it.",
            "text_dominant": "The text carries the metaphor; the image illustrates.",
            "image_dominant": "The image carries the metaphor; the text anchors it.",
        },
    },
    # MET-Meme's `source_domain` and `target_domain` are NOT here, and their
    # absence is a measured limit rather than an oversight: the scheme constrains
    # those two by SHAPE ("adj + n" / "verb + n") rather than by a list, so they
    # need a free-text answer, and this service has no such type (see
    # UNSUPPORTED_QUESTION_TYPES for the measurement). They are the one part of
    # the scheme this profile cannot ask for. `docs/dataset-translation.md`
    # records it as a gap instead of guessing an enumeration to stand in.
    "source_modality": {
        "type": "choice",
        "instructions": "Which modality carries the source domain?",
        "requires": ["image_visible"],
        "criteria": {
            "complementary": "Both.",
            "text_dominant": "The text.",
            "image_dominant": "The image.",
        },
    },
    "target_modality": {
        "type": "choice",
        "instructions": "Which modality carries the target domain?",
        "requires": ["image_visible"],
        "criteria": {
            "complementary": "Both.",
            "text_dominant": "The text.",
            "image_dominant": "The image.",
        },
    },
    "sentiment": {
        "type": "choice",
        "instructions": "Which feeling does this artifact carry?",
        "criteria": {
            "happiness": "Happiness.",
            "love": "Love or affection.",
            "anger": "Anger.",
            "sorrow": "Sorrow.",
            "fear": "Fear.",
            "hate": "Hate or contempt.",
            "surprise": "Surprise.",
        },
    },
    "intention": {
        "type": "choice",
        "instructions": "What is this artifact doing?",
        "criteria": {
            "interactive": "It invites a response.",
            "expressive": "It states a feeling or position.",
            "purely_entertaining": "It aims only to amuse.",
            "offensive": "Its aim is to offend.",
            "other": "None of the above.",
        },
    },
    "offensiveness": {
        "type": "choice",
        "instructions": "How offensive would this read to a general audience?",
        "criteria": {
            "non_offensive": "Not offensive.",
            "slightly_offensive": "Slightly offensive.",
            "moderately_offensive": "Moderately offensive.",
            "very_offensive": "Very offensive.",
        },
    },
    "evidence_is_actionable": {
        "type": "noul",
        "instructions": (
            "Do the supplied materials carry enough reliable evidence to label this "
            "at all, given what the state says is missing?"
        ),
        "criteria": {
            "true": "The prompt and whatever measurements are present can support a label.",
            "false": "Something the labels depend on is absent, so a label would be a guess.",
        },
    },
}


def project_artifact(artifact: dict[str, Any]) -> dict[str, Any]:
    """Project a studio generation artifact into a compact Jev state.

    The artifact is the studio's own shape for a text-image pair: the prompt
    (from the DiffusionDB library, or typed), the settings the generator ran
    with, and whatever measurements were taken of the raster. The prompt text is
    the ONLY thing here that came from a public dataset — everything else is this
    system's own record of what it generated.

    What it deliberately does NOT do is claim to show the picture. This annotator
    is handed numbers and text and never pixels, so `image_visible` is false
    UNLESS the caller carried a caption back from a captioner that did see them
    (chopshop-jev#2). With one, the evidence is a written description rather than
    the pixels themselves — which is enough for a text model to judge whether the
    picture matches the prompt, and is still not the same as looking. Without one
    the question declares `requires: ["image_visible"]` and the fold reports it
    unevidenced: the difference between a labelled dataset and a plausible-looking
    one.
    """
    if not isinstance(artifact, dict):
        raise ValueError("expected a JSON object for the artifact")
    prompt = artifact.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError(
            "the dataset-translation profile reads a generation artifact and needs a "
            "'prompt' string; this file has none"
        )

    settings = artifact.get("settings") if isinstance(artifact.get("settings"), dict) else {}
    generation = artifact.get("generation") if isinstance(artifact.get("generation"), dict) else {}
    measurements = artifact.get("measurements")
    if not isinstance(measurements, dict):
        measurements = {}

    image = artifact.get("image") if isinstance(artifact.get("image"), dict) else {}
    has_image = bool(image.get("file") or image.get("raster") or measurements)

    # The caption is the PIXELS-DERIVED state: some captioner looked at this PNG
    # and wrote down what it saw, and the caller carried that back with the
    # artifact. Absent means absent — an empty or untrusted string does not
    # satisfy the requirement, so a failed caption leaves the question
    # unevidenced exactly as it was before the seam existed.
    caption = image.get("caption") if isinstance(image.get("caption"), str) else ""
    caption = " ".join(caption.split()).strip()
    captioned = bool(caption)
    caption_by = image.get("caption_model") if isinstance(image.get("caption_model"), str) else None

    return {
        "artifact_schema": "generation-artifact",
        "prompt": _scrub(" ".join(prompt.split()), 1000),
        "topic": _scrub(artifact.get("topic"), 120) if artifact.get("topic") else None,
        "phrase_root": _scrub(artifact.get("phrase_root"), 120) if artifact.get("phrase_root") else None,
        # A setting the caller did not record is ABSENT rather than null: "no
        # sampler was recorded" and "the sampler is null" are the same statement,
        # and a null in a request invites the service to decide which it is.
        "settings": {
            key: settings[key]
            for key in ("seed", "steps", "guidance", "sampler", "width", "height", "model")
            if settings.get(key) is not None
        },
        "generation": {
            key: (generation[key] if key != "raster" else _short_path(generation[key]))
            for key in ("model", "job", "raster")
            if key in generation
        },
        # The scalars a label might lean on, if the caller measured any. Kept as a
        # flat dict of numbers on purpose: a nested measurement object would be a
        # second schema to keep in step with the pipeline's.
        "measurements": {k: v for k, v in sorted(measurements.items())
                         if isinstance(v, (int, float, str, bool))},
        # The EVIDENCE declaration the fold reads. Never inferred from the
        # question set: what is present is a fact about this input.
        "evidence": {
            "prompt": True,
            "settings": bool(settings),
            "measurements": bool(measurements),
            # True only when a captioner's description travelled with the
            # artifact; the model that wrote it is named beside it so a reader
            # can weigh the evidence against its source.
            "image_visible": captioned,
            **({"caption_by": _scrub(caption_by, 80)} if captioned and caption_by else {}),
        },
        # Present only when there IS one: an absent key and a null mean the same
        # thing here, and the absent one cannot be mistaken for a caption.
        **({"image_caption": _scrub(caption, 600)} if captioned else {}),
        "note": (
            "image_visible is true because a captioner described this raster "
            "(%s); the evidence is that written description, not the pixels."
            % (caption_by or "source not named")
        ) if captioned else (
            "image_visible is false by construction: this annotator is given text and "
            "numbers, never pixels."
        ),
        "_has_image": has_image,
    }


def compose_annotation_verdict(
    answers: dict[str, Any],
    questions: dict[str, Any],
    state: dict[str, Any] | None = None,
    *,
    confidence_floor: float = DEFAULT_CONFIDENCE_FLOOR,
    vocabulary: str | None = None,
) -> dict[str, Any]:
    """Fold any profile's answers by TYPE, into one compact verdict.

    Deliberately generic where `compose_verdict` is specific: that one is a
    domain contract (the studio reads `headline`, `print_route`, `tonal_score`,
    `evidence_actionable` by name), so it stays untouched. This fold reads the
    question set itself, so a new template needs no new folding code.

    Three lists, because they are three different admissions:
      * `values`          — what was answered;
      * `low_confidence`  — answered, but below the floor;
      * `unevidenced`     — answered, but the state says the evidence that
                            question needs is not here.

    Every shipped question is one of the three shapes the service answers
    (`choice`, `score`, `noul`), so every answer here carries a certainty the
    floor can be applied to. There is no free-text branch, because the service
    has no free-text type — see `UNSUPPORTED_QUESTION_TYPES` for the
    measurement.
    """
    evidence = state.get("evidence") if isinstance(state, dict) else None
    evidence = evidence if isinstance(evidence, dict) else {}

    verdict: dict[str, Any] = {
        "values": {},
        # The RAW mass for every answer that carries one, under its own name.
        # This is the addition chopshop-jev#1 asks for and it is the part that
        # matters: a floor-gated verdict with the numbers kept private is a
        # measurement turned into a constant, because a caller who cannot see the
        # mass cannot tell "the model was unsure" from "the floor is set for a
        # different backend". Reported ALWAYS, gated or not.
        "confidence": {},
        "low_confidence": [],
        "unevidenced": [],
        "confidence_floor": confidence_floor,
        # Stated in the artifact rather than left to be inferred, so a consumer
        # reading `low_confidence` knows what it is: a note about the numbers,
        # not a verdict about the raster. See DEFAULT_CONFIDENCE_FLOOR.
        "confidence_floor_is_advisory": True,
        # The measured evidence for this vocabulary, when it has been recorded.
        # Present at the TOP of the verdict, not only inside `confidence_range`,
        # so a caller reading the floor does not have to go looking for the
        # context that makes the floor checkable.
        "confidence_evidence": recorded_confidence_evidence(vocabulary),
    }

    def record(name: str, answer: dict[str, Any]) -> float | None:
        """The answer's mass, recorded raw, and the low-confidence note beside it.

        The raw number is written whether or not it is under the floor — that is
        the whole point. `low_confidence` stays for every existing caller that
        reads it; what changes is that it can no longer be the ONLY thing a
        verdict contains, so it cannot be mistaken for the measurement.
        """
        confidence = _answer_confidence(answer)
        if confidence is None:
            return None
        verdict["confidence"][name] = round(float(confidence), 4)
        if confidence < confidence_floor:
            verdict["low_confidence"].append(name)
        return confidence

    for name, question in questions.items():
        answer = answers.get(name)
        if not isinstance(answer, dict):
            continue
        kind = question.get("type")

        needs = question.get("requires") or []
        if needs and not all(bool(evidence.get(key)) for key in needs):
            # An answer to a question whose evidence is absent is recorded as
            # UNEVIDENCED and NOTHING ELSE. Reporting a value as well would
            # contradict the harness's own rule, pinned in
            # tests/test_slop_cannon.py: "an unevidenced answer must not be
            # reported as a value" — and it is what keeps a keep/escalate loop
            # from quoting a number for a picture nobody described. The raw
            # answer stays in `answers`; it does not become a finding.
            verdict["unevidenced"].append(name)
            continue

        if kind == "noul":
            value = answer.get("noul")
            if isinstance(value, (int, float)):
                verdict["values"][name] = bool(value >= 0.5)
                record(name, answer)
            continue

        if kind == "score":
            if answer.get("score") is not None:
                verdict["values"][name] = round(float(answer["score"]), 2)
                verdict["values"][name + "_label"] = _fraction_label(
                    answer.get("score"), answer.get("legend")
                )
                record(name, answer)
            continue

        # choice, and anything unrecognised treated as a choice: the value is the
        # chosen key, and the mass beside it is recorded either way.
        if answer.get("choice"):
            verdict["values"][name] = answer["choice"]
            record(name, answer)

    verdict["confidence_range"] = observed_confidence_range(
        verdict["confidence"], vocabulary, floor=confidence_floor)
    return verdict


def observed_confidence_range(
    confidences: dict[str, Any],
    vocabulary: str | None = None,
    floor: float = DEFAULT_CONFIDENCE_FLOOR,
) -> dict[str, Any] | None:
    """What range of masses this run actually produced, beside the floor.

    The floor is a constant and this is a measurement, and putting them in the
    same artifact is what makes the first one checkable. When every mass lands
    under the floor — the failure mode chopshop-jev#1 describes — the report says
    so in a field a caller can read without re-deriving anything:

        "all 4 answers came back under the 0.6 floor (0.33-0.52), so
         `low_confidence` is a property of the floor and the backend, not of
         the rasters"

    ``None`` when no answer carried a mass, rather than a zero-width range that
    would read as a real measurement of nothing.
    """
    values = [v for v in confidences.values() if isinstance(v, (int, float))]
    if not values:
        return None
    low, high = round(min(values), 4), round(max(values), 4)
    return {
        "n": len(values),
        "low": low,
        "high": high,
        # BOTH numbers, because they answer different questions and only one of
        # them moves when a caller sets its own floor. `all_below_floor` is this
        # run's floor (the one that gated `low_confidence`); the default-floor
        # pair keeps describing the shipped constant, which is what the recorded
        # ranges below were measured against.
        "all_below_floor": high < floor,
        "floor": floor,
        "all_below_default_floor": high < DEFAULT_CONFIDENCE_FLOOR,
        "default_floor": DEFAULT_CONFIDENCE_FLOOR,
        # The recorded evidence for this vocabulary, when there is any. A run's
        # own range is a measurement of THIS run; the recorded one is what the
        # floor has been sitting against, and the two together are what let a
        # caller see the floor is the thing moving, not the answers.
        "recorded_evidence": recorded_confidence_evidence(vocabulary),
        "note": (
            "all %d answer(s) came back under the floor in use (%s, default %s) "
            "(%.2f-%.2f), so `low_confidence` is a property of the floor and "
            "this backend, not of what was measured"
            % (len(values), floor, DEFAULT_CONFIDENCE_FLOOR, low, high))
        if high < floor else
            "masses span %.2f-%.2f against a %s floor in use (default %s)"
            % (low, high, floor, DEFAULT_CONFIDENCE_FLOOR),
    }


# The templates. `fold` names which verdict composer reads this profile's
# answers: "printability" is the domain contract above, "generic" the type-driven
# fold. `projector` names which reader turns the input file into state.
# The slop vocabulary: what a MEASURED RASTER says about whether it is worth
# keeping. Every question here is answered from numbers the driver measured off
# the PNG, so none of them needs `image_visible` — and the ONE that genuinely
# would ("does it depict what the prompt asked for?") declares that it does, so
# the fold reports it UNEVIDENCED. That is the honest outcome twice over: it is
# true, and it is visible in the output rather than being silently dropped or,
# worse, answered by a text model that has never seen a pixel.
SLOP_QUESTIONS: dict[str, dict[str, Any]] = {
    "has_structure": {
        "type": "noul",
        "instructions": (
            "Do the supplied measurements describe a picture with edges and separated "
            "regions in it, rather than a fog or a field of noise?"
        ),
        "criteria": {
            "true": "Edges and separated regions are present.",
            "false": "The measurements show near-uniform colour or high-frequency noise.",
        },
    },
    "dominant_field": {
        "type": "noul",
        "instructions": (
            "Does a single colour cover most of the frame, so that the frame reads as a "
            "field with something on it?"
        ),
        "criteria": {
            "true": "One colour covers most of the frame.",
            "false": "No single colour covers most of the frame.",
        },
    },
    "structure_score": {
        "type": "score",
        "instructions": (
            "How much visible structure do the measurements show, judged only from edge "
            "density, region count and tonal spread?"
        ),
        "criteria": [
            "None: a flat field, or noise with no regions.",
            "Thin: one or two edges around an otherwise empty field.",
            "Some: several regions with distinguishable boundaries.",
            "Dense: many regions, a real tonal spread, and boundaries throughout.",
        ],
    },
    "slop_signature": {
        "type": "choice",
        "instructions": "Which of these best describes what the measurements show?",
        "criteria": {
            "blank_or_near_blank": "One colour, essentially everywhere.",
            "uniform_noise": "High-frequency variation with no regions.",
            "colour_explosion": "Very many distinct colours with little structure.",
            "washed_flat": "Low contrast, few distinct levels, no clear regions.",
            "structured": "Separated regions, edges, and a real tonal spread.",
        },
    },
    # The one this vocabulary CANNOT ask, stated rather than omitted. A text model
    # is handed numbers and never pixels, so prompt adherence is unevidenced here
    # by construction — and the answer is reported as unevidenced, which is what
    # stops a keep/escalate loop from claiming it measured something it did not.
    "prompt_adherence": {
        "type": "noul",
        "instructions": "Does the image depict what the prompt asked for?",
        "requires": ["image_visible"],
        "criteria": {
            "true": "It shows what was asked for.",
            "false": "It does not.",
        },
    },
}


PROFILES: dict[str, dict[str, Any]] = {
    "printability": {
        "id": "printability",
        "title": "Printability signature of a preflight manifest",
        "why": (
            "The original, and the SANE DEFAULT: four narrow questions about what kind of "
            "print problem an artwork has, folded into the verdict the studio's JEV page "
            "reads. Unchanged, and deliberately so."
        ),
        "projector": "manifest",
        "fold": "printability",
        "questions": QUESTIONS,
    },
    "dataset-translation": {
        "id": "dataset-translation",
        "title": "Meme annotation of a generation artifact (MET-Meme's scheme)",
        "why": (
            "A second vocabulary, applied to this system's own text-image pairs: the prompt "
            "a generator was given and the numbers measured from what it produced. Its "
            "answers are NOT ground truth — MET-Meme's images and their labels are not here "
            "— so an answer is an unvalidated annotation and must be read as one."
        ),
        "projector": "artifact",
        "fold": "generic",
        "questions": MEME_QUESTIONS,
    },
    "generation-slop": {
        "id": "generation-slop",
        "title": "Is a generated raster worth keeping? (measured signals only)",
        "why": (
            "A third vocabulary, over the same generation artifacts as "
            "dataset-translation: what the MEASUREMENTS of a raster say about whether it "
            "is slop. It is the scoring half of a keep/escalate loop over the DiffusionDB "
            "prompt library — the loop itself is the caller's, because this annotator "
            "never ranks and never picks. Two limits are deliberate: it judges the "
            "RASTER's measured quality and never whether the image matches its prompt "
            "(no pixels here; prompt_adherence declares image_visible and comes back "
            "unevidenced), and its kept verdict means 'not obviously slop', never 'good'."
        ),
        "projector": "artifact",
        "fold": "generic",
        "questions": SLOP_QUESTIONS,
    },
}

DEFAULT_PROFILE = "printability"

# The state keys each projector produces, so a caller can check a profile against
# an input without running it. Declared rather than inferred: a profile that reads
# a key its projector never writes is a bug the contract should catch.
PROFILE_INPUTS = {
    "manifest": ("passed", "input", "summary", "findings", "stats", "notes"),
    "artifact": ("prompt", "settings", "generation", "measurements", "evidence"),
}


def profile(name: str | None) -> dict[str, Any]:
    """The named profile, or the default. Raises ValueError on an unknown name.

    An unknown name is REFUSED rather than quietly answered with the default: a
    caller that mistyped a template should be told, not handed somebody else's
    questions and left to wonder why the answers read oddly.
    """
    key = (name or DEFAULT_PROFILE).strip().lower()
    if key not in PROFILES:
        raise ValueError(
            f"unknown profile {key!r}; this annotator ships "
            + ", ".join(sorted(PROFILES))
        )
    return PROFILES[key]


def check_profile(p: dict[str, Any]) -> None:
    """Assert a profile is internally sound. Called by the suite, cheap enough to
    call for real on every run, and it is what keeps a hand-edited template from
    reaching the service malformed."""
    for key in ("id", "title", "projector", "fold", "questions"):
        if key not in p:
            raise ValueError(f"profile {p.get('id')!r} has no {key!r}")
    if p["projector"] not in PROFILE_INPUTS:
        raise ValueError(f"profile {p['id']!r} names an unknown projector {p['projector']!r}")
    if p["fold"] not in ("printability", "generic"):
        raise ValueError(f"profile {p['id']!r} names an unknown fold {p['fold']!r}")
    if not p["questions"]:
        raise ValueError(f"profile {p['id']!r} has no questions")
    for name, question in p["questions"].items():
        kind = question.get("type")
        if kind in UNSUPPORTED_QUESTION_TYPES:
            raise ValueError(
                f"{p['id']}/{name}: the {kind!r} type cannot be asked — "
                + UNSUPPORTED_QUESTION_TYPES[kind]
            )
        if kind not in QUESTION_TYPES:
            raise ValueError(f"{p['id']}/{name}: unknown type {kind!r}")
        if not question.get("instructions"):
            raise ValueError(f"{p['id']}/{name}: no instructions")
        if kind == "choice":
            criteria = question.get("criteria")
            if not isinstance(criteria, dict) or not criteria:
                raise ValueError(f"{p['id']}/{name}: a choice needs a criteria MAP")
        elif kind == "score":
            criteria = question.get("criteria")
            if not isinstance(criteria, list) or not criteria:
                raise ValueError(f"{p['id']}/{name}: a score needs a criteria LIST")
        elif kind == "noul":
            if not isinstance(question.get("criteria"), dict):
                raise ValueError(f"{p['id']}/{name}: a noul needs its true/false criteria")
        for requirement in question.get("requires") or []:
            if requirement not in ("prompt", "settings", "measurements", "image_visible"):
                raise ValueError(f"{p['id']}/{name}: unknown requirement {requirement!r}")


def _scrub(text: str, limit: int) -> str:
    """Collapse long hex runs and truncate long free text."""
    if not isinstance(text, str):
        return str(text)
    matches = _HEX.findall(text)
    if len(matches) > 8:
        kept = ", ".join(matches[:6])
        text = _HEX.sub("", text)
        text = re.sub(r"[,\s]{2,}", " ", text).strip()
        text = f"{text} [colours: {kept} … {len(matches) - 6} more omitted]"
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > limit:
        text = text[: limit - 1].rstrip() + "…"
    return text


def _short_path(value: Any) -> Any:
    """Remove machine-specific path prefixes while retaining useful names."""
    if not isinstance(value, str):
        return value
    if "/" in value or "\\" in value:
        return Path(value).name
    return value


def _compact_finding(finding: Any) -> dict[str, Any]:
    """Keep the classifier fields and a scrubbed human-readable detail.

    The real preflight manifest calls the human-readable text ``detail``;
    ``message``/``note`` are kept as aliases for older or external producers.
    """
    if not isinstance(finding, dict):
        return {"detail": _scrub(str(finding), _DETAIL_LIMIT)}
    result: dict[str, Any] = {}
    for key in ("detail", "message", "note"):
        if key in finding:
            result["detail"] = _scrub(str(finding[key]), _DETAIL_LIMIT)
            break
    for key in (
        "rule", "code", "severity", "layer", "value", "actual",
        "limit", "expected", "path", "field", "kind",
    ):
        if key in finding:
            result[key] = _short_path(finding[key]) if key == "path" else finding[key]
    if not result:
        # Keep an unknown finding inspectable but bounded.
        result = {str(k): v for k, v in list(finding.items())[:8]}
    return result


def _compact_top_inks(value: Any) -> Any:
    if isinstance(value, list):
        return value[:_TOP_INKS_LIMIT]
    return value


def _compact_stats(stats: Any) -> dict[str, Any]:
    """Project the real preflight stats object down to decision-useful scalars.

    Large colour lists are intentionally excluded (the counts suffice); node
    and geometry figures live in ``stats.static`` and are lifted out below.
    """
    if not isinstance(stats, dict):
        return {}
    scalars = [
        "input_kind", "dpi", "proof_pixels",
        "hard_findings", "advisory_findings",
        "rendered_distinct_colors", "rendered_significant_colors",
        "rendered_ink_colors", "rendered_colored_inks", "rendered_screens",
        "rendered_white_screen", "rendered_white_treated_as",
        "rendered_continuous_tone", "rendered_ramp_colors",
        "rendered_largest_ramp_percent", "rendered_diffuse_tone",
        "rendered_diffuse_colors", "rendered_diffuse_area_percent",
        "rendered_blends_absorbed", "rendered_area_threshold_percent",
        "rendered_merge_tolerance", "rendered_blend_tolerance",
        "ink_tac_max_percent", "ink_tac_mean_percent",
        "ink_tac_area_over_limit_percent", "ink_tac_limit_percent",
        "ink_profile_used", "tac_exact", "tac_is_estimate",
        "white_counted_as_ink", "dark_garment_underbase",
        "pdf_pages", "pdf_page_size", "pdf_color_spaces",
        "ink_plate_means_percent", "render_error", "pdf_error",
    ]
    result: dict[str, Any] = {k: stats[k] for k in scalars if k in stats}
    if "pdf_images" in stats and isinstance(stats["pdf_images"], list):
        result["pdf_images"] = {"count": len(stats["pdf_images"])}
    if "pdf_fonts" in stats and isinstance(stats["pdf_fonts"], list):
        fonts = stats["pdf_fonts"]
        result["pdf_fonts"] = {
            "count": len(fonts),
            "embedded": sum(1 for f in fonts if isinstance(f, dict) and f.get("embedded")),
        }
    if "pdf_image_masks" in stats and isinstance(stats["pdf_image_masks"], list):
        result["pdf_image_masks"] = {"count": len(stats["pdf_image_masks"])}
    if "rendered_top_inks" in stats:
        result["rendered_top_inks"] = _compact_top_inks(stats["rendered_top_inks"])
    if "proof_path" in stats:
        result["proof_path"] = _short_path(stats["proof_path"])
    if "pdf_path" in stats:
        result["pdf_path"] = _short_path(stats["pdf_path"])
    # Node/geometry and colour-conformance figures live under stats.static in
    # the real manifest; lift the decision-relevant ones to the top level. The
    # ``static`` dict itself is never copied -- it can contain a full
    # off-palette colour list (thousands of hexes).
    static = stats.get("static")
    if isinstance(static, dict):
        for key in ("paths", "path_nodes_total", "path_nodes_max",
                    "paths_over_node_limit", "color_count",
                    "palette_conformance", "stroke_scale_advisories"):
            if key in static:
                result[key] = static[key]
    return result


def project_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
    """Project a full preflight manifest into a compact Jev state object."""
    source = manifest.get("input") if isinstance(manifest.get("input"), dict) else {}
    summary = manifest.get("summary") if isinstance(manifest.get("summary"), dict) else {}
    findings = manifest.get("findings") if isinstance(manifest.get("findings"), list) else []
    notes = manifest.get("notes") if isinstance(manifest.get("notes"), list) else []

    input_projection = {k: source[k] for k in ("kind",) if k in source}
    if "file" in source:
        input_projection["file"] = _short_path(source["file"])
    if "spec" in source:
        input_projection["spec"] = _short_path(source["spec"])

    summary_projection = {
        k: summary[k] for k in (
            "hard", "advisory", "by_layer", "print_method",
            "gradient_handling", "require_cmyk", "tac_exact",
        ) if k in summary
    }

    return {
        "manifest_schema": "preflight-manifest",
        "passed": bool(manifest.get("passed")),
        "input": input_projection,
        "summary": summary_projection,
        "findings": [_compact_finding(item) for item in findings],
        "stats": _compact_stats(manifest.get("stats")),
        "notes": [_scrub(n, _NOTE_LIMIT) for n in notes],
    }


def build_request(
    state: dict[str, Any],
    model: str = DEFAULT_MODEL,
    profile_name: str | None = None,
) -> dict[str, Any]:
    """Build the documented TypeSafe System One request for one TEMPLATE.

    The questions ride from the profile, so the request always declares exactly
    the vocabulary that will be read back. No profile name means the default
    (printability), which is what every existing caller passes — the signature
    grew, nothing it does changed.

    The envelope is ENVELOPE_KEYS and nothing else: which profile answered is
    recorded in the sidecar, never sent. See that constant for the measurement.
    """
    p = profile(profile_name)
    return {
        "model": model,
        "state": state,
        "questions": copy.deepcopy(p["questions"]),
    }


def _read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object in {path}")
    return value


def _write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")


def call_jev(
    request: dict[str, Any],
    *,
    api_key: str,
    endpoint: str = DEFAULT_ENDPOINT,
    timeout: float = DEFAULT_HTTP_TIMEOUT,
) -> dict[str, Any]:
    """Make one non-retried JSON request to Jev.

    No automatic retry: a timeout or a truncated response may already have been
    charged, and a blind retry could double-bill or mask an unknown outcome.
    """
    body = json.dumps(request, separators=(",", ":")).encode("utf-8")
    http_request = urllib.request.Request(
        endpoint,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "chopshop-svg-jev-annotator/0.4",
        },
    )
    try:
        with urllib.request.urlopen(http_request, timeout=timeout) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:1000]
        raise RuntimeError(f"Jev HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Jev connection failed: {exc.reason}") from exc
    try:
        result = json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError("Jev returned invalid JSON") from exc
    if not isinstance(result, dict):
        raise RuntimeError("Jev returned a non-object JSON response")
    return result


def validate_response(
    response: dict[str, Any],
    questions: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Validate the response envelope without pretending semantic correctness.

    `questions` is the set that was ASKED, which is the profile's and not
    necessarily the default's: reading the module constant here would pass a
    response that answered a different vocabulary, which is exactly the mistake
    this check exists to catch.
    """
    answers = response.get("answers")
    if not isinstance(answers, dict):
        raise RuntimeError("Jev response has no answers object")
    asked = QUESTIONS if questions is None else questions
    missing = sorted(set(asked) - set(answers))
    if missing:
        raise RuntimeError("Jev response is missing answers: " + ", ".join(missing))
    return answers


def _fraction_label(score: Any, legend: Any) -> Any:
    """Map a possibly-fractional score onto the nearest described level."""
    if not isinstance(legend, dict) or score is None:
        return None
    try:
        index = int(round(float(score)))
    except (TypeError, ValueError):
        return None
    return legend.get(str(index)) or legend.get(index)


def _answer_confidence(answer: dict[str, Any]) -> float | None:
    """Extract a usable 0..1 certainty from any answer type.

    Live Jev responses (verified 2026-09-24) report ``confidence`` only for
    ``choice`` answers. ``score`` answers carry ``confidence: 0.0`` and a real
    ``probabilities`` distribution, and ``noul`` answers carry no confidence
    field at all — the value *is* the calibrated P(true). This maps each shape
    to a certainty so the confidence-floor check is type-aware.

    ``answer_confidence`` is checked first because it is the probability mass on
    the reported answer (``max(p)``) — the quantity a floor can be applied to —
    and a local backend that reports it sends an entropy-style ``confidence``
    instead, which is a *different* function of the same distribution. TypeSafe's
    response has no such field, so a Jev answer still takes the branches below
    exactly as before; this only keeps the floor meaning the same thing on both
    backends.
    """
    mass = answer.get("answer_confidence")
    if isinstance(mass, (int, float)) and mass > 0:
        return float(mass)
    confidence = answer.get("confidence")
    if isinstance(confidence, (int, float)) and confidence > 0:
        return float(confidence)
    probabilities = answer.get("probabilities")
    if isinstance(probabilities, dict) and probabilities:
        return float(max(probabilities.values()))
    noul = answer.get("noul")
    if isinstance(noul, (int, float)):
        # Certainty = distance from a coin-flip: 0.5 -> 0, 0/1 -> 1.
        return float(2 * abs(noul - 0.5))
    return None


def compose_verdict(answers: dict[str, Any], *, confidence_floor: float = DEFAULT_CONFIDENCE_FLOOR) -> dict[str, Any]:
    """Turn the raw typed answers into a compact, thresholded verdict.

    The verdict states what Jev judged and how sure it was; it never ranks
    candidates and never overrides the deterministic gates. Any choice answer
    below the confidence floor is surfaced in low_confidence instead of being
    reported as a settled fact.
    """
    verdict = {
        "headline": None,
        "print_route": None,
        "tonal_label": None,
        "tonal_score": None,
        "evidence_actionable": None,
        # The same treatment as compose_annotation_verdict, and for the same
        # reason: the masses are recorded RAW for every answer that carries one,
        # so a caller can see them and choose its own floor. See the note on
        # DEFAULT_CONFIDENCE_FLOOR and `printability`'s observed 0.23-0.61.
        "confidence": {},
        "low_confidence": [],
        "confidence_floor": confidence_floor,
        "confidence_floor_is_advisory": True,
        # The printability vocabulary's own recorded range, which is 0.23-0.61
        # against this 0.6 floor -- the same shape as generation-slop and the
        # reason the floor is advisory here too. See
        # recorded_confidence_evidence.
        "confidence_evidence": recorded_confidence_evidence("printability"),
    }

    def _gate(key: str, answer: dict[str, Any]) -> None:
        confidence = _answer_confidence(answer)
        if confidence is None:
            return
        verdict["confidence"][key] = round(float(confidence), 4)
        if confidence < confidence_floor:
            verdict["low_confidence"].append(key)

    failure = answers.get("failure_mode") or {}
    if failure.get("choice"):
        verdict["headline"] = failure["choice"]
        _gate("failure_mode", failure)

    route = answers.get("print_route") or {}
    if route.get("choice"):
        verdict["print_route"] = route["choice"]
        _gate("print_route", route)

    tonal = answers.get("tonal_structure") or {}
    if tonal.get("score") is not None:
        verdict["tonal_score"] = round(float(tonal["score"]), 2)
        verdict["tonal_label"] = _fraction_label(tonal["score"], tonal.get("legend"))
        _gate("tonal_structure", tonal)

    evidence = answers.get("evidence_is_actionable") or {}
    if evidence.get("noul") is not None:
        # A noul has no separate confidence field; the value is P(true).
        verdict["evidence_actionable"] = bool(evidence["noul"] >= 0.5)
        _gate("evidence_is_actionable", evidence)

    verdict["confidence_range"] = observed_confidence_range(
        verdict["confidence"], floor=confidence_floor)
    return verdict


def make_annotation(
    manifest_path: Path,
    state: dict[str, Any],
    request: dict[str, Any],
    response: dict[str, Any],
    profile_name: str | None = None,
    *,
    confidence_floor: float = DEFAULT_CONFIDENCE_FLOOR,
) -> dict[str, Any]:
    """The sidecar, for whichever TEMPLATE was asked.

    It records the profile it answered, so a sidecar is never ambiguous about
    which vocabulary its verdict is in — and the verdict comes from the fold that
    profile names, because a MEME answer folded through the printability contract
    would produce a verdict full of nulls that still looks like a verdict.
    """
    p = profile(profile_name)
    answers = validate_response(response, p["questions"])
    verdict = (
        compose_verdict(answers, confidence_floor=confidence_floor)
        if p["fold"] == "printability"
        else compose_annotation_verdict(
            answers, p["questions"], state, vocabulary=p["id"],
            confidence_floor=confidence_floor,
        )
    )
    return {
        "schema": ANNOTATION_SCHEMA,
        "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "source_manifest": manifest_path.name,
        "model": response.get("model", request.get("model")),
        "profile": p["id"],
        "status": "ok",
        "state": state,
        "verdict": verdict,
        "questions": request["questions"],
        "answers": answers,
        "usage": response.get("usage"),
    }


def make_skipped_annotation(
    manifest_path: Path,
    state: dict[str, Any],
    reason: str,
    profile_name: str | None = None,
) -> dict[str, Any]:
    p = profile(profile_name)
    return {
        "schema": ANNOTATION_SCHEMA,
        "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "source_manifest": manifest_path.name,
        "model": DEFAULT_MODEL,
        "profile": p["id"],
        "status": "skipped",
        "reason": reason,
        "state": state,
        "questions": p["questions"],
    }


def default_output(manifest_path: Path) -> Path:
    name = manifest_path.name
    if name.endswith(".manifest.json"):
        name = name[: -len(".manifest.json")] + ".jev.json"
    else:
        name = manifest_path.stem + ".jev.json"
    return manifest_path.with_name(name)


def main(argv: list[str] | None = None) -> int:
    file_values = _env_file_values(*DEFAULT_ENV_FILES)
    parser = argparse.ArgumentParser(description=__doc__)
    # Optional so `--list-profiles` works without one; main() refuses a missing
    # path itself, with the reason, rather than argparse's usage dump.
    parser.add_argument("manifest", type=Path, nargs="?", help="preflight manifest JSON, or a generation artifact for the translation profile")
    parser.add_argument("--output", type=Path, help="sidecar path; defaults to <stem>.jev.json")
    parser.add_argument("--endpoint", default=resolve_env(
        ("JEV_ENDPOINT", "TYPESAFE_ENDPOINT"), DEFAULT_ENDPOINT, file_values))
    parser.add_argument("--model", default=resolve_env(
        ("JEV_MODEL", "TYPESAFE_MODEL"), DEFAULT_MODEL, file_values))
    parser.add_argument("--timeout", type=float, default=_env_float(
        ("JEV_HTTP_TIMEOUT", "TYPESAFE_HTTP_TIMEOUT"), DEFAULT_HTTP_TIMEOUT, file_values))
    parser.add_argument("--api-key", default=None, help=argparse.SUPPRESS)
    # The floor is advisory, and #6 asked for the knob the README already
    # claimed: a caller whose backend and vocabulary justify a different number
    # sets it here (or in JEV_CONFIDENCE_FLOOR) instead of being told the value
    # is configurable and finding that it is not.
    parser.add_argument(
        "--confidence-floor", type=float,
        default=_env_float(
            ("JEV_CONFIDENCE_FLOOR", "TYPESAFE_CONFIDENCE_FLOOR"),
            DEFAULT_CONFIDENCE_FLOOR, file_values),
        help="certainty below which an answer is listed in `low_confidence` "
             f"(default {DEFAULT_CONFIDENCE_FLOOR}, env JEV_CONFIDENCE_FLOOR); "
             "advisory: it never changes an answer, only the note beside it")
    parser.add_argument("--dry-run", action="store_true", help="write the request envelope without calling Jev")
    parser.add_argument("--optional", action="store_true", help="write status=skipped and exit 0 when no key or API call is available")
    parser.add_argument("--profile", default=DEFAULT_PROFILE,
                        help="which question-set TEMPLATE to ask: " + ", ".join(sorted(PROFILES))
                             + f" (default: {DEFAULT_PROFILE})")
    parser.add_argument("--list-profiles", action="store_true",
                        help="print the templates and exit")
    args = parser.parse_args(argv)

    if args.list_profiles:
        for p in PROFILES.values():
            print(f"{p['id']}\t{p['projector']}\t{len(p['questions'])} questions\t{p['title']}")
        return 0

    if args.manifest is None:
        print("error: a manifest (or artifact) path is required", file=sys.stderr)
        return 2

    if not 0.0 <= args.confidence_floor <= 1.0:
        print(
            "error: --confidence-floor must be within 0..1, got %s "
            "(read from --confidence-floor / JEV_CONFIDENCE_FLOOR)"
            % args.confidence_floor, file=sys.stderr)
        return 2

    try:
        # The template decides how the input is READ, not just what is asked: the
        # default profile reads a preflight manifest, the translation profile reads
        # a generation artifact, and naming the wrong one is refused by the
        # projector rather than answered about the wrong document.
        chosen = profile(args.profile)
        check_profile(chosen)
        manifest = _read_json(args.manifest)
        state = (project_manifest(manifest) if chosen["projector"] == "manifest"
                 else project_artifact(manifest))
        request = build_request(state, args.model, chosen["id"])
        output = args.output or default_output(args.manifest)

        if args.dry_run:
            _write_json(output, {
                "schema": ANNOTATION_SCHEMA,
                "status": "dry_run",
                "source_manifest": args.manifest.name,
                "model": args.model,
                "profile": chosen["id"],
                # There is no response and so no verdict here, and inventing one
                # would be a fabrication. The floor's STATUS still belongs in
                # the envelope, because the envelope is where a caller reads
                # what is about to be asked and decides its own floor -- and
                # `confidence_floor` is advisory. See DEFAULT_CONFIDENCE_FLOOR.
                # The value is the floor THIS run would use, so a caller reads
                # what is about to be applied rather than the constant.
                "confidence_floor": args.confidence_floor,
                "confidence_floor_is_advisory": True,
                "confidence_evidence": recorded_confidence_evidence(chosen["id"]),
                "request": request,
            })
            print(f"Jev dry-run request: {output}")
            return 0

        api_key = args.api_key or resolve_env(
            ("JEV_API_KEY", "TYPESAFE_API_KEY", "LAYA_API_KEY"), None, file_values)
        if not api_key:
            reason = ("no API key: set JEV_API_KEY (or LAYA_API_KEY for the "
                      "local backend), or put one of them in ~/.hermes/.env / .env")
            if args.optional:
                _write_json(output, make_skipped_annotation(args.manifest, state, reason, chosen["id"]))
                print(f"Jev skipped: {output}")
                return 0
            print(f"error: {reason}; use --dry-run or --optional", file=sys.stderr)
            return 2

        try:
            response = call_jev(request, api_key=api_key, endpoint=args.endpoint, timeout=args.timeout)
            annotation = make_annotation(
                args.manifest, state, request, response, chosen["id"],
                confidence_floor=args.confidence_floor)
        except RuntimeError as exc:
            if not args.optional:
                print(f"error: {exc}", file=sys.stderr)
                return 1
            annotation = make_skipped_annotation(args.manifest, state, str(exc), chosen["id"])
            annotation["endpoint"] = args.endpoint
        _write_json(output, annotation)
        print(f"Jev annotation: {output}")
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
