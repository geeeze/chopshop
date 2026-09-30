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

# Fields an element may carry in 3D and nowhere else. They are NOT part of the
# shared element vocabulary (spec.py): `generate` draws SVG, which is flat, so a
# `depth` there would be a field accepted and silently ignored. They are checked
# in ``_check_element`` and withheld from the shared check instead.
_ELEMENT_3D_FIELDS = ("z", "depth")

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
    "box": {"x", "y", "width", "height", "depth", "z", "fill"},
    # The curved solids. `segments` (and the torus's `tube_segments`) is the
    # resolution rule: how many straight pieces approximate the curve. It is
    # per element, so one document can carry a smooth hero sphere and a faceted
    # background one.
    "sphere": {"cx", "cy", "r", "depth", "z", "fill", "segments"},
    "cylinder": {"cx", "cy", "r", "depth", "z", "fill", "segments"},
    "cone": {"cx", "cy", "r", "depth", "z", "fill", "segments"},
    # A torus is a ring, so it has two radii: `r` is the distance from the
    # centre to the middle of the tube, `tube` is the tube's own radius.
    "torus": {"cx", "cy", "r", "tube", "depth", "z", "fill", "segments",
              "tube_segments"},
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
                  "elevation", "azimuth", "projection", "lens"}
_SIZE_FIELDS = {"width", "height"}
_EXPORT_FIELDS = {"glb"}

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

    for field in _ELEMENT_3D_FIELDS:
        if field in elem and not is_number(elem[field]):
            raise SpecError(f"{where}: '{field}' must be a number")
    if elem.get("depth") is not None and elem["depth"] < 0:
        raise SpecError(f"{where}: 'depth' must be a number >= 0")

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
    if background is not None and not isinstance(background, str):
        raise SpecError(f"{where}.render: 'background' must be a colour string")

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
    }


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

    binary = config.blender_binary()
    if shutil.which(binary) is None:
        raise BlenderUnavailable(
            f"blender binary {binary!r} not found on PATH: the blender operation needs "
            f"Blender installed (set {config.BLENDER_BINARY_ENV} to its path)"
        )

    os.makedirs(out_dir, exist_ok=True)
    names = output_names(spec)

    # The spec travels as a file, not as stdout: a Blender invocation is
    # `--python script` with the arguments after `--`, and a JSON document on
    # stdin is invisible to the script. The temp directory is this process's, and
    # goes away with it.
    with tempfile.TemporaryDirectory(prefix="chopshop-blender-") as scratch:
        spec_path = os.path.join(scratch, "spec.json")
        with open(spec_path, "w", encoding="utf-8") as handle:
            json.dump(spec, handle, indent=2, sort_keys=True)
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
