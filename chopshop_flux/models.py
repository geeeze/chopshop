"""The model registry: what we can run, and what running it commits you to.

Every field here is a verified fact, not a guess, and the ones that constrain
behaviour are the licence and the VRAM. Which licence a model carries is not
guessable from the outside: the *fastest* entry in this registry, sdxl-turbo,
is the one whose output may not be sold.

The registry is no longer klein-only. It spans several diffusers families —
FLUX.2 [klein], Stable Diffusion XL and Stable Diffusion 1.5 — and each family
brings its own pipeline class, its own resolution rules and its own calling
convention. Those live on the ``ModelSpec`` rather than in module-level
constants, because a single set of constants would silently apply one family's
rules to another.

This registry is hand-mirrored, and nothing syncs it. chopshop-studio cannot
import this module, so ``app/models/flux_conf.rb`` transcribes it and the
studio's FLUX page renders that copy: the model ids (its ``MODELS`` and
``DEFAULT_MODEL_KEY``), the per-family dimension constraints (``MIN_DIMENSION``,
``DIMENSION_MULTIPLE``, ``DEFAULT_MAX_PIXELS``, and each entry's
``dim_multiple``/``min_dim``/``max_pixels``), every default an entry carries
(``default_steps``, ``default_guidance``, ``distilled``, ``commercial_ok``,
``pipeline``/``edit_pipeline``) and the service's route list
(``API[:routes]``). That page therefore speaks with this file's authority while
being a copy of it — an edit here with no matching edit there silently makes the
studio claim facts this service no longer has. This file is the source; the
studio is the mirror and drifts in silence.
"""

from __future__ import annotations

from dataclasses import dataclass

from . import config

# Licence strings as they actually appear on the model cards. Kept verbatim so a
# grep for the licence finds the thing the licence is called. The card's
# ``cardData.license`` is often only a slug (``openrail++``, ``other``), which
# does not name the licence, so these are the human-readable names the cards and
# their LICENSE files actually use.
APACHE_2 = "Apache-2.0"
SDXL_OPENRAIL_PP = "CreativeML Open RAIL++-M License"
SDXL_TURBO_NONCOMMERCIAL = "Stability AI Non-Commercial Research Community License"
SD15_OPENRAIL_M = "CreativeML Open RAIL-M License"


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

    # -- family-specific behaviour -----------------------------------------
    # Not every diffusers family loads the same class or obeys the same rules,
    # so the pipeline class, the resolution rules and the calling convention are
    # per-model. The defaults are the FLUX.2 [klein] family's — what this
    # service did when it was klein-only — so an entry that does not name them
    # keeps behaving exactly as it used to.
    pipeline: str = "Flux2KleinPipeline"    # diffusers class to import() at load
    # A family that splits text-to-image and image-to-image across two diffusers
    # classes (SDXL, SD 1.5) names its edit class here. The engine loads THIS
    # class for a request carrying a reference, and `pipeline` for one without.
    # None means one class serves both (Flux2KleinPipeline's unified image=).
    edit_pipeline: str | None = None
    dim_multiple: int = config.DIMENSION_MULTIPLE
    min_dim: int = config.MIN_DIMENSION
    max_pixels: int = config.DEFAULT_MAX_PIXELS
    negative_prompt: bool = False   # __call__ accepts a negative_prompt kwarg
    img2img_strength: bool = False  # img2img uses SD-style image= + strength=
                                    # instead of klein's unified image= (None = t2i)

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
#
# The other families set their own pipeline/dim_multiple/min_dim/max_pixels and
# flip negative_prompt/img2img_strength on: SDXL and SD 1.5 are multiples of 8,
# floor 128, and take an SD-style negative_prompt + img2img strength.
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
    "sdxl-1.0": ModelSpec(
        key="sdxl-1.0",
        repo_id="stabilityai/stable-diffusion-xl-base-1.0",
        params_b=3.5,
        license=SDXL_OPENRAIL_PP,
        commercial_ok=True,
        vram_gb=8.0,
        repo_bytes=13.9e9,
        layout="diffusers",
        default_steps=30,
        default_guidance=5.0,
        distilled=False,
        aliases=("sdxl", "xl", "sdxl-base"),
        pipeline="StableDiffusionXLPipeline",
        edit_pipeline="StableDiffusionXLImg2ImgPipeline",
        dim_multiple=8,
        min_dim=128,
        max_pixels=2 * 1024 * 1024,
        negative_prompt=True,
        img2img_strength=True,
        notes="OpenRAIL++-M, so generated output is commercially usable. "
              "vram_gb and repo_bytes are ESTIMATES, not measurements. "
              "SD-style: takes a real negative_prompt, and img2img takes a "
              "strength.",
    ),
    "sdxl-turbo": ModelSpec(
        key="sdxl-turbo",
        repo_id="stabilityai/sdxl-turbo",
        params_b=3.5,
        license=SDXL_TURBO_NONCOMMERCIAL,
        commercial_ok=False,
        vram_gb=8.0,
        repo_bytes=13.9e9,
        layout="diffusers",
        default_steps=2,
        default_guidance=0.0,
        distilled=True,
        aliases=("turbo", "sdxl-turbo"),
        pipeline="StableDiffusionXLPipeline",
        edit_pipeline="StableDiffusionXLImg2ImgPipeline",
        dim_multiple=8,
        min_dim=128,
        max_pixels=1024 * 1024,
        negative_prompt=True,
        img2img_strength=True,
        notes="NON-COMMERCIAL: Stability AI's non-commercial research community "
              "licence — a token is not needed but an acknowledgement is "
              "(CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1). A 2-step distilled SDXL, so "
              "classifier-free guidance never runs. vram_gb and repo_bytes are "
              "ESTIMATES, not measurements.",
    ),
    "sd-1.5": ModelSpec(
        key="sd-1.5",
        repo_id="stable-diffusion-v1-5/stable-diffusion-v1-5",
        params_b=0.86,
        license=SD15_OPENRAIL_M,
        commercial_ok=True,
        vram_gb=4.0,
        repo_bytes=5.5e9,
        layout="diffusers",
        default_steps=30,
        default_guidance=7.5,
        distilled=False,
        aliases=("sd15", "sd1.5", "sd"),
        pipeline="StableDiffusionPipeline",
        edit_pipeline="StableDiffusionImg2ImgPipeline",
        dim_multiple=8,
        min_dim=128,
        max_pixels=1024 * 1024,
        negative_prompt=True,
        img2img_strength=True,
        notes="OpenRAIL-M, so generated output is commercially usable. "
              "vram_gb and repo_bytes are ESTIMATES, not measurements. "
              "SD-style: takes a real negative_prompt, and img2img takes a "
              "strength.",
    ),
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
            "requires a licence from the model's licensor."
            % (spec.key, spec.license), exit_code=2)


def validate_size(spec: ModelSpec, width: int, height: int,
                  *, max_pixels: int | None = None) -> None:
    """Enforce the model's own resolution rules, in one place.

    Multiples of ``spec.dim_multiple``, at least ``spec.min_dim`` on a side, at
    most ``spec.max_pixels`` (or an explicit override) in total. These are the
    model's constraints and they differ per family — FLUX.2 [klein] wants
    multiples of 16 from 64 up to 4 MP, SDXL multiples of 8 from 128 up to
    2 MP — so they come from the spec rather than a single global constant. A
    request that violates them is a caller error, not a generation failure, so
    it is reported as such.
    """
    for label, value in (("width", width), ("height", height)):
        if not isinstance(value, int):
            raise ModelError("%s must be an integer, got %r" % (label, value))
        if value < spec.min_dim:
            raise ModelError("%s must be at least %d, got %d"
                             % (label, spec.min_dim, value))
        if value % spec.dim_multiple:
            raise ModelError("%s must be a multiple of %d, got %d"
                             % (label, spec.dim_multiple, value))
    cap = spec.max_pixels if max_pixels is None else max_pixels
    # A configured global ceiling only ever lowers a cap.
    global_cap = config.max_pixels()
    if global_cap is not None and global_cap < cap:
        cap = global_cap
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
        "pipeline": spec.pipeline,
        "edit_pipeline": spec.edit_pipeline,
        "dim_multiple": spec.dim_multiple,
        "min_dim": spec.min_dim,
        "max_pixels": spec.max_pixels,
        "negative_prompt": spec.negative_prompt,
        "img2img_strength": spec.img2img_strength,
    }


def all_as_dict() -> list[dict]:
    return [as_dict(REGISTRY[k]) for k in sorted(REGISTRY)]
