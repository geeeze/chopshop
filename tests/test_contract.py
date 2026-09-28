"""Tests that pin the language-agnostic contract itself.

The contract (docs/contract.md) is the interface a Julia/R backend must satisfy.
These tests assert the reference implementation honours it in both directions:
valid specs produce well-formed SVG; invalid specs raise SpecError with a clear
message rather than emitting a partial document.
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from chopshop_plot import generate, digest
from chopshop_plot.spec import SpecError

REPO_ROOT = Path(__file__).resolve().parent.parent


class TestContractErrors(unittest.TestCase):
    def test_error_messages_name_the_field(self):
        with self.assertRaises(SpecError) as ctx:
            generate({"canvas": {"width": 1, "height": 1},
                      "elements": [{"type": "circle", "r": 5}]})
        self.assertIn("cx", str(ctx.exception))

    def test_unknown_field_rejected(self):
        with self.assertRaises(SpecError):
            generate({"canvas": {"width": 1, "height": 1},
                      "elements": [{"type": "rect", "x": 0, "y": 0, "width": 1,
                                    "height": 1, "wat": True}]})


class TestCli(unittest.TestCase):
    def _run(self, op, payload):
        with tempfile.TemporaryDirectory() as tmp:
            spec_path = Path(tmp) / "spec.json"
            out_path = Path(tmp) / "out.svg"
            spec_path.write_text(json.dumps(payload))
            proc = subprocess.run(
                [sys.executable, str(REPO_ROOT / "cli.py"), op, str(spec_path), str(out_path)],
                capture_output=True, text=True,
            )
            out_text = out_path.read_text() if out_path.exists() else None
            return proc, out_text

    def test_generate_via_cli(self):
        proc, out_text = self._run("generate", {
            "canvas": {"width": 10, "height": 10},
            "elements": [{"type": "circle", "cx": 5, "cy": 5, "r": 2}],
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIsNotNone(out_text)
        self.assertTrue(out_text.startswith("<svg"))

    def test_digest_via_cli(self):
        proc, out_text = self._run("digest", {
            "chart": "bar", "data": {"labels": ["a"], "values": [1]},
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("<svg", out_text)

    def test_invalid_spec_exits_3(self):
        proc, _ = self._run("generate", {"canvas": {"width": 10}})
        self.assertEqual(proc.returncode, 3)
        self.assertIn("canvas", proc.stderr)

    def test_stdio_mode(self):
        proc = subprocess.run(
            [sys.executable, str(REPO_ROOT / "cli.py"), "generate", "-"],
            input=json.dumps({"canvas": {"width": 5, "height": 5},
                              "elements": [{"type": "rect", "x": 0, "y": 0,
                                            "width": 1, "height": 1}]}),
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(proc.stdout.startswith("<svg"))

    def test_usage_error_exits_2(self):
        proc = subprocess.run(
            [sys.executable, str(REPO_ROOT / "cli.py")], capture_output=True, text=True
        )
        self.assertEqual(proc.returncode, 2)


if __name__ == "__main__":
    unittest.main()
