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
# Each style maps a human name to prompt-suffix text plus a trace preset.
BUILTIN_STYLES: dict[str, dict[str, str]] = {
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
    styles = load_styles(styles_path)
    if style_name not in styles:
        names = ", ".join(sorted(styles))
        raise ModelError("unknown style '%s' (available: %s)"
                         % (style_name, names), exit_code=2)
    entry = styles[style_name]
    return entry.get("prompt_suffix", ""), entry.get("trace_preset", "")


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
