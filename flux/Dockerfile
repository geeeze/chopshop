# chopshop-flux — containerised generation service (runs anywhere Docker does).
#
# The service code is pure-stdlib Python (see requirements.txt: the repo has NO
# install-time dependencies), so the runtime image needs no pip/venv step for
# the service itself. The HEAVY runtime — torch + diffusers — is deliberately
# NOT baked in: it is a multi-GB, platform-specific GPU stack (here: ROCm for a
# Radeon RX 9070 XT) that belongs to the machine that has the GPU, exactly as
# requirements.txt states. Supply it at run time by mounting a GPU venv and
# pointing CHOPSHOP_FLUX_PYTHON at it (see docker-compose.yml), or extend this
# image per host.
#
# Host PATHS are configuration, not facts about this machine — no box-specific
# path is baked in.
#
# The container binds 0.0.0.0 and is published loopback-only by default; the
# literal-tailnet-IP bind that crash-loops the native unit (OSError errno 99)
# can never work inside a container netns — exposure is the publish layer's job.

FROM debian:13

# libatomic.so.1: required by EVERY Linux torch wheel (the GPU runtime is a
# bind-mounted venv, but the system lib it links against must live here).
# Measured: without it the service's first `import torch` dies mid-import and
# leaves a broken torch in sys.modules, so the failure that surfaces later is
# a confusing `torch has no attribute '_utils'`.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        ca-certificates \
        libatomic1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Service code (stdlib). The tests gate the build on a green suite (same as
# bp / the svg runner): pytest goes into a THROWAWAY target dir used only for
# the gate (Debian 13 is PEP-668 externally-managed, hence
# --break-system-packages --target), then is removed so the runtime stays clean.
COPY . .
RUN apt-get update && apt-get install -y --no-install-recommends python3-pip \
    && pip install --no-cache-dir --break-system-packages --target=/tmp/testdeps pytest \
    && PYTHONPATH=/tmp/testdeps python3 -m pytest tests/ -q \
    && rm -rf /tmp/testdeps \
    && apt-get purge -y python3-pip && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# The service runs under the GPU venv's interpreter when one is mounted and
# CHOPSHOP_FLUX_PYTHON points at it (set in docker-compose.yml /
# docker-compose.override.yml), falling back to the base python3 (serves but
# cannot generate). Same CLI as the host unit: `<python> -m chopshop_flux serve`.
EXPOSE 8795
CMD ["sh", "-c", "exec \"${CHOPSHOP_FLUX_PYTHON:-python3}\" -m chopshop_flux serve"]
