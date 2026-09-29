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
CIRCLE_STEPS = 64
CORNER_STEPS = 8
CURVE_STEPS = 16

# The orthographic camera: a fixed elevation (the spec has no field for it, so
# every render of a spec is comparable), an azimuth that steps 0..360 across
# ``views``, and a distance that only has to clear the near clip — in an ortho
# projection the distance does not change the framing.
ELEVATION_DEGREES = 25.0
FRAME_MARGIN = 1.12
ZOOM_OUT = 3.0

# The colours an element with no fill/stroke renders in: a neutral, so an
# uncoloured solid is still visible against the background.
NEUTRAL = (0.8, 0.8, 0.8)

CLOSED_TYPES = ("rect", "circle", "ellipse", "polygon")
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
    """The spec path and the output directory, after the ``--`` separator.

    Blender owns ``sys.argv`` up to ``--`` (its own flags, then ``--python``);
    everything after the separator is ours.
    """
    if "--" not in sys.argv:
        _fail("expected: blender --background --python bpy_geometry.py -- SPEC.json OUT_DIR")
    rest = sys.argv[sys.argv.index("--") + 1:]
    if len(rest) < 2:
        _fail("expected two arguments after --: the spec JSON path and the output dir")
    return rest[0], rest[1]


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


def _element_colour(element):
    """The colour an element renders in: its fill when solid, its stroke as a tube."""
    key = "stroke" if _is_stroke(element) else "fill"
    return _colour(element.get(key), NEUTRAL)


# ---------------------------------------------------------------------------
# Element vocabulary -> contours. Same shapes as generate, in Blender's plane.
# ---------------------------------------------------------------------------


def _is_stroke(element):
    """Mirrors chopshop_plot/blender.py's is_stroke: open elements become tubes."""
    etype = element["type"]
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
    """One element -> ``[(points, closed), ...]`` in spec coordinates."""
    etype = element["type"]
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


def _material(colour, cache):
    key = "material_%02x%02x%02x" % tuple(int(round(channel * 255)) for channel in colour)
    material = cache.get(key)
    if material is not None:
        return material
    material = bpy.data.materials.new(key)
    material.diffuse_color = (colour[0], colour[1], colour[2], 1.0)
    material.use_nodes = True
    shader = material.node_tree.nodes.get("Principled BSDF")
    if shader is not None:
        shader.inputs["Base Color"].default_value = (colour[0], colour[1], colour[2], 1.0)
    cache[key] = material
    return material


def _element_object(name, element, extrude, offset, materials):
    """One element as a curve object: a filled solid, or a stroke tube.

    Closed elements (rect/circle/ellipse/polygon, and a path whose data closes
    the contour and which carries a fill) are a 2D curve: filled with BOTH caps,
    extruded by ``extrude.depth`` and bevelled by ``bevel_depth``. Open ones
    (line/polyline/unfilled path) are a 3D curve with no extrusion and a bevel
    that IS the stroke: ``stroke_width`` is the tube radius, default 0.02.
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
        curve.extrude = extrude["depth"]
        curve.bevel_depth = extrude["bevel_depth"]
        curve.bevel_resolution = extrude["bevel_resolution"]
    curve.resolution_u = 12

    ox, oy = offset
    for points, closed in _subpaths(element):
        if len(points) < 2:
            continue
        spline = curve.splines.new("POLY")
        spline.points.add(len(points) - 1)
        for point, (px, py) in zip(spline.points, points):
            # Spec y grows downward and 3D y grows up, so the sketch is flipped
            # about the x axis: seen from above, the render is what the same spec
            # draws as an SVG. Depth extrudes along +z.
            point.co = (px + ox, -(py + oy), 0.0, 1.0)
        spline.use_cyclic_u = bool(closed)

    curve.materials.append(_material(_element_colour(element), materials))
    obj = bpy.data.objects.new(name, curve)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def _build_geometry(spec, extrude, materials):
    """Every element, and the tiled one repeated across its grid, as objects.

    Tiling comes first, exactly as ``generate`` draws it: the tiling element's
    own coordinates are offsets within each cell.
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
                objects.append(_element_object("tile_%03d_%03d" % (column, row), element,
                                               extrude, offset, materials))
    for position, element in enumerate(spec.get("elements", [])):
        objects.append(_element_object("element_%03d" % position, element, extrude,
                                       (0.0, 0.0), materials))
    if not objects:
        _fail("the spec produced no geometry")
    return objects


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


def _aim(camera, data, lower, upper, centre, distance, azimuth, size):
    """Place and frame the camera for one azimuth.

    Elevation is fixed (ELEVATION_DEGREES) and the azimuth steps 0..360 across
    the requested views. Framing projects the eight corners of the bounds box
    onto the camera's right/up axes and takes the larger half-extent, so the
    fit comes from the geometry rather than from a guess — the same spec always
    frames the same way, whatever the bevel and the extrusion added.
    """
    elevation = math.radians(ELEVATION_DEGREES)
    pitch = math.pi / 2.0 - elevation
    camera.location = (
        centre[0] + distance * math.cos(elevation) * math.sin(azimuth),
        centre[1] - distance * math.cos(elevation) * math.cos(azimuth),
        centre[2] + distance * math.sin(elevation),
    )
    camera.rotation_euler = (pitch, 0.0, azimuth)

    right = (math.cos(azimuth), math.sin(azimuth), 0.0)
    up = (-math.sin(azimuth) * math.cos(pitch), math.cos(azimuth) * math.cos(pitch),
          math.sin(pitch))
    half_width = half_height = 0.0
    for corner in _corners(lower, upper):
        offset = [corner[axis] - centre[axis] for axis in range(3)]
        half_width = max(half_width, abs(offset[0] * right[0] + offset[1] * right[1]))
        half_height = max(half_height, abs(offset[0] * up[0] + offset[1] * up[1]
                                        + offset[2] * up[2]))
    width, height = float(size[0]), float(size[1])
    data.ortho_scale = max(1e-3, max(2.0 * half_width,
                                    2.0 * half_height * (width / height)) * FRAME_MARGIN)


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
    spec_path, out_dir = _args()
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
    objects = _build_geometry(spec, extrude, {})
    lower, upper = _bounds(objects)
    _setup_scene(scene, render, background)
    camera, data, centre, radius, distance = _camera(scene, lower, upper)

    written = []
    for index in range(render["views"]):
        azimuth = 2.0 * math.pi * (index / render["views"])
        _aim(camera, data, lower, upper, centre, distance, azimuth, render["size"])
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
