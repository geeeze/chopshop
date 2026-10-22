"""The slop cannon's measurement and bucketing, with no GPU and no network.

Two things here are worth more than the rest and are tested hardest:

  * The PNG DEFILTER. It is the only place in this harness where being wrong
    produces plausible numbers instead of an error, so all five filter types are
    round-tripped against a known image rather than assumed. A measurement
    harness whose decoder is subtly wrong is worse than no harness.
  * The BUCKET rule. It is the caller's decision and it deliberately escalates
    rather than resolves, so the disagreement cases are pinned.
"""

import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import slop_cannon  # noqa: E402
from slop_cannon import SlopError, bucket, decode_png, measure_raster, _luma  # noqa: E402


def png_bytes(rows, filter_type=0):
    """Encode RGB8 rows as a PNG, applying `filter_type` as a real filter.

    The forward filters are implemented here so the decoder's inverse can be
    checked against them. Only filter 0 is what the generators write, but the
    decoder claims all five, so all five are exercised.
    """
    height = len(rows)
    width = len(rows[0])
    channels = 3
    stride = width * channels
    raw = bytearray()
    previous = bytearray(stride)
    for row in rows:
        line = bytearray(v for pixel in row for v in pixel)
        if filter_type == 0:
            raw.append(0)
            raw += line
        elif filter_type == 1:
            raw.append(1)
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                raw.append((line[i] - left) & 0xFF)
        elif filter_type == 2:
            raw.append(2)
            for i in range(stride):
                raw.append((line[i] - previous[i]) & 0xFF)
        elif filter_type == 3:
            raw.append(3)
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                raw.append((line[i] - ((left + previous[i]) >> 1)) & 0xFF)
        elif filter_type == 4:
            raw.append(4)
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
                raw.append((line[i] - pred) & 0xFF)
        previous = line

    def chunk(kind, body):
        return (struct.pack(">I", len(body)) + kind + body
                + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b""))


def flat(width, height, colour):
    return [[colour] * width for _ in range(height)]


class DecodeTest(unittest.TestCase):
    def test_every_filter_type_round_trips_to_the_same_pixels(self):
        rows = [[(x * 7 % 256, y * 11 % 256, (x + y) * 5 % 256) for x in range(9)]
                for y in range(7)]
        expected = [pixel for row in rows for pixel in row]
        for filter_type in range(5):
            with self.subTest(filter_type=filter_type):
                _, _, pixels = decode_png(png_bytes(rows, filter_type))
                self.assertEqual(pixels, expected)

    def test_a_flat_image_measures_as_flat(self):
        measurements = measure_raster(png_bytes(flat(8, 8, (10, 20, 30))))
        self.assertEqual(measurements["slop_distinct_colors"], 1)
        self.assertEqual(measurements["slop_significant_colors"], 1)
        self.assertEqual(measurements["slop_background_fraction"], 1.0)
        self.assertEqual(measurements["slop_edge_density"], 0.0)
        self.assertEqual(measurements["slop_luma_std"], 0.0)
        # No distant delta means no ratio, and it must be 0 rather than a crash.
        self.assertEqual(measurements["slop_noise_ratio"], 0.0)

    def test_two_halves_measure_as_two_colours_and_one_boundary(self):
        rows = [[(0, 0, 0) if x < 4 else (255, 255, 255) for x in range(8)]
                for _ in range(8)]
        measurements = measure_raster(png_bytes(rows))
        self.assertEqual(measurements["slop_distinct_colors"], 2)
        self.assertEqual(measurements["slop_significant_colors"], 2)
        self.assertEqual(measurements["slop_background_fraction"], 0.5)
        self.assertGreater(measurements["slop_luma_std"], 100)
        # One vertical boundary per row over 8 rows: 8 of 64 pixels step.
        self.assertEqual(measurements["slop_edge_density"], 0.125)

    def test_noise_has_a_noise_ratio_above_one_where_structure_does_not(self):
        # Alternating black/white is the extreme: neighbours differ maximally
        # while pixels 8 apart agree, so adjacent/distant is unbounded. A flat
        # two-tone BLOCK image keeps the two comparable. That difference is the
        # whole reason the ratio exists.
        noise = [[(0, 0, 0) if (x + y) % 2 else (255, 255, 255) for x in range(16)]
                 for y in range(16)]
        blocks = [[(0, 0, 0) if (x // 8 + y // 8) % 2 else (255, 255, 255)
                   for x in range(16)] for y in range(16)]
        noise_measurements = measure_raster(png_bytes(noise))
        block_measurements = measure_raster(png_bytes(blocks))
        self.assertGreater(noise_measurements["slop_noise_ratio"],
                           block_measurements["slop_noise_ratio"])
        self.assertGreater(noise_measurements["slop_noise_ratio"], 5)

    def test_unsupported_pngs_are_refused_by_name_rather_than_guessed_at(self):
        good = png_bytes(flat(2, 2, (1, 2, 3)))
        self.assertEqual(len(decode_png(good)[2]), 4)

        with self.assertRaises(SlopError):
            decode_png(b"not a png at all")

        # 16-bit, interlaced, and palette each with their own reason.
        def with_header(width, height, depth, colour_type, interlace):
            def chunk(kind, body):
                return (struct.pack(">I", len(body)) + kind + body
                        + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))
            header = struct.pack(">IIBBBBB", width, height, depth, colour_type, 0, 0, interlace)
            return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                    + chunk(b"IDAT", zlib.compress(b"\x00" * 32)) + chunk(b"IEND", b""))

        for depth, colour_type, interlace, wanted in (
                (16, 2, 0, "bit depth"), (8, 2, 1, "interlaced"),
                (8, 3, 0, "colour type")):
            with self.subTest(depth=depth, colour_type=colour_type, interlace=interlace):
                with self.assertRaises(SlopError) as caught:
                    decode_png(with_header(4, 4, depth, colour_type, interlace))
                self.assertIn(wanted, str(caught.exception))

    def test_luma_orders_black_below_white(self):
        self.assertLess(_luma((0, 0, 0)), _luma((255, 255, 255)))


def sidecar(signature, score, *, low=(), unevidenced=(), floor=0.6):
    """A sidecar shaped like the annotator's, for the bucket rule."""
    answers = {}
    if signature is not None:
        answers["slop_signature"] = {"type": "choice", "choice": signature}
    if score is not None:
        answers["structure_score"] = {"type": "score", "score": score}
    return {"answers": answers,
            "verdict": {"confidence_floor": floor,
                        "low_confidence": list(low),
                        "unevidenced": list(unevidenced)}}


class BucketTest(unittest.TestCase):
    def test_a_confident_structured_answer_is_kept(self):
        verdict, why = bucket(sidecar("structured", 3))
        self.assertEqual(verdict, "keep")
        self.assertIn("structured", why)

    def test_a_confident_slop_signature_is_dropped(self):
        for signature in ("blank_or_near_blank", "uniform_noise", "washed_flat",
                          "colour_explosion"):
            with self.subTest(signature=signature):
                verdict, _ = bucket(sidecar(signature, 0))
                self.assertEqual(verdict, "drop")

    def test_a_low_confidence_answer_is_escalated_not_resolved(self):
        verdict, why = bucket(sidecar("structured", 3, low=["slop_signature"]))
        self.assertEqual(verdict, "escalate")
        self.assertIn("floor", why)

    def test_a_below_floor_score_is_escalated_even_beside_a_confident_signature(self):
        # The floor gate reads BOTH question names, and the score half is the
        # one a reader is tempted to drop as redundant: a confident
        # `structured` signature beside a below-floor score reads as a
        # settled keep, when the number that would have to carry that
        # judgement is the one the service flagged. Escalation is the design.
        verdict, why = bucket(sidecar("structured", 3, low=["structure_score"]))
        self.assertEqual(verdict, "escalate")
        self.assertIn("floor", why)

    def test_a_signature_that_disagrees_with_the_score_is_escalated(self):
        # The case a single threshold would hide: the model says slop but scores
        # the structure high. Ordering the two rules would silently pick one.
        verdict, why = bucket(sidecar("uniform_noise", 3))
        self.assertEqual(verdict, "escalate")
        self.assertIn("disagrees", why)

    def test_an_unevidenced_answer_is_escalated(self):
        verdict, why = bucket(sidecar("structured", 3, unevidenced=["slop_signature"]))
        self.assertEqual(verdict, "escalate")
        self.assertIn("unevidenced", why)

    def test_an_unevidenced_score_is_escalated_too(self):
        # Same gate, the other half. Defensive today: the shipped vocabularies
        # only ever declare `requires` on prompt_adherence (and the MET-Meme
        # questions), so the fold never puts structure_score in `unevidenced`
        # -- the disjunct is a belt over a vocabulary that could change. Pinned
        # anyway, because a one-sided gate would read as deliberate when it is
        # an accident of today's question set.
        verdict, why = bucket(sidecar("structured", 3, unevidenced=["structure_score"]))
        self.assertEqual(verdict, "escalate")
        self.assertIn("unevidenced", why)

    def test_a_missing_answer_is_escalated(self):
        self.assertEqual(bucket(sidecar(None, None))[0], "escalate")

    def test_a_partial_answer_is_escalated_not_read_as_structured(self):
        # The signature is confident and structured, so only a missing-ANSWER
        # gate keeps this out of the keep branch. Reading the absent score as
        # anything but "no usable answer" would also put None into a `score
        # >= 2` comparison on the sloppy path, where it is a TypeError.
        verdict, why = bucket(sidecar("structured", None))
        self.assertEqual(verdict, "escalate")
        self.assertIn("no usable answer", why)
        self.assertEqual(bucket(sidecar(None, 3))[0], "escalate")

    def test_a_sidecar_with_no_recorded_floor_gets_the_default(self):
        # Defensive: the fold always writes verdict.confidence_floor, so the
        # 0.6 default is unreachable through a real sidecar. Pinned rather
        # than dropped, because a hand-built sidecar (a fixture, a caller in
        # another repo) that omits it must still be gated at 0.60 rather than
        # at whatever `floor` happened to be unset to.
        bare = {"answers": {"slop_signature": {"type": "choice", "choice": "structured"},
                            "structure_score": {"type": "score", "score": 3}},
                "verdict": {"low_confidence": ["structure_score"]}}
        verdict, why = bucket(bare)
        self.assertEqual(verdict, "escalate")
        self.assertIn("0.60", why)


class ConfidenceTest(unittest.TestCase):
    """The type-dependent confidence rule, which is easy to read backwards.

    A `choice` reports `answer_confidence` (the mass on the reported answer); a
    `score` reports `confidence: 0.0` and keeps its certainty in a distribution; a
    `noul` carries neither and its value IS P(true). Getting this wrong makes
    every score read as maximally uncertain — the trap the laya docs name
    explicitly — so each shape is pinned.
    """

    def test_a_choice_reports_its_answer_mass(self):
        self.assertEqual(
            slop_cannon.confidence_of({"type": "choice", "choice": "structured",
                                       "answer_confidence": 0.8123, "confidence": 0.4}),
            0.8123)

    def test_a_score_reports_its_distribution_not_its_zero_confidence(self):
        # `confidence: 0.0` on a score is not "no certainty"; reading it as the
        # certainty would flag every score answer as uncertain.
        self.assertEqual(
            slop_cannon.confidence_of({"type": "score", "score": 2,
                                       "confidence": 0.0,
                                       "probabilities": [0.05, 0.1, 0.7, 0.15]}),
            0.7)

    def test_a_noul_carries_no_confidence_at_all(self):
        self.assertIsNone(slop_cannon.confidence_of({"type": "noul", "noul": 0.62}))
        self.assertEqual(slop_cannon.noul_value({"type": "noul", "noul": 0.62}), 0.62)

    def test_the_unevidenced_answer_is_recorded_as_unevidenced(self):
        # prompt_adherence has no pixels to read, so it must come out None rather
        # than as a number a reader could mistake for a measurement.
        row = slop_cannon.row_from({
            "answers": {"slop_signature": {"type": "choice", "choice": "structured",
                                           "answer_confidence": 0.7},
                        "structure_score": {"type": "score", "score": 3,
                                            "probabilities": [0, 0, 0.2, 0.8]},
                        "has_structure": {"type": "noul", "noul": 0.71},
                        "prompt_adherence": {"type": "noul", "noul": 0.99}},
            "verdict": {"unevidenced": ["prompt_adherence"]}})
        self.assertEqual(row["signature"], "structured")
        self.assertEqual(row["score"], 3)
        self.assertEqual(row["score_confidence"], 0.8)
        self.assertEqual(row["p_has_structure"], 0.71)
        self.assertIsNone(row["p_prompt_adherence"],
                          "an unevidenced answer must not be reported as a value")
        self.assertEqual(row["unevidenced"], ["prompt_adherence"])


class EndpointTest(unittest.TestCase):
    """The failure that stopped the first bracket run, pinned.

    jev_annotate.py wants the FULL route (its own default is
    `https://api.typesafe.ai/v1/systemone`), and a bare base URL posts to the
    host root and comes back 404. Accepting both forms is the fix; this is what
    would notice if someone "simplified" it back.
    """

    def test_a_base_url_gets_the_route_appended(self):
        self.assertEqual(slop_cannon.systemone_url("http://host:8797"),
                         "http://host:8797/v1/systemone")
        self.assertEqual(slop_cannon.systemone_url("http://host:8797/"),
                         "http://host:8797/v1/systemone")

    def test_a_full_route_is_left_alone(self):
        for endpoint in ("http://host:8797/v1/systemone", "http://host:8797/v1/systemone/",
                         "https://api.typesafe.ai/v1/systemone"):
            with self.subTest(endpoint=endpoint):
                self.assertEqual(slop_cannon.systemone_url(endpoint).rstrip("/"),
                                 endpoint.rstrip("/"))
                # And never doubled, which is the bug a naive append would create.
                self.assertEqual(slop_cannon.systemone_url(endpoint).count("/v1/systemone"), 1)


class EndpointConfigTest(unittest.TestCase):
    """Where the services are comes from the ENVIRONMENT, and nothing else.

    The regression this pins is specific: both addresses were once argparse
    DEFAULTS holding a tailnet address. A default is worse than a stale doc,
    because `./slop_cannon.py` with no arguments then silently aimed at that one
    machine and reported "unreachable" — which reads as a network fault, so the
    operator debugs the network instead of the missing variable.
    """

    def test_the_flag_wins(self):
        with mock.patch.dict(os.environ, {slop_cannon.FLUX_ENDPOINT_ENV: "http://from-env"}, clear=False):
            self.assertEqual(
                slop_cannon.resolve_endpoint("http://from-flag",
                                             slop_cannon.FLUX_ENDPOINT_ENV,
                                             "the flux service"),
                "http://from-flag")

    def test_the_environment_is_read_when_no_flag_is_given(self):
        for variable in (slop_cannon.FLUX_ENDPOINT_ENV, slop_cannon.JEV_ENDPOINT_ENV):
            with self.subTest(variable=variable):
                with mock.patch.dict(os.environ, {variable: "http://from-env"}, clear=False):
                    self.assertEqual(slop_cannon.resolve_endpoint(None, variable, "svc"),
                                     "http://from-env")
                    # Blank is unset, not an endpoint: an empty env var must not
                    # become the base URL "".
                    with mock.patch.dict(os.environ, {variable: "  "}, clear=False):
                        with self.assertRaises(SlopError):
                            slop_cannon.resolve_endpoint(None, variable, "svc")

    def test_an_unset_endpoint_is_refused_by_naming_the_variable(self):
        for variable in (slop_cannon.FLUX_ENDPOINT_ENV, slop_cannon.JEV_ENDPOINT_ENV):
            with self.subTest(variable=variable):
                with mock.patch.dict(os.environ, {}, clear=True):
                    with self.assertRaises(SlopError) as caught:
                        slop_cannon.resolve_endpoint(None, variable, "the flux service")
                message = str(caught.exception)
                # Naming the variable is the whole point: an operator who sees
                # this knows the fix, and no host is named for them to guess at.
                self.assertIn(variable, message)
                self.assertIn("the flux service", message)

    def test_no_tracked_file_carries_a_host_fact(self):
        """The repo-wide half: no IPv4 literal in any tracked file.

        The per-function tests above would still pass if someone added a default
        somewhere else — a second script, a doc example that gets copy-pasted
        into a default. This is the fleet rule from chopshop-flux/AGENTS.md
        applied to the whole tree, and it is the check that would have caught
        the original two.
        """
        import re
        import subprocess

        tracked = subprocess.run(
            # `--others` too: a new file that has not been added yet is exactly
            # when a copy-pasted default is most likely to land, and a scan that
            # only saw committed files would pass straight over it.
            ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
            capture_output=True, text=True,
            cwd=Path(__file__).resolve().parent.parent, check=True).stdout.split()
        self.assertTrue(tracked, "git ls-files returned nothing")
        address = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
        # 127.0.0.1 is loopback: not a location, and the operator's own
        # redaction convention already treats it as such.
        loopback = "127.0.0.1"
        offenders = {}
        for name in tracked:
            path = Path(__file__).resolve().parent.parent / name
            try:
                text = path.read_text()
            except (UnicodeDecodeError, OSError):
                continue
            hits = {hit for hit in address.findall(text) if hit != loopback}
            if hits:
                offenders[name] = sorted(hits)
        self.assertEqual(offenders, {},
                         "host addresses in the tree: %s" % offenders)
class AnnotateCommandTest(unittest.TestCase):
    """The credential the harness resolves is FORWARDED to the annotator.

    `slop_cannon.main` accepts JEV_API_KEY *or* LAYA_API_KEY, while
    `jev_annotate.py` reads only the JEV_*/TYPESAFE_* names. Inheriting the
    environment is therefore not enough: a caller who exported the service's own
    key name would pass the harness's own check and then fail one level down,
    which reads as a broken annotator rather than a missing flag.
    """

    def _command(self, api_key):
        with tempfile.TemporaryDirectory() as tmp:
            sidecar = Path(tmp) / "artifact.jev.json"
            sidecar.write_text("{}")
            with mock.patch.object(slop_cannon.subprocess, "run") as run:
                run.return_value = subprocess.CompletedProcess([], 0, "", "")
                slop_cannon.annotate(Path(tmp) / "artifact.json", sidecar,
                                     profile="generation-slop",
                                     endpoint="http://host:8797",
                                     model="typed-decisions", api_key=api_key,
                                     timeout=30)
            return run.call_args[0][0]

    def test_a_resolved_key_reaches_the_annotator(self):
        command = self._command("a-token")
        self.assertIn("--api-key", command)
        self.assertEqual(command[command.index("--api-key") + 1], "a-token")
        # And the endpoint is normalised to the full route on the way through.
        self.assertIn("http://host:8797/v1/systemone", command)
        self.assertIn("generation-slop", command)

    def test_no_key_means_no_flag_at_all(self):
        command = self._command(None)
        self.assertNotIn("--api-key", command)


if __name__ == "__main__":
    unittest.main()
