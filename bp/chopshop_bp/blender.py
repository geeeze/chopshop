"""Blender spec -> rendered 3D (the ``blender`` operation of the contract).

The other operations answer with SVG, which is flat by definition. This one
answers with what a rasteriser and a 3D viewer consume: PNG frames from a real
Blender render, and optionally a GLB. It is the one operation whose output is not
a document — so it is the one operation that BUILDS the artifacts and hands back
their names, and the service's manifest (the same names, for a client to fetch)
is derived from them rather than guessed.

Blender is NOT a dependency of this package, and nothing here imports ``bpy``:
the package writes the spec to a temp file, runs a headless Blender process and
collects the files that came back. Same subprocess boundary chopshop-svg uses for
Inkscape and VTracer, for the same reasons — a renderer that crashes must not
take the service with it, the package stays stdlib-only, and a machine with no
Blender installed still runs every other operation. ``BlenderUnavailable`` is the
one failure mode, and it always names the binary and why (a missing binary or a
non-zero exit is never a silent empty success).

The exit code is the whole error channel, and it is a weak one: MEASURED,
``blender --background --python`` exits 0 when the script raises an unhandled
exception. Two things close that hole — the in-Blender script wraps its own main
in a guard that turns any exception into an explicit non-zero exit and checks
each file on disk before reporting success (``blender/bpy_geometry.py``), and the
frame names are computed from the spec here, so an empty answer is a named
failure rather than an empty list.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile

from . import config
from .spec import SpecError, check_element, check_tiling, is_number

# The script that runs INSIDE Blender, addressed relative to this file so the
# repo can live anywhere: no absolute machine path is written down, the same rule
# config.py states for the environment. It is standalone on purpose (it imports
# only bpy and the stdlib and cannot import this package), which is why the frame
# stem rule below is mirrored there — see ``output_stem``.
BPY_SCRIPT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "blender", "bpy_geometry.py"
)

# The contract's defaults (docs/contract.md). Named here rather than inlined so
# the validation, the naming and the doc cannot drift apart.
DEFAULT_DEPTH = 0.5
DEFAULT_BEVEL_DEPTH = 0.02
DEFAULT_BEVEL_RESOLUTION = 2
DEFAULT_VIEWS = 1
DEFAULT_BACKGROUND = "#1a1a24"
DEFAULT_ENGINE = "workbench"
ENGINES = ("workbench", "eevee")
DEFAULT_RENDER_SIZE = (1024, 1024)
DEFAULT_TUBE_RADIUS = 0.02

# The camera, which the spec used to have no say in at all: elevation was a
# module constant, so EVERY render of EVERY spec came from 25 degrees above the
# horizon and a plan view — the reading a graph or a floor plan needs — was
# unreachable. A renderer that cannot look straight down cannot draw a chart.
DEFAULT_ELEVATION = 25.0
DEFAULT_AZIMUTH = 0.0
DEFAULT_PROJECTION = "ortho"
DEFAULT_LENS = 50.0
PROJECTIONS = ("ortho", "perspective")

# Geometry sampling (chopshop-bp#2). These are the DEFAULTS a spec overrides
# through `render.curve_resolution`, and they are deliberately the values the
# in-Blender builder has always used: a caller who says nothing gets exactly the
# renders they got before this field existed, byte for byte. That is enforced
# rather than intended — `test_the_curve_resolution_default_does_not_change_a
#_render` hashes a real frame before and after and compares.
#
# The reading of each: `circle` is the straight-segment count around a circle or
# ellipse, `corner` is the steps per rounded corner, `bezier` is the samples per
# C/Q/S/T curve segment, and `spline` is Blender's own `resolution_u` on the
# curve data. The first three are this file's sampling; the last is Blender's.
# A circle at 64 is faceted in a close-up, which is the limit the issue names.
DEFAULT_CURVE_RESOLUTION = {
    "circle": 64, "corner": 8, "bezier": 16, "spline": 12,
}
# An integer >= 3 everywhere, for the same reason a primitive's `segments` is: a
# curve approximated by fewer than three straight pieces is not a curve, and a
# count of 0 or 1 gives Blender nothing to tessellate.
MIN_CURVE_RESOLUTION = 3
MAX_CURVE_RESOLUTION = 4096

# Surface shading (chopshop-bp#2). Principled BSDF defaults are 0.5 roughness
# and 0.0 metallic, and this repo renders flat poster work where a shiny
# surface is never wanted — so the DEFAULT is matte and non-metallic, which is
# also what a Workbench render shows, meaning a spec that says nothing looks the
# same on both engines. A caller who wants a highlight asks for it by name.
#
# EEVEE honours all of these; **Workbench ignores every one of them** (it reads
# `diffuse_color` and nothing else), which is stated in the contract rather than
# left to be discovered by comparing two renders.
DEFAULT_SHADING = {
    "roughness": 1.0, "metallic": 0.0, "specular": 0.0,
}
# alpha is 0..1 and belongs on the ELEMENT's `material` block rather than here:
# a partly transparent surface is a property of one object (a shadow pass, a
# highlight overlay, glass), and a document-wide alpha would make every element
# see-through. It needs EEVEE: Workbench renders opaque no matter what it says.
MAX_ALPHA = 1.0

# The per-element `material` block (chopshop-bp#2): the surface properties the
# shared vocabulary has no room for, because SVG has no material. A `material`
# key is therefore 3D-only in exactly the way `z` and `depth` are, and for the
# same reason: `generate` must refuse it rather than accept and ignore it.
#
# `alpha` is here and not in `render.shading` because it is the one shading
# property that belongs to a single object — a see-through overlay, a shadow —
# and a document-wide alpha would make every element translucent at once.
_MATERIAL_FIELDS = {"roughness", "metallic", "specular", "emission", "alpha"}
# emission is a COLOUR, not a number: "emits cyan" is a different statement from
# "emits". It takes the same #rgb/#rrggbb the fills do, and a material with no
# emission does not emit.
_MATERIAL_COLOUR_FIELDS = ("emission",)
# The 0..1 fields. Roughness and specular are bounded above by 1 because the
# shader's range is; metallic is too, for the same reason.
_MATERIAL_UNIT_FIELDS = ("roughness", "metallic", "specular", "alpha")

# Fields an element may carry in 3D and nowhere else. They are NOT part of the
# shared element vocabulary (spec.py): `generate` draws SVG, which is flat, so a
# `depth` there would be a field accepted and silently ignored. They are checked
# in ``_check_element`` and withheld from the shared check instead.
#
# `luminance` and `layer` are the relief MEASUREMENTS (chopshop-bp#3), and are
# 3D-only for the same reason as `z`: a height has no reading in a flat drawing.
# They are meaningless without a `relief` block, which is why they are numbers
# this side only reads when the spec states a rule — see `_check_relief`.
_ELEMENT_3D_FIELDS = ("z", "depth", "material", "luminance", "layer")

_ELEMENT_FIELDS = {
    "rect": {"x", "y", "width", "height", "rx", "fill", "stroke", "stroke_width"},
    "circle": {"cx", "cy", "r", "fill", "stroke", "stroke_width"},
    "ellipse": {"cx", "cy", "rx", "ry", "fill", "stroke", "stroke_width"},
    "polygon": {"points", "fill", "stroke", "stroke_width"},
    "polyline": {"points", "stroke", "stroke_width"},
    "line": {"x1", "y1", "x2", "y2", "stroke", "stroke_width"},
    "path": {"d", "fill", "stroke", "stroke_width"},
}

# The 3D PRIMITIVES — the types that exist only here, because `generate` draws
# SVG and SVG has no solid with a silhouette that changes as the camera moves.
# Every one is a CLOSED solid with no outline, so `fill` is its only colour:
# a mesh has no stroke to tint, and a `stroke` this accepted and ignored would
# be a lie in the same shape as a `depth` on a flat spec. They are deliberately
# absent from ``spec._ELEMENT_FIELDS``, so the shared check refuses them by
# name and the flat operations cannot be handed one.
#
# Each is a transform (where, how big) plus the same `fill` the rest of the
# vocabulary uses, and each takes `z` and `depth` on the SAME symmetric terms a
# contour does — `depth` is the HALF extent along z, so the solid spans
# z - depth .. z + depth (see ``element_depth``, which is why that measurement
# is now a test and not a comment).
_PRIMITIVE_FIELDS = {
    # A box is a rect that has stopped pretending: the third extent is real
    # rather than an extrusion of a silhouette. Anchored at its (x, y) corner so
    # it drops into a 2D layout where the others already sit.
    "box": {"x", "y", "width", "height", "depth", "z", "fill", "material",
            "luminance", "layer"},
    # The curved solids. `segments` (and the torus's `tube_segments`) is the
    # resolution rule: how many straight pieces approximate the curve. It is
    # per element, so one document can carry a smooth hero sphere and a faceted
    # background one.
    "sphere": {"cx", "cy", "r", "depth", "z", "fill", "segments", "material",
               "luminance", "layer"},
    "cylinder": {"cx", "cy", "r", "depth", "z", "fill", "segments", "material",
                 "luminance", "layer"},
    "cone": {"cx", "cy", "r", "depth", "z", "fill", "segments", "material",
             "luminance", "layer"},
    # A torus is a ring, so it has two radii: `r` is the distance from the
    # centre to the middle of the tube, `tube` is the tube's own radius.
    "torus": {"cx", "cy", "r", "tube", "depth", "z", "fill", "segments",
              "tube_segments", "material", "luminance", "layer"},
}

# The fields every primitive must carry, and which of them are numbers.
_PRIMITIVE_REQUIRED = {
    "box": ["x", "y", "width", "height"],
    "sphere": ["cx", "cy", "r"],
    "cylinder": ["cx", "cy", "r"],
    "cone": ["cx", "cy", "r"],
    "torus": ["cx", "cy", "r", "tube"],
}
_PRIMITIVE_NUMERIC = {
    "box": {"x", "y", "width", "height"},
    "sphere": {"cx", "cy", "r"},
    "cylinder": {"cx", "cy", "r"},
    "cone": {"cx", "cy", "r"},
    "torus": {"cx", "cy", "r", "tube"},
}
# Resolution: an integer >= 3 (a polygon has three sides, so a lower bound
# below that is not a curve at all), and the same bound on the torus's tube.
_PRIMITIVE_SEGMENT_FIELDS = ("segments", "tube_segments")
# Radii and extents that must be positive, or the primitive is not a solid.
_PRIMITIVE_POSITIVE = {
    "box": ("width", "height"),
    "sphere": ("r",),
    "cylinder": ("r",),
    "cone": ("r",),
    "torus": ("r", "tube"),
}

# Defaults for the resolution rule, stated once so the validation, the builder
# and the contract cannot drift. A sphere at 32 segments is smooth at any
# framing this operation produces and cheap to build; the torus's tube gets
# fewer because it is the smaller of the two loops.
DEFAULT_SEGMENTS = 32
DEFAULT_TUBE_SEGMENTS = 16

_PRIMITIVE_TYPES = tuple(_PRIMITIVE_FIELDS)

# The element types that are a CLOSED contour by definition, so they render as a
# filled, extruded, bevelled solid. A `path` is closed only when its own data
# closes the contour AND it carries a fill (see ``is_stroke``).
CLOSED_TYPES = ("rect", "circle", "ellipse", "polygon")

# A path command the in-Blender builder understands. Everything else (an arc,
# most often) is refused here rather than quietly drawn as a straight line: a
# wrong solid is worse than a named error.
_PATH_COMMANDS = "MmLlHhVvZzCcSsQqTt"
_PATH_LETTERS = re.compile(r"[A-Za-z]")
_PATH_NUMBERS = re.compile(r"-?\d*\.?\d+")

_EXTRUDE_FIELDS = {"depth", "bevel_depth", "bevel_resolution"}
_RENDER_FIELDS = {"size", "views", "background", "engine",
                  "elevation", "azimuth", "projection", "lens",
                  "curve_resolution", "shading"}
# The geometry-sampling knobs, as a `render` sub-block. A resolution is a
# property of the RENDER rather than of an element: one document has one camera
# and one frame size, so a circle drawn at the back of a scene wants the same
# sampling as one in front. Per-element resolution already exists for the 3D
# primitives (`segments`), where a smooth hero solid and cheap background
# geometry genuinely coexist in one frame.
_CURVE_RESOLUTION_FIELDS = {"circle", "corner", "bezier", "spline"}
# The shading knobs, as a `render` sub-block rather than per element. A `roughness`
# is a property of the LIGHT as much as of the surface, and a document that sets
# it per element would have five numbers that are almost always the same. The
# `material` block on an element still overrides these (see `_material_spec`).
_SHADING_FIELDS = {"roughness", "metallic", "specular"}
_SIZE_FIELDS = {"width", "height"}
_EXPORT_FIELDS = {"glb"}

# -- the relief rule (chopshop-bp#3) ----------------------------------------
#
# Turning a 2D image into DEPTH is the missing half of raster -> trace -> extrude.
# The division of labour is stated rather than blurred, because it is a change to
# what this repository is for if it gets it wrong: this repo DRAWS and does not
# MEASURE. So the height rule is DATA in the spec — a `relief` block naming one
# rule and its parameters — and the per-element measurement is the CALLER's,
# handed over as a number per element.
#
# That split is what keeps the boundary intact: a luminance value cannot be
# computed here (this repository does not read rasters), and an area ordering
# cannot either without a trace this repository did not produce. What this side
# owns is the part that IS drawing: given a stated rule and a stated measurement,
# what height does this contour stand at. That is arithmetic over the spec, the
# same category of work as applying `extrude.depth`, and it is testable without a
# renderer — which a "smart" depth heuristic invented here would not be.
#
# Two rules, because they are the two that come up and they disagree about what
# height means:
#
#   `luminance` — brighter stands higher. Each element carries `luminance`
#     (0..1, measured by the caller from the raster it traced), mapped linearly
#     across `z_min`..`z_max`. `invert` flips it for a bas-relief / intaglio
#     reading, where the light parts are the recess.
#   `layers` — a layered cut-paper look. Each element carries `layer` (an
#     integer, 0 = first trace layer) and successive layers are lifted by
#     `step`. Ordinal, not measured: it is the trace's own stacking order, and
#     the relief is the cut-paper one rather than the tonal one.
#
# Both read a field the caller sets per element; a spec that sets a rule and then
# gives an element neither measurement is refused, because the alternative is a
# contour that silently sits on the floor of the range and reads as a decision
# nobody made.
_RELIEF_RULES = ("luminance", "layers")
_RELIEF_FIELDS = {"rule", "z_min", "z_max", "invert", "step", "thickness"}
# What each rule needs on every element it is to place, and its range. Both
# measurements are bounded: a luminance outside 0..1 is not "very bright", and a
# negative layer index is not "the backmost layer", so both are caller errors
# rather than values to clamp.
_RELIEF_MEASUREMENT = {
    "luminance": {"field": "luminance", "low": 0.0, "high": 1.0},
    "layers": {"field": "layer", "low": 0, "high": None},
}
# The defaults. `z_min` 0 and `z_max` 20 is a relief that is clearly three-
# dimensional at a default framing without any of it leaving frame; `step` 4 is
# one visible step between cut layers; `thickness` 1.5 is a slab thin enough that
# the layering reads as layering rather than as a stack of tiles.
DEFAULT_RELIEF = {"z_min": 0.0, "z_max": 20.0, "invert": False,
                  "step": 4.0, "thickness": 1.5}

# Blender is not a service call: a render is CPU work measured in seconds to
# minutes. The cap exists so a wedged process cannot hold a request thread (or
# the CLI) open forever; it is deliberately generous.
_TIMEOUT_SECONDS = 900


class BlenderUnavailable(RuntimeError):
    """The Blender binary is missing, or the render process failed.

    Separate from ``SpecError`` on purpose: a bad spec is the caller's mistake
    (exit 3, HTTP 400) and a missing renderer is this machine's problem (exit 4,
    HTTP 503). Collapsing the two would tell a caller to fix a spec that is fine.
    """


# ---------------------------------------------------------------------------
# Validation: the same element vocabulary as generate, plus the 3D blocks.
# ---------------------------------------------------------------------------


def _check_material(block, where):
    """Validate one element's ``material`` block.

    The rules, and why each exists:

    * the field set is CLOSED. A material is a block this operation reads key by
      key, so a typo inside it (``roughnes``) is a field that would be accepted
      and ignored — the exact failure the shared vocabulary refuses unknown
      fields to prevent, and the reason the allowance is enumerated rather than
      inferred.
    * the 0..1 fields are bounded at BOTH ends. Roughness above 1 is not a
      rougher surface, it is a value outside the shader's range that Blender
      clamps silently, so the render would not match the spec and nothing would
      say so. Negative alpha is the same in the other direction.
    * ``emission`` is a COLOUR and is checked as one, because "emits cyan" is a
      different statement from "emits".

    Absent keys are not an error and not a zero: they resolve to the spec's
    `render.shading` defaults, so a document sets the house style once and an
    element overrides only what it must.
    """
    if not isinstance(block, dict):
        raise SpecError(f"{where}: must be an object")
    unknown = sorted(set(block) - _MATERIAL_FIELDS)
    if unknown:
        raise SpecError(
            f"{where}: unknown field(s) {unknown}. A material takes "
            f"{sorted(_MATERIAL_FIELDS)} — this operation reads these keys by "
            f"name, so a key it does not know is one it would ignore.")
    for field in _MATERIAL_UNIT_FIELDS:
        if field not in block:
            continue
        value = block[field]
        if not is_number(value):
            raise SpecError(f"{where}: '{field}' must be a number")
        if value < 0.0 or value > MAX_ALPHA:
            raise SpecError(
                f"{where}: '{field}' must be a number in 0..1 (got {value}). "
                f"Blender clamps a value outside the shader's range silently, so "
                f"the render would not match the spec and nothing would say so.")
    for field in _MATERIAL_COLOUR_FIELDS:
        if field in block and not isinstance(block[field], str):
            raise SpecError(f"{where}: '{field}' must be a colour string "
                            f"('#rgb' or '#rrggbb')")


def _check_curve_resolution(block, where):
    """Validate `render.curve_resolution`: four integers, each >= 3.

    The lower bound is the number of sides a polygon has — fewer than three
    straight pieces is not a curve — and 0 or 1 would hand Blender nothing to
    tessellate, which it accepts and renders as nothing. The upper bound is not
    a quality opinion but a memory one: a 64-segment circle is a circle, and a
    4-million-segment one is a render that exhausts a box, so a typo that says
    64000 is refused rather than half-finished.
    """
    if not isinstance(block, dict):
        raise SpecError(f"{where}.render.curve_resolution: must be an object")
    unknown = sorted(set(block) - _CURVE_RESOLUTION_FIELDS)
    if unknown:
        raise SpecError(
            f"{where}.render.curve_resolution: unknown field(s) {unknown}. It "
            f"takes {sorted(_CURVE_RESOLUTION_FIELDS)}; a key it does not know "
            f"is one it would ignore.")
    for field, value in sorted(block.items()):
        if isinstance(value, bool) or not isinstance(value, int):
            raise SpecError(f"{where}.render.curve_resolution: '{field}' must be "
                            f"an integer (got {value!r})")
        if value < MIN_CURVE_RESOLUTION:
            raise SpecError(
                f"{where}.render.curve_resolution: '{field}' must be >= "
                f"{MIN_CURVE_RESOLUTION} (a curve approximated by fewer than "
                f"three straight pieces is not a curve, and Blender renders 0 or "
                f"1 as nothing)")
        if value > MAX_CURVE_RESOLUTION:
            raise SpecError(
                f"{where}.render.curve_resolution: '{field}' must be <= "
                f"{MAX_CURVE_RESOLUTION}. Past a few hundred segments the curve "
                f"is already smoother than the frame can show, and the cost is "
                f"in geometry memory rather than in quality.")


def _check_shading(block, where):
    """Validate `render.shading`: three numbers in 0..1.

    Same bounded-at-both-ends rule as the material block and for the same
    reason — a value outside the shader's range is clamped silently, so the
    render stops matching the spec without anything reporting it.
    """
    if not isinstance(block, dict):
        raise SpecError(f"{where}.render.shading: must be an object")
    unknown = sorted(set(block) - _SHADING_FIELDS)
    if unknown:
        raise SpecError(
            f"{where}.render.shading: unknown field(s) {unknown}. It takes "
            f"{sorted(_SHADING_FIELDS)}.")
    for field, value in sorted(block.items()):
        if not is_number(value):
            raise SpecError(f"{where}.render.shading: '{field}' must be a number")
        if value < 0.0 or value > MAX_ALPHA:
            raise SpecError(
                f"{where}.render.shading: '{field}' must be a number in 0..1 "
                f"(got {value}); Blender clamps outside the shader's range "
                f"silently, so the render would not match the spec.")


def _check_measurement(elem, where):
    """Validate an element's relief MEASUREMENT: `luminance` or `layer`.

    Two rules, both about a number the CALLER measured from the image it traced
    — this operation does not read rasters, so it can only check that the number
    is one it can map.

    * `luminance` is 0..1. Outside that it is not "very bright", it is a
      different quantity (a 0..255 channel, a percentage) that would be mapped
      as if it were normalised, so the relief would come out with every contour
      past the top of the range. Refused, because the fix is one number at the
      caller and silently clamping it here would be inventing the caller's
      measurement.
    * `layer` is an integer >= 0 — an ORDINAL, the trace's own stacking order.
      A fractional layer is not "between two layers", it is a value that would
      have to be rounded, and rounding is a decision the caller did not make.

    A measurement is only *required* once the spec states a `relief` rule, and
    that requirement is enforced in `_check_relief`, which is the only place
    that knows which rule is in force. This check is unconditional so a spec
    with no relief block still refuses a malformed number rather than carrying
    it into a render that ignores it.
    """
    if "luminance" in elem:
        value = elem["luminance"]
        if not is_number(value):
            raise SpecError(f"{where}: 'luminance' must be a number in 0..1")
        if value < 0.0 or value > 1.0:
            raise SpecError(
                f"{where}: 'luminance' must be a number in 0..1 (got {value}). It "
                f"is a NORMALISED brightness measured by the caller, and a 0..255 "
                f"channel or a percentage would place every contour past the top "
                f"of the relief range.")
    if "layer" in elem:
        value = elem["layer"]
        if isinstance(value, bool) or not isinstance(value, int):
            raise SpecError(
                f"{where}: 'layer' must be an integer >= 0 (got {value!r}); it is "
                f"an ordinal — which trace layer this contour is — not a "
                f"fractional height")
        if value < 0:
            raise SpecError(f"{where}: 'layer' must be an integer >= 0 (got {value})")


def _check_relief(spec, where):
    """Validate the document `relief` block, and what it requires of elements.

    The block names ONE rule and its parameters, so the whole block is checked
    against a closed field set for the same reason every other block in this
    operation is: a `z_mx` is a relief nobody applied, and it would render
    exactly like the default.

    `rule` is required, and required to be one of the two named rules. An absent
    rule is not "use the default": the two rules disagree about what height
    MEANS (tonal versus ordinal), so a default would be picking a reading of the
    caller's image on their behalf.

    `z_min` above `z_max` is refused rather than swapped. A relief whose range
    runs backwards is a legitimate intaglio, and `invert` is how a caller asks
    for one — so the reversed range is nearly always a sign error, and silently
    swapping it would turn a typo into a render nobody asked for.

    Finally, every element must carry the measurement ITS rule reads. A contour
    with no `luminance` under a luminance relief has exactly one place it can go
    — the floor of the range — and a floor contour looks like a deliberate
    decision rather than a missing measurement, so it is refused by index.
    """
    block = spec.get("relief")
    if block is None:
        # No rule in force. The measurements are still refused if malformed (by
        # `_check_measurement`), but nothing is REQUIRED: a spec that sets
        # `luminance` and no relief has said nothing about height, and its
        # elements keep the z they asked for, which is 0.
        return None
    if not isinstance(block, dict):
        raise SpecError(f"{where}.relief: must be an object")
    unknown = sorted(set(block) - _RELIEF_FIELDS)
    if unknown:
        raise SpecError(
            f"{where}.relief: unknown field(s) {unknown}. It takes "
            f"{sorted(_RELIEF_FIELDS)}; a key it does not know is a relief "
            f"parameter nobody applied.")
    rule = block.get("rule")
    if rule is None:
        raise SpecError(
            f"{where}.relief: 'rule' is required — it is the height rule, and "
            f"there is no default because the two rules "
            f"({', '.join(_RELIEF_RULES)}) disagree about what height means: one "
            f"is tonal, the other ordinal.")
    if rule not in _RELIEF_RULES:
        raise SpecError(f"{where}.relief: 'rule' must be one of "
                        f"{', '.join(_RELIEF_RULES)} (got {rule!r})")
    for field in ("z_min", "z_max", "step", "thickness"):
        if field in block and not is_number(block[field]):
            raise SpecError(f"{where}.relief: '{field}' must be a number")
    if "invert" in block and not isinstance(block["invert"], bool):
        raise SpecError(f"{where}.relief: 'invert' must be true or false")
    if block.get("thickness", 1) < 0:
        raise SpecError(f"{where}.relief: 'thickness' must be a number >= 0")
    z_min = block.get("z_min", DEFAULT_RELIEF["z_min"])
    z_max = block.get("z_max", DEFAULT_RELIEF["z_max"])
    if z_min > z_max:
        raise SpecError(
            f"{where}.relief: 'z_min' ({z_min}) must be <= 'z_max' ({z_max}). A "
            f"reversed range is a typo rather than an intaglio — set "
            f"'invert': true to lift the darker regions instead.")

    field = _RELIEF_MEASUREMENT[rule]["field"]
    for i, elem in enumerate(spec.get("elements") or []):
        # An element that states its own `z` is placing itself and does not need
        # the measurement. That is the escape hatch for a plate or a backdrop in
        # a relief document, and it is why this is a per-element check rather
        # than a document-level one.
        if isinstance(elem, dict) and elem.get("z") is not None:
            continue
        if not isinstance(elem, dict) or field not in elem:
            raise SpecError(
                f"{where}.elements[{i}]: the '{rule}' relief rule reads "
                f"'{field}', and this element has none. Every element a relief "
                f"places needs its measurement — an element with no "
                f"'{field}' would sit at the floor of the range and look like a "
                f"decision. Give it a '{field}', or give it an explicit 'z' to "
                f"place it yourself.")
    return block


def _check_path_data(d, where):
    """Refuse a path the in-Blender builder cannot draw.

    Two things, both caller errors rather than renderer failures: a command the
    builder has no 3D reading for (an arc, most often — a wrong solid is worse
    than a named error), and data that is not a contour at all (a single point
    has nothing to extrude or to run a tube along). The second would otherwise
    reach Blender and come back as "the renderer failed", telling a caller to
    check the machine over a spec nobody can draw.
    """
    unsupported = sorted({c for c in _PATH_LETTERS.findall(d) if c not in _PATH_COMMANDS})
    if unsupported:
        raise SpecError(
            f"{where}: path command(s) {unsupported} are not supported by the blender "
            f"operation (M L H V Z C S Q T, either case; arcs are not drawn in 3D)"
        )
    if len(_PATH_NUMBERS.findall(d)) < 4:
        raise SpecError(f"{where}: path data 'd' needs at least two points to render in 3D")


def is_primitive(elem):
    """Whether an element is one of the 3D solids this operation adds.

    A question worth its own name because the answer changes several rules at
    once: a primitive is built as a MESH rather than an extruded curve, it is
    never a stroke, and its colours are read from ``fill`` alone.
    """
    return elem.get("type") in _PRIMITIVE_FIELDS


def primitive_segments(elem):
    """One primitive's resolution: its own ``segments``, or the default.

    The resolution rule, in one place: a curved solid is approximated by
    ``segments`` straight pieces around its loop, and a torus by
    ``tube_segments`` around its tube. A caller who wants a hero sphere smooth
    at a close-up says so here, and a caller who wants cheap background
    geometry says so too — the default sits between, which is why the same
    document can carry both.
    """
    segments = elem.get("segments")
    tube = elem.get("tube_segments")
    return {
        "segments": DEFAULT_SEGMENTS if segments is None else int(segments),
        "tube_segments": DEFAULT_TUBE_SEGMENTS if tube is None else int(tube),
    }


def _check_primitive(elem, where):
    """Validate one 3D primitive: its transform, its resolution, its colour.

    Refusals name the field, like every other check in this module. The rules
    that are more than shape:

    - a radius or extent must be POSITIVE, because a zero-radius sphere is not a
      smaller sphere, it is a degenerate mesh that renders as nothing; and
    - ``depth`` is checked with the contour's own rule (a number >= 0) rather
      than the positive one, because ``depth: 0`` is a legitimate flat
      primitive — a coin, a tile — and absent still means the spec's
      ``extrude.depth`` rather than zero.

    The unknown-field check is the one this function existed to be missing, and
    it is not optional. A primitive short-circuits the shared element check, so
    without this it is the ONE element in the vocabulary that silently accepts
    any field at all: ``stroke`` on a sphere would be accepted, ignored, and
    draw an outline the caller was never told would not appear. A field this
    operation reads but does not act on is the same lie as a ``depth`` on a flat
    SVG spec, and the shared vocabulary refuses unknown fields for exactly that
    reason. So the allowance is stated as a CLOSED SET and everything outside it
    is a named error.
    """
    etype = elem["type"]
    allowed = _PRIMITIVE_FIELDS[etype] | {"type"}
    unknown = sorted(set(elem) - allowed)
    if unknown:
        raise SpecError(
            f"{where}: unknown field(s) {unknown} on {etype}. A 3D primitive is "
            f"a solid with no outline, so it takes {sorted(allowed - {'type'})} "
            f"and nothing else — a field it would ignore is a field the caller "
            f"was never told about.")
    for field in _PRIMITIVE_REQUIRED[etype]:
        _require_field(elem, field, where)
    for field in _PRIMITIVE_NUMERIC[etype]:
        if field in elem and not is_number(elem[field]):
            raise SpecError(f"{where}: '{field}' must be a number")
    for field in _PRIMITIVE_POSITIVE[etype]:
        value = elem.get(field)
        if value is not None and value <= 0:
            raise SpecError(f"{where}: '{field}' must be a number > 0 "
                            f"({etype} has no shape at {field}=0)")
    # The contour's rule, applied to the field the contour also has. Checked
    # HERE rather than inherited: a negative half-thickness is a mesh built
    # inside out, and bpy accepts it silently, so the render would come out
    # inside-out and the report would show nothing wrong with it.
    if elem.get("depth") is not None and elem["depth"] < 0:
        raise SpecError(f"{where}: 'depth' must be a number >= 0 (it is the HALF "
                        f"extent along z, like every other solid's)")
    # `material` is in every primitive's allowed set, so without this check a
    # sphere would be the one element that accepts a material block and then
    # reads it key by key with no validation: `roughnes: 0.2` on a primitive
    # rendered matte, which is the same silent-ignore the unknown-field check
    # above exists to prevent, one level down. Checked with the contour's own
    # `_check_material`, so a block means the same thing on both sides.
    if "material" in elem:
        _check_material(elem["material"], f"{where}.material")
    _check_measurement(elem, where)

    for field in _PRIMITIVE_SEGMENT_FIELDS:
        if field not in elem:
            continue
        value = elem[field]
        if isinstance(value, bool) or not isinstance(value, int) or value < 3:
            raise SpecError(f"{where}: '{field}' must be an integer >= 3 (a curve "
                            f"approximated by fewer than three straight pieces is "
                            f"not a curve)")


def _require_field(elem, field, where):
    """The shared `_require`, repeated here so this module stands on its own."""
    if field not in elem or elem[field] is None:
        raise SpecError(f"{where}: missing required field '{field}'")


def _check_element(elem, where):
    """The shared element vocabulary, the 3D primitives, and what 3D adds.

    A polygon or polyline with one point is a legal SVG element that draws
    nothing; in 3D it is a spec with nothing to render, so it is refused here
    rather than after a Blender process has been started for it.

    ``z`` and ``depth`` are the other direction: legitimate in 3D, meaningless in
    the flat SVG ``generate`` shares this element vocabulary with. So they are
    validated HERE and WITHHELD from the shared check, which refuses any field it
    does not know. Teaching the shared vocabulary a ``depth`` would make
    ``generate`` accept a field it silently ignores, and a field SVG refuses is
    honest where one it ignores is not.

    A primitive short-circuits the shared check entirely: these types do not
    exist in the flat vocabulary, so there is no shared rule to defer to and
    running them through it would refuse the type by name.
    """
    if not isinstance(elem, dict):
        raise SpecError(f"{where}: element must be an object")
    if is_primitive(elem):
        _check_primitive(elem, where)
        return

    # `text` is in the shared (flat) vocabulary but has no 3D reading. It is
    # refused HERE, by name, rather than left to the in-Blender builder: a
    # spec this operation cannot draw must be a 400 naming the type, not a
    # 503 'renderer failed' that sends the caller to check the machine.
    # Likewise the flat-only `marker` and `stroke_dasharray`: a stroke tube
    # has no arrowhead and no dash pattern, so accepting them would draw a
    # plain solid tube and say nothing — the same lie as a `depth` on a flat
    # spec, in the other direction. (`z`, `depth`, `material`, `luminance`
    # and `layer` are the 3D-only fields; they are stripped below instead,
    # because this operation VALIDATES them rather than ignoring them.)
    etype = elem.get("type")
    if etype == "text":
        raise SpecError(
            f"{where}: 'text' is a flat-only element — it draws a label, and "
            f"the blender operation builds solids and stroke tubes, so there "
            f"is nothing here to render it with")
    flat_only = {"marker", "stroke_dasharray"} & set(elem)
    if flat_only:
        raise SpecError(
            f"{where}: field(s) {sorted(flat_only)} are flat-only — a solid "
            f"or a stroke tube has no arrowhead and no dash pattern, so they "
            f"would be accepted and silently ignored")

    # `z` and `depth` are numbers; `material` is a block and has its own check.
    # Both are in _ELEMENT_3D_FIELDS because both are 3D-only and must be
    # STRIPPED before the shared check sees them — which is also why the loop
    # below cannot just run over that tuple.
    for field in ("z", "depth"):
        if field in elem and not is_number(elem[field]):
            raise SpecError(f"{where}: '{field}' must be a number")
    if elem.get("depth") is not None and elem["depth"] < 0:
        raise SpecError(f"{where}: 'depth' must be a number >= 0")
    if "material" in elem:
        _check_material(elem["material"], f"{where}.material")
    _check_measurement(elem, where)

    shared = {key: value for key, value in elem.items()
              if key not in _ELEMENT_3D_FIELDS}
    check_element(shared, where)
    if elem["type"] == "path":
        _check_path_data(elem["d"], where)
    if elem["type"] in ("polygon", "polyline") and len(elem["points"]) < 2:
        raise SpecError(f"{where}: 'points' needs at least two points to render in 3D")


def element_depth(elem, extrude):
    """The extrusion one element gets: its own ``depth``, or the spec's.

    Per-element depth is what makes a bar chart a bar chart — every bar is a
    ``rect`` that differs only in how far it rises — and it is the same rule for
    a tiled element, which is why it lives on the element rather than on the
    tiling block. A stroke tube does not extrude, so this means nothing to one;
    ``is_stroke`` is the caller's question, not this one's.

    MEASURED, Blender 4.3, and not what this codebase used to say: Blender's 2D
    curve ``extrude`` grows BOTH ways from the element's plane, so the value here
    is HALF the resulting thickness — ``depth: 1`` spans z - 1 to z + 1, two
    units thick, and ``depth: 0.25`` spans ±0.25. The old comment claimed the
    extrusion went along "+z", which is false. It matters the moment anyone
    composes solids, because a bar meant to stand ON a plate rather than through
    it has to be placed at the plate's top plus its own half-thickness.
    """
    value = elem.get("depth")
    return extrude["depth"] if value is None else float(value)


def element_z(elem):
    """An element's plane height. ``z`` is absent = on the sketch plane.

    The plane, not the bottom: the solid spans ``z ± depth`` about it (see
    ``element_depth``).
    """
    value = elem.get("z")
    return 0.0 if value is None else float(value)


def _check_extrude(spec, where):
    extrude = spec.get("extrude")
    if extrude is None:
        return
    if not isinstance(extrude, dict):
        raise SpecError(f"{where}: 'extrude' must be an object")
    unknown = sorted(set(extrude) - _EXTRUDE_FIELDS)
    if unknown:
        raise SpecError(f"{where}.extrude: unknown field(s) {unknown}")
    for key in ("depth", "bevel_depth"):
        value = extrude.get(key)
        if value is not None and (not is_number(value) or value < 0):
            raise SpecError(f"{where}.extrude: '{key}' must be a number >= 0")
    resolution = extrude.get("bevel_resolution")
    if resolution is not None and (
        isinstance(resolution, bool) or not isinstance(resolution, int) or resolution < 0
    ):
        raise SpecError(f"{where}.extrude: 'bevel_resolution' must be an integer >= 0")


# `render.background` takes a CSS hex colour OR this sentinel, and nothing
# else. The sentinel is named here rather than compared inline because both
# halves read it: `_check_render` validates it, the in-Blender script acts on
# it, and a value neither recognises used to be passed straight through to
# `_colour` -- which falls back silently -- so `"transparnet"` rendered the
# default background and said nothing. A silent no-op is the failure mode this
# repo keeps writing tests against.
BACKGROUND_TRANSPARENT = "transparent"

# Mirrors `blender/bpy_geometry.py`'s `HEX_COLOUR`. It cannot be imported: that
# module starts with `import bpy` and only exists inside Blender, exactly like
# `is_stroke`, which is the acknowledged cost of a driver that validates what a
# script elsewhere consumes. Keep the two in step.
_HEX_COLOUR = __import__("re").compile(r"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")


def _check_render(spec, where):
    render = spec.get("render")
    if render is None:
        return
    if not isinstance(render, dict):
        raise SpecError(f"{where}: 'render' must be an object")
    unknown = sorted(set(render) - _RENDER_FIELDS)
    if unknown:
        raise SpecError(f"{where}.render: unknown field(s) {unknown}")

    size = render.get("size")
    if size is not None:
        if not isinstance(size, dict):
            raise SpecError(f"{where}.render: 'size' must be an object")
        unknown = sorted(set(size) - _SIZE_FIELDS)
        if unknown:
            raise SpecError(f"{where}.render.size: unknown field(s) {unknown}")
        for key in _SIZE_FIELDS:
            if key in size and (not is_number(size[key]) or size[key] <= 0):
                raise SpecError(f"{where}.render.size: '{key}' must be a positive number")

    views = render.get("views")
    if views is not None and (
        isinstance(views, bool) or not isinstance(views, int) or views < 1
    ):
        raise SpecError(f"{where}.render: 'views' must be an integer >= 1")

    background = render.get("background")
    if background is not None:
        if not isinstance(background, str):
            raise SpecError(f"{where}.render: 'background' must be a colour string")
        # Closed on purpose: an unrecognised value used to reach `_colour`,
        # which substitutes the default WITHOUT saying so, so a typo rendered
        # the default background and reported success. Both accepted forms are
        # named in the message because an error the operator can act on is the
        # whole point of refusing.
        if not (_HEX_COLOUR.match(background.strip())
                or background.strip().lower() == BACKGROUND_TRANSPARENT):
            raise SpecError(
                f"{where}.render: 'background' must be a hex colour like "
                f"'#1a1a24' or '{BACKGROUND_TRANSPARENT}' (got {background!r}); "
                f"anything else would silently render the default background")

    # The two 3D fidelity sub-blocks (chopshop-bp#2). Validated here, at the
    # same place and with the same closed-set rule as every other block in
    # `render`, so a typo inside either is a named error rather than a sampling
    # rate nobody changed.
    if render.get("curve_resolution") is not None:
        _check_curve_resolution(render["curve_resolution"], where)
    if render.get("shading") is not None:
        _check_shading(render["shading"], where)

    engine = render.get("engine")
    if engine is not None and engine not in ENGINES:
        raise SpecError(f"{where}.render: 'engine' must be one of {', '.join(ENGINES)}")

    # The camera. Elevation is degrees above the horizon (90 looks straight
    # down), azimuth is where the sweep STARTS — `views` still steps evenly
    # around from it — and both are unconstrained in range because an angle
    # outside 0..360 is the same angle, not a mistake worth refusing.
    for key in ("elevation", "azimuth"):
        value = render.get(key)
        if value is not None and not is_number(value):
            raise SpecError(f"{where}.render: '{key}' must be a number of degrees")

    projection = render.get("projection")
    if projection is not None and projection not in PROJECTIONS:
        raise SpecError(f"{where}.render: 'projection' must be one of "
                        f"{', '.join(PROJECTIONS)}")

    # Only a perspective camera has a lens. It is accepted whatever the
    # projection so a spec can carry the pair, but a value on an ortho render
    # changes nothing — which the contract says, rather than this refusing it.
    lens = render.get("lens")
    if lens is not None and (not is_number(lens) or lens <= 0):
        raise SpecError(f"{where}.render: 'lens' must be a positive number of "
                        f"millimetres")


def _check_export(spec, where):
    export = spec.get("export")
    if export is None:
        return
    if not isinstance(export, dict):
        raise SpecError(f"{where}: 'export' must be an object")
    unknown = sorted(set(export) - _EXPORT_FIELDS)
    if unknown:
        raise SpecError(f"{where}.export: unknown field(s) {unknown}")
    glb = export.get("glb")
    if glb is not None and not isinstance(glb, bool):
        raise SpecError(f"{where}.export: 'glb' must be true or false")


def validate_blender(spec):
    """Validate a blender spec, returning the canonical spec dict (or raising).

    Elements are the ``generate`` vocabulary checked by the same code, plus the
    3D primitives this operation adds (a mesh solid has no 2D reading, so there
    is no shared rule for them and they are checked here), and ``tiling`` is the
    same block: a spec that draws in SVG must mean the same thing when it is
    extruded. A spec with nothing to draw is a caller error — a render of
    nothing is not a render — and a typo'd field inside ``extrude``, ``render``
    or ``export`` is refused rather than silently taking its default.
    """
    if not isinstance(spec, dict):
        raise SpecError("spec must be an object")
    where = "blender spec"

    title = spec.get("title")
    if title is not None and not isinstance(title, str):
        raise SpecError(f"{where}: 'title' must be a string")

    elements = spec.get("elements")
    if elements is None:
        raise SpecError(f"{where}: missing required field 'elements'")
    if not isinstance(elements, list):
        raise SpecError(f"{where}: 'elements' must be a list")

    tiling = spec.get("tiling")
    if tiling is not None:
        check_tiling(tiling, f"{where}.tiling")
        _check_element(tiling["element"], f"{where}.tiling.element")

    if not elements and tiling is None:
        raise SpecError(f"{where}: nothing to render — 'elements' is empty and "
                        f"there is no 'tiling'")

    for i, elem in enumerate(elements):
        _check_element(elem, f"{where}.elements[{i}]")

    _check_extrude(spec, where)
    _check_relief(spec, where)
    _check_render(spec, where)
    _check_export(spec, where)
    return spec


# ---------------------------------------------------------------------------
# The resolved blocks: defaults applied once, so the driver, the naming and the
# in-Blender script all read the same numbers.
# ---------------------------------------------------------------------------


def resolve_extrude(spec):
    extrude = spec.get("extrude") or {}
    return {
        "depth": extrude.get("depth", DEFAULT_DEPTH),
        "bevel_depth": extrude.get("bevel_depth", DEFAULT_BEVEL_DEPTH),
        "bevel_resolution": extrude.get("bevel_resolution", DEFAULT_BEVEL_RESOLUTION),
    }


def resolve_render(spec):
    render = spec.get("render") or {}
    size = render.get("size") or {}
    width, height = DEFAULT_RENDER_SIZE
    return {
        "size": {
            "width": size.get("width", width),
            "height": size.get("height", height),
        },
        "views": render.get("views", DEFAULT_VIEWS),
        "background": render.get("background", DEFAULT_BACKGROUND),
        "engine": render.get("engine", DEFAULT_ENGINE),
        # Resolved here, once, so the driver, the naming and the in-Blender
        # script all read the same camera — the same rule the other blocks keep.
        "elevation": render.get("elevation", DEFAULT_ELEVATION),
        "azimuth": render.get("azimuth", DEFAULT_AZIMUTH),
        "projection": render.get("projection", DEFAULT_PROJECTION),
        "lens": render.get("lens", DEFAULT_LENS),
        # The two fidelity blocks, resolved with their defaults here rather
        # than in the in-Blender script, so the driver, the contract and the
        # builder all read the same numbers — the same rule every other block
        # keeps. A COPIED dict, not a reference to the module constant: the
        # in-Blender script receives this through JSON and could not reach the
        # constant anyway, and a shared mutable default is one edit away from
        # being changed by a render.
        "curve_resolution": dict(DEFAULT_CURVE_RESOLUTION,
                                 **(render.get("curve_resolution") or {})),
        "shading": dict(DEFAULT_SHADING, **(render.get("shading") or {})),
    }


def resolve_relief(spec):
    """The document's relief rule, resolved with its defaults; None if absent.

    A COPY, not the module constant, for the reason every other resolved block
    is a copy: a shared mutable default is one edit away from being changed by a
    render, and the second render in a process would then differ from the first
    for a reason no spec stated.

    The `rule` key is what tells a caller whether a relief is in force at all,
    so it is kept even though it is not a parameter — ``None`` (no block) and a
    block with no rule (refused) are different states and must not look alike.
    """
    block = spec.get("relief")
    if not isinstance(block, dict):
        return None
    resolved = dict(DEFAULT_RELIEF)
    resolved.update(block)
    return resolved


def relief_height(elem, relief):
    """The height ONE element's measurement puts it at, in z.

    The whole of the depth rule, and deliberately the whole of it: two rules,
    each a couple of lines of arithmetic over a number the caller measured. This
    is the "stated as data rather than buried in a script" half of chopshop-bp#3
    — the rule is a name the spec carries, and this is the one place its meaning
    is written down, so a caller implementing the same rule in another language
    has exactly these lines to match.

    `luminance` maps 0..1 LINEARLY onto ``z_min``..``z_max``: 0 is the floor of
    the range and 1 the ceiling, both inclusive, so the extremes of the
    measurement land on the stated ends rather than short of them. `invert`
    reflects the range about its own midpoint (`z_min + z_max - z`), which keeps
    both ends where the caller put them — a reflected relief is bounded by the
    same numbers, not by an accidental range.

    `layers` is ordinal: ``z_min + layer * step``. No ceiling is applied, because
    capping it would flatten the top layers into one plane and destroy the very
    stacking the rule exists to produce; a caller who wants a ceiling sets
    `z_max` to the height they want and picks a `step` that fits under it.

    An element with its own `z` keeps it. The rule fills in heights, it does not
    overrule a height the caller stated directly — which is what makes an
    explicit `z` the documented escape hatch for a plate or a backdrop.
    """
    if elem.get("z") is not None:
        return float(elem["z"])
    z_min = relief["z_min"]
    if relief["rule"] == "layers":
        return z_min + float(elem["layer"]) * relief["step"]
    value = float(elem["luminance"])
    height = z_min + value * (relief["z_max"] - z_min)
    if relief["invert"]:
        height = z_min + relief["z_max"] - height
    return height


def relief_depth(elem, relief):
    """The half-thickness a relief element gets; its own `depth` if it has one.

    `thickness` is the relief's slab: with `depth` unset, every contour the rule
    places would take `extrude.depth`, which a caller writing a relief has
    usually left at whatever the flat work uses. A relief whose layers are 0.2
    thick and 4 apart is four floating discs rather than a relief, so the relief
    states its own thickness and an element's explicit `depth` still wins.
    """
    if elem.get("depth") is not None:
        return float(elem["depth"])
    return relief["thickness"]


def apply_relief(spec):
    """A copy of the spec with the relief rule RESOLVED into `z` and `depth`.

    The relief is applied HERE, in the driver, rather than inside Blender, and
    that placement is the design decision rather than an accident. Everything
    else in this operation that Blender needs is either geometry or a resolved
    block the two sides read from the same JSON — but a height RULE is neither:
    if it lived in `blender/bpy_geometry.py` it would be a second implementation
    of the same arithmetic in a file that cannot import this module, and the two
    would drift exactly the way the mirrored defaults here have to be tested
    against. Resolving it in the driver means the rule is written ONCE, in the
    file that also validates it, and the spec that reaches Blender carries plain
    `z` and `depth` like any other — so the builder needs no relief code at all
    and a probe measures the same heights the render draws.

    Returns the spec UNCHANGED (the same object) when there is no relief block,
    so a document that does not use the rule takes a byte-identical path and the
    frame stem — a hash of the spec — does not move.

    The copy is shallow-per-element and does not mutate the caller's spec: a
    caller that re-renders the same dict must get the same frames, and a rule
    that consumed its own input could not promise that twice.
    """
    relief = resolve_relief(spec)
    if relief is None:
        return spec
    elements = []
    for elem in spec.get("elements") or []:
        placed = dict(elem)
        placed["z"] = relief_height(elem, relief)
        placed["depth"] = relief_depth(elem, relief)
        elements.append(placed)
    resolved = dict(spec)
    resolved["elements"] = elements
    return resolved


def resolve_material(elem, shading):
    """One element's effective material, as the builder reads it.

    The element's own `material` block wins over the document's `render.shading`
    for the keys it sets, and the document's for the keys it does not — a
    house style declared once, overridden per object. Absent on both sides means
    the DEFAULT_SHADING value, so a spec that says nothing is a matte surface,
    which is what the flat work this repo draws has always rendered as.
    """
    block = dict(shading or DEFAULT_SHADING)
    own = elem.get("material")
    if isinstance(own, dict):
        block.update(own)
    return block


def resolve_export(spec):
    export = spec.get("export") or {}
    return {"glb": bool(export.get("glb", False))}


def is_stroke(elem):
    """Whether an element renders as a stroke-tube rather than a filled solid.

    ``line`` and ``polyline`` are open by definition. A ``path`` is a solid when
    its data closes the contour (``Z``) and which carries a ``fill``; anything
    else is a stroke, which is the only reading of "filled-closed path" that
    keeps an unfilled outline an outline. Everything else (``rect``, ``circle``,
    ``ellipse``, ``polygon``) is a closed contour whatever its fill says, and so
    is every 3D primitive — a mesh solid has no tube reading, so the question
    does not arise rather than being answered no.
    """
    if is_primitive(elem):
        return False
    etype = elem["type"]
    if etype in CLOSED_TYPES:
        return False
    if etype == "path":
        fill = elem.get("fill")
        filled = isinstance(fill, str) and fill.strip().lower() not in ("", "none")
        return not (filled and re.search(r"[Zz]", elem["d"]))
    return True


def tube_radius(elem):
    """The stroke tube's radius: ``stroke_width``, or the contract's default.

    The in-Blender script applies the same rule (it cannot import this module),
    and the default is stated once here so the contract, the doc and the
    renderer agree on the number.
    """
    stroke_width = elem.get("stroke_width")
    return DEFAULT_TUBE_RADIUS if stroke_width is None else float(stroke_width)


def output_stem(spec):
    """The frame stem: the title as a slug, plus a short hash of the spec.

    Deterministic, and unique per spec: the same document always writes the same
    names (so a rerun overwrites rather than accumulates), and two different
    documents never collide in one output directory. Read the title for a human,
    the hash for identity.

    ``blender/bpy_geometry.py`` MIRRORS this rule — it runs inside Blender and
    cannot import this module — and the real-render smoke test is the guard that
    the two agree: it reads the files back by the names this function returns.
    """
    canonical = json.dumps(spec, sort_keys=True, separators=(",", ":"), default=str)
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:8]
    title = spec.get("title")
    slug = re.sub(r"[^a-z0-9]+", "-", title.strip().lower()).strip("-")[:40] if isinstance(
        title, str
    ) else ""
    return f"{slug}-{digest}" if slug else f"render-{digest}"


def output_names(spec):
    """Every file a valid spec writes: the frames in view order, then the GLB.

    The names the operation promises, computed from the spec alone, so a caller
    can name the artifacts before the render and the answer is not a guess.
    """
    stem = output_stem(spec)
    views = resolve_render(spec)["views"]
    names = [f"{stem}_{index:03d}.png" for index in range(views)]
    if resolve_export(spec)["glb"]:
        names.append(f"{stem}.glb")
    return names


def manifest(names):
    """The operation's answer shape: ``frames`` in view order, and ``glb``.

    One place defines it, because the service, the CLI and a caller reading the
    contract all describe the same result.
    """
    frames = [name for name in names if name.endswith(".png")]
    glb = next((name for name in names if name.endswith(".glb")), None)
    return {"frames": frames, "glb": glb}


# ---------------------------------------------------------------------------
# The render: a subprocess, and the files it wrote.
# ---------------------------------------------------------------------------


def _as_spec(spec):
    if isinstance(spec, str):
        try:
            spec = json.loads(spec)
        except json.JSONDecodeError as exc:
            raise SpecError(f"blender: spec is not valid JSON: {exc}") from exc
    return spec


def render_blender(spec, out_dir):
    """Render a blender spec into ``out_dir``; return the output file names.

    ``spec`` may be a dict or a JSON string (the CLI and the service hand over
    what they received). Raises ``SpecError`` for an invalid spec and
    ``BlenderUnavailable`` when the binary is missing or the process fails — never
    silently returns an empty list in either case.
    """
    spec = _as_spec(spec)
    validate_blender(spec)
    # The relief rule is resolved into plain `z`/`depth` before the spec is
    # written, so Blender builds the heights the rule says without knowing the
    # rule exists (see `apply_relief`).
    build_spec = apply_relief(spec)

    binary = config.blender_binary()
    if shutil.which(binary) is None:
        raise BlenderUnavailable(
            f"blender binary {binary!r} not found on PATH: the blender operation needs "
            f"Blender installed (set {config.BLENDER_BINARY_ENV} to its path)"
        )

    os.makedirs(out_dir, exist_ok=True)
    # The names are computed from the RESOLVED spec, because the stem is a hash
    # of the document and `blender/bpy_geometry.py` — which writes the frames —
    # only ever sees the resolved one. Naming them from the caller's spec
    # instead returns a name no file has, which is how a relief render reported
    # success and wrote nothing anybody could find. A document with no relief
    # block resolves to ITSELF (`apply_relief` returns the same object), so this
    # is byte-identical for every existing render and the frame stem does not
    # move.
    names = output_names(build_spec)

    # The spec travels as a file, not as stdout: a Blender invocation is
    # `--python script` with the arguments after `--`, and a JSON document on
    # stdin is invisible to the script. The temp directory is this process's, and
    # goes away with it.
    with tempfile.TemporaryDirectory(prefix="chopshop-blender-") as scratch:
        spec_path = os.path.join(scratch, "spec.json")
        with open(spec_path, "w", encoding="utf-8") as handle:
            json.dump(build_spec, handle, indent=2, sort_keys=True)
        command = [binary, "--background", "--python", BPY_SCRIPT, "--", spec_path, out_dir]
        try:
            proc = subprocess.run(
                command, capture_output=True, text=True, timeout=_TIMEOUT_SECONDS
            )
        except subprocess.TimeoutExpired as exc:
            raise BlenderUnavailable(
                f"blender ({binary}) did not finish within {_TIMEOUT_SECONDS}s"
            ) from exc
        except OSError as exc:
            raise BlenderUnavailable(f"blender ({binary}) could not be run: {exc}") from exc

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()[-6:]
        raise BlenderUnavailable(
            "blender (%s) exited %d%s"
            % (binary, proc.returncode, (": " + " | ".join(detail)) if detail else "")
        )
    return names


def blender(spec, out_dir=None):
    """The operation itself: a blender spec -> the files it rendered.

    ``out_dir`` defaults to the configured output directory, read at call time
    (config.py's rule), so the CLI and the service cannot disagree about where a
    render lands. The method that carries the operation's NAME is
    ``PlotEngine.blender`` in server.py, which is what HTTP routes to.
    """
    return render_blender(spec, config.blender_out_dir() if out_dir is None else out_dir)
