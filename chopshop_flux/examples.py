"""The example/test prompt set: load it, and check it against the registries.

``examples/prompts.json`` is the machine-readable half of "give us example/test
prompts"; ``scripts/smoke_examples.py`` is the half that runs them against real
weights. This module is the part in between, and it is deliberately the strict
part: every example is checked against the model, modifier and VAE registries
*before* anything is loaded, so a drifted example is a failed test on a CI box
rather than a failed load on the GPU box twenty minutes later.

Two rules here are worth stating because they are the reason the file can be
trusted at all:

* **Coverage is part of validity.** An example set that stops exercising a
  modifier is a set that will not notice when that modifier breaks. So the
  validator does not only check that each example is individually sane — it
  checks that every registered model, modifier and VAE appears somewhere.
* **The numbers must agree with the registries they came from.** An example that
  runs a distilled checkpoint off its own schedule, or asks for a resolution the
  model forbids, is a broken example however plausible its prompt reads.

stdlib only, no torch, no network: this has to import on the box that runs the
tests.
"""

from __future__ import annotations

import json
import os

from .models import ModelError, REGISTRY, resolve, validate_size
from .modifiers import MODIFIERS, VAES, resolve_modifier, resolve_vae
from .styles import style_suggestions

# The bundled example set, resolved against the repository root rather than any
# machine's home or checkout path — the same reason styles.py resolves its own
# file from its module location. One directory up from the package.
DEFAULT_EXAMPLES_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "examples", "prompts.json")

# Every key an example must carry. ``reference`` is optional and means "use
# another example's output as this one's input image", which is the only way an
# example set can express an edit without shipping a raster with it.
#
# It is a string for the ordinary one-reference edit and a LIST of strings for a
# multi-reference one, because the wire field takes both (`image` is a data URL
# or a list of them) and the one path that proves the checkpoint conditions on
# ALL its references is otherwise inexpressible in the set. One field rather
# than `reference` plus `references`: two spellings of the same idea is one
# more than the format needs, and a list of one is still a list. See
# ``reference_ids``, which is the only place that difference is interpreted.
REQUIRED_FIELDS = ("id", "model", "modifiers", "vae", "prompt",
                   "negative_prompt", "width", "height", "steps", "guidance",
                   "seed", "style", "what_it_proves")
OPTIONAL_FIELDS = ("reference",)

# The subjects the ask named. Checked as explicit predicates over structured
# fields rather than as substrings of everything concatenated: "the set contains
# the word background somewhere" is not the same claim as "the set has an edit
# example that applies the background-removal adapter to a real reference", and
# only the second one is worth asserting.
REQUIRED_SUBJECTS = {
    "a logo mark": lambda e: e.get("style") == "logo-mark",
    "a line-art crest": lambda e: e.get("style") == "line-art",
    "a flat poster": lambda e: e.get("style") == "flat-vector",
    "a sticker": lambda e: e.get("style") == "sticker",
    "a pixel sprite": lambda e: e.get("style") == "pixel-art",
    "a background-removal edit": lambda e: (
        "klein-background-remove" in (e.get("modifiers") or [])
        and bool(e.get("reference"))),
    "an img2img edit": lambda e: (
        bool(e.get("reference"))
        and resolve(e["model"]).img2img_strength),
    # A multi-reference edit, on a checkpoint that actually declares it. Without
    # this the set can only ever exercise the single-reference path, and the
    # capability stays argued-for rather than demonstrated. The registry is the
    # source of truth here, not a hardcoded model list: a model that gains
    # multi-reference is covered the day the flag flips, and one that loses it
    # fails validation rather than shipping an example the service refuses.
    "a multi-reference edit": lambda e: (
        len(reference_ids(e)) > 1
        and resolve(e["model"]).multi_reference),
}


def reference_ids(entry: dict) -> list:
    """The example ids this entry edits, in order. Always a list.

    The single place ``reference``'s two shapes are read. Callers that only need
    to know whether there IS a reference keep using ``entry.get("reference")``
    — a non-empty string and a non-empty list are both truthy — so the change is
    additive: an example set with no multi-reference entry behaves exactly as
    before, and every consumer that has not been taught about lists still gets
    a value that means "it edits something".

    Order is preserved, because it is the whole of the caller's claim: "the pose
    from the first, the palette from the second" is a distinction no consumer
    downstream can recover on its own, and the engine passes the references to
    the pipeline in the order given.
    """
    target = entry.get("reference")
    if target is None:
        return []
    if isinstance(target, str):
        return [target]
    if isinstance(target, list):
        return list(target)
    return [target]  # wrong type: _validate_references names it, don't pre-empt


def load_examples(path: str | None = None) -> list[dict]:
    """Read the example set. A missing or malformed file is an error, not a pass.

    Unlike a styles file — where a missing file falls back to the built-in three
    and generation still works — an example set IS the deliverable. An empty
    result would make every downstream check vacuous, so this raises.
    """
    target = path or DEFAULT_EXAMPLES_PATH
    if not os.path.isfile(target):
        raise ModelError("no example set at %s" % target, exit_code=2)
    try:
        with open(target, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError) as exc:
        raise ModelError("example set %s is not readable JSON: %s"
                         % (target, exc), exit_code=2) from exc
    if not isinstance(payload, list):
        raise ModelError("example set %s must be a JSON array, got %s"
                         % (target, type(payload).__name__), exit_code=2)
    for entry in payload:
        if not isinstance(entry, dict):
            raise ModelError("every example must be a JSON object, got %s"
                             % type(entry).__name__, exit_code=2)
    return payload


def coverage(entries: list[dict]) -> dict:
    """Which registry keys the set exercises, and which it misses.

    Returns ``{"models": {"covered": [...], "missing": [...]}, "modifiers": ...,
    "vaes": ...}``. Split out from ``validate_examples`` so the smoke report can
    state coverage as a measurement instead of asserting it in prose.
    """
    seen = {
        "models": {entry.get("model") for entry in entries},
        "modifiers": {m for entry in entries for m in (entry.get("modifiers") or [])},
        "vaes": {entry.get("vae") for entry in entries if entry.get("vae")},
    }
    registries = {"models": set(REGISTRY), "modifiers": set(MODIFIERS),
                  "vaes": set(VAES)}
    result = {}
    for kind, known in registries.items():
        # Resolve before comparing: an example may legitimately name an alias,
        # and reporting "sdxl-1.0 missing" because the set said "sdxl" would be
        # a false alarm. An unknown name is caught by validate_examples, which
        # runs first.
        resolved = set()
        for name in seen[kind]:
            if name in known:
                resolved.add(name)
                continue
            try:
                if kind == "models":
                    spec = resolve(name)
                    resolved.add(spec.key if spec is not None else name)
                elif kind == "modifiers":
                    mod = resolve_modifier(name)
                    resolved.add(mod.key if mod is not None else name)
                else:
                    vae = resolve_vae(name)
                    resolved.add(vae.key if vae is not None else name)
            except ModelError:
                resolved.add(name)
        result[kind] = {
            "covered": sorted(resolved & known),
            "missing": sorted(known - resolved),
        }
    return result


def validate_examples(entries: list[dict], path: str | None = None) -> dict:
    """Check every example against the registries. Raises on the first problem.

    ``path`` is only used to make the error messages name the file the set came
    from. Returns the coverage report so a caller can print what was proven
    without walking the registries itself.
    """
    where = path or DEFAULT_EXAMPLES_PATH
    if not entries:
        raise ModelError("example set %s is empty" % where, exit_code=2)

    ids = set()
    for index, entry in enumerate(entries):
        label = entry.get("id") or "#%d" % index
        _validate_one(entry, label, where, ids)
    _validate_references(entries, where)

    report = coverage(entries)
    for kind, info in report.items():
        if info["missing"]:
            raise ModelError(
                "%s exercises no %s: %s. Every registered %s must appear in at "
                "least one example, or the set cannot notice when it breaks."
                % (where, kind, ", ".join(info["missing"]), kind), exit_code=2)
    _validate_subjects(entries, where)
    return report


def _fail(where: str, label: str, message: str) -> None:
    raise ModelError("%s: example '%s': %s" % (where, label, message),
                     exit_code=2)


def _validate_one(entry: dict, label: str, where: str, ids: set) -> None:
    """One example: shape, registry resolution, size, schedule, style."""
    for field in REQUIRED_FIELDS:
        if field not in entry:
            _fail(where, label, "missing field '%s'" % field)
    unknown = set(entry) - set(REQUIRED_FIELDS) - set(OPTIONAL_FIELDS)
    if unknown:
        # A typo'd field is a field that silently does nothing, and a set that
        # silently does nothing is worse than one that fails loudly.
        _fail(where, label, "unknown field(s): %s" % ", ".join(sorted(unknown)))

    example_id = entry["id"]
    if not isinstance(example_id, str) or not example_id.strip():
        _fail(where, label, "'id' must be a non-empty string")
    if example_id in ids:
        _fail(where, label, "duplicate id '%s'" % example_id)
    ids.add(example_id)

    if not isinstance(entry["what_it_proves"], str) or not entry["what_it_proves"].strip():
        _fail(where, label, "'what_it_proves' must be one honest sentence")

    spec = resolve(entry["model"])

    modifiers = entry["modifiers"]
    if not isinstance(modifiers, list):
        _fail(where, label, "'modifiers' must be a list (use [] for none)")
    resolved_modifiers = []
    for name in modifiers:
        mod = resolve_modifier(name)
        if mod is None:
            _fail(where, label, "'modifiers' contains an empty entry")
        resolved_modifiers.append(mod)

    vae_spec = resolve_vae(entry["vae"])
    if entry["vae"] is not None and vae_spec is None:
        _fail(where, label, "'vae' contains an empty entry")

    # The model's own resolution rules, through the same function the service
    # uses — so an example cannot be valid here and a 400 over HTTP.
    try:
        validate_size(spec, entry["width"], entry["height"])
    except ModelError as exc:
        _fail(where, label, str(exc))

    steps, guidance = entry["steps"], entry["guidance"]
    if not isinstance(steps, int) or steps < 1:
        _fail(where, label, "'steps' must be a positive integer")
    if not isinstance(guidance, (int, float)) or isinstance(guidance, bool):
        _fail(where, label, "'guidance' must be a number")
    if not isinstance(entry["seed"], int) or isinstance(entry["seed"], bool):
        _fail(where, label, "'seed' must be an integer, so a run is reproducible")

    # A distilled checkpoint has exactly one correct schedule; running it at
    # another one is not a variation, it is the wrong schedule. Non-distilled
    # models are free to be explored, which is why this is a hard error only
    # where the registry already knows the answer.
    if spec.distilled and steps != spec.default_steps:
        _fail(where, label,
              "steps=%d contradicts %s's distilled schedule (%d steps)"
              % (steps, spec.key, spec.default_steps))
    if spec.distilled and float(guidance) != float(spec.default_guidance):
        _fail(where, label,
              "guidance=%s contradicts %s's distilled schedule (guidance %s)"
              % (guidance, spec.key, spec.default_guidance))

    # Two adapters asking for two different schedulers cannot both be honoured,
    # so an example that requests both is an example with a hidden coin flip.
    # Checked BEFORE the per-adapter schedule comparison below: a set that cannot
    # be honoured at all is a more fundamental problem than one that is merely
    # off-schedule, and reporting the fixable one first would hide the fact that
    # no numbering of this example works.
    schedulers = {m.scheduler for m in resolved_modifiers if m.scheduler}
    if len(schedulers) > 1:
        _fail(where, label, "modifiers ask for conflicting schedulers: %s"
              % ", ".join(sorted(schedulers)))

    # An adapter that carries its own schedule is the same case one level down:
    # LCM and Lightning ARE their distilled schedule, so an example that loads
    # one at other numbers is an example that proves nothing about the adapter.
    for mod in resolved_modifiers:
        if mod.steps is not None and steps != mod.steps:
            _fail(where, label,
                  "steps=%d contradicts modifier %s's own schedule (%d steps)"
                  % (steps, mod.key, mod.steps))
        if mod.guidance is not None and float(guidance) != float(mod.guidance):
            _fail(where, label,
                  "guidance=%s contradicts modifier %s's own schedule "
                  "(guidance %s)" % (guidance, mod.key, mod.guidance))
        if mod.scheduler and mod.scheduler not in ("lcm", "trailing-euler"):
            _fail(where, label, "modifier %s names an unknown scheduler %r"
                  % (mod.key, mod.scheduler))

    # A style carries an advisory model and modifier list. An example that names
    # a style and then ignores what it suggests is an example that tests nothing
    # about the style, so the suggestion has to be honoured — but "honoured"
    # means the same FAMILY, not the same key: the suggestion names the pipeline
    # the style was written for, and ssd-1b is that pipeline. Requiring the exact
    # key would turn an advisory field into a hard constraint.
    if entry["style"] is not None:
        try:
            style_model, style_modifiers = style_suggestions(entry["style"])
        except ModelError as exc:
            _fail(where, label, str(exc))
            return  # unreachable: _fail always raises
        if style_model is not None and resolve(style_model).pipeline != spec.pipeline:
            _fail(where, label,
                  "style '%s' suggests model %s but this example runs %s"
                  % (entry["style"], style_model, spec.key))
        for name in style_modifiers or []:
            wanted = resolve_modifier(name)
            if wanted is not None and wanted.key not in [m.key for m in resolved_modifiers]:
                _fail(where, label,
                      "style '%s' suggests modifier %s, which this example does "
                      "not request" % (entry["style"], name))

    # Warnings the service would emit for this example are acceptable only where
    # the example admits it: an adapter aimed at another family, or a VAE swap
    # onto a model it was not built for. Silence here would let the set rot into
    # examples that generate something other than what they claim.
    for mod in resolved_modifiers:
        if spec.key not in mod.targets:
            _fail(where, label,
                  "modifier %s does not target %s (targets: %s)"
                  % (mod.key, spec.key, ", ".join(mod.targets)))
    if vae_spec is not None and spec.key not in vae_spec.targets:
        _fail(where, label, "vae %s does not target %s (targets: %s)"
              % (vae_spec.key, spec.key, ", ".join(vae_spec.targets)))


def _validate_references(entries: list[dict], where: str) -> None:
    """Every ``reference`` must name another example in the same set.

    A list is walked in order, and the shape is checked here rather than being
    left to the service: an example set is the deliverable, and a set whose
    multi-reference entry names one id twice or points at a model that takes a
    single reference is a broken example that would otherwise be discovered
    twenty minutes later on the GPU box, as a 400 from the service.
    """
    ids = {entry["id"] for entry in entries}
    by_id = {entry["id"]: entry for entry in entries}
    for entry in entries:
        target = entry.get("reference")
        if target is None:
            continue
        if isinstance(target, str):
            targets = [target]
        elif isinstance(target, list):
            targets = target
        else:
            _fail(where, entry["id"],
                  "'reference' must be an example id, a list of them, or null")
            continue
        if not targets:
            _fail(where, entry["id"],
                  "'reference' is an empty list: an edit needs at least one "
                  "reference image")
        seen = set()
        for one in targets:
            if not isinstance(one, str) or not one.strip():
                _fail(where, entry["id"],
                      "'reference' must be an example id or null")
            if one == entry["id"]:
                _fail(where, entry["id"], "'reference' cannot point at itself")
            if one not in ids:
                _fail(where, entry["id"],
                      "'reference' names '%s', which is not in this set" % one)
            if one in seen:
                _fail(where, entry["id"],
                      "'reference' names '%s' twice: the same frame twice is "
                      "not a second conditioning input" % one)
            seen.add(one)
        # The checkpoint decides how many references it can take, and the
        # registry is where that is written down. Checking it here means the
        # example set cannot carry a multi-reference entry on a family that
        # refuses one — the service's own refusal is correct, but it arrives
        # as a failed run rather than as a failed example set.
        if len(targets) > 1:
            spec = resolve(entry["model"])
            if not spec.multi_reference:
                _fail(where, entry["id"],
                      "it sends %d references to %s, which takes a single "
                      "reference image; multi-reference is a property of the "
                      "checkpoint and this one does not declare it"
                      % (len(targets), spec.key))
        for one in targets:
            if by_id[one].get("reference"):
                _fail(where, entry["id"],
                      "'reference' names '%s', which is itself an edit. A chain "
                      "must terminate: this repo's set expresses one edit of a "
                      "generated frame, not a pipeline of them" % one)


def _validate_subjects(entries: list[dict], where: str) -> None:
    """The named print subjects must each appear somewhere in the set."""
    missing = []
    for name, predicate in sorted(REQUIRED_SUBJECTS.items()):
        matched = False
        for entry in entries:
            try:
                if predicate(entry):
                    matched = True
                    break
            except ModelError:
                # An unresolvable model is already an error from _validate_one;
                # this pass must not raise a worse message first.
                continue
        if not matched:
            missing.append(name)
    if missing:
        raise ModelError(
            "%s has no example for: %s" % (where, ", ".join(missing)),
            exit_code=2)
