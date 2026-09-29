"""The serve contract, exercised over a real socket.

No GPU, no network beyond loopback, nothing outside the standard library: the
engine is injected, which is the property that makes this suite portable. It is
also the contract that matters most, because the studio drives this package over
HTTP -- the CLI and the service are the same operation functions, and these
tests pin that they stay the same set.

Two engine fixtures are used on purpose. A STUB proves the plumbing (routing,
the envelope, status codes, the size cap, the token) without a renderer; the
REAL engine proves the wiring (that a spec crossing HTTP draws the same SVG the
CLI would write), so neither can pass while the other is broken.
"""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest import mock

from chopshop_plot import config
from chopshop_plot.digest import digest
from chopshop_plot.generate import generate
from chopshop_plot.log import log
from chopshop_plot.metrics import METRICS_VERSION
from chopshop_plot.query import query
from chopshop_plot.server import OPERATIONS, PlotEngine, build_server
from chopshop_plot.spec import SpecError, unwrap_payload
from chopshop_plot.tree import tree

from fixtures import two_source_two_recipe_runs

REPO_ROOT = Path(__file__).resolve().parent.parent

MARKER = ('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" '
          'viewBox="0 0 10 10"></svg>')

GEOMETRY = {
    "canvas": {"width": 120, "height": 80},
    "elements": [{"type": "circle", "cx": 40, "cy": 40, "r": 20, "fill": "#333333"}],
}

BAR = {"chart": "bar", "data": {"labels": ["a", "b"], "values": [1, 3]}}

HIERARCHY = {
    "nodes": [{"id": "a", "label": "a", "kind": "root"},
              {"id": "b", "label": "b", "kind": "tool"}],
    "edges": [{"from": "a", "to": "b"}],
}

EVENTS = {"events": [{"t": "00:00:01", "kind": "start", "label": "started", "pos": 1}]}


class StubEngine:
    """Stands in for PlotEngine: the same surface, no renderer behind it.

    It records what crossed the HTTP boundary, so a test can assert the spec
    arrived intact rather than assume it did.
    """

    def __init__(self):
        self.calls = []

    def status(self):
        return {"operations": ["generate", "digest", "query"], "metrics_version": 7}

    def generate(self, spec):
        self.calls.append(("generate", spec))
        return MARKER

    def digest(self, spec):
        self.calls.append(("digest", spec))
        return MARKER

    def query(self, runs, spec):
        self.calls.append(("query", runs, spec))
        return MARKER

    def tree(self, spec):
        self.calls.append(("tree", spec))
        return MARKER

    def log(self, spec):
        self.calls.append(("log", spec))
        return MARKER


class LiveServerTest(unittest.TestCase):
    """A running server on an ephemeral port. Subclasses choose the engine."""

    def make_engine(self):
        raise NotImplementedError

    def setUp(self):
        self.engine = self.make_engine()
        self.server = build_server(self.engine, bind="127.0.0.1", port=0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    # -- one request helper, so every test reads the same way --------------

    def request(self, route, payload=None, raw_body=None, token=None, method=None):
        """Return (status, raw_bytes, content_type). Never raises on 4xx/5xx."""
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer %s" % token
        if raw_body is not None:
            data = raw_body
        elif payload is not None:
            data = json.dumps(payload).encode("utf-8")
        else:
            data = None
        req = urllib.request.Request(self.base + route, data=data, headers=headers,
                                     method=method)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return resp.status, resp.read(), resp.headers.get("Content-Type")
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read(), exc.headers.get("Content-Type")

    def call(self, route, payload=None, **kwargs):
        status, body, ctype = self.request(route, payload=payload, **kwargs)
        return status, json.loads(body), ctype

    def with_env(self, **values):
        """Set (or clear, with None) environment variables, and put them back."""
        originals = {name: os.environ.get(name) for name in values}
        for name, value in values.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

        def restore():
            for name, original in originals.items():
                if original is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = original

        self.addCleanup(restore)


class StubEngineOverHTTPTest(LiveServerTest):
    """The plumbing: routing, the envelope, status codes, limits, the token."""

    def make_engine(self):
        return StubEngine()

    # -- health -----------------------------------------------------------

    def test_health_reports_the_service_and_its_engine(self):
        status, body, _ = self.call("/health", method="GET")
        self.assertEqual(status, 200)
        self.assertIs(body["ok"], True)
        self.assertEqual(body["service"], "chopshop-bp")
        self.assertEqual(body["engine"]["metrics_version"], 7)
        self.assertIs(body["auth_required"], False)

    def test_an_unknown_route_is_a_404_not_a_500(self):
        status, body, _ = self.call("/nope", payload={})
        self.assertEqual(status, 404)
        self.assertEqual(body["kind"], "not_found")

    def test_an_unknown_get_route_is_a_404_too(self):
        status, body, _ = self.call("/nope", method="GET")
        self.assertEqual(status, 404)
        self.assertEqual(body["kind"], "not_found")

    # -- the operations, through a stub ------------------------------------

    def test_generate_takes_a_bare_spec_and_returns_svg(self):
        status, body, ctype = self.request("/generate", payload=GEOMETRY)
        self.assertEqual(status, 200)
        self.assertEqual(body.decode("utf-8"), MARKER)
        self.assertIn("image/svg+xml", ctype)
        self.assertEqual(self.engine.calls, [("generate", GEOMETRY)])

    def test_the_op_envelope_is_unwrapped(self):
        status, _, _ = self.request("/generate",
                                    payload={"op": "generate", "spec": GEOMETRY})
        self.assertEqual(status, 200)
        self.assertEqual(self.engine.calls, [("generate", GEOMETRY)])

    def test_an_envelope_for_the_wrong_op_is_rejected(self):
        status, body, _ = self.call("/digest", payload={"op": "generate", "spec": GEOMETRY})
        self.assertEqual(status, 400)
        self.assertEqual(body["kind"], "invalid_spec")
        self.assertIn("op='generate'", body["error"])
        self.assertEqual(self.engine.calls, [], "nothing is drawn for a mismatch")

    def test_digest_and_generate_are_separate_routes(self):
        self.request("/digest", payload=BAR)
        self.assertEqual(self.engine.calls, [("digest", BAR)])

    def test_tree_and_log_are_their_own_routes(self):
        self.request("/tree", payload=HIERARCHY)
        self.request("/log", payload=EVENTS)
        self.assertEqual(self.engine.calls, [("tree", HIERARCHY), ("log", EVENTS)])

    def test_the_diagram_routes_unwrap_the_envelope_too(self):
        status, _, _ = self.request("/tree", payload={"op": "tree", "spec": HIERARCHY})
        self.assertEqual(status, 200)
        self.request("/log", payload={"op": "log", "spec": EVENTS})
        self.assertEqual(self.engine.calls, [("tree", HIERARCHY), ("log", EVENTS)])

    def test_a_tree_envelope_sent_to_log_is_rejected(self):
        status, body, _ = self.call("/log", payload={"op": "tree", "spec": HIERARCHY})
        self.assertEqual(status, 400)
        self.assertEqual(body["kind"], "invalid_spec")
        self.assertIn("op='tree'", body["error"])

    def test_query_carries_runs_and_a_spec(self):
        runs = two_source_two_recipe_runs()
        spec = {"chart": "scatter", "x": "node_count_max", "y": "mae_art"}
        status, _, _ = self.request("/query",
                                    payload={"op": "query", "runs": runs, "spec": spec})
        self.assertEqual(status, 200)
        self.assertEqual(self.engine.calls, [("query", runs, spec)])

    def test_query_accepts_one_bare_run_record(self):
        run = two_source_two_recipe_runs()[0]
        spec = {"chart": "scatter", "x": "node_count_max", "y": "mae_art"}
        status, _, _ = self.request("/query", payload={"runs": run, "spec": spec})
        self.assertEqual(status, 200)
        self.assertEqual(self.engine.calls, [("query", [run], spec)],
                         "a single record is a set of one, not a type error")

    def test_query_accepts_a_bare_chart_spec_beside_runs(self):
        runs = two_source_two_recipe_runs()
        status, _, _ = self.request("/query",
                                    payload={"runs": runs, "chart": "pareto",
                                             "x": "hard", "y": "file_size"})
        self.assertEqual(status, 200)
        _, got_runs, got_spec = self.engine.calls[-1]
        self.assertEqual(got_runs, runs)
        self.assertEqual(got_spec, {"chart": "pareto", "x": "hard", "y": "file_size"},
                         "'runs' is transport; what is left is the spec")

    def test_query_without_runs_is_a_caller_error(self):
        status, body, _ = self.call("/query", payload={"spec": BAR})
        self.assertEqual(status, 400)
        self.assertEqual(body["kind"], "bad_request")
        self.assertIn("runs", body["error"])
        self.assertEqual(self.engine.calls, [])

    # -- bodies -----------------------------------------------------------

    def test_a_body_that_is_not_json_is_rejected_cleanly(self):
        status, body, _ = self.call("/generate", raw_body=b"{not json")
        self.assertEqual(status, 400)
        self.assertIn("not valid JSON", body["error"])

    def test_an_empty_body_is_not_a_spec(self):
        status, body, _ = self.call("/generate", raw_body=b"")
        self.assertEqual(status, 400)
        self.assertIn("empty body", body["error"])

    def test_a_body_that_is_not_an_object_is_rejected(self):
        status, body, _ = self.call("/generate", raw_body=b"[1, 2, 3]")
        self.assertEqual(status, 400)
        self.assertIn("JSON object", body["error"])

    def test_an_oversized_body_is_refused_before_it_is_read(self):
        with mock.patch.object(config, "MAX_BODY_BYTES", 128):
            status, body, _ = self.call("/generate", raw_body=b"x" * 512)
        self.assertEqual(status, 413)
        self.assertEqual(body["kind"], "too_large")

    # -- the token --------------------------------------------------------

    def test_a_configured_token_is_enforced_and_health_is_exempt(self):
        self.with_env(CHOPSHOP_PLOT_TOKEN="s3cret")
        status, _, _ = self.request("/generate", payload=GEOMETRY)
        self.assertEqual(status, 401)
        status, _, _ = self.request("/generate", payload=GEOMETRY, token="wrong")
        self.assertEqual(status, 401)
        status, _, _ = self.request("/generate", payload=GEOMETRY, token="s3cret")
        self.assertEqual(status, 200)
        status, body, _ = self.call("/health", method="GET")
        self.assertEqual(status, 200,
                         "a health check that needs the secret cannot be used to "
                         "decide whether to send the secret")
        self.assertIs(body["auth_required"], True)

    def test_with_no_token_configured_everything_is_open(self):
        self.with_env(CHOPSHOP_PLOT_TOKEN=None)
        status, _, _ = self.request("/generate", payload=GEOMETRY)
        self.assertEqual(status, 200)

    # -- the injected engine ----------------------------------------------

    def test_the_engine_the_handler_uses_is_the_injected_one(self):
        self.assertIs(self.server.engine, self.engine)

    def test_an_engine_that_raises_is_a_500_with_its_type_named(self):
        with mock.patch.object(self.engine, "generate", side_effect=RuntimeError("boom")):
            status, body, _ = self.call("/generate", payload=GEOMETRY)
        self.assertEqual(status, 500)
        self.assertIn("RuntimeError: boom", body["error"])


class RealEngineOverHTTPTest(LiveServerTest):
    """The wiring: a spec over HTTP draws the same SVG the CLI would write."""

    def make_engine(self):
        return PlotEngine()

    def test_health_reports_the_real_engine(self):
        status, body, _ = self.call("/health", method="GET")
        self.assertEqual(status, 200)
        self.assertEqual(body["engine"]["operations"], list(OPERATIONS))
        self.assertEqual(body["engine"]["operations"],
                         ["generate", "digest", "query", "tree", "log", "blender"],
                         "the status page lists the operations the service routes")
        self.assertEqual(body["engine"]["metrics_version"], METRICS_VERSION)

    def _svg_root(self, route, payload, **kwargs):
        status, body, ctype = self.request(route, payload=payload, **kwargs)
        self.assertEqual(status, 200, body[:400])
        self.assertIn("image/svg+xml", ctype)
        text = body.decode("utf-8")
        return ET.fromstring(text), text

    def test_generate_answers_with_the_same_svg_the_operation_returns(self):
        root, text = self._svg_root("/generate", GEOMETRY)
        self.assertEqual(text, generate(GEOMETRY),
                         "the service is the CLI's own function, not a second renderer")
        self.assertEqual(root.get("width"), "120")
        self.assertEqual(root.get("height"), "80")
        self.assertEqual(root.get("viewBox"), "0 0 120 80")

    def test_digest_answers_with_a_chart_svg(self):
        root, text = self._svg_root("/digest", BAR)
        self.assertEqual(text, digest(BAR))
        self.assertEqual(root.get("width"), "800", "the contract's default size")
        self.assertEqual(root.get("height"), "400")

    def test_tree_answers_with_a_tree_svg(self):
        root, text = self._svg_root("/tree", HIERARCHY)
        self.assertEqual(text, tree(HIERARCHY),
                         "the service is the CLI's own function, not a second renderer")
        self.assertIsNotNone(root.get("viewBox"))

    def test_log_answers_with_a_timeline_svg(self):
        root, text = self._svg_root("/log", EVENTS)
        self.assertEqual(text, log(EVENTS))
        self.assertIsNotNone(root.get("viewBox"))

    def test_an_invalid_hierarchy_is_refused_over_http(self):
        status, body, _ = self.call("/tree", payload={
            "nodes": [{"id": "a"}], "edges": [{"from": "a", "to": "ghost"}]})
        self.assertEqual(status, 400)
        self.assertEqual(body["kind"], "invalid_spec")
        self.assertIn("ghost", body["error"])

    def test_an_invalid_event_spec_is_refused_over_http(self):
        status, body, _ = self.call("/log", payload={"events": [{"pos": "first"}]})
        self.assertEqual(status, 400)
        self.assertEqual(body["kind"], "invalid_spec")
        self.assertIn("integer", body["error"])

    def test_query_answers_with_a_chart_svg_over_run_records(self):
        runs = two_source_two_recipe_runs()
        spec = {"chart": "scatter", "x": "node_count_max", "y": "mae_art",
                "color": "fidelity_verdict"}
        root, text = self._svg_root("/query", {"runs": runs, "spec": spec})
        self.assertEqual(text, query(runs, spec))
        self.assertEqual(root.get("width"), "800")

    def test_the_pareto_frontier_and_the_diff_are_reachable_over_http(self):
        runs = two_source_two_recipe_runs()
        specs = [
            {"chart": "pareto", "x": "hard", "y": "file_size"},
            {"chart": "diff", "left": {"candidate_id": "a1"},
             "right": {"candidate_id": "a2"}},
        ]
        for spec in specs:
            root, _ = self._svg_root("/query", {"runs": runs, "spec": spec})
            self.assertIsNotNone(root, spec["chart"])

    # -- a refused spec is the contract's own error, over HTTP ------------

    def test_an_invalid_generate_spec_names_the_field(self):
        status, body, _ = self.call("/generate", payload={"canvas": {"width": 10}})
        self.assertEqual(status, 400)
        self.assertEqual(body["kind"], "invalid_spec")
        self.assertIn("height", body["error"])

    def test_an_invalid_digest_spec_is_refused(self):
        status, body, _ = self.call("/digest", payload={"chart": "pie", "data": {}})
        self.assertEqual(status, 400)
        self.assertIn("bar, line, scatter", body["error"])

    def test_a_categorical_axis_is_rejected_rather_than_approximated(self):
        runs = two_source_two_recipe_runs()
        status, body, _ = self.call("/query", payload={
            "runs": runs, "spec": {"chart": "scatter", "x": "preset", "y": "mae_art"}})
        self.assertEqual(status, 400)
        self.assertEqual(body["kind"], "invalid_spec")
        self.assertIn("not a numeric metric field", body["error"])

    def test_an_unresolvable_diff_selector_is_refused(self):
        runs = two_source_two_recipe_runs()
        status, body, _ = self.call("/query", payload={
            "runs": runs, "spec": {"chart": "diff", "left": {"candidate_id": "nope"},
                                   "right": {"candidate_id": "a1"}}})
        self.assertEqual(status, 400)
        self.assertIn("no candidate 'nope'", body["error"])


class PortBindingTest(unittest.TestCase):
    """port 0 means port 0, and no argument means the configured port."""

    def test_an_explicit_port_zero_binds_somewhere_free(self):
        # Hold a port of our own and *call it* the configured port, so this test
        # does not care what the machine is already doing on the real default.
        blocker = socket.socket()
        blocker.bind(("127.0.0.1", 0))
        blocker.listen(1)
        held = blocker.getsockname()[1]
        try:
            with mock.patch.dict(os.environ, {"CHOPSHOP_PLOT_PORT": str(held)}):
                server = build_server(StubEngine(), bind="127.0.0.1", port=0)
        finally:
            blocker.close()
        try:
            self.assertNotEqual(server.server_address[1], held,
                                "`port or config.port()` would make an explicit 0 "
                                "mean the configured port and collide with a real "
                                "service running there")
        finally:
            server.server_close()

    def test_the_configured_port_is_used_when_none_is_given(self):
        with mock.patch.dict(os.environ, {"CHOPSHOP_PLOT_PORT": "8899"}):
            server = build_server(StubEngine(), bind="127.0.0.1")
        try:
            self.assertEqual(server.server_address[1], 8899)
        finally:
            server.server_close()

    def test_the_defaults_are_loopback_and_the_plot_port(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(config.bind(), "127.0.0.1")
            self.assertEqual(config.port(), 8796)
            self.assertIsNone(config.token())


class ServeCommandTest(unittest.TestCase):
    """`python3 cli.py serve` has to work: that is how the service is started."""

    def test_the_cli_serves_and_reports_the_port_it_bound(self):
        proc = subprocess.Popen(
            [sys.executable, str(REPO_ROOT / "cli.py"), "serve",
             "--bind", "127.0.0.1", "--port", "0"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=str(REPO_ROOT),
        )
        banner = []
        threading.Thread(target=lambda: banner.append(proc.stdout.readline()),
                         daemon=True).start()
        try:
            deadline = time.time() + 20
            while not banner and time.time() < deadline:
                time.sleep(0.05)
            self.assertTrue(banner and banner[0],
                            "the serve banner never arrived (exit %r)" % proc.poll())
            match = re.search(r"listening on http://(\S+):(\d+)", banner[0])
            self.assertIsNotNone(match, "unparseable banner: %r" % banner[0])
            base = "http://%s:%s" % (match.group(1), match.group(2))

            body = None
            deadline = time.time() + 10
            while body is None and time.time() < deadline:
                try:
                    with urllib.request.urlopen(base + "/health", timeout=5) as resp:
                        body = json.loads(resp.read())
                except urllib.error.URLError:
                    time.sleep(0.1)
            self.assertIsNotNone(body, "the advertised port never answered")
            self.assertIs(body["ok"], True)
            self.assertEqual(body["service"], "chopshop-bp")
        finally:
            proc.terminate()
            proc.wait(timeout=10)
            proc.stdout.close()
            proc.stderr.close()


class StdlibOnlyTest(unittest.TestCase):
    def test_importing_the_service_pulls_in_no_third_party_module(self):
        """Pins the rule the whole package is built on.

        If someone imports numpy (or a renderer) at module scope in the service,
        this suite silently becomes unrunnable on a machine without it -- and the
        package's one hard rule is that it has no dependencies. Checked in a
        subprocess, because this process may already have imported something.
        """
        code = ("import sys, chopshop_plot.server, chopshop_plot.generate, "
                "chopshop_plot.digest, chopshop_plot.query, chopshop_plot.tree, "
                "chopshop_plot.log; "
                "print(sorted(m for m in ('numpy', 'PIL', 'matplotlib', 'shapely') "
                "if m in sys.modules))")
        out = subprocess.run([sys.executable, "-c", code], capture_output=True,
                             text=True, cwd=str(REPO_ROOT))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "[]")


class EnvelopeRuleTest(unittest.TestCase):
    """The envelope rule, shared with the CLI, tested once and directly."""

    def test_a_bare_spec_is_the_spec(self):
        self.assertEqual(unwrap_payload(GEOMETRY, "generate"), GEOMETRY)

    def test_an_envelope_is_unwrapped(self):
        self.assertEqual(unwrap_payload({"op": "digest", "spec": BAR}, "digest"), BAR)

    def test_a_mismatched_op_is_a_spec_error(self):
        with self.assertRaises(SpecError):
            unwrap_payload({"op": "generate", "spec": GEOMETRY}, "digest")


if __name__ == "__main__":
    unittest.main()
