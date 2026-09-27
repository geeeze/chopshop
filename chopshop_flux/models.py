"""The model registry: what we can run, and what running it commits you to.

Every field here is a verified fact, not a guess, and the ones that constrain
behaviour are the licence and the VRAM. The two are related in a way that is
easy to get wrong: the *smaller* model is the one you are allowed to sell
output from.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import config

# Licence strings as they actually appear on the model cards. Kept verbatim so a
# grep for the licence finds the thing the licence is called.
APACHE_2 = "Apache-2.0"
FLUX_NONCOMMERCIAL = "FLUX Non-Commercial License v2.1"


@dataclass(frozen=True)
class ModelSpec:
    key: str
    repo_id: str
    params_b: float
    license: str
    commercial_ok: bool
    vram_gb: float
    repo_bytes: float
    layout: str            # "diffusers" (what from_pretrained needs) or "single-file"
    default_steps: int
    default_guidance: float
    distilled: bool
    gated: bool = False     # HF gates these, so a token is required to fetch them
    aliases: tuple[str, ...] = ()
    notes: str = ""

    @property
    def is_default(self) -> bool:
        return self.key == DEFAULT_MODEL_KEY


# FLUX.2 [klein] is step-distilled: 4 inference steps at guidance 1.0. The
# pipeline class defaults (50 steps, guidance 4.0) are the *base* model's, so
# they must always be passed explicitly — omitting them is not "using defaults",
# it is running the wrong schedule.
#
# There is no negative_prompt parameter on Flux2KleinPipeline.__call__ at all.
# The negative prompt has no effect on a distilled klein, so a caller asking for
# one is asking for something the model does not have; the service says so
# rather than accepting a parameter it silently drops.
REGISTRY: dict[str, ModelSpec] = {
    "klein-4b": ModelSpec(
        key="klein-4b",
        repo_id="black-forest-labs/FLUX.2-klein-4B",
        params_b=4,
        license=APACHE_2,
        commercial_ok=True,
        vram_gb=13.0,
        repo_bytes=15.98e9,
        layout="diffusers",
        default_steps=4,
        default_guidance=1.0,
        distilled=True,
        aliases=("4b", "klein", "klein4b", "klein-4B"),
        notes="Apache 2.0, so generated output is yours to sell. The default.",
    ),
    "klein-4b-base": ModelSpec(
        key="klein-4b-base",
        repo_id="black-forest-labs/FLUX.2-klein-base-4B",
        params_b=4,
        license=APACHE_2,
        commercial_ok=True,
        vram_gb=13.0,
        repo_bytes=16.0e9,
        layout="diffusers",
        # Undistilled: it preserves the full training signal, which is why it is
        # the fine-tuning starting point — and why guidance > 1.0 works on it.
        default_steps=28,
        default_guidance=4.0,
        distilled=False,
        aliases=("4b-base", "klein-base", "base-4b"),
        notes="Undistilled sibling of klein-4b. Slower, but guidance > 1.0 and "
              "a negative prompt actually do something.",
    ),
    "klein-9b": ModelSpec(
        key="klein-9b",
        repo_id="black-forest-labs/FLUX.2-klein-9B",
        params_b=9,
        license=FLUX_NONCOMMERCIAL,
        commercial_ok=False,
        vram_gb=24.0,
        repo_bytes=18.16e9,
        layout="diffusers",
        default_steps=4,
        default_guidance=1.0,
        distilled=True,
        gated=True,
        aliases=("9b", "klein9b"),
        notes="NON-COMMERCIAL: local/non-commercial use only. HF gates it, so a "
              "token is needed. ~24 GB VRAM at bf16 against a 17 GB card, so it "
              "only runs with CPU offload.",
    ),
}


# These exist, and are deliberately NOT registered as loadable models.
#
# Both are single-file builds with no model_index.json, so
# Flux2KleinPipeline.from_pretrained cannot load them at all: they are ComfyUI's
# format. Registering them would produce a model that appears selectable and
# fails at load time. Listed here so the answer to "can we just use the fp8 one?"
# is written down instead of re-derived.
UNLOADABLE: dict[str, str] = {
    "klein-9b-fp8": "black-forest-labs/FLUX.2-klein-9b-fp8 (9.43 GB) is a "
                    "single-file build with no model_index.json — a ComfyUI "
                    "format. diffusers needs from_single_file plus a matching "
                    "text encoder and VAE, which that repo does not ship.",
    "klein-9b-nvfp4": "black-forest-labs/FLUX.2-klein-9b-nvfp4 (5.76 GB) is "
                      "single-file NVFP4, and NVFP4 is an NVIDIA format — not "
                      "runnable on this ROCm box.",
}

DEFAULT_MODEL_KEY = "klein-4b"


class ModelError(Exception):
    """A model cannot be resolved, or cannot be used as asked."""

    def __init__(self, message: str, exit_code: int = 2):
        super().__init__(message)
        self.exit_code = exit_code


def resolve(name: str | None) -> ModelSpec:
    """Look up a model by key or alias. ``None`` means the default."""
    if name is None or str(name).strip() == "":
        return REGISTRY[DEFAULT_MODEL_KEY]
    wanted = str(name).strip()
    if wanted in REGISTRY:
        return REGISTRY[wanted]
    lowered = wanted.lower()
    for spec in REGISTRY.values():
        if lowered == spec.key.lower() or lowered in (a.lower() for a in spec.aliases):
            return spec
    if lowered in UNLOADABLE:
        raise ModelError("'%s' cannot be loaded by this service. %s"
                         % (wanted, UNLOADABLE[lowered]))
    known = ", ".join(sorted(REGISTRY))
    raise ModelError("unknown model '%s' (known: %s)" % (wanted, known))


def check_usable(spec: ModelSpec, *, ack: bool | None = None) -> None:
    """Raise if this model must not be loaded in this configuration.

    The licence check is here rather than in the view because it is a property
    of the model, and it must hold on every path that loads one.
    """
    if spec.commercial_ok:
        return
    if ack is None:
        ack = config.ack_noncommercial()
    if not ack:
        raise ModelError(
            "%s is %s — non-commercial use only. Loading it requires an explicit "
            "acknowledgement (CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1) so a commercial "
            "deployment cannot happen by accident; commercial use of its output "
            "requires a licence from Black Forest Labs."
            % (spec.key, spec.license), exit_code=2)


def validate_size(spec: ModelSpec, width: int, height: int,
                  *, max_pixels: int | None = None) -> None:
    """Enforce FLUX.2's own resolution rules, in one place.

    Multiples of 16, at least 64 on a side, at most max_pixels total. These are
    the model's constraints; a request that violates them is a caller error, not
    a generation failure, so it is reported as such.
    """
    for label, value in (("width", width), ("height", height)):
        if not isinstance(value, int):
            raise ModelError("%s must be an integer, got %r" % (label, value))
        if value < config.MIN_DIMENSION:
            raise ModelError("%s must be at least %d, got %d"
                             % (label, config.MIN_DIMENSION, value))
        if value % config.DIMENSION_MULTIPLE:
            raise ModelError("%s must be a multiple of %d, got %d"
                             % (label, config.DIMENSION_MULTIPLE, value))
    cap = config.max_pixels() if max_pixels is None else max_pixels
    if width * height > cap:
        raise ModelError("%dx%d is %d pixels, over the %d cap"
                         % (width, height, width * height, cap))


def as_dict(spec: ModelSpec) -> dict:
    """The registry entry as the API reports it."""
    return {
        "key": spec.key,
        "repo_id": spec.repo_id,
        "params_b": spec.params_b,
        "license": spec.license,
        "commercial_ok": spec.commercial_ok,
        "vram_gb": spec.vram_gb,
        "repo_bytes": spec.repo_bytes,
        "layout": spec.layout,
        "default_steps": spec.default_steps,
        "default_guidance": spec.default_guidance,
        "distilled": spec.distilled,
        "gated": spec.gated,
        "default": spec.is_default,
        "notes": spec.notes,
    }


def all_as_dict() -> list[dict]:
    return [as_dict(REGISTRY[k]) for k in sorted(REGISTRY)]
