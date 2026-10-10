# chopshop-bp — containerised blend + plot service (runs anywhere Docker does)
#
# Debian 13 (trixie) base.  bp is pure-stdlib Python (no third-party imports),
# so there is NO pip/venv step here: the package runs on the base python3.13.
# The one heavy, non-packaged dependency is headless Blender 4.2 LTS, which --
# exactly as on the host -- is installed from the official portable tarball
# (Blender is not shipped in Debian 13 apt in a form the service can use).
#
# Host PATHS are configuration, not facts about this machine -- no box-specific
# path is baked in.  The blender binary and the render output dir are supplied
# at runtime (see docker-compose.yml / the service env), so the same image runs
# on any box.

FROM debian:13

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        ca-certificates \
        wget \
        xz-utils \
        libx11-6 libxext6 libxi6 libxrender1 libxrandr2 libxxf86vm1 \
        libxfixes3 libxcursor1 libxinerama1 libgl1 libglu1-mesa \
        libsm6 libice6 libwayland-client0 libwayland-cursor0 libwayland-egl1 \
        libegl1 libdbus-1-3 \
        libxkbcommon0 libxkbcommon-x11-0 \
        libfontconfig1 libfreetype6 \
        fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# Blender 4.2.9 LTS (matches the host install): official portable tarball,
# extracted to /opt, PATH-extended.  Pinned to the exact release so the image
# is reproducible and matches the renderer the fixtures were captured against.
ENV BLENDER_VERSION=4.2.9
RUN set -eux; \
    wget -q "https://download.blender.org/release/Blender4.2/blender-${BLENDER_VERSION}-linux-x64.tar.xz" -O /tmp/blender.tar.xz; \
    mkdir -p /opt/blender; \
    tar -xJf /tmp/blender.tar.xz -C /opt/blender --strip-components=1; \
    rm -f /tmp/blender.tar.xz; \
    ln -s /opt/blender/blender /usr/local/bin/blender; \
    blender --version

WORKDIR /app

# bp is pure-stdlib, so the RUNTIME image needs no pip/venv.  But the tests
# use pytest (not in the Debian base), and this image gates the build on a
# green suite (same as the svg runner).  Install pytest into a THROWAWAY
# target dir used only for this gate (Debian 13 marks the env PEP-668
# externally-managed, hence --break-system-packages pip install --target);
# the runtime service stays clean stdlib and pytest is not left behind.
COPY . .
RUN apt-get update && apt-get install -y --no-install-recommends python3-pip \
    && pip install --no-cache-dir --break-system-packages --target=/tmp/testdeps pytest \
    && PYTHONPATH=/tmp/testdeps python3 -m pytest tests/ -q \
    && rm -rf /tmp/testdeps \
    && apt-get purge -y python3-pip && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# The container runs the service: same CLI as the host unit
# (`cli.py serve --bind 0.0.0.0 --port 8796`).  Host-side, bind to 127.0.0.1
# via compose (published as 127.0.0.1:8796) so it stays loopback-only, exactly
# like the native unit did.
EXPOSE 8796
CMD ["python3", "cli.py", "serve", "--bind", "0.0.0.0", "--port", "8796"]
