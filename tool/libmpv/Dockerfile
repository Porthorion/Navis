# LGPL libmpv for Navis Linux bundles. Ubuntu 22.04 keeps the glibc baseline
# of the Linux release build (docs/release/release-linux.md).
FROM ubuntu:22.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential nasm pkg-config python3 python3-pip ninja-build git \
      ca-certificates curl xz-utils patchelf \
      libgnutls28-dev zlib1g-dev libfreetype-dev libfribidi-dev \
      libharfbuzz-dev libfontconfig-dev libasound2-dev libpulse-dev \
      libvulkan-dev \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir 'meson==1.6.1' 'jinja2==3.1.4'
COPY build_linux_lgpl.sh /build.sh
COPY Dockerfile /Dockerfile
ENTRYPOINT ["/bin/bash", "/build.sh"]
