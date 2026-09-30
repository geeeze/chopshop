# blend-plot: one service, two halves - `plot` draws documents, `blender` renders 3D.
"""Build and render a chopshop-bp ``blender`` spec, INSIDE Blender.

Standalone by rule: this file runs under ``blender --background --python``, not
in the package, so it imports ``bpy`` and the standard library only (json, math,
os, re, sys, hashlib) and cannot import ``chopshop_plot``. It is invoked as:

    blender --background --python <repo>/blender/bpy_geometry.py -- SPEC.json OUT_DIR

The two positional arguments after ``--`` are the spec JSON path and the output
directory. Frames are written as ``<stem>_NNN.png`` and, when ``export.glb`` is
true, ``<stem>.glb``.

Two rules this file does NOT own:

- **Validation.** ``validate_blender`` in ``chopshop_plot/blender.py`` already
  refused a bad spec before this process was started, so a malformed document
  never reaches Blender. This builder reads the spec assuming it is valid.
- **The stem.** ``_output_stem`` MIRRORS ``chopshop_plot/blender.py``'s
  ``output_stem`` (a slug of ``title`` plus a short hash of the spec) because the
  driver names the files the operation will return before the render runs. The
  real-render smoke test is the guard that the two agree: it reads the frames
  back by the names the driver returned.

What this file does enforce is that a render either produced its files or failed
loudly: every frame and the GLB is checked on disk before the process reports
success, and any error exits non-zero (``_fail``), so the driver can never read a
zero exit as "nothing to collect".
"""

import bpy
import hashlib
import json
import math
import os
import re
import sys

# Mirrors chopshop_plot/blender.py: the contract's defaults.
DEPTH_DEFAULT = 0.5
BEVEL_DEPTH_DEFAULT = 0.02
BEVEL_RESOLUTION_DEFAULT = 2
VIEWS_DEFAULT = 1
BACKGROUND_DEFAULT = "#1a1a24"
ENGINE_DEFAULT = "workbench"
SIZE_DEFAULT = (1024, 1024)
TUBE_RADIUS_DEFAULT = 0.02

# Geometry sampling. POLY splines are the whole vocabulary here (straight
# segments, sampled curves): deterministic, and a curve is a control net in
# Blender only if you ask it to be, which a render does not need.
# Mirrors DEFAULT_CURVE_RESOLUTION in chopshop_plot/blender.py. Kept as four
# names rather than a dict because the sampling functions read them as module
# globals, and as a dict they would be threaded through four call sites and a
# signature change for no gain. `resolve_resolution` rebinds them from the spec
# before any geometry is built, which is why they are not constants in the
# mathematical sense.
CIRCLE_STEPS = 64
CORNER_STEPS = 8
CURVE_STEPS = 16
SPLINE_RESOLUTION_U = 12

# The shading defaults, mirrored from DEFAULT_SHADING for the same reason: this
# file runs inside Blender and cannot import the package. Every one of these is
# read by EEVEE and IGNORED by Workbench, which is why they cost nothing on the
# default engine.
SHADING_DEFAULTS = {"roughness": 1.0, "metallic": 0.0, "specular": 0.0}

# How hard an emissive surface emits. A CONSTANT rather than a spec field on
# purpose, and the reasoning is worth keeping: the issue's list of material
# properties is roughness, metallic, emission, alpha, and "emission" there means
# the COLOUR a surface emits. Exposing strength as well would be a sixth knob
# whose only honest description is "how much brighter than the light is this",
# and a caller who wants a dim glow can dim the colour. 1.0 means the surface
# shows its emission colour at full value, which is the reading that makes
# `emission: "#e08030"` mean what it says.
#
# MEASURED, and 1.0 rather than something lower. An earlier version of this
# file used 0.4, on the reasoning that "anything summing past 1.0 clips to
# white, so the emission's hue is gone — an orange emitter and a green one both
# come out white". That reasoning is WRONG, and the real render is what showed
# it: the scene uses the Standard view transform, which CLIPS PER CHANNEL, not
# per pixel. A saturated red emitter at 1.0 has its red channel clipped while
# its green and blue stay near zero, so it comes out red and not white. The
# thing 0.4 actually broke was the field itself: the sun already puts a lit
# surface around 0.68, so an emissive ball rendered DARKER than the same colour
# unlit-emissive — peak red 176 against 197 — i.e. asking for emission made the
# picture dimmer, which is the accepted-and-dropped fault wearing a different
# hat. A caller who wants a dim glow dims the colour.
EMISSION_STRENGTH = 1.0


def resolve_resolution(block):
    """Bind the sampling counts from the spec's `render.curve_resolution`.

    Module globals rather than parameters, because the sampling is spread across
    `_ellipse_points`, `_rect_points` and `_parse_path`, which are pure
    functions of an element and should stay that way. Rebinding once, before any
    geometry is built, keeps the call sites unchanged and the sampling in one
    place. The names are restored by the caller's finally-block, so a second
    render in the same process cannot inherit the first one's resolution.
    """
    global CIRCLE_STEPS, CORNER_STEPS, CURVE_STEPS, SPLINE_RESOLUTION_U
    previous = (CIRCLE_STEPS, CORNER_STEPS, CURVE_STEPS, SPLINE_RESOLUTION_U)
    block = block or {}
    CIRCLE_STEPS = int(block.get("circle", CIRCLE_STEPS))
    CORNER_STEPS = int(block.get("corner", CORNER_STEPS))
    CURVE_STEPS = int(block.get("bezier", CURVE_STEPS))
    SPLINE_RESOLUTION_U = int(block.get("spline", SPLINE_RESOLUTION_U))
    return previous


def restore_resolution(previous):
    """Put the sampling counts back, so one render cannot leak into the next."""
    global CIRCLE_STEPS, CORNER_STEPS, CURVE_STEPS, SPLINE_RESOLUTION_U
    CIRCLE_STEPS, CORNER_STEPS, CURVE_STEPS, SPLINE_RESOLUTION_U = previous

# The orthographic camera: a fixed elevation, an azimuth that steps 0..360
# across ``views``, and a distance that only has to clear the near clip — in an
# ortho projection the distance does not change the framing.
#
# The elevation is only the DEFAULT now: the spec's ``render.elevation`` sets it,
# which is what makes a plan view (90 degrees, straight down) reachable at all.
ELEVATION_DEGREES = 25.0
PROJECTION_DEFAULT = "ortho"
LENS_DEFAULT = 50.0
FRAME_MARGIN = 1.12
ZOOM_OUT = 3.0

# Blender's default sensor size in mm. sensor_fit is HORIZONTAL, so this is the
# frame's WIDTH and the vertical half-angle follows from the aspect ratio — which
# keeps the perspective fit on the same arithmetic the ortho one uses.
SENSOR_WIDTH_MM = 36.0

# The colours an element with no fill/stroke renders in: a neutral, so an
# uncoloured solid is still visible against the background.
NEUTRAL = (0.8, 0.8, 0.8)

CLOSED_TYPES = ("rect", "circle", "ellipse", "polygon")
# The 3D primitives, mirrored from chopshop_plot/blender.py. See the note there
# for why they live only in this operation: SVG cannot describe a solid whose
# silhouette changes with the view, so `generate` refuses these types by name.
PRIMITIVE_TYPES = ("box", "sphere", "cylinder", "cone", "torus")
# Mirrors DEFAULT_SEGMENTS / DEFAULT_TUBE_SEGMENTS in the package: how many
# straight pieces approximate a curved solid's loop, and its tube.
SEGMENTS_DEFAULT = 32
TUBE_SEGMENTS_DEFAULT = 16
PATH_COMMANDS = "MmLlHhVvZzCcSsQqTt"
PATH_TOKEN = re.compile(r"[MmLlHhVvZzCcSsQqTt]|-?\d*\.?\d+(?:[eE][-+]?\d+)?")
HEX_COLOUR = re.compile(r"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")


# ---------------------------------------------------------------------------
# Plumbing: arguments and failure.
# ---------------------------------------------------------------------------


def _fail(message):
    """Print why and exit non-zero. Never a silent success."""
    print("bpy_geometry: %s" % message, file=sys.stderr)
    raise SystemExit(1)


def _run():
    """``main`` with every escape hatch turned into a non-zero exit.

    MEASURED, and the reason this wrapper exists: ``blender --background
    --python`` exits 0 when the script raises an unhandled Python exception — it
    prints the traceback and reports success anyway. Only an explicit
    ``SystemExit`` reaches the shell. The driver reads the exit code, so an
    unexpected error here would otherwise be collected as a completed render.
    """
    try:
        main()
    except SystemExit:
        raise
    except BaseException as exc:  # noqa: BLE001 - the last line of defence
        _fail("unhandled %s: %s" % (type(exc).__name__, exc))


def _args():
    """The spec path, the output directory, and an optional ``probe`` flag.

    Blender owns ``sys.argv`` up to ``--`` (its own flags, then ``--python``);
    everything after the separator is ours. The optional third argument is
    ``probe`` (see ``_probe``); the driver never passes it, because a caller
    wants frames and not a measurement.
    """
    if "--" not in sys.argv:
        _fail("expected: blender --background --python bpy_geometry.py -- SPEC.json OUT_DIR")
    rest = sys.argv[sys.argv.index("--") + 1:]
    if len(rest) < 2:
        _fail("expected two arguments after --: the spec JSON path and the output dir")
    probe = len(rest) > 2 and rest[2] == "probe"
    return rest[0], rest[1], probe


def _probe(objects):
    """Report each object's mesh bounds as JSON, and render nothing.

    The measurements this operation makes are claims about Blender, not about
    this code: that ``extrude`` is a HALF thickness and that a solid of depth
    ``d`` at height ``z`` occupies ``z - d .. z + d`` was established by reading
    the generated mesh's z bounds. A comment recording that is a memory, and
    the codebase had that memory WRONG once (it claimed the extrusion ran
    along ``+z``). So the numbers are read back here, from ``to_mesh()`` — the
    same surface the render shows — and the tests assert on them, which is what
    keeps a Blender release or a refactor from silently reopening the
    measurement.

    One JSON object on stdout after a marker line, so a caller can read it
    without parsing Blender's own log noise around it.
    """
    bpy.context.view_layer.update()
    report = []
    for obj in objects:
        mesh = obj.to_mesh()
        if not mesh.vertices:
            obj.to_mesh_clear()
            _fail("%s produced no geometry to measure" % obj.name)
        lower = [min(vertex.co[i] for vertex in mesh.vertices) for i in range(3)]
        upper = [max(vertex.co[i] for vertex in mesh.vertices) for i in range(3)]
        report.append({
            "name": obj.name,
            "type": obj.data.name,
            "is_curve": obj.type == "CURVE",
            "min": [round(value, 6) for value in lower],
            "max": [round(value, 6) for value in upper],
            "verts": len(mesh.vertices),
            "polys": len(mesh.polygons),
        })
        obj.to_mesh_clear()
    print("bpy_geometry: probe %s" % json.dumps(report, sort_keys=True), flush=True)
    return report


# ---------------------------------------------------------------------------
# Colours: the spec speaks CSS/sRGB, Blender speaks linear.
# ---------------------------------------------------------------------------


def _linear(channel):
    """sRGB 0..1 -> linear, the inverse of the sRGB transfer function."""
    if channel <= 0.04045:
        return channel / 12.92
    return ((channel + 0.055) / 1.055) ** 2.4


def _colour(value, default):
    """A ``#rrggbb`` (or ``#rgb``) string -> a linear RGB tuple.

    A colour this cannot read — a CSS name such as ``red``, or ``none`` — falls
    back to ``default`` rather than failing the render: the geometry is the
    point of this operation and an unreadable colour must not lose it. The
    fallback is stated, not guessed at per element.
    """
    match = HEX_COLOUR.match(value.strip()) if isinstance(value, str) else None
    if not match:
        return default
    digits = match.group(1)
    if len(digits) == 3:
        digits = "".join(ch * 2 for ch in digits)
    return tuple(_linear(int(digits[i:i + 2], 16) / 255.0) for i in (0, 2, 4))


def _rgba(value, default):
    """`_colour` as a 4-tuple, for Blender's RGBA sockets.

    Separate from `_colour` rather than a flag on it: the shape a socket wants
    is a property of the SOCKET, and the two call sites want different shapes
    for the same string. Writing a 3-tuple into an RGBA socket raises inside
    Blender's property setter rather than at the call, which is the kind of
    failure that disappears into a broad `except` and leaves a default in place
    that nobody notices.
    """
    return tuple(_colour(value, default[:3])) + (default[3],)


def _element_colour(element):
    """The colour an element renders in: its fill when solid, its stroke as a tube."""
    key = "stroke" if _is_stroke(element) else "fill"
    return _colour(element.get(key), NEUTRAL)


# ---------------------------------------------------------------------------
# Element vocabulary -> contours. Same shapes as generate, in Blender's plane.
# ---------------------------------------------------------------------------


def _is_stroke(element):
    """Mirrors chopshop_plot/blender.py's is_stroke: open elements become tubes.

    A 3D PRIMITIVE is never a stroke, and the package's own `is_stroke` says so
    explicitly. This mirror has to say it too, and the reason is a bug worth
    recording: the two implementations of `is_stroke` with two
    implementations is exactly the shape this repo warns about, and when the
    primitives landed here without the matching branch, every primitive fell
    through to the `return True` below, read `stroke` — a field primitives
    validate_blender REFUSES — found nothing, and rendered in NEUTRAL grey. An
    orange sphere came out the same grey as a white one, with no error anywhere,
    because the fallback is a default rather than a failure.

    That is why the branch is here and not left implicit: a mirror of a
    predicate has to carry every case the original has, and a case it is missing
    does not raise, it just quietly picks a different answer.
    """
    etype = element["type"]
    if etype in PRIMITIVE_TYPES:
        return False
    if etype in CLOSED_TYPES:
        return False
    if etype == "path":
        fill = element.get("fill")
        filled = isinstance(fill, str) and fill.strip().lower() not in ("", "none")
        return not (filled and re.search(r"[Zz]", element["d"]))
    return True


def _cubic(p0, p1, p2, p3, t):
    u = 1.0 - t
    return (
        u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
        u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
    )


def _quadratic(p0, p1, p2, t):
    u = 1.0 - t
    return (
        u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
        u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1],
    )


def _reflect(control, previous, current):
    """The control point a shorthand curve mirrors; the current point if the
    previous command was not the same family of curve."""
    if control is None or previous not in ("C", "S", "Q", "T"):
        return current
    return (2.0 * current[0] - control[0], 2.0 * current[1] - control[1])


def _parse_path(d):
    """SVG path data -> ``[(points, closed), ...]``, one entry per subpath.

    Absolute and relative moveto/lineto/horizontal/vertical/close plus the C, S,
    Q and T curves (sampled at CURVE_STEPS). Nothing else can arrive here:
    ``validate_blender`` refused every other command before this process started.
    """
    tokens = PATH_TOKEN.findall(d)
    subpaths = []
    points = []
    closed = False
    current = (0.0, 0.0)
    start = (0.0, 0.0)
    command = None
    previous = None
    control = None
    index = 0

    def end_subpath():
        nonlocal points, closed
        # A one-point subpath has no contour to extrude or to run a tube along.
        if len(points) >= 2:
            subpaths.append((points, closed))
        points = []
        closed = False

    def numbers(count):
        nonlocal index
        if index + count > len(tokens):
            _fail("path data ends inside a command: %r" % d)
        values = [float(token) for token in tokens[index:index + count]]
        index += count
        return values

    while index < len(tokens):
        token = tokens[index]
        if token in PATH_COMMANDS:
            command = token
            index += 1
            if command in ("Z", "z"):
                closed = True
                end_subpath()
                current = start
                command = None
                previous = "Z"
                continue
        elif command is None:
            _fail("path data starts with a number instead of a command: %r" % d)

        upper = command.upper()
        relative = command.islower()

        if upper == "M":
            x, y = numbers(2)
            end_subpath()
            current = (current[0] + x, current[1] + y) if relative else (x, y)
            start = current
            points.append(current)
            # The SVG grammar says the rest of a moveto's numbers are linetos:
            # "M0 0 10 10" is a line, not a moveto nobody drew.
            command = "l" if relative else "L"
            previous = "M"
            control = None
        elif upper == "L":
            x, y = numbers(2)
            current = (current[0] + x, current[1] + y) if relative else (x, y)
            points.append(current)
            previous, control = "L", None
        elif upper == "H":
            (x,) = numbers(1)
            current = (current[0] + x, current[1]) if relative else (x, current[1])
            points.append(current)
            previous, control = "H", None
        elif upper == "V":
            (y,) = numbers(1)
            current = (current[0], current[1] + y) if relative else (current[0], y)
            points.append(current)
            previous, control = "V", None
        elif upper in ("C", "S", "Q", "T"):
            if upper in ("C", "S"):
                if upper == "C":
                    x1, y1, x2, y2, x, y = numbers(6)
                else:
                    x2, y2, x, y = numbers(4)
                    x1, y1 = _reflect(control, previous, current)
                if relative:
                    x1, y1 = current[0] + x1, current[1] + y1
                    x2, y2 = current[0] + x2, current[1] + y2
                    x, y = current[0] + x, current[1] + y
                origin = current
                for step in range(1, CURVE_STEPS + 1):
                    points.append(_cubic(origin, (x1, y1), (x2, y2), (x, y),
                                         step / CURVE_STEPS))
                control = (x2, y2)
            else:
                if upper == "Q":
                    x1, y1, x, y = numbers(4)
                else:
                    x, y = numbers(2)
                    x1, y1 = _reflect(control, previous, current)
                if relative:
                    x1, y1 = current[0] + x1, current[1] + y1
                    x, y = current[0] + x, current[1] + y
                origin = current
                for step in range(1, CURVE_STEPS + 1):
                    points.append(_quadratic(origin, (x1, y1), (x, y), step / CURVE_STEPS))
                control = (x1, y1)
            current = (x, y)
            previous = upper
        else:  # pragma: no cover - validate_blender refused these already
            _fail("unsupported path command %r" % command)

    end_subpath()
    return subpaths


def _rect_points(element):
    x, y = float(element["x"]), float(element["y"])
    width, height = float(element["width"]), float(element["height"])
    radius = element.get("rx") or 0.0
    if not radius:
        return [(x, y), (x + width, y), (x + width, y + height), (x, y + height)]
    # A rounded corner is sampled like any other curve, so the render is the
    # shape the same rx draws in SVG rather than a square with the rounding lost.
    radius = min(float(radius), width / 2.0, height / 2.0)
    corners = (
        ((x + width - radius, y + radius), -90.0),
        ((x + width - radius, y + height - radius), 0.0),
        ((x + radius, y + height - radius), 90.0),
        ((x + radius, y + radius), 180.0),
    )
    points = []
    for (cx, cy), start_angle in corners:
        for step in range(CORNER_STEPS + 1):
            angle = math.radians(start_angle + 90.0 * step / CORNER_STEPS)
            points.append((cx + radius * math.cos(angle), cy + radius * math.sin(angle)))
    return points


def _ellipse_points(element):
    cx, cy = float(element["cx"]), float(element["cy"])
    rx = float(element.get("rx", element.get("r", 0.0)))
    ry = float(element.get("ry", element.get("r", 0.0)))
    points = []
    for step in range(CIRCLE_STEPS):
        angle = 2.0 * math.pi * step / CIRCLE_STEPS
        points.append((cx + rx * math.cos(angle), cy + ry * math.sin(angle)))
    return points


def _subpaths(element):
    """One element -> ``[(points, closed), ...]`` in spec coordinates.

    A primitive has NO contour reading and says so: it is a mesh solid, not a
    silhouette, so the in-Blender path that flattens 2D shapes into splines is
    not where it is built (see ``_primitive_object``). Refusing here rather than
    returning nothing keeps a wrong solid from becoming a blank render.
    """
    etype = element["type"]
    if etype in PRIMITIVE_TYPES:
        _fail("%r is a 3D primitive: it has no contour" % etype)
    if etype == "rect":
        return [(_rect_points(element), True)]
    if etype == "circle":
        return [(_ellipse_points(element), True)]
    if etype == "ellipse":
        return [(_ellipse_points(element), True)]
    if etype == "polygon":
        return [([(float(px), float(py)) for px, py in element["points"]], True)]
    if etype == "polyline":
        return [([(float(px), float(py)) for px, py in element["points"]], False)]
    if etype == "line":
        return [([(float(element["x1"]), float(element["y1"])),
                  (float(element["x2"]), float(element["y2"]))], False)]
    if etype == "path":
        return _parse_path(element["d"])
    _fail("unknown element type %r" % etype)  # pragma: no cover


# ---------------------------------------------------------------------------
# The scene: one curve object per element, a camera framed to the bounds.
# ---------------------------------------------------------------------------


def _material(colour, cache, shading=None, name_hint=""):
    """One material for one surface, and the cache key has to say which.

    `shading` is the resolved block (the document's `render.shading` with the
    element's own `material` overrides applied). It is part of the cache KEY
    rather than applied afterwards, which is the whole reason the key changes:
    two elements of the same colour but different roughness must be two
    materials, and a key of the colour alone would hand both of them the first
    one's surface — a second element silently rendering with the wrong material,
    which is exactly the class of fault this repo refuses to ship.

    MEASURED on 4.3: the Principled BSDF input is named `Specular IOR Level`;
    before 4.0 it was `Specular`. Both are tried and a missing one is skipped
    rather than fatal, because the property is a refinement and failing the
    whole render over it would be worse than not setting it.
    """
    shading = dict(SHADING_DEFAULTS, **(shading or {}))
    emission = shading.get("emission")
    alpha = float(shading.get("alpha", 1.0))
    key = "material_%02x%02x%02x_a%03d_r%03d_m%03d_s%03d_e%s" % (
        tuple(int(round(channel * 255)) for channel in colour)
        + (int(round(alpha * 255)),
           int(round(float(shading["roughness"]) * 255)),
           int(round(float(shading["metallic"]) * 255)),
           int(round(float(shading.get("specular", 0.0)) * 255)),
           emission or "none"))
    material = cache.get(key)
    if material is not None:
        return material
    material = bpy.data.materials.new(key)
    # `diffuse_color` is what WORKBENCH reads, and its alpha is the only way a
    # partly transparent surface can be opaque-to-Workbench and see-through to
    # EEVEE. It is set from the same number, so the two engines cannot disagree
    # about what the caller asked for.
    material.diffuse_color = (colour[0], colour[1], colour[2], alpha)
    material.use_nodes = True
    # The blend method is a SCENE setting as much as a material one, and a
    # surface with alpha < 1 under EEVEE needs it or it renders fully opaque —
    # which would make `alpha` a field this operation reads and does not act on.
    if alpha < 1.0:
        for attribute, value in (("blend_method", "BLEND"),
                                 ("shadow_method", "HASHED")):
            try:
                setattr(material, attribute, value)
            except (AttributeError, TypeError):
                pass  # removed in a later Blender; EEVEE Next uses render settings
    shader = material.node_tree.nodes.get("Principled BSDF")
    if shader is not None:
        _set_input(shader, "Base Color", (colour[0], colour[1], colour[2], 1.0))
        _set_input(shader, "Roughness", float(shading["roughness"]))
        _set_input(shader, "Metallic", float(shading["metallic"]))
        _set_input(shader, "Specular IOR Level", float(shading.get("specular", 0.0)))
        _set_input(shader, "Specular", float(shading.get("specular", 0.0)))
        if emission:
            # MEASURED on 4.3, and both of these lines are load-bearing:
            #
            # * `Emission Color` alone changes NOTHING, because the socket next
            #   to it, `Emission Strength`, defaults to 0.0. A colour with a
            #   strength of zero emits nothing, so an implementation setting
            #   only the colour produces an ordinary unlit ball and `emission`
            #   looks accepted-and-dropped — the exact fault this block exists
            #   to prevent.
            # * the colour is written as an explicit RGBA, because `_colour`
            #   returns a 3-tuple and Blender's colour sockets are 4-vectors.
            #   Assigning a 3-tuple raises inside the property setter, and
            #   `_set_input` swallows TypeError as "this Blender does not have
            #   that socket" — so the write is skipped and the socket keeps
            #   Blender's white default. The result is an emitter that emits
            #   WHITE whatever colour the spec asked for.
            #
            # The pre-4.0 name is tried too, for older Blender.
            rgba = _rgba(emission, (0.0, 0.0, 0.0, 1.0))
            _set_input(shader, "Emission Color", rgba)
            _set_input(shader, "Emission", rgba)
            _set_input(shader, "Emission Strength", EMISSION_STRENGTH)
        if alpha < 1.0:
            _set_input(shader, "Alpha", alpha)
    cache[key] = material
    return material


def _set_input(shader, name, value):
    """Set a shader input if this Blender has it. Returns what it managed.

    Principled BSDF is renamed between versions (`Specular` -> `Specular IOR
    Level` in 4.0, `Emission` -> `Emission Color`), so a caller naming one
    spelling would silently set nothing on the other. Trying a short list and
    skipping what is absent is what makes the material block portable.

    The two failure modes are kept APART on purpose, and that separation is not
    tidiness. Writing a 3-tuple into an RGBA socket raises TypeError from
    inside Blender's property setter — the same exception a genuinely absent
    socket never raises. An earlier version of this function caught both and
    returned False, so a shape mistake was indistinguishable from a missing
    socket: the write was skipped, Blender's white default stayed, and an
    `emission: "#00ff00"` produced a WHITE emitter with nothing logged. A
    caller cannot fix what it is never told about, so a bad value is now a loud
    failure and only a genuinely absent socket is a quiet skip.
    """
    socket = shader.inputs.get(name)
    if socket is None:
        return "absent"
    try:
        socket.default_value = value
    except (TypeError, ValueError) as exc:
        _fail("cannot set %s '%s' to %r (%s: %s) — this is a bug in "
              "bpy_geometry, not a bad spec: the value came from a validated "
              "field"
              % (shader.name, name, value, type(exc).__name__, exc))
    return "set"


def _is_primitive(element):
    """Mirrors chopshop_plot/blender.py's is_primitive: the 3D mesh solids."""
    return element["type"] in PRIMITIVE_TYPES


def _element_depth(element, extrude):
    """Mirrors chopshop_plot/blender.py's element_depth.

    One element's own extrusion, or the spec's. Read here as well because this
    file runs inside Blender and cannot import the package — the same reason
    ``_is_stroke`` and ``_output_stem`` are mirrored.

    MEASURED, Blender 4.3: the value is HALF the resulting thickness and the
    solid grows both ways from the element's plane, so `depth: 1` spans z ± 1.
    """
    value = element.get("depth")
    return extrude["depth"] if value is None else float(value)


def _element_material(element, shading=None):
    """Mirrors chopshop_plot/blender.py's resolve_material: the document's
    shading with this element's own `material` block on top.

    Key by key rather than replacing, so a document sets the house style once in
    `render.shading` and an element overrides only what it must. An element with
    no block is exactly the document's material — which is what makes the
    document-level knob a knob rather than a second, parallel way to say the
    same thing.
    """
    block = dict(SHADING_DEFAULTS, **(shading or {}))
    own = element.get("material")
    if isinstance(own, dict):
        block.update(own)
    return block


def _element_z(element):
    """Mirrors chopshop_plot/blender.py's element_z: the element's plane height.

    The solid spans ``z ± depth`` about it — Blender extrudes both ways (see
    ``_element_depth``).
    """
    value = element.get("z")
    return 0.0 if value is None else float(value)


def _primitive_object(name, element, extrude, offset, materials, shading=None):
    """One 3D primitive as a MESH object: a real solid, not an extruded contour.

    This is the gap the 2D vocabulary could not cross. Every contour element is
    a silhouette pushed along z, so its outline is fixed no matter where the
    camera stands: a sphere drawn that way is a bevelled disc from the side. A
    primitive is a solid of revolution (or a box), so its silhouette genuinely
    changes with the view, which is what "a 3D model" means.

    The parameterisation, and the one rule the whole set keeps:

    - ``depth`` is the HALF extent along z, exactly as it is for a contour, so a
      primitive at height ``z`` spans ``z - depth .. z + depth``. Consistent with
      ``_element_depth`` rather than a second convention — the measurement that
      makes a composed solid sit correctly has to be the same measurement
      everywhere, and it is a TEST now (see the note in chopshop_plot/blender.py).
    - ``r`` (and a torus's ``tube``) are radii, so a primitive's own size does
      not depend on the spec's ``extrude.depth``: absent, it takes it, exactly
      as a contour does.
    - a box is anchored at its ``(x, y)`` corner, like the ``rect`` it replaces,
      so it drops into an existing 2D layout; every other primitive is centred on
      ``(cx, cy)``, like the ``circle`` and ``ellipse`` beside it.
    - ``segments`` is the resolution rule: how many straight pieces stand in for
      the curve. A higher number is smoother and heavier, and the default sits
      where a solid looks round at this operation's framings.

    MEASURED (Blender 4.3): ``bpy.ops.mesh.primitive_*_add`` writes into the
    ACTIVE collection and leaves the new object selected, and — the reason
    ``_apply_transform`` exists — ``to_mesh()`` returns LOCAL coordinates, so a
    primitive left untransformed would be framed and probed at the origin no
    matter where the spec put it.
    """
    etype = element["type"]
    segments = element.get("segments")
    segments = SEGMENTS_DEFAULT if segments is None else int(segments)
    half = _element_depth(element, extrude)
    ox, oy = offset
    height = _element_z(element)

    # The y flip is the same one the contour path applies: spec y grows
    # downward and 3D y grows up, so a spec seen from above reads like the SVG
    # the same document draws.
    if etype == "box":
        # A box is corner-anchored, so its centre is a half-extent away.
        cx = float(element["x"]) + ox + float(element["width"]) / 2.0
        cy = -(float(element["y"]) + oy + float(element["height"]) / 2.0)
        bpy.ops.mesh.primitive_cube_add(size=2.0, location=(cx, cy, height))
        obj = bpy.context.active_object
        # size=2 is the UNIT cube, so the scale carries the real extents and the
        # half-thickness is `depth` like every other solid's.
        obj.scale = (float(element["width"]) / 2.0,
                     float(element["height"]) / 2.0, half)
    else:
        radius = float(element["r"])
        cx = float(element["cx"]) + ox
        cy = -(float(element["cy"]) + oy)
        obj = None
        if etype == "sphere":
            bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=max(3, segments // 2),
                                                 radius=radius, location=(cx, cy, height))
            obj = bpy.context.active_object
            # A sphere's z extent is its radius; an explicit `depth` squashes or
            # stretches it into an ellipsoid, which is the honest reading of
            # "this solid is `depth` tall" rather than silently ignoring it.
            if half != radius:
                obj.scale = (1.0, 1.0, half / radius)
        elif etype == "cylinder":
            bpy.ops.mesh.primitive_cylinder_add(vertices=segments, radius=radius,
                                                depth=2.0 * half,
                                                location=(cx, cy, height))
            obj = bpy.context.active_object
        elif etype == "cone":
            # radius1 the base, radius2 the apex: a cone, not a truncated one.
            bpy.ops.mesh.primitive_cone_add(vertices=segments, radius1=radius,
                                            radius2=0.0, depth=2.0 * half,
                                            location=(cx, cy, height))
            obj = bpy.context.active_object
        elif etype == "torus":
            tube_segments = element.get("tube_segments")
            tube_segments = (TUBE_SEGMENTS_DEFAULT if tube_segments is None
                             else int(tube_segments))
            tube = float(element["tube"])
            bpy.ops.mesh.primitive_torus_add(major_radius=radius, minor_radius=tube,
                                             major_segments=segments,
                                             minor_segments=tube_segments,
                                             location=(cx, cy, height))
            obj = bpy.context.active_object
            # A torus's own z extent is its tube radius; `depth` scales that
            # tube, the same squash-the-solid reading a sphere gets.
            if half != tube:
                obj.scale = (1.0, 1.0, half / tube)
        else:  # pragma: no cover - validate_blender refused these already
            _fail("unknown primitive type %r" % etype)
        if obj is None:  # pragma: no cover - _fail above raises
            _fail("primitive %r produced no object" % etype)

    obj.name = name
    obj.data.name = name
    # A curved solid built from `segments` flat facets is a faceted solid; the
    # mesh is smooth-shaded so the facets affect its SILHOUETTE (where
    # `segments` governs the resolution) and not its shading, which is what
    # makes the default look round. MEASURED: 4.3 removed the mesh-level
    # auto-smooth flag, so this is set per polygon.
    obj.data.polygons.foreach_set("use_smooth", [True] * len(obj.data.polygons))
    _apply_transform(obj)
    obj.data.materials.append(
        _material(_element_colour(element), materials, _element_material(element, shading)))
    return obj


def _apply_transform(obj):
    """Bake an object's location/rotation/scale into its mesh data.

    MEASURED, Blender 4.3: ``to_mesh()`` hands back LOCAL coordinates, so an
    object left at ``location=(300, 0, 0)`` with ``scale=(2, 1, 1)`` still
    measures as a unit box at the origin. The camera framing (``_bounds``) and
    the probe both read the mesh, so without this a primitive would be framed
    and measured in the wrong place. Applying the transform is the one reading
    where the mesh data and the world agree.
    """
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    obj.select_set(False)


def _element_object(name, element, extrude, offset, materials, shading=None):
    """One element as a curve object: a filled solid, or a stroke tube.

    Closed elements (rect/circle/ellipse/polygon, and a path whose data closes
    the contour and which carries a fill) are a 2D curve: filled with BOTH caps,
    extruded by this element's ``depth`` (its own, or the spec's) and bevelled by
    ``bevel_depth``. Open ones (line/polyline/unfilled path) are a 3D curve with
    no extrusion and a bevel that IS the stroke: ``stroke_width`` is the tube
    radius, default 0.02.

    ``z`` lifts the whole element off the sketch plane, which is what lets a
    spec stack layers and stand bars on a base rather than all of it sharing z=0.
    """
    curve = bpy.data.curves.new(name, "CURVE")
    if _is_stroke(element):
        stroke_width = element.get("stroke_width")
        curve.dimensions = "3D"
        curve.fill_mode = "FULL"
        curve.extrude = 0.0
        curve.bevel_depth = TUBE_RADIUS_DEFAULT if stroke_width is None else float(stroke_width)
        curve.bevel_resolution = extrude["bevel_resolution"]
    else:
        curve.dimensions = "2D"
        curve.fill_mode = "BOTH"
        curve.extrude = _element_depth(element, extrude)
        curve.bevel_depth = extrude["bevel_depth"]
        curve.bevel_resolution = extrude["bevel_resolution"]
    curve.resolution_u = SPLINE_RESOLUTION_U

    ox, oy = offset
    height = _element_z(element)
    for points, closed in _subpaths(element):
        if len(points) < 2:
            continue
        spline = curve.splines.new("POLY")
        spline.points.add(len(points) - 1)
        for point, (px, py) in zip(spline.points, points):
            # Spec y grows downward and 3D y grows up, so the sketch is flipped
            # about the x axis: seen from above, the render is what the same spec
            # draws as an SVG. The extrusion grows BOTH ways along z from this
            # plane (MEASURED — depth is the half-thickness, see _element_depth),
            # so `z` places the element's mid-plane rather than its base.
            point.co = (px + ox, -(py + oy), height, 1.0)
        spline.use_cyclic_u = bool(closed)

    curve.materials.append(
        _material(_element_colour(element), materials, _element_material(element, shading)))
    obj = bpy.data.objects.new(name, curve)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def _build_geometry(spec, extrude, materials, shading=None):
    """Every element, and the tiled one repeated across its grid, as objects.

    Tiling comes first, exactly as ``generate`` draws it: the tiling element's
    own coordinates are offsets within each cell.

    The dispatch is the one that matters: a 3D primitive becomes a MESH and
    every other element becomes an extruded CURVE, through the same name, the
    same ``z``/``depth`` rules and the same material cache — so the two kinds
    compose in one document and are framed together.
    """
    objects = []
    tiling = spec.get("tiling")
    if tiling:
        element = tiling["element"]
        columns, rows = tiling["grid"]
        cell = tiling["cell"]
        origin = tiling["origin"]
        for row in range(rows):
            for column in range(columns):
                offset = (origin[0] + column * cell[0], origin[1] + row * cell[1])
                objects.append(_any_object("tile_%03d_%03d" % (column, row), element,
                                           extrude, offset, materials, shading))
    for position, element in enumerate(spec.get("elements", [])):
        objects.append(_any_object("element_%03d" % position, element, extrude,
                                   (0.0, 0.0), materials, shading))
    if not objects:
        _fail("the spec produced no geometry")
    return objects


def _any_object(name, element, extrude, offset, materials, shading=None):
    """A primitive as a mesh, anything else as a curve. The one dispatch point."""
    if _is_primitive(element):
        return _primitive_object(name, element, extrude, offset, materials, shading)
    return _element_object(name, element, extrude, offset, materials, shading)


def _bounds(objects):
    """The geometry's true bounds, from the generated surface.

    A curve's own ``bound_box`` is its control box: it does NOT include the
    bevel or the extrusion, so framing to it would clip the solid. ``to_mesh()``
    gives the surface the render actually shows.
    """
    lower = [float("inf")] * 3
    upper = [float("-inf")] * 3
    bpy.context.view_layer.update()
    for obj in objects:
        mesh = obj.to_mesh()
        for vertex in mesh.vertices:
            for axis, value in enumerate((vertex.co.x, vertex.co.y, vertex.co.z)):
                lower[axis] = min(lower[axis], value)
                upper[axis] = max(upper[axis], value)
        obj.to_mesh_clear()
    if lower[0] == float("inf") or lower[1] == float("inf"):
        _fail("the spec produced no geometry to frame")
    return lower, upper


def _corners(lower, upper):
    return [(x, y, z) for x in (lower[0], upper[0])
            for y in (lower[1], upper[1])
            for z in (lower[2], upper[2])]


def _camera(scene, lower, upper):
    """An orthographic camera, aimed at the bounds centre by ``_aim``."""
    centre = [(lower[axis] + upper[axis]) / 2.0 for axis in range(3)]
    radius = max(0.001, max(upper[axis] - lower[axis] for axis in range(3)) / 2.0)
    data = bpy.data.cameras.new("chopshop-camera")
    data.type = "ORTHO"
    # The ortho scale is the frame's WIDTH, always: sensor_fit HORIZONTAL, so the
    # framing arithmetic below does not depend on which dimension is larger.
    data.sensor_fit = "HORIZONTAL"
    distance = ZOOM_OUT * radius
    data.clip_start = max(0.001, distance - 4.0 * radius)
    data.clip_end = distance + 4.0 * radius
    camera = bpy.data.objects.new("chopshop-camera", data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    return camera, data, centre, radius, distance


def _aim(camera, data, lower, upper, centre, radius, distance, azimuth, render):
    """Place and frame the camera for one azimuth.

    ``render.elevation`` is degrees above the horizon and ``render.azimuth`` is
    where the sweep STARTS (``views`` still steps evenly around from it), so a
    plan view — 90 degrees, straight down, the reading a chart or a floor plan
    is actually taken in — is a spec away rather than unreachable.

    Framing projects the eight corners of the bounds box onto the camera's
    right/up axes and takes the larger half-extent, so the fit comes from the
    geometry rather than from a guess — the same spec always frames the same way,
    whatever the bevel and the extrusion added.

    The projection decides how that fit becomes a frame. Orthographic framing is
    independent of the camera's distance, so the distance only has to clear the
    near clip and ``ortho_scale`` is the fit. A PERSPECTIVE frame IS its
    distance, so the distance is solved from the fit instead: the lens gives the
    half-angles and the distance that covers the geometry follows.
    """
    elevation = math.radians(float(render["elevation"]))
    pitch = math.pi / 2.0 - elevation
    width, height = float(render["size"][0]), float(render["size"][1])

    right = (math.cos(azimuth), math.sin(azimuth), 0.0)
    up = (-math.sin(azimuth) * math.cos(pitch), math.cos(azimuth) * math.cos(pitch),
          math.sin(pitch))
    half_width = half_height = 0.0
    for corner in _corners(lower, upper):
        offset = [corner[axis] - centre[axis] for axis in range(3)]
        half_width = max(half_width, abs(offset[0] * right[0] + offset[1] * right[1]))
        half_height = max(half_height, abs(offset[0] * up[0] + offset[1] * up[1]
                                        + offset[2] * up[2]))

    if render["projection"] == "perspective":
        data.type = "PERSP"
        data.lens = float(render["lens"])
        data.sensor_width = SENSOR_WIDTH_MM
        # sensor_fit is HORIZONTAL, so the sensor's 36mm spans the frame's WIDTH
        # and the vertical half-angle follows from the aspect ratio.
        half_angle_h = math.atan((SENSOR_WIDTH_MM / 2.0) / float(render["lens"]))
        half_angle_v = math.atan((SENSOR_WIDTH_MM / 2.0) * (height / width)
                                 / float(render["lens"]))
        distance = max(half_width / math.tan(half_angle_h),
                       half_height / math.tan(half_angle_v)) * FRAME_MARGIN
        data.clip_start = max(0.001, distance - 8.0 * radius)
        data.clip_end = distance + 8.0 * radius
    else:
        data.type = "ORTHO"
        data.ortho_scale = max(1e-3, max(2.0 * half_width,
                                        2.0 * half_height * (width / height))
                                    * FRAME_MARGIN)
        data.clip_start = max(0.001, distance - 4.0 * radius)
        data.clip_end = distance + 4.0 * radius

    camera.location = (
        centre[0] + distance * math.cos(elevation) * math.sin(azimuth),
        centre[1] - distance * math.cos(elevation) * math.cos(azimuth),
        centre[2] + distance * math.sin(elevation),
    )
    camera.rotation_euler = (pitch, 0.0, azimuth)


def _setup_scene(scene, render, background):
    """Resolution, engine, background and the colour pipeline."""
    width, height = render["size"]
    scene.render.resolution_x = int(round(width))
    scene.render.resolution_y = int(round(height))
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.film_transparent = False
    # Standard rather than Filmic/AgX: the spec's colours are CSS/sRGB, and a
    # colour a caller wrote down should be the colour in the PNG.
    scene.view_settings.view_transform = "Standard"
    _no_metadata(scene)

    if render["engine"] == "eevee":
        # EEVEE reads the world's colour and lights nothing by itself: without a
        # sun the render is a black frame, which would look like a failure.
        scene.render.engine = _eevee_engine()
        _add_sun(scene)
        _enable_transparency(scene)
    else:
        scene.render.engine = "BLENDER_WORKBENCH"
        shading = scene.display.shading
        shading.background_type = "VIEWPORT"
        shading.background_color = (background[0], background[1], background[2])

    # A world is created either way: Workbench's VIEWPORT background only takes
    # effect when the scene has one (without it the render comes out the theme's
    # light grey, whatever the spec asked for), and EEVEE reads its colour.
    world = bpy.data.worlds.new("chopshop-world")
    world.use_nodes = True
    node = world.node_tree.nodes.get("Background")
    if node is not None:
        node.inputs[0].default_value = (background[0], background[1], background[2], 1.0)
    world.color = (background[0], background[1], background[2])
    scene.world = world


# Blender writes a set of text chunks into every PNG — Date, RenderTime, Time,
# Software, and the host name — and they are the ONLY thing that varies between
# two runs of one spec. MEASURED: the image data is byte-identical run to run,
# while the file hash is not, because the stamps carry a wall clock. Turning them
# off makes an artifact somebody will hash or diff reproducible, and keeps the
# machine's identity out of the file at the same time.
_METADATA_FLAGS = (
    "use_stamp", "use_stamp_date", "use_stamp_time", "use_stamp_render_time",
    "use_stamp_frame", "use_stamp_frame_range", "use_stamp_scene", "use_stamp_camera",
    "use_stamp_filename", "use_stamp_hostname", "use_stamp_lens", "use_stamp_marker",
    "use_stamp_note", "use_stamp_labels", "use_stamp_memory", "use_stamp_sequencer_strip",
)


def _no_metadata(scene):
    for flag in _METADATA_FLAGS:
        if hasattr(scene.render, flag):
            setattr(scene.render, flag, False)


def _eevee_engine():
    """EEVEE's identifier, which is version-dependent: 4.2 renamed it."""
    for name in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        try:
            bpy.context.scene.render.engine = name
            return name
        except TypeError:
            continue
    _fail("this Blender has no EEVEE engine")


def _enable_transparency(scene):
    """Make EEVEE actually honour a material's alpha.

    A `material.alpha` below 1 is a promise, and EEVEE only keeps it when the
    scene's own blend settings allow it — the setting moved between versions
    (EEVEE Legacy's `blend_method`/`shadow_method` on the MATERIAL, EEVEE
    Next's `surface_render_method` on the SCENE), so this tries the modern
    location and then the legacy ones. Everything is set-if-present rather than
    required, because a Blender that has none of them still renders; what it
    would not do is honour the alpha, and that is a documented limit rather than
    a crash.
    """
    for owner, attribute, value in (
            (scene.eevee, "surface_render_method", "BLENDED"),
            (scene.eevee, "use_ssr_refraction", True),
            (scene.render, "film_transparent", False)):
        try:
            if hasattr(owner, attribute):
                setattr(owner, attribute, value)
        except (AttributeError, TypeError, ValueError):
            continue


def _add_sun(scene):
    light = bpy.data.lights.new("chopshop-sun", type="SUN")
    light.energy = 3.0
    lamp = bpy.data.objects.new("chopshop-sun", light)
    # Fixed angles: the same spec lights the same way on every run.
    lamp.rotation_euler = (math.radians(55.0), 0.0, math.radians(35.0))
    scene.collection.objects.link(lamp)
    return lamp


def _export_glb(path):
    """Write a GLB, and fail loudly if it is not there afterwards."""
    kwargs = {"filepath": path, "export_format": "GLB",
              "export_draco_mesh_compression_enable": False}
    try:
        bpy.ops.export_scene.gltf(**kwargs)
    except TypeError:
        # A Blender without the draco flag: the export itself is the point.
        bpy.ops.export_scene.gltf(filepath=path, export_format="GLB")
    if not os.path.isfile(path):
        _fail("Blender wrote no %s" % os.path.basename(path))


# ---------------------------------------------------------------------------
# The run.
# ---------------------------------------------------------------------------


def _resolved(spec):
    """The spec's optional blocks with their defaults applied."""
    extrude = spec.get("extrude") or {}
    render = spec.get("render") or {}
    size = render.get("size") or {}
    export = spec.get("export") or {}
    curve_resolution = render.get("curve_resolution")
    return (
        {
            "depth": extrude.get("depth", DEPTH_DEFAULT),
            "bevel_depth": extrude.get("bevel_depth", BEVEL_DEPTH_DEFAULT),
            "bevel_resolution": extrude.get("bevel_resolution", BEVEL_RESOLUTION_DEFAULT),
        },
        {
            "size": (size.get("width", SIZE_DEFAULT[0]), size.get("height", SIZE_DEFAULT[1])),
            "views": render.get("views", VIEWS_DEFAULT),
            "background": render.get("background", BACKGROUND_DEFAULT),
            "engine": render.get("engine", ENGINE_DEFAULT),
            "elevation": render.get("elevation", ELEVATION_DEGREES),
            "azimuth": render.get("azimuth", 0.0),
            "projection": render.get("projection", PROJECTION_DEFAULT),
            "lens": render.get("lens", LENS_DEFAULT),
            # The fidelity blocks (chopshop-bp#2), already defaulted by
            # resolve_render on the package side. Re-defaulted here because this
            # file is also run directly, against a hand-written spec, by the
            # probe path — and a render must not depend on having been through
            # the validator to have a resolution.
            "curve_resolution": dict(curve_resolution or {}),
            "shading": dict(SHADING_DEFAULTS, **(render.get("shading") or {})),
        },
        {"glb": bool(export.get("glb", False))},
    )


def _output_stem(spec):
    """Mirrors chopshop_plot/blender.py's output_stem — see the note there."""
    canonical = json.dumps(spec, sort_keys=True, separators=(",", ":"), default=str)
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:8]
    title = spec.get("title")
    slug = re.sub(r"[^a-z0-9]+", "-", title.strip().lower()).strip("-")[:40] if isinstance(
        title, str) else ""
    return "%s-%s" % (slug, digest) if slug else "render-%s" % digest


def main():
    spec_path, out_dir, probe = _args()
    with open(spec_path, "r", encoding="utf-8") as handle:
        spec = json.load(handle)
    os.makedirs(out_dir, exist_ok=True)

    extrude, render, export = _resolved(spec)
    stem = _output_stem(spec)

    # An empty scene, not the factory one: the default cube, camera and lamp are
    # not part of anybody's spec.
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene

    background = _colour(render["background"], _colour(BACKGROUND_DEFAULT, (0.005, 0.005, 0.009)))
    # The sampling counts are module globals rebound for the duration of the
    # build, and restored in a finally so a second render in the same process
    # cannot inherit this one's resolution. The restore is not ceremony: the
    # probe path and the render path both come through here, and a probe run
    # after a high-resolution render would otherwise measure against the wrong
    # numbers.
    previous_resolution = resolve_resolution(render.get("curve_resolution"))
    try:
        objects = _build_geometry(spec, extrude, {}, render.get("shading"))
    finally:
        restore_resolution(previous_resolution)
    # `probe` answers the measured questions (how thick is a solid, how many
    # faces does a circle get) and writes no files at all, so a test can pin
    # the numbers this codebase states about Blender without paying for a
    # render per assertion.
    if probe:
        _probe(objects)
        return
    lower, upper = _bounds(objects)
    _setup_scene(scene, render, background)
    camera, data, centre, radius, distance = _camera(scene, lower, upper)

    written = []
    # The azimuth sweep starts where the spec put it, so `azimuth` is an aim and
    # `views` a rotation — a single view is exactly one angle, and N views walk
    # around from that angle rather than from an arbitrary zero.
    start = math.radians(float(render["azimuth"]))
    for index in range(render["views"]):
        azimuth = start + 2.0 * math.pi * (index / render["views"])
        _aim(camera, data, lower, upper, centre, radius, distance, azimuth, render)
        scene.render.filepath = os.path.join(out_dir, "%s_%03d" % (stem, index))
        bpy.ops.render.render(write_still=True)
        frame = "%s_%03d.png" % (stem, index)
        if not os.path.isfile(os.path.join(out_dir, frame)):
            _fail("Blender wrote no frame %s" % frame)
        written.append(frame)

    if export["glb"]:
        glb = "%s.glb" % stem
        _export_glb(os.path.join(out_dir, glb))
        written.append(glb)

    print("bpy_geometry: wrote %s" % ", ".join(written), flush=True)


if __name__ == "__main__":
    _run()
