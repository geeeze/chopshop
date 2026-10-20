# chopshop-laya — containerised local decision service (runs anywhere Docker does).
#
# laya is a published pip package (laya[serve]), NOT a checkout: the host
# install is a venv built by pip, so the container builds the same way. The
# proven recipe (see the host's install script) installs the CPU torch wheel
# FIRST, then laya[serve]: the default PyPI torch on Linux is the CUDA build,
# ~2 GB of download for a card the target may not have. This service runs on
# CPU by default (LAYA_DEVICE=cpu); GPU is an override concern.
#
# Host PATHS and SECRETS are configuration, not facts about this machine -- no
# box-specific path or token is baked in. The service binds 0.0.0.0 in the
# container (a literal host/tailnet IP can never bind inside a container netns
# -- that is what crash-loops the native unit with OSError errno 99); exposure
# is the publish layer's job (see docker-compose.yml).

FROM python:3.13-slim

# CPU torch first, then laya[serve] (pulls transformers, fastapi, uvicorn).
# Pinned to the exact releases the host's proven install runs (laya 0.3.21,
# torch 2.14.0+cpu) so the image reproduces the wire behaviour the caller
# (the Jev annotator) is written against. Unpin deliberately, not casually.
# The gate is an IMPORT check, not `laya-serve --help`: MEASURED, laya-serve
# ignores --help and starts the uvicorn server (which then also pulls model
# weights at startup), hanging the build forever. Importing laya.serve proves
# the install without booting anything.
RUN pip install --no-cache-dir torch==2.14.0 --index-url https://download.pytorch.org/whl/cpu \
    && pip install --no-cache-dir "laya[serve]==0.3.21" \
    && python3 -c "import laya.serve, laya.mcp.device; print('laya ok')"

# The service speaks the TypeSafe SystemOne wire protocol: POST /v1/systemone.
#
# Verify inside the image with --entrypoint, e.g.:
#   podman run --rm --entrypoint sh chopshop-laya:0.1.0 -c "pip show laya"
# A bare `podman run <img> <cmd>` passes <cmd> as ARGS to laya-serve, which
# boots the server and tries to preload checkpoints (network!) instead of
# running your command.
EXPOSE 8797
ENTRYPOINT ["laya-serve"]
