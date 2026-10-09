#!/usr/bin/env bash
# Builds Outsider, a native runtime for RPG Maker MV/MZ games (JavaScript in
# QuickJS-NG, OpenGL rendering, SoLoud audio), for linking into mkxp: one
# relocatable object that defines only outsider_main(), next to the
# JavaScript shims it loads at run time.
#
# Outsider gets the PS5 port from Tsukuru Player (an SDL2 platform layer,
# DualSense touchpad, MV compatibility work), and outsider-mkxp.patch on top:
# GPU OpenGL through ps5-opengl, and outsider_main() in place of main().
# Everything is pinned and verified.
#
# Usage: build-outsider.sh ps5|host <output dir>
#   ps5   for the native title (PS5 toolchain, SDL2 with ps5-opengl's driver)
#   host  for the machine it runs on, with the system's SDL2 (for tests)
#
# Output: <output dir>/outsider.o and <output dir>/shims/

set -euo pipefail

TARGET=$1
OUT=$2

OUTSIDER_COMMIT=f789f467942bd47449c481941bec38bc8a234a4c
SOLOUD_COMMIT=e82fd32c1f62183922f08c14c814a02b58db1873
# The QuickJS-NG revision Tsukuru Player builds Outsider with
QUICKJS_COMMIT=2f0aa72a6b09cf69ff06399bcf9f4c083ac1a278
TSUKURU_COMMIT=9cdcf19058d9e663b1eea9b801194fab7cebc1fa
TSUKURU_PATCH_SHA256=35e48a943cb357e0286c6d7107de790e6c6f6064f41f2cd5a47e0c45b4c024cf

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# clone_at URL COMMIT DIR
clone_at() {
    git clone -q "$1" "$3"
    git -C "$3" -c advice.detachedHead=false checkout -q "$2"
    [ "$(git -C "$3" rev-parse HEAD)" = "$2" ]
}

case "${TARGET}" in
    ps5)
        : "${PS5_PAYLOAD_SDK:=/opt/ps5-payload-sdk}"
        source "${PS5_PAYLOAD_SDK}/toolchain/prospero.sh"
        # SDL2 with ps5-opengl's video driver (see native/setup-native.sh)
        pkg_config="${HERE}/../native/native-pkg-config"
        # prospero-lld adds the payload linker script, which a partial link
        # mustn't have
        ld_r="${PS5_PAYLOAD_SDK}/bin/ld.lld"
        flags=(-DRMMZ_PS5_GPU=ON)
        ;;
    host)
        CMAKE=cmake MAKE=make OBJCOPY=objcopy
        pkg_config=pkg-config
        ld_r=ld
        flags=(-DRMMZ_PS5_HOST=ON)
        ;;
    *)
        echo "usage: $0 ps5|host <output dir>" >&2
        exit 2
        ;;
esac

echo "==> Outsider sources"
clone_at https://github.com/General-Arcade/outsider.git "${OUTSIDER_COMMIT}" "${WORK}/outsider"
clone_at https://github.com/jarikomppa/soloud.git "${SOLOUD_COMMIT}" "${WORK}/soloud"
clone_at https://github.com/quickjs-ng/quickjs.git "${QUICKJS_COMMIT}" "${WORK}/quickjs"
clone_at https://github.com/tragicdiscordly-spec/tsukuru-player.git "${TSUKURU_COMMIT}" "${WORK}/tsukuru"

tsukuru_patch="${WORK}/tsukuru/patches/outsider/0001-ps5-port.patch"
echo "${TSUKURU_PATCH_SHA256}  ${tsukuru_patch}" | sha256sum -c -
git -C "${WORK}/outsider" apply "${tsukuru_patch}"
git -C "${WORK}/outsider" apply "${HERE}/outsider-mkxp.patch"

echo "==> QuickJS-NG"
prefix="${WORK}/prefix"
(
    cd "${WORK}/quickjs"
    # The PS5 SDK's math.h trips a warning that -Werror would turn fatal
    sed -i '/xcheck_add_c_compiler_flag(-Werror)/d' CMakeLists.txt
    ${CMAKE} -S . -B build -DCMAKE_BUILD_TYPE=Release \
             -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
             -DBUILD_SHARED_LIBS=OFF -DQJS_BUILD_LIBC=ON -DQJS_BUILD_EXAMPLES=OFF \
             -DCMAKE_INSTALL_PREFIX="${prefix}" > /dev/null
    ${MAKE} -C build -j"$(nproc)" qjs > /dev/null
    # Installs into the prefix only (DESTDIR is the PS5 sysroot otherwise)
    DESTDIR= ${MAKE} -C build install > /dev/null
)

echo "==> Outsider"
build="${WORK}/outsider/build"
${CMAKE} -S "${WORK}/outsider" -B "${build}" -DCMAKE_BUILD_TYPE=Release \
         -DRMMZ_PS5=ON -DRMMZ_PS5_EMBED=ON "${flags[@]}" \
         -DRMMZ_PS5_PREFIX="${prefix}" \
         -DRMMZ_PS5_SDL_CFLAGS="$("${pkg_config}" --cflags sdl2 | xargs | tr ' ' ';')" \
         -DRMMZ_PS5_SOLOUD_DIR="${WORK}/soloud" > /dev/null
${MAKE} -C "${build}" -j"$(nproc)" outsider soloud

# One object out of Outsider, SoLoud and QuickJS-NG, defining nothing but
# outsider_main(), so none of their symbols can clash with mkxp's libraries.
# What they use from SDL2, libc and libc++ stays undefined.
mkdir -p "${OUT}"
"${ld_r}" -r -o "${WORK}/outsider-all.o" --whole-archive \
      "${build}/liboutsider.a" "${build}/libsoloud.a" "${prefix}/lib/libqjs.a"
${OBJCOPY} --keep-global-symbol=outsider_main "${WORK}/outsider-all.o" "${OUT}/outsider.o"

rm -rf "${OUT}/shims"
cp -r "${WORK}/outsider/src/shims" "${OUT}/shims"

echo "==> ${OUT}/outsider.o"
