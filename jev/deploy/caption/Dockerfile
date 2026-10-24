# chopshop-caption — containerised local captioner (runs anywhere Docker does).
#
# The captioner needs CPU torch + torchvision + transformers. This image builds
# that environment from scratch so it does not depend on a host-mounted venv.
#
# BUILD CONTEXT IS `jev/`, NOT THIS DIRECTORY. The script lives where the rest of
# the Jev scripts live (`jev/scripts/caption_serve.py`), and COPY cannot climb
# out of its context with `..`. So compose builds this as
#
#     build:
#       context: ./jev
#       dockerfile: deploy/caption/Dockerfile
#
# which keeps ONE copy of the service (the same file the harness and the systemd
# unit run) instead of a second one beside the Dockerfile that would drift.
#
# Host PATHS and SECRETS are configuration, not facts about this machine -- no
# box-specific path or token is baked in. The model cache is a runtime mount,
# and the API key is a compose variable; see the `caption` service and
# `.env.example`.

FROM python:3.14-slim

# Install CPU torch first, then torchvision, then transformers.
# Pinned to the exact releases the host's proven install runs. The gate is an
# IMPORT check rather than an install exit code, so a wheel that installs but
# cannot load (the wrong ABI, a missing lib) fails the build instead of the
# first caption.
RUN pip install --no-cache-dir torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cpu \
    && pip install --no-cache-dir "transformers>=5.1" \
    && python3 -c "import torch, torchvision, transformers; print(f'torch {torch.__version__}, torchvision {torchvision.__version__}, transformers {transformers.__version__}')"

WORKDIR /app

# The captioner itself -- the same file `jev/scripts/` ships and the systemd unit
# points at, not a copy.
COPY scripts/caption_serve.py /app/caption_serve.py

# The service speaks a simple HTTP API on port 8798.
#
# NOTE ON THE BIND: CAPTION_HOST=0.0.0.0 inside the container is what the publish
# layer needs (a 127.0.0.1 listener accepts and then resets a forwarded
# connection), and the service REFUSES to bind off loopback without
# CAPTION_API_KEY. So this image run bare needs the key set; with it unset the
# container exits naming the variable, which is the honest failure.
EXPOSE 8798
CMD ["python3", "/app/caption_serve.py"]
