#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The captioner seam (chopshop-jev#2): how a picture reaches a text model.

Three contracts, in the order the data travels:

  1. PROJECTOR — an artifact carrying `image.caption` makes `image_visible` true
     and puts the caption in the state; an artifact without one is byte-for-byte
     the state it was before the seam existed.
  2. HARNESS — `caption_image` posts the PNG bytes to the local service, and a
     captioner that is DOWN is recorded on the artifact instead of killing the
     run or being silently skipped.
  3. SERVICE — `caption_serve` refuses a non-loopback bind without a token,
     answers 401 before touching the model, and reports a missing dependency as
     a 503 with the package named.

No model is loaded here: these are the seams, tested without the weights.
"""

import base64
import json
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import caption_serve  # noqa: E402
import jev_annotate as jev  # noqa: E402
import slop_cannon  # noqa: E402
from slop_cannon import SlopError  # noqa: E402


def artifact(image=None, prompt="a frog on a skateboard"):
    body = {
        "prompt": prompt,
        "settings": {"seed": 1, "steps": 4, "model": "klein-4b",
                     "width": 512, "height": 512},
        "generation": {"model": "klein-4b", "raster": "frame.png"},
        "measurements": {"slop_edge_density": 0.12},
    }
    if image is not None:
        body["image"] = image
    return body


class CaptionedProjectorTest(unittest.TestCase):
    def test_a_caption_makes_the_evidence_visible_and_names_its_source(self):
        state = jev.project_artifact(artifact({"file": "frame.png",
                                               "caption": "a plush frog on a skateboard, photo style",
                                               "caption_model": "LiquidAI/LFM2.5-VL-450M"}))
        self.assertTrue(state["evidence"]["image_visible"])
        self.assertIn("image_caption", state)
        self.assertIn("plush frog", state["image_caption"])
        self.assertEqual(state["evidence"]["caption_by"], "LiquidAI/LFM2.5-VL-450M")
        self.assertIn("captioner", state["note"])

    def test_without_a_caption_the_state_is_exactly_what_it_used_to_be(self):
        before = jev.project_artifact(artifact({"file": "frame.png"}))
        self.assertFalse(before["evidence"]["image_visible"])
        self.assertNotIn("image_caption", before)
        self.assertIn("never pixels", before["note"])
        # and an artifact with no image block at all is the same claim
        plain = jev.project_artifact(artifact(None))
        self.assertFalse(plain["evidence"]["image_visible"])
        self.assertNotIn("image_caption", plain)

    def test_an_empty_caption_does_not_count_as_evidence(self):
        for blank in ("", "   ", None, 123):
            with self.subTest(blank=blank):
                state = jev.project_artifact(
                    artifact({"file": "frame.png", "caption": blank}))
                self.assertFalse(state["evidence"]["image_visible"],
                                 "a blank caption must not unlock the question")

    def test_the_caption_is_scrubbed_and_bounded(self):
        state = jev.project_artifact(artifact({
            "file": "frame.png",
            "caption": "a " + "very " * 400 + "long description"}))
        self.assertLessEqual(len(state["image_caption"]), 600)


class AdherenceBecomesAnswerableTest(unittest.TestCase):
    def _verdict(self, state, answer):
        answers = dict(jev.SLOP_QUESTIONS)
        answers = {name: dict(q) for name, q in answers.items()}
        got = {"prompt_adherence": answer}
        return jev.compose_annotation_verdict(got, answers, state,
                                              vocabulary="generation-slop")

    def test_with_a_caption_the_answer_is_reported_not_unevidenced(self):
        state = jev.project_artifact(artifact({
            "file": "frame.png",
            "caption": "a plush frog riding a skateboard on concrete"}))
        verdict = self._verdict(state, {"type": "noul", "noul": 0.7,
                                        "answer_confidence": 0.7})
        self.assertNotIn("prompt_adherence", verdict["unevidenced"])
        self.assertEqual(verdict["confidence"].get("prompt_adherence"), 0.7)

    def test_without_a_caption_it_stays_unevidenced(self):
        state = jev.project_artifact(artifact({"file": "frame.png"}))
        verdict = self._verdict(state, {"type": "noul", "noul": 0.7,
                                        "answer_confidence": 0.7})
        self.assertIn("prompt_adherence", verdict["unevidenced"])
        # The answer is recorded as UNANSWERED, never as a number.
        self.assertNotIn("prompt_adherence", verdict["confidence"])


# ---------------------------------------------------------------------------
# the harness's half: posting the bytes, and surviving a service that is down
# ---------------------------------------------------------------------------

class _CaptionStub(BaseHTTPRequestHandler):
    """Answers /caption; class-level `mode` picks the behaviour per test."""

    mode = "ok"

    def log_message(self, format, *args):  # quiet
        pass

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("content-length") or 0)
        self.rfile.read(length)
        if self.mode == "down":
            self.send_response(503)
            body = json.dumps({"detail": "loading"}).encode()
        elif self.mode == "unauthorised":
            self.send_response(401)
            body = json.dumps({"detail": "invalid or missing bearer token"}).encode()
        else:
            self.send_response(200)
            body = json.dumps({"caption": "a plush frog riding a skateboard",
                               "model": "stub-captioner"}).encode()
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class CaptionClientTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _CaptionStub)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = "http://127.0.0.1:%d" % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def test_a_caption_comes_back_with_its_model(self):
        _CaptionStub.mode = "ok"
        result = slop_cannon.caption_image(b"png-bytes", self.url)
        self.assertEqual(result["caption"], "a plush frog riding a skateboard")
        self.assertEqual(result["model"], "stub-captioner")

    def test_a_refusal_is_reported_with_the_services_own_message(self):
        _CaptionStub.mode = "unauthorised"
        with self.assertRaises(SlopError) as caught:
            slop_cannon.caption_image(b"png-bytes", self.url, api_key="wrong")
        self.assertIn("401", str(caught.exception))
        self.assertIn("token", str(caught.exception))

    def test_an_unreachable_service_is_a_refusal_not_a_traceback(self):
        with self.assertRaises(SlopError) as caught:
            slop_cannon.caption_image(b"png-bytes", "http://127.0.0.1:1",
                                      timeout=2)
        self.assertIn("unreachable", str(caught.exception))


class CaptionedBracketTest(unittest.TestCase):
    """main() with a captioner: on, off, and down."""

    @classmethod
    def setUpClass(cls):
        # Its OWN stub, so the class does not depend on another one having run
        # first — unittest orders classes by name, and a run of one file must
        # not be what decides whether this test works.
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _CaptionStub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = "http://127.0.0.1:%d" % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def _run(self, caption_endpoint=None):
        import tempfile
        tmp = tempfile.mkdtemp()
        prompt_file = Path(tmp) / "prompts.json"
        prompt_file.write_text(json.dumps(["a frog on a skateboard"]))
        out = Path(tmp) / "out"
        _CaptionStub.mode = "ok"

        def fake_generate(base, prompt, model, *, width, height, steps, guidance, seed):
            return (b"png-bytes", {"model": model, "seed": seed, "steps": steps or 4,
                                   "guidance": guidance, "width": width, "height": height,
                                   "raster": "raster.png", "total_seconds": 1.0})

        argv = ["--prompts", str(prompt_file), "--models", "model-a",
                "--out", str(out), "--endpoint", "http://flux.invalid",
                "--jev-endpoint", "http://decision.invalid"]
        if caption_endpoint:
            argv += ["--caption-endpoint", caption_endpoint]

        import io
        from contextlib import redirect_stdout
        buffer = io.StringIO()
        with mock.patch.object(slop_cannon, "generate", fake_generate), \
             mock.patch.object(slop_cannon, "measure_raster",
                               lambda raw: {"slop_edge_density": 0.1}), \
             mock.patch.object(slop_cannon, "annotate",
                               lambda *a, **k: {"answers": {}, "verdict": {}}), \
             mock.patch.dict(os.environ, {"JEV_API_KEY": "stub-key"}, clear=False), \
             redirect_stdout(buffer):
            code = slop_cannon.main(argv)
        artifact_json = json.loads(
            sorted(out.glob("*.artifact.json"))[0].read_text())
        return code, buffer.getvalue(), artifact_json

    def test_with_a_captioner_the_artifact_carries_the_caption(self):
        code, stdout, body = self._run(self.url)
        self.assertEqual(code, 0)
        self.assertIn("caption", body["image"])
        self.assertEqual(body["image"]["caption_model"], "stub-captioner")
        self.assertNotIn("caption_error", body["image"])
        # and the projector then unlocks the evidence it needs
        self.assertTrue(jev.project_artifact(body)["evidence"]["image_visible"])

    def test_without_one_the_run_says_so_and_the_artifact_is_plain(self):
        code, stdout, body = self._run(None)
        self.assertEqual(code, 0)
        self.assertIn("not configured", stdout)
        self.assertNotIn("caption", body["image"])
        self.assertFalse(jev.project_artifact(body)["evidence"]["image_visible"])

    def test_a_captioner_that_is_down_is_recorded_and_the_run_survives(self):
        code, stdout, body = self._run("http://127.0.0.1:1")
        self.assertEqual(code, 0, "a down captioner must not cost the bracket")
        self.assertIn("caption_error", body["image"])
        self.assertIn("unreachable", body["image"]["caption_error"])
        # recorded, so "we never asked" and "it was down" stay distinguishable
        self.assertFalse(jev.project_artifact(body)["evidence"]["image_visible"])


# ---------------------------------------------------------------------------
# the service's half: config rules, auth, and a missing dependency as a 503
# ---------------------------------------------------------------------------

class CaptionServiceTest(unittest.TestCase):
    def setUp(self):
        self._config = dict(caption_serve.CONFIG)
        self._loaded = dict(caption_serve.LOADED)

    def tearDown(self):
        caption_serve.CONFIG.clear()
        caption_serve.CONFIG.update(self._config)
        caption_serve.LOADED.clear()
        caption_serve.LOADED.update(self._loaded)

    def test_a_non_loopback_bind_without_a_token_is_refused_at_start(self):
        # A non-loopback NAME, not an address: the sweep this test lives under
        # rejects every IPv4 literal but 127.0.0.1, and a wildcard IP would be a
        # host-shaped fact in a file that must not carry one.
        with mock.patch.dict(os.environ, {"CAPTION_HOST": "caption.internal",
                                          "CAPTION_API_KEY": ""},
                             clear=False):
            with self.assertRaises(SystemExit) as caught:
                caption_serve.configure_from_env()
        self.assertIn("CAPTION_API_KEY", str(caught.exception))

    def test_loopback_needs_no_token_and_reads_the_model(self):
        with mock.patch.dict(os.environ, {"CAPTION_HOST": "127.0.0.1",
                                          "CAPTION_MODEL": "some/model",
                                          "CAPTION_PORT": "9000"}, clear=False):
            os.environ.pop("CAPTION_API_KEY", None)
            config = caption_serve.configure_from_env()
        self.assertEqual(config["model"], "some/model")
        self.assertEqual(config["port"], 9000)
        self.assertIsNone(config["key"])

    def test_the_handler_answers_health_and_enforces_the_token(self):
        caption_serve.CONFIG.update({"key": "sekrit", "model": "m", "device": "cpu",
                                     "preload": False, "max_new_tokens": 8,
                                     "prompt": "describe", "port": 0,
                                     "host": "127.0.0.1"})
        caption_serve.LOADED.update({"ready": False, "error": None,
                                     "model": None, "processor": None,
                                     "load_seconds": None})
        server = ThreadingHTTPServer(("127.0.0.1", 0), caption_serve.CaptionHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = "http://127.0.0.1:%d" % server.server_address[1]
        try:
            import urllib.request
            with urllib.request.urlopen(base + "/health", timeout=5) as response:
                health = json.loads(response.read())
            self.assertEqual(health["status"], "ok")
            self.assertTrue(health["auth_required"])

            # no token -> 401, and it never gets as far as loading a model
            request = urllib.request.Request(
                base + "/caption", data=b'{"image_b64": "aGk="}', method="POST",
                headers={"content-type": "application/json"})
            try:
                urllib.request.urlopen(request, timeout=5)
                self.fail("an unauthenticated caption was served")
            except urllib.error.HTTPError as exc:
                self.assertEqual(exc.code, 401)
        finally:
            server.shutdown()
            server.server_close()

    def test_a_missing_dependency_becomes_a_named_503_not_a_traceback(self):
        # The repo venv has no transformers, which is exactly the state a fresh
        # box is in: the service must say WHICH package is missing.
        caption_serve.CONFIG.update({"model": "LiquidAI/LFM2.5-VL-450M",
                                     "device": "cpu", "key": None,
                                     "preload": False, "max_new_tokens": 8,
                                     "prompt": "describe", "port": 0,
                                     "host": "127.0.0.1"})
        caption_serve.LOADED.update({"ready": False, "error": None,
                                     "model": None, "processor": None,
                                     "load_seconds": None})
        state = caption_serve.load_model()
        if state["error"]:
            self.assertIn("transformers", state["error"])
        else:
            # transformers IS available (running under the GPU venv) — then the
            # loader must have succeeded rather than half-failed.
            self.assertTrue(state["ready"])


if __name__ == "__main__":
    unittest.main()
