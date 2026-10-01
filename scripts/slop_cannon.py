#!/usr/bin/env python3
"""The slop cannon: fire the dataset's prompts at several models, measure what
comes back, and let the decision service say which of it is slop.

WHAT THIS IS, AND WHAT IT IS NOT

It is a keep/escalate loop. It draws real prompts, generates a raster per
(prompt, model), measures that raster into numbers, has `jev_annotate.py` answer
the `generation-slop` vocabulary about those numbers, and buckets the results.
The KEEPING is done here and not by the annotator, which is a hard rule in this
repo: Jev never ranks and never picks.

It does NOT judge whether an image matches its prompt. That needs pixels, this
system has no captioner, and the one question that would need one
(`prompt_adherence`) is declared `requires: image_visible` and therefore comes
back UNEVIDENCED. A kept raster here means "not obviously slop" — never "good",
and never "as asked for". Read every number below with that in mind.

MEASUREMENTS, AND WHY THEY ARE NAMED THE WAY THEY ARE

The numbers are computed HERE, from the PNG, by this file — they are not
`chopshop-svg`'s `rendered_*` print-preflight metrics, which are a different
pipeline's definitions computed on a different box. So they are namespaced
`slop_` to make it impossible to read one as the other. The definitions are
stated in `measure_raster` and are deliberately crude: they are slop DETECTORS,
not a quality metric.

Stdlib only, like the annotator it shells: no Pillow, no numpy. The PNG decoder
is the minimum that reads what these generators actually write, and it refuses
anything else by name rather than guessing.

WHERE THE SERVICES ARE
----------------------

Nowhere in this file. Both endpoints come from the environment --
`$CHOPSHOP_FLUX_ENDPOINT` and `$JEV_ENDPOINT` -- or from the matching flag, and
with neither set the run REFUSES, naming the variable it wanted. That is the
same rule `chopshop-flux/AGENTS.md` states for its own repo ("nothing in the
repo names a host, a port or a path belonging to one machine"), and it used to
be broken here: both addresses were argparse DEFAULTS, so a bare
`./slop_cannon.py` on a different box aimed at one machine, failed, and reported
"unreachable" as though the network were at fault.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys
import urllib.error
import urllib.request
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ANNOTATOR = HERE / "jev_annotate.py"

# Quantisation for "how many colours are there". 5 bits per channel: the point is
# to tell "a poster" from "a photograph with a million tones", and finer buckets
# would make every smooth gradient read as an explosion.
COLOUR_BITS = 5
SIGNIFICANT_SHARE = 0.01      # a colour covering >= 1% of the frame
EDGE_THRESHOLD = 24           # a luminance step this large is a boundary
FAR_OFFSET = 8                # the lag for the "is it structure or noise" ratio


class SlopError(RuntimeError):
    """Something this harness refuses to guess about."""

# ---------------------------------------------------------------------------
# Where the two services are: the ENVIRONMENT, never a literal in this file.
#
# These two addresses used to be `--endpoint` DEFAULTS baked in at 100.x.y.z,
# which is the same class of host fact chopshop-flux/AGENTS.md forbids outright:
# "Nothing in the repo names a host, a port or a path belonging to one machine."
# A default is worse than a stale doc — `./slop_cannon.py` with no arguments
# silently aimed at one machine, so a run anywhere else reported "unreachable"
# and the operator went hunting a network fault instead of a missing variable.
#
# So there is no default. An unset endpoint is a STATE TO REPORT, and this
# reports it by naming the variable: the same rule this ecosystem already
# applies to an unconfigured add-on (503 with a reason, never a bare 404)
# turned onto a CLI. There is deliberately not even a loopback fallback: a port
# is a port belonging to one deployment, and guessing one is the same mistake
# one level down.
# ---------------------------------------------------------------------------

FLUX_ENDPOINT_ENV = "CHOPSHOP_FLUX_ENDPOINT"
JEV_ENDPOINT_ENV = "JEV_ENDPOINT"


def resolve_endpoint(supplied: str | None, variable: str, role: str) -> str:
    """The endpoint to use: the flag if given, else $variable, else a refusal.

    ``role`` names what the endpoint IS ("the flux service", "the decision
    service") so the error reads as a statement about the run rather than about
    a variable name the operator has never heard of.
    """
    if supplied is not None and supplied.strip():
        return supplied.strip()
    from_env = (os.environ.get(variable) or "").strip()
    if from_env:
        return from_env
    raise SlopError(
        "no endpoint for %s: pass --%s, or export %s=<url>. This harness names "
        "no host, so an unset endpoint is reported rather than guessed at."
        % (role, "endpoint" if variable == FLUX_ENDPOINT_ENV else "jev-endpoint",
           variable)
    )


# ---------------------------------------------------------------------------
# The PNG decoder: what these generators write, and nothing else.
# ---------------------------------------------------------------------------


def decode_png(raw: bytes) -> tuple[int, int, list[tuple[int, int, int]]]:
    """PNG bytes -> (width, height, pixels).

    Supports what the flux service actually writes (8-bit RGB or RGBA, no
    interlace) and REFUSES everything else with the chunk that said so: a decoder
    that guesses at a 16-bit or interlaced file would produce plausible numbers
    from wrong data, which is the one failure mode a measurement harness must not
    have.
    """
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise SlopError("not a PNG")
    pos = 8
    width = height = depth = colour_type = interlace = None
    idat = bytearray()
    while pos + 8 <= len(raw):
        (length,) = struct.unpack(">I", raw[pos:pos + 4])
        kind = raw[pos + 4:pos + 8]
        body = raw[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, colour_type, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if width is None or height is None:
        raise SlopError("no IHDR chunk")
    # Narrowed into new names: the checker cannot see that the loop above always
    # sets them, and a decoder that silently used None as a width would be the
    # worst possible failure here.
    frame_width: int = width
    frame_height: int = height
    if depth != 8:
        raise SlopError("bit depth %d is not supported (8 only)" % depth)
    if interlace:
        raise SlopError("interlaced PNGs are not supported")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(colour_type)
    if channels is None:
        raise SlopError("colour type %d is not supported (2 or 6 only)" % colour_type)
    if channels not in (3, 4):
        raise SlopError("colour type %d is not supported (2 or 6 only)" % colour_type)

    data = zlib.decompress(bytes(idat))
    stride = frame_width * channels
    pixels: list[tuple[int, int, int]] = []
    previous = bytearray(stride)
    offset = 0
    for _ in range(frame_height):
        filter_type = data[offset]
        offset += 1
        line = bytearray(data[offset:offset + stride])
        offset += stride
        if filter_type == 0:
            pass
        elif filter_type == 1:      # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:      # Up
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:      # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:      # Paeth
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                up = previous[i]
                upleft = previous[i - channels] if i >= channels else 0
                p = left + up - upleft
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - upleft)
                if pa <= pb and pa <= pc:
                    pred = left
                elif pb <= pc:
                    pred = up
                else:
                    pred = upleft
                line[i] = (line[i] + pred) & 0xFF
        else:
            raise SlopError("unknown PNG filter type %d" % filter_type)
        for x in range(frame_width):
            i = x * channels
            pixels.append((line[i], line[i + 1], line[i + 2]))
        previous = line
    return frame_width, frame_height, pixels


# ---------------------------------------------------------------------------
# The measurement: raster -> the numbers the vocabulary is asked about.
# ---------------------------------------------------------------------------


def _luma(pixel: tuple[int, int, int]) -> int:
    """Rec. 601 luma, integer. Only used for relative comparisons."""
    r, g, b = pixel
    return (299 * r + 587 * g + 114 * b) // 1000


def measure_raster(raw: bytes) -> dict:
    """PNG bytes -> a flat dict of scalars.

    Every definition here is crude ON PURPOSE and is stated so it cannot be read
    as more than it is:

    * `slop_distinct_colors` — distinct colours after 5-bit quantisation.
    * `slop_significant_colors` — colours covering >= 1% of the frame.
    * `slop_background_fraction` — the share of the single most common colour.
      High means "a field with something on it"; 1.0 means blank.
    * `slop_luma_std` — the spread of luminance. Near 0 is a flat frame.
    * `slop_luma_levels` — how many 16-wide luminance buckets are in use.
    * `slop_edge_density` — the share of pixels with a >= 24 luma step to the
      right or below. Zero means no boundaries anywhere.
    * `slop_adjacent_delta_mean` vs `slop_distant_delta_mean`, and their ratio
      `slop_noise_ratio` = adjacent / max(distant, 1). Neighbouring pixels
      differing while pixels 8 apart do NOT is high-frequency noise, and it is
      the ratio that separates that from real structure. The denominator is
      CLAMPED AT 1 rather than guarded to 0: for a checkerboard, pixels 8 apart
      are identical (8 is even), so the distant mean is 0 — and a "0 if the
      denominator is falsy" guard turned the most extreme noise there is into a
      ratio of 0.0, inverting the metric exactly where it mattered. Clamped, a
      checkerboard reads ~255 and a flat frame reads 0.
    * `slop_saturation_mean` — mean max-minus-min channel. Low means greyish.
    """
    width, height, pixels = decode_png(raw)
    total = width * height
    quantised: dict[int, int] = {}
    luma_buckets: set[int] = set()
    lumas: list[int] = []
    saturation_total = 0
    adjacent_total = 0
    adjacent_count = 0
    distant_total = 0
    distant_count = 0
    edges = 0

    for y in range(height):
        row = pixels[y * width:(y + 1) * width]
        for x in range(width):
            r, g, b = row[x]
            key = ((r >> (8 - COLOUR_BITS)) << (2 * COLOUR_BITS)
                   | (g >> (8 - COLOUR_BITS)) << COLOUR_BITS
                   | (b >> (8 - COLOUR_BITS)))
            quantised[key] = quantised.get(key, 0) + 1
            value = _luma((r, g, b))
            lumas.append(value)
            luma_buckets.add(value >> 4)
            saturation_total += max(r, g, b) - min(r, g, b)

            stepped = False
            if x + 1 < width:
                delta = abs(value - _luma(row[x + 1]))
                adjacent_total += delta
                adjacent_count += 1
                stepped = stepped or delta >= EDGE_THRESHOLD
            if y + 1 < height:
                below = pixels[(y + 1) * width + x]
                delta = abs(value - _luma(below))
                adjacent_total += delta
                adjacent_count += 1
                stepped = stepped or delta >= EDGE_THRESHOLD
            if stepped:
                edges += 1
            if x + FAR_OFFSET < width:
                distant_total += abs(value - _luma(row[x + FAR_OFFSET]))
                distant_count += 1
            if y + FAR_OFFSET < height:
                distant_total += abs(value - _luma(pixels[(y + FAR_OFFSET) * width + x]))
                distant_count += 1

    mean_luma = sum(lumas) / total
    variance = sum((value - mean_luma) ** 2 for value in lumas) / total
    background = max(quantised.values()) / total
    adjacent_mean = adjacent_total / adjacent_count if adjacent_count else 0.0
    distant_mean = distant_total / distant_count if distant_count else 0.0

    return {
        "slop_pixels": total,
        "slop_distinct_colors": len(quantised),
        "slop_significant_colors": sum(
            1 for count in quantised.values() if count / total >= SIGNIFICANT_SHARE),
        "slop_background_fraction": round(background, 4),
        "slop_luma_mean": round(mean_luma, 2),
        "slop_luma_std": round(variance ** 0.5, 2),
        "slop_luma_levels": len(luma_buckets),
        "slop_edge_density": round(edges / total, 4),
        "slop_adjacent_delta_mean": round(adjacent_mean, 3),
        "slop_distant_delta_mean": round(distant_mean, 3),
        # Clamped, not guarded to 0 — see the note on this metric in the docstring.
        # A checkerboard makes the distant mean exactly 0, and turning that into a
        # ratio of 0.0 would report the noisiest possible frame as the most
        # structured.
        "slop_noise_ratio": round(adjacent_mean / max(distant_mean, 1.0), 3),
        "slop_saturation_mean": round(saturation_total / total, 2),
    }


# ---------------------------------------------------------------------------
# The generator: the flux service, over its own API.
# ---------------------------------------------------------------------------


def _post(base: str, route: str, payload: dict, timeout: float = 900) -> dict:
    request = urllib.request.Request(
        base.rstrip("/") + route, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/json"})
    token = os.environ.get("CHOPSHOP_FLUX_TOKEN")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode()[:300]
        raise SlopError("flux %s -> %s: %s" % (route, exc.code, detail)) from exc
    except urllib.error.URLError as exc:
        raise SlopError("cannot reach the flux service at %s (%s)" % (base, exc)) from exc


def _get_bytes(base: str, name: str, timeout: float = 300) -> bytes:
    request = urllib.request.Request(base.rstrip("/") + "/files/" + name)
    token = os.environ.get("CHOPSHOP_FLUX_TOKEN")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def generate(base: str, prompt: str, model: str, *, width: int, height: int,
             steps: int | None, guidance: float | None, seed: int) -> tuple[bytes, dict]:
    payload = {"prompt": prompt, "model": model, "width": width, "height": height,
               "seed": seed, "images": 1}
    if steps is not None:
        payload["steps"] = steps
    if guidance is not None:
        payload["guidance"] = guidance
    body = _post(base, "/generate", payload)
    entries = body.get("images") or []
    if not entries:
        raise SlopError("the flux service reported no images")
    return _get_bytes(base, entries[0]["name"]), {
        "model": body.get("model"), "seed": body.get("seed"),
        "steps": body.get("steps"), "guidance": body.get("guidance"),
        "width": body.get("width"), "height": body.get("height"),
        "raster": entries[0]["name"],
        "total_seconds": body.get("total_seconds"),
    }


# ---------------------------------------------------------------------------
# The annotator: SHELLED, never reimplemented (this repo's rule).
# ---------------------------------------------------------------------------


def systemone_url(endpoint: str) -> str:
    """The decision service's FULL route from whatever the caller supplied.

    ``jev_annotate.py`` expects the complete endpoint — its own default is
    ``https://api.typesafe.ai/v1/systemone``, route included — and posting to a
    bare base URL is a 404 from the host root, which is exactly how the first
    bracket run failed. Accepting either form here means an operator who pastes
    ``http://host:8797`` (the obvious thing, and what this harness's own default
    used to be) is not punished for it, while a caller who already names the
    route is left alone.
    """
    trimmed = endpoint.rstrip("/")
    return trimmed if trimmed.endswith("/v1/systemone") else trimmed + "/v1/systemone"


def annotate(artifact_path: Path, sidecar: Path, *, profile: str, endpoint: str,
             model: str, api_key: str | None, timeout: float) -> dict:
    """Shell the annotator for one artifact and read the sidecar it wrote.

    The key is FORWARDED rather than inherited: this harness accepts either
    ``JEV_API_KEY`` or ``LAYA_API_KEY``, and the annotator reads only the first
    of those (plus the historical ``TYPESAFE_API_KEY``). Passing it explicitly
    means a caller who exported the service's own name still authenticates,
    instead of failing one level down with "JEV_API_KEY is not set".
    """
    command = [sys.executable, str(ANNOTATOR), str(artifact_path),
               "--profile", profile, "--output", str(sidecar),
               "--endpoint", systemone_url(endpoint),
               "--model", model, "--timeout", str(timeout)]
    # The key is FORWARDED, and it has to be passed explicitly because the two
    # scripts do not agree on its name. This file accepts LAYA_API_KEY (it is
    # the variable the decision service's own unit file sets) and validates it,
    # so an operator who set the documented variable got a run that started,
    # generated every raster, and then failed on the last step with a 401 —
    # after the expensive part. The annotator, separately, only reads
    # JEV_API_KEY and TYPESAFE_API_KEY. Neither script was wrong on its own and
    # together they dropped the key on the floor.
    #
    # --api-key is the annotator's own hidden flag, which exists for exactly
    # this: a caller that resolved the key itself must be able to hand it over
    # rather than hoping the child's environment agrees.
    if api_key:
        command += ["--api-key", api_key]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SlopError("the annotator exited %d: %s"
                        % (result.returncode,
                           (result.stderr or result.stdout or "").strip()[-400:]))
    return json.loads(sidecar.read_text())


# ---------------------------------------------------------------------------
# The bucket: the caller's job, not the annotator's.
# ---------------------------------------------------------------------------


def bucket(sidecar: dict) -> tuple[str, str]:
    """(verdict, why) for one raster, from the answers and their confidence.

    Three outcomes, and the ESCALATE one is the point of the whole design: an
    answer below the floor, or a signature and a structure score that disagree, is
    not silently resolved in either direction — it is handed on. A confident
    slop signature drops the raster; a confident structured one keeps it.
    """
    answers = sidecar.get("answers") or {}
    verdicts = sidecar.get("verdict") or {}
    floor = verdicts.get("confidence_floor", 0.6)
    low = set(verdicts.get("low_confidence") or [])
    unevidenced = set(verdicts.get("unevidenced") or [])

    if "slop_signature" in unevidenced or "structure_score" in unevidenced:
        return "escalate", "the signature question came back unevidenced"

    signature = (answers.get("slop_signature") or {}).get("choice")
    score = (answers.get("structure_score") or {}).get("score")
    if signature is None or score is None:
        return "escalate", "no usable answer from the service"

    sloppy = {"blank_or_near_blank", "uniform_noise", "washed_flat", "colour_explosion"}
    if "slop_signature" in low or "structure_score" in low:
        return "escalate", "below the confidence floor (%.2f)" % floor
    # A confident signature that contradicts the score is exactly the case a
    # threshold would hide, so it is escalated rather than resolved by ordering
    # the two rules.
    if signature in sloppy and score >= 2:
        return "escalate", "signature %s disagrees with score %s" % (signature, score)
    if signature == "structured" and score == 0:
        return "escalate", "signature structured disagrees with score 0"
    if signature in sloppy:
        return "drop", "confident slop: %s" % signature
    return "keep", "confident structure: %s at score %s" % (signature, score)


def confidence_of(answer: dict | None) -> float | None:
    """The number a floor can be applied to, or None if the answer carries none.

    The type-dependent rule, and the single easiest thing to read wrong: a
    `choice` reports `answer_confidence` (the probability mass on the reported
    answer) beside an entropy-based `confidence`; a `score` reports
    `confidence: 0.0` and puts its certainty in a distribution; a `noul` reports
    neither, because its value IS the calibrated P(true).

    Worth knowing before reading any bracket result: the LOCAL backend's masses
    on this vocabulary sit around 0.23–0.60, i.e. under the annotator's default
    0.6 floor — a gap `chopshop-jev/CONTEXT.md` already records as the floor not
    being calibrated for this backend. That is why the harness reports these
    numbers rather than only the floor-gated verdict: at floor 0.6 everything
    escalates, which says something about the floor and nothing about the models.
    """
    if not isinstance(answer, dict):
        return None
    mass = answer.get("answer_confidence")
    if isinstance(mass, (int, float)):
        return round(float(mass), 4)
    if answer.get("type") == "score":
        probabilities = answer.get("probabilities")
        if isinstance(probabilities, (list, tuple)) and probabilities:
            return round(float(max(probabilities)), 4)
    return None


def noul_value(answer: dict | None) -> float | None:
    """A `noul` answer's P(true) — the value itself, not a confidence."""
    if isinstance(answer, dict) and isinstance(answer.get("noul"), (int, float)):
        return round(float(answer["noul"]), 4)
    return None


def row_from(answers: dict) -> dict:
    """The signals the comparison turns on, pulled out of one sidecar.

    Kept flat and explicit so a bracket result can be read (and later
    re-analysed) without re-parsing sidecars: the type-dependent confidence, the
    two calibrated P(true) values the vocabulary's noul questions produce, and a
    flag for the answer that is UNEVIDENCED by construction.
    """
    got = answers.get("answers") or {}
    unevidenced = set((answers.get("verdict") or {}).get("unevidenced") or [])
    return {
        "signature": (got.get("slop_signature") or {}).get("choice"),
        "signature_confidence": confidence_of(got.get("slop_signature")),
        "score": (got.get("structure_score") or {}).get("score"),
        "score_confidence": confidence_of(got.get("structure_score")),
        "p_has_structure": noul_value(got.get("has_structure")),
        "p_dominant_field": noul_value(got.get("dominant_field")),
        # Recorded as the unevidenced answer it is, never as a measurement.
        "p_prompt_adherence": (None if "prompt_adherence" in unevidenced
                               else noul_value(got.get("prompt_adherence"))),
        "unevidenced": sorted(unevidenced),
    }


# ---------------------------------------------------------------------------
# The run.
# ---------------------------------------------------------------------------


def load_prompts(path: Path) -> list[dict]:
    """A prompt list from a JSON file: either artifacts or plain strings."""
    data = json.loads(path.read_text())
    if isinstance(data, dict):
        data = data.get("prompts") or data.get("rows") or []
    prompts = []
    for entry in data:
        if isinstance(entry, str):
            prompts.append({"prompt": entry})
        elif isinstance(entry, dict) and entry.get("prompt"):
            prompts.append(entry)
    if not prompts:
        raise SlopError("no prompts with a 'prompt' field in %s" % path)
    return prompts


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--prompts", type=Path, required=True,
                        help="JSON: a list of strings, or of objects with a 'prompt'")
    parser.add_argument("--models", required=True,
                        help="comma-separated model keys, e.g. klein-4b,sd-1.5,sdxl-turbo")
    parser.add_argument("--out", type=Path, required=True, help="output directory")
    parser.add_argument("--endpoint", default=None,
                        help="the flux service base URL. Not given here means "
                             "read $%s" % FLUX_ENDPOINT_ENV)
    parser.add_argument("--jev-endpoint", default=None,
                        help="the decision service: a base URL or the full "
                             "/v1/systemone route. Not given here means read "
                             "$%s" % JEV_ENDPOINT_ENV)
    parser.add_argument("--jev-model", default="typed-decisions")
    parser.add_argument("--profile", default="generation-slop")
    parser.add_argument("--size", type=int, default=512)
    parser.add_argument("--limit", type=int, default=0, help="prompts to use (0 = all)")
    parser.add_argument("--seed", type=int, default=4242,
                        help="one seed for every model, so the comparison is the model")
    args = parser.parse_args(argv)

    api_key = os.environ.get("JEV_API_KEY") or os.environ.get("LAYA_API_KEY")
    if not api_key:
        raise SlopError("no JEV_API_KEY or LAYA_API_KEY in the environment: the "
                        "decision service refuses an unauthenticated call")

    # Resolved BEFORE any work, so an unconfigured run costs nothing and says
    # what is missing rather than failing on the first HTTP call.
    flux_endpoint = resolve_endpoint(args.endpoint, FLUX_ENDPOINT_ENV,
                                     "the flux service")
    jev_endpoint = resolve_endpoint(args.jev_endpoint, JEV_ENDPOINT_ENV,
                                    "the decision service")

    prompts = load_prompts(args.prompts)
    if args.limit:
        prompts = prompts[:args.limit]
    models = [name.strip() for name in args.models.split(",") if name.strip()]
    args.out.mkdir(parents=True, exist_ok=True)

    rows = []
    for prompt in prompts:
        for model in models:
            label = "%s/%s" % (model, prompt["prompt"][:38].replace("/", "-"))
            print("\n--- %s" % label, flush=True)
            raw, settings = generate(flux_endpoint, prompt["prompt"], model,
                                     width=args.size, height=args.size,
                                     steps=prompt.get("steps"), guidance=prompt.get("guidance"),
                                     seed=int(prompt.get("seed") or args.seed))
            measurements = measure_raster(raw)

            artifact = {
                "prompt": prompt["prompt"],
                "topic": prompt.get("topic"),
                "settings": {"seed": settings["seed"], "steps": settings["steps"],
                             "guidance": settings["guidance"], "model": model,
                             "width": settings["width"], "height": settings["height"]},
                "generation": {"model": model, "raster": settings["raster"]},
                "measurements": measurements,
                "image": {"file": settings["raster"]},
            }
            stem = "%s-%s" % (model, settings["raster"].replace(".png", ""))
            artifact_path = args.out / ("%s.artifact.json" % stem)
            sidecar = args.out / ("%s.jev.json" % stem)
            artifact_path.write_text(json.dumps(artifact, indent=2, sort_keys=True))

            answers = annotate(artifact_path, sidecar, profile=args.profile,
                               endpoint=jev_endpoint, model=args.jev_model,
                               api_key=api_key, timeout=180)
            verdict, why = bucket(answers)
            row = {
                "model": model, "prompt": prompt["prompt"], "raster": settings["raster"],
                "verdict": verdict, "why": why,
                "measurements": measurements, "artifact": str(artifact_path),
                "sidecar": str(sidecar),
                **row_from(answers),
            }
            rows.append(row)
            print("   %-9s %-14s score=%-5s conf=%-6s %s"
                  % (verdict.upper(), row["signature"], row["score"],
                     row["score_confidence"], why), flush=True)

    results = args.out / "slop-cannon-results.json"
    results.write_text(json.dumps(rows, indent=2, sort_keys=True))

    print("\n=== %d rasters ===" % len(rows))
    by_model: dict[str, dict[str, int]] = {}
    for row in rows:
        counts = by_model.setdefault(row["model"], {"keep": 0, "escalate": 0, "drop": 0})
        counts[row["verdict"]] += 1
    print("%-14s %6s %9s %6s" % ("model", "keep", "escalate", "drop"))
    for model in models:
        counts = by_model.get(model, {"keep": 0, "escalate": 0, "drop": 0})
        print("%-14s %6d %9d %6d" % (model, counts["keep"], counts["escalate"], counts["drop"]))

    # The signals that ARE comparable across models, independent of the floor.
    # Reported because the floor is NOT calibrated for the local backend (masses
    # land around 0.23–0.60 against a default 0.6), so a floor-only summary would
    # read "everything escalated" and say nothing about the models. Means are
    # across that model's rasters; None means the answer did not carry the field.
    def mean(values):
        kept = [v for v in values if isinstance(v, (int, float))]
        return round(sum(kept) / len(kept), 3) if kept else None

    print("\n%-14s %8s %8s %8s %8s %8s"
          % ("model", "P(struct)", "P(field)", "score", "sr_conf", "measure"))
    for model in models:
        mine = [row for row in rows if row["model"] == model]
        print("%-14s %8s %8s %8s %8s %8s"
              % (model,
                 mean([r["p_has_structure"] for r in mine]),
                 mean([r["p_dominant_field"] for r in mine]),
                 mean([r["score"] for r in mine]),
                 mean([r["score_confidence"] for r in mine]),
                 # Measured, not judged: the raster's mean edge density.
                 mean([r["measurements"]["slop_edge_density"] for r in mine])))
    print("\nP(struct)/P(field) are the vocabulary's calibrated P(true) values, and")
    print("score is 0..3 — those four columns are the comparison. 'escalate' usually")
    print("means the FLOOR, not the raster: the local backend's masses sit under 0.6.")
    print("\nkept means 'not obviously slop' — it is NOT a claim about the prompt.")
    print("results: %s" % results)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SlopError as failure:
        # A refusal is an ANSWER, not a crash. The traceback would bury the one
        # line that tells the operator what to do, under a stack through argparse
        # and urllib that says nothing they did not already know.
        print("slop_cannon: %s" % failure, file=sys.stderr)
        raise SystemExit(2)
