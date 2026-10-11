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
# The permissive ones. Apache-2.0 and MIT are named exactly like that on the
# cards, so there is no slug to expand: verbatim is the whole string.
MIT = "MIT"


# The per-family negative prompt the entries that HAVE a real negative_prompt
# carry as their default. Tuned for the trace stage, not for the eye: the tracer
# wants flat, high-contrast, few-colour art, so everything a gradient, a soft
# shadow or a hairline would put into the frame is named here. It is a DEFAULT,
# not a silent insertion — `generate()` echoes the value that was actually sent
# (and marks it as the default) so a caller can see it and override it with
# their own, or with an empty string to send none.
PRINT_NEGATIVE_PROMPT = ("gradients, soft shadows, photographic texture, "
                         "hairlines, blur")


@dataclass(frozen=True)
class ModelSpec:
    key: str
    repo_id: str
    params_b: float
    license: str
    commercial_ok: bool
    vram_gb: float
    repo_bytes: float
    layout: str            # "diffusers" (what from_pretrained needs), "single-file", or "remote"
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
    # The negative prompt this entry sends when the caller did not give one.
    # Only ever set where ``negative_prompt`` is True: an entry whose pipeline
    # has no such parameter cannot have a default for it, and a test pins that
    # pairing. None means "nothing is inserted".
    default_negative_prompt: str | None = None
    img2img_strength: bool = False  # img2img uses SD-style image= + strength=
                                    # instead of klein's unified image= (None = t2i)
    # __call__ accepts a LIST of images as one conditioning set, so a request
    # can carry several references and the prompt says how to combine them.
    # Flux2KleinPipeline declares `List[PIL.Image.Image]` in its `image=`
    # annotation and its body normalises a bare image to a one-element list
    # before building `condition_images` — so multi-reference is a property of
    # the CHECKPOINT, not something the service has to synthesise by tiling
    # references into one canvas. The SD-style img2img families take exactly
    # one image, which is why this is a per-model flag and not a global.
    multi_reference: bool = False
    # A distilled checkpoint whose pipeline nevertheless ACTS on guidance_scale.
    # Its whole effect is to suppress the "guidance is ignored" warning, because
    # the two mechanisms that make the number matter need the same answer:
    #   * an EMBEDDING — SanaSprintPipeline runs no classifier-free-guidance pass
    #     (it is distilled) but feeds guidance_scale to the transformer as a
    #     guidance embedding, so the number changes the image; and
    #   * a CFG gate that is not `is_distilled` — ZImagePipeline's
    #     `do_classifier_free_guidance` is `guidance_scale > 0`, so at any
    #     guidance above 0 it runs a REAL CFG pass even though the checkpoint is
    #     8-NFE distilled (MEASURED on Z-Image-Turbo: guidance 0.0 vs 4.0 at the
    #     same seed move the frame, so calling it ignored would be false).
    # klein and sdxl-turbo have neither mechanism at their own schedule and
    # genuinely ignore the number. False is the CFG-less default, so the five
    # original entries keep the warning they always had.
    guidance_embedded: bool = False
    # The pipeline re-bins a requested size to its own buckets and says nothing
    # (`use_resolution_binning=True` is SanaSprintPipeline's default). The image
    # that comes back can therefore be a different size than the one asked for,
    # so the service says so in `warnings` rather than letting the caller find
    # out from the PNG.
    resolution_binning: bool = False
    # "local" (a diffusers checkpoint loaded on this box) or "novita" (a hosted
    # model reached over HTTP).  The remote entries have no local footprint:
    # vram_gb and repo_bytes are 0, and the engine never tries to load them.
    backend: str = "local"
    # Which vendor endpoint a remote entry is served at: "images/generations"
    # (text-to-image) or "images/edits" (multipart, one reference). It is a
    # property of the ENTRY, not of whether a reference was passed, because the
    # two ming models each serve only ONE endpoint — the engine refuses the
    # wrong pairing rather than letting the vendor answer 400. None on a local
    # entry.
    remote_endpoint: str | None = None

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
        multi_reference=True,
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
        multi_reference=True,
        aliases=("4b-base", "klein-base", "base-4b"),
        notes="Undistilled sibling of klein-4b. Slower, but guidance > 1.0 and "
              "a negative prompt actually do something — and that is MEASURED, "
              "not quoted from the card: same prompt, same seed, same 4 steps, "
              "guidance 4.0 and 1.0 produced frames differing by a mean absolute "
              "pixel difference of 34.38, where the distilled klein-4b ignores "
              "the number entirely. Read the cost with it: 28 steps at 1024x1024 "
              "took 58.8s against klein-4b's ~3.5s at 512x512, because under CPU "
              "offload every step is paid for.",
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
        default_negative_prompt=PRINT_NEGATIVE_PROMPT,
        img2img_strength=True,
        notes="OpenRAIL++-M, so generated output is commercially usable. "
              "vram_gb and repo_bytes are ESTIMATES, not measurements. "
              "SD-style: takes a real negative_prompt, and img2img takes a "
              "strength. A request that gives no negative_prompt therefore "
              "sends the print default (%s) and says so in "
              "negative_prompt_source; an empty string sends none."
              % PRINT_NEGATIVE_PROMPT,
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
        default_negative_prompt=PRINT_NEGATIVE_PROMPT,
        img2img_strength=True,
        notes="NON-COMMERCIAL: Stability AI's non-commercial research community "
              "licence — a token is not needed but an acknowledgement is "
              "(CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1). A 2-step distilled SDXL, so "
              "classifier-free guidance never runs: the default negative prompt "
              "is sent like any SDXL's, but at this entry's own guidance 0.0 "
              "there is no CFG pass for it to act through, so raise guidance "
              "above 1.0 if you want it to do anything. vram_gb and repo_bytes "
              "are ESTIMATES, not measurements.",
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
        default_negative_prompt=PRINT_NEGATIVE_PROMPT,
        img2img_strength=True,
        notes="OpenRAIL-M, so generated output is commercially usable. "
              "vram_gb and repo_bytes are ESTIMATES, not measurements. "
              "SD-style: takes a real negative_prompt, and img2img takes a "
              "strength. A request that gives no negative_prompt therefore "
              "sends the print default (%s) and says so in "
              "negative_prompt_source." % PRINT_NEGATIVE_PROMPT,
    ),

    # -- the Sana Sprint and SSD-1B families --------------------------------
    #
    # Both Sana rows are guidance-DISTILLED in the same sense as klein (no
    # classifier-free-guidance pass runs), but their guidance number is NOT
    # ignored the way klein's is: SanaSprintPipeline takes guidance_scale and
    # feeds it to the transformer as a *guidance embedding*
    # (``guidance_embeds_scale``), so the value changes the image with no CFG
    # pass anywhere. The spec's ``guidance_embedded`` flag records that
    # difference, because the two cases need opposite warnings.
    #
    # Their VAE is a 32x-*downsampling* AutoencoderDC, not a 8x AutoencoderKL,
    # which is the whole reason dim_multiple is 32 and min_dim is 512 here. That
    # is read from the downloaded repo's own vae/config.json:
    #   _class_name AutoencoderDC, encoder_block_out_channels has 6 entries, and
    #   the installed diffusers computes vae_scale_factor as
    #   2 ** (len(encoder_block_out_channels) - 1) = 32.
    # The card's own example is 1024x1024 at ``num_inference_steps=2``, and
    # 1024 % 32 == 0, so a multiple of 32 is the resolution rule those weights
    # were trained for.
    #
    # Sana's text encoder is Gemma-2, which is NOT Apache-2.0. The model weights
    # are apache-2.0 and that is what the licence field carries, but the Gemma
    # Terms of Use riding along with it are a real pass-through condition on
    # anyone shipping output; the notes say so rather than leaving it to be
    # discovered.
    "sana-sprint-0.6b": ModelSpec(
        key="sana-sprint-0.6b",
        repo_id="Efficient-Large-Model/Sana_Sprint_0.6B_1024px_diffusers",
        params_b=0.6,
        license=APACHE_2,
        commercial_ok=True,
        # 7.66 GB download, MEASURED (1.19 GB transformer + 5.23 GB Gemma-2-2B
        # text encoder + 1.25 GB VAE), and MEASURED to run on this card:
        # from_pretrained 3.7s, offload ~0s, and 15.58 GB of 17.10 GB free
        # between calls. The number here is the download rather than a resident
        # footprint, because under CPU offload it is the download that decides
        # whether the box can hold the stages.
        vram_gb=7.7,
        repo_bytes=7.66e9,
        layout="diffusers",
        default_steps=2,
        default_guidance=4.5,
        distilled=True,
        aliases=("sana", "sana-sprint", "sana-0.6b", "sana-sprint-06b"),
        pipeline="SanaSprintPipeline",
        edit_pipeline="SanaSprintImg2ImgPipeline",
        dim_multiple=32,
        min_dim=512,
        max_pixels=1024 * 1024,
        negative_prompt=False,
        img2img_strength=True,
        guidance_embedded=True,
        resolution_binning=True,
        notes="Apache-2.0 weights, but the text encoder is Gemma-2 under "
              "Google's Gemma Terms of Use — a licence that rides along with the "
              "Apache-2.0 weights, so \"the weights are commercially usable\" is "
              "not the whole answer for output you ship. VERIFIED RUNNING on "
              "this card: from_pretrained 3.7s, offload ~0s, 1024x1024 at 2 "
              "steps / guidance 4.5 takes ~40s on the FIRST call after a load "
              "and ~2.5s on subsequent calls (512x512 ~2.1s); both numbers are "
              "real, because the first call carries a one-off warm-up. 15.58 GB "
              "of 17.10 GB VRAM free between calls; every frame non-blank. "
              "2-step distilled at guidance 4.5 (the pipeline's own default): "
              "guidance is an embedding, so unlike klein the number IS honoured. "
              "Has NO negative_prompt parameter — a negative prompt is ignored, "
              "with a warning. Its 32x AutoencoderDC VAE is why dim_multiple is "
              "32 and min_dim 512 (read from the repo's vae/config.json; the "
              "scale factor is diffusers' own "
              "2**(len(encoder_block_out_channels)-1), and 512 generating fine "
              "is verified while the full bucket list was never enumerated). "
              "CAVEAT: the pipeline's use_resolution_binning defaults to True, "
              "so a size that is not one of its buckets is silently re-binned — "
              "the frame that comes back can be a different size than the one "
              "asked for, which is why the service warns when this entry is "
              "used.",
    ),
    "sana-sprint-1.6b": ModelSpec(
        key="sana-sprint-1.6b",
        repo_id="Efficient-Large-Model/Sana_Sprint_1.6B_1024px_diffusers",
        params_b=1.6,
        license=APACHE_2,
        commercial_ok=True,
        # NOT run on hardware — the 0.6B row is the one that was measured. This
        # is the measured download (3.22 GB transformer + the same 5.23 GB text
        # encoder + 1.25 GB VAE).
        vram_gb=9.7,
        repo_bytes=9.70e9,
        layout="diffusers",
        default_steps=2,
        default_guidance=4.5,
        distilled=True,
        aliases=("sana-1.6b", "sana-sprint-16b"),
        pipeline="SanaSprintPipeline",
        edit_pipeline="SanaSprintImg2ImgPipeline",
        dim_multiple=32,
        min_dim=512,
        max_pixels=1024 * 1024,
        negative_prompt=False,
        img2img_strength=True,
        guidance_embedded=True,
        resolution_binning=True,
        notes="Same family, same 32x AutoencoderDC resolution rules and the same "
              "Gemma-2 text-encoder pass-through as sana-sprint-0.6b — that "
              "encoder is under Google's Gemma Terms of Use, a licence that "
              "rides along with the Apache-2.0 weights — with a "
              "3.22 GB transformer instead of 1.19 GB (9.70 GB download). 2 "
              "steps at guidance 4.5, guidance embedded and therefore honoured. "
              "No negative_prompt parameter. The same use_resolution_binning "
              "caveat applies. NOT run on this card: the 0.6B sibling is the one "
              "that was measured, so treat repo_bytes as measured and vram_gb as "
              "an ESTIMATE.",
    ),
    "ssd-1b": ModelSpec(
        key="ssd-1b",
        repo_id="segmind/SSD-1B",
        params_b=1.3,
        license=APACHE_2,
        commercial_ok=True,
        # SDXL architecture, so SDXL's estimated footprint applies rather than a
        # number of its own. Not measured here.
        vram_gb=8.0,
        repo_bytes=9.0e9,
        layout="diffusers",
        # MEASURED at 1024x1024: 25 steps at guidance 7.5 returns well-formed
        # frames (6.1s first call after a load, 4.4s after). The card states no
        # schedule, so these were estimates until they were run — and being run
        # is what makes them a measurement rather than a guess. 25/7.5 sits near
        # the SDXL entry's 30/5.0 because this is an undistilled CFG model:
        # "distilled" in the Segmind name describes how the checkpoint was
        # PRUNED from SDXL, not a few-step inference schedule.
        default_steps=25,
        default_guidance=7.5,
        distilled=False,
        aliases=("ssd", "ssd1b", "segmind-ssd-1b"),
        pipeline="StableDiffusionXLPipeline",
        edit_pipeline="StableDiffusionXLImg2ImgPipeline",
        dim_multiple=8,
        min_dim=128,
        max_pixels=2 * 1024 * 1024,
        negative_prompt=True,
        default_negative_prompt=PRINT_NEGATIVE_PROMPT,
        img2img_strength=True,
        notes="Apache-2.0, so generated output is commercially usable. Same "
              "SDXL architecture and same pipeline class as sdxl-1.0, at 1.3B "
              "params instead of 3.5B. NOT distilled — it is a full CFG model, "
              "which is why guidance 7.5 does something on it and why it does "
              "NOT belong in the few-step distilled group. default_steps 25 and "
              "default_guidance 7.5 are MEASURED, not estimates: 1024x1024 at "
              "25 steps / guidance 7.5 returns well-formed frames (6.1s on the "
              "first call after a load, 4.4s after), which makes it the fastest "
              "1024px checkpoint in this registry. vram_gb and repo_bytes are "
              "ESTIMATES. SD-style: takes a real negative_prompt, and "
              "img2img takes a strength.",
    ),

    # -- Z-Image ------------------------------------------------------------
    #
    # Z-Image-Turbo is a 6B single-stream DiT and is step-DISTILLED (8 NFEs by
    # Decoupled-DMD; the card's own example asks for num_inference_steps=9, which
    # is 8 transformer forwards, at guidance_scale=0.0). Its class defaults are
    # the base model's (50 steps / 5.0), so the Turbo schedule has to be named on
    # the entry or a distilled checkpoint runs the wrong one — the same trap as
    # Flux2KleinPipeline's 50 / 4.0, in a different family.
    #
    # The resolution rule is READ FROM THE CLASS, not copied from a sibling:
    # ZImagePipeline.__call__ raises ValueError unless height and width are
    # divisible by ``vae_scale_factor * 2``, and vae_scale_factor is diffusers'
    # own 2**(len(vae.config.block_out_channels) - 1) = 8 for this repo's 4-entry
    # AutoencoderKL (vae/config.json), so the multiple is 16. The class imposes
    # no floor and no cap of its own, so min_dim and max_pixels here are OUR
    # policy and the note says so rather than implying a measurement.
    #
    # The repo stores the transformer AND the text encoder in fp32 (24.61 GB +
    # 8.05 GB of the 32.8 GB core download). torch_dtype=torch.bfloat16 halves
    # the RESIDENT module to ~12.3 GB, which is what lets a 6B checkpoint run
    # under offload=cpu on a 15.92 GiB card; the download stays the fp32 figure,
    # so the disk is sized from 32.8 GB and the card from the bf16 module.
    "z-image-turbo": ModelSpec(
        key="z-image-turbo",
        repo_id="Tongyi-MAI/Z-Image-Turbo",
        params_b=6,
        license=APACHE_2,
        commercial_ok=True,
        # Largest resident module in bf16, derived from the fp32 file sizes the
        # HF API reports (transformer 24.61 GB / 2) — not measured. What was
        # measured is the peak VRAM line in the note.
        vram_gb=12.3,
        # The core download: transformer 24.61 GB fp32 + Qwen3 text encoder
        # 8.05 GB fp32 + VAE 0.17 GB, as enumerated from the HF API.
        repo_bytes=32.8e9,
        layout="diffusers",
        default_steps=9,
        default_guidance=0.0,
        distilled=True,
        aliases=("z-image", "zimage", "zimage-turbo"),
        pipeline="ZImagePipeline",
        # The family splits t2i and img2img across two classes (unlike klein's
        # unified image=), so an /edit request needs the img2img one.
        edit_pipeline="ZImageImg2ImgPipeline",
        # 16, not 8 and not 16-by-taste: the class's own divisibility check is
        # vae_scale_factor(8) * 2, and it raises rather than re-binning.
        dim_multiple=16,
        min_dim=128,
        max_pixels=1024 * 1024,
        # ZImagePipeline.__call__ HAS a negative_prompt parameter (so the engine
        # passes it instead of warning), but CFG — the machinery it acts through
        # — only runs above guidance 0: see the note and guidance_embedded.
        negative_prompt=True,
        img2img_strength=True,
        # Distilled, yet the number IS honoured: see the field's comment and the
        # MEASURED guidance difference in the note.
        guidance_embedded=True,
        resolution_binning=False,
        notes="Apache-2.0 weights, so generated output is commercially usable. "
              "VERIFIED RUNNING on this card under offload=cpu: from_pretrained "
              "55.8s, and 1024x1024 at 9 steps / guidance 0.0 takes 41.3s on the "
              "FIRST call after a load and 17.0s after (both real — the first call "
              "carries a one-off warm-up), every frame non-blank (84536 and 65448 "
              "distinct colours in the two frames), 0 NaN warnings, and 0.65 GB in "
              "use afterwards because CPU offload returns each module to host RAM "
              "(peak during the run: 15.52 GB = 14.45 GiB of the 15.92 GiB card, "
              "sampled every 0.5s — the guidance-4.0 call, which runs CFG, is the "
              "heaviest). 8-NFE step-distilled (Decoupled-DMD), so 9 / 0.0 is the "
              "Turbo schedule and the class's own 50 / 5.0 must never be let "
              "through. Guidance is NOT ignored the way klein's is: "
              "ZImagePipeline.do_classifier_free_guidance is "
              "`guidance_scale > 0`, so above 0 it runs a REAL CFG pass — "
              "MEASURED, guidance 0.0 vs 4.0 at the same seed, same 9 steps, "
              "differ by a mean absolute pixel difference of 25.11 (max 255), and "
              "the service emits NO 'guidance is ignored' warning for it. At "
              "the vendor's 0.0 no CFG runs, which is why a negative prompt is "
              "unused at the default schedule — the parameter EXISTS, so the "
              "service passes it rather than warning. dim_multiple 16 is the "
              "CLASS's rule — vae_scale_factor 8 doubled, raised as an error, not "
              "a re-bin. min_dim 128 and the 1 MP cap are OUR policy, ESTIMATE, "
              "not measurements: 1024x1024 is the size that was RUN (512x512 also "
              "ran, 7.0s in-process) and a 1536x1536 request is refused by the cap "
              "rather than proven to work. The family's second class is VERIFIED: "
              "an /edit through ZImageImg2ImgPipeline at its default strength 0.6 "
              "returned a non-blank 1024x1024 frame (49.3s, 86281 colours). "
              "repo_bytes 32.8 GB is the download enumerated from the HF API "
              "(24.61 GB transformer + 8.05 GB text encoder, both stored fp32, + "
              "0.17 GB VAE); vram_gb 12.3 is DERIVED from that (bf16 halves the "
              "resident module) — the measured VRAM figure is the peak above.",
    ),

    # -- the novita remote backend -------------------------------------------
    #
    # Two hosted models from Novita AI.  They are NOT diffusers checkpoints:
    # there is no pipeline class to import, no weights to download, and no
    # VRAM to account for.  The engine never tries to load them; the remote
    # client (chopshop_flux/remote.py) talks to the vendor's HTTP API instead.
    #
    # UNVERIFIED: these entries are registered from the vendor's published API
    # contract, not from a run on this box.  The model names, endpoint shapes,
    # and response formats are taken from Novita's documentation; no generation
    # has been made against them yet.
    "ming-image-0.1-design": ModelSpec(
        key="ming-image-0.1-design",
        repo_id="ming-image-0.1-design",
        params_b=0,
        license="Novita AI Terms of Service",
        commercial_ok=False,
        vram_gb=0.0,
        repo_bytes=0.0,
        layout="remote",
        # The remote API has no step or guidance control; these values are
        # inert placeholders so the engine's steps>=1 check passes and the
        # response body reports a coherent schedule.
        default_steps=1,
        default_guidance=1.0,
        distilled=False,
        backend="novita",
        remote_endpoint="images/generations",
        # The API documents '1k and above' for size; the default min_dim=64
        # would wrongly let a sub-1k request through.
        min_dim=1024,
        notes="UNVERIFIED: hosted model on Novita AI's API. "
              "Text-to-image via POST /images/generations. "
              "No local footprint — vram_gb and repo_bytes are 0. "
              "Commercial use governed by Novita AI's Terms of Service.",
    ),
    "ming-image-0.1-design-layer": ModelSpec(
        key="ming-image-0.1-design-layer",
        repo_id="ming-image-0.1-design-layer",
        params_b=0,
        license="Novita AI Terms of Service",
        commercial_ok=False,
        vram_gb=0.0,
        repo_bytes=0.0,
        layout="remote",
        # Same inert defaults as the t2i entry: the API has no step/guidance
        # control, but the engine requires steps>=1 and a coherent schedule.
        default_steps=1,
        default_guidance=1.0,
        distilled=False,
        backend="novita",
        remote_endpoint="images/edits",
        # The edit output size follows the reference image, so the same 1k
        # floor applies: a sub-1k reference would produce a sub-1k output
        # that the API may refuse or upscale unpredictably.
        min_dim=1024,
        notes="UNVERIFIED: hosted model on Novita AI's API. "
              "Image editing via POST /images/edits (multipart/form-data, "
              "field 'image[]'). Returns revised_prompt with canvas and "
              "regions. No local footprint — vram_gb and repo_bytes are 0. "
              "Commercial use governed by Novita AI's Terms of Service.",
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
        "default_negative_prompt": spec.default_negative_prompt,
        "img2img_strength": spec.img2img_strength,
        "multi_reference": spec.multi_reference,
        "guidance_embedded": spec.guidance_embedded,
        "resolution_binning": spec.resolution_binning,
        "backend": spec.backend,
        "remote_endpoint": spec.remote_endpoint,
    }


def all_as_dict() -> list[dict]:
    return [as_dict(REGISTRY[k]) for k in sorted(REGISTRY)]
