"""Output-side passes on a decoded frame: an ink cap, a background, a palette.

Everything here works on a raw pixel buffer (``mode``/``width``/``height`` plus
bytes) rather than on a Pillow image, for two reasons:

* **The suite must run with no Pillow and no torch.** ``engine.py`` is the PIL
  seam and the tests fake it, so a reduction that lived there would be
  unfalsifiable on any machine but the GPU box. Here the ink counting, the
  palette cut and the flood key are real code the tests drive with real bytes.
* **A count is evidence; a claim is not.** ``colors_present`` is measured from
  the buffer that is actually written, so "at most N colours" is a number a
  caller can read back rather than a promise about a pipeline's internals.

Nothing in this module judges a frame. The passes are reductions and
isolations — ``ink_cap`` is a colour REDUCTION, never a colour *separation*, and
the wording in the response follows that ("reduce the frame to at most N flat
colours"), because a separation implies per-ink plates that this is not.
"""

from __future__ import annotations

import math
from collections import Counter

from .models import ModelError

# The three passes, and the values each key accepts. Kept here rather than in the
# registry because they are properties of the OP, not of a checkpoint: every
# model that can produce a frame can be capped and keyed.
INK_CAP_MODES = ("quantize", "posterize")
BACKGROUND_MODES = ("white", "key", "keep")
UPSCALERS = ("lanczos", "nearest", "bilinear", "bicubic")

# An 8-bit PNG can carry 256 colours, and a two-colour frame is the floor that is
# still a frame: below 2 there is nothing to reduce.
INK_CAP_MIN = 2
INK_CAP_MAX = 256

# Posterize is a per-channel bit reduction, so its reachable counts are
# 2**(3*bits) — 8, 64, 512 ... — not an arbitrary N. A cap below 8 is therefore
# not reachable by posterize at all, and saying so (rather than silently
# overshooting to 8) is the whole point of validating it.
POSTERIZE_MIN_COLORS = 8
POSTERIZE_MAX_BITS = 8

# `hires` is a second pass, and the numbers that make it a second pass rather
# than a re-roll: below 1.5 it is not worth the extra generation, above 2.0 the
# img2img re-render invents detail at a size the checkpoint was never trained at.
HIRES_MIN_SCALE = 1.5
HIRES_MAX_SCALE = 2.0
# 0.2–0.35 is the safe band (composition survives); above 0.5 the composition
# drifts, which is a different request than "the same frame, more of it".
HIRES_SAFE_STRENGTH_LOW = 0.2
HIRES_SAFE_STRENGTH_HIGH = 0.35
HIRES_MAX_STRENGTH = 0.5
HIRES_DEFAULT_SCALE = 2.0
HIRES_DEFAULT_STRENGTH = 0.35
HIRES_DEFAULT_UPSCALER = "lanczos"
HIRES_KEYS = ("scale", "strength", "steps", "upscaler")


# -- the frame -------------------------------------------------------------


class Frame:
    """A raw 8-bit RGB or RGBA buffer. The unit every pass below operates on."""

    __slots__ = ("mode", "width", "height", "data")

    def __init__(self, mode: str, width: int, height: int, data: bytes):
        mode = (mode or "").upper()
        if mode not in ("RGB", "RGBA"):
            raise ValueError("Frame mode must be RGB or RGBA, got %r" % mode)
        channels = 3 if mode == "RGB" else 4
        if len(data) != width * height * channels:
            raise ValueError("%dx%d %s needs %d bytes, got %d"
                             % (width, height, mode,
                                width * height * channels, len(data)))
        self.mode = mode
        self.width = int(width)
        self.height = int(height)
        self.data = bytes(data)

    @property
    def channels(self) -> int:
        return 3 if self.mode == "RGB" else 4

    def pixel(self, x: int, y: int) -> tuple:
        offset = (y * self.width + x) * self.channels
        return tuple(self.data[offset:offset + self.channels])

    def colors(self) -> Counter:
        """Exact colour histogram. The unit of "how many inks are in this"."""
        channels = self.channels
        data = self.data
        counter: Counter = Counter()
        for offset in range(0, len(data), channels):
            counter[data[offset:offset + channels]] += 1
        return counter

    def color_count(self) -> int:
        return len(self.colors())

    def with_rgba(self) -> "Frame":
        """This frame with an opaque alpha channel (identity if already RGBA)."""
        if self.mode == "RGBA":
            return self
        out = bytearray()
        for offset in range(0, len(self.data), 3):
            out += self.data[offset:offset + 3] + b"\xff"
        return Frame("RGBA", self.width, self.height, bytes(out))


def rect_frame(width: int, height: int, rows) -> Frame:
    """Build a frame from one colour per row — for tests and probes."""
    out = bytearray()
    for y in range(height):
        colour = tuple(rows[y % len(rows)])
        out += bytes(colour) * width
    return Frame("RGB", width, height, bytes(out))


# -- `ink_cap` -------------------------------------------------------------


def parse_ink_cap(ink_cap, ink_cap_mode=None) -> dict | None:
    """Validate the ``ink_cap`` / ``ink_cap_mode`` pair, or ``None`` if unset.

    A bad value is a caller error naming the key it came from — never a silent
    default, and never a clamp. The posterize floor is rejected for the same
    reason: a cap of 3 asked for as posterize cannot be reached by a per-channel
    bit reduction, and quietly producing 8 colours would be a lie about the cap.
    """
    if ink_cap is None and ink_cap_mode is None:
        return None
    if ink_cap is None:
        raise ModelError(
            "ink_cap_mode '%s' was given without ink_cap: there is no cap for it "
            "to apply to (set ink_cap to the number of flat colours you want)"
            % ink_cap_mode, exit_code=2)
    if isinstance(ink_cap, bool) or not isinstance(ink_cap, int):
        raise ModelError("ink_cap must be an integer between %d and %d, got %r"
                         % (INK_CAP_MIN, INK_CAP_MAX, ink_cap), exit_code=2)
    if not INK_CAP_MIN <= ink_cap <= INK_CAP_MAX:
        raise ModelError("ink_cap must be between %d and %d, got %d"
                         % (INK_CAP_MIN, INK_CAP_MAX, ink_cap), exit_code=2)
    mode = "quantize" if ink_cap_mode is None else str(ink_cap_mode).strip().lower()
    if mode not in INK_CAP_MODES:
        raise ModelError("ink_cap_mode must be one of %s, got %r"
                         % ("/".join(INK_CAP_MODES), ink_cap_mode), exit_code=2)
    if mode == "posterize" and ink_cap < POSTERIZE_MIN_COLORS:
        raise ModelError(
            "ink_cap %d with ink_cap_mode 'posterize' cannot be honoured: "
            "posterize is a per-channel bit reduction, so its smallest reachable "
            "cap is %d colours (3 channels x 1 bit). Use ink_cap_mode 'quantize' "
            "for a cap below %d."
            % (ink_cap, POSTERIZE_MIN_COLORS, POSTERIZE_MIN_COLORS), exit_code=2)
    return {"max_colors": ink_cap, "mode": mode}


def _median_cut(entries, want: int) -> list:
    """Deterministic median cut: split the widest box at its weighted median.

    The palette entry for a box is the box's most FREQUENT colour rather than its
    centroid, so every colour in the result is a colour the frame actually
    contained — a reduction, not an invention.
    """
    boxes = [list(entries)]
    while len(boxes) < want:
        chosen = None
        widest = 0
        for index, box in enumerate(boxes):
            if len(box) < 2:
                continue
            spread = max(max(entry[0][ch] for entry in box)
                         - min(entry[0][ch] for entry in box) for ch in range(3))
            if spread > widest:
                widest = spread
                chosen = index
        if chosen is None:
            break
        box = boxes[chosen]
        channel = max(range(3), key=lambda ch: (
            max(entry[0][ch] for entry in box) - min(entry[0][ch] for entry in box)))
        box.sort(key=lambda entry: (entry[0][channel], entry[0]))
        half = sum(entry[1] for entry in box) / 2.0
        running = 0
        split = 1
        for index, entry in enumerate(box):
            running += entry[1]
            if running >= half:
                split = min(max(index + 1, 1), len(box) - 1)
                break
        boxes[chosen:chosen + 1] = [box[:split], box[split:]]
    palette = []
    for box in boxes:
        if not box:
            continue
        best = max(box, key=lambda entry: (entry[1], tuple(-c for c in entry[0])))
        palette.append(best[0])
    return palette


def _reduce_quantize(frame: Frame, cap: int) -> tuple[Frame, dict]:
    """Median-cut the frame to at most ``cap`` colours, chosen from its own."""
    histogram = frame.colors()
    palette = _median_cut(list(histogram.items()), cap)
    # Nearest palette entry per distinct colour, computed once and looked up per
    # pixel: a 2048x2048 frame has up to 4 M pixels and far fewer distinct ones.
    lookup = {}
    for colour in histogram:
        rgb = colour[:3]
        lookup[colour] = min(
            range(len(palette)),
            key=lambda index: (sum((rgb[ch] - palette[index][ch]) ** 2
                                   for ch in range(3)), index))
    channels = frame.channels
    out = bytearray()
    # One loop for both modes: a palette entry is already as wide as the frame
    # (the histogram was taken over whole pixels), so nothing has to be
    # reassembled per channel — and the alpha bytes a keyed frame carries come
    # through untouched, because they were part of the key.
    for offset in range(0, len(frame.data), channels):
        out += bytes(palette[lookup[frame.data[offset:offset + channels]]])
    return Frame(frame.mode, frame.width, frame.height, bytes(out)), {
        "palette": [hex_color(colour) for colour in palette]}


def _posterize_value(value: int, levels: int) -> int:
    """Round one channel channel to ``levels`` evenly spaced flat values."""
    if levels < 2:
        return value
    step = 255.0 / (levels - 1)
    return int(round(round(value / step) * step))


def _reduce_posterize(frame: Frame, cap: int) -> tuple[Frame, dict]:
    """Per-channel bit reduction, then MEASURED: the count is whatever it is.

    The cap chooses the largest level count whose cube fits inside it
    (``levels = 2**bits`` with ``2**(3*bits) <= cap``), so the result is at most
    the cap and is usually comfortably under it — which is reported as the count
    actually present rather than as the number that was asked for.
    """
    bits = max(1, min(POSTERIZE_MAX_BITS, int(math.log2(float(cap))) // 3))
    levels = 2 ** bits
    channels = frame.channels
    out = bytearray()
    for offset in range(0, len(frame.data), channels):
        for channel in range(3):
            out.append(_posterize_value(frame.data[offset + channel], levels))
        if channels == 4:
            out.append(frame.data[offset + 3])
    return Frame(frame.mode, frame.width, frame.height, bytes(out)), {
        "bits": bits, "levels_per_channel": levels}


def reduce_colors(frame: Frame, cap: int, mode: str = "quantize") -> tuple[Frame, dict]:
    """Reduce ``frame`` to at most ``cap`` flat colours. Pure; returns a report.

    The report always carries BOTH numbers — the cap and the count actually
    present — and ``changed`` is false when the frame was already at or below the
    cap. A skip is a state, not work done, and the response says so instead of
    implying a reduction happened.
    """
    before = frame.color_count()
    report = {"max_colors": cap, "mode": mode, "colors_before": before}
    if before <= cap:
        report.update({"colors_present": before, "changed": False,
                       "note": "the frame was already at %d colour(s), at or "
                               "below the %d cap: nothing was reduced"
                               % (before, cap)})
        return frame, report
    if mode == "posterize":
        reduced, extra = _reduce_posterize(frame, cap)
    else:
        reduced, extra = _reduce_quantize(frame, cap)
    present = reduced.color_count()
    report.update(extra)
    report.update({
        "colors_present": present,
        "changed": True,
        "note": "reduced the frame from %d colours to %d, at or below the %d cap; "
                "this is a colour reduction, not a colour separation"
                % (before, present, cap),
    })
    return reduced, report


# -- `background` ----------------------------------------------------------


def parse_background(background) -> str:
    """Validate ``background``. Unset means ``keep`` — today's behaviour."""
    if background is None:
        return "keep"
    value = str(background).strip().lower()
    if value not in BACKGROUND_MODES:
        raise ModelError("background must be one of %s, got %r"
                         % ("/".join(BACKGROUND_MODES), background), exit_code=2)
    return value


def hex_color(colour) -> str:
    return "#%02x%02x%02x" % tuple(colour[:3])


def border_colors(frame: Frame) -> Counter:
    """The exact colours on the frame's four edges. Keying starts from here."""
    counter: Counter = Counter()
    if frame.width == 0 or frame.height == 0:
        return counter
    for x in range(frame.width):
        counter[frame.pixel(x, 0)] += 1
        counter[frame.pixel(x, frame.height - 1)] += 1
    for y in range(frame.height):
        counter[frame.pixel(0, y)] += 1
        counter[frame.pixel(frame.width - 1, y)] += 1
    return counter


def isolate_background(frame: Frame, mode: str) -> tuple[Frame, dict]:
    """``white`` or ``key`` on a decoded frame. Pure; returns a report.

    ``key`` is a 4-connected FLOOD key from the border, not a colour match over
    the whole frame: a white region inside the artwork that touches no border
    pixel of the same colour is part of the artwork and stays. A border that is
    not one uniform colour is left completely alone and says so — keying a
    near-uniform edge would take pixels that are not background with it.
    """
    if mode == "keep":
        return frame, {"mode": "keep", "changed": False,
                       "note": "the frame was written as decoded"}
    if mode == "white":
        return _flatten_to_white(frame)
    return _flood_key(frame)


def _flatten_to_white(frame: Frame) -> tuple[Frame, dict]:
    """Composite the frame onto opaque white (what prep's own checks assume)."""
    rgba = frame.with_rgba()
    data = rgba.data
    out = bytearray()
    transparent = 0
    for offset in range(0, len(data), 4):
        alpha = data[offset + 3]
        if alpha == 255:
            out += data[offset:offset + 3]
            continue
        transparent += 1
        scale = alpha / 255.0
        out += bytes(int(round(data[offset + ch] * scale + 255 * (1 - scale)))
                     for ch in range(3))
    report = {"mode": "white", "transparent_pixels": transparent,
              "changed": transparent > 0}
    if transparent:
        report["note"] = ("composited %d transparent pixel(s) onto white and "
                          "flattened the frame to RGB" % transparent)
    else:
        report["note"] = ("the frame was already opaque, so there was nothing to "
                          "composite: the ground colour is a prompt matter")
    return Frame("RGB", frame.width, frame.height, bytes(out)), report


def _flood_key(frame: Frame) -> tuple[Frame, dict]:
    """Flood-key the frame's uniform border colour to transparent."""
    edges = border_colors(frame)
    if len(edges) != 1:
        return frame, {
            "mode": "key", "uniform": False, "border_colors": len(edges),
            "changed": False,
            "note": "the border is not a uniform colour (%d distinct colours on "
                    "the edges): not uniform, left alone" % len(edges)}
    key = next(iter(edges))
    rgba = frame.with_rgba()
    width, height = rgba.width, rgba.height
    data = bytearray(rgba.data)
    key_bytes = bytes(key)
    seen = bytearray(width * height)
    stack = []
    for x in range(width):
        stack.append((x, 0))
        stack.append((x, height - 1))
    for y in range(height):
        stack.append((0, y))
        stack.append((width - 1, y))
    moved = 0
    while stack:
        x, y = stack.pop()
        if x < 0 or y < 0 or x >= width or y >= height:
            continue
        index = y * width + x
        if seen[index]:
            continue
        offset = index * 4
        if rgba.data[offset:offset + 3] != key_bytes:
            continue
        seen[index] = 1
        data[offset + 3] = 0
        moved += 1
        stack.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    report = {"mode": "key", "uniform": True, "key_color": hex_color(key),
              "pixels_moved": moved, "changed": moved > 0}
    if moved:
        report["note"] = ("flood-keyed the uniform border colour %s to "
                          "transparent: %d pixel(s) moved, and pixels of that "
                          "colour not connected to the border were left alone"
                          % (hex_color(key), moved))
    else:
        report["note"] = ("the border is the uniform colour %s but no pixel was "
                          "connected to it by that colour: nothing was keyed"
                          % hex_color(key))
    return Frame("RGBA", width, height, bytes(data)), report


# -- `hires` ---------------------------------------------------------------


def parse_hires(hires) -> dict | None:
    """Validate the ``hires`` block. Unset means one pass, as before.

    Every value is checked and every default is documented in `docs/API.md`; a
    strength above 0.5 is REFUSED rather than clamped, because a silently
    lowered strength would render a different request than the one that was sent
    and report it as done.
    """
    if hires is None:
        return None
    if not isinstance(hires, dict):
        raise ModelError(
            "hires must be an object like {\"scale\": 2.0, \"strength\": 0.35, "
            "\"steps\": 20, \"upscaler\": \"lanczos\"}, got %r" % (hires,),
            exit_code=2)
    unknown = sorted(set(hires) - set(HIRES_KEYS))
    if unknown:
        raise ModelError("hires.%s is not a hires option; the options are %s"
                         % (unknown[0], ", ".join(HIRES_KEYS)), exit_code=2)

    raw_scale = hires.get("scale", HIRES_DEFAULT_SCALE)
    if isinstance(raw_scale, bool) or not isinstance(raw_scale, (int, float)):
        raise ModelError("hires.scale must be a number between %s and %s, got %r"
                         % (HIRES_MIN_SCALE, HIRES_MAX_SCALE, raw_scale),
                         exit_code=2)
    scale = float(raw_scale)
    if not HIRES_MIN_SCALE <= scale <= HIRES_MAX_SCALE:
        raise ModelError(
            "hires.scale must be between %s and %s, got %s: below %s a second "
            "pass is not worth a generation, and above %s the img2img re-render "
            "invents detail at a size the checkpoint was not trained at"
            % (HIRES_MIN_SCALE, HIRES_MAX_SCALE, raw_scale, HIRES_MIN_SCALE,
               HIRES_MAX_SCALE), exit_code=2)

    raw_strength = hires.get("strength", HIRES_DEFAULT_STRENGTH)
    if isinstance(raw_strength, bool) or not isinstance(raw_strength, (int, float)):
        raise ModelError("hires.strength must be a number between 0 and %s, got %r"
                         % (HIRES_MAX_STRENGTH, raw_strength), exit_code=2)
    strength = float(raw_strength)
    if not 0.0 <= strength <= HIRES_MAX_STRENGTH:
        raise ModelError(
            "hires.strength must be between 0 and %s, got %s: above %s the "
            "composition drifts, which is a different request than \"the same "
            "frame, more of it\" (this is refused, never clamped)"
            % (HIRES_MAX_STRENGTH, raw_strength, HIRES_MAX_STRENGTH), exit_code=2)

    raw_steps = hires.get("steps")
    if raw_steps is not None and (isinstance(raw_steps, bool)
                                  or not isinstance(raw_steps, int)):
        raise ModelError("hires.steps must be an integer >= 1, got %r"
                         % (raw_steps,), exit_code=2)
    if raw_steps is not None and raw_steps < 1:
        raise ModelError("hires.steps must be >= 1, got %d" % raw_steps, exit_code=2)

    upscaler = str(hires.get("upscaler", HIRES_DEFAULT_UPSCALER)).strip().lower()
    if upscaler not in UPSCALERS:
        raise ModelError("hires.upscaler must be one of %s, got %r"
                         % ("/".join(UPSCALERS), hires.get("upscaler")),
                         exit_code=2)

    return {"scale": scale, "strength": strength, "steps": raw_steps,
            "upscaler": upscaler}


def hires_target(width: int, height: int, scale: float) -> tuple[int, int]:
    """The size a ``hires`` second pass would run at. Rounded, and then checked."""
    return int(round(width * scale)), int(round(height * scale))


# -- `seeds` ---------------------------------------------------------------


def parse_seeds(seeds) -> list | None:
    """Validate a seed sweep: a non-empty list of integers, or ``None``."""
    if seeds is None:
        return None
    if isinstance(seeds, (str, bytes)) or not isinstance(seeds, (list, tuple)):
        raise ModelError("seeds must be a list of integers, got %r" % (seeds,),
                         exit_code=2)
    if not seeds:
        raise ModelError("seeds is an empty list: a sweep needs at least one "
                         "seed", exit_code=2)
    out = []
    for index, entry in enumerate(seeds):
        if isinstance(entry, bool) or not isinstance(entry, int):
            raise ModelError("seeds[%d] must be an integer, got %r"
                             % (index, entry), exit_code=2)
        out.append(int(entry))
    return out


def parse_provenance(provenance) -> bool:
    """Validate ``provenance``. Unset means "only when a new key needs it"."""
    if provenance is None:
        return False
    if not isinstance(provenance, bool):
        raise ModelError("provenance must be true or false, got %r" % (provenance,),
                         exit_code=2)
    return provenance


def records_provenance(explicit: bool, *, ink_cap=None, hires=None, seeds=None,
                       background: str = "keep") -> bool:
    """Whether to record a frame's provenance for this request.

    Explicitly asked for, or implied by a request that MEASURED or changed the
    frame — a comparison between frames needs those numbers to have been written
    down. A plain request keeps writing nothing it did not write before, which is
    what makes the determinism check meaningful.
    """
    return bool(explicit or ink_cap is not None or hires is not None
                or seeds is not None or background != "keep")


def hires_warnings(spec_key: str, hires: dict) -> list[str]:
    """The honest note when a hires strength sits outside the safe band."""
    strength = hires["strength"]
    if strength > HIRES_SAFE_STRENGTH_HIGH:
        return ["hires.strength %s is above the safe band %s-%s: the second pass "
                "keeps the upscaled frame's composition only loosely there, so "
                "the result may differ from the first pass by more than detail "
                "(%s was asked for, and is what ran)."
                % (strength, HIRES_SAFE_STRENGTH_LOW, HIRES_SAFE_STRENGTH_HIGH,
                   spec_key)]
    return []
