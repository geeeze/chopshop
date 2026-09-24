#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tests for scripts/swarm_bridge.py.

Everything here stubs SwarmUI's HTTP layer (``SwarmClient._post`` /
``_get_bytes``) and the front_pipeline.sh seam, so the tests run without a
SwarmUI server or any models.  They assert the payloads are built correctly and
the subcommands wire the results to disk / the pipeline as documented.
"""

import json
import os
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")
for p in (ROOT, SCRIPTS):
    if p not in sys.path:
        sys.path.insert(0, p)

import swarm_bridge as sb  # noqa: E402
from PIL import Image  # noqa: E402


class FakeClient(sb.SwarmClient):
    """Records calls and returns canned responses; never touches the network."""

    def __init__(self):
        super().__init__(base_url="http://fake")
        self.posts = []
        self.gets = []
        self._image_data = b"not-really-png"

    def _post(self, route, payload):
        self.posts.append((route, payload))
        if route == "/API/GetNewSession":
            return {"session_id": "sess123"}
        if route == "/API/ListT2IParams":
            return {"models": {"Stable-Diffusion": [["sd_xl", "arch"]]}}
        if route == "/API/GenerateText2Image":
            return {"images": ["View/local/raw/2024-01-01/out.png"]}
        raise AssertionError("unexpected route: %s" % route)

    def _get_bytes(self, path):
        self.gets.append(path)
        return self._image_data


def _img(path, size=(20, 20), color=(255, 0, 0)):
    Image.new("RGB", size, color).save(path, "PNG")
    return str(path)


def test_build_generate_payload_defaults():
    p = sb.build_generate_payload("a cat", 1024, 768)
    assert p == {"prompt": "a cat", "width": 1024, "height": 768}


def test_build_generate_payload_full():
    p = sb.build_generate_payload("x", 512, 512, model="m", negative="n",
                                  steps=20, cfg=7.5, seed=42)
    assert p["model"] == "m"
    assert p["negativeprompt"] == "n"
    assert p["steps"] == 20
    assert p["cfgscale"] == 7.5
    assert p["seed"] == 42


def test_build_filter_payload_has_initimage(tmp_path):
    src = _img(tmp_path / "s.png")
    p = sb.build_filter_payload("make it flat", src, 30, 40, creativity=0.4)
    assert p["initimage"].startswith("data:image/png;base64,")
    assert p["initimagecreativity"] == 0.4
    assert p["width"] == 30 and p["height"] == 40


def test_apply_style_builtin():
    suffix, preset = sb.apply_style("flat-poster", "/nonexistent/styles.json")
    assert "flat" in suffix
    assert preset == "poster"


def test_apply_style_unknown():
    with pytest.raises(sb.SwarmError) as ei:
        sb.apply_style("nope", "/nonexistent/styles.json")
    assert ei.value.exit_code == 2


def test_style_sweep_json_written(tmp_path):
    target = tmp_path / "sweep.json"
    path = sb.style_sweep_json("poster", str(target))
    data = json.load(open(path, encoding="utf-8"))
    assert data["presets"] == ["poster"]
    assert data["hierarchical"] == ["cutout", "stacked"]


def test_model_note_no_models():
    ok, note = sb._model_note({})
    assert ok is False
    assert "no generation model" in note


def test_model_note_has_models():
    ok, note = sb._model_note({"Stable-Diffusion": [["m", "a"]]})
    assert ok is True and note is None


def test_generate_downloads_to_out_dir(tmp_path, monkeypatch):
    out = tmp_path / "out"
    client = FakeClient()
    monkeypatch.setattr(sb, "SwarmClient", lambda base_url, **kw: client)

    args = sb.build_argparser().parse_args(
        ["generate", "a cat", "--out-dir", str(out), "--base-url", "http://fake"])
    code = args.func(args)

    assert code == 0
    # the downloaded file is written and the manifest records it
    manifest = json.load(open(os.path.join(str(out), "swarm_generate.json"),
                              encoding="utf-8"))
    assert manifest["mode"] == "generate"
    assert len(manifest["files"]) == 1
    assert os.path.exists(manifest["files"][0])
    # session + generate were both posted
    routes = [r for r, _ in client.posts]
    assert "/API/GetNewSession" in routes
    assert "/API/GenerateText2Image" in routes


def test_generate_no_models_exits_4(tmp_path, monkeypatch):
    client = FakeClient()
    client._post = (lambda route, payload:
                    {"session_id": "s"}
                    if route == "/API/GetNewSession"
                    else {"models": {}})
    monkeypatch.setattr(sb, "SwarmClient", lambda base_url, **kw: client)

    # Exercise the real exit-code path via main() (SwarmError -> exit 4).
    code = sb.main(["generate", "a cat", "--out-dir", str(tmp_path),
                    "--base-url", "http://fake"])
    assert code == 4


def test_filter_uses_source_dimensions(tmp_path, monkeypatch):
    src = _img(tmp_path / "src.png", size=(33, 21))
    client = FakeClient()
    monkeypatch.setattr(sb, "SwarmClient", lambda base_url, **kw: client)

    args = sb.build_argparser().parse_args(
        ["filter", src, "restyle", "--out-dir", str(tmp_path / "o"),
         "--creativity", "0.3"])
    code = args.func(args)
    assert code == 0

    gen = [p for r, p in client.posts if r == "/API/GenerateText2Image"][0]
    assert gen["width"] == 33 and gen["height"] == 21
    assert gen["initimagecreativity"] == 0.3
    assert gen["initimage"].startswith("data:image/png;base64,")


def test_gen2pipe_applies_style_and_runs_pipeline(tmp_path, monkeypatch):
    runs = []
    monkeypatch.setattr(sb, "_run_front_pipeline",
                        lambda raster, sweep=None, skip_prep=False:
                        runs.append((raster, sweep, skip_prep)) or 0)
    client = FakeClient()
    monkeypatch.setattr(sb, "SwarmClient", lambda base_url, **kw: client)
    # stub download so the raster lands in tmp (FakeClient._get_bytes returns
    # a fixed byte blob, but the path is what matters for the seam)
    monkeypatch.setattr(client, "download",
                        lambda view, out_dir:
                        os.path.join(out_dir, "gen.png"))

    args = sb.build_argparser().parse_args(
        ["gen2pipe", "a dragon", "--style", "flat-poster",
         "--source-dir", str(tmp_path / "src")])
    code = args.func(args)
    assert code == 0

    gen = [p for r, p in client.posts if r == "/API/GenerateText2Image"][0]
    assert "flat vector poster" in gen["prompt"]

    assert len(runs) == 1
    raster, sweep, skip_prep = runs[0]
    assert raster.endswith("gen.png")
    assert sweep is not None and os.path.exists(sweep)
    sweep_data = json.load(open(sweep, encoding="utf-8"))
    assert sweep_data["presets"] == ["poster"]


def test_gen2pipe_pipeline_failure_exits_2(tmp_path, monkeypatch):
    monkeypatch.setattr(sb, "_run_front_pipeline", lambda *a, **k: 2)
    client = FakeClient()
    monkeypatch.setattr(sb, "SwarmClient", lambda base_url, **kw: client)
    monkeypatch.setattr(client, "download",
                        lambda view, out_dir:
                        os.path.join(out_dir, "gen.png"))

    args = sb.build_argparser().parse_args(
        ["gen2pipe", "x", "--source-dir", str(tmp_path / "src")])
    with pytest.raises(sb.SwarmError) as ei:
        args.func(args)
    assert ei.value.exit_code == 2


def test_connect_unreachable_exits_3(monkeypatch):
    client = sb.SwarmClient(base_url="http://127.0.0.1:1")

    def boom(route, payload):
        raise OSError("connection refused")
    monkeypatch.setattr(client, "_post", boom)
    with pytest.raises(sb.SwarmError) as ei:
        client.connect()
    assert ei.value.exit_code == 3


def test_resolve_model_explicit_wins():
    models = {"Stable-Diffusion": [["sd_xl", "arch"]]}
    assert sb._resolve_model(models, "my_model.safetensors") == "my_model.safetensors"


def test_resolve_model_falls_back_to_first_sd():
    models = {"Stable-Diffusion": [["sd_xl_base.safetensors", "arch"],
                                   ["other.safetensors", "arch"]]}
    assert sb._resolve_model(models) == "sd_xl_base.safetensors"


def test_resolve_model_handles_diffusion_models_key():
    models = {"diffusion_models": ["foo.safetensors"]}
    assert sb._resolve_model(models) == "foo.safetensors"


def test_resolve_model_none_when_empty():
    assert sb._resolve_model({}) is None
    assert sb._resolve_model({"Stable-Diffusion": []}) is None


def test_generate_without_model_resolves_first_sd(tmp_path, monkeypatch):
    # No --model on the CLI: the bridge must auto-select the first SD model so
    # a fresh SwarmUI (no default selected) does not answer "No model input".
    out = tmp_path / "out"
    client = FakeClient()
    monkeypatch.setattr(sb, "SwarmClient", lambda base_url, **kw: client)

    args = sb.build_argparser().parse_args(
        ["generate", "a cat", "--out-dir", str(out), "--base-url", "http://fake"])
    code = args.func(args)

    assert code == 0
    gen = [p for r, p in client.posts if r == "/API/GenerateText2Image"][0]
    assert gen["model"] == "sd_xl"


def test_run_front_pipeline_uses_sweep_equals_form(monkeypatch):
    calls = []
    monkeypatch.setattr(sb.subprocess, "call", lambda argv: calls.append(argv) or 0)
    sb._run_front_pipeline("/tmp/x.png", sweep="/tmp/sweep.json", skip_prep=True)
    assert calls == [
        [sb.os.path.join(sb.PROJECT, "front_pipeline.sh"), "/tmp/x.png",
         "--sweep=/tmp/sweep.json", "--skip-prep"]
    ]


def test_get_bytes_percent_encodes_prompt_spaces(monkeypatch):
    # SwarmUI image paths embed the prompt (spaces, commas). A raw path would
    # make urllib raise InvalidURL; _get_bytes must percent-encode it.
    client = sb.SwarmClient(base_url="http://fake")
    captured = {}

    class _Resp:
        def read(self):
            return b"png-bytes"
        def __enter__(self):
            return self
        def __exit__(self, *a):
            return False

    def fake_urlopen(url, timeout=None):
        captured["url"] = url
        return _Resp()

    monkeypatch.setattr(sb.urllib.request, "urlopen", fake_urlopen)
    path = ("View/local/raw/2026-09-24/1137-a flat vector dragon emblem, "
            "limited fla-sd_xl.png")
    data = client._get_bytes(path)

    assert data == b"png-bytes"
    assert " " not in captured["url"]
    assert "%20" in captured["url"]
    assert captured["url"] == ("http://fake/View/local/raw/2026-09-24/"
                               "1137-a%20flat%20vector%20dragon%20emblem%2C"
                               "%20limited%20fla-sd_xl.png")
