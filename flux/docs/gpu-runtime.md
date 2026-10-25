# Running chopshop-flux on a GPU: the NVIDIA path and the ROCm path

The service is vendor-neutral: it asks torch which device it has, and it reports
the answer. `/health` carries

```json
{"device": "cuda", "device_name": "Tesla T4", "torch": "2.6.0+cu124", "rocm": null}
```

`rocm` is `torch.version.hip` — non-null means the interpreter is a HIP build —
so the SAME code path serves both vendors. What differs is the **host plumbing**,
and that is the whole subject of this page.

Outside a container, the plumbing is your distribution's problem: a working CUDA
or ROCm install, and a venv built against it. Inside a container, the kernel
driver stays on the host and has to be handed in. There are two tracked overlays
for that, so the choice is one flag rather than a research project:

| host GPU | overlay | what it passes in |
|---|---|---|
| NVIDIA | `docker-compose.nvidia.yml` | device nodes + the driver libraries |
| AMD (ROCm) | `docker-compose.rocm.yml` | `/dev/kfd`, `/dev/dri`, the video/render groups |

```bash
# NVIDIA
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml up -d --build flux

# AMD / ROCm
docker compose -f docker-compose.yml -f docker-compose.rocm.yml up -d --build flux
```

Both are additive: they say nothing about ports, tokens or paths, so the base
file stays the single place those are described.

## Which one is this machine?

```bash
nvidia-smi                       # exits 0 on an NVIDIA host
rocm-smi                         # exits 0 on a ROCm host
ls -l /dev/kfd /dev/dri          # ROCm-only nodes
```

A host with neither has no GPU to give and the service will serve but not
generate. Its `/health` says so: `torch` is `null` until the first load, and torch
is imported LAZILY, so a `200` on `/health` is not evidence either way. Generate
something.

## The two things outside the overlays

The overlays deliberately contain no absolute host path, because a venv path is a
fact about one machine. Both go in the untracked `docker-compose.override.yml`
(see `docker-compose.override.yml.example`):

1. **The GPU venv, mounted, and the interpreter to run it under.** The venv that
already has torch + diffusers + accelerate belongs on the host, not in the image
— that is why the Dockerfile ships the service code and no torch.

   ```yaml
   services:
     flux:
       volumes:
         - /path/to/gpu-venv:/gpu-venv:ro
       environment:
         CHOPSHOP_FLUX_PYTHON: /gpu-venv/bin/python
   ```

   **If the venv's `bin/python` is a symlink into a separate interpreter install**
   (uv, pyenv, asdf, and every venv made with `uv venv`), the mount above gives a
   container a python that points at an absolute path outside itself. Mount that
   install too, **at its own path**, so the symlink still resolves:

   ```yaml
   # print it with: <venv>/bin/python -c 'import sys; print(sys.base_prefix)'
   volumes:
     - /the/interpreter/base:/the/interpreter/base:ro
   ```

2. **Nothing else.** No device or driver stanza, no `group_add` — that is what
   the overlays are for, and duplicating them in two files is how one of them
   ends up stale.

## NVIDIA: the trap is the library DIRECTORY

The device list is the part everyone gets right. The part that fails is this:

> Mount `libcuda.so.1` at its own host path and it is **visible** in the
> container while torch still reports no GPU.

The image is Debian. Its dynamic loader does not search `/usr/lib64`, so a driver
mounted at `/usr/lib64/libcuda.so.1` sits there unread and `dlopen` fails with

```
OSError: libcuda.so.1: cannot open shared object file: No such file or directory
```

`torch.cuda.is_available()` is then `False` in a container whose `/usr/lib64`
plainly contains the driver, which reads as "the device was not passed through"
and sends you to fix a device list that was already correct.

The overlay mounts the same two files into the multiarch directory
(`/usr/lib/x86_64-linux-gnu/`), which is where the loader looks on Debian. On a
host that keeps its driver elsewhere, point `CHOPSHOP_FLUX_DRIVER_DIR` at it.

Only the two files that are needed are mounted, not the whole driver tree:
`libcuda.so.1` is what torch loads, and `libnvidia-ml.so.1` is what the GPU guard
queries for free VRAM. Without the second, the guard cannot measure the card and
says so rather than guessing.

## ROCm: userspace is in the venv, not on the host

There is nothing to mount. A ROCm torch wheel carries its own HIP runtime
(libamdhip64, MIOpen, hipBLASLt, rocBLAS); the host supplies the kernel driver,
which is reachable through `/dev/kfd` and `/dev/dri` once the process is in the
`video` and `render` groups. So the whole overlay is three keys, and the venv
mount from the section above is the only other thing ROCm needs.

`/dev/kfd` is the giveaway that a host is not a ROCm host, and asking for it
anyway fails at container-create time:

```
Error: stat /dev/kfd: no such file or directory
```

That is a platform mismatch, not a compose bug. Do not add the device.

## Verify it, from inside the container

Do this before blaming the service: it answers the question "did the plumbing
work" without loading a 15 GB model.

```bash
# One question per line. Single-quoted on the host and expanded by the
# container's shell, so there is no escaping to get wrong.
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml exec flux \
  sh -lc '"$CHOPSHOP_FLUX_PYTHON" -c "import torch; print(\"avail\", torch.cuda.is_available())"'

docker compose -f docker-compose.yml -f docker-compose.nvidia.yml exec flux \
  sh -lc '"$CHOPSHOP_FLUX_PYTHON" -c "import torch; print(\"cuda\", torch.version.cuda, \"rocm\", torch.version.hip)"'
```

`True` on the first, `cuda 12.4 rocm None` on the second: the NVIDIA path.
`True` and a HIP version in the `rocm` slot: the ROCm path. Both are the same
`torch.cuda` namespace — that is why one service serves both, and why the code
has no vendor branch in it.

Then a real generation is the only proof of the whole chain:

```bash
curl -s -X POST 127.0.0.1:8795/generate -H 'Content-Type: application/json' \
  -d '{"prompt":"a woodcut fox in two inks, thick outlines, flat vector","model":"sd-1.5","width":512,"height":512,"steps":20,"seed":1234}'
```

A frame with real detail in it, not a blank square: a smoke test at 256 px proves
the API, not the model.

## dtype: one knob that changes with the card, not the vendor

`CHOPSHOP_FLUX_DTYPE` is per-card, and it matters more than it looks. Default is
`bfloat16`, which is right on any card with native bf16. Cards without it —
NVIDIA Turing (sm_75) and older, and older AMD GCDs — execute bf16 by upcasting:

```
MEASURED, 4096^2 GEMM:  float16  5.55 ms   |  bfloat16 54.94 ms   |  float32 32.42 ms
```

bf16 is slower than fp32 there. It is also a CORRECTNESS switch: Sana's DC-AE
raises `GET was unable to find an engine to execute this computation` from a
conv2d in bf16 on sm_75, and generates normally in fp16. The full account is in
`README.md` and `docs/MODELS.md`; set `CHOPSHOP_FLUX_DTYPE=float16` in the
untracked override or the env file when the card needs it.

## Troubleshooting, in the order the failures actually appear

| symptom | cause |
|---|---|
| `Error: stat /dev/kfd: no such file or directory` | the ROCm overlay on a host without ROCm |
| `torch.cuda.is_available()` is `False`, and `ls` shows the driver in the container | the driver is mounted at `/usr/lib64`, where Debian's loader does not look — use the NVIDIA overlay |
| `avail True` but the guard reports no free VRAM | `libnvidia-ml.so.1` is not mounted |
| `exec: /gpu-venv/bin/python: not found` right after a mount that looks right | the venv's python is a symlink; mount the interpreter base at its own path |
| `/health` is `200` with `"torch": null` | nothing has loaded yet — torch is imported lazily; generate something |
| `avail True` and a generation still OOMs | another process holds the card; see `CHOPSHOP_FLUX_GUARD` in `README.md` |
