"""The blender operation: the spec, the driver, the route, and a real render.

Three layers, tested apart on purpose. The SPEC layer proves an invalid document
is refused with the field named. The DRIVER layer proves the invocation is the
one the contract states — exactly, argv for argv — with the subprocess mocked, so
it needs no renderer. The ROUTE layer proves the two answer shapes (the image,
the manifest) and the file guard, over a real socket with a stub engine.

Everything here passes with no Blender installed; the last class is the real
render and skips unless the binary is on PATH, because a mocked subprocess
proves the plumbing and nothing about whether bpy can build the geometry. That
smoke test is also the guard on the one rule with two implementations: the frame
stem, computed by the driver and mirrored inside `blender/bpy_geometry.py` — it
reads the frames back by the names the driver returned.
"""

import contextlib
import importlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

from chopshop_plot import config
from chopshop_plot.blender import (BPY_SCRIPT, BlenderUnavailable, is_stroke, manifest,
                                   output_names, output_stem, render_blender,
                                   resolve_extrude, resolve_render, tube_radius,
                                   validate_blender)
from chopshop_plot.server import FILE_NAME, OPERATIONS, PlotEngine, build_server
from chopshop_plot.spec import SpecError

REPO_ROOT = Path(__file__).resolve().parent.parent
HAVE_BLENDER = shutil.which("blender")

# importlib, not `from chopshop_plot import blender`: the package exports the
# operation FUNCTION under that name (as it does for generate, query, ...), so
# the attribute is the function and this is the module the driver lives in.
blender_module = importlib.import_module("chopshop_plot.blender")

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
GLB_MAGIC = b"glTF"


def valid_spec(**overrides):
    """A spec that satisfies the contract, so a test can change one thing."""
    spec = {
        "title": "unit",
        "elements": [
            {"type": "rect", "x": 0, "y": 0, "width": 100, "height": 60, "fill": "#e04030"},
            {"type": "polyline", "points": [[0, 100], [100, 160]],
             "stroke": "#ffffff", "stroke_width": 3},
        ],
        "extrude": {"depth": 10},
        "render": {"size": {"width": 320, "height": 240}, "views": 1},
        "export": {"glb": True},
    }
    spec.update(overrides)
    return spec


class BlenderSpecTest(unittest.TestCase):
    """validate_blender: an invalid spec is a caller error, named field by field."""

    def assert_refused(self, spec, fragment):
        with self.assertRaises(SpecError) as caught:
            validate_blender(spec)
        self.assertIn(fragment, str(caught.exception))

    def test_a_valid_spec_is_kept_and_returned(self):
        spec = valid_spec()
        self.assertIs(validate_blender(spec), spec)

    def test_a_spec_that_is_not_an_object_is_refused(self):
        self.assert_refused([], "must be an object")

    def test_elements_are_required(self):
        self.assert_refused({}, "missing required field 'elements'")

    def test_an_element_from_the_shared_vocabulary_is_checked_by_the_shared_code(self):
        self.assert_refused(valid_spec(elements=[{"type": "blob"}]), "unknown element type")
        self.assert_refused(valid_spec(elements=[{"type": "circle", "cx": 1, "cy": 2}]),
                            "missing required field 'r'")
        self.assert_refused(valid_spec(elements=[{"type": "circle", "cx": 1, "cy": 2, "r": 3,
                                                  "wobble": 1}]),
                            "unknown field(s) ['wobble']")

    def test_a_spec_with_nothing_to_draw_is_refused(self):
        self.assert_refused({"elements": []}, "nothing to render")
        self.assert_refused({"elements": [{"type": "polygon", "points": [[1, 2]]}]},
                            "at least two points")
        self.assert_refused({"elements": [{"type": "path", "d": "M 10 10", "fill": "#fff"}]},
                            "at least two points")

    def test_solid_or_stroke_follows_the_elements_own_shape(self):
        closed = {"type": "rect", "x": 0, "y": 0, "width": 1, "height": 1}
        self.assertFalse(is_stroke(closed), "a rect is closed whatever its fill says")
        self.assertFalse(is_stroke(dict(closed, type="circle", cx=0, cy=0, r=1)))
        self.assertFalse(is_stroke(dict(closed, type="polygon", points=[[0, 0], [1, 1], [0, 1]])))
        self.assertTrue(is_stroke({"type": "line", "x1": 0, "y1": 0, "x2": 1, "y2": 1}))
        self.assertTrue(is_stroke({"type": "polyline", "points": [[0, 0], [1, 1]]}))
        self.assertTrue(is_stroke({"type": "path", "d": "M0 0 L1 1"}),
                        "an unfilled path is an outline")
        self.assertFalse(is_stroke({"type": "path", "d": "M0 0 L1 1 Z", "fill": "#fff"}),
                         "a filled, closed path is a solid")
        self.assertTrue(is_stroke({"type": "path", "d": "M0 0 L1 1 Z", "fill": "none"}))
        self.assertTrue(is_stroke({"type": "path", "d": "M0 0 L1 1 Z"}),
                        "closed but unfilled is still an outline")

    def test_the_tube_radius_is_the_stroke_width_or_the_contracts_default(self):
        thin = {"type": "line", "x1": 0, "y1": 0, "x2": 1, "y2": 1}
        self.assertEqual(tube_radius(thin), 0.02)
        self.assertEqual(tube_radius(dict(thin, stroke_width=4)), 4.0)

    def test_a_path_command_with_no_3d_reading_is_refused_by_name(self):
        self.assert_refused(valid_spec(elements=[{"type": "path", "d": "M0 0 A 5 5 0 0 1 10 10",
                                                  "fill": "#fff"}]),
                            "path command(s) ['A']")

    # -- the optional blocks -------------------------------------------------

    def test_a_bad_element_field_in_extrude_names_the_key(self):
        self.assert_refused(valid_spec(extrude="deep"), "'extrude' must be an object")
        self.assert_refused(valid_spec(extrude={"depth": "deep"}), "'depth' must be a number")
        self.assert_refused(valid_spec(extrude={"depth": -1}), "must be a number >= 0")
        self.assert_refused(valid_spec(extrude={"bevel_resolution": 2.5}),
                            "'bevel_resolution' must be an integer")
        self.assert_refused(valid_spec(extrude={"bevel_resolution": True}),
                            "'bevel_resolution' must be an integer")

    def test_a_typo_in_extrude_is_refused_rather_than_taking_the_default(self):
        self.assert_refused(valid_spec(extrude={"dept": 10}), "unknown field(s) ['dept']")

    def test_a_bad_render_field_is_refused(self):
        self.assert_refused(valid_spec(render=5), "'render' must be an object")
        self.assert_refused(valid_spec(render={"views": 0}), "'views' must be an integer >= 1")
        self.assert_refused(valid_spec(render={"views": "two"}), "'views' must be an integer >= 1")
        self.assert_refused(valid_spec(render={"views": True}), "'views' must be an integer >= 1")
        self.assert_refused(valid_spec(render={"engine": "cycles"}),
                            "'engine' must be one of workbench, eevee")
        self.assert_refused(valid_spec(render={"background": 17}), "must be a colour string")
        self.assert_refused(valid_spec(render={"size": {"width": 0}}),
                            "'width' must be a positive number")
        self.assert_refused(valid_spec(render={"size": {"width": 10, "depth": 4}}),
                            "unknown field(s) ['depth']")

    def test_a_bad_export_field_is_refused(self):
        self.assert_refused(valid_spec(export={"glb": "yes"}), "'glb' must be true or false")
        self.assert_refused(valid_spec(export={"stl": True}), "unknown field(s) ['stl']")

    def test_a_bad_tiling_block_is_refused_with_the_generate_rules(self):
        self.assert_refused(valid_spec(tiling={"grid": [1, 1]}), "missing required field 'cell'")
        self.assert_refused(
            valid_spec(tiling={"grid": "many", "cell": [1, 1], "origin": [0, 0],
                               "element": {"type": "circle", "cx": 0, "cy": 0, "r": 1}}),
            "'grid' must be a [cols, rows] pair")
        self.assert_refused(
            valid_spec(tiling={"grid": [1, 1], "cell": [1, 1], "origin": [0, 0],
                               "element": {"type": "nope"}}),
            "unknown element type")

    # -- the resolved defaults ----------------------------------------------

    def test_the_contracts_defaults_are_the_ones_applied(self):
        spec = {"elements": [{"type": "circle", "cx": 0, "cy": 0, "r": 5}]}
        validate_blender(spec)
        self.assertEqual(resolve_extrude(spec),
                         {"depth": 0.5, "bevel_depth": 0.02, "bevel_resolution": 2})
        self.assertEqual(resolve_render(spec),
                         {"size": {"width": 1024, "height": 1024}, "views": 1,
                          "background": "#1a1a24", "engine": "workbench"})

    def test_the_stem_is_deterministic_and_per_spec(self):
        first = output_stem(valid_spec())
        self.assertEqual(first, output_stem(valid_spec()), "same document, same name")
        self.assertNotEqual(first, output_stem(valid_spec(title="other")))
        self.assertTrue(first.startswith("unit-"))
        self.assertRegex(first, r"^[A-Za-z0-9][A-Za-z0-9._-]*$",
                         "a frame name has to survive GET /files/<name>")

    def test_output_names_are_the_frames_in_view_order_then_the_glb(self):
        spec = valid_spec(render={"views": 3}, export={"glb": True})
        stem = output_stem(spec)
        names = output_names(spec)
        self.assertEqual(names, [f"{stem}_000.png", f"{stem}_001.png", f"{stem}_002.png",
                                 f"{stem}.glb"])
        self.assertEqual(manifest(names), {"frames": names[:3], "glb": names[3]})

        quiet = valid_spec(export={"glb": False})
        self.assertEqual(manifest(output_names(quiet)),
                         {"frames": [f"{output_stem(quiet)}_000.png"], "glb": None})


class BlenderDriverTest(unittest.TestCase):
    """The driver builds the invocation the contract states, and its failures are loud."""

    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="chopshop-blender-driver-")
        self.addCleanup(shutil.rmtree, self.out, ignore_errors=True)

    def fake_run(self, captured):
        """A subprocess.run stand-in: record the command, and the spec file it points at."""
        def run(command, **kwargs):
            captured["command"] = command
            captured["spec_path"] = command[-2]
            captured["out_dir"] = command[-1]
            with open(command[-2], encoding="utf-8") as handle:
                captured["spec"] = json.load(handle)
            return subprocess.CompletedProcess(command, 0, "", "")
        return run

    def driver_patched(self, run_side_effect):
        """The process boundary, patched: a resolvable binary AND a stubbed run.

        ``which`` is patched too, deliberately: these tests are about the argv the
        driver builds, and they must give the same answer on a machine with no
        Blender installed — the real-render smoke test is the only test allowed
        to need the binary.
        """
        stack = contextlib.ExitStack()
        stack.enter_context(mock.patch.object(blender_module.shutil, "which",
                                              return_value="/usr/bin/blender"))
        stack.enter_context(mock.patch.object(blender_module.subprocess, "run",
                                              side_effect=run_side_effect))
        return stack

    def test_the_invocation_is_blender_background_python_script_spec_and_out_dir(self):
        spec = valid_spec()
        captured = {}
        with self.driver_patched(self.fake_run(captured)):
            names = render_blender(spec, self.out)

        command = captured["command"]
        self.assertEqual(command[0], "blender", "the configured binary runs first")
        self.assertIn("--background", command)
        self.assertIn("--python", command)
        self.assertEqual(command[command.index("--python") + 1], BPY_SCRIPT)
        self.assertTrue(command[command.index("--python") + 1].endswith(
            os.path.join("blender", "bpy_geometry.py")))
        self.assertIn("--", command, "Blender's own argv has to stop before ours")
        self.assertEqual(command[-3], "--")
        self.assertEqual(command[-2:], [captured["spec_path"], self.out],
                         "the two positional args are the spec JSON, then the out dir")
        self.assertEqual(captured["spec"], spec, "the spec reached the file unchanged")
        self.assertEqual(captured["out_dir"], self.out)
        self.assertEqual(names, output_names(spec))
        self.assertFalse(os.path.exists(captured["spec_path"]),
                         "the temp spec goes away with the call")

    def test_the_binary_comes_from_the_configured_name(self):
        captured = {}
        with mock.patch.dict(os.environ, {"CHOPSHOP_BLENDER_BINARY": "blender-4.3"}), \
                self.driver_patched(self.fake_run(captured)):
            render_blender(valid_spec(), self.out)
            self.assertEqual(config.blender_binary(), "blender-4.3",
                             "the binary is read at call time, not at import")
        self.assertEqual(captured["command"][0], "blender-4.3")

    def test_a_spec_that_is_not_valid_never_starts_a_process(self):
        with self.driver_patched(mock.Mock()) as _:
            with mock.patch.object(blender_module.subprocess, "run") as run:
                with self.assertRaises(SpecError):
                    render_blender({"elements": [{"type": "nope"}]}, self.out)
        run.assert_not_called()

    def test_a_missing_binary_raises_blender_unavailable_naming_it(self):
        with mock.patch.object(config, "blender_binary", return_value="no-such-blender"), \
                mock.patch.object(blender_module.shutil, "which", return_value=None):
            with self.assertRaises(BlenderUnavailable) as caught:
                render_blender(valid_spec(), self.out)
        message = str(caught.exception)
        self.assertIn("no-such-blender", message)
        self.assertIn("not found", message)
        self.assertIn(config.BLENDER_BINARY_ENV, message,
                      "the message says how to fix it")

    def test_a_failed_process_raises_blender_unavailable_with_the_exit_code(self):
        def failing(command, **kwargs):
            return subprocess.CompletedProcess(command, 3, "", "bpy_geometry: boom")
        with self.driver_patched(failing):
            with self.assertRaises(BlenderUnavailable) as caught:
                render_blender(valid_spec(), self.out)
        message = str(caught.exception)
        self.assertIn("blender", message)
        self.assertIn("3", message, "the exit code is the diagnostic")
        self.assertIn("boom", message, "and so is what the script said")

    def test_a_process_that_cannot_be_started_is_named_too(self):
        with self.driver_patched(FileNotFoundError("no exec")):
            with self.assertRaises(BlenderUnavailable) as caught:
                render_blender(valid_spec(), self.out)
        self.assertIn("could not be run", str(caught.exception))

    def test_the_output_directory_is_created(self):
        target = os.path.join(self.out, "nested", "deeper")
        captured = {}
        with self.driver_patched(self.fake_run(captured)):
            render_blender(valid_spec(), target)
        self.assertTrue(os.path.isdir(target))


class _StubBlenderEngine:
    """The service's blender surface without a renderer behind it."""

    def __init__(self, out_dir, frames=(), glb=None, error=None):
        self.out_dir = out_dir
        self.frames = list(frames)
        self.glb = glb
        self.error = error
        self.calls = []

    def status(self):
        return {"operations": ["blender"], "metrics_version": 1}

    def blender(self, spec):
        self.calls.append(spec)
        if self.error is not None:
            raise self.error
        for name in self.frames:
            with open(os.path.join(self.out_dir, name), "wb") as handle:
                handle.write(PNG_MAGIC + b"stub frame")
        return {"frames": self.frames, "glb": self.glb}


class BlenderRouteTest(unittest.TestCase):
    """POST /blender and GET /files/<name>, over a real socket, no renderer."""

    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="chopshop-blender-route-")
        self.addCleanup(shutil.rmtree, self.out, ignore_errors=True)
        self.with_env(CHOPSHOP_BLENDER_OUT_DIR=self.out)

    def with_env(self, **values):
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

    def serve(self, engine):
        self.server = build_server(engine, bind="127.0.0.1", port=0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.thread.join, 5)
        self.addCleanup(self.server.shutdown)
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.engine = engine

    def request(self, route, payload=None, method=None):
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        request = urllib.request.Request(self.base + route, data=data,
                                         headers={"Content-Type": "application/json"},
                                         method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, response.read(), response.headers.get("Content-Type")
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read(), exc.headers.get("Content-Type")

    def call(self, route, payload=None, **kwargs):
        status, body, ctype = self.request(route, payload=payload, **kwargs)
        try:
            return status, json.loads(body), ctype
        except ValueError:
            return status, body, ctype

    # -- the operation is on the surface ------------------------------------

    def test_blender_is_one_of_the_operations_the_service_routes(self):
        self.assertIn("blender", OPERATIONS)

    def test_status_lists_blender(self):
        self.serve(PlotEngine())
        status, body, _ = self.call("/health", method="GET")
        self.assertEqual(status, 200)
        self.assertIn("blender", body["engine"]["operations"])

    # -- the two answer shapes ----------------------------------------------

    def test_one_view_answers_with_the_png_itself(self):
        engine = _StubBlenderEngine(self.out, frames=["frame_000.png"])
        self.serve(engine)
        status, body, ctype = self.request("/blender", payload=valid_spec())
        self.assertEqual(status, 200)
        self.assertIn("image/png", ctype)
        self.assertEqual(body, PNG_MAGIC + b"stub frame")
        self.assertEqual(len(engine.calls), 1)

    def test_one_view_with_a_glb_export_answers_with_the_manifest(self):
        # A single view PLUS an exported GLB is a second artifact, so the frame
        # bytes cannot be the whole answer: the GLB's name must reach the caller.
        engine = _StubBlenderEngine(self.out, frames=["frame_000.png"], glb="frame.glb")
        self.serve(engine)
        status, body, _ = self.call("/blender", payload=valid_spec(export={"glb": True}))
        self.assertEqual(status, 200)
        self.assertEqual(body, {"frames": ["frame_000.png"], "glb": "frame.glb"})

    def test_several_views_answer_with_the_manifest(self):
        frames = ["frame_000.png", "frame_001.png", "frame_002.png"]
        self.serve(_StubBlenderEngine(self.out, frames=frames, glb="frame.glb"))
        status, body, _ = self.call("/blender", payload=valid_spec(render={"views": 3},
                                                                   export={"glb": True}))
        self.assertEqual(status, 200)
        self.assertEqual(body, {"frames": frames, "glb": "frame.glb"})

    def test_the_manifest_carries_frames_and_glb_and_nothing_else(self):
        self.serve(_StubBlenderEngine(self.out, frames=["a.png", "b.png"]))
        status, body, _ = self.call("/blender", payload=valid_spec(render={"views": 2}))
        self.assertEqual(status, 200)
        self.assertEqual(sorted(body), ["frames", "glb"])
        self.assertIsNone(body["glb"], "no export means null, not a missing key")

    def test_the_envelope_is_unwrapped_like_every_other_operation(self):
        engine = _StubBlenderEngine(self.out, frames=["only.png"])
        self.serve(engine)
        status, _, _ = self.request("/blender",
                                   payload={"op": "blender", "spec": valid_spec()})
        self.assertEqual(status, 200)
        self.assertEqual(engine.calls, [valid_spec()])

    def test_an_envelope_for_another_operation_is_refused(self):
        self.serve(_StubBlenderEngine(self.out, frames=["only.png"]))
        status, body, _ = self.call("/blender",
                                    payload={"op": "generate", "spec": valid_spec()})
        self.assertEqual(status, 400)
        self.assertEqual(body["kind"], "invalid_spec")

    # -- refusals -----------------------------------------------------------

    def test_the_stub_engine_never_sees_an_invalid_blender_spec(self):
        engine = _StubBlenderEngine(self.out, frames=["only.png"])
        self.serve(engine)
        for spec, fragment in [
            (valid_spec(render={"views": 0}), "views"),
            (valid_spec(extrude={"depth": "deep"}), "depth"),
            ({"elements": [{"type": "nope"}]}, "unknown element type"),
        ]:
            status, body, _ = self.call("/blender", payload=spec)
            self.assertEqual(status, 400, spec)
            self.assertEqual(body["kind"], "invalid_spec")
            self.assertIn(fragment, body["error"])
        self.assertEqual(engine.calls, [], "the handler validates before it renders")

    def test_a_missing_renderer_is_a_503_and_never_a_404(self):
        engine = _StubBlenderEngine(self.out,
                                    error=BlenderUnavailable("blender binary 'blender' "
                                                             "not found on PATH"))
        self.serve(engine)
        status, body, ctype = self.call("/blender", payload=valid_spec())
        self.assertEqual(status, 503)
        self.assertEqual(body["kind"], "blender_unavailable")
        self.assertIn("not found on PATH", body["error"])
        self.assertIn("application/json", ctype)

    # -- the files ----------------------------------------------------------

    def test_a_written_frame_is_fetchable_by_name(self):
        engine = _StubBlenderEngine(self.out, frames=["fetch_000.png"])
        self.serve(engine)
        self.call("/blender", payload=valid_spec())
        status, body, ctype = self.request("/files/fetch_000.png", method="GET")
        self.assertEqual(status, 200)
        self.assertIn("image/png", ctype)
        self.assertEqual(body, PNG_MAGIC + b"stub frame")

    def test_a_name_that_is_not_there_is_a_404(self):
        self.serve(_StubBlenderEngine(self.out))
        status, body, _ = self.call("/files/absent_000.png", method="GET")
        self.assertEqual(status, 404)
        self.assertEqual(body["kind"], "not_found")

    def test_a_traversal_name_is_refused_and_reads_nothing(self):
        """The one attack that matters: the name comes from the network."""
        victim = os.path.join(os.path.dirname(self.out), "victim.txt")
        with open(victim, "w", encoding="utf-8") as handle:
            handle.write("PRIVATE-CONTENT")
        self.addCleanup(os.remove, victim)
        self.serve(_StubBlenderEngine(self.out))
        for name in ["../victim.txt", "..%2fvictim.txt", "..%2Fvictim.txt", "/etc/passwd",
                     "a/b.png", "..", ".", "", "sub/../victim.txt", "....//victim.txt"]:
            status, body, _ = self.call("/files/" + name, method="GET")
            self.assertEqual(status, 404, name)
            self.assertEqual(body["kind"], "not_found", name)
            self.assertNotIn(b"PRIVATE-CONTENT", body, name)

    def test_a_name_the_regex_refuses_is_never_joined_to_the_directory(self):
        """The guard itself, called directly: what a file name may look like."""
        for name in ["../x", "a/b", "/abs", "..%2fpasswd", ".hidden", "..", "", "a\\b"]:
            self.assertFalse(FILE_NAME.match(name), name)
        for name in ["unit-5f7814aa_000.png", "unit-5f7814aa.glb", "a_b-1.2.png"]:
            self.assertTrue(FILE_NAME.match(name), name)


class BlenderCliTest(unittest.TestCase):
    """The CLI's exit codes, without a renderer: 3 for a bad spec, 4 for no blender."""

    def run_cli(self, *args, **env):
        environment = dict(os.environ)
        environment.update(env)
        return subprocess.run([sys.executable, str(REPO_ROOT / "cli.py"), *args],
                              capture_output=True, text=True, cwd=str(REPO_ROOT),
                              env=environment)

    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="chopshop-blender-cli-")
        self.addCleanup(shutil.rmtree, self.out, ignore_errors=True)
        self.spec_path = os.path.join(self.out, "spec.json")
        with open(self.spec_path, "w", encoding="utf-8") as handle:
            json.dump(valid_spec(), handle)

    def test_an_invalid_spec_exits_3(self):
        bad = os.path.join(self.out, "bad.json")
        with open(bad, "w", encoding="utf-8") as handle:
            json.dump({"elements": [{"type": "nope"}]}, handle)
        result = self.run_cli("blender", bad, self.out)
        self.assertEqual(result.returncode, 3)
        self.assertIn("unknown element type", result.stderr)

    def test_no_blender_exits_4_with_the_fix_named(self):
        result = self.run_cli("blender", self.spec_path, self.out,
                              CHOPSHOP_BLENDER_BINARY="definitely-not-blender")
        self.assertEqual(result.returncode, 4)
        self.assertIn("definitely-not-blender", result.stderr)
        self.assertIn("CHOPSHOP_BLENDER_BINARY", result.stderr)

    def test_usage_without_a_spec_exits_2(self):
        self.assertEqual(self.run_cli("blender").returncode, 2)


@unittest.skipUnless(HAVE_BLENDER, "the blender binary is not installed")
class RealRenderSmokeTest(unittest.TestCase):
    """The real thing: a headless Blender has to build the geometry and write files.

    A mocked subprocess proves the argv; only this proves bpy turns a spec into a
    PNG that starts with a PNG header and a GLB that starts with the glTF magic.
    It also guards the one rule with two implementations — the frame stem — by
    reading the frames back under the names the driver returned.
    """

    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="chopshop-blender-smoke-")
        self.addCleanup(shutil.rmtree, self.out, ignore_errors=True)

    def smoke_spec(self, **overrides):
        spec = {
            "title": "smoke",
            "elements": [
                {"type": "rect", "x": 0, "y": 0, "width": 200, "height": 120,
                 "fill": "#e04030"},
                {"type": "circle", "cx": 320, "cy": 60, "r": 60, "fill": "#3080e0"},
            ],
            "extrude": {"depth": 40, "bevel_depth": 6, "bevel_resolution": 3},
            "render": {"size": {"width": 480, "height": 360}, "views": 1,
                       "background": "#1a1a24"},
            "export": {"glb": True},
        }
        spec.update(overrides)
        return spec

    def test_one_extruded_rect_and_one_circle_render_a_png_and_a_glb(self):
        spec = self.smoke_spec()
        names = render_blender(spec, self.out)

        self.assertEqual(names, output_names(spec),
                         "the driver's names and the files Blender wrote have to agree")
        self.assertEqual(sorted(os.listdir(self.out)), sorted(names))

        frames = [name for name in names if name.endswith(".png")]
        self.assertEqual(len(frames), 1)
        frame_path = os.path.join(self.out, frames[0])
        with open(frame_path, "rb") as handle:
            head = handle.read(24)
        self.assertEqual(head[:8], PNG_MAGIC, "a PNG, by its header")
        self.assertEqual(head[12:16], b"IHDR")
        self.assertEqual(struct.unpack(">II", head[16:24]), (480, 360),
                         "render.size is the frame size")
        self.assertGreater(os.path.getsize(frame_path), 5000,
                           "a frame with no geometry in it compresses to almost nothing")

        glbs = [name for name in names if name.endswith(".glb")]
        self.assertEqual(len(glbs), 1)
        with open(os.path.join(self.out, glbs[0]), "rb") as handle:
            self.assertEqual(handle.read(4), GLB_MAGIC)
        self.assertGreater(os.path.getsize(os.path.join(self.out, glbs[0])), 1000)

    def test_the_azimuth_steps_so_two_views_are_two_different_frames(self):
        spec = self.smoke_spec(render={"size": {"width": 320, "height": 240}, "views": 2},
                               export={"glb": False})
        names = render_blender(spec, self.out)
        self.assertEqual(names, output_names(spec))
        self.assertEqual(sorted(os.listdir(self.out)), sorted(names))

        frames = []
        for name in names:
            with open(os.path.join(self.out, name), "rb") as handle:
                frames.append(handle.read(8))
        for head in frames:
            self.assertEqual(head, PNG_MAGIC)
        with open(os.path.join(self.out, names[0]), "rb") as handle:
            first = handle.read()
        with open(os.path.join(self.out, names[1]), "rb") as handle:
            second = handle.read()
        self.assertNotEqual(first, second,
                            "views>1 means the camera moved, not the same frame twice")

    def test_a_rerun_writes_the_same_bytes(self):
        """The repo's determinism rule, at the level of the artifact.

        MEASURED, and the reason the in-Blender script turns Blender's PNG
        metadata off: the image data was always identical run to run, but the
        Date and RenderTime text chunks made the FILE differ. A frame whose hash
        changes for no reason is a frame nobody can cache or compare.
        """
        spec = self.smoke_spec(render={"size": {"width": 240, "height": 180}, "views": 1},
                               export={"glb": True})
        second = tempfile.mkdtemp(prefix="chopshop-blender-smoke-again-")
        self.addCleanup(shutil.rmtree, second, ignore_errors=True)
        first_names = render_blender(spec, self.out)
        second_names = render_blender(spec, second)
        self.assertEqual(first_names, second_names)
        for name in first_names:
            with open(os.path.join(self.out, name), "rb") as handle:
                one = handle.read()
            with open(os.path.join(second, name), "rb") as handle:
                two = handle.read()
            self.assertEqual(one, two, "%s differs between two runs of one spec" % name)


if __name__ == "__main__":
    unittest.main()
