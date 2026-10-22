"""The CLI's modifier flags and its three new listing commands.

The stub client pattern is the same one test_cli.py uses — no network, no
service, and the assertion is on the request body the command built.
"""

import json

import pytest

from chopshop_flux import cli
from chopshop_flux.modifiers import MODIFIERS, VAES


class StubClient:
    def __init__(self, *args, **kwargs):
        self.generated = []
        self.edited = []

    def generate(self, prompt, **kwargs):
        self.generated.append((prompt, kwargs))
        scales = kwargs.get("modifier_scales") or {}
        return {"seed": 11, "steps": 4, "guidance": 1.0, "total_seconds": 1.0,
                "load_seconds": 2.0, "warnings": [],
                "modifiers": [{"key": k, "scale": scales.get(k, 1.0)}
                              for k in kwargs.get("modifiers") or []],
                "vae": kwargs.get("vae"), "scheduler": None,
                "images": [{"name": "g-01.png", "width": 512, "height": 512,
                            "bytes": 10, "seconds": 1.0}]}

    def edit(self, source, prompt, **kwargs):
        self.edited.append((source, prompt, kwargs))
        return self.generate(prompt, **kwargs)

    def download(self, name, out_dir):
        return "%s/%s" % (out_dir, name)

    def health(self):
        return {"ok": True, "service": "chopshop-flux"}

    def models(self):
        return {"models": [], "modifiers": [], "vaes": []}


@pytest.fixture
def stub(monkeypatch):
    holder = {}

    def factory(*args, **kwargs):
        holder["client"] = StubClient()
        return holder["client"]

    monkeypatch.setattr(cli, "FluxClient", factory)
    return holder


# -- the flags -------------------------------------------------------------

def test_generate_forwards_a_repeatable_lora_flag(stub):
    code = cli.main(["generate", "x", "--width", "512", "--height", "512",
                     "--model", "sdxl-1.0",
                     "--lora", "pixel-art-xl", "--lora", "lcm-lora-sdxl"])
    assert code == 0
    _prompt, kwargs = stub["client"].generated[-1]
    assert kwargs["modifiers"] == ["pixel-art-xl", "lcm-lora-sdxl"]


def test_generate_forwards_a_lora_scale(stub):
    code = cli.main(["generate", "x", "--width", "512", "--height", "512",
                     "--model", "sdxl-1.0", "--lora", "pixel-art-xl",
                     "--lora-scale", "pixel-art-xl=0.8"])
    assert code == 0
    _prompt, kwargs = stub["client"].generated[-1]
    assert kwargs["modifier_scales"] == {"pixel-art-xl": 0.8}


def test_generate_forwards_a_vae(stub):
    code = cli.main(["generate", "x", "--width", "512", "--height", "512",
                     "--model", "sdxl-1.0", "--vae", "taesdxl"])
    assert code == 0
    _prompt, kwargs = stub["client"].generated[-1]
    assert kwargs["vae"] == "taesdxl"


def test_edit_forwards_the_modifier_flags(stub, tmp_path):
    source = tmp_path / "src.png"
    source.write_bytes(b"x")
    code = cli.main(["edit", str(source), "flatten", "--width", "512",
                     "--height", "512", "--model", "sdxl-1.0",
                     "--lora", "colouring-book", "--vae", "sdxl-vae-fp16-fix"])
    assert code == 0
    _source, _prompt, kwargs = stub["client"].edited[-1]
    assert kwargs["modifiers"] == ["colouring-book"]
    assert kwargs["vae"] == "sdxl-vae-fp16-fix"


def test_the_modifier_knobs_are_unset_unless_asked_for(stub):
    """An ordinary request must send the body it always did."""
    cli.main(["generate", "x", "--width", "512", "--height", "512"])
    _prompt, kwargs = stub["client"].generated[-1]
    assert "modifiers" not in kwargs
    assert "modifier_scales" not in kwargs
    assert "vae" not in kwargs


def test_a_malformed_lora_scale_is_a_usage_error(stub):
    assert cli.main(["generate", "x", "--width", "512", "--height", "512",
                     "--lora", "pixel-art-xl",
                     "--lora-scale", "pixel-art-xl"]) == 2
    assert cli.main(["generate", "x", "--width", "512", "--height", "512",
                     "--lora", "pixel-art-xl",
                     "--lora-scale", "pixel-art-xl=heavy"]) == 2
    assert cli.main(["generate", "x", "--width", "512", "--height", "512",
                     "--lora", "pixel-art-xl",
                     "--lora-scale", "=0.5"]) == 2


def test_a_scale_with_no_adapter_is_a_usage_error(stub):
    """A scale with nothing to apply it to is a mistake in the command, not a
    request the service should have to warn about."""
    code = cli.main(["generate", "x", "--width", "512", "--height", "512",
                     "--lora-scale", "pixel-art-xl=0.5"])
    assert code == 2
    assert not stub["client"].generated


def test_gen2pipe_carries_the_modifier_flags(stub, monkeypatch, tmp_path):
    monkeypatch.setattr(cli, "run_pipeline", lambda raster, **kwargs: 0)
    code = cli.main(["gen2pipe", "x", "--width", "512", "--height", "512",
                     "--out", str(tmp_path), "--model", "sdxl-1.0",
                     "--lora", "stickers"])
    assert code == 0
    _prompt, kwargs = stub["client"].generated[-1]
    assert kwargs["modifiers"] == ["stickers"]


def test_json_output_carries_the_applied_modifiers(stub, capsys):
    cli.main(["generate", "x", "--width", "512", "--height", "512",
              "--model", "sdxl-1.0", "--lora", "pixel-art-xl", "--json"])
    payload = json.loads(capsys.readouterr().out)
    assert payload["modifiers"] == [{"key": "pixel-art-xl", "scale": 1.0}]


def test_the_summary_prints_what_was_applied(stub, capsys):
    cli.main(["generate", "x", "--width", "512", "--height", "512",
              "--model", "sdxl-1.0", "--lora", "pixel-art-xl",
              "--lora-scale", "pixel-art-xl=0.5"])
    out = capsys.readouterr().out
    assert "applied: pixel-art-xl@0.5" in out


# -- the listing commands --------------------------------------------------

def test_modifiers_lists_every_registry_entry(capsys):
    assert cli.main(["modifiers"]) == 0
    out = capsys.readouterr().out
    for key in MODIFIERS:
        assert key in out, key
    # The exact weight filename is part of the entry's identity, so it is shown.
    assert "sdxl_lightning_4step_lora.safetensors" in out


def test_vaes_lists_every_registry_entry_and_marks_the_tiny_ones(capsys):
    assert cli.main(["vaes"]) == 0
    out = capsys.readouterr().out
    for key in VAES:
        assert key in out, key
    assert "AutoencoderTiny" in out
    assert "AutoencoderKL" in out


def test_modifiers_and_vaes_can_print_json(capsys):
    assert cli.main(["modifiers", "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert len(payload) == len(MODIFIERS)
    assert cli.main(["vaes", "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert len(payload) == len(VAES)


def test_modifiers_does_not_need_a_service(monkeypatch, capsys):
    """The registries are the same compiled-in facts on both sides, so listing
    them must not require the GPU box to be up."""

    def explode(*args, **kwargs):
        raise AssertionError("the modifiers command must not call the service")

    monkeypatch.setattr(cli, "FluxClient", explode)
    assert cli.main(["modifiers"]) == 0
    assert cli.main(["vaes"]) == 0


def test_examples_lists_the_bundled_set_with_its_coverage_checked(capsys):
    assert cli.main(["examples"]) == 0
    out = capsys.readouterr().out
    assert "klein-emblem-t2i" in out
    assert "sana-sprint-0.6b" in out


def test_examples_prints_json(capsys):
    assert cli.main(["examples", "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert isinstance(payload, list)
    assert payload and "what_it_proves" in payload[0]


def test_an_invalid_example_set_is_a_usage_error(tmp_path, capsys):
    broken = tmp_path / "prompts.json"
    broken.write_text(json.dumps([{"id": "x", "model": "klein-4b"}]))
    assert cli.main(["examples", "--examples", str(broken)]) == 2


def test_a_missing_example_file_is_a_usage_error(tmp_path):
    assert cli.main(["examples", "--examples",
                     str(tmp_path / "nope.json")]) == 2


def test_python_dash_m_lists_the_new_commands():
    import subprocess
    import sys
    import os

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    result = subprocess.run([sys.executable, "-m", "chopshop_flux", "--help"],
                            cwd=root, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    for command in ("serve", "health", "models", "generate", "edit", "gen2pipe",
                    "modifiers", "vaes", "examples"):
        assert command in result.stdout, command


def test_examples_and_modifiers_run_without_torch():
    """These commands are pure registry reads and must work on any box."""
    import subprocess
    import sys
    import os

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for command in ("modifiers", "vaes", "examples"):
        code = ("import sys, chopshop_flux.cli as c; "
                "raise SystemExit(c.main(['%s']))" % command)
        result = subprocess.run([sys.executable, "-c", code], cwd=root,
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, (command, result.stderr)
