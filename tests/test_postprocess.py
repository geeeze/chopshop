"""The output-side passes, on REAL pixels and with no Pillow or torch.

This is where the ink cap, the background key and the palette cut are actually
exercised: the passes live in ``chopshop_flux/postprocess.py`` and work on raw
buffers, so the numbers the service reports — `colors_before`, `colors_present`,
`pixels_moved` — are produced by the same code the GPU box runs, here, on a frame
this file built. A test that only asserted the response contained a key would
prove nothing about the pixels.
"""

import pytest

from chopshop_flux.models import ModelError
from chopshop_flux.postprocess import (BACKGROUND_MODES, INK_CAP_MODES, UPSCALERS,
                                       Frame, border_colors, hex_color,
                                       hires_target, isolate_background,
                                       parse_background, parse_hires, parse_ink_cap,
                                       parse_provenance, parse_seeds,
                                       records_provenance, reduce_colors)


def frame(width, height, fn) -> Frame:
    """Build an RGB frame from a colour function — real bytes, no pillow."""
    data = bytearray()
    for y in range(height):
        for x in range(width):
            data += bytes(fn(x, y))
    return Frame("RGB", width, height, bytes(data))


def gradient(width=64, height=64) -> Frame:
    """A photographic-ish gradient: one distinct colour per pixel."""
    return frame(width, height,
                 lambda x, y: (x * 4 % 256, y * 4 % 256, (x + y) * 2 % 256))


def surrounded(width, height, inner, ground) -> Frame:
    """A ground colour with a rectangle in the middle that never touches an edge."""
    return frame(width, height,
                 lambda x, y: inner if (4 <= y <= 11 and 4 <= x <= width - 5)
                 else ground)


def mean_absolute_difference(left: Frame, right: Frame) -> float:
    """The metric named when a pass is said to have changed a frame."""
    assert (left.width, left.height) == (right.width, right.height)
    assert left.mode == right.mode
    return (sum(abs(a - b) for a, b in zip(left.data, right.data))
            / len(left.data))


# -- the buffer is the unit -------------------------------------------------

def test_a_frame_knows_its_own_colours():
    one = frame(8, 8, lambda x, y: (255, 0, 0))
    assert one.color_count() == 1
    assert gradient(16, 16).color_count() == 256


def test_a_frame_refuses_a_buffer_that_does_not_match_its_shape():
    with pytest.raises(ValueError):
        Frame("RGB", 4, 4, b"\x00" * 10)
    with pytest.raises(ValueError):
        Frame("CMYK", 4, 4, b"\x00" * 64)


# -- `ink_cap` -------------------------------------------------------------

def test_quantize_never_exceeds_the_cap_and_reports_both_numbers():
    """The cap AND the count actually present, measured from the output."""
    source = gradient()
    reduced, report = reduce_colors(source, 3, "quantize")
    assert report["mode"] == "quantize"
    assert report["max_colors"] == 3
    assert report["colors_before"] == source.color_count() == 4096
    assert report["colors_present"] == reduced.color_count()
    assert report["colors_present"] <= 3
    assert report["changed"] is True


def test_the_reduction_is_called_a_reduction_and_never_a_separation():
    """The wording is the feature: a separation implies per-ink plates."""
    _reduced, report = reduce_colors(gradient(), 3, "quantize")
    assert "colour reduction, not a colour separation" in report["note"]


def test_a_frame_already_at_the_cap_is_a_skip_and_says_so():
    """A missing/skipped pass is a STATE, not work done."""
    source = frame(8, 8, lambda x, y: (0, 0, 0) if x < 4 else (255, 255, 255))
    assert source.color_count() == 2
    reduced, report = reduce_colors(source, 3, "quantize")
    assert report["changed"] is False
    assert report["colors_present"] == 2
    assert "nothing was reduced" in report["note"]
    assert reduced is source                       # untouched, not rewritten


def test_the_palette_is_taken_from_the_frame_itself():
    """A reduction must not invent a colour the frame never contained."""
    source = gradient()
    existing = set(source.colors())
    _reduced, report = reduce_colors(source, 4, "quantize")
    for entry in report["palette"]:
        assert any(hex_color(colour) == entry for colour in existing)


def test_the_cut_is_deterministic():
    first, _ = reduce_colors(gradient(), 3, "quantize")
    second, _ = reduce_colors(gradient(), 3, "quantize")
    assert first.data == second.data


def test_the_reduction_keeps_alpha_when_the_frame_has_it():
    """A keyed or partly transparent frame keeps its alpha through the cut."""
    data = bytearray()
    for y in range(16):
        for x in range(16):
            data += bytes((x * 8 % 256, y * 8 % 256, 128, 77))
    rgba = Frame("RGBA", 16, 16, bytes(data))
    reduced, report = reduce_colors(rgba, 2, "quantize")
    assert reduced.mode == "RGBA"
    assert all(reduced.data[offset + 3] == 77
               for offset in range(0, len(reduced.data), 4))
    assert report["colors_present"] <= 2


# The metric, both numbers, on a fixed frame: a cap of 3 takes this 4096-colour
# gradient to 3 colours and moves a channel by 34.86 on average over all 12288
# channel values. It is pinned so that a change to the cut's aggressiveness shows
# up as a NUMBER rather than as a vibe.
#
# Was 70.28 under the population-median cut, which split each box at its pixel
# median and represented it by its busiest colour. Less than half the error on
# the same frame, because the split now maximises between-class variance and the
# representative is the frame colour nearest each box's centroid.
REDUCTION_MAD_ON_THE_TEST_GRADIENT = 34.86


def test_the_reduction_moves_the_frame_by_a_measured_amount():
    source = gradient()
    reduced, report = reduce_colors(source, 3, "quantize")
    measured = mean_absolute_difference(source, reduced)
    assert report["colors_before"] == 4096 and report["colors_present"] == 3
    assert round(measured, 2) == REDUCTION_MAD_ON_THE_TEST_GRADIENT


def test_the_cap_keeps_the_dark_ink_when_the_ground_dominates():
    """The frame that made this algorithm change: a woodcut whose white ground
    holds most of the pixels must not have its black ink quantised away.

    The shape is the one MEASURED on a real klein-4b 1024x1024 frame — ground
    over 60% of the pixels, ink ~16%, the rest antialiasing spread across most of
    the grey range — and it is deliberate: the OLD rule split the box at the
    pixel-count median, so with everything except the ground under half the
    pixels, the cut landed exactly at the ground entry, the ground came back as
    the most frequent colour of the box, and `ink_cap: 2` returned `#fefefe,
    #ffffff` with zero black pixels. The same prompt at 512 px returned
    `#000000, #fefefe`, which is why this looked like a resolution bug.
    """
    width = height = 128
    total = width * height

    def pixel(x, y):
        position = y * width + x
        if position < 0.60 * total:
            return (254, 254, 254)              # ground
        if position < 0.76 * total:
            return (0, 0, 0)                    # ink
        if position < 0.80 * total:
            return (255, 255, 255)              # a second white, as real frames have
        grey = 1 + position % 254               # antialiasing across the range
        return (grey, grey, grey)

    source = frame(width, height, pixel)
    reduced, report = reduce_colors(source, 2, "quantize")
    assert report["colors_present"] == 2
    palette = [tuple(int(entry[ch:ch + 2], 16) for ch in (1, 3, 5))
               for entry in report["palette"]]
    assert any(max(colour) < 32 for colour in palette), \
        "the black ink was quantised away: palette %r" % (report["palette"],)
    assert any(min(colour) > 224 for colour in palette)
    black_left = sum(1 for offset in range(0, len(reduced.data), 3)
                     if max(reduced.data[offset:offset + 3]) < 32)
    assert black_left >= 0.15 * total, \
        "the subject survived as a palette entry but not as pixels (%d px)" % black_left


def test_posterize_reaches_at_most_its_cap_and_reports_the_levels():
    source = gradient()
    reduced, report = reduce_colors(source, 8, "posterize")
    assert report["levels_per_channel"] == 2
    assert report["colors_present"] == reduced.color_count() <= 8
    assert report["bits"] == 1
    # A bigger cap buys more levels, and the count present follows.
    bigger, report64 = reduce_colors(source, 64, "posterize")
    assert report64["levels_per_channel"] == 4
    assert bigger.color_count() <= 64


def test_posterize_is_refused_below_its_own_floor_by_name():
    with pytest.raises(ModelError) as caught:
        parse_ink_cap(3, "posterize")
    message = str(caught.value)
    assert "ink_cap" in message and "posterize" in message
    assert "quantize" in message


@pytest.mark.parametrize("value,mode,expected", [
    ("three", None, "ink_cap"),
    (1, None, "ink_cap"),
    (300, None, "ink_cap"),
    (True, None, "ink_cap"),
    (3, "kmeans", "ink_cap_mode"),
    (None, "quantize", "ink_cap_mode"),
])
def test_a_bad_ink_cap_value_names_its_key(value, mode, expected):
    with pytest.raises(ModelError) as caught:
        parse_ink_cap(value, mode)
    assert expected in str(caught.value)
    assert caught.value.exit_code == 2


def test_the_cap_defaults_to_quantize_and_is_off_when_unset():
    assert parse_ink_cap(None, None) is None
    assert parse_ink_cap(3, None) == {"max_colors": 3, "mode": "quantize"}
    assert parse_ink_cap(8, "Posterize")["mode"] == "posterize"


# -- `background` ----------------------------------------------------------

def test_key_flood_keys_only_the_region_connected_to_the_border():
    """Same colour, not connected: part of the artwork, and left alone."""
    ground, ink = (255, 255, 255), (0, 0, 0)
    with_island = frame(32, 16, lambda x, y: ground
                        if (6 <= y <= 9 and 10 <= x <= 20)
                        else (ink if (4 <= y <= 11 and 4 <= x <= 27) else ground))
    without_island = surrounded(32, 16, ink, ground)
    island, island_report = isolate_background(with_island, "key")
    plain, plain_report = isolate_background(without_island, "key")
    # The enclosed white island is background-coloured and touches no border
    # pixel of that colour, so the flood does not reach it: identical counts.
    assert island_report["pixels_moved"] == plain_report["pixels_moved"]
    assert island_report["key_color"] == "#ffffff"
    assert island_report["uniform"] is True
    assert 0 < island_report["pixels_moved"] < 32 * 16


def test_key_moves_exactly_the_pixels_it_reports():
    keyed, report = isolate_background(surrounded(32, 16, (0, 0, 0),
                                                  (255, 255, 255)), "key")
    transparent = sum(1 for offset in range(3, len(keyed.data), 4)
                      if keyed.data[offset] == 0)
    assert keyed.mode == "RGBA"
    assert transparent == report["pixels_moved"]
    assert report["pixels_moved"] > 0 and report["changed"] is True
    assert "flood-keyed the uniform border colour #ffffff" in report["note"]


def test_a_non_uniform_border_is_left_alone_and_says_so():
    """A border the modal colour covers only half of fails the coverage gate."""
    source = frame(32, 16, lambda x, y: (0, 0, 255) if (x, y)[0] % 2 == 0
                   and (x < 1 or y < 1 or x > 30 or y > 14)
                   else ((0, 0, 0) if (4 <= y <= 11 and 4 <= x <= 27)
                         else (255, 255, 255)))
    edges = border_colors(source)
    assert len(edges) == 2 and set(edges.values()) == {48}
    unchanged, report = isolate_background(source, "key")
    assert report["uniform"] is False
    assert report["keyed"] is False and report["keyed_pixels"] == 0
    assert report["border_coverage"] == 0.5
    assert report["tolerance"] == 2
    assert report["changed"] is False
    assert "not uniform, left alone" in report["note"]
    assert unchanged.data == source.data


def test_a_near_uniform_border_fires_within_the_tolerance():
    """#12's real flat-art frame: three colours one unit apart, 100% at N=1.

    The old exact-colour rule refused this frame even though the border is
    visibly one colour; the tolerance plus the coverage gate keys it, and
    reports the numbers the decision was made on.
    """
    source = frame(32, 16, lambda x, y: (252, 253, 253) if (x * 7 + y) % 3
                   else ((253, 253, 255) if (x, y) == (0, 0) else (253, 253, 253)))
    keyed, report = isolate_background(source, "key")
    assert report["keyed"] is True and report["uniform"] is True
    assert report["border_coverage"] == 1.0 and report["tolerance"] == 2
    assert report["keyed_pixels"] == report["pixels_moved"] > 0
    assert report["changed"] is True
    assert sum(1 for offset in range(3, len(keyed.data), 4)
               if keyed.data[offset] == 0) == report["keyed_pixels"]


def test_a_noisy_real_border_refuses_and_reports_the_coverage():
    """A real-generation border: modal colour on ~0% of the edges, refuses.

    Built the way #12 and #25 measured a klein-4B frame still in out/ — one
    modal colour on a sliver of the border and the rest spread over ~4 000
    distinct colours — so no tolerance in the safe range reaches the 95%
    coverage gate. The refusal must say what it measured.
    """
    import random
    rng = random.Random(7)
    def border_pixel():
        return (191, 193, 193) if rng.random() < 0.005 else (
            191 + rng.randint(-30, 30), 193 + rng.randint(-30, 30),
            193 + rng.randint(-30, 30))
    source = frame(64, 64, lambda x, y: border_pixel()
                   if (x < 1 or y < 1 or x > 62 or y > 63)
                   else ((40, 42, 46) if (16 <= x <= 47 and 16 <= y <= 47)
                         else border_pixel()))
    assert len(border_colors(source)) > 200
    unchanged, report = isolate_background(source, "key")
    assert report["keyed"] is False and report["keyed_pixels"] == 0
    assert report["uniform"] is False
    assert report["border_coverage"] < 0.01 and report["tolerance"] == 2
    assert report["changed"] is False
    assert "not uniform, left alone" in report["note"]
    assert unchanged.data == source.data


def test_white_composites_transparency_and_says_so_when_there_is_none():
    original = surrounded(16, 16, (0, 0, 0), (255, 255, 255))
    _same, nothing = isolate_background(original, "white")
    assert nothing["changed"] is False
    assert nothing["transparent_pixels"] == 0
    assert "nothing to composite" in nothing["note"]

    keyed, _ = isolate_background(original, "key")
    flattened, report = isolate_background(keyed, "white")
    assert report["changed"] is True
    assert report["transparent_pixels"] == 192
    assert flattened.mode == "RGB"
    # Keying changed the ALPHA only, so compositing those pixels onto white
    # reproduces the original RGB exactly — an end-to-end check of both passes.
    assert flattened.data == original.data


def test_the_background_keep_is_a_real_no_op():
    source = surrounded(16, 16, (0, 0, 0), (255, 255, 255))
    same, report = isolate_background(source, "keep")
    assert same is source
    assert report["changed"] is False
    assert "as decoded" in report["note"]


def test_a_bad_background_value_names_the_key():
    with pytest.raises(ModelError) as caught:
        parse_background("chroma")
    assert "background" in str(caught.value)
    for mode in BACKGROUND_MODES:
        assert parse_background(mode) == mode
    assert parse_background(None) == "keep"


# -- `hires` ---------------------------------------------------------------

def test_hires_defaults_are_the_documented_ones():
    assert parse_hires(None) is None
    assert parse_hires({}) == {"scale": 2.0, "strength": 0.35, "steps": None,
                               "upscaler": "lanczos"}
    assert parse_hires({"scale": 1.5, "strength": 0.2, "steps": 20,
                        "upscaler": "bicubic"}) == {
        "scale": 1.5, "strength": 0.2, "steps": 20, "upscaler": "bicubic"}


def test_hires_scales_the_size_it_reports():
    assert hires_target(512, 512, 1.5) == (768, 768)
    assert hires_target(1024, 1024, 2.0) == (2048, 2048)
    assert hires_target(512, 768, 1.5) == (768, 1152)


@pytest.mark.parametrize("block,expected", [
    (1.5, "hires must be an object"),
    ({"zoom": 2}, "hires.zoom"),
    ({"scale": 1.2}, "hires.scale"),
    ({"scale": 2.5}, "hires.scale"),
    ({"scale": "big"}, "hires.scale"),
    ({"strength": 0.6}, "hires.strength"),
    ({"strength": "lots"}, "hires.strength"),
    ({"steps": 0}, "hires.steps"),
    ({"steps": "many"}, "hires.steps"),
    ({"upscaler": "waifu2x"}, "hires.upscaler"),
])
def test_a_bad_hires_value_names_its_key(block, expected):
    with pytest.raises(ModelError) as caught:
        parse_hires(block)
    assert expected in str(caught.value)
    assert caught.value.exit_code == 2


def test_the_safe_band_is_0_2_to_0_35_and_0_5_is_the_hard_ceiling():
    """Above 0.5 is REFUSED, never clamped down to something quieter."""
    assert parse_hires({"strength": 0.5})["strength"] == 0.5   # allowed, warned
    with pytest.raises(ModelError) as caught:
        parse_hires({"strength": 0.51})
    assert "refused, never clamped" in str(caught.value)
    for upscaler in UPSCALERS:
        assert parse_hires({"upscaler": upscaler})["upscaler"] == upscaler


# -- `seeds` and `provenance` ----------------------------------------------

@pytest.mark.parametrize("value,expected", [
    ("1,2", "seeds must be a list"),
    ([], "at least one seed"),
    ([1, "two"], "seeds[1]"),
    ([True], "seeds[0]"),
])
def test_a_bad_seed_sweep_names_the_key(value, expected):
    with pytest.raises(ModelError) as caught:
        parse_seeds(value)
    assert expected in str(caught.value)


def test_a_seed_sweep_is_a_list_of_integers_in_order():
    assert parse_seeds(None) is None
    assert parse_seeds([3, 1, 2]) == [3, 1, 2]     # the caller's order, kept


def test_provenance_must_be_a_boolean():
    assert parse_provenance(None) is False
    assert parse_provenance(True) is True
    with pytest.raises(ModelError) as caught:
        parse_provenance("yes")
    assert "provenance must be true or false" in str(caught.value)


def test_provenance_is_implied_by_a_pass_that_measured_or_changed_the_frame():
    assert records_provenance(True) is True
    assert records_provenance(False) is False
    assert records_provenance(False, ink_cap={"max_colors": 3}) is True
    assert records_provenance(False, hires={"scale": 2.0}) is True
    assert records_provenance(False, seeds=[1]) is True
    assert records_provenance(False, background="key") is True
    # ...but an explicit `keep` is not a pass, and asks for nothing.
    assert records_provenance(False, background="keep") is False


def test_the_mode_tuples_are_what_the_docs_list():
    assert INK_CAP_MODES == ("quantize", "posterize")
    assert BACKGROUND_MODES == ("white", "key", "keep")
    assert UPSCALERS == ("lanczos", "nearest", "bilinear", "bicubic")
