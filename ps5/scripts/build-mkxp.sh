#!/usr/bin/env bash
# Configure and build mkxp for the PS5. Runs inside the mkxp-ps5-dev image
# with the mkxp checkout mounted at /src.
#
# Usage: build-mkxp.sh [payload|native|all]
#   payload  ELF payload for an ELF loader, software OpenGL (OSMesa)
#   native   title folder, GPU OpenGL through ps5-opengl
#   all      both (default; 'native' only if the image has its toolchain)
#
# Output in /src/ps5/out:
#   mkxp.elf (+ libOSMesa.so.8, if the image has it)   payload
#   <title id>/                                       native title folder

set -euo pipefail

SRC="${SRC:-/src}"
OUT="${OUT:-${SRC}/ps5/out}"
MODE="${1:-all}"
: "${PS5_NATIVE:=/opt/ps5-native}"

source "${PS5_PAYLOAD_SDK}/toolchain/prospero.sh"

build_payload() {
    local build="${SRC}/ps5/build/payload"

    ${CMAKE} -S "${SRC}" -B "${build}" \
             -DCMAKE_BUILD_TYPE=Release \
             -DCMAKE_VERBOSE_MAKEFILE=OFF \
             -DBINDING=MRI -DMRIVERSION=3.1
    ${CMAKE} --build "${build}" -j"$(nproc)"

    mkdir -p "${OUT}"
    "${STRIP}" --strip-debug -o "${OUT}/mkxp.elf" "${build}/mkxp.elf"
    cp "${SRC}/mkxp.conf.sample" "${OUT}/"

    # Runtime OpenGL implementation, dlopen()ed by SDL on the console. The
    # payload loader also searches the working directory, which mkxp sets
    # to its own location, so it can simply sit next to mkxp.elf.
    local osmesa="${PS5_SYSROOT}${PS5_HBROOT}/lib/libOSMesa.so.8"
    if [ -e "${osmesa}" ]; then
        cp -L "${osmesa}" "${OUT}/"
    else
        echo "note: image built without mesa; libOSMesa.so.8 must already be" \
             "installed on the console (e.g. in /user/homebrew/lib)" >&2
    fi

    echo "Built ${OUT}/mkxp.elf"
}

build_native() {
    local build="${SRC}/ps5/build/native"
    local native="${SRC}/ps5/native"

    # SDL2 resolves to the ps5-opengl build; the link step produces a
    # title folder instead of an ELF (see native/native-link.sh)
    ${CMAKE} -S "${SRC}" -B "${build}" \
             -DCMAKE_BUILD_TYPE=Release \
             -DCMAKE_VERBOSE_MAKEFILE=OFF \
             -DBINDING=MRI -DMRIVERSION=3.1 -DPS5_NATIVE=ON \
             -DPKG_CONFIG_EXECUTABLE="${native}/native-pkg-config" \
             -DCMAKE_CXX_LINK_EXECUTABLE="${native}/native-link.sh <OBJECTS> -o <TARGET> <LINK_LIBRARIES>"
    mkdir -p "${OUT}"
    NATIVE_OUT="${OUT}" ${CMAKE} --build "${build}" -j"$(nproc)"
    cp "${SRC}/mkxp.conf.sample" "${OUT}/"
}

case "${MODE}" in
    payload) build_payload ;;
    native) build_native ;;
    all)
        build_payload
        if [ -d "${PS5_NATIVE}/boilerplate" ]; then
            build_native
        else
            echo "note: image built without the native toolchain" \
                 "(WITH_NATIVE=0); skipping the native title" >&2
        fi
        ;;
    *) echo "usage: $0 [payload|native|all]" >&2; exit 2 ;;
esac
