"""The CLI's exit codes, and that the hand-off runs the pipeline it built."""

import os
import subprocess
import sys

import pytest

from chopshop_flux import cli
from chopshop_flux.client import FluxError


class StubClient:
    """Stands in for FluxClient: no network, deterministic response."""

    def __init__(self, *args, **kwargs):
        self.downloaded = []
        self.generated = []

    def generate(self, prompt, **kwargs):
        self.generated.append((prompt, kwargs))
        return {"seed": 11, "steps": 4, "guidance": 1.0, "total_seconds": 1.5,
                "load_seconds": 30.0, "warnings": [],
                "images": [{"name": "gen-01.png", "width": 512, "height": 512,
                            "bytes": 100, "seconds": 1.5}]}

    def edit(self, source, prompt, **kwargs):
        return self.generate(prompt, **kwargs)

    def download(self, name, out_dir):
        self.downloaded.append((name, out_dir))
        return "%s/%s" % (out_dir, name)

    def health(self):
        return {"ok": True, "service": "chopshop-flux"}

    def models(self):
        return {"models": [], "unloadable": {}}


@pytest.fixture
def stub(monkeypatch):
    holder = {}

    def factory(*args, **kwargs):
        holder["client"] = StubClient()
        return holder["client"]

    monkeypatch.setattr(cli, "FluxClient", factory)
    return holder


def test_generate_downloads_and_reports(stub, tmp_path, capsys):
    code = cli.main(["generate", "a phoenix emblem", "--width", "512",
                     "--height", "512", "--out", str(tmp_path)])
    assert code == 0
    out = capsys.readouterr().out
    assert "gen-01.png" in out
    assert "seed 11" in out
    assert stub["client"].downloaded == [("gen-01.png", str(tmp_path))]


def test_generate_prints_json_when_asked(stub, capsys):
    code = cli.main(["generate", "x", "--width", "512", "--height", "512", "--json"])
    assert code == 0
    assert '"seed": 11' in capsys.readouterr().out


def test_generate_reads_a_prompt_from_stdin(stub, monkeypatch, capsys):
    import io
    monkeypatch.setattr("sys.stdin", io.StringIO("an owl crest\n"))
    code = cli.main(["generate", "--width", "512", "--height", "512"])
    assert code == 0
    assert stub["client"].generated[0][0] == "an owl crest"


def test_an_empty_prompt_is_a_usage_error(stub, monkeypatch):
    import io
    monkeypatch.setattr("sys.stdin", io.StringIO("   \n"))
    assert cli.main(["generate", "--width", "512", "--height", "512"]) == 2


def test_a_client_error_becomes_its_exit_code(monkeypatch):
    def boom(*args, **kwargs):
        raise FluxError("service unreachable", exit_code=3)

    monkeypatch.setattr(cli, "FluxClient", boom)
    assert cli.main(["health"]) == 3


def test_health_exits_5_when_the_service_is_not_ok(monkeypatch):
    class Unhealthy(StubClient):
        def health(self):
            return {"ok": False}

    monkeypatch.setattr(cli, "FluxClient", lambda *a, **k: Unhealthy())
    assert cli.main(["health"]) == 5


def test_models_marks_the_non_commercial_one(monkeypatch, capsys):
    class M(StubClient):
        def models(self):
            return {"models": [
                {"key": "klein-4b", "license": "Apache-2.0", "vram_gb": 13.0,
                 "commercial_ok": True, "notes": ""},
                {"key": "klein-9b", "license": "FLUX Non-Commercial License v2.1",
                 "vram_gb": 24.0, "commercial_ok": False, "notes": "nope"},
            ], "unloadable": {}}

    monkeypatch.setattr(cli, "FluxClient", lambda *a, **k: M())
    assert cli.main(["models"]) == 0
    out = capsys.readouterr().out
    assert "commercial OK" in out
    assert "NON-COMMERCIAL" in out


def test_gen2pipe_generates_then_hands_off(stub, monkeypatch, tmp_path):
    """The whole point: a generated raster becomes pipeline input."""
    calls = {}
    monkeypatch.setattr(cli, "run_pipeline",
                        lambda raster, **kwargs: calls.update(kwargs) or 0)
    code = cli.main(["gen2pipe", "a phoenix emblem", "--width", "512",
                     "--height", "512", "--out", str(tmp_path),
                     "--sweep", "sweep.json"])
    assert code == 0
    assert calls["sweep"] == "sweep.json"
    assert stub["client"].downloaded == [("gen-01.png", str(tmp_path))]


def test_gen2pipe_passes_a_passing_pipeline_run_through(stub, monkeypatch, tmp_path):
    """Exit 1 (candidates produced, none passed) is not an error: the pipeline
    made candidates, and picking is a human's job, not this command's."""
    monkeypatch.setattr(cli, "run_pipeline", lambda raster, **kwargs: 1)
    code = cli.main(["gen2pipe", "x", "--width", "512", "--height", "512",
                     "--out", str(tmp_path)])
    assert code == 1


def test_gen2pipe_treats_a_pipeline_failure_as_exit_2(stub, monkeypatch, tmp_path):
    monkeypatch.setattr(cli, "run_pipeline", lambda raster, **kwargs: 2)
    code = cli.main(["gen2pipe", "x", "--width", "512", "--height", "512",
                     "--out", str(tmp_path)])
    assert code == 2


def test_gen2pipe_reports_warnings_from_the_service(stub, monkeypatch, tmp_path, capsys):
    def generating(prompt, **kwargs):
        return {"seed": 1, "steps": 4, "guidance": 3.0, "total_seconds": 1.0,
                "load_seconds": 1.0,
                "warnings": ["guidance_scale is 3 but klein-4b is distilled"],
                "images": [{"name": "g.png", "width": 512, "height": 512,
                            "bytes": 1, "seconds": 1.0}]}

    client = StubClient()
    client.generate = generating
    monkeypatch.setattr(cli, "FluxClient", lambda *a, **k: client)
    monkeypatch.setattr(cli, "run_pipeline", lambda raster, **kwargs: 0)
    cli.main(["gen2pipe", "x", "--width", "512", "--height", "512",
              "--out", str(tmp_path)])
    assert "distilled" in capsys.readouterr().err


def test_an_unknown_subcommand_is_usage_error_2():
    with pytest.raises(SystemExit) as caught:
        cli.main(["frobnicate"])
    assert caught.value.code == 2


def test_python_dash_m_is_a_real_entry_point():
    """The docs say `python -m chopshop_flux serve`, so that has to work.

    Every other test in this file calls cli.main() directly, which is exactly
    how a missing __main__.py goes unnoticed: the documented command was broken
    while the whole suite stayed green.
    """
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    result = subprocess.run([sys.executable, "-m", "chopshop_flux", "--help"],
                            cwd=root, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    for command in ("serve", "health", "models", "generate", "edit", "gen2pipe"):
        assert command in result.stdout, command
