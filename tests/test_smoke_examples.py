"""The smoke script's own parts: the blank-frame check and the --only selector.

``scripts/smoke_examples.py`` is not a test — it needs a live service and real
weights — but two of its pieces are pure functions that decide whether a run is
reported as a pass, and a bug in either would make a whole report wrong:

* the frame decoder, because "the exit code was zero" is exactly the claim this
  project refuses to trust;
* the ``--only`` selector, because the reference chain it walks must include the
  frame an edit edits.

Both are exercised here with the real module, loaded from its path so the tests
do not need it on any path.
"""

import importlib.util
import json
import os
import struct
import zlib

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "smoke_examples.py")


def _load_script():
    spec = importlib.util.spec_from_file_location("smoke_examples", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


smoke = _load_script()


# -- writing PNGs by hand, so the decoder is tested rather than trusted -----

def _chunk(kind, body):
    return (struct.pack(">I", len(body)) + kind + body
            + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))


def write_png(path, rows, width=None, height=None, colour_type=2, filter_type=0):
    """An 8-bit non-interlaced PNG. ``rows`` is a list of pixel byte rows."""
    height = height if height is not None else len(rows)
    width = width if width is not None else len(rows[0]) // 3
    raw = b"".join(bytes([filter_type]) + bytes(row) for row in rows)
    payload = (b"\x89PNG\r\n\x1a\n"
               + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8,
                                             colour_type, 0, 0, 0))
               + _chunk(b"IDAT", zlib.compress(raw))
               + _chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(payload)
    return path



# -- the content check -----------------------------------------------------

def test_a_uniform_frame_counts_as_one_colour_and_fails(tmp_path):
    """This is the failure the check exists for: NaN latents produce a uniform
    black PNG that every exit code calls a success."""
    path = write_png(str(tmp_path / "blank.png"),
                     [[0, 0, 0] * 8 for _ in range(8)])
    assert smoke.frame_colour_count(path) == 1
    ok, detail = smoke.content_check(path)
    assert ok is False
    assert "BLANK" in detail


def test_a_uniform_white_frame_also_fails(tmp_path):
    """Uniform is uniform: a white frame is as blank as a black one."""
    path = write_png(str(tmp_path / "white.png"),
                     [[255, 255, 255] * 8 for _ in range(8)])
    ok, detail = smoke.content_check(path)
    assert ok is False
    assert "BLANK" in detail


def test_a_varied_frame_counts_its_real_colours_and_passes(tmp_path):
    row = [10, 20, 30, 200, 1, 2, 10, 20, 30, 7, 7, 7] * 2
    path = write_png(str(tmp_path / "varied.png"), [row for _ in range(4)])
    assert smoke.frame_colour_count(path) == 3
    ok, detail = smoke.content_check(path)
    assert ok is True
    assert "3 distinct colours" in detail


def _paeth_predict(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def encode_row(filter_type, row, previous, channels=3):
    """Encode one scanline with a real PNG predictor.

    Written out rather than faked: a decoder tested against a wrong encoder
    proves nothing, and the first version of this helper produced bytes that
    only looked like valid Average-filtered rows.
    """
    out = []
    for i, value in enumerate(row):
        left = row[i - channels] if i >= channels else 0
        up = previous[i]
        up_left = previous[i - channels] if i >= channels else 0
        if filter_type == 0:
            predictor = 0
        elif filter_type == 1:
            predictor = left
        elif filter_type == 2:
            predictor = up
        elif filter_type == 3:
            predictor = (left + up) >> 1
        else:
            predictor = _paeth_predict(left, up, up_left)
        out.append((value - predictor) & 0xFF)
    return out


def test_the_decoder_undoes_every_png_filter(tmp_path):
    """Filtered scanlines are the trap: reading the raw bytes without undoing the
    filters yields plausible-looking noise rather than an error, so a check built
    on it would report almost anything as a pass."""
    reference = [[11, 22, 33, 44, 55, 66, 44, 55, 66, 200, 1, 2] for _ in range(3)]
    plain = write_png(str(tmp_path / "plain.png"), reference, filter_type=0)
    assert smoke.frame_colour_count(plain) == 3

    for filter_type in (1, 2, 3, 4):
        rows = []
        previous = [0] * len(reference[0])
        for row in reference:
            rows.append(encode_row(filter_type, row, previous))
            previous = row
        path = write_png(str(tmp_path / ("filter%d.png" % filter_type)), rows,
                         filter_type=filter_type)
        assert smoke.frame_colour_count(path) == 3, filter_type


def test_a_missing_file_is_a_failure_not_an_exception(tmp_path):
    ok, detail = smoke.content_check(str(tmp_path / "nope.png"))
    assert ok is False
    assert "no file" in detail


def test_a_zero_byte_file_is_a_failure(tmp_path):
    path = tmp_path / "empty.png"
    path.write_bytes(b"")
    ok, detail = smoke.content_check(str(path))
    assert ok is False
    assert "0-byte" in detail


def test_a_file_that_is_not_a_png_is_a_failure_not_a_crash(tmp_path):
    path = tmp_path / "not-really.png"
    path.write_bytes(b"this is not a PNG at all")
    ok, detail = smoke.content_check(str(path))
    assert ok is False
    assert "unreadable" in detail


def test_a_format_it_cannot_measure_is_refused_rather_than_guessed(tmp_path):
    """A check that silently measures the wrong thing is worse than no check."""
    path = tmp_path / "16bit.png"
    payload = (b"\x89PNG\r\n\x1a\n"
               + _chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 16, 2, 0, 0, 0))
               + _chunk(b"IDAT", zlib.compress(b"\x00" * 64))
               + _chunk(b"IEND", b""))
    path.write_bytes(payload)
    ok, detail = smoke.content_check(str(path))
    assert ok is False
    assert "cannot measure" in detail


# -- the --only selector ---------------------------------------------------

def _entries():
    return [
        {"id": "a", "reference": None},
        {"id": "b", "reference": None},
        {"id": "edit-of-a", "reference": "a"},
        {"id": "edit-of-edit", "reference": "edit-of-a"},
    ]


def test_no_only_runs_the_whole_set_in_order():
    got = [entry["id"] for entry in smoke.select(_entries(), None)]
    assert got == ["a", "b", "edit-of-a", "edit-of-edit"]


def test_only_runs_one_example():
    got = [entry["id"] for entry in smoke.select(_entries(), "b")]
    assert got == ["b"]


def test_only_pulls_in_the_reference_and_its_own_reference_first():
    """An edit cannot run without the frame it edits, so the chain is included —
    in dependency order, not registration order."""
    got = [entry["id"] for entry in smoke.select(_entries(), "edit-of-edit")]
    assert got == ["a", "edit-of-a", "edit-of-edit"]


def test_only_does_not_run_an_unrelated_reference_example():
    got = [entry["id"] for entry in smoke.select(_entries(), "edit-of-a")]
    assert got == ["a", "edit-of-a"]


def test_an_unknown_only_id_is_a_usage_error():
    with pytest.raises(SystemExit) as caught:
        smoke.select(_entries(), "no-such-example")
    assert "no-such-example" in str(caught.value)


# -- the request each example builds --------------------------------------

def test_the_request_carries_the_modifier_knobs():
    entry = {"model": "sdxl-1.0", "width": 768, "height": 768, "steps": 4,
             "guidance": 0.0, "seed": 1234, "modifiers": ["sdxl-lightning-4step"],
             "vae": None, "negative_prompt": None}
    kwargs = smoke.example_request(entry)
    assert kwargs["modifiers"] == ["sdxl-lightning-4step"]
    assert kwargs["vae"] is None
    assert kwargs["steps"] == 4
    assert "negative_prompt" not in kwargs


def test_the_request_omits_an_empty_modifier_list():
    entry = {"model": "klein-4b", "width": 512, "height": 512, "steps": 4,
             "guidance": 1.0, "seed": 1, "modifiers": [], "vae": None,
             "negative_prompt": "blurry"}
    kwargs = smoke.example_request(entry)
    assert kwargs["modifiers"] is None
    assert kwargs["negative_prompt"] == "blurry"


# -- the reports -----------------------------------------------------------

def _report_rows():
    return {
        "service": "http://127.0.0.1:8795",
        "examples_path": "/repo/examples/prompts.json",
        "offload": "cpu",
        "ack_noncommercial": False,
        "examples": [
            {"id": "a", "model": "klein-4b", "modifiers": ["pixel-art-xl"],
             "vae": None, "style": None, "reference": None, "width": 512,
             "height": 512, "steps": 4, "guidance": 1.0, "requested_seed": 1,
             "edited": False, "what_it_proves": "something.", "status": "PASS",
             "detail": "12 distinct colours", "seconds": 1.5, "seed": 1,
             "warnings": ["a warning"],
             "images": [{"sha256": "a" * 64, "content_detail": "12 distinct colours"}]},
            {"id": "b", "model": "sdxl-1.0", "modifiers": [], "vae": "taesdxl",
             "style": None, "reference": None, "width": 768, "height": 768,
             "steps": 20, "guidance": 6.0, "requested_seed": 2, "edited": False,
             "what_it_proves": "something else.", "status": "FAIL",
             "detail": "BLANK frame (1 distinct colour(s))", "seconds": 2.5,
             "seed": 2, "warnings": [], "images": []},
        ],
        "passed": 1, "failed": 1,
    }


def test_the_json_report_is_written_and_parseable(tmp_path):
    smoke.write_reports(_report_rows(), str(tmp_path / "r.json"),
                        str(tmp_path / "r.md"))
    payload = json.loads((tmp_path / "r.json").read_text())
    assert payload["passed"] == 1 and payload["failed"] == 1
    assert [row["id"] for row in payload["examples"]] == ["a", "b"]


def test_the_markdown_report_has_a_row_per_example_and_the_failures(tmp_path):
    smoke.write_reports(_report_rows(), str(tmp_path / "r.json"),
                        str(tmp_path / "r.md"))
    text = (tmp_path / "r.md").read_text()
    for token in ("| `a` |", "| `b` |", "**PASS**", "**FAIL**",
                  "12 distinct colours", "BLANK frame", "a warning",
                  "something.", "1 PASS, 1 FAIL"):
        assert token in text, token


# -- the style, which the report claims but the script used to ignore --------

def test_a_style_row_sends_the_PREFIX_composed_prompt():
    """A style is a prompt SUFFIX, composed client-side, and the report claims as
    much for eight rows ("so it isolates what the style text contributes").

    The script used to pass the bare prompt, so those rows proved nothing about
    the style while still printing PASS beside the claim. This pins that the
    suffix really is appended, and that it matches what the CLI would send.
    """
    from chopshop_flux.styles import apply_style

    entry = {"prompt": "a cheerful cartoon fox head", "style": "flat-vector"}
    sent = smoke.effective_prompt(entry)

    suffix, _preset = apply_style("flat-vector")
    assert suffix, "the style must have a suffix for this test to mean anything"
    assert sent == entry["prompt"] + suffix
    assert sent != entry["prompt"], "the style must actually change what is sent"
    # And it is the CLI's composition, not a second opinion about it.
    assert sent.startswith(entry["prompt"])


def test_a_row_with_no_style_sends_the_prompt_unchanged():
    entry = {"prompt": "a flat vector wolf head badge", "style": None}
    assert smoke.effective_prompt(entry) == entry["prompt"]


def test_an_unknown_style_is_a_caller_error_not_a_silent_bare_prompt():
    """The failure mode this guards: a typo'd style name would otherwise be
    dropped and the row would be run unstyled and still reported as testing it."""
    from chopshop_flux.models import ModelError

    with pytest.raises(ModelError):
        smoke.effective_prompt({"prompt": "x", "style": "no-such-style"})
