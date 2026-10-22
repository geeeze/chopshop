#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The bracket's DESIGN, which is what chopshop-jev#3 is actually about.

The first bracket proved the pipeline and then could not rank anything: 4
prompts x 3 models, ONE seed per cell, and a between-model spread (0.008) an
order of magnitude under the within-model spread (0.03-0.04) that was never
reported beside it. Three things are pinned here so the next run cannot repeat
that by accident:

  1. `--seeds` multiplies the cells, so "within a model" is a sample rather
     than a range over n=1.
  2. `spread_report` computes BETWEEN vs WITHIN per measure and says which side
     is larger — the report the issue asks for, made mechanical.
  3. `prompts_from_diffusiondb` draws prompts from the WHOLE slice, seeded, so
     the sample is not one author's batch wearing the models' names.

Nothing here touches the network or the GPU: `main()` is driven with the
service calls stubbed.
"""

import json
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import prompts_from_diffusiondb as extractor  # noqa: E402
import slop_cannon  # noqa: E402
from slop_cannon import SlopError, parse_seeds, spread_report  # noqa: E402


# ---------------------------------------------------------------------------
# 1. seeds
# ---------------------------------------------------------------------------

class SeedsTest(unittest.TestCase):
    def test_a_comma_list_becomes_several_seeds(self):
        self.assertEqual(parse_seeds("4242,4243,4244"), [4242, 4243, 4244])

    def test_a_bare_number_is_one_seed(self):
        self.assertEqual(parse_seeds("7"), [7])

    def test_surrounding_space_is_not_a_new_number(self):
        self.assertEqual(parse_seeds(" 1 , 2 "), [1, 2])

    def test_the_key_source_is_announced_when_both_names_are_set(self):
        """A hosted key sent to a local service is a 401 that blames the wrong
        thing; the run says which name it used before any request goes out."""
        import io
        from contextlib import redirect_stdout

        # The decision-service env is scrubbed, not merged: the developer's own
        # CHOPSHOP_OPENROUTER_KEY/JEV_API_KEY in the shell would otherwise
        # outrank the keys this test names and the assertions would test the
        # developer's box instead of the code.
        decision_env = {name: "" for name in (
            "JEV_API_KEY", "TYPESAFE_API_KEY", "LAYA_API_KEY",
            "CHOPSHOP_OPENROUTER_KEY", "JEV_MODEL", "JEV_ENDPOINT")}

        def run(env):
            prompt_file = Path(tempfile.mkdtemp()) / "p.json"
            prompt_file.write_text(json.dumps(["x"]))
            out = prompt_file.parent / "out"
            with mock.patch.object(slop_cannon, "generate",
                                   lambda *a, **k: (b"x", {
                                       "model": "m", "seed": k["seed"], "steps": 4,
                                       "guidance": None, "width": 512, "height": 512,
                                       "raster": "r.png", "total_seconds": 1.0})), \
                 mock.patch.object(slop_cannon, "measure_raster",
                                   lambda raw: {"slop_edge_density": 0.1}), \
                 mock.patch.object(slop_cannon, "annotate",
                                   lambda *a, **k: json.loads(json.dumps(CANNED_ANSWERS))), \
                 mock.patch.dict(os.environ, {**decision_env, **env}, clear=False):
                buffer = io.StringIO()
                with redirect_stdout(buffer):
                    code = slop_cannon.main([
                        "--prompts", str(prompt_file), "--models", "m",
                        "--out", str(out), "--endpoint", "http://flux.invalid",
                        "--jev-endpoint", "http://decision.invalid"])
            return code, buffer.getvalue()

        import tempfile
        code, stdout = run({"JEV_API_KEY": "hosted-key", "LAYA_API_KEY": "local-key"})
        self.assertEqual(code, 0)
        self.assertIn("BOTH set and differ", stdout)
        self.assertIn("using JEV_API_KEY", stdout)

        code, stdout = run({"LAYA_API_KEY": "local-key"})
        self.assertEqual(code, 0)
        self.assertIn("decision key: $LAYA_API_KEY", stdout)
        self.assertNotIn("BOTH set", stdout)

    def test_garbage_is_refused_by_name(self):
        for bad in ("1,two", "abc", "1.5"):
            with self.subTest(bad=bad):
                with self.assertRaises(SlopError) as caught:
                    parse_seeds(bad)
                self.assertIn("--seeds", str(caught.exception))

    def test_an_empty_list_is_refused(self):
        with self.assertRaises(SlopError):
            parse_seeds(" , ,")

    def test_model_steps_are_per_model_not_global(self):
        from slop_cannon import parse_model_steps
        self.assertEqual(parse_model_steps("klein-4b=12,klein-4b-base=12"),
                         {"klein-4b": 12, "klein-4b-base": 12})
        self.assertEqual(parse_model_steps(None), {})
        self.assertEqual(parse_model_steps(""), {})
        for bad in ("klein-4b", "klein-4b=x", "klein-4b=0"):
            with self.subTest(bad=bad):
                with self.assertRaises(SlopError) as caught:
                    parse_model_steps(bad)
                self.assertIn("--model-steps", str(caught.exception))


# ---------------------------------------------------------------------------
# 2. between vs within
# ---------------------------------------------------------------------------

def _row(model, seed, struct, field, score, edge):
    return {
        "model": model, "seed": seed,
        "p_has_structure": struct, "p_dominant_field": field, "score": score,
        "measurements": {"slop_edge_density": edge},
    }


class SpreadTest(unittest.TestCase):
    def test_between_exceeding_within_reports_separates(self):
        rows = [
            _row("a", 1, 0.80, 0.5, 2.0, 0.20),
            _row("a", 2, 0.82, 0.5, 2.0, 0.22),
            _row("b", 1, 0.30, 0.5, 1.0, 0.05),
            _row("b", 2, 0.28, 0.5, 1.0, 0.07),
        ]
        report = spread_report(rows)
        self.assertTrue(report["P(struct)"]["separates"])
        self.assertAlmostEqual(report["P(struct)"]["between"], 0.52, places=4)
        self.assertAlmostEqual(report["P(struct)"]["within_avg"], 0.02, places=4)

    def test_within_exceeding_between_reports_does_not_separate(self):
        """The first bracket's shape: a tiny difference drowned by the noise."""
        rows = [
            _row("a", 1, 0.50, 0.5, 2.0, 0.10),
            _row("a", 2, 0.54, 0.5, 2.0, 0.14),
            _row("b", 1, 0.51, 0.5, 2.0, 0.11),
            _row("b", 2, 0.53, 0.5, 2.0, 0.13),
        ]
        report = spread_report(rows)
        entry = report["P(struct)"]
        self.assertFalse(entry["separates"])
        self.assertLess(entry["between"], entry["within_avg"])
        # And the means are still reported — the reader checks the claim.
        self.assertEqual(sorted(entry["means"]), ["a", "b"])

    def test_one_model_reports_none_rather_than_zero(self):
        rows = [_row("only", 1, 0.5, 0.5, 1.0, 0.1),
                _row("only", 2, 0.6, 0.5, 1.0, 0.2)]
        self.assertIsNone(spread_report(rows)["P(struct)"])

    def test_a_measure_nothing_reports_is_none_not_a_crash(self):
        rows = [_row("a", 1, None, None, None, 0.10),
                _row("a", 2, None, None, None, 0.12),
                _row("b", 1, None, None, None, 0.40),
                _row("b", 2, None, None, None, 0.42)]
        report = spread_report(rows)
        self.assertIsNone(report["P(struct)"],
                          "no answer means no spread to report, not 0.0000")
        # the deterministic measurement still has two models, two draws each
        entry = report["edge density"]
        self.assertIsNotNone(entry)
        self.assertTrue(entry["separates"])
        self.assertAlmostEqual(entry["between"], 0.30, places=4)
        self.assertAlmostEqual(entry["within_avg"], 0.02, places=4)

    def test_a_single_draw_per_model_has_no_within_and_says_so(self):
        rows = [_row("a", 1, 0.8, 0.5, 2.0, 0.2),
                _row("b", 1, 0.3, 0.5, 1.0, 0.1)]
        entry = spread_report(rows)["P(struct)"]
        self.assertIsNone(entry["within_avg"])
        # n records what each side actually rests on, so n=1 is visible.
        self.assertEqual(entry["n"], {"a": 1, "b": 1})
        self.assertFalse(entry["separates"], "no within-spread means no claim")


# ---------------------------------------------------------------------------
# 3. the loop main() runs: prompts x models x seeds
# ---------------------------------------------------------------------------

CANNED_ANSWERS = {
    "answers": {
        "slop_signature": {"type": "choice", "choice": "structured",
                           "answer_confidence": 0.9},
        "structure_score": {"type": "score", "score": 2.0,
                            "answer_confidence": 0.9},
        "has_structure": {"type": "noul", "noul": 0.8},
        "dominant_field": {"type": "noul", "noul": 0.6},
        "prompt_adherence": {"type": "noul", "noul": 0.5},
    },
    "verdict": {"confidence_floor": 0.6, "low_confidence": [],
                "unevidenced": ["prompt_adherence"]},
}


def run_bracket(tmp, prompts, seeds_flag):
    """main() with every service call stubbed; returns (code, stdout, rows)."""
    prompt_file = Path(tmp) / "prompts.json"
    prompt_file.write_text(json.dumps([{"prompt": p} for p in prompts]))
    out = Path(tmp) / "out"

    calls = {"generations": []}

    def fake_generate(base, prompt, model, *, width, height, steps, guidance, seed):
        calls["generations"].append({"prompt": prompt, "model": model, "seed": seed})
        name = "raster-%d.png" % len(calls["generations"])
        return (b"png-bytes", {"model": model, "seed": seed, "steps": steps or 4,
                               "guidance": guidance, "width": width, "height": height,
                               "raster": name, "total_seconds": 1.0})

    argv = ["--prompts", str(prompt_file), "--models", "model-a,model-b",
            "--out", str(out), "--endpoint", "http://flux.invalid",
            "--jev-endpoint", "http://decision.invalid", "--seeds", seeds_flag]

    import io
    from contextlib import redirect_stdout
    buffer = io.StringIO()
    with mock.patch.object(slop_cannon, "generate", fake_generate), \
         mock.patch.object(slop_cannon, "measure_raster",
                           lambda raw: {"slop_edge_density": 0.1,
                                       "slop_noise_ratio": 1.0}), \
         mock.patch.object(slop_cannon, "annotate",
                           lambda *a, **k: json.loads(json.dumps(CANNED_ANSWERS))), \
         mock.patch.dict(os.environ, {"JEV_API_KEY": "stub-key"}), \
         redirect_stdout(buffer):
        code = slop_cannon.main(argv)
    rows = json.loads((out / "slop-cannon-results.json").read_text())
    return code, buffer.getvalue(), rows, calls, out


class BracketLoopTest(unittest.TestCase):
    def test_seeds_multiply_the_cells_and_each_row_records_its_seed(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            code, stdout, rows, calls, out = run_bracket(
                tmp, ["prompt one", "prompt two"], "11,22,33")

            self.assertEqual(code, 0)
            self.assertEqual(len(rows), 2 * 2 * 3, "prompts x models x seeds")
            self.assertEqual(sorted({r["seed"] for r in rows}), [11, 22, 33])
            self.assertEqual(len(calls["generations"]), 12)

            # every cell is reported, and the spread lands beside the results
            self.assertIn("=== spread: between-model vs within-model ===", stdout)
            self.assertIn("does NOT separate", stdout)
            spread = json.loads((out / "slop-cannon-spread.json").read_text())
            self.assertEqual(spread["seeds"], [11, 22, 33])
            self.assertEqual(spread["prompts"], 2)
            self.assertEqual(spread["rasters"], 12)
            self.assertIn("P(struct)", spread["report"])

    def test_a_prompt_with_its_own_seed_keeps_it(self):
        """The list's seed beats the flag: a deliberate seed in the prompt file
        must not be silently replaced by the bracket's own sequence."""
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            prompt_file = Path(tmp) / "prompts.json"
            prompt_file.write_text(json.dumps([
                {"prompt": "free prompt"},
                {"prompt": "pinned prompt", "seed": 777},
            ]))
            out = Path(tmp) / "out"
            with mock.patch.object(slop_cannon, "generate",
                                   lambda *a, **k: (b"x", {
                                       "model": "m", "seed": k["seed"], "steps": 4,
                                       "guidance": None, "width": 512, "height": 512,
                                       "raster": "r.png", "total_seconds": 1.0})), \
                 mock.patch.object(slop_cannon, "measure_raster",
                                   lambda raw: {"slop_edge_density": 0.1}), \
                 mock.patch.object(slop_cannon, "annotate",
                                   lambda *a, **k: json.loads(json.dumps(CANNED_ANSWERS))), \
                 mock.patch.dict(os.environ, {"JEV_API_KEY": "stub-key"}):
                code = slop_cannon.main(["--prompts", str(prompt_file),
                                         "--models", "model-a", "--out", str(out),
                                         "--endpoint", "http://flux.invalid",
                                         "--jev-endpoint", "http://decision.invalid",
                                         "--seeds", "1,2"])
            self.assertEqual(code, 0)
            rows = json.loads((out / "slop-cannon-results.json").read_text())
            by_prompt = {r["prompt"]: r["seed"] for r in rows}
            self.assertEqual(by_prompt["pinned prompt"], 777)
            self.assertEqual(by_prompt["free prompt"], 2,
                             "an unpinned prompt runs every requested seed")

    def test_the_default_single_seed_still_works_without_the_flag(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            prompt_file = Path(tmp) / "prompts.json"
            prompt_file.write_text(json.dumps(["only prompt"]))
            out = Path(tmp) / "out"
            with mock.patch.object(slop_cannon, "generate",
                                   lambda *a, **k: (b"x", {
                                       "model": k.get("model") or "m", "seed": k["seed"],
                                       "steps": 4, "guidance": None, "width": 512,
                                       "height": 512, "raster": "r.png",
                                       "total_seconds": 1.0})), \
                 mock.patch.object(slop_cannon, "measure_raster",
                                   lambda raw: {"slop_edge_density": 0.1}), \
                 mock.patch.object(slop_cannon, "annotate",
                                   lambda *a, **k: json.loads(json.dumps(CANNED_ANSWERS))), \
                 mock.patch.dict(os.environ, {"JEV_API_KEY": "stub-key"}):
                code = slop_cannon.main(["--prompts", str(prompt_file),
                                         "--models", "model-a", "--out", str(out),
                                         "--endpoint", "http://flux.invalid",
                                         "--jev-endpoint", "http://decision.invalid"])
            self.assertEqual(code, 0)
            rows = json.loads((out / "slop-cannon-results.json").read_text())
            self.assertEqual([r["seed"] for r in rows], [4242])


# ---------------------------------------------------------------------------
# 4. one transient refusal must not cost the bracket
# ---------------------------------------------------------------------------

class AnnotateRetryTest(unittest.TestCase):
    def test_a_transient_failure_is_retried_and_then_returns(self):
        from pathlib import Path as P
        calls = {"n": 0}

        def flaky(*args, **kwargs):
            calls["n"] += 1
            if calls["n"] < 3:
                raise SlopError("Jev HTTP 401: invalid or missing bearer token")
            return {"answers": {}, "verdict": {}}

        with mock.patch.object(slop_cannon, "annotate", flaky):
            result = slop_cannon.annotate_with_retry(
                P("a.json"), P("b.json"), attempts=3, delay=0.01,
                profile="p", endpoint="e", model="m", api_key="k", timeout=1)
        self.assertEqual(result, {"answers": {}, "verdict": {}})
        self.assertEqual(calls["n"], 3)

    def test_a_genuine_refusal_still_surfaces_after_the_attempts(self):
        from pathlib import Path as P
        calls = {"n": 0}

        def always_fails(*args, **kwargs):
            calls["n"] += 1
            raise SlopError("Jev HTTP 422: question has an unsupported type")

        with mock.patch.object(slop_cannon, "annotate", always_fails):
            with self.assertRaises(SlopError) as caught:
                slop_cannon.annotate_with_retry(
                    P("a.json"), P("b.json"), attempts=3, delay=0.01,
                    profile="p", endpoint="e", model="m", api_key="k", timeout=1)
        self.assertEqual(calls["n"], 3, "it used every attempt then gave up")
        self.assertIn("unsupported type", str(caught.exception),
                      "the service's own message is what the operator needs")

    def test_one_attempt_is_allowed_and_means_no_retry(self):
        from pathlib import Path as P
        calls = {"n": 0}

        def fails_once(*args, **kwargs):
            calls["n"] += 1
            raise SlopError("boom")

        with mock.patch.object(slop_cannon, "annotate", fails_once):
            with self.assertRaises(SlopError):
                slop_cannon.annotate_with_retry(
                    P("a.json"), P("b.json"), attempts=1, delay=0.01,
                    profile="p", endpoint="e", model="m", api_key="k", timeout=1)
        self.assertEqual(calls["n"], 1)


# ---------------------------------------------------------------------------
# 5. the extractor that feeds it
# ---------------------------------------------------------------------------

class ExtractorTest(unittest.TestCase):
    def _slice(self, tmp, count=20):
        path = Path(tmp) / "metadata.jsonl"
        path.write_text("\n".join(
            json.dumps({"prompt": "prompt number %d" % i, "cfg": 5.0})
            for i in range(count)) + "\n")
        return path

    def test_a_plain_slice_is_read_and_written_as_a_prompt_list(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            source = self._slice(tmp)
            out = Path(tmp) / "prompts.json"
            code = extractor.main(["--dataset", str(source), "--out", str(out),
                                   "--limit", "5"])
            self.assertEqual(code, 0)
            prompts = json.loads(out.read_text())
            self.assertEqual(len(prompts), 5)
            self.assertTrue(all(set(p) == {"prompt"} for p in prompts))
            self.assertTrue(all(p["prompt"].startswith("prompt number ")
                                for p in prompts))

    def test_the_same_seed_draws_the_same_prompts(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            source = self._slice(tmp, count=40)
            first, second, third = (Path(tmp) / n for n in ("a.json", "b.json", "c.json"))
            for out in (first, second, third):
                extractor.main(["--dataset", str(source), "--out", str(out),
                                "--limit", "7", "--seed", "99"])
            self.assertEqual(first.read_text(), second.read_text())
            # and the draw comes from across the file, not just its head
            drawn = {p["prompt"] for p in json.loads(first.read_text())}
            self.assertTrue(any("39" in d for d in drawn),
                            "the sample never reached the end of the slice")
            extractor.main(["--dataset", str(source), "--out", str(third),
                            "--limit", "7", "--seed", "100"])
            self.assertNotEqual(first.read_text(), third.read_text())

    def test_min_length_filters_short_prompts(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "m.jsonl"
            source.write_text("\n".join([
                json.dumps({"prompt": "tiny"}),
                json.dumps({"prompt": "a prompt long enough to survive"}),
            ]) + "\n")
            out = Path(tmp) / "out.json"
            extractor.main(["--dataset", str(source), "--out", str(out),
                            "--limit", "0", "--min-length", "10"])
            prompts = json.loads(out.read_text())
            self.assertEqual([p["prompt"] for p in prompts],
                             ["a prompt long enough to survive"])

    def test_a_missing_dataset_is_refused_by_name(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            code = extractor.main(["--dataset", str(Path(tmp) / "nope.jsonl"),
                                   "--out", str(Path(tmp) / "out.json")])
            self.assertEqual(code, 2)

    @unittest.skipUnless(shutil.which("zstdcat"), "zstdcat not on PATH")
    def test_a_zstd_slice_is_decoded_through_the_cli(self):
        """The path a real run takes: the compressed slice, streamed."""
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            plain = Path(tmp) / "slice.jsonl"
            plain.write_text("\n".join(
                json.dumps({"prompt": "row %d" % i}) for i in range(12)) + "\n")
            packed = Path(tmp) / "slice.jsonl.zst"
            with packed.open("wb") as handle:
                subprocess.run(["zstd", "-q", "-f", "-o", str(packed), str(plain)],
                               check=True, capture_output=True)
            out = Path(tmp) / "out.json"
            code = extractor.main(["--dataset", str(packed), "--out", str(out),
                                   "--limit", "0"])
            self.assertEqual(code, 0)
            prompts = json.loads(out.read_text())
            self.assertEqual(len(prompts), 12)
            self.assertEqual(prompts[0]["prompt"], "row 0")


if __name__ == "__main__":
    unittest.main()
