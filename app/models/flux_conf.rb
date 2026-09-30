# The chopshop-flux conf, mirrored from the repo that defines it.
#
# This is a faithful copy of the constants in chopshop-flux's
# `chopshop_flux/config.py` and the registry in `chopshop_flux/models.py`, which
# is what the service actually reads. It is shown on the FLUX page so the
# settings, the model facts and the licence are visible instead of implied.
#
# IMPORTANT, and the reason this is a model and not a settings table: this page
# does not run the service and cannot change its environment. It shows what the
# service would be started with, validates a request the same way the service
# does, and hands you the env block and the JSON to copy. See #writable? and the
# note on the page -- the same honesty the JEV page carries.
#
# Anything here that drifts from config.py/models.py is a bug in THIS file. The
# values are transcribed, not paraphrased: a licence string that is not the
# licence string is worse than no licence string.
class FluxConf
  SERVICE = "chopshop-flux".freeze

  # config.py, verbatim.
  DEFAULT_BIND = "127.0.0.1".freeze
  DEFAULT_PORT = 8795

  # The service's HTTP surface, as seen from here. Listed because the point of
  # that service is that it is a STANDARD API: these are the routes any other
  # application calls too, not something shaped around this studio.
  API = {
    routes: "POST /generate, POST /edit, GET /models, GET /health, " \
            "GET /files/<name>, POST /unload"
  }.freeze
  DEFAULT_OUT_DIR = "./out".freeze
  MIN_DIMENSION = 64
  DIMENSION_MULTIPLE = 16
  DEFAULT_MAX_PIXELS = 4 * 1024 * 1024
  MAX_UPLOAD_BYTES = 32 * 1024 * 1024

  # models.py, verbatim. Licence strings are kept exactly as they appear on the
  # model cards so a grep for the licence finds the thing the licence is called.
  APACHE_2 = "Apache-2.0".freeze
  SDXL_OPENRAIL_PP = "CreativeML Open RAIL++-M License".freeze
  SD15_OPENRAIL_M = "CreativeML Open RAIL-M License".freeze
  SDXL_TURBO_NONCOMMERCIAL =
    "Stability AI Non-Commercial Research Community License".freeze
  # Both VAE repos in the registry are MIT, and the string is transcribed rather
  # than abbreviated for the same reason every other one is.
  MIT = "MIT".freeze

  DEFAULT_MODEL_KEY = "klein-4b".freeze

  # models.py, verbatim.
  #
  # NOT every family obeys the same resolution rules, so each entry carries its
  # OWN `dim_multiple` / `min_dim` / `max_pixels` -- exactly as models.py's
  # ModelSpec does, where the klein entries take the dataclass defaults and the
  # SD and Sana families name theirs. The module-level MIN_DIMENSION /
  # DIMENSION_MULTIPLE / DEFAULT_MAX_PIXELS above are the klein family's values
  # and #validate no longer reaches past a spec's own rules to them: applying
  # one family's floor to another is how a legal SDXL request gets refused, or a
  # Sana one gets accepted at a size the pipeline cannot draw.
  MODELS = {
    "klein-4b" => {
      "key" => "klein-4b",
      "repo_id" => "black-forest-labs/FLUX.2-klein-4B",
      "params_b" => 4,
      "licence" => APACHE_2,
      "commercial_ok" => true,
      "vram_gb" => 13.0,
      "repo_bytes" => 15.98e9,
      "layout" => "diffusers",
      "default_steps" => 4,
      "default_guidance" => 1.0,
      "distilled" => true,
      "gated" => false,
      "negative_prompt" => false,
      # Stated explicitly here (false) because models.py states it explicitly —
      # the studio omitting a flag the service carries is the same drift as
      # getting it wrong, and it is what makes this entry comparable.
      "img2img_strength" => false,
      # Mirrored from models.py for the same reason the flags above are: a
      # field the service reports and the studio omits is drift. Load-bearing,
      # not decoration -- it is whether a request may carry SEVERAL reference
      # images as one conditioning set, which is a property of the pipeline.
      "multi_reference" => true,
      "dim_multiple" => DIMENSION_MULTIPLE,
      "min_dim" => MIN_DIMENSION,
      "max_pixels" => DEFAULT_MAX_PIXELS,
      # Mirrored from models.py, explicitly, for the same reason img2img_strength is:
      # the studio omitting a field the service reports is drift. These two are
      # LOAD-BEARING, not decoration -- 
      #   guidance_embedded: a distilled pipeline with a guidance EMBEDDING acts on the
      #     number without running CFG, so the service does NOT warn "ignored" for it.
      #   resolution_binning: the pipeline re-bins a size it does not have a bucket
      #     for, so the PNG can come back at a different resolution than asked.
      # validate() reads both, so the page stops telling the operator guidance is
      # ignored on a model that honours it.
      "guidance_embedded" => false,
      "resolution_binning" => false,
      "aliases" => %w[4b klein klein4b klein-4B],
      "notes" => "Apache 2.0, so generated output is yours to sell. The default."
    },
    "klein-4b-base" => {
      "key" => "klein-4b-base",
      "repo_id" => "black-forest-labs/FLUX.2-klein-base-4B",
      "params_b" => 4,
      "licence" => APACHE_2,
      "commercial_ok" => true,
      "vram_gb" => 13.0,
      "repo_bytes" => 16.0e9,
      "layout" => "diffusers",
      "default_steps" => 28,
      "default_guidance" => 4.0,
      "distilled" => false,
      "gated" => false,
      "negative_prompt" => false,
      "img2img_strength" => false,
      # Mirrored from models.py for the same reason the flags above are: a
      # field the service reports and the studio omits is drift. Load-bearing,
      # not decoration -- it is whether a request may carry SEVERAL reference
      # images as one conditioning set, which is a property of the pipeline.
      "multi_reference" => true,
      "dim_multiple" => DIMENSION_MULTIPLE,
      "min_dim" => MIN_DIMENSION,
      "max_pixels" => DEFAULT_MAX_PIXELS,
      # Mirrored from models.py, explicitly, for the same reason img2img_strength is:
      # the studio omitting a field the service reports is drift. These two are
      # LOAD-BEARING, not decoration -- 
      #   guidance_embedded: a distilled pipeline with a guidance EMBEDDING acts on the
      #     number without running CFG, so the service does NOT warn "ignored" for it.
      #   resolution_binning: the pipeline re-bins a size it does not have a bucket
      #     for, so the PNG can come back at a different resolution than asked.
      # validate() reads both, so the page stops telling the operator guidance is
      # ignored on a model that honours it.
      "guidance_embedded" => false,
      "resolution_binning" => false,
      "aliases" => %w[4b-base klein-base base-4b],
      # Undistilled: it preserves the full training signal, which is why it is
      # the fine-tuning starting point -- and why guidance > 1.0 works on it.
      "notes" => "Undistilled sibling of klein-4b. Slower, but guidance > 1.0 and a negative prompt actually do something \u2014 and that is MEASURED, not quoted from the card: same prompt, same seed, same 4 steps, guidance 4.0 and 1.0 produced frames differing by a mean absolute pixel difference of 34.38, where the distilled klein-4b ignores the number entirely. Read the cost with it: 28 steps at 1024x1024 took 58.8s against klein-4b's ~3.5s at 512x512, because under CPU offload every step is paid for."
    },
    "sdxl-1.0" => {
      "key" => "sdxl-1.0",
      "repo_id" => "stabilityai/stable-diffusion-xl-base-1.0",
      "params_b" => 3.5,
      "licence" => SDXL_OPENRAIL_PP,
      "commercial_ok" => true,
      "vram_gb" => 8.0,
      "repo_bytes" => 13.9e9,
      "layout" => "diffusers",
      "default_steps" => 30,
      "default_guidance" => 5.0,
      "distilled" => false,
      "gated" => false,
      "negative_prompt" => true,
      "img2img_strength" => true,
      # Mirrored from models.py for the same reason the flags above are: a
      # field the service reports and the studio omits is drift. Load-bearing,
      # not decoration -- it is whether a request may carry SEVERAL reference
      # images as one conditioning set, which is a property of the pipeline.
      "multi_reference" => false,
      "dim_multiple" => 8,
      "min_dim" => 128,
      "max_pixels" => 2 * 1024 * 1024,
      # Mirrored from models.py, explicitly, for the same reason img2img_strength is:
      # the studio omitting a field the service reports is drift. These two are
      # LOAD-BEARING, not decoration -- 
      #   guidance_embedded: a distilled pipeline with a guidance EMBEDDING acts on the
      #     number without running CFG, so the service does NOT warn "ignored" for it.
      #   resolution_binning: the pipeline re-bins a size it does not have a bucket
      #     for, so the PNG can come back at a different resolution than asked.
      # validate() reads both, so the page stops telling the operator guidance is
      # ignored on a model that honours it.
      "guidance_embedded" => false,
      "resolution_binning" => false,
      "aliases" => %w[sdxl xl sdxl-base],
      "notes" => "OpenRAIL++-M, so generated output is commercially usable. vram_gb and repo_bytes are ESTIMATES, not measurements. SD-style: takes a real negative_prompt, and img2img takes a strength."
    },
    "sdxl-turbo" => {
      "key" => "sdxl-turbo",
      "repo_id" => "stabilityai/sdxl-turbo",
      "params_b" => 3.5,
      "licence" => SDXL_TURBO_NONCOMMERCIAL,
      "commercial_ok" => false,
      "vram_gb" => 8.0,
      "repo_bytes" => 13.9e9,
      "layout" => "diffusers",
      "default_steps" => 2,
      "default_guidance" => 0.0,
      "distilled" => true,
      # Not gated: the acknowledgement IS the gate, so fetching it needs no
      # token. Distilled, which is why its own schedule is 2 steps at guidance
      # 0.0 rather than the 5.0 sdxl-1.0 runs at — and why CFG never runs on it.
      "gated" => false,
      "negative_prompt" => true,
      "img2img_strength" => true,
      # Mirrored from models.py for the same reason the flags above are: a
      # field the service reports and the studio omits is drift. Load-bearing,
      # not decoration -- it is whether a request may carry SEVERAL reference
      # images as one conditioning set, which is a property of the pipeline.
      "multi_reference" => false,
      "dim_multiple" => 8,
      "min_dim" => 128,
      "max_pixels" => 1024 * 1024,
      # Mirrored from models.py, explicitly, for the same reason img2img_strength is:
      # the studio omitting a field the service reports is drift. These two are
      # LOAD-BEARING, not decoration -- 
      #   guidance_embedded: a distilled pipeline with a guidance EMBEDDING acts on the
      #     number without running CFG, so the service does NOT warn "ignored" for it.
      #   resolution_binning: the pipeline re-bins a size it does not have a bucket
      #     for, so the PNG can come back at a different resolution than asked.
      # validate() reads both, so the page stops telling the operator guidance is
      # ignored on a model that honours it.
      "guidance_embedded" => false,
      "resolution_binning" => false,
      "aliases" => %w[turbo sdxl-turbo],
      "notes" => "NON-COMMERCIAL: Stability AI's non-commercial research community licence \u2014 a token is not needed but an acknowledgement is (CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1). A 2-step distilled SDXL, so classifier-free guidance never runs. vram_gb and repo_bytes are ESTIMATES, not measurements."
    },
    "sd-1.5" => {
      "key" => "sd-1.5",
      "repo_id" => "stable-diffusion-v1-5/stable-diffusion-v1-5",
      "params_b" => 0.86,
      "licence" => SD15_OPENRAIL_M,
      "commercial_ok" => true,
      "vram_gb" => 4.0,
      "repo_bytes" => 5.5e9,
      "layout" => "diffusers",
      "default_steps" => 30,
      "default_guidance" => 7.5,
      "distilled" => false,
      "gated" => false,
      "negative_prompt" => true,
      "img2img_strength" => true,
      # Mirrored from models.py for the same reason the flags above are: a
      # field the service reports and the studio omits is drift. Load-bearing,
      # not decoration -- it is whether a request may carry SEVERAL reference
      # images as one conditioning set, which is a property of the pipeline.
      "multi_reference" => false,
      "dim_multiple" => 8,
      "min_dim" => 128,
      "max_pixels" => 1024 * 1024,
      # Mirrored from models.py, explicitly, for the same reason img2img_strength is:
      # the studio omitting a field the service reports is drift. These two are
      # LOAD-BEARING, not decoration -- 
      #   guidance_embedded: a distilled pipeline with a guidance EMBEDDING acts on the
      #     number without running CFG, so the service does NOT warn "ignored" for it.
      #   resolution_binning: the pipeline re-bins a size it does not have a bucket
      #     for, so the PNG can come back at a different resolution than asked.
      # validate() reads both, so the page stops telling the operator guidance is
      # ignored on a model that honours it.
      "guidance_embedded" => false,
      "resolution_binning" => false,
      "aliases" => %w[sd15 sd1.5 sd],
      "notes" => "OpenRAIL-M, so generated output is commercially usable. vram_gb and repo_bytes are ESTIMATES, not measurements. SD-style: takes a real negative_prompt, and img2img takes a strength."
    },
    # The Sana family's resolution rules are its OWN and differ from every other
    # entry here: multiples of 32, a 512 floor and a 1 MP cap. The klein
    # constants above (16 / 64 / 4 MP) are NOT its rules and must not be applied
    # to it -- hence the explicit dim_multiple/min_dim/max_pixels below.
    #
    # steps and guidance are the pipeline's own MEASURED defaults on the
    # service's box (2 / 4.5), which is why they are not hedged the way the SD
    # entries' estimates are.
    "sana-sprint-0.6b" => {
      "key" => "sana-sprint-0.6b",
      "repo_id" => "Efficient-Large-Model/Sana_Sprint_0.6B_1024px_diffusers",
      "params_b" => 0.6,
      "licence" => APACHE_2,
      "commercial_ok" => true,
      "vram_gb" => 7.7,
      "repo_bytes" => 7.66e9,
      "layout" => "diffusers",
      "default_steps" => 2,
      "default_guidance" => 4.5,
      "distilled" => true,
      "gated" => false,
      "negative_prompt" => false,
      "img2img_strength" => true,
      # Mirrored from models.py for the same reason the flags above are: a
      # field the service reports and the studio omits is drift. Load-bearing,
      # not decoration -- it is whether a request may carry SEVERAL reference
      # images as one conditioning set, which is a property of the pipeline.
      "multi_reference" => false,
      "dim_multiple" => 32,
      "min_dim" => 512,
      "max_pixels" => 1024 * 1024,
      # Mirrored from models.py, explicitly, for the same reason img2img_strength is:
      # the studio omitting a field the service reports is drift. These two are
      # LOAD-BEARING, not decoration -- 
      #   guidance_embedded: a distilled pipeline with a guidance EMBEDDING acts on the
      #     number without running CFG, so the service does NOT warn "ignored" for it.
      #   resolution_binning: the pipeline re-bins a size it does not have a bucket
      #     for, so the PNG can come back at a different resolution than asked.
      # validate() reads both, so the page stops telling the operator guidance is
      # ignored on a model that honours it.
      "guidance_embedded" => true,
      "resolution_binning" => true,
      "aliases" => %w[sana sana-sprint sana-0.6b sana-sprint-06b],
      "notes" => "Apache-2.0 weights, but the text encoder is Gemma-2 under Google's Gemma Terms of Use \u2014 a licence that rides along with the Apache-2.0 weights, so \"the weights are commercially usable\" is not the whole answer for output you ship. VERIFIED RUNNING on this card: from_pretrained 3.7s, offload ~0s, 1024x1024 at 2 steps / guidance 4.5 takes ~40s on the FIRST call after a load and ~2.5s on subsequent calls (512x512 ~2.1s); both numbers are real, because the first call carries a one-off warm-up. 15.58 GB of 17.10 GB VRAM free between calls; every frame non-blank. 2-step distilled at guidance 4.5 (the pipeline's own default): guidance is an embedding, so unlike klein the number IS honoured. Has NO negative_prompt parameter \u2014 a negative prompt is ignored, with a warning. Its 32x AutoencoderDC VAE is why dim_multiple is 32 and min_dim 512 (read from the repo's vae/config.json; the scale factor is diffusers' own 2**(len(encoder_block_out_channels)-1), and 512 generating fine is verified while the full bucket list was never enumerated). CAVEAT: the pipeline's use_resolution_binning defaults to True, so a size that is not one of its buckets is silently re-binned \u2014 the frame that comes back can be a different size than the one asked for, which is why the service warns when this entry is used."
    },
    "sana-sprint-1.6b" => {
      "key" => "sana-sprint-1.6b",
      "repo_id" => "Efficient-Large-Model/Sana_Sprint_1.6B_1024px_diffusers",
      "params_b" => 1.6,
      "licence" => APACHE_2,
      "commercial_ok" => true,
      "vram_gb" => 9.7,
      "repo_bytes" => 9.70e9,
      "layout" => "diffusers",
      "default_steps" => 2,
      "default_guidance" => 4.5,
      "distilled" => true,
      "gated" => false,
      "negative_prompt" => false,
      "img2img_strength" => true,
      # Mirrored from models.py for the same reason the flags above are: a
      # field the service reports and the studio omits is drift. Load-bearing,
      # not decoration -- it is whether a request may carry SEVERAL reference
      # images as one conditioning set, which is a property of the pipeline.
      "multi_reference" => false,
      "dim_multiple" => 32,
      "min_dim" => 512,
      "max_pixels" => 1024 * 1024,
      # Mirrored from models.py, explicitly, for the same reason img2img_strength is:
      # the studio omitting a field the service reports is drift. These two are
      # LOAD-BEARING, not decoration -- 
      #   guidance_embedded: a distilled pipeline with a guidance EMBEDDING acts on the
      #     number without running CFG, so the service does NOT warn "ignored" for it.
      #   resolution_binning: the pipeline re-bins a size it does not have a bucket
      #     for, so the PNG can come back at a different resolution than asked.
      # validate() reads both, so the page stops telling the operator guidance is
      # ignored on a model that honours it.
      "guidance_embedded" => true,
      "resolution_binning" => true,
      "aliases" => %w[sana-1.6b sana-sprint-16b],
      "notes" => "Same family, same 32x AutoencoderDC resolution rules and the same Gemma-2 text-encoder pass-through as sana-sprint-0.6b \u2014 that encoder is under Google's Gemma Terms of Use, a licence that rides along with the Apache-2.0 weights \u2014 with a 3.22 GB transformer instead of 1.19 GB (9.70 GB download). 2 steps at guidance 4.5, guidance embedded and therefore honoured. No negative_prompt parameter. The same use_resolution_binning caveat applies. NOT run on this card: the 0.6B sibling is the one that was measured, so treat repo_bytes as measured and vram_gb as an ESTIMATE."
    },
    # SDXL's architecture at 1.3B, so it is a drop-in sibling of sdxl-1.0: the
    # same pipeline class and the SAME resolution rules (8 / 128 / 2 MP).
    # steps and guidance are MEASURED — the service's box ran it at 1024x1024
    # and it returned well-formed frames. Its vram/byte figures are still
    # estimates, and its note says so; claiming a measurement for a number that
    # was never run is the same fault as presenting an estimate as a fact.
    "ssd-1b" => {
      "key" => "ssd-1b",
      "repo_id" => "segmind/SSD-1B",
      "params_b" => 1.3,
      "licence" => APACHE_2,
      "commercial_ok" => true,
      "vram_gb" => 8.0,
      "repo_bytes" => 9.0e9,
      "layout" => "diffusers",
      "default_steps" => 25,
      "default_guidance" => 7.5,
      "distilled" => false,
      "gated" => false,
      "negative_prompt" => true,
      "img2img_strength" => true,
      # Mirrored from models.py for the same reason the flags above are: a
      # field the service reports and the studio omits is drift. Load-bearing,
      # not decoration -- it is whether a request may carry SEVERAL reference
      # images as one conditioning set, which is a property of the pipeline.
      "multi_reference" => false,
      "dim_multiple" => 8,
      "min_dim" => 128,
      "max_pixels" => 2 * 1024 * 1024,
      # Mirrored from models.py, explicitly, for the same reason img2img_strength is:
      # the studio omitting a field the service reports is drift. These two are
      # LOAD-BEARING, not decoration -- 
      #   guidance_embedded: a distilled pipeline with a guidance EMBEDDING acts on the
      #     number without running CFG, so the service does NOT warn "ignored" for it.
      #   resolution_binning: the pipeline re-bins a size it does not have a bucket
      #     for, so the PNG can come back at a different resolution than asked.
      # validate() reads both, so the page stops telling the operator guidance is
      # ignored on a model that honours it.
      "guidance_embedded" => false,
      "resolution_binning" => false,
      "aliases" => %w[ssd ssd1b segmind-ssd-1b],
      "notes" => "Apache-2.0, so generated output is commercially usable. Same SDXL architecture and same pipeline class as sdxl-1.0, at 1.3B params instead of 3.5B. NOT distilled \u2014 it is a full CFG model, which is why guidance 7.5 does something on it and why it does NOT belong in the few-step distilled group. default_steps 25 and default_guidance 7.5 are MEASURED, not estimates: 1024x1024 at 25 steps / guidance 7.5 returns well-formed frames (6.1s on the first call after a load, 4.4s after), which makes it the fastest 1024px checkpoint in this registry. vram_gb and repo_bytes are ESTIMATES. SD-style: takes a real negative_prompt, and img2img takes a strength."
    },
    "z-image-turbo" => {
      "key" => "z-image-turbo",
      "repo_id" => "Tongyi-MAI/Z-Image-Turbo",
      "params_b" => 6,
      "licence" => APACHE_2,
      "commercial_ok" => true,
      "vram_gb" => 12.3,
      "repo_bytes" => 32.8e9,
      "layout" => "diffusers",
      "default_steps" => 9,
      "default_guidance" => 0.0,
      "distilled" => true,
      "gated" => false,
      "negative_prompt" => true,
      "img2img_strength" => true,
      "multi_reference" => false,
      "dim_multiple" => 16,
      "min_dim" => 128,
      "max_pixels" => 1048576,
      "guidance_embedded" => true,
      "resolution_binning" => false,
      "aliases" => %w[z-image zimage zimage-turbo],
      "notes" => "Apache-2.0 weights, so generated output is commercially usable. VERIFIED RUNNING on this card under offload=cpu: from_pretrained 55.8s, and 1024x1024 at 9 steps / guidance 0.0 takes 41.3s on the FIRST call after a load and 17.0s after (both real \u2014 the first call carries a one-off warm-up), every frame non-blank (84536 and 65448 distinct colours in the two frames), 0 NaN warnings, and 0.65 GB in use afterwards because CPU offload returns each module to host RAM (peak during the run: 15.52 GB = 14.45 GiB of the 15.92 GiB card, sampled every 0.5s \u2014 the guidance-4.0 call, which runs CFG, is the heaviest). 8-NFE step-distilled (Decoupled-DMD), so 9 / 0.0 is the Turbo schedule and the class's own 50 / 5.0 must never be let through. Guidance is NOT ignored the way klein's is: ZImagePipeline.do_classifier_free_guidance is `guidance_scale > 0`, so above 0 it runs a REAL CFG pass \u2014 MEASURED, guidance 0.0 vs 4.0 at the same seed, same 9 steps, differ by a mean absolute pixel difference of 25.11 (max 255), and the service emits NO 'guidance is ignored' warning for it. At the vendor's 0.0 no CFG runs, which is why a negative prompt is unused at the default schedule \u2014 the parameter EXISTS, so the service passes it rather than warning. dim_multiple 16 is the CLASS's rule \u2014 vae_scale_factor 8 doubled, raised as an error, not a re-bin. min_dim 128 and the 1 MP cap are OUR policy, ESTIMATE, not measurements: 1024x1024 is the size that was RUN (512x512 also ran, 7.0s in-process) and a 1536x1536 request is refused by the cap rather than proven to work. The family's second class is VERIFIED: an /edit through ZImageImg2ImgPipeline at its default strength 0.6 returned a non-blank 1024x1024 frame (49.3s, 86281 colours). repo_bytes 32.8 GB is the download enumerated from the HF API (24.61 GB transformer + 8.05 GB text encoder, both stored fp32, + 0.17 GB VAE); vram_gb 12.3 is DERIVED from that (bf16 halves the resident module) \u2014 the measured VRAM figure is the peak above."
    }
  }.freeze

  # THE QUALITY HALF, which models.py does not carry.
  #
  # MODELS above mirrors the registry field for field and stays a faithful copy
  # of it -- so the quality judgement does NOT live in there. A registry entry is
  # a set of facts (steps, guidance, a licence); "what is this one good at, and
  # where does it disappoint" is a different kind of claim and is kept apart
  # deliberately, so a reader can tell the transcription from the copy.
  #
  # Transcribed from chopshop-flux's `docs/MODELS.md` (section 2, "Expected
  # quality"), which is the file that carries the measurements behind each
  # sentence. The axis is the pipeline's, not the eye's: whatever traces into
  # flat colour, legible shapes and few inks. Nothing here ranks a frame or the
  # art -- it states what a checkpoint is good at and its weak spot.
  #
  # ONE sentence per model key. Pinned to MODELS by flux_page_test: a model
  # mirrored without a sentence fails rather than rendering an empty line.
  QUALITY = {
    "klein-4b" => "Where it fits: a described graphic — prompt adherence is its strength, " \
                  "multi-reference editing is built in, and at 4 steps it is the one entry here " \
                  "that answers in seconds warm. Weak spot: it is distilled, so guidance and a " \
                  "negative prompt do nothing on it — the steering has to come from the prompt " \
                  "and the reference image.",
    "klein-4b-base" => "Where it fits: the honest steering — undistilled, so guidance and a " \
                       "negative prompt act (MEASURED: frames at guidance 4.0 vs 1.0 differ by a " \
                       "mean absolute pixel difference of 34.38), which makes it the " \
                       "fine-tuning starting point. Weak spot: every step is paid for under CPU " \
                       "offload — 28 steps at 1024x1024 took 58.8s against klein-4b's ~3.5s at " \
                       "512x512.",
    "sdxl-1.0" => "Where it fits: a specific look — the style family, with the deepest " \
                  "LoRA/adapter ecosystem here and the most predictable SDXL output. Weak spot: " \
                  "prompt adherence is fair and text in the image garbles past a word, so it " \
                  "wants a real negative prompt and a careful prompt.",
    "sdxl-turbo" => "Where it fits: a 2-step SDXL frame, inheriting part of SDXL's LoRA " \
                    "ecosystem. Weak spots: the licence is non-commercial (research use only), " \
                    "and CFG never runs at guidance 0.0, so guidance and a negative prompt do " \
                    "nothing on it.",
    "sd-1.5" => "Where it fits: breadth on the lightest checkpoint here — the old LoRA, " \
                "embedding and ControlNet ecosystem, kept because a specific one of them is " \
                "sometimes the point. Weak spot: prompt adherence is weak (short prompts only), " \
                "and it is the dated end of this registry.",
    "sana-sprint-0.6b" => "Where it fits: the cheapest iteration loop — 2 steps, guidance " \
                          "embedded and honoured, MEASURED 2.5s warm at 1024px — so it is a " \
                          "sketchpad for many ideas. Weak spot: the least predictable of these on " \
                          "complex scenes, printability only fair, and no negative prompt at all.",
    "sana-sprint-1.6b" => "Where it fits: the same family with a 1.6B transformer instead of " \
                          "0.6B. Weak spot: NOT run on this card, so its speed is an ESTIMATE " \
                          "between the 0.6B and SDXL; its style range is as thin as its sibling's " \
                          "and it has the same no-negative-prompt limit.",
    # Same order as MODELS above, so the two can be read side by side; the page
    # test asserts the sets are equal, not merely overlapping.
    "ssd-1b" => "Where it fits: an SDXL-class 1024px frame at 1.3B, and MEASURED as the fastest " \
                "1024px entry in the registry (6.1s on the first call after a load, 4.4s after) — " \
                "undistilled, with a real negative prompt and an img2img strength. Weak spot: its " \
                "style range is limited next to sdxl-1.0's ecosystem.",
    "z-image-turbo" => "Where it fits: the fastest commercial-safe generalist here — " \
                      "Apache-2.0, and MEASURED on the card at 1024 px: 41.3s on the first " \
                      "call after a load and 17.0s after, at 9 steps. Weak spot: it is " \
                      "step-distilled, so at its own schedule (guidance 0.0) no CFG runs and a " \
                      "negative prompt does nothing; raise guidance above 0 and a real CFG " \
                      "pass runs (MEASURED: guidance 0.0 vs 4.0 differ by a mean absolute pixel " \
                      "difference of 25.11), which is also the heaviest VRAM case measured.",
  }.freeze

  # modifiers.py, verbatim. The LoRA adapters the service can apply on top of a
  # model.
  #
  # `targets` is which models an adapter may load against, and it is checked
  # BEFORE anything loads: offering an SDXL-only LoRA to a klein is a caller
  # error, not a silent no-op, because the load would fail after the GPU had
  # already been paid for.
  #
  # `weight_name` is the file INSIDE the repo that actually gets loaded, which is
  # why it is transcribed rather than derived from the repo id -- the Lightning
  # repo alone publishes 2, 4 and 8 step files under one id, and the LCM repos
  # publish `pytorch_lora_weights.safetensors` like every other diffusers LoRA.
  #
  # steps/guidance/scheduler are the adapter's OWN schedule, or nil when it has
  # none and simply rides the model's. `scale` is the multiplier applied when the
  # operator types none.
  MODIFIERS = {
    "klein-background-remove" => {
      "key" => "klein-background-remove",
      "repo_id" => "fal/flux-2-klein-4B-background-remove-lora",
      "weight_name" => "flux-background-remove-lora.safetensors",
      "targets" => %w[klein-4b klein-4b-base],
      "licence" => APACHE_2,
      "commercial_ok" => true,
      "repo_bytes" => 76.0e6,
      "steps" => nil,
      "guidance" => nil,
      "scheduler" => nil,
      "scale" => 1.0,
      "notes" => "fal's klein-4B background remover. Apache-2.0, so its output " \
                 "is commercially usable. No schedule of its own: it rides the " \
                 "model's."
    },
    "klein-object-remove" => {
      "key" => "klein-object-remove",
      "repo_id" => "fal/flux-2-klein-4B-object-remove-lora",
      "weight_name" => "flux-object-remove-lora.safetensors",
      "targets" => %w[klein-4b klein-4b-base],
      "licence" => APACHE_2,
      "commercial_ok" => true,
      "repo_bytes" => 58.4e6,
      "steps" => nil,
      "guidance" => nil,
      "scheduler" => nil,
      "scale" => 1.0,
      "notes" => "fal's klein-4B object remover. Apache-2.0, so its output is " \
                 "commercially usable. No schedule of its own: it rides the " \
                 "model's."
    },
    "klein-outpaint" => {
      "key" => "klein-outpaint",
      "repo_id" => "fal/flux-2-klein-4B-outpaint-lora",
      "weight_name" => "flux-outpaint-lora.safetensors",
      "targets" => %w[klein-4b klein-4b-base],
      "licence" => APACHE_2,
      "commercial_ok" => true,
      "repo_bytes" => 76.0e6,
      "steps" => nil,
      "guidance" => nil,
      "scheduler" => nil,
      "scale" => 1.0,
      "notes" => "fal's klein-4B outpaint adapter. Apache-2.0, so its output is " \
                 "commercially usable. No schedule of its own: it rides the " \
                 "model's."
    },
    "klein-spritesheet" => {
      "key" => "klein-spritesheet",
      "repo_id" => "fal/flux-2-klein-4b-spritesheet-lora",
      "weight_name" => "flux-spritesheet-lora.safetensors",
      "targets" => %w[klein-4b klein-4b-base],
      "licence" => APACHE_2,
      "commercial_ok" => true,
      "repo_bytes" => 76.0e6,
      "steps" => nil,
      "guidance" => nil,
      "scheduler" => nil,
      "scale" => 1.0,
      "notes" => "fal's klein-4B spritesheet adapter. Apache-2.0, so its output " \
                 "is commercially usable. No schedule of its own: it rides the " \
                 "model's."
    },
    # The three Lightning files ship under ONE repo id and are three different
    # distilled schedules -- hence three entries and three weight_names rather
    # than one entry with a choice inside it.
    "sdxl-lightning-4step" => {
      "key" => "sdxl-lightning-4step",
      "repo_id" => "ByteDance/SDXL-Lightning",
      "weight_name" => "sdxl_lightning_4step_lora.safetensors",
      "targets" => %w[sdxl-1.0 ssd-1b],
      "licence" => SDXL_OPENRAIL_PP,
      "commercial_ok" => true,
      "repo_bytes" => 393.9e6,
      "steps" => 4,
      "guidance" => 0.0,
      "scheduler" => "trailing-euler",
      "scale" => 1.0,
      "notes" => "The 4-step SDXL Lightning schedule. Runs at guidance 0.0 with " \
                 "the trailing-euler scheduler; the model's own schedule is what " \
                 "this replaces."
    },
    "sdxl-lightning-2step" => {
      "key" => "sdxl-lightning-2step",
      "repo_id" => "ByteDance/SDXL-Lightning",
      "weight_name" => "sdxl_lightning_2step_lora.safetensors",
      "targets" => %w[sdxl-1.0 ssd-1b],
      "licence" => SDXL_OPENRAIL_PP,
      "commercial_ok" => true,
      "repo_bytes" => 393.9e6,
      "steps" => 2,
      "guidance" => 0.0,
      "scheduler" => "trailing-euler",
      "scale" => 1.0,
      "notes" => "The 2-step SDXL Lightning schedule. Runs at guidance 0.0 with " \
                 "the trailing-euler scheduler; the model's own schedule is what " \
                 "this replaces."
    },
    "sdxl-lightning-8step" => {
      "key" => "sdxl-lightning-8step",
      "repo_id" => "ByteDance/SDXL-Lightning",
      "weight_name" => "sdxl_lightning_8step_lora.safetensors",
      "targets" => %w[sdxl-1.0 ssd-1b],
      "licence" => SDXL_OPENRAIL_PP,
      "commercial_ok" => true,
      "repo_bytes" => 393.9e6,
      "steps" => 8,
      "guidance" => 0.0,
      "scheduler" => "trailing-euler",
      "scale" => 1.0,
      "notes" => "The 8-step SDXL Lightning schedule. Runs at guidance 0.0 with " \
                 "the trailing-euler scheduler; the model's own schedule is what " \
                 "this replaces."
    },
    "lcm-lora-sdxl" => {
      "key" => "lcm-lora-sdxl",
      "repo_id" => "latent-consistency/lcm-lora-sdxl",
      "weight_name" => "pytorch_lora_weights.safetensors",
      "targets" => %w[sdxl-1.0 ssd-1b],
      "licence" => SDXL_OPENRAIL_PP,
      "commercial_ok" => true,
      "repo_bytes" => 393.9e6,
      "steps" => 4,
      "guidance" => 1.0,
      "scheduler" => "lcm",
      "scale" => 1.0,
      "notes" => "LCM's SDXL distillation: 4 steps at guidance 1.0 with the lcm " \
                 "scheduler. Unlike Lightning it keeps CFG at 1.0, so a negative " \
                 "prompt still means something here."
    },
    "lcm-lora-sd15" => {
      "key" => "lcm-lora-sd15",
      "repo_id" => "latent-consistency/lcm-lora-sdv1-5",
      "weight_name" => "pytorch_lora_weights.safetensors",
      "targets" => %w[sd-1.5],
      # RAIL-M, matching SD 1.5 itself -- NOT the ++-M the SDXL sibling carries.
      # The two LCM adapters therefore differ in licence, which is exactly the
      # kind of thing a table transcribed on autopilot gets wrong: modifiers.py
      # is the file that loads it and is the side that wins.
      "licence" => SD15_OPENRAIL_M,
      "commercial_ok" => true,
      "repo_bytes" => 134.6e6,
      "steps" => 4,
      "guidance" => 1.0,
      "scheduler" => "lcm",
      "scale" => 1.0,
      "notes" => "LCM's SD 1.5 distillation: 4 steps at guidance 1.0 with the lcm " \
                 "scheduler. The 1.5 sibling of lcm-lora-sdxl, and half its size."
    },
    "pixel-art-xl" => {
      "key" => "pixel-art-xl",
      "repo_id" => "nerijs/pixel-art-xl",
      "weight_name" => "pixel-art-xl.safetensors",
      "targets" => %w[sdxl-1.0 ssd-1b],
      "licence" => SD15_OPENRAIL_M,
      "commercial_ok" => true,
      "repo_bytes" => 170.5e6,
      "steps" => 8,
      "guidance" => 1.5,
      "scheduler" => nil,
      "scale" => 1.0,
      "notes" => "A style adapter: pixel-art, at 8 steps and guidance 1.5. No " \
                 "scheduler recommendation of its own."
    },
    "logo-redmond" => {
      "key" => "logo-redmond",
      "repo_id" => "artificialguybr/LogoRedmond-LogoLoraForSDXL-V2",
      "weight_name" => "LogoRedmondV2-Logo-LogoRedmAF.safetensors",
      "targets" => %w[sdxl-1.0 ssd-1b],
      "licence" => SD15_OPENRAIL_M,
      "commercial_ok" => true,
      "repo_bytes" => 170.5e6,
      "steps" => nil,
      "guidance" => nil,
      "scheduler" => nil,
      "scale" => 1.0,
      "notes" => "A style adapter: logo marks. No schedule of its own — it rides " \
                 "the model's."
    },
    "colouring-book" => {
      "key" => "colouring-book",
      "repo_id" => "artificialguybr/ColoringBookRedmond-V2",
      "weight_name" => "ColoringBookRedmond-ColoringBook-ColoringBookAF.safetensors",
      "targets" => %w[sdxl-1.0 ssd-1b sd-1.5],
      "licence" => SD15_OPENRAIL_M,
      "commercial_ok" => true,
      "repo_bytes" => 170.5e6,
      "steps" => nil,
      "guidance" => nil,
      "scheduler" => nil,
      "scale" => 1.0,
      "notes" => "A style adapter: colouring-book line art. Targets the whole SD " \
                 "family, not only SDXL. No schedule of its own — it rides the " \
                 "model's."
    },
    "stickers" => {
      "key" => "stickers",
      "repo_id" => "artificialguybr/StickersRedmond",
      "weight_name" => "StickersRedmond.safetensors",
      "targets" => %w[sdxl-1.0 ssd-1b sd-1.5],
      "licence" => SD15_OPENRAIL_M,
      "commercial_ok" => true,
      "repo_bytes" => 170.5e6,
      "steps" => nil,
      "guidance" => nil,
      "scheduler" => nil,
      "scale" => 1.0,
      "notes" => "A style adapter: die-cut sticker shapes. Targets the whole SD " \
                 "family, not only SDXL. No schedule of its own — it rides the " \
                 "model's."
    },
    "papercut-sdxl" => {
      "key" => "papercut-sdxl",
      "repo_id" => "TheLastBen/Papercut_SDXL",
      "weight_name" => "papercut.safetensors",
      "targets" => %w[sdxl-1.0 ssd-1b],
      "licence" => SD15_OPENRAIL_M,
      "commercial_ok" => true,
      "repo_bytes" => 340.8e6,
      "steps" => nil,
      "guidance" => nil,
      "scheduler" => nil,
      "scale" => 1.0,
      "notes" => "A style adapter: layered papercut. No schedule of its own — it " \
                 "rides the model's."
    }
  }.freeze

  # The VAE swaps: which decoder a generation is decoded with, instead of the one
  # the checkpoint ships. `targets` is enforced the same way a modifier's is.
  #
  # `repo_bytes` is the actual DOWNLOAD -- the safetensors plus config -- not the
  # repo's total across every precision it publishes.
  #
  # The `tiny` entries are the TAESD autoencoders: a distilled decoder an order of
  # magnitude smaller than the real VAE. They are a preview tool, NOT a free
  # speed-up, and the notes say so rather than letting the size speak for itself.
  VAES = {
    "sdxl-vae-fp16-fix" => {
      "key" => "sdxl-vae-fp16-fix",
      "repo_id" => "madebyollin/sdxl-vae-fp16-fix",
      "targets" => %w[sdxl-1.0 ssd-1b],
      "tiny" => false,
      "licence" => MIT,
      "commercial_ok" => true,
      "repo_bytes" => 334.7e6,
      "notes" => "The fp16-safe SDXL VAE: the same decode as sdxl-vae, made safe " \
                 "to run in fp16. MIT."
    },
    "sdxl-vae" => {
      "key" => "sdxl-vae",
      "repo_id" => "stabilityai/sdxl-vae",
      "targets" => %w[sdxl-1.0 ssd-1b],
      "tiny" => false,
      "licence" => MIT,
      "commercial_ok" => true,
      "repo_bytes" => 334.7e6,
      "notes" => "The stock SDXL VAE, at the precision Stability AI published it " \
                 "in. MIT. sdxl-vae-fp16-fix is the fp16-safe variant of this " \
                 "same decode."
    },
    "sd-vae-ft-mse" => {
      "key" => "sd-vae-ft-mse",
      "repo_id" => "stabilityai/sd-vae-ft-mse",
      "targets" => %w[sd-1.5],
      "tiny" => false,
      "licence" => MIT,
      "commercial_ok" => true,
      "repo_bytes" => 334.7e6,
      "notes" => "The fine-tuned (EMA / MSE) SD 1.5 VAE. MIT. The 1.5 sibling of " \
                 "the two SDXL entries, so it is NOT interchangeable with them."
    },
    "taesdxl" => {
      "key" => "taesdxl",
      "repo_id" => "madebyollin/taesdxl",
      "targets" => %w[sdxl-1.0 ssd-1b],
      "tiny" => true,
      "licence" => MIT,
      "commercial_ok" => true,
      "repo_bytes" => 9.8e6,
      "notes" => "Tiny AutoEncoder for SDXL — a distilled decoder roughly 2 MB of " \
                 "weights against the VAE's ~335 MB. MIT. It decodes VISIBLY " \
                 "SOFTER than the real VAE: a sensible trade for a preview grid, " \
                 "not a free upgrade for a final image."
    },
    "taesd" => {
      "key" => "taesd",
      "repo_id" => "madebyollin/taesd",
      "targets" => %w[sd-1.5],
      "tiny" => true,
      "licence" => MIT,
      "commercial_ok" => true,
      "repo_bytes" => 9.8e6,
      "notes" => "Tiny AutoEncoder for SD 1.5 — the 1.5 sibling of taesdxl, and " \
                 "not interchangeable with it. MIT. It decodes VISIBLY SOFTER " \
                 "than the real VAE: a sensible trade for a preview grid, not a " \
                 "free upgrade for a final image."
    }
  }.freeze

  # The four SETTING cards, in the 2x2 grid. Each pairs with a card of similar
  # weight so neither row is stretched by a tall neighbour: Service|Model, then
  # Resolution|Hand-off. The live validation is deliberately NOT one of these --
  # it is a different kind of thing (an answer, not a setting), and wedging it
  # into the Resolution card stretched the whole row and left the Hand-off card
  # two-thirds empty.
  #
  # Each card's "?" documents that card's fields and nothing else: the help text
  # for a field is the field's own `:help`, so the <dt> list and the <label>s
  # cannot drift -- both are rendered from this one array. (The JSON page has the
  # same rule enforced by a test because its cards are hand-written; here the
  # structure makes drift impossible.)
  #
  # `env` is the variable the service actually reads. Fields without one are
  # request parameters, not environment.
  CARDS = [
    {
      title: "Service",
      help: "help-flux-service",
      blurb: "How a runner reaches the service. Every one of these is an " \
             "environment variable the service reads at call time, so nothing " \
             "in the flux repo names a host.",
      fields: [
        { label: "bind", env: "CHOPSHOP_FLUX_BIND", type: :text, default: DEFAULT_BIND,
          hint: "Loopback by default, deliberately.",
          help: "The address the service listens on. The default is loopback " \
                "rather than 0.0.0.0: a service that generates images and " \
                "streams them back has no business on every interface. " \
                "chopshop-svg's runner.py ships 0.0.0.0 and its own contract " \
                "doc calls that a footgun. Reaching this from elsewhere is an " \
                "explicit act — set it to the private address." },
        { label: "port", env: "CHOPSHOP_FLUX_PORT", type: :number, default: DEFAULT_PORT,
          min: 1, max: 65_535,
          hint: "8791 is the SVG runner, 8790 the studio's mock runner.",
          help: "8795 keeps it in the same range as the rest of the shop but " \
                "clear of both: chopshop-svg's runner owns 8791 and the " \
                "studio's mock runner owns 8790, so a collision here would look " \
                "like the wrong service answering." },
        { label: "out_dir", env: "CHOPSHOP_FLUX_OUT", type: :text, default: DEFAULT_OUT_DIR,
          hint: "Generated PNGs land here.",
          help: "Where generated PNGs are written — and the ONLY tree " \
                "GET /files/ will serve. The name in a download request arrives " \
                "over the network, so the service checks containment rather than " \
                "assuming it: anything resolving outside this directory is a 404." },
        { label: "token", env: "CHOPSHOP_FLUX_TOKEN", type: :text, default: "",
          hint: "Blank means every route is open.",
          help: "A bearer token, enforced on every route except /health when it " \
                "is set. /health is exempt on purpose: a health check that " \
                "requires the secret cannot be used to decide whether to send " \
                "the secret. Blank means open — which is why the bind default " \
                "is loopback." },
        { label: "url", env: "CHOPSHOP_FLUX_URL", type: :text,
          default: "http://#{DEFAULT_BIND}:#{DEFAULT_PORT}",
          hint: "Where the client looks for the service.",
          help: "The client's side of the same coin. This is what gen2pipe and " \
                "the rest of the CLI dial, which is how a runner on another " \
                "machine reaches a service on the GPU box without either end " \
                "knowing a hostname the other one does not." }
      ]
    },
    {
      title: "Model",
      help: "help-flux-model",
      blurb: "Which model, and what running it commits you to. The licence is " \
             "not decoration: every checkpoint here but sdxl-turbo leaves the " \
             "output yours to sell.",
      fields: [
        { label: "model", env: "CHOPSHOP_FLUX_MODEL", type: :select,
          default: DEFAULT_MODEL_KEY, options: MODELS.keys,
          hint: "klein-4b is the default: Apache 2.0.",
          help: "Which registered model to load. EIGHT are registered and every " \
                "one of them loads: the two klein, the two Sana Sprint, ssd-1b " \
                "and the three forerunner SD-family checkpoints. Note that ssd-1b " \
                "is an SDXL-architecture entry rather than a family of its own — " \
                "same pipeline class and resolution rules as sdxl-1.0. The model " \
                "decides the licence and the schedule, so it is the first field " \
                "to look at when an output is wrong. The SD-style entries take a " \
                "real negative prompt, and img2img takes a strength." },
        { label: "steps", env: nil, type: :number, default: nil, min: 1, max: 100,
          hint: "Follows the model. klein is distilled: 4.",
          help: "Inference steps. The default follows the model, and it is not " \
                "the pipeline class's default: Flux2KleinPipeline.__call__ " \
                "defaults to 50 steps because that is what a BASE model wants. " \
                "Running a distilled checkpoint at 50 is running the wrong " \
                "schedule, so the registry's value always overrides it." },
        { label: "guidance", env: nil, type: :number, default: nil, step: 0.1,
          min: 0, max: 20,
          hint: "1.0 on distilled klein. Above that is ignored.",
          help: "Classifier-free guidance. On a distilled klein it does " \
                "NOTHING: the pipeline's own do_classifier_free_guidance is " \
                "`guidance_scale > 1 and not is_distilled`, so it is always " \
                "false and diffusers logs \"Guidance scale X is ignored\". This " \
                "is also the whole reason a negative prompt has no effect — CFG " \
                "is the machinery a negative prompt acts through. If you " \
                "genuinely need real guidance, use klein-4b-base." },
        { label: "negative_prompt", env: nil, type: :text, default: nil,
          hint: "Only a model with a real CFG path (sdxl-1.0).",
          help: "What the generation should steer away from. A request " \
                "parameter, not environment: it rides with the request, and " \
                "it is only passed to the pipeline for a model whose registry " \
                "says negative_prompt: true — sdxl-1.0. Flux2KleinPipeline." \
                "__call__ has no such parameter at all, so a negative prompt " \
                "on klein is generated anyway and reported instead of silently " \
                "dropped: \"negative prompt ignored: klein-4b has no " \
                "negative_prompt parameter\"." },
        { label: "strength", env: nil, type: :number, default: nil, min: 0, max: 1,
          step: 0.05,
          hint: "img2img only, and only on sdxl-1.0, and only with a reference.",
          help: "How far an edit may move from the reference image, for the " \
                "SD-style model called as img2img. A request parameter, not " \
                "environment, and img2img-only in two senses: the service " \
                "passes strength= to the pipeline only for a model whose " \
                "registry says img2img_strength: true, and only when a " \
                "reference image is actually present — so a text-to-image call " \
                "never carries it, and a klein has no strength parameter to " \
                "carry it to. Blank means the key is not sent at all, leaving " \
                "the pipeline's own default in place rather than a zero." },
        { label: "offload", env: "CHOPSHOP_FLUX_OFFLOAD", type: :select,
          default: "cpu", options: %w[cpu none],
          hint: "None does not fit this card.",
          help: "Where the model's stages live between calls. 'cpu' pages each " \
                "stage in and out; 'none' keeps everything resident. Measured on " \
                "this box: the 4B weights are 15.97 GB against a card torch " \
                "reports as 15.92 GiB (17.10 GB), so resident runs reach VAE " \
                "decode with 174 MiB free and die there. 'none' is for measuring " \
                "the difference on a card that can afford it, not for using here." },
        { label: "vae_tiling", env: "CHOPSHOP_FLUX_VAE_TILING", type: :select,
          default: "0", options: %w[0 1],
          hint: "For large decodes. Off until measured.",
          help: "Decode the VAE in tiles, reducing the peak memory of the " \
                "decode. Off by default: the memory failure that prompted it was " \
                "in RESIDENT mode, which CPU offload removes, so it is left off " \
                "until something measured asks for it. Note the switch lives on " \
                "the VAE (pipe.vae.enable_tiling()) — Flux2KleinPipeline has no " \
                "enable_vae_tiling(), so the obvious call raises AttributeError " \
                "and tiling silently never happens." },
        { label: "ack_noncommercial", env: "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL",
          type: :select, default: "0", options: %w[0 1],
          hint: "Required to load a non-commercial model.",
          help: "The licence gate, and the one setting here that is a business " \
                "decision rather than a technical one. sdxl-turbo is Stability " \
                "AI's Non-Commercial Research Community Licence: research use " \
                "only, and commercial use of its output needs a licence from " \
                "Stability AI. Loading it requires this set explicitly, so a " \
                "commercial deployment cannot happen by accident. The check lives " \
                "in the registry, on every path that loads a model — not in the " \
                "view." }
      ]
    },
    {
      title: "Resolution",
      help: "help-flux-resolution",
      blurb: "FLUX.2's own limits, enforced by the service before anything loads: " \
             "a bad size is a caller error, not a failed generation.",
      fields: [
        { label: "width", env: nil, type: :number, default: 1024, min: MIN_DIMENSION,
          step: DIMENSION_MULTIPLE,
          hint: "Multiple of the model's own alignment — 16 on klein, 32 on Sana, 8 on SDXL.",
          help: "Pixels across. Every dimension must be a multiple of the MODEL's " \
                "own alignment and at least its own floor: 16 and 64 on the klein " \
                "family (what this card's defaults are set to), 32 and 512 on Sana, " \
                "8 and 128 on the SD family. That rule is the model's, not ours, so " \
                "it is not negotiable and the service rejects a violation as a 400 " \
                "rather than discovering it mid-generation." },
        { label: "height", env: nil, type: :number, default: 1024, min: MIN_DIMENSION,
          step: DIMENSION_MULTIPLE,
          hint: "Multiple of the model's own alignment.",
          help: "Pixels down, under the same rules as the width — the model's own " \
                "alignment and floor, and its own cap below. The pair is also " \
                "capped in total, so see the derived panel for what this request " \
                "comes to." },
        { label: "images", env: nil, type: :number, default: 1, min: 1, max: 8,
          hint: "Batched in one call.",
          help: "How many images one request produces, via " \
                "num_images_per_prompt. This is genuinely batched and is the " \
                "cheap kind of parallelism. Separate concurrent requests are " \
                "NOT parallel — there is one GPU, so a second request waits on a " \
                "lock rather than over-subscribing VRAM, and the response " \
                "reports how long it waited." }
      ]
    },
    {
      title: "Hand-off",
      help: "help-flux-handoff",
      blurb: "gen2pipe generates, fetches the raster, then calls chopshop-svg's " \
             "front pipeline. This layer calls the pipeline; the pipeline never " \
             "calls it.",
      fields: [
        { label: "pipeline", env: "CHOPSHOP_FLUX_PIPELINE", type: :text, default: "",
          hint: "A chopshop-svg checkout. Blank disables gen2pipe.",
          help: "Where front_pipeline.sh lives. Deliberately not defaulted: the " \
                "hand-off refuses to guess, because guessing where the pipeline " \
                "lives is how you trace the wrong tree — and across a network it " \
                "is how you trace someone else's. Only gen2pipe needs it." },
        { label: "sweep", env: nil, type: :text, default: "",
          hint: "Passed as --sweep=FILE.",
          help: "A sweep spec file to hand the pipeline, passed in the " \
                "equals form (--sweep=FILE). The two-token form hits " \
                "front_pipeline.sh's unknown-option path and the sweep is " \
                "silently not applied — chopshop-sui shipped exactly that bug, " \
                "and chopshop-flux carries a regression test for it." },
        { label: "skip_prep", env: nil, type: :select, default: "0", options: %w[0 1],
          hint: "Pass --skip-prep when the raster is already prepped.",
          help: "Skips the prep stage of the front pipeline. Use it when the " \
                "generated raster is already the size and colour space you want, " \
                "so prep does not re-do work that would change nothing. It never " \
                "silently transforms a source — prep is check-first, and this is " \
                "the explicit way to say you do not want it run at all." }
      ]
    }
  ].freeze

  # The FIFTH card: the GPU-contention guard, full width outside the 2x2 setting
  # grid for the same reason Checks and the deployment card are -- it is not a
  # setting of the generated image, it is what happens when the CARD is already
  # busy. It is a card rather than rows inside another one because the card is
  # SHARED (LM Studio, ollama, a second generation) and that is where the
  # operator's "why was my run refused" question lands.
  #
  # Transcribed from chopshop-flux's `chopshop_flux/config.py` (the five
  # `guard_*` accessors) and its `docs/API.md` error table. The env names, the
  # defaults and the meaning of each mode are the service's own; the parity test
  # compares this inventory against config.py, so a knob that changes there and
  # not here fails the suite rather than drifting quietly (that drift is
  # issue #13, and it was found by inspection because nothing checked it).
  GUARD = {
    title: "GPU",
    help: "help-flux-gpu",
    blurb: "This card is SHARED, and the guard decides what happens when another " \
           "process is already holding it. It is a refusal the operator meets as " \
           "503 gpu_busy \u2014 retry, do not fix the request \u2014 and only where the " \
           "guard is set to refuse; the default warn never returns it.",
    fields: [
      { label: "guard", env: "CHOPSHOP_FLUX_GUARD", type: :select, default: "warn",
        options: %w[off warn wait block],
        hint: "What to do when the card is already held.",
        help: "How to treat a GPU another process is holding. off \u2014 never check " \
              "(a card dedicated to this service); warn \u2014 the DEFAULT, which records " \
              "what the guard found and generates anyway, because a box with a small " \
              "model resident can still fit a load and a service that refuses by " \
              "default breaks a pipeline on a box that only LOOKS full; wait \u2014 hold " \
              "the request until the card clears, up to its own budget " \
              "(CHOPSHOP_FLUX_GUARD_WAIT seconds), then refuse; block \u2014 refuse " \
              "immediately and let the caller " \
              "retry. Only the two refusing modes produce the refusal: warn generates " \
              "and warns, and never answers 503." },
      { label: "guard_vram_gb", env: "CHOPSHOP_FLUX_GUARD_VRAM_GB", type: :number,
        default: 5.0, min: 0, step: 0.5,
        hint: "Free VRAM required before a load is attempted.",
        help: "Free VRAM, in decimal GB, that has to be there before a load is " \
              "attempted. Under offload=cpu the peak is ONE stage, not the whole " \
              "model, so this is deliberately not the model's total size: the " \
              "recorded datapoint is an SDXL 4-image batch at 1024px that tried to " \
              "allocate 4.83 GB with 4.47 GB free. Below the line a generation is a " \
              "coin flip, which is where 5.0 sits." },
      { label: "guard_wait", env: "CHOPSHOP_FLUX_GUARD_WAIT", type: :number,
        default: 120, min: 0,
        hint: "Seconds wait holds a request before refusing.",
        help: "How long guard=wait holds a request before refusing. A generation in " \
              "flight frees the card when it ends; a model merely RESIDENT does not, " \
              "which is why this is a budget and not a loop." },
      { label: "guard_poll", env: "CHOPSHOP_FLUX_GUARD_POLL", type: :number,
        default: 5, min: 1,
        hint: "Seconds between VRAM readings while waiting.",
        help: "Seconds between VRAM readings while guard=wait is holding a request." },
      { label: "lmstudio_url", env: "CHOPSHOP_FLUX_LMSTUDIO_URL", type: :text,
        default: "",
        hint: "Names the holder in a refusal. Attribution only.",
        help: "LM Studio's local server, so a refusal can NAME what is holding the " \
              "card instead of only how much memory is missing. Attribution only: the " \
              "gate itself is free VRAM, which catches every holder, not just LM " \
              "Studio \u2014 and there is no way to ask LM Studio whether it is queuing, " \
              "which is why the gate is the memory reading. Unset by default, like " \
              "every other address in the service's config." }
    ],
    entries: [
      ["the refusal: 503 gpu_busy", "The one 503 on this service. The request was " \
                                    "well-formed and the CARD was not free, so it is " \
                                    "not a caller error and retrying is the right " \
                                    "response \u2014 a queued caller backs off rather " \
                                    "than spins. It appears only where the guard " \
                                    "refuses (block, or wait after its budget expired), " \
                                    "so a default deployment never returns it."],
      ["the card is shared, and the arithmetic is unforgiving", "MEASURED: a resident " \
                                                                "262144-context LM " \
                                                                "Studio model had its " \
                                                                "llama-server holding " \
                                                                "16.21 GB of 17.10 GB, " \
                                                                "while one klein-4b " \
                                                                "offload=cpu stage wants " \
                                                                "~5 GB. Both cannot be " \
                                                                "true at once, which is " \
                                                                "why the guard exists."],
      ["/health's engine.gpu_guard", "The gate's own reading, in the /health engine " \
                                     "block, so a busy card is legible WITHOUT a failed " \
                                     "generation: mode, required_free_gb, free_gb, " \
                                     "measured, contended, lmstudio, notes, last."]
    ]
  }.freeze

  # The tips block: how to get a good result OUT of the model the operator picked.
  # Four things, each a sentence or two on the card and the reasoning behind its
  # "?" \u2014 the same split the four setting cards use. The measurements are
  # chopshop-flux's `docs/MODELS.md`, which is where a reader goes for the numbers
  # these sentences come from; the printable numbers themselves (dpi, max_colors)
  # live in the pipeline's print spec and are NOT restated here as a second set.
  TIPS = {
    title: "Tips",
    help: "help-flux-tips",
    blurb: "What to know before you press Generate. The axis that matters here is " \
           "not how a frame looks on screen \u2014 it is whether the trace stage can " \
           "turn it into a good print, which is flat colour, legible shapes, edges " \
           "that survive vectorisation and few inks.",
    items: [
      ["distilled vs undistilled", "Steps and guidance are not knobs on a distilled " \
                                   "checkpoint: 2\u20134 steps is the schedule, more " \
                                   "steps do NOT help, and guidance is ignored on " \
                                   "klein-4b and sdxl-turbo (it is embedded and " \
                                   "honoured on the Sana entries). The undistilled " \
                                   "entries run 25\u201330 steps and there guidance is " \
                                   "honoured and measured to matter. No step-count " \
                                   "speedup can be claimed on this box: stage paging " \
                                   "dominates, not per-step compute."],
      ["which entries have a REAL negative prompt", "The SD-family ones: sdxl-1.0, " \
                                                    "sd-1.5 and ssd-1b \u2014 write " \
                                                    "one, it works. sdxl-turbo accepts " \
                                                    "the parameter but CFG is off at " \
                                                    "its guidance 0.0, so it does " \
                                                    "nothing there. The two klein " \
                                                    "entries and both Sana entries " \
                                                    "have no negative_prompt " \
                                                    "parameter at all: a negative " \
                                                    "prompt is ignored, and the " \
                                                    "studio tells you so rather than " \
                                                    "dropping it silently."],
      ["generate at the model's native size", "1024 px on klein, sdxl-1.0, sdxl-turbo " \
                                              "and ssd-1b; 512 px on sd-1.5 and the " \
                                              "Sana entries. Above it the model " \
                                              "invents anatomy, below it it loses " \
                                              "composition. Every dimension must be " \
                                              "a multiple of that entry's own " \
                                              "alignment \u2014 a size that breaks its " \
                                              "rules is a 400 before anything loads, " \
                                              "not a bad frame."],
      ["the print formula", "Subject + ink count + art style + simplification + " \
                            "composition. Name the ink count in the prompt (\"exactly " \
                            "three flat ink colours\"), ask for flat colour and thick " \
                            "uniform outlines, a plain white ground, no gradients and " \
                            "no soft shadows, and keep hairlines and fine detail out " \
                            "\u2014 they trace into nodes nobody wants to cut. The " \
                            "printable numbers are the job's own spec (dpi 300, " \
                            "max_colors); a 12-inch front print at 300 dpi is ~3600 px."]
    ],
    entries: [
      ["why flat colour, and why the ink count", "\"Three spot colours\" measurably " \
                                                 "steers a model away from subtle " \
                                                 "shading, and it is what makes a " \
                                                 "frame separable for print \u2014 the " \
                                                 "same reason the pipeline's own " \
                                                 "max_colors exists. A gradient-heavy " \
                                                 "frame is the worst possible input " \
                                                 "to the tracer."],
      ["judge a source by its trace, not by itself", "A candidate that looks good and " \
                                                     "traces into 400 nodes is worse " \
                                                     "for this job than a plainer " \
                                                     "frame that traces into 60. The " \
                                                     "pipeline's own comparison and " \
                                                     "tournament surfaces measure " \
                                                     "that; the studio never picks a " \
                                                     "winner."],
      ["the seed is a knob, not a constant", "One frame is one sample: run several " \
                                             "seeds and compare, because the frame " \
                                             "you would have shipped is not " \
                                             "necessarily the first one."],
      ["steps and guidance follow the model", "The pipeline class's defaults are the " \
                                              "BASE model's schedule (50 steps at " \
                                              "guidance 4.0 on Flux2KleinPipeline), so " \
                                              "running a distilled checkpoint at them " \
                                              "runs the wrong schedule entirely. The " \
                                              "steps and guidance boxes on this page " \
                                              "follow the model select for that " \
                                              "reason."],
      ["where these sentences come from", "The per-model sentences in MODELS and this " \
                                          "block are transcribed from " \
                                          "chopshop-flux's docs/MODELS.md, which " \
                                          "carries the measurements behind them " \
                                          "(MEASURED means run on this box; anything " \
                                          "else is marked ESTIMATE)."]
    ]
  }.freeze

  # The live validation card, which runs the service's own rules in the browser.
  # `entries` documents what the card shows, in the same field-help vocabulary
  # the setting cards use, so its "?" reads like theirs.
  CHECKS = {
    title: "Checks",
    help: "help-flux-checks",
    blurb: "What the service does with the settings above, in its own order, and " \
           "what this request comes to. This page does not run the service; it " \
           "runs the same rules, so a request the service would reject is " \
           "rejectable before anything loads.",
    entries: [
      ["pixels", "width x height, against the cap on the right. Shown as a share " \
                 "of the cap so a request that is legal but heavy is visible as " \
                 "heavy rather than only as legal. The cap is INCLUSIVE: 2048x2048 " \
                 "IS 4 MP exactly, so it is allowed."],
      ["verdict", "Accepted or rejected, by the same checks the service runs " \
                  "before it loads anything. A violation is a 400 — a caller " \
                  "error — not a failed generation, which is why the problems " \
                  "appear in the JSON as well as in the status line."],
      ["the checks, in order", "Integer, then the selected model's floor, then its alignment, then its pixel cap. The first failure reported is the first one the service would hit, because the order is its order."]
    ]
  }.freeze

  # The derived legend under the Checks card: what the service checks, in the
  # order it checks it, with the message it actually raises.
  #
  # The labels are the RULES, not one family's numbers. Every model carries its
  # own rules (klein 16 / 64 / 4 MP, SDXL 8 / 128 / 2 MP, Sana 32 / 512 / 1 MP)
  # and both #validate and the page's JS read them from the spec, so a legend
  # that named klein's as though they were everyone's would be the same bug the
  # per-model rules exist to prevent -- one family's floor quoted as another's
  # truth. The numbers are given as examples so the defaults stay findable.
  SIZE_RULES = [
    ["integer", "A dimension must be an integer. A JSON body with 1024.0 in it is a caller error, not a rounding opportunity."],
    ["the model's floor", "The model's own minimum on either side — 64 for the klein family, 512 for Sana."],
    ["the model's alignment", "The model's own alignment, not ours and not negotiable: multiples of 16 for klein, 32 for Sana, 8 for the SD family."],
    ["the model's pixel cap", "The model's own cap on width x height — 4 MP for klein, 2 MP for SDXL, 1 MP for Sana. Inclusive: 2048x2048 IS 4 MP exactly and is allowed."]
  ].freeze

  # The two ways this is deployed, on the page because it was the first question
  # the page did not answer: where does any of this run, and what has to be true
  # of a box for it to work there. Both shapes are the same code — the only
  # difference is two environment variables, one on each side.
  PLACEMENT = {
    title: "Where it runs",
    help: "help-flux-placement",
    blurb: "This page configures a SERVICE. The service and this studio are two " \
           "programs that talk over HTTP, and the only thing joining them is a " \
           "URL — so the same pair runs on one machine or on two, and nothing " \
           "here names a host.",
    shapes: [
      ["one box", "The service and this studio on the same machine. The service " \
                  "listens on #{DEFAULT_BIND} — loopback, so nothing on the " \
                  "network can reach it — and the studio's runner URL is a " \
                  "loopback address too. Nothing to expose, nothing to " \
                  "authenticate. This is the shape a laptop or a single " \
                  "workstation wants.",
       [["CHOPSHOP_FLUX_BIND=#{DEFAULT_BIND}", "where the service listens — loopback"],
        ["CHOPSHOP_RUNNER_FLUX_URL=http://127.0.0.1:#{DEFAULT_PORT}", "where the studio calls"]]],
      ["split", "The studio on one machine, the GPU on another — a VPS driving a " \
                "box at home, say. Over a private network (a tailnet, a LAN, a " \
                "tunnel) the GPU box sets the bind to the address the studio can " \
                "reach it on AND sets a token; the studio sets its runner URL to " \
                "that same address. Both are required together: a generation " \
                "endpoint on a shared network with no token is somebody else's " \
                "free GPU.",
       [["CHOPSHOP_FLUX_BIND=<the private address>", "on the GPU box: where it listens"],
        ["CHOPSHOP_FLUX_TOKEN=<shared secret>", "on the GPU box: who may call it"],
        ["CHOPSHOP_RUNNER_FLUX_URL=http://<that address>:#{DEFAULT_PORT}",
         "on the studio box: where the GPU is"]]]
    ],
    entries: [
      ["one box / split", "The two deployments this supports. They differ only " \
                          "in the URLs and whether a token is set — not in code, " \
                          "not in a build, not in a config file in either repo."],
      ["the URL is the whole seam", "A runner is a URL and a kind. The service " \
                                    "does not know which machine the studio is " \
                                    "on, and the studio does not know which " \
                                    "machine the GPU is on. Neither repo is " \
                                    "allowed to record a host, so moving either " \
                                    "end is an edit to one environment variable."],
      ["other applications", "The service is a plain HTTP API — #{API[:routes]} — " \
                             "and this studio is one client of it, not its " \
                             "reason for existing. Anything that can send a POST " \
                             "can generate an image without knowing this studio " \
                             "exists. That is why the studio holds a token of its " \
                             "own rather than sharing the pipeline's."],
      ["turning it off", "The service is a program you start and stop, so the GPU " \
                         "is yours when you want it — and stopping it is a normal " \
                         "state, not a fault. Run Job shows it offline, and a flux " \
                         "job fails with the service's own message instead of " \
                         "waiting. Start it again and nothing needs reconfiguring."],
      ["the raster comes back over /files/", "The service reports where it wrote " \
                                             "the PNG on ITS disk, which is " \
                                             "useless to a studio on another " \
                                             "machine. So the studio fetches the " \
                                             "bytes from the documented " \
                                             "/files/<name> route instead — the " \
                                             "same route any other client would " \
                                             "use."]
    ]
  }.freeze

  class << self
    def model(key)
      MODELS[key] || MODELS[DEFAULT_MODEL_KEY]
    end

    def model_for(key)
      MODELS[key.to_s]
    end

    # The three resolution facts that constrain a request, read from the model's
    # own entry: models.py puts them on the ModelSpec, per family, and so does
    # MODELS. One reader, so #facts, #validate and the page cannot disagree about
    # which family's rules apply to the model in front of them.
    #
    # The module-level MIN_DIMENSION / DIMENSION_MULTIPLE / DEFAULT_MAX_PIXELS are
    # the FLUX.2 [klein] family's values and are only the fallback for an entry
    # that carries none: applying one family's floor to another is how a legal
    # SDXL or Sana request gets refused, or an illegal one accepted.
    def limits(model_key)
      spec = model(model_key)
      {
        "min_dim" => spec["min_dim"] || MIN_DIMENSION,
        "dim_multiple" => spec["dim_multiple"] || DIMENSION_MULTIPLE,
        "max_pixels" => spec["max_pixels"] || DEFAULT_MAX_PIXELS
      }
    end

    # A modifier by key, or nil. Strict like #model_for rather than lenient like
    # #model: an unknown modifier is a caller error #validate has to be able to
    # SEE, and a fallback would hide it.
    def modifier(key)
      MODIFIERS[key.to_s]
    end

    # The modifiers that may load against a model, by the same `targets` list the
    # service gates on. This is the ONE place the filtering lives: the form, the
    # JSON and #validate all read it rather than each deciding what "applies".
    def modifiers_for(model_key)
      key = model_key.to_s
      MODIFIERS.values.select { |entry| Array(entry["targets"]).include?(key) }
    end

    # The VAE swaps that may load against a model, on the same rule.
    def vaes_for(model_key)
      key = model_key.to_s
      VAES.values.select { |entry| Array(entry["targets"]).include?(key) }
    end

    # The licence gate, in the registry's own words, for a model, a modifier or
    # a VAE alike: a checkpoint that may not be sold is the same business
    # decision whoever published it, and the one acknowledgement clears all
    # three. Returns the sentence, or nil when there is nothing to say.
    def licence_problem(entry, ack)
      return nil unless entry["commercial_ok"] == false
      return nil if ack.to_s == "1"
      "#{entry['key']} is #{entry['licence']} — non-commercial use only. " \
        "Loading it requires an explicit acknowledgement " \
        "(CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1) so a commercial deployment cannot " \
        "happen by accident; commercial use of its output requires a licence " \
        "from the model's licensor."
    end

    # Everything the page needs to validate a request, handed to the browser as
    # one JSON blob so the rules are NOT restated in JavaScript. A second copy of
    # a rule is a second thing to get wrong.
    #
    # `models` keeps its existing shape (a key -> spec map) and `modifiers` /
    # `vaes` are handed over the same way, so the form filters a modifier or a
    # VAE through the SAME `targets` list #validate gates on rather than through
    # a list re-typed in the view.
    def facts
      {
        "constraints" => {
          "minDimension" => MIN_DIMENSION,
          "dimensionMultiple" => DIMENSION_MULTIPLE,
          "maxPixels" => DEFAULT_MAX_PIXELS,
          "defaultModel" => DEFAULT_MODEL_KEY
        },
        "models" => MODELS,
        "modifiers" => MODIFIERS,
        "vaes" => VAES
      }
    end

    # Validate a request exactly as the service does, and return the SAME
    # sentences. Returns problems and warnings separately because the service
    # treats them differently: a violation is a 400 the caller must fix, a
    # warning is something the service does anyway and tells you about.
    #
    # `modifiers` is the list of LoRA keys a request asked to stack, and `vae`
    # the decoder swap. Both are checked against the registry here rather than
    # left to the service, for the same reason the size rules are: a load that
    # will fail is a caller error, and finding out after the GPU has been paid
    # for is the expensive way.
    def validate(width:, height:, images:, model_key:, guidance:, ack:,
                 negative_prompt: nil, strength: nil, modifiers: nil, vae: nil,
                 references: nil)
      problems = []
      warnings = []
      spec = model(model_key)

      # The model's OWN rules, not the klein constants at the top of this file.
      # Every entry carries dim_multiple/min_dim/max_pixels, so this reads one
      # place and a family can never inherit another family's floor.
      limits = limits(model_key)
      min_dim = limits["min_dim"]
      dim_multiple = limits["dim_multiple"]
      max_pixels = limits["max_pixels"]

      [["width", width], ["height", height]].each do |label, value|
        if value.nil? || value.to_s.strip.empty?
          problems << "#{label} is required"
          next
        end
        unless value.to_s.match?(/\A-?\d+\z/)
          problems << "#{label} must be an integer, got #{value}"
          next
        end
        n = value.to_i
        problems << "#{label} must be at least #{min_dim}, got #{n}" if n < min_dim
        if n % dim_multiple != 0
          problems << "#{label} must be a multiple of #{dim_multiple}, got #{n}"
        end
      end

      if images.to_s.match?(/\A-?\d+\z/) && images.to_i < 1
        problems << "images must be a positive integer, got #{images}"
      end

      pixels = nil
      if problems.empty?
        pixels = width.to_i * height.to_i
        if pixels > max_pixels
          problems << "#{width}x#{height} is #{pixels} pixels, over the " \
                      "#{max_pixels} cap"
        end
      end

      # The guidance warning is the engine's, and it says what the pipeline does
      # rather than what we wish it did. The `guidance_embedded` guard is the
      # engine's too, and it is not cosmetic: a distilled pipeline that embeds
      # guidance in the prompt ACTS on the number without running CFG, so the
      # Sana rows honour a guidance we would otherwise call ignored. Warning
      # there would be a claim about the service that the service contradicts.
      if spec["distilled"] && !spec["guidance_embedded"] &&
         guidance.to_s.match?(/\A\d+(\.\d+)?\z/) && guidance.to_f != spec["default_guidance"].to_f
        warnings << "guidance_scale #{guidance} is ignored: #{spec['key']} is " \
                    "step-wise distilled, so the pipeline never runs " \
                    "classifier-free guidance. That is also why a negative prompt " \
                    "has no effect on it — put the steering in the prompt and the " \
                    "reference image."
      end

      # Nor is the size always honoured, and a caller who asked for a size does
      # not find out otherwise: resolution binning quietly re-bins a request to
      # the pipeline's own buckets. Mirrors the engine's own warning.
      if spec["resolution_binning"]
        warnings << "#{spec['key']} runs with resolution binning enabled, so a " \
                    "requested size without a matching bucket is re-binned to one " \
                    "the pipeline has — check the returned image's width and height " \
                    "rather than assuming the ones asked for."
      end

      # The two request parameters a model may not have. The service generates
      # anyway and says so in `warnings` rather than silently dropping them, and
      # so does this: a caller who asked for a negative prompt on a distilled
      # klein needs to know it did nothing.
      if negative_prompt.to_s.strip.present? && !spec["negative_prompt"]
        warnings << "negative prompt ignored: #{spec['key']} has no " \
                    "negative_prompt parameter"
      end
      if strength.to_s.strip.present? && !spec["img2img_strength"]
        warnings << "strength ignored: #{spec['key']} is not an SD-style " \
                    "img2img model"
      end

      # Modifiers: an unknown key, an adapter that cannot load against the chosen
      # model, or one whose licence needs the acknowledgement.
      #
      # The unknown sentence is the SERVICE's, character for character
      # (modifiers._resolve: "unknown %s '%s' (known: %s)"), including the SORTED
      # key list — the service sorts its "known:" names, and a studio that listed
      # them in registry order would be a different sentence.
      #
      # The TARGETS sentence is deliberately NOT the service's, and this is the
      # one place the studio is stricter than the thing it mirrors. engine.py's
      # modifier_warnings accepts an off-target adapter and warns:
      #   "modifier %s targets %s, not %s: it will be applied anyway, but it was
      #    not trained for this model, so its output is not what its own card
      #    shows."
      # The studio makes that a PROBLEM instead, so the form cannot assemble a
      # request whose output is not what the operator's card shows. A hand-edited
      # spec still reaches the service, which warns — this is the PAGE's check,
      # and it is the strict half of the pair on purpose.
      selected = []
      Array(modifiers).each do |raw|
        key = raw.to_s.strip
        next if key.empty?
        entry = modifier(key)
        if entry.nil?
          problems << "unknown modifier '#{key}' (known: " \
                      "#{MODIFIERS.keys.sort.join(', ')})"
          next
        end
        selected << entry
        unless Array(entry["targets"]).include?(spec["key"])
          problems << "modifier '#{key}' does not target #{spec['key']} " \
                      "(it targets #{Array(entry['targets']).join(', ')})"
        end
        if (sentence = licence_problem(entry, ack))
          problems << sentence
        end
      end

      # A modifier that carries its own schedule overrides the request's, so a
      # guidance that disagrees with it is reported exactly the way a distilled
      # model's is: the schedule that actually runs is the modifier's. The
      # service says the same thing in its own words (engine.modifier_warnings:
      # "guidance %s is in effect but %s was trained at guidance %s"); this
      # phrasing is the studio's, kept parallel to the distilled-model warning
      # directly above so the two read as one family of sentence.
      if guidance.to_s.match?(/\A\d+(\.\d+)?\z/)
        selected.each do |entry|
          recommendation = entry["guidance"]
          next if recommendation.nil?
          next if recommendation.to_f == guidance.to_f
          warnings << "guidance_scale #{guidance} is ignored: #{entry['key']} " \
                      "runs #{entry['steps']} steps at guidance " \
                      "#{recommendation}, so the modifier's own schedule wins."
        end
      end

      # The VAE swap, under the same rules as a modifier.
      vae_key = vae.to_s.strip
      if vae_key.present?
        entry = VAES[vae_key]
        if entry.nil?
          problems << "unknown vae '#{vae_key}' (known: #{VAES.keys.sort.join(', ')})"
        else
          unless Array(entry["targets"]).include?(spec["key"])
            problems << "vae '#{vae_key}' does not target #{spec['key']} " \
                        "(it targets #{Array(entry['targets']).join(', ')})"
          end
          if (sentence = licence_problem(entry, ack))
            problems << sentence
          end
        end
      end

      # Multi-reference, under the same "reject before the GPU" rule as every
      # other registry check. Whether a request may carry SEVERAL references is a
      # property of the checkpoint (`multi_reference`), not a studio preference:
      # the FLUX.2 [klein] family declares a list in its `image=` and conditions
      # on all of them at once, and every img2img family (SDXL, SSD-1B, SD 1.5,
      # Sana Sprint) takes exactly one.
      #
      # The sentence is the SERVICE'S, character for character (engine.py:
      # "%s takes a single reference image, but %d were given. ..."), because the
      # service is what refuses this -- a 400 naming the model, before anything is
      # loaded. Restating it in the studio's own words would give an operator two
      # different explanations of one refusal. The studio's only addition is
      # WHERE it was caught, which is the point of checking here at all: a form
      # error the operator can fix, instead of a paid-for round trip to a GPU box
      # that was always going to say no.
      reference_count = Array(references).map { |r| r.to_s.strip }.reject(&:empty?).size
      if reference_count > 1 && !spec["multi_reference"]
        problems << "#{spec['key']} takes a single reference image, but " \
                    "#{reference_count} were given. Multi-reference is a property " \
                    "of the checkpoint: a pipeline that declares a list for its " \
                    "'image' conditions on all of them at once (the FLUX.2 [klein] " \
                    "family does), and an img2img pipeline takes exactly one."
      end

      # The licence gate, in the registry's own words.
      if (sentence = licence_problem(spec, ack))
        problems << sentence
      end

      { problems: problems, warnings: warnings, pixels: pixels, spec: spec }
    end
  end
end