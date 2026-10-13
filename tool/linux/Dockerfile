# Match the pinned, separately built LGPL libmpv's glibc baseline.
FROM ubuntu:22.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils clang cmake ninja-build pkg-config \
    libgtk-3-dev libsecret-1-dev liblzma-dev libstdc++-12-dev \
    dpkg-dev rpm binutils desktop-file-utils file \
    && rm -rf /var/lib/apt/lists/*
