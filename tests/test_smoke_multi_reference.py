"""The multi-reference case in `scripts/smoke.py`.

`scripts/smoke.py` is not a test — it loads real weights and needs a GPU. But the
parts that DECIDE the case's verdict are pure, and they are the parts that can be
wrong quietly:

* the comparison (digest equality, and the magnitude beside it), because "the
  second reference changed the frame" is the entire claim and a comparison that
  cannot fail proves nothing;
* the registry guard, because four generations is the price of the comparison
  and a family that takes one reference would pay it to reach a refusal the
  registry already predicts.

The real render stays in the smoke script. What is tested here is that the thing
that INTERPRETS it is right, and that the verdict comes from comparing BYTES
rather than from trusting a field in the response — the failure mode this repo
has already been bitten by once, when a uniform black frame arrived announced
as a successful-looking file.

Pillow is needed only for the one helper that measures a pixel difference. The
rest writes PNGs byte by byte, the way `tests/test_smoke_examples.py` does, so a
CI box without Pillow still runs the checks that decide the verdict rather than
skipping the whole file.
"""

import importlib.util
import os
import struct
import sys
import zlib

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "smoke.py")


def _load_script():
    spec = importlib.util.spec_from_file_location("flux_smoke", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


smoke = _load_script()


def _has_pillow():
    # An import that is only ever reached to find out whether it works. The
    # name is not used, which is the point.
    import importlib

    try:
        importlib.import_module("PIL.Image")
    except ImportError:
        return False
    return True


needs_pillow = pytest.mark.skipif(
    not _has_pillow(), reason="the pixel-difference helper needs Pillow")


# -- writing PNGs by hand, so these tests need no image library ------------

def _chunk(kind, body):
    return (struct.pack(">I", len(body)) + kind + body
            + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))


def write_png(path, colour, size=16):
    """A solid-colour 8-bit non-interlaced RGB PNG, written from scratch.

    Hand-rolled on purpose. The digest comparison is about FILE BYTES, so the
    frames have to be real files, and a library that is not installed in this
    repo's venv must not be the reason the check that decides the verdict does
    not run.
    """
    row = bytes(colour) * size
    raw = b"".join(b"\x00" + row for _ in range(size))
    payload = (b"\x89PNG\r\n\x1a\n"
               + _chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
               + _chunk(b"IDAT", zlib.compress(raw))
               + _chunk(b"IEND", b""))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(payload)
    return path


# -- the comparison --------------------------------------------------------

def test_two_different_frames_have_different_digests(tmp_path):
    a = write_png(str(tmp_path / "a.png"), (200, 30, 30))
    b = write_png(str(tmp_path / "b.png"), (30, 30, 200))
    assert smoke.frame_digest(a) != smoke.frame_digest(b)


def test_identical_frames_have_identical_digests(tmp_path):
    """The direction that has to be able to FAIL. If equal digests were not the
    failing condition, the comparison would pass on any run — including one
    where the second reference was silently dropped, which is the fault the
    case exists to catch."""
    a = write_png(str(tmp_path / "a.png"), (12, 34, 56))
    b = write_png(str(tmp_path / "b.png"), (12, 34, 56))
    assert smoke.frame_digest(a) == smoke.frame_digest(b)


def test_a_digest_is_of_the_bytes_on_disk_not_of_the_path(tmp_path):
    """A digest of the FILENAME would be equal for two different frames, which is
    exactly the comparison that cannot fail. Same basename, different
    directories, different content."""
    first = write_png(str(tmp_path / "run-a" / "frame.png"), (1, 2, 3))
    second = write_png(str(tmp_path / "run-b" / "frame.png"), (9, 9, 9))
    assert os.path.basename(first) == os.path.basename(second)
    assert smoke.frame_digest(first) != smoke.frame_digest(second)


@needs_pillow
def test_the_difference_is_reported_as_a_number_not_a_verdict(tmp_path):
    """The magnitude answers a question the digest cannot: a one-pixel change
    and a visibly different image are both "different", and only the size of the
    change says which happened."""
    same = write_png(str(tmp_path / "a.png"), (0, 0, 0))
    also_same = write_png(str(tmp_path / "b.png"), (0, 0, 0))
    very_different = write_png(str(tmp_path / "c.png"), (255, 255, 255))
    assert smoke.mean_abs_pixel_difference(same, also_same) == 0.0
    assert smoke.mean_abs_pixel_difference(same, very_different) == pytest.approx(255.0)


@needs_pillow
def test_a_size_mismatch_is_refused_rather_than_summarised(tmp_path):
    """A mean over two different-sized frames is a number about nothing, so the
    helper returns None rather than inventing one."""
    small = write_png(str(tmp_path / "a.png"), (0, 0, 0), size=8)
    large = write_png(str(tmp_path / "b.png"), (0, 0, 0), size=16)
    assert smoke.mean_abs_pixel_difference(small, large) is None


# -- the registry guard ----------------------------------------------------

def test_the_guard_follows_the_registry_not_a_list_of_names():
    """Asked of the registry, so a model that gains multi-reference is covered
    the day the flag flips rather than the day someone edits this test."""
    from chopshop_flux.models import REGISTRY

    declared = [spec for spec in REGISTRY.values() if spec.multi_reference]
    assert declared, "the registry must still declare at least one such family"
    for spec in declared:
        assert smoke.spec_supports_multi(spec.key) is True
    for spec in REGISTRY.values():
        if not spec.multi_reference:
            assert smoke.spec_supports_multi(spec.key) is False


def test_an_unknown_model_is_not_a_multi_reference_model():
    assert smoke.spec_supports_multi("no-such-model") is False


# -- the case's own verdict logic ------------------------------------------

def test_the_case_declines_rather_than_running_on_a_single_reference_model(
        tmp_path):
    """Four generations is the price of the comparison. On a family that takes
    one reference the service would refuse the second image anyway, so the case
    must not spend them — and must not report a FAILURE either, because the
    capability does not apply to that checkpoint. `passed: None` is the
    distinction, and a caller reading it as False would turn every img2img row
    red."""
    calls = []

    class Engine:
        def generate(self, **kwargs):
            calls.append(kwargs)
            raise AssertionError("the comparison must not run here")

    block = smoke.multi_reference_case(
        Engine(), str(tmp_path), "sdxl-1.0", 512, 4, 4321)
    assert calls == [], "no generation should have been attempted"
    assert block["passed"] is None, "not run is not failed"
    assert "does not declare" in block["detail"]


def _recording_engine(tmp_path, edit_colour):
    """An engine that writes real PNGs and records what it was asked for.

    ``edit_colour`` decides what the two EDIT frames look like: the same colour
    twice is exactly what a second-ignored reference produces, and different
    colours is exactly what a conditioned one produces. Everything else about
    the two edits is identical, because ``multi_reference_case`` varies only the
    reference list.
    """
    recorded = []
    counter = {"n": 0}

    class Engine:
        def generate(self, **kwargs):
            recorded.append(kwargs)
            counter["n"] += 1
            name = "frame-%02d.png" % counter["n"]
            count = len(kwargs["reference"]) if kwargs.get("reference") else 0
            if count == 1:
                colour = (40, 40, 40)
            elif count == 2:
                colour = edit_colour
            else:
                # The two reference frames differ from each other, so a later
                # difference cannot be explained by them being identical.
                colour = (10 * counter["n"], 0, 0)
            write_png(os.path.join(str(tmp_path), name), colour)
            return {"images": [{"name": name}], "seed": kwargs.get("seed"),
                    "steps": kwargs.get("steps")}

    return Engine(), recorded


def test_a_case_that_finds_identical_frames_fails_with_the_reason(tmp_path):
    """The whole point: a pipeline that reads only image[0] produces two
    byte-identical frames, and the case has to say so rather than passing."""
    from chopshop_flux.models import resolve

    assert resolve("klein-4b").multi_reference, "the fixture model must qualify"

    engine, recorded = _recording_engine(tmp_path, edit_colour=(40, 40, 40))
    block = smoke.multi_reference_case(
        engine, str(tmp_path), "klein-4b", 16, 4, 4321)
    assert block["passed"] is False
    assert "BYTE-IDENTICAL" in block["detail"]
    assert block["comparison"]["digests_differ"] is False
    # The two edits really were sent one and two references, at the same seed
    # and the same prompt — so identical frames are evidence about the
    # CONDITIONING rather than about the two runs having differed at all.
    edits = [k for k in recorded if k.get("reference")]
    assert [len(k["reference"]) for k in edits] == [1, 2]
    assert {k["seed"] for k in edits} == {4321}
    assert {k["prompt"] for k in edits} == {smoke.MULTI_REFERENCE_PROMPT}
    assert {k["steps"] for k in edits} == {4}
    assert all(k["width"] == k["height"] == 16 for k in edits)


@needs_pillow
def test_a_case_where_the_second_reference_changes_the_frame_passes(tmp_path):
    engine, _recorded = _recording_engine(tmp_path, edit_colour=(200, 200, 200))
    block = smoke.multi_reference_case(
        engine, str(tmp_path), "klein-4b", 16, 4, 4321)
    assert block["passed"] is True
    assert block["comparison"]["digests_differ"] is True
    assert "conditioned the generation" in block["detail"]


def test_a_case_that_changes_the_frame_passes_on_the_digest_alone(tmp_path):
    """The verdict does not depend on Pillow. The magnitude is reported as
    evidence, but a box that cannot compute it must still get PASS/FAIL — and
    the test that pins the magnitude is the one marked `needs_pillow`."""
    engine, _recorded = _recording_engine(tmp_path, edit_colour=(200, 200, 200))
    block = smoke.multi_reference_case(
        engine, str(tmp_path), "klein-4b", 16, 4, 4321)
    assert block["passed"] is True
    assert block["comparison"]["sha256_single"] != block["comparison"]["sha256_dual"]


def test_the_reference_frames_use_seeds_of_their_own(tmp_path):
    """A reference generated at the comparison's own seed would be a frame the
    comparison might also produce, and "the two-reference frame differs from the
    one-reference frame" would then be comparing a frame with itself."""
    engine, recorded = _recording_engine(tmp_path, edit_colour=(99, 99, 99))
    smoke.multi_reference_case(engine, str(tmp_path), "klein-4b", 16, 4, 4321)
    reference_seeds = [k["seed"] for k in recorded if not k.get("reference")]
    assert sorted(reference_seeds) == [4322, 4323]
    assert 4321 not in reference_seeds


def test_the_two_references_are_prompted_differently(tmp_path):
    """The second reference has to be a different SUBJECT. Two references of the
    same kind would let a pipeline that ignores the second one produce a frame
    that differs anyway, on the strength of the first alone — and the case would
    pass on a fault."""
    engine, recorded = _recording_engine(tmp_path, edit_colour=(200, 200, 200))
    smoke.multi_reference_case(engine, str(tmp_path), "klein-4b", 16, 4, 4321)
    reference_prompts = [k["prompt"] for k in recorded if not k.get("reference")]
    assert len(set(reference_prompts)) == 2
    assert reference_prompts[0] == smoke.MULTI_REFERENCE_PROMPT
    assert reference_prompts[1] == smoke.MULTI_REFERENCE_SECOND_PROMPT


if __name__ == "__main__":
    sys.exit(pytest.main([__file__]))
