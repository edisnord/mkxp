#!/usr/bin/env bash
# Build and install a list of ps5-payload-dev/pacbrew-repo packages into
# /opt/ps5-payload-sdk. Runs as an unprivileged user (makepkg refuses root)
# with passwordless sudo for pacman.
#
# Usage: build-pacbrew.sh PKG [PKG...]
#
# Environment:
#   PACBREW_DIR       checkout of ps5-payload-dev/pacbrew-repo
#   PS5_SDK_COMMIT    commit of ps5-payload-dev/sdk to pin the 'sdk' package to
#   PS5_SDL_COMMIT    commit of ps5-payload-dev/SDL to pin the 'SDL2' package to

set -euo pipefail

: "${PACBREW_DIR:?PACBREW_DIR must be set}"

for PKG in "$@"; do
    echo "==> pacbrew: ${PKG}"
    cd "${PACBREW_DIR}/${PKG}"

    # Pin packages that otherwise track a git HEAD, for reproducibility.
    case "${PKG}" in
        sdk)
            sed -i "s|sdk.git'|sdk.git#commit=${PS5_SDK_COMMIT}'|" PKGBUILD
            sed -i "s|sdk.git\"|sdk.git#commit=${PS5_SDK_COMMIT}\"|" PKGBUILD
            ;;
        SDL2)
            sed -i "s|SDL.git'|SDL.git#commit=${PS5_SDL_COMMIT}'|" PKGBUILD
            ;;
    esac

    rm -rf src pkg ./*.pkg.tar.*
    # -d: dependencies are resolved by the ordering given on the command
    #     line, not by pacman (e.g. openal lists ffmpeg/libsndfile as
    #     makedepends although its configuration does not use them).
    makepkg -d -f -c --noconfirm
    sudo pacman --noconfirm -dd -U ./ps5-payload-*.pkg.tar.*
    rm -rf src pkg ./*.pkg.tar.* ./*.tar.gz ./*.tar.xz ./*.tar.bz2
done
