"""Named styles: a prompt suffix and the trace preset it wants.

A style is a two-field mapping, nothing more: text appended to the prompt that
steers the generation, and the trace preset the traced sweep should use. It is
deliberately not a workflow, a graph or a preset bundle — this layer produces
sources and the pipeline traces them, so the only thing a style may influence
is the prompt text and which single preset the front half is pointed at.

Ported from the sibling chopshop-sui repo's ``scripts/swarm_bridge.py``, where
the same three built-ins lived with the same ``apply_style`` contract. The
built-ins here are a fallback, not the only source: ``load_styles`` merges a
caller-supplied JSON file over them, so a styles file can add styles or retune
the built-in ones without editing code.

Two further fields are OPTIONAL and both are advisory: ``model`` and
``modifiers``. A style that names them is saying "this subject traces well when
generated this way", which is a suggestion a caller may ignore — which is why
they are read through ``style_recipe`` and never enforced by ``apply_style``,
whose two-value contract predates them and is what every existing consumer
uses. The print styles below carry them because the whole point of a print
style is steering the *raster* toward something a tracer can follow: flat
regions, few colours, closed shapes, no gradients.

This module is stdlib-only on purpose, so it imports on a box with neither
torch nor diffusers — the same box the tests run on.
"""

from __future__ import annotations

import json
import os

from .models import ModelError

# The bundled styles file, resolved against this package's own directory rather
# than any machine's home or checkout path. A repo that hardcodes where it lives
# goes stale the moment the tree moves; this one does not name a machine.
DEFAULT_STYLES_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "styles.json")

# Built-in fallback for when no styles file is present or it cannot be read.
# Each style maps a human name to prompt-suffix text plus a trace preset, and
# optionally a suggested ``model`` and ``modifiers``.
#
# The first three are the original tonality axes (flat, mono, photographic).
# The six after them are the PRINT styles: everything about their suffix exists
# to remove the three things a tracer cannot handle — gradients, antialiased
# edges and large colour counts. That is a different goal from "looks good",
# and the suffix says so out loud, because a diffusion model left to itself
# reproduces photographic lighting with pleasure.
BUILTIN_STYLES: dict[str, dict] = {
    "flat-poster": {
        "prompt_suffix": ", flat vector poster, limited flat color palette, "
                         "clean bold shapes, no gradients, high contrast, "
                         "print-friendly screen-print art",
        "trace_preset": "poster",
    },
    "mono-line": {
        "prompt_suffix": ", black and white line art, single color ink, "
                         "solid silhouette, no gray, no gradients",
        "trace_preset": "bw",
    },
    "photo-halftone": {
        "prompt_suffix": ", photographic, soft gradients, halftone-friendly "
                         "continuous tone, detailed",
        "trace_preset": "photo",
    },
    "logo-mark": {
        "prompt_suffix": ", minimal logo mark, single flat solid fill, hard "
                         "clean edges, pure white background, no gradients, no "
                         "shading, no text, centered symbol",
        "trace_preset": "bw",
        "model": "sdxl-1.0",
        "modifiers": ["logo-redmond"],
    },
    "line-art": {
        "prompt_suffix": ", clean black line art on pure white, continuous "
                         "single-weight outline, closed shapes, high contrast "
                         "inked crest, no fills, no shading, no gradients",
        "trace_preset": "bw",
        "model": "sdxl-1.0",
    },
    "flat-vector": {
        "prompt_suffix": ", flat vector illustration, 4 to 6 solid colors, "
                         "hard edges, no gradients, no texture, no shading, "
                         "geometric poster shapes, screen-print separations",
        "trace_preset": "poster",
    },
    "sticker": {
        "prompt_suffix": ", die-cut sticker, single subject centered with a "
                         "thick solid outline, one flat background colour, no "
                         "gradients, no drop shadow, no texture",
        "trace_preset": "poster",
        "model": "sdxl-1.0",
        "modifiers": ["stickers"],
    },
    "colouring-book": {
        "prompt_suffix": ", black outline colouring book page, unfilled white "
                         "areas, uniform line weight, closed regions, no "
                         "shading, no hatching, no grey, no gradients",
        "trace_preset": "bw",
        "model": "sdxl-1.0",
        "modifiers": ["colouring-book"],
    },
    "pixel-art": {
        "prompt_suffix": ", 8-bit pixel art sprite, crisp axis-aligned pixels, "
                         "hard-edged blocks, indexed limited palette, no "
                         "antialiasing, no gradients, no blur",
        "trace_preset": "poster",
        "model": "sdxl-1.0",
        "modifiers": ["pixel-art-xl"],
    },
}


def load_styles(styles_path: str | None = None) -> dict:
    """The known styles, with any styles file merged over the built-ins.

    The built-ins are always the base, so a styles file never has to repeat
    them and a broken one never leaves the caller with nothing. A styles file
    may add a style or override an existing one by naming it again.

    A missing, unreadable or malformed file is not an error: the built-ins come
    back. Styles are a convenience, and refusing to generate because a hint
    file went missing would be the tail wagging the dog.
    """
    styles = {name: dict(entry) for name, entry in BUILTIN_STYLES.items()}
    if styles_path and os.path.exists(styles_path):
        try:
            with open(styles_path, "r", encoding="utf-8") as handle:
                extra = json.load(handle)
        except (OSError, ValueError):
            return styles
        if isinstance(extra, dict):
            for name, entry in extra.items():
                if isinstance(entry, dict):
                    styles[name] = entry
    return styles


def apply_style(style_name: str, styles_path: str | None = None) -> tuple[str, str]:
    """Return ``(prompt_suffix, trace_preset)`` for a named style.

    An unknown name is a caller error — the same class of mistake as an unknown
    model — so it raises ``ModelError`` with exit_code 2 and names the styles
    that do exist, rather than silently generating an unstyled image.
    """
    entry = style_recipe(style_name, styles_path)
    return entry.get("prompt_suffix", ""), entry.get("trace_preset", "")


def style_recipe(style_name: str, styles_path: str | None = None) -> dict:
    """The whole style entry, optional ``model``/``modifiers`` included.

    ``apply_style`` is the two-value view of this; a caller that wants a style's
    suggested model or adapters reads the entry instead. Both go through the
    same lookup so an unknown name raises the same error either way.
    """
    styles = load_styles(styles_path)
    if style_name not in styles:
        names = ", ".join(sorted(styles))
        raise ModelError("unknown style '%s' (available: %s)"
                         % (style_name, names), exit_code=2)
    return dict(styles[style_name])


def style_suggestions(style_name: str, styles_path: str | None = None) -> tuple:
    """``(model, modifiers)`` a style suggests, either of which may be None.

    Advisory, and deliberately returned as None rather than as a filled-in
    default: "this style has no opinion about the model" and "this style wants
    the default model" are different statements, and collapsing them would make
    the caller's own choice look like the style's.
    """
    entry = style_recipe(style_name, styles_path)
    return entry.get("model"), list(entry.get("modifiers") or []) or None


def style_sweep_json(trace_preset: str, target_path: str) -> str:
    """Write a single-preset sweep file driven by one style's trace preset.

    The shape is what chopshop-svg's ``front_pipeline.sh`` consumes — a sweep
    object whose ``presets`` holds exactly the one preset the style named, with
    the other axes left at the pipeline's own defaults. Writing it here rather
    than in the engine keeps the contract in one place.

    Parent directories are created, and the written path is returned.
    """
    payload = {
        "version": 1,
        "presets": [trace_preset],
        "filter_speckle": [2, 8],
        "hierarchical": ["cutout", "stacked"],
        "use_palette": [False, True],
        "max_candidates": 8,
    }
    parent = os.path.dirname(target_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(target_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    return target_path
