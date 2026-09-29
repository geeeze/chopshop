# Adding models, LoRA adapters and VAE swaps

How to extend the generation registry: what to verify, in what order, and the GPU
traps that make an otherwise-correct implementation fail. Everything marked
MEASURED was run on the real card; treat the rest as procedure.

## The order of work

1. **Enumerate the repo from the HF API, never from the model card's prose.**
   `https://huggingface.co/api/models/<repo_id>?blobs=true` returns the licence
   slug, the gating flag and a per-file size for every `rfilename`. Two things
   come out of it that nothing else gives you:
   - `gated` (`false` / `auto`) — an `auto` repo needs a token and fails a plain
     download, so it is a different deployment story.
   - the exact weight FILENAMES and byte sizes, which is what a LoRA
     `weight_name` and a `repo_bytes` figure have to be. Guessing a filename is
     the most common way this goes wrong.
2. **Decide the licence from the LICENCE FILE, and prefer the conservative
   reading when the card disagrees with it** (the `sdxl-turbo` case — see the
   flux-jobs reference). If the licence is not nameable (`license: other` with no
   `license_name`, or no licence field at all), do not register the model.
3. **`repo_bytes` means the DOWNLOAD, not the repo's total.** A repo holds every
   precision it ever published (fp16 + fp32 + onnx + single-file variants), so
   summing all `safetensors` can be several times what `from_pretrained` fetches —
   49 GB of SDXL weights against ~14 GB needed. Size the entry from the files the
   pipeline actually pulls.
4. **Check the pipeline class's OWN defaults before writing the entry.** A class
   default is not a neutral starting point: it is the *base* model's schedule, so
   a distilled checkpoint at the class default runs the wrong schedule entirely.
   Read them, then override deliberately. MEASURED on the installed diffusers:
   `Flux2KleinPipeline` 50 / 4.0, `SanaSprintPipeline` 2 / 4.5,
   `SanaSprintImg2ImgPipeline` 2 / 4.5 (`strength=0.6`), `SanaPipeline` 20 / 4.5,
   `PixArtSigmaPipeline` 20 / 4.5, `StableDiffusionXLPipeline` 50 / 5.0.
5. **Check what the class does NOT accept** the same way — by inspecting
   `__call__`'s signature, not by assuming parity with a sibling family. A
   pipeline with no `negative_prompt` parameter needs the entry's flag off AND
   the service emitting its "ignored" warning, or the operator is handed a knob
   that silently does nothing. Also look for a default that CHANGES the request:
   `use_resolution_binning` on the Sana pipelines silently re-bins a size that is
   not one of the model's buckets, so a caller who asked for a size is not told it
   changed.
6. **Prove it on the card before claiming the entry works.** A registry entry that
   passes a unit suite can still be a model this hardware cannot run. Download it
   and generate one frame, checking for CONTENT rather than a zero exit code.

## MEASURED: the diffusers call order that makes a VAE swap work

This is the trap worth the most. With `enable_model_cpu_offload()` already
applied, reassigning `pipe.vae = AutoencoderKL.from_pretrained(...)` loads fine
and then **the next generation dies**:

```
RuntimeError: Expected all tensors to be on the same device, but found at least
  two devices, cuda:0 and cpu!
```

raised inside the SCHEDULER's `step` (LCM here), which names the wrong component —
nothing is wrong with the scheduler. accelerate's offload device map was built
over the ORIGINAL VAE, so the newly assigned VAE sits outside it.

Three orderings, same seed, SDXL + LCM-LoRA, 512x512, 4 steps:

| ordering | result |
|---|---|
| assign `pipe.vae`, THEN `enable_model_cpu_offload()` | OK (2.6 s, stdev 65.2) |
| offload, assign `pipe.vae`, offload AGAIN | OK (1.9 s, identical output) |
| offload, assign `pipe.vae`, no re-offload | **FAILS** (device mismatch) |

So the required build order is:

```
from_pretrained -> scheduler override -> load_lora_weights per adapter
  -> set_adapters(scales) -> VAE assignment -> enable_model_cpu_offload() LAST
```

and if a VAE ever must be swapped on a live offloaded pipe, re-calling
`enable_model_cpu_offload()` after the assignment is a VERIFIED fix.

**Do not extend this rule to the scheduler.** Swapping to
`EulerDiscreteScheduler(timestep_spacing="trailing")` after the offload is fine
(MEASURED, stdev 84.9) — the scheduler is not in the device map, only
module-bearing components are. Adding a constraint the hardware does not require
makes the code harder to reason about for no gain.

Pin the sequence with a test on a FAKE pipeline that records the order of
vae-assign / scheduler-assign / load_lora_weights / set_adapters / offload and
asserts the offload is LAST. That test is what stops this regressing, because the
failure only appears on a real GPU run.

## MEASURED: LoRA needs `peft`, and it must be VENDORED

`diffusers` refuses LoRA loading without `peft`: `is_peft_available()` returned
False and `import peft` raised ModuleNotFoundError in the GPU environment. That
environment belongs to another project and must not be modified, so vendor the one
package beside the checkout and put it on the path:

```bash
pip install --no-deps --target .vendor peft
# then run with PYTHONPATH pointing at .vendor
```

(`--target` is the point: it writes only into that directory.) VERIFIED afterwards
that the host environment *still* cannot `import peft` on its own, and that
`is_peft_available()` is True with the path set. `accelerate` is vendored the same
way for the same reason.

LoRA works end to end MEASURED (SDXL, 512x512, offload=cpu): `load_lora_weights`
+ `set_adapters(adapter_weights=[...])` at 1.0 and 0.5 distinctly change the
output, and two adapters coexist (`get_active_adapters()` lists both).

## MEASURED timings, and the honest way to quote them

| what (512x512, offload=cpu) | seconds |
|---|---|
| `sdxl-1.0` from_pretrained + cpu offload | 8.3 |
| base SDXL 30 steps | 15.0 |
| LCM-LoRA 4 steps | 11.2 |
| same, adapter weight 0.5 | 1.3 |

**A distilled/LCM checkpoint is NOT proportionally faster.** 4 steps vs 30 steps
came out 11.2 s vs 15.0 s: under CPU offload the per-step compute is no longer the
bottleneck, the stage paging is. Fewer steps is strictly less work, but any large
speedup claim from a low-step model on this box is false, and the notes must not
make one.

Sana Sprint 0.6B MEASURED, at its own schedule (2 steps, guidance 4.5):
`from_pretrained` 3.7 s; first 1024x1024 frame **39.7 s**; subsequent 1024x1024
**2.5 s**; 512x512 2.1 s; 15.58 GB free of 17.10 GB VRAM between calls. Quote the
cold and warm numbers TOGETHER — the first call carries a large one-off warm-up,
so either figure alone misleads.

SSD-1B MEASURED, 1024x1024 at its 25 / 7.5 schedule: load + offload 34.2 s; first
call 6.1 s; second 4.4 s; frames non-blank. The fastest 1024px checkpoint of the
three, at the cost of being a 25-step undistilled model.

klein-4b-base MEASURED, 1024x1024 at 28 steps / guidance 4.0: load 1.3 s, one frame
**58.8 s** — against klein-4b's ~3.5 s at 512px. An undistilled checkpoint pays for
every step under CPU offload, so its notes must carry the cost next to the benefit.

### Proving a CFG model really honours guidance

An entry's justification is often "undistilled, so guidance does something". That is a claim about
behaviour, so measure it rather than quoting the card: generate twice from the SAME seed and prompt
at two guidance values, then take the **mean absolute pixel difference** between the frames. Anything
above ~1.0 means the number changed the image (klein-4b-base: **34.38** between guidance 4.0 and
1.0, both frames non-blank, where the distilled klein-4b ignores the value entirely). Report both
frames' content spread alongside the difference so "they differ" cannot be satisfied by noise or by a
blank one.

### "distilled" in a model's NAME is not the `distilled` field

Read the field, never the marketing name. Segmind's `SSD-1B` is called distilled because the
checkpoint was PRUNED from SDXL — not because it runs a few-step schedule, and it is `distilled=False`
at guidance 7.5. An entry whose notes call it "the distilled checkpoint" while its own `distilled`
field is False is self-contradictory, and the contradiction survives review because the note and the
field are read by different people at different times. Derive every behavioural sentence in the notes
from the FIELD, and re-read the notes of anything you touch when a field changes.

## Licence triage — the rejections matter as much as the accepts

Record WHY a candidate was refused, in the repo's own research notes; it is
cheap to re-derive wrongly later and someone will ask.

- **No decidable licence → do not register:** `stabilityai/sd-turbo` (no licence
  field; README says commercial is fine while `LICENSE.md` is the Stability
  Community License), `ByteDance/Hyper-SD` (no licence field),
  `ostris/ikea-instructions-lora-sdxl` (`other` only).
- **Gated → different deployment story:** `stabilityai/stable-diffusion-3.5-medium`,
  `black-forest-labs/FLUX.1-schnell`.
- **Too large for the card or the repo:** `FLUX.2-klein-9B` and its `-base`
  (~24 GB VRAM against 17 GB), `Alpha-VLLM/Lumina-Image-2.0` (31.7 GB),
  `PixArt-alpha/*` (a T5-XXL text encoder dominates disk and VRAM for a
  superseded architecture).
- **Non-commercial:** `tianweiy/DMD2` (CC-BY-NC).
- **A hidden pass-through term:** Apache-2.0 on the weights is not the whole
  licence. `Efficient-Large-Model/Sana_*` ships a Gemma-2 text encoder, so
  Google's Gemma Terms of Use ride along — name that in the entry's notes.

Style LoRAs for the SDXL family are typically `creativeml-openrail-m` (commercial
OK) at ~170 MB each, cheap enough that the registry can carry several.

## Practicalities

- Downloads land in `HF_HOME`; check free disk BEFORE starting (a 40 GB SDXL repo
  plus several models adds up). `du -sh` of the hub shows what is resident.
- The `hf download` CLI comes from the GPU environment's venv and works without a
  token for ungated repos; expect an unauthenticated-requests warning.
- A `tiny` VAE (TAESD/TAESDXL, ~10 MB) decodes visibly softer — say that in its
  notes rather than presenting it as a free speed-up.
- A failed first attempt is worth checking for a BLANK frame rather than only a
  non-zero exit: a uniform black PNG written as a success is the failure mode a
  content check exists to catch.
