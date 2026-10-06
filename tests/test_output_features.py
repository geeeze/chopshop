"""The output-side passes end to end through ``FluxEngine.generate``.

No GPU, no torch, no Pillow — but REAL pixels: the fake pipeline hands back a
frame that carries bytes, `Image.frombytes` rebuilds one from the buffer the
passes produce, and ``save`` writes that buffer to disk. So the assertions here
are about the file that landed, not about a key existing somewhere:

* a request using NONE of the new keys is byte-for-byte the request this build
  made before them — the same pipeline kwargs, the same PNG bytes, the same
  response body (pinned from ``scripts/probe_output_path.py`` run against the
  committed tree; the clock is the only thing normalised away);
* every new key is validated, and a bad value is a 400 NAMING THE KEY rather
  than a silent default;
* the passes report what they measured, including when they changed nothing;
* nothing ranks.
"""

import hashlib
import json
import os
import re
import sys
import types

import pytest

from chopshop_flux.engine import FluxEngine, _resampling_flag
from chopshop_flux.models import (PRINT_NEGATIVE_PROMPT, REGISTRY, ModelError,
                                  resolve)
from chopshop_flux.postprocess import Frame

# -- a fake PIL whose frames carry real pixels ------------------------------

# (size, flag) for every resize, so the upscaler can be asserted rather than
# assumed. Cleared per test by the fixture below.
RESIZES: list = []

RESAMPLING = types.SimpleNamespace(LANCZOS="LANCZOS", NEAREST="NEAREST",
                                   BILINEAR="BILINEAR", BICUBIC="BICUBIC")


class PixelImage:
    """A decoded frame with real bytes behind it, and PIL's reading surface."""

    def __init__(self, mode, width, height, data):
        self.mode = mode
        self.width = width
        self.height = height
        self.data = data

    def convert(self, mode):  # noqa: A002 - PIL's own name
        return self

    def tobytes(self):
        return self.data

    def resize(self, size, flag):
        RESIZES.append((tuple(size), flag))
        channels = 3 if self.mode == "RGB" else 4
        target_width, target_height = size
        out = bytearray()
        for y in range(target_height):
            source_y = min(self.height - 1, int(y * self.height / target_height))
            for x in range(target_width):
                source_x = min(self.width - 1, int(x * self.width / target_width))
                offset = (source_y * self.width + source_x) * channels
                out += self.data[offset:offset + channels]
        return PixelImage(self.mode, target_width, target_height, bytes(out))

    def save(self, path, format=None):  # noqa: A002 - PIL's own name
        # The RAW pixels, deliberately: the test then reads the file back as the
        # buffer the passes produced, which is what makes the ink counts below
        # evidence about the file rather than about the pipeline object.
        with open(path, "wb") as handle:
            handle.write(self.data)


class Pipe:
    """Records every pass and returns the frame it was handed, if any."""

    def __init__(self, frames):
        self.frames = list(frames)
        self.calls = []

    def __call__(self, **kwargs):
        self.calls.append(kwargs)
        given = kwargs.get("image")
        if isinstance(given, PixelImage):
            return types.SimpleNamespace(images=[given])
        count = kwargs.get("num_images_per_prompt", 1)
        return types.SimpleNamespace(images=list(self.frames[:count]))


def frame(width, height, fn, mode="RGB") -> PixelImage:
    channels = 3 if mode == "RGB" else 4
    data = bytearray()
    for y in range(height):
        for x in range(width):
            colour = fn(x, y)
            data += bytes(colour[:channels]) if channels == 3 else bytes(colour)
    return PixelImage(mode, width, height, bytes(data))


def solid(width=8, height=8, colour=(200, 30, 30)) -> PixelImage:
    return frame(width, height, lambda x, y: colour)


def gradient(width=8, height=8) -> PixelImage:
    return frame(width, height,
                 lambda x, y: (x * 32 % 256, y * 32 % 256, (x + y) * 16 % 256))


def bordered(width=16, height=16):
    """A uniform white border with an interior rectangle: keyable."""
    return frame(width, height,
                 lambda x, y: (0, 0, 0)
                 if (4 <= y <= height - 5 and 4 <= x <= width - 5)
                 else (255, 255, 255))


def _install_fake_pil(monkeypatch):
    class _Opened:
        def convert(self, mode):
            return "CONVERTED:%s" % mode

    image = types.SimpleNamespace(
        open=staticmethod(lambda fp: _Opened()),
        frombytes=staticmethod(lambda mode, size, data: PixelImage(
            mode, size[0], size[1], bytes(data))),
        Resampling=RESAMPLING, LANCZOS=RESAMPLING.LANCZOS,
        NEAREST=RESAMPLING.NEAREST, BILINEAR=RESAMPLING.BILINEAR,
        BICUBIC=RESAMPLING.BICUBIC)
    module = types.ModuleType("PIL")
    module.Image = image
    monkeypatch.setitem(sys.modules, "PIL", module)
    return module


def _install_fake_torch(monkeypatch):
    class _Ctx:
        def __enter__(self):
            return None

        def __exit__(self, *exc):
            return False

    class _Generator:
        def manual_seed(self, seed):
            return self

    module = types.ModuleType("torch")
    module.inference_mode = staticmethod(lambda: _Ctx())
    module.Generator = staticmethod(lambda: _Generator())
    monkeypatch.setitem(sys.modules, "torch", module)
    return module


@pytest.fixture(autouse=True)
def _no_leftover_resizes():
    RESIZES.clear()
    yield
    RESIZES.clear()


def engine_with(monkeypatch, tmp_path, frames, model="klein-4b", loads=None):
    """An engine whose pipeline is a recorder and which never loads anything."""
    fake_torch = _install_fake_torch(monkeypatch)
    _install_fake_pil(monkeypatch)
    engine = FluxEngine(out_dir=str(tmp_path))
    pipe = Pipe(frames)
    engine._pipe = pipe
    engine._torch = fake_torch

    def fake_load(name=None, **kwargs):
        # The output-side keys must not change WHICH pipeline a request needs,
        # so load() is stubbed; `loads` counts how many times it was asked.
        if loads is not None:
            loads.append(name or model)
        return resolve(model)

    monkeypatch.setattr(engine, "load", fake_load)
    return engine, pipe


def written(tmp_path, name) -> bytes:
    return (tmp_path / name).read_bytes()


def normalise(body: dict, tmp_path) -> dict:
    """Drop the two things that are not part of the request path: the UTC stamp
    and the wall clock."""
    text = json.dumps(body, sort_keys=True)
    text = re.sub(r"\d{8}T\d{6}Z", "<STAMP>", text)
    text = text.replace(str(tmp_path), "<OUT>")
    text = re.sub(r'"(seconds|total_seconds|queue_wait_seconds)": [0-9.]+',
                  r'"\1": "<CLOCK>"', text)
    return json.loads(text)


# -- the determinism pin ---------------------------------------------------
#
# Captured by running scripts/probe_output_path.py against the COMMITTED tree
# (git archive HEAD into a scratch dir) and again against this worktree: the two
# outputs diff clean. These are the after-run's normalised values.

GOLDEN_RESPONSE = {
    "commercial_ok": True, "edited": False, "guidance": 1.0, "height": 512,
    "images": [{"bytes": 14, "height": 8, "model": "klein-4b",
                "name": "<STAMP>-klein-4b-s4242-01.png",
                "path": "<OUT>/<STAMP>-klein-4b-s4242-01.png",
                "seconds": "<CLOCK>", "seed": 4242,
                "sha256": ("4f233fc32323053ab0df2c32bd99f2cd"
                           "084b6347e29a28a3fdb9ee08a771038a"),
                "width": 8}],
    "license": "Apache-2.0", "load_seconds": None, "model": "klein-4b",
    "modifiers": [], "negative_prompt": None, "prompt": "a phoenix emblem",
    "queue_wait_seconds": "<CLOCK>", "references": 0,
    "repo_id": "black-forest-labs/FLUX.2-klein-4B", "scheduler": None,
    "seed": 4242, "steps": 4, "strength": None, "total_seconds": "<CLOCK>",
    "vae": None, "warnings": [], "width": 512,
}

# The exact kwargs the pipeline is called with, normalised (the generator is an
# object). The generator is the whole reason the seed is reproducible.
GOLDEN_PIPELINE_KWARGS = {
    "generator": "<GENERATOR>", "guidance_scale": 1.0, "height": 512,
    "image": None, "num_images_per_prompt": 1, "num_inference_steps": 4,
    "output_type": "pil", "prompt": "a phoenix emblem", "width": 512,
}

GOLDEN_PNG_SHA256 = ("4f233fc32323053ab0df2c32bd99f2cd"
                     "084b6347e29a28a3fdb9ee08a771038a")


def test_a_request_using_none_of_the_new_keys_is_the_request_it_always_was(
        monkeypatch, tmp_path):
    """The acceptance criterion, pinned rather than promised.

    Same pipeline kwargs, same PNG bytes, same response body — captured from the
    committed build by scripts/probe_output_path.py before any of this landed.
    """
    engine, pipe = engine_with(monkeypatch, tmp_path,
                               [PixelImage("RGB", 8, 8, b"FRAME-seed4242")])
    body = engine.generate(prompt="a phoenix emblem", width=512, height=512,
                           seed=4242)

    assert normalise(body, tmp_path) == GOLDEN_RESPONSE

    kwargs = pipe.calls[-1]
    normalised_kwargs = {key: ("<GENERATOR>" if key == "generator" else value)
                         for key, value in kwargs.items()}
    assert normalised_kwargs == GOLDEN_PIPELINE_KWARGS

    assert body["images"][0]["sha256"] == GOLDEN_PNG_SHA256
    assert hashlib.sha256(written(tmp_path, body["images"][0]["name"])).hexdigest() \
        == GOLDEN_PNG_SHA256
    # And no new FILE: a request that asked for no sidecar writes none.
    assert sorted(os.listdir(tmp_path)) == [body["images"][0]["name"]]


def test_the_new_keys_are_absent_from_a_request_that_did_not_use_them(
        monkeypatch, tmp_path):
    """Not merely "the same values": the KEYS are not there at all.

    A caller reading the response finds exactly the fields it always found, which
    is the rule the modifier knobs already follow.
    """
    engine, _pipe = engine_with(monkeypatch, tmp_path, [solid()])
    body = engine.generate(prompt="x", width=512, height=512, seed=1)
    for key in ("ink_cap", "background", "hires", "seeds", "seed_files",
                "provenance", "negative_prompt_source"):
        assert key not in body, key
    for key in ("ink_cap", "background", "hires", "provenance", "sidecar"):
        assert key not in body["images"][0], key


# -- per-key validation: a bad value is a 400 naming the KEY ---------------

@pytest.mark.parametrize("kwargs,expected", [
    ({"ink_cap": 1}, "ink_cap"),
    ({"ink_cap": 300}, "ink_cap"),
    ({"ink_cap": "three"}, "ink_cap"),
    ({"ink_cap": 3, "ink_cap_mode": "kmeans"}, "ink_cap_mode"),
    ({"ink_cap_mode": "quantize"}, "ink_cap_mode"),
    ({"ink_cap": 3, "ink_cap_mode": "posterize"}, "ink_cap"),
    ({"background": "chroma"}, "background"),
    ({"hires": 2.0}, "hires must be an object"),
    ({"hires": {"scale": 1.2}}, "hires.scale"),
    ({"hires": {"scale": 2.5}}, "hires.scale"),
    ({"hires": {"strength": 0.6}}, "hires.strength"),
    ({"hires": {"zoom": 9}}, "hires.zoom"),
    ({"hires": {"upscaler": "waifu2x"}}, "hires.upscaler"),
    ({"seeds": "7"}, "seeds"),
    ({"seeds": []}, "seeds"),
    ({"seeds": [1, "x"]}, "seeds[1]"),
    ({"provenance": "yes"}, "provenance"),
])
def test_a_bad_output_key_is_a_caller_error_naming_the_key(
        kwargs, expected, monkeypatch, tmp_path):
    """Refused BEFORE anything is loaded — no torch, no pipeline, no model.

    ``sys.modules["torch"]`` is set to None, so any import would explode: this
    test only passes if the check fires on the request path.
    """
    monkeypatch.setitem(sys.modules, "torch", None)
    engine = FluxEngine(out_dir=str(tmp_path))
    with pytest.raises(ModelError) as caught:
        engine.generate(prompt="x", width=512, height=512, **kwargs)
    assert expected in str(caught.value)
    assert caught.value.exit_code == 2


def test_seeds_and_seed_together_are_refused_naming_seeds(monkeypatch, tmp_path):
    monkeypatch.setitem(sys.modules, "torch", None)
    with pytest.raises(ModelError) as caught:
        FluxEngine(out_dir=str(tmp_path)).generate(
            prompt="x", width=512, height=512, seed=3, seeds=[1, 2])
    assert "seeds" in str(caught.value) and "seed" in str(caught.value)


# -- the per-family negative prompt default --------------------------------

def test_an_entry_with_a_real_negative_prompt_sends_the_print_default(
        monkeypatch, tmp_path):
    engine, pipe = engine_with(monkeypatch, tmp_path, [solid()], model="sdxl-1.0")
    body = engine.generate(prompt="x", model="sdxl-1.0", width=512, height=512,
                           seed=1)
    assert body["negative_prompt"] == PRINT_NEGATIVE_PROMPT
    assert body["negative_prompt_source"] == "default"
    assert pipe.calls[-1]["negative_prompt"] == PRINT_NEGATIVE_PROMPT


def test_an_empty_negative_prompt_is_a_choice_that_sends_none(
        monkeypatch, tmp_path):
    """The escape hatch: "" is how a caller asks for the pre-default request."""
    engine, pipe = engine_with(monkeypatch, tmp_path, [solid()], model="sdxl-1.0")
    body = engine.generate(prompt="x", model="sdxl-1.0", width=512, height=512,
                           seed=1, negative_prompt="")
    assert body["negative_prompt"] == ""
    assert "negative_prompt_source" not in body
    assert pipe.calls[-1]["negative_prompt"] == ""


def test_a_callers_own_negative_prompt_is_never_replaced_by_the_default(
        monkeypatch, tmp_path):
    engine, pipe = engine_with(monkeypatch, tmp_path, [solid()], model="sdxl-1.0")
    body = engine.generate(prompt="x", model="sdxl-1.0", width=512, height=512,
                           seed=1, negative_prompt="harsh edges")
    assert body["negative_prompt"] == "harsh edges"
    assert "negative_prompt_source" not in body
    assert pipe.calls[-1]["negative_prompt"] == "harsh edges"


def test_an_entry_without_a_negative_prompt_keeps_the_ignored_warning(
        monkeypatch, tmp_path):
    """klein has no negative_prompt parameter, and the answer does not change."""
    engine, _pipe = engine_with(monkeypatch, tmp_path, [solid()])
    body = engine.generate(prompt="x", width=512, height=512, seed=1,
                           negative_prompt="blurry")
    assert any("negative prompt ignored" in w for w in body["warnings"])
    assert body["negative_prompt"] == "blurry"
    assert "negative_prompt_source" not in body


def test_only_entries_whose_pipeline_takes_a_negative_prompt_carry_a_default():
    """A default for a parameter that does not exist would be a silent lie."""
    for key, spec in REGISTRY.items():
        if spec.default_negative_prompt is not None:
            assert spec.negative_prompt is True, key
            assert spec.default_negative_prompt == PRINT_NEGATIVE_PROMPT
    with_default = sorted(k for k, s in REGISTRY.items()
                          if s.default_negative_prompt)
    assert with_default == ["sd-1.5", "sdxl-1.0", "sdxl-turbo", "ssd-1b"]


# -- `ink_cap` -------------------------------------------------------------

def test_the_cap_reaches_the_file_and_reports_both_numbers(monkeypatch, tmp_path):
    source = gradient()
    assert source.mode == "RGB"
    before = Frame("RGB", source.width, source.height, source.data).color_count()
    assert before == 64
    engine, _pipe = engine_with(monkeypatch, tmp_path, [source])
    body = engine.generate(prompt="x", width=512, height=512, seed=1, ink_cap=3)

    report = body["images"][0]["ink_cap"]
    assert report["max_colors"] == 3 and report["mode"] == "quantize"
    assert report["colors_before"] == before
    assert report["colors_present"] <= 3 and report["changed"] is True

    raw = written(tmp_path, body["images"][0]["name"])
    on_disk = Frame("RGB", 8, 8, raw)
    assert on_disk.color_count() == report["colors_present"] <= 3
    assert body["ink_cap"] == {"max_colors": 3, "mode": "quantize"}


def test_a_cap_that_changes_nothing_leaves_the_file_and_says_so(
        monkeypatch, tmp_path):
    source = borderless_two_colour()
    engine, _pipe = engine_with(monkeypatch, tmp_path, [source])
    body = engine.generate(prompt="x", width=512, height=512, seed=1, ink_cap=6)
    report = body["images"][0]["ink_cap"]
    assert report["colors_before"] == report["colors_present"] == 2
    assert report["changed"] is False
    assert "nothing was reduced" in report["note"]
    assert written(tmp_path, body["images"][0]["name"]) == source.data


def borderless_two_colour():
    return frame(8, 8, lambda x, y: (0, 0, 0) if x < 4 else (255, 255, 255))


def test_posterize_caps_at_its_own_floor_and_reports_the_count_present(
        monkeypatch, tmp_path):
    engine, _pipe = engine_with(monkeypatch, tmp_path, [gradient()])
    body = engine.generate(prompt="x", width=512, height=512, seed=1,
                           ink_cap=8, ink_cap_mode="posterize")
    report = body["images"][0]["ink_cap"]
    assert report["mode"] == "posterize" and report["max_colors"] == 8
    assert report["colors_present"] <= 8 and report["levels_per_channel"] == 2


def test_a_cap_on_a_transparent_frame_keeps_the_alpha(monkeypatch, tmp_path):
    """A frame that arrived RGBA (a keyed one) is capped without losing alpha."""
    data = bytearray()
    for y in range(8):
        for x in range(8):
            data += bytes((x * 32 % 256, y * 32 % 256, (x + y) * 16 % 256,
                           0 if x == 7 else 200))
    engine, _pipe = engine_with(monkeypatch, tmp_path,
                                [PixelImage("RGBA", 8, 8, bytes(data))])
    body = engine.generate(prompt="x", width=512, height=512, seed=1, ink_cap=4)
    raw = written(tmp_path, body["images"][0]["name"])
    assert len(raw) == 8 * 8 * 4                      # still RGBA
    assert all(raw[offset + 3] in (0, 200)
               for offset in range(0, len(raw), 4))
    assert len({raw[offset:offset + 3] for offset in range(0, len(raw), 4)}) <= 4
    assert body["images"][0]["ink_cap"]["colors_present"] <= 4


# -- `background` ----------------------------------------------------------

def test_key_writes_transparency_where_the_border_was(monkeypatch, tmp_path):
    engine, _pipe = engine_with(monkeypatch, tmp_path, [bordered()])
    body = engine.generate(prompt="x", width=512, height=512, seed=1,
                           background="key")
    report = body["images"][0]["background"]
    assert report["uniform"] is True and report["key_color"] == "#ffffff"
    assert report["pixels_moved"] == 192 and report["changed"] is True
    raw = written(tmp_path, body["images"][0]["name"])
    assert Frame("RGBA", 16, 16, raw).mode == "RGBA"
    assert sum(1 for offset in range(3, len(raw), 4) if raw[offset] == 0) == 192
    assert body["background"] == "key"


def test_a_non_uniform_border_is_left_alone_and_the_file_is_untouched(
        monkeypatch, tmp_path):
    source = frame(16, 16, lambda x, y: (0, 0, 255) if (x, y) == (0, 0)
                   else ((0, 0, 0) if (4 <= y <= 11 and 4 <= x <= 11)
                         else (255, 255, 255)))
    engine, _pipe = engine_with(monkeypatch, tmp_path, [source])
    body = engine.generate(prompt="x", width=512, height=512, seed=1,
                           background="key")
    report = body["images"][0]["background"]
    assert report["uniform"] is False and report["changed"] is False
    assert "not uniform, left alone" in report["note"]
    assert written(tmp_path, body["images"][0]["name"]) == source.data


def test_white_flattens_a_transparent_frame_onto_white(monkeypatch, tmp_path):
    data = bytearray()
    for y in range(4):
        for x in range(4):
            data += bytes((10, 20, 30, 0 if x == 0 else 255))
    engine, _pipe = engine_with(monkeypatch, tmp_path,
                                [PixelImage("RGBA", 4, 4, bytes(data))])
    body = engine.generate(prompt="x", width=512, height=512, seed=1,
                           background="white")
    report = body["images"][0]["background"]
    assert report["changed"] is True and report["transparent_pixels"] == 4
    raw = written(tmp_path, body["images"][0]["name"])
    assert len(raw) == 4 * 4 * 3                     # flattened to RGB
    assert raw[0:3] == b"\xff\xff\xff"               # the transparent pixel


def test_an_explicit_keep_is_echoed_and_changes_nothing(monkeypatch, tmp_path):
    source = bordered()
    engine, _pipe = engine_with(monkeypatch, tmp_path, [source])
    body = engine.generate(prompt="x", width=512, height=512, seed=1,
                           background="keep")
    assert body["background"] == "keep"
    assert "background" not in body["images"][0]
    assert written(tmp_path, body["images"][0]["name"]) == source.data


# -- `hires` ---------------------------------------------------------------

def test_hires_runs_two_passes_and_reports_each_second_and_the_target(
        monkeypatch, tmp_path):
    """The second pass gets the UPSCALED frame and the low strength.

    The request is 128 px and so is the frame the fake pipeline returns, because
    the hires target is computed from the frame that came back — a pipeline that
    re-bins a size gets its real size reported, not the requested one.
    """
    engine, pipe = engine_with(monkeypatch, tmp_path, [solid(128, 128)],
                               model="sdxl-1.0")
    body = engine.generate(prompt="x", model="sdxl-1.0", width=128, height=128,
                           seed=1, hires={"scale": 2.0, "strength": 0.35})
    assert len(pipe.calls) == 2
    first, second = pipe.calls
    # Pass one is the request exactly as it would have been without hires.
    assert first["width"] == 128 and first["height"] == 128
    assert first["num_inference_steps"] == 30
    assert "image" not in first and "strength" not in first
    # Pass two is the upscaled frame at the low strength.
    assert (second["width"], second["height"]) == (256, 256)
    assert second["strength"] == 0.35
    assert second["num_inference_steps"] == 30      # the request's own steps
    assert isinstance(second["image"], PixelImage)
    assert (second["image"].width, second["image"].height) == (256, 256)
    assert second["negative_prompt"] == PRINT_NEGATIVE_PROMPT
    # The filter is the documented default, and it is the one that ran.
    assert RESIZES[-1] == ((256, 256), "LANCZOS")

    entry = body["images"][0]
    assert (entry["width"], entry["height"]) == (256, 256)
    assert entry["hires"]["target"] == [256, 256]
    assert entry["hires"]["upscaler"] == "lanczos"
    assert entry["hires"]["steps"] == 30
    assert len(entry["hires"]["pass_seconds"]) == 2
    assert body["hires"]["scale"] == 2.0
    assert body["hires"]["target"] == [256, 256]
    assert len(body["hires"]["pass_seconds"]) == 2
    # The frame written is the SECOND pass's, not the first one's.
    assert written(tmp_path, entry["name"]) == second["image"].data


def test_hires_steps_can_be_asked_for_and_the_upscaler_chosen(monkeypatch, tmp_path):
    engine, pipe = engine_with(monkeypatch, tmp_path, [solid(128, 128)],
                               model="sd-1.5")
    body = engine.generate(prompt="x", model="sd-1.5", width=128, height=128,
                           seed=1, hires={"scale": 1.5, "strength": 0.2,
                                          "steps": 12, "upscaler": "nearest"})
    assert pipe.calls[-1]["num_inference_steps"] == 12
    assert RESIZES[-1] == ((192, 192), "NEAREST")
    assert body["hires"]["steps"] == 12
    assert (body["images"][0]["width"], body["images"][0]["height"]) == (192, 192)


def test_hires_inherits_the_requests_step_count(monkeypatch, tmp_path):
    """#13: pass 2 used to fall back to the MODEL's default, so `--steps 20`
    bought a cheaper first pass and a full-price second one — and the record
    said 30 with no sign that 20 had been asked for. Pass 2 is the dearer of
    the two (measured 4.21 s then 7.80 s), which is what made it a cost bug."""
    engine, pipe = engine_with(monkeypatch, tmp_path, [solid(128, 128)],
                               model="sdxl-1.0")
    body = engine.generate(prompt="x", model="sdxl-1.0", width=128, height=128,
                           steps=7, seed=1,
                           hires={"scale": 2.0, "strength": 0.35})
    assert [call["num_inference_steps"] for call in pipe.calls] == [7, 7]
    entry = body["images"][0]
    assert entry["hires"]["steps"] == 7
    assert entry["hires"]["requested_steps"] == 7


def test_an_explicit_hires_steps_wins_and_both_numbers_are_recorded(
        monkeypatch, tmp_path):
    """The deliberate form of #13: a caller who really wants a different second
    pass says so, and the record shows the pair rather than one number."""
    engine, pipe = engine_with(monkeypatch, tmp_path, [solid(128, 128)],
                               model="sdxl-1.0")
    body = engine.generate(prompt="x", model="sdxl-1.0", width=128, height=128,
                           steps=7, seed=1,
                           hires={"scale": 2.0, "strength": 0.35, "steps": 12})
    assert [call["num_inference_steps"] for call in pipe.calls] == [7, 12]
    entry = body["images"][0]
    assert entry["hires"]["steps"] == 12
    assert entry["hires"]["requested_steps"] == 7


# -- the size that actually came back (#11) ---------------------------------

def test_a_re_binned_frame_is_called_out_in_the_response(monkeypatch, tmp_path):
    """#11: requested_* and produced dims were recorded and nothing read the
    pair, so a re-binned frame still looked like the size that was asked for.
    Sana Sprint bins by default — asked 512, the pipeline answers 160."""
    engine, pipe = engine_with(monkeypatch, tmp_path, [solid(160, 160)],
                               model="sana-sprint-0.6b")
    body = engine.generate(prompt="x", model="sana-sprint-0.6b",
                           width=512, height=512, seed=1, provenance=True)
    assert [w for w in body["warnings"] if "re-binned it" in w], body["warnings"]
    warning = [w for w in body["warnings"] if "re-binned it" in w][0]
    assert "requested 512x512" in warning and "produced 160x160" in warning
    record = body["images"][0]["provenance"]
    assert (record["requested_width"], record["requested_height"]) == (512, 512)
    assert (record["width"], record["height"]) == (160, 160)


def test_a_size_the_pipeline_honoured_is_not_reported_as_re_binned(
        monkeypatch, tmp_path):
    """The warning is about an ACTUAL mismatch, unlike the prospective one the
    request path already carries for every binning model."""
    engine, pipe = engine_with(monkeypatch, tmp_path, [solid(512, 512)],
                               model="sana-sprint-0.6b")
    body = engine.generate(prompt="x", model="sana-sprint-0.6b",
                           width=512, height=512, seed=1)
    assert [w for w in body["warnings"] if "re-binned it" in w] == []


def test_a_hires_target_over_the_entries_max_pixels_is_refused(monkeypatch, tmp_path):
    """sdxl-1.0 is a 2 MP entry: 1024 px at 2.0x is 4.19 MP, i.e. not available."""
    monkeypatch.setitem(sys.modules, "torch", None)
    engine = FluxEngine(out_dir=str(tmp_path))
    with pytest.raises(ModelError) as caught:
        engine.generate(prompt="x", model="sdxl-1.0", width=1024, height=1024,
                        hires={"scale": 2.0})
    message = str(caught.value)
    assert "hires.scale" in message and "2048x2048" in message
    assert resolve("sdxl-1.0").max_pixels == 2 * 1024 * 1024


def test_a_hires_target_off_the_models_grid_is_refused(monkeypatch, tmp_path):
    """sd-1.5 is multiples of 8: 512 x 1.7 lands on 870, which is not one."""
    monkeypatch.setitem(sys.modules, "torch", None)
    with pytest.raises(ModelError) as caught:
        FluxEngine(out_dir=str(tmp_path)).generate(
            prompt="x", model="sd-1.5", width=512, height=512,
            hires={"scale": 1.7})
    assert "hires.scale" in str(caught.value)
    assert "multiple of 8" in str(caught.value)


def test_hires_is_refused_on_an_entry_with_no_img2img_strength(monkeypatch, tmp_path):
    monkeypatch.setitem(sys.modules, "torch", None)
    with pytest.raises(ModelError) as caught:
        FluxEngine(out_dir=str(tmp_path)).generate(
            prompt="x", width=512, height=512, hires={"scale": 2.0})
    message = str(caught.value)
    assert "hires" in message and "klein-4b" in message
    assert "Flux2KleinPipeline" in message


def test_a_hires_strength_outside_the_safe_band_warns_but_still_runs(
        monkeypatch, tmp_path):
    engine, pipe = engine_with(monkeypatch, tmp_path, [solid(128, 128)],
                               model="sdxl-1.0")
    body = engine.generate(prompt="x", model="sdxl-1.0", width=128, height=128,
                           seed=1, hires={"scale": 2.0, "strength": 0.45})
    assert any("safe band" in w for w in body["warnings"])
    assert pipe.calls[-1]["strength"] == 0.45       # run as asked, not clamped

    quiet, _pipe = engine_with(monkeypatch, tmp_path, [solid(128, 128)],
                               model="sdxl-1.0")
    body = quiet.generate(prompt="x", model="sdxl-1.0", width=128, height=128,
                          seed=1, hires={"scale": 2.0, "strength": 0.35})
    assert not any("safe band" in w for w in body["warnings"])


def test_the_resampling_flag_is_read_across_pillows_two_spellings():
    modern = types.SimpleNamespace(Resampling=RESAMPLING)
    legacy = types.SimpleNamespace(LANCZOS="LEGACY-LANCZOS")
    assert _resampling_flag(modern, "lanczos") == "LANCZOS"
    assert _resampling_flag(legacy, "lanczos") == "LEGACY-LANCZOS"
    with pytest.raises(AttributeError):
        _resampling_flag(modern, "waifu2x")


# -- `seeds` ---------------------------------------------------------------

def test_a_seed_sweep_files_one_frame_per_seed_and_returns_the_mapping(
        monkeypatch, tmp_path):
    engine, pipe = engine_with(monkeypatch, tmp_path, [solid()])
    body = engine.generate(prompt="x", width=512, height=512, seeds=[7, 8, 9])

    assert body["seeds"] == [7, 8, 9]
    assert body["seed"] is None               # no single seed describes a sweep
    assert [entry["seed"] for entry in body["images"]] == [7, 8, 9]
    assert len(pipe.calls) == 3
    names = [entry["name"] for entry in body["images"]]
    assert body["seed_files"] == {"7": [names[0]], "8": [names[1]],
                                 "9": [names[2]]}
    for name in names:
        assert os.path.isfile(os.path.join(tmp_path, name))


def test_a_sweep_runs_on_one_LOAD_of_the_model(monkeypatch, tmp_path):
    """One load, N generations: that is what makes a sweep cheap to ask for."""
    loads = []
    engine, pipe = engine_with(monkeypatch, tmp_path, [solid()], loads=loads)
    engine.generate(prompt="x", width=512, height=512, seeds=[1, 2, 3, 4])
    assert len(loads) == 1
    assert len(pipe.calls) == 4


def test_images_and_seeds_together_file_every_frame_of_every_seed(
        monkeypatch, tmp_path):
    engine, _pipe = engine_with(monkeypatch, tmp_path, [solid(), solid()])
    body = engine.generate(prompt="x", width=512, height=512, images=2,
                           seeds=[11, 12])
    assert len(body["images"]) == 4
    assert body["seed_files"]["11"] == [body["images"][0]["name"],
                                        body["images"][1]["name"]]
    assert body["seed_files"]["12"] == [body["images"][2]["name"],
                                        body["images"][3]["name"]]


RANKING_WORDS = ("score", "rank", "best", "winner", "rating", "preferred",
                 "compare", "order")


def test_nothing_in_a_sweep_ranks_the_frames(monkeypatch, tmp_path):
    """Nothing is ordered, scored or preferred: the mapping is the whole answer."""
    engine, _pipe = engine_with(monkeypatch, tmp_path, [solid()])
    body = engine.generate(prompt="x", width=512, height=512, seeds=[4, 5])
    # The filesystem paths are normalised out first: a temp directory named after
    # this test is not a ranking surface.
    text = json.dumps(normalise(body, tmp_path)).lower()
    for word in RANKING_WORDS:
        assert word not in text, word
    assert list(body["seed_files"]) == ["4", "5"]   # the caller's order, kept


# -- `provenance` ----------------------------------------------------------

def test_provenance_records_the_fields_a_comparison_needs(monkeypatch, tmp_path):
    engine, _pipe = engine_with(monkeypatch, tmp_path, [gradient(128, 128)],
                                model="sdxl-1.0")
    body = engine.generate(prompt="an owl crest", model="sdxl-1.0", width=128,
                           height=128, seed=31, ink_cap=4, provenance=True)
    entry = body["images"][0]
    assert body["provenance"] is True
    provenance = entry["provenance"]
    for field in ("model", "seed", "prompt", "ink_cap", "hires", "width",
                  "height", "negative_prompt", "negative_prompt_source",
                  "requested_width", "requested_height", "sha256", "name"):
        assert field in provenance, field
    assert provenance["model"] == "sdxl-1.0"
    assert provenance["seed"] == 31
    assert provenance["prompt"] == "an owl crest"
    assert provenance["ink_cap"]["colors_present"] <= 4
    assert provenance["hires"] is None            # no hires was asked for
    assert (provenance["width"], provenance["height"]) == (128, 128)
    assert (provenance["requested_width"], provenance["requested_height"]) \
        == (128, 128)
    assert provenance["negative_prompt_source"] == "default"

    # ...and the same record travels in a sidecar beside the frame.
    sidecar = entry["sidecar"]
    assert sidecar == entry["name"] + ".json"
    with open(os.path.join(tmp_path, sidecar), encoding="utf-8") as handle:
        assert json.load(handle) == provenance


def test_the_provenance_carries_no_score_no_rank_and_no_verdict(monkeypatch, tmp_path):
    engine, _pipe = engine_with(monkeypatch, tmp_path, [solid()])
    body = engine.generate(prompt="x", width=512, height=512, seed=1,
                           provenance=True)
    text = json.dumps(body["images"][0]["provenance"]).lower()
    for word in RANKING_WORDS:
        assert word not in text, word


def test_provenance_does_not_touch_the_pixels(monkeypatch, tmp_path):
    """A record is a record: the frame it describes is byte-identical."""
    plain, _pipe = engine_with(monkeypatch, tmp_path, [gradient()])
    bare = plain.generate(prompt="x", width=512, height=512, seed=1)
    recorded, _pipe = engine_with(monkeypatch, tmp_path, [gradient()])
    with_prov = recorded.generate(prompt="x", width=512, height=512, seed=1,
                                  provenance=True)
    assert written(tmp_path, bare["images"][0]["name"]) == \
        written(tmp_path, with_prov["images"][0]["name"])
    assert bare["images"][0]["sha256"] == with_prov["images"][0]["sha256"]
    assert "provenance" not in bare["images"][0]
    assert "provenance" in with_prov["images"][0]


def test_provenance_is_implied_by_a_pass_that_measured_the_frame(
        monkeypatch, tmp_path):
    engine, _pipe = engine_with(monkeypatch, tmp_path, [gradient()])
    body = engine.generate(prompt="x", width=512, height=512, seed=1, ink_cap=6)
    assert body["provenance"] is True
    assert body["images"][0]["provenance"]["ink_cap"]["max_colors"] == 6
    assert body["images"][0]["sidecar"]
    # And a plain request still writes neither.
    plain, _pipe = engine_with(monkeypatch, tmp_path, [gradient()])
    bare = plain.generate(prompt="x", width=512, height=512, seed=1)
    assert "provenance" not in bare
    assert "sidecar" not in bare["images"][0]


def test_the_number_of_frames_a_request_wrote_is_the_number_of_sidecars(
        monkeypatch, tmp_path):
    engine, _pipe = engine_with(monkeypatch, tmp_path, [solid(), solid()])
    body = engine.generate(prompt="x", width=512, height=512, seed=1,
                           images=2, provenance=True)
    assert len(body["images"]) == 2
    sidecars = sorted(entry["sidecar"] for entry in body["images"])
    on_disk = sorted(name for name in os.listdir(tmp_path)
                     if name.endswith(".json"))
    assert sidecars == on_disk
    assert len(on_disk) == 2


def test_the_three_passes_compose_with_a_sweep_and_a_batch(monkeypatch, tmp_path):
    """hires + ink_cap + background + seeds + images, all in one request."""
    engine, pipe = engine_with(monkeypatch, tmp_path, [bordered(128, 128),
                                                       bordered(128, 128)],
                               model="sdxl-1.0")
    body = engine.generate(prompt="x", model="sdxl-1.0", width=128, height=128,
                           seeds=[21, 22], images=2,
                           hires={"scale": 1.5, "strength": 0.3},
                           ink_cap=3, background="key")
    assert len(body["images"]) == 4                   # 2 seeds x 2 images
    # One pass-1 call per seed (which returns `images` frames) plus one pass-2
    # call PER FRAME: 2 x (1 + 2).
    assert len(pipe.calls) == 6
    for entry in body["images"]:
        assert (entry["width"], entry["height"]) == (192, 192)
        assert entry["hires"]["target"] == [192, 192]
        assert entry["ink_cap"]["colors_present"] <= 3
        assert entry["background"]["mode"] == "key"
        assert entry["provenance"]["hires"]["scale"] == 1.5
        assert len(written(tmp_path, entry["name"])) == 192 * 192 * 4
    assert [entry["seed"] for entry in body["images"]] == [21, 21, 22, 22]
    assert body["seed_files"]["21"] == [body["images"][0]["name"],
                                       body["images"][1]["name"]]
    assert body["seed_files"]["22"] == [body["images"][2]["name"],
                                       body["images"][3]["name"]]


# -- the order of the passes -----------------------------------------------

def test_the_passes_run_hires_then_cap_then_key(monkeypatch, tmp_path):
    """Fixed order: the cap sees the judged frame, the key sees the final palette."""
    engine, pipe = engine_with(monkeypatch, tmp_path, [bordered(128, 128)],
                               model="sdxl-1.0")
    body = engine.generate(prompt="x", model="sdxl-1.0", width=128, height=128,
                           seed=1, hires={"scale": 2.0, "strength": 0.3},
                           ink_cap=2, background="key", provenance=True)
    entry = body["images"][0]
    assert len(pipe.calls) == 2                      # hires really ran twice
    assert entry["hires"]["target"] == [256, 256]
    assert (entry["width"], entry["height"]) == (256, 256)
    assert entry["ink_cap"]["colors_present"] <= 2
    assert entry["background"]["mode"] == "key"
    raw = written(tmp_path, entry["name"])
    assert len(raw) == 256 * 256 * 4                 # RGBA: the key ran last
    assert Frame("RGBA", 256, 256, raw).mode == "RGBA"
    # The keyed frame is at most two colours once alpha is ignored.
    assert len({raw[offset:offset + 3] for offset in range(0, len(raw), 4)}) <= 2
    # And the provenance knows what was asked for and what came out.
    assert entry["provenance"]["requested_width"] == 128
    assert entry["provenance"]["width"] == 256
