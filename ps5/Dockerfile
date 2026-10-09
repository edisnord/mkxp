# Reproducible build environment for mkxp on the PlayStation 5, using
# ps5-payload-dev/sdk and ps5-payload-dev/pacbrew-repo.
#
# See ps5/README.md for usage.

# Overridable so that e.g. a corporate proxy CA can be layered on top.
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates sudo git curl wget xz-utils bzip2 unzip file \
        build-essential pkg-config pkgconf cmake meson ninja-build \
        autoconf automake libtool autopoint gettext bison flex gperf \
        yasm nasm python3 python3-mako python3-pyelftools \
        clang-18 lld-18 llvm-18 \
        libarchive-tools makepkg pacman-package-manager fakeroot \
        ruby xxd mm-common \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf

# Upstream revisions, pinned for reproducibility. Bump deliberately.
ARG PS5_SDK_COMMIT=10b539de8f2b6773a9a78caa7576a97dbd99b29a
ARG PS5_PACBREW_COMMIT=dbb6998c90910f58d4f781fc2cab0ecb5ac202b4
ARG PS5_SDL_COMMIT=ee4c47dc0d617b3bc8f35108f9956baf228a1322

ENV PS5_PAYLOAD_SDK=/opt/ps5-payload-sdk \
    SRCDEST=/home/builder/sources \
    PS5_SDK_COMMIT=${PS5_SDK_COMMIT} \
    PS5_SDL_COMMIT=${PS5_SDL_COMMIT} \
    PACBREW_DIR=/home/builder/pacbrew-repo

# makepkg refuses to run as root
RUN useradd -m builder \
    && echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder \
    && mkdir -p ${PS5_PAYLOAD_SDK} && chown builder:builder ${PS5_PAYLOAD_SDK}
USER builder
WORKDIR /home/builder

RUN git clone https://github.com/ps5-payload-dev/pacbrew-repo.git ${PACBREW_DIR} \
    && git -C ${PACBREW_DIR} checkout ${PS5_PACBREW_COMMIT}

# Optional pre-seeded source tarballs (see README). makepkg and build-deps.sh
# still verify their checksums; anything missing is downloaded from upstream.
COPY --chown=builder:builder sources/ ${SRCDEST}/
COPY --chown=builder:builder scripts/build-pacbrew.sh /usr/local/bin/build-pacbrew.sh

ARG MAKEFLAGS=-j4
ENV MAKEFLAGS=${MAKEFLAGS}

# SDK, C++ runtime and the libraries mkxp links against
RUN build-pacbrew.sh sdk openlibm libcxx \
        zlib bzip2 libpng libjpeg-turbo libwebp freetype \
        libsamplerate libogg libvorbis \
        SDL2 SDL2_image SDL2_ttf openal

# OpenGL: SDL's PS5 video driver dlopen()s libOSMesa.so.8 (software llvmpipe)
# at runtime, so mesa (and the LLVM it JITs with) is only needed on the
# console, not for linking. Kept in its own layer since it takes the longest;
# pass --build-arg WITH_MESA=0 to skip it if libOSMesa is already installed
# on the console.
ARG WITH_MESA=1
RUN if [ "${WITH_MESA}" = 1 ]; then build-pacbrew.sh expat zstd llvm mesa; fi

# mkxp dependencies not provided by pacbrew-repo
COPY --chown=builder:builder scripts/build-deps.sh /usr/local/bin/build-deps.sh
COPY --chown=builder:builder patches /home/builder/patches
COPY --chown=builder:builder compat /home/builder/compat
# (the sysroot is root-owned after the pacman installs above)
RUN sudo chown -R builder:builder ${PS5_PAYLOAD_SDK}/target && build-deps.sh

# Native title with GPU OpenGL (ps5-opengl). Pass --build-arg WITH_NATIVE=0
# to build only the payload.
ARG WITH_NATIVE=1
ENV PS5_NATIVE=/opt/ps5-native
COPY --chown=builder:builder native/setup-native.sh native/sdl-g19-render-thread.patch \
     /home/builder/native/
RUN if [ "${WITH_NATIVE}" = 1 ]; then \
        sudo apt-get update \
        && sudo apt-get install -y --no-install-recommends libclang-rt-18-dev \
        && sudo rm -rf /var/lib/apt/lists/* \
        && sudo install -d -o builder -g builder ${PS5_NATIVE} \
        && /home/builder/native/setup-native.sh; \
    fi

WORKDIR /src
