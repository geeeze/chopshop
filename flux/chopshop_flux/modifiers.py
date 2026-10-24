"""LoRA adapters and VAE swaps: the two ways a registered model is *modified*.

The model registry answers "what can we run". This one answers "what can we put
on top of it", which is a different question with a different licence surface: a
LoRA is a separate work with its own terms, and bolting one onto an Apache-2.0
checkpoint does not launder it. So every entry carries its own
``commercial_ok`` and goes through the same gate as a model
(``check_usable``) rather than a weaker one.

Two shapes, deliberately not one:

* a LoRA is a *weight file* — a repo can hold several (`ByteDance/SDXL-Lightning`
  holds 2-, 4- and 8-step adapters), so the file name is part of the identity
  and two registry entries may share a ``repo_id``.
* a VAE is a *whole module* loaded with ``from_pretrained`` against the repo
  itself, so its identity is the repo.

The other difference that matters is ordering. A LoRA can be loaded onto a
pipeline at any point before the device map is built; the VAE cannot be swapped
in afterwards, because accelerate's offload map is built over the original VAE
and the replacement stays on CPU — the failure surfaces as a device mismatch
inside the scheduler, naming everything except the VAE. ``engine.load`` applies
both *before* the offload for that reason, and the sequence is pinned by a test.

stdlib only, and no torch: this module has to import on the box that runs the
tests, which has neither torch nor a GPU.
"""

from __future__ import annotations

from dataclasses import dataclass

from . import config
from .models import (APACHE_2, MIT, SD15_OPENRAIL_M, SDXL_OPENRAIL_PP,
                     ModelError)

# Re-exported so a caller has one import for "the licences this layer knows",
# and so ``modifiers.SD15_OPENRAIL_M`` does not look like a second definition of
# the same licence string.
__all__ = [
    "ModifierSpec", "VAESpec", "MODIFIERS", "VAES", "SD15_OPENRAIL_M",
    "SDXL_OPENRAIL_PP", "APACHE_2", "MIT",
    "resolve_modifier", "resolve_vae", "check_modifier_usable",
    "as_dict", "all_as_dict",
]

# The scheduler values a modifier may name. A string rather than a scheduler
# class, because naming a diffusers class at import time would put diffusers in
# this module's imports — and this module must import with no GPU stack at all.
SCHEDULERS = ("lcm", "trailing-euler")


@dataclass(frozen=True)
class ModifierSpec:
    """A LoRA adapter: which repo, which file in it, and what it changes."""

    key: str
    repo_id: str
    weight_name: str          # the exact file ``load_lora_weights`` resolves
    targets: tuple[str, ...]  # model keys this adapter is built for
    license: str
    commercial_ok: bool
    repo_bytes: float         # the weight file's size, not the repo total
    steps: int | None = None      # the schedule this adapter wants, if it has one
    guidance: float | None = None  # and the guidance it was trained for
    # "lcm" | "trailing-euler" | None. The LCM adapters need LCMScheduler and
    # the Lightning ones need Euler with trailing timestep spacing; loading
    # either without its scheduler produces noise, not a faster image, so the
    # requirement travels with the adapter instead of being folklore.
    scheduler: str | None = None
    scale: float = 1.0        # adapter weight when the caller does not give one
    aliases: tuple[str, ...] = ()
    notes: str = ""

    @property
    def is_default(self) -> bool:
        return False


@dataclass(frozen=True)
class VAESpec:
    """A VAE swap: a whole autoencoder repo, loaded with from_pretrained."""

    key: str
    repo_id: str
    targets: tuple[str, ...]
    license: str
    commercial_ok: bool
    repo_bytes: float
    # A TAESD-style tiny autoencoder. It loads through AutoencoderTiny rather
    # than AutoencoderKL — a different class, not a smaller checkpoint of the
    # same thing — and it decodes visibly softer, so it is a trade rather than a
    # free speed-up.
    tiny: bool = False
    aliases: tuple[str, ...] = ()
    notes: str = ""

    @property
    def is_default(self) -> bool:
        return False


# Every LoRA here was enumerated against the HuggingFace API this session: the
# ``weight_name`` is the exact ``rfilename`` the repo's tree reports, and
# ``repo_bytes`` is that file's size in bytes. Two of these repos ship a second,
# comfy-converted copy of the same adapter; the diffusers-format file is the one
# named here, because ``load_lora_weights`` is what reads it.
#
# ``targets`` names model keys, never repo ids, and every key in every targets
# tuple exists in models.REGISTRY — a test pins that, because a typo here would
# otherwise only show up as "that adapter did nothing" on the GPU.
MODIFIERS: dict[str, ModifierSpec] = {
    # -- the klein edit adapters (Apache-2.0) -------------------------------
    "klein-background-remove": ModifierSpec(
        key="klein-background-remove",
        repo_id="fal/flux-2-klein-4B-background-remove-lora",
        weight_name="flux-background-remove-lora.safetensors",
        targets=("klein-4b", "klein-4b-base"),
        license=APACHE_2,
        commercial_ok=True,
        repo_bytes=76.0e6,
        aliases=("background-remove", "klein-bg-remove"),
        notes="Apache-2.0, same licence as the checkpoint it adapts. "
              "Background removal as an edit — pair it with an /edit call "
              "rather than a text-to-image one.",
    ),
    "klein-object-remove": ModifierSpec(
        key="klein-object-remove",
        repo_id="fal/flux-2-klein-4B-object-remove-lora",
        weight_name="flux-object-remove-lora.safetensors",
        targets=("klein-4b", "klein-4b-base"),
        license=APACHE_2,
        commercial_ok=True,
        repo_bytes=58.4e6,
        aliases=("object-remove", "klein-object-rm"),
        notes="Apache-2.0. Removes a named object from a reference image; the "
              "prompt names what to drop.",
    ),
    "klein-outpaint": ModifierSpec(
        key="klein-outpaint",
        repo_id="fal/flux-2-klein-4B-outpaint-lora",
        weight_name="flux-outpaint-lora.safetensors",
        targets=("klein-4b", "klein-4b-base"),
        license=APACHE_2,
        commercial_ok=True,
        repo_bytes=76.0e6,
        aliases=("outpaint", "klein-extend"),
        notes="Apache-2.0. Extends a reference image outward — the one adaptor "
              "here whose useful output is a LARGER canvas than its input.",
    ),
    "klein-spritesheet": ModifierSpec(
        key="klein-spritesheet",
        repo_id="fal/flux-2-klein-4b-spritesheet-lora",
        weight_name="flux-spritesheet-lora.safetensors",
        targets=("klein-4b", "klein-4b-base"),
        license=APACHE_2,
        commercial_ok=True,
        repo_bytes=76.0e6,
        aliases=("spritesheet", "klein-sprite"),
        notes="Apache-2.0. Lays a subject out as a sprite sheet — flat cells on "
              "a plain background, which is a good raster to trace.",
    ),

    # -- the SDXL speed adapters (OpenRAIL++) -------------------------------
    # ByteDance/SDXL-Lightning is one repo holding three LoRAs. There is no
    # 1-step LoRA: the 1-step artifact is a full ~5.1 GB UNet, which is a
    # replacement model rather than a modifier, so it is not registered here.
    "sdxl-lightning-4step": ModifierSpec(
        key="sdxl-lightning-4step",
        repo_id="ByteDance/SDXL-Lightning",
        weight_name="sdxl_lightning_4step_lora.safetensors",
        targets=("sdxl-1.0", "ssd-1b"),
        license=SDXL_OPENRAIL_PP,
        commercial_ok=True,
        repo_bytes=393.9e6,
        steps=4,
        guidance=0.0,
        scheduler="trailing-euler",
        aliases=("lightning-4", "sdxl-lightning-4"),
        notes="CreativeML Open RAIL++-M, matching SDXL itself. Requires "
              "EulerDiscreteScheduler with timestep_spacing='trailing' — a "
              "distilled adapter run on the base scheduler produces noise, not "
              "a cheap image. Guidance 0.0: it is trained without CFG.",
    ),
    "sdxl-lightning-2step": ModifierSpec(
        key="sdxl-lightning-2step",
        repo_id="ByteDance/SDXL-Lightning",
        weight_name="sdxl_lightning_2step_lora.safetensors",
        targets=("sdxl-1.0", "ssd-1b"),
        license=SDXL_OPENRAIL_PP,
        commercial_ok=True,
        repo_bytes=393.9e6,
        steps=2,
        guidance=0.0,
        scheduler="trailing-euler",
        aliases=("lightning-2", "sdxl-lightning-2"),
        notes="CreativeML Open RAIL++-M. The 2-step sibling of the 4-step "
              "adapter, same scheduler requirement. Fewer steps is not free: "
              "under CPU offload the per-step compute is not the bottleneck, so "
              "the wall-clock difference is far smaller than 2:4 suggests.",
    ),
    "sdxl-lightning-8step": ModifierSpec(
        key="sdxl-lightning-8step",
        repo_id="ByteDance/SDXL-Lightning",
        weight_name="sdxl_lightning_8step_lora.safetensors",
        targets=("sdxl-1.0", "ssd-1b"),
        license=SDXL_OPENRAIL_PP,
        commercial_ok=True,
        repo_bytes=393.9e6,
        steps=8,
        guidance=0.0,
        scheduler="trailing-euler",
        aliases=("lightning-8", "sdxl-lightning-8"),
        notes="CreativeML Open RAIL++-M. The 8-step adapter: the slowest of the "
              "three and the one whose output needs the least luck.",
    ),
    "lcm-lora-sdxl": ModifierSpec(
        key="lcm-lora-sdxl",
        repo_id="latent-consistency/lcm-lora-sdxl",
        weight_name="pytorch_lora_weights.safetensors",
        targets=("sdxl-1.0", "ssd-1b"),
        license=SDXL_OPENRAIL_PP,
        commercial_ok=True,
        repo_bytes=393.9e6,
        steps=4,
        guidance=1.0,
        scheduler="lcm",
        aliases=("lcm-sdxl", "lcm"),
        notes="CreativeML Open RAIL++-M (the card's slug is 'openrail++', and "
              "'CreativeML Open RAIL++-M' is the name its parent SDXL cards "
              "spell out; no LICENSE file of its own is served). Needs "
              "LCMScheduler. Guidance 1.0 rather than 0: LCM LoRA is trained "
              "with no CFG, and the LCM author's own guidance for a CFG model "
              "is to disable it or stay in 1.0-2.0.",
    ),
    "lcm-lora-sd15": ModifierSpec(
        key="lcm-lora-sd15",
        repo_id="latent-consistency/lcm-lora-sdv1-5",
        weight_name="pytorch_lora_weights.safetensors",
        targets=("sd-1.5",),
        license=SD15_OPENRAIL_M,
        commercial_ok=True,
        repo_bytes=134.6e6,
        steps=4,
        guidance=1.0,
        scheduler="lcm",
        aliases=("lcm-sd15", "lcm-1.5"),
        notes="CreativeML Open RAIL-M, matching SD 1.5 itself. Built for "
              "runwayml/stable-diffusion-v1-5; the registry's sd-1.5 is that "
              "checkpoint's continuation, so the adapater's own base model "
              "matches. Needs LCMScheduler; supports 2-8 steps.",
    ),

    # -- the SDXL style adapters (CreativeML Open RAIL-M) -------------------
    # These four cards carry the slug ``creativeml-openrail-m``, whose text is
    # the Open RAIL-M licence — the same licence SD 1.5 carries. They are the
    # reason the modifier registry needs its own licence field rather than
    # inheriting SDXL's: putting one of these on sdxl-1.0 changes the terms of
    # what comes out.
    "pixel-art-xl": ModifierSpec(
        key="pixel-art-xl",
        repo_id="nerijs/pixel-art-xl",
        weight_name="pixel-art-xl.safetensors",
        targets=("sdxl-1.0", "ssd-1b"),
        license=SD15_OPENRAIL_M,
        commercial_ok=True,
        repo_bytes=170.5e6,
        steps=8,
        guidance=1.5,
        aliases=("pixel-art", "pixelart-xl"),
        notes="CreativeML Open RAIL-M. The card states its own schedule — "
              "'Use 8 steps and guidance scale of 1.5' — so this entry's steps "
              "and guidance are the card's numbers, not an inference. Pixel "
              "grids are the easiest thing on this list to trace.",
    ),
    "logo-redmond": ModifierSpec(
        key="logo-redmond",
        repo_id="artificialguybr/LogoRedmond-LogoLoraForSDXL-V2",
        weight_name="LogoRedmondV2-Logo-LogoRedmAF.safetensors",
        targets=("sdxl-1.0", "ssd-1b"),
        license=SD15_OPENRAIL_M,
        commercial_ok=True,
        repo_bytes=170.5e6,
        aliases=("logo", "logo-lora", "redmond-logo"),
        notes="CreativeML Open RAIL-M. Logo marks: flat fills, few colours, "
              "closed shapes. The card names no step/guidance schedule, so this "
              "entry leaves both unset and the model's own defaults apply.",
    ),
    "colouring-book": ModifierSpec(
        key="colouring-book",
        repo_id="artificialguybr/ColoringBookRedmond-V2",
        weight_name="ColoringBookRedmond-ColoringBook-ColoringBookAF.safetensors",
        targets=("sdxl-1.0", "ssd-1b", "sd-1.5"),
        license=SD15_OPENRAIL_M,
        commercial_ok=True,
        repo_bytes=170.5e6,
        aliases=("coloring-book", "colouring", "coloring"),
        notes="CreativeML Open RAIL-M. Targets sd-1.5 as well as the SDXL pair, "
              "because a 1.5-shaped adapter is the one thing here that fits the "
              "smallest model. Outline art on white: the closest thing to a "
              "trace-ready raster in the registry.",
    ),
    "stickers": ModifierSpec(
        key="stickers",
        repo_id="artificialguybr/StickersRedmond",
        weight_name="StickersRedmond.safetensors",
        targets=("sdxl-1.0", "ssd-1b", "sd-1.5"),
        license=SD15_OPENRAIL_M,
        commercial_ok=True,
        repo_bytes=170.5e6,
        aliases=("sticker", "redmond-stickers"),
        notes="CreativeML Open RAIL-M. Sticker shapes: one subject, a hard "
              "outline, a flat fill behind it. Also targets sd-1.5.",
    ),
    "papercut-sdxl": ModifierSpec(
        key="papercut-sdxl",
        repo_id="TheLastBen/Papercut_SDXL",
        weight_name="papercut.safetensors",
        targets=("sdxl-1.0", "ssd-1b"),
        license=SD15_OPENRAIL_M,
        commercial_ok=True,
        repo_bytes=340.8e6,
        aliases=("papercut",),
        notes="CreativeML Open RAIL-M. 340 MB rather than the ~170 MB the other "
              "style adapters weigh, so it is a full-rank adapter and not a "
              "rank-8 one. Layered-paper look: solid shapes with visible "
              "occlusion edges.",
    ),
}


# ``repo_bytes`` here is the DOWNLOAD — the safetensors the loader actually
# fetches plus its config — not the repo's total across precisions. That
# distinction is the difference between 334 MB and 1.3 GB for the fp16-fix VAE,
# and quoting the larger number would make every one of these look like a swap
# nobody can afford.
VAES: dict[str, VAESpec] = {
    "sdxl-vae-fp16-fix": VAESpec(
        key="sdxl-vae-fp16-fix",
        repo_id="madebyollin/sdxl-vae-fp16-fix",
        targets=("sdxl-1.0", "ssd-1b"),
        license=MIT,
        commercial_ok=True,
        repo_bytes=334.7e6,
        aliases=("fp16-fix", "sdxl-vae-fix"),
        notes="MIT. The same VAE SDXL ships, retrained so it does not overflow "
              "in fp16 — the repo's own reason for existing. 334.7 MB is the "
              "single diffusion_pytorch_model.safetensors the loader fetches, "
              "not the repo's 1.34 GB total across its fp16/unpacked copies. "
              "Byte-for-byte a drop-in, so a swap here buys numerical range, not "
              "a different look.",
    ),
    "sdxl-vae": VAESpec(
        key="sdxl-vae",
        repo_id="stabilityai/sdxl-vae",
        targets=("sdxl-1.0", "ssd-1b"),
        license=MIT,
        commercial_ok=True,
        repo_bytes=334.7e6,
        aliases=("sdxl-vae-original",),
        notes="MIT. The VAE SDXL was released with, standalone. Mostly useful as "
              "the way back after a swap, and as the control when comparing "
              "another decode against the one the pipeline came with.",
    ),
    "sd-vae-ft-mse": VAESpec(
        key="sd-vae-ft-mse",
        repo_id="stabilityai/sd-vae-ft-mse",
        targets=("sd-1.5",),
        license=MIT,
        commercial_ok=True,
        repo_bytes=334.7e6,
        aliases=("vae-ft-mse", "sd15-vae"),
        notes="MIT. The fine-tuned MSE VAE for SD 1.5 — smoother than the "
              "original, which is a real difference in flat areas and therefore "
              "in what a tracer sees.",
    ),
    "taesdxl": VAESpec(
        key="taesdxl",
        repo_id="madebyollin/taesdxl",
        targets=("sdxl-1.0", "ssd-1b"),
        license=MIT,
        commercial_ok=True,
        repo_bytes=9.8e6,
        tiny=True,
        aliases=("taesd-xl", "tiny-sdxl"),
        notes="MIT. A TAESD: a tiny distilled autoencoder, ~30x smaller, loaded "
              "through AutoencoderTiny rather than AutoencoderKL — a different "
              "class, not a smaller file. **It decodes visibly softer**, so this "
              "is a speed-for-quality trade, not a free swap, and the softness "
              "lands exactly where a tracer needs hard edges.",
    ),
    "taesd": VAESpec(
        key="taesd",
        repo_id="madebyollin/taesd",
        targets=("sd-1.5",),
        license=MIT,
        commercial_ok=True,
        repo_bytes=9.8e6,
        tiny=True,
        aliases=("taesd-15", "tiny-15"),
        notes="MIT. The SD 1.5 TAESD, same trade as taesdxl: ~30x smaller and "
              "visibly softer. Loads through AutoencoderTiny.",
    ),
}


def _resolve(name: str | None, registry: dict, kind: str):
    """Shared lookup: key, then alias, case-insensitively. ``None`` means none."""
    if name is None or str(name).strip() == "":
        return None
    wanted = str(name).strip()
    if wanted in registry:
        return registry[wanted]
    lowered = wanted.lower()
    for spec in registry.values():
        if lowered == spec.key.lower() or lowered in (a.lower() for a in spec.aliases):
            return spec
    known = ", ".join(sorted(registry))
    raise ModelError("unknown %s '%s' (known: %s)" % (kind, wanted, known))


def resolve_modifier(name: str | None) -> ModifierSpec | None:
    """Look up a LoRA by key or alias. ``None`` means "no modifier".

    There is deliberately no default modifier: a default would be a silent
    change to every existing request's output.
    """
    return _resolve(name, MODIFIERS, "modifier")


def resolve_vae(name: str | None) -> VAESpec | None:
    """Look up a VAE by key or alias. ``None`` means "the model's own VAE"."""
    return _resolve(name, VAES, "vae")


def check_modifier_usable(spec, *, ack: bool | None = None) -> None:
    """The licence gate, for a modifier or a VAE.

    Same shape and same env var as ``models.check_usable`` — one gate, not two,
    because an operator who has acknowledged non-commercial use has acknowledged
    it for the whole request. A surface with its own weaker copy of this check
    is how a non-commercial adapter ends up on a commercial job.
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


def as_dict(spec) -> dict:
    """A modifier or VAE entry as the API reports it."""
    payload = {
        "key": spec.key,
        "repo_id": spec.repo_id,
        "targets": list(spec.targets),
        "license": spec.license,
        "commercial_ok": spec.commercial_ok,
        "repo_bytes": spec.repo_bytes,
        "aliases": list(spec.aliases),
        "notes": spec.notes,
    }
    if isinstance(spec, ModifierSpec):
        payload.update({
            "kind": "modifier",
            "weight_name": spec.weight_name,
            "steps": spec.steps,
            "guidance": spec.guidance,
            "scheduler": spec.scheduler,
            "scale": spec.scale,
        })
    else:
        payload.update({"kind": "vae", "tiny": spec.tiny})
    return payload


def all_as_dict() -> dict:
    """Both registries, for ``GET /models``.

    Returns ``{"modifiers": [...], "vaes": [...]}`` rather than a flat list:
    a LoRA and a VAE are not interchangeable, and a caller that cannot tell them
    apart would try to pass one where the other goes.
    """
    return {
        "modifiers": [as_dict(MODIFIERS[k]) for k in sorted(MODIFIERS)],
        "vaes": [as_dict(VAES[k]) for k in sorted(VAES)],
    }
