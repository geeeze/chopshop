"""The CLI's flags for the output-side passes, and what it prints for them.

The CLI is a thin client, so the interesting parts are: a flag combination that
cannot mean anything is a usage error naming the flag, and the numbers a pass
measured are shown rather than hidden behind ``--json``.
"""

import pytest

from chopshop_flux import cli


class StubClient:
    def __init__(self, *args, **kwargs):
        self.generated = []

    def generate(self, prompt, **kwargs):
        self.generated.append((prompt, kwargs))
        return {
            "seed": 4, "steps": 30, "guidance": 5.0, "total_seconds": 3.5,
            "load_seconds": 8.0, "warnings": [], "model": "sdxl-1.0",
            "images": [{
                "name": "gen-01.png", "width": 1024, "height": 1024,
                "bytes": 100, "seconds": 3.5,
                "ink_cap": {"max_colors": 3, "mode": "quantize",
                            "colors_before": 4096, "colors_present": 3,
                            "changed": True,
                            "note": "reduced the frame from 4096 colours to 3"},
                "hires": {"scale": 2.0, "strength": 0.35, "steps": 30,
                          "upscaler": "lanczos", "target": [1024, 1024],
                          "pass_seconds": [1.5, 2.0]},
                "background": {"mode": "key", "uniform": False,
                               "changed": False,
                               "note": "not uniform, left alone"},
                "sidecar": "gen-01.png.json"}]}

    def edit(self, source, prompt, **kwargs):
        return self.generate(prompt, **kwargs)

    def download(self, name, out_dir):
        return "%s/%s" % (out_dir, name)


@pytest.fixture
def stub(monkeypatch):
    holder = {}

    def factory(*args, **kwargs):
        holder["client"] = StubClient()
        return holder["client"]

    monkeypatch.setattr(cli, "FluxClient", factory)
    return holder


def test_the_output_flags_reach_the_client(stub):
    code = cli.main(["generate", "x", "--width", "512", "--height", "512",
                     "--ink-cap", "3", "--background", "key",
                     "--hires", "--hires-scale", "1.5", "--hires-strength", "0.3",
                     "--seeds", "1,2", "--provenance"])
    assert code == 0
    kwargs = stub["client"].generated[0][1]
    assert kwargs["ink_cap"] == 3
    assert kwargs["background"] == "key"
    assert kwargs["seeds"] == [1, 2]
    assert kwargs["provenance"] is True
    assert kwargs["hires"] == {"scale": 1.5, "strength": 0.3}


def test_hires_alone_sends_the_empty_block_the_service_fills_in(stub):
    """No flags means the documented defaults, and the service echoes them."""
    assert cli.main(["generate", "x", "--width", "512", "--height", "512",
                     "--hires"]) == 0
    assert stub["client"].generated[0][1]["hires"] == {}


def test_a_hires_flag_without_hires_is_a_usage_error(stub, capsys):
    code = cli.main(["generate", "x", "--width", "512", "--height", "512",
                     "--hires-scale", "1.5"])
    assert code == 2
    assert "--hires-scale" in capsys.readouterr().err
    assert stub["client"].generated == []


def test_a_malformed_seed_list_is_a_usage_error(stub, capsys):
    code = cli.main(["generate", "x", "--width", "512", "--height", "512",
                     "--seeds", "1,two"])
    assert code == 2
    assert "--seeds" in capsys.readouterr().err
    assert stub["client"].generated == []


def test_a_value_the_service_refuses_is_left_to_the_service(stub):
    """The CLI does not duplicate the service's ranges; it forwards them."""
    assert cli.main(["generate", "x", "--width", "512", "--height", "512",
                     "--ink-cap", "300"]) == 0
    assert stub["client"].generated[0][1]["ink_cap"] == 300


def test_the_summary_prints_what_each_pass_measured(stub, capsys):
    assert cli.main(["generate", "x", "--width", "512", "--height", "512"]) == 0
    out = capsys.readouterr().out
    assert "ink_cap: 4096 -> 3 colour(s) at most 3 (quantize)" in out
    assert "hires: 2.0x lanczos, target 1024x1024, passes [1.5, 2.0] s" in out
    assert "background: key  [not uniform, left alone]" in out
    assert "sidecar: gen-01.png.json" in out


def test_a_cap_that_changed_nothing_is_shown_as_a_skip(stub, capsys, monkeypatch):
    class Skipping(StubClient):
        def generate(self, prompt, **kwargs):
            body = super().generate(prompt, **kwargs)
            body["images"][0]["ink_cap"] = {
                "max_colors": 6, "mode": "quantize", "colors_before": 3,
                "colors_present": 3, "changed": False,
                "note": "the frame was already at 3 colour(s)"}
            return body

    monkeypatch.setattr(cli, "FluxClient", lambda *a, **k: Skipping())
    assert cli.main(["generate", "x", "--width", "512", "--height", "512"]) == 0
    assert "[nothing was reduced]" in capsys.readouterr().out


def test_a_seed_sweep_is_printed_as_a_mapping_and_nothing_more(stub, capsys,
                                                              monkeypatch):
    class Sweeping(StubClient):
        def generate(self, prompt, **kwargs):
            body = super().generate(prompt, **kwargs)
            body["seed"] = None
            body["seeds"] = [4, 5]
            body["seed_files"] = {"4": ["a.png"], "5": ["b.png"]}
            return body

    monkeypatch.setattr(cli, "FluxClient", lambda *a, **k: Sweeping())
    assert cli.main(["generate", "x", "--width", "512", "--height", "512",
                     "--seeds", "4,5"]) == 0
    out = capsys.readouterr().out
    assert "seed sweep (1 frame(s), nothing ranked):" in out
    assert "seed 4 -> a.png" in out
    assert "seed 5 -> b.png" in out
