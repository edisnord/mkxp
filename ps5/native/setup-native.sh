#!/usr/bin/env bash
# Set up the toolchain for the hardware-accelerated native-title build of
# mkxp (see ps5/README.md, "Native title with GPU OpenGL"):
#
#  - ps5-opengl SDK (Mesa on the PS5 GPU, EGL/OpenGL up to 4.6)
#  - ps5-native-app-boilerplate (FSELF tooling and the clean-room libc.prx)
#  - SDL2 with ps5-opengl's EGL video driver, built with audio enabled
#    (upstream's bridge disables SDL audio, which mkxp needs for OpenAL) and
#    allowing GL calls from mkxp's render thread
#
# Everything is pinned and verified. Installs into ${PS5_NATIVE}; SDL is
# installed into the SDK sysroot under /user/native.

set -euo pipefail

: "${PS5_PAYLOAD_SDK:=/opt/ps5-payload-sdk}"
: "${PS5_NATIVE:=/opt/ps5-native}"
: "${SRCDEST:=${HOME}/sources}"
export USE_CCACHE=0

PS5_OPENGL_VERSION=1.0.1
PS5_OPENGL_SDK_SHA256=aaa2e8957f55e1fc0b654dcb35a36e585f7e635d63952da40a28be7f64fde741
PS5_OPENGL_COMMIT=db752da4c89380af228497b5b6852163a4e61069
# The boilerplate revision ps5-opengl ${PS5_OPENGL_VERSION} pins
BOILERPLATE_COMMIT=4f531c4b517f80bcb6b1267135848168d2250047
# The SDL revision ps5-opengl's SDL2 integration pins, and its git archive
SDL_COMMIT=8c56053f13ca13a0c050de613706ff69eb615836
SDL_ARCHIVE_SHA256=9dc445a5add6a6abccbad323d173881fe489ec5fe196c26bc08f127c47f00ee4

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSROOT="${PS5_PAYLOAD_SDK}/target"
SDL_PREFIX=/user/native
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${PS5_NATIVE}" "${SRCDEST}"

# clone_at URL COMMIT DIR
clone_at() {
    git clone -q "$1" "$3"
    git -C "$3" -c advice.detachedHead=false checkout -q "$2"
    [ "$(git -C "$3" rev-parse HEAD)" = "$2" ]
}

echo "==> ps5-opengl SDK ${PS5_OPENGL_VERSION}"
tarball="${SRCDEST}/ps5-opengl-sdk-${PS5_OPENGL_VERSION}.tar.gz"
[ -f "${tarball}" ] || curl -fL --retry 4 -o "${tarball}" \
    "https://github.com/blackbearreloaded/ps5-opengl/releases/download/v${PS5_OPENGL_VERSION}/ps5-opengl-sdk-${PS5_OPENGL_VERSION}.tar.gz"
echo "${PS5_OPENGL_SDK_SHA256}  ${tarball}" | sha256sum -c -
tar xzf "${tarball}" -C "${WORK}"
mv "${WORK}/ps5-opengl-sdk-${PS5_OPENGL_VERSION}/sdk" "${PS5_NATIVE}/gl"
(cd "${PS5_NATIVE}/gl" && sha256sum --check --strict --quiet manifest.sha256)
# The SDK's AGC import stubs, next to the other system stubs
cp "${PS5_NATIVE}/gl/lib/libSceAgc.so" "${PS5_NATIVE}/gl/lib/libSceAgcDriver.so" \
   "${SYSROOT}/lib/"

echo "==> ps5-opengl source (native-app glue, SDL2 video driver)"
clone_at https://github.com/blackbearreloaded/ps5-opengl.git \
         "${PS5_OPENGL_COMMIT}" "${PS5_NATIVE}/ps5-opengl"

echo "==> ps5-native-app-boilerplate"
bp="${PS5_NATIVE}/boilerplate"
clone_at https://github.com/blackbearreloaded/ps5-native-app-boilerplate.git \
         "${BOILERPLATE_COMMIT}" "${bp}"
# Build against the SDK in this image instead of downloading another copy
mkdir -p "${bp}/.deps/native"
ln -s "${PS5_PAYLOAD_SDK}" "${bp}/.deps/native/ps5-payload-sdk"
# Its host tools need zlib; reuse pacbrew's verified download if present
if [ -f "${SRCDEST}/zlib-1.3.2.tar.gz" ]; then
    mkdir -p "${bp}/.deps/native/zlib"
    cp "${SRCDEST}/zlib-1.3.2.tar.gz" "${bp}/.deps/native/zlib/"
fi
make -C "${bp}" libc
# Its scripts run the compiler wrapper through sh; CMake needs it executable
chmod +x "${bp}/tooling/prospero-clang18"
(cd "${bp}/runtime" && sha256sum --check --strict libc.prx.sha256)

echo "==> SDL2 with the ps5-opengl video driver"
sdl_git="${WORK}/SDL.git"
git clone -q --bare https://github.com/ps5-payload-dev/SDL.git "${sdl_git}"
git -C "${sdl_git}" archive "${SDL_COMMIT}" > "${WORK}/sdl.tar"
echo "${SDL_ARCHIVE_SHA256}  ${WORK}/sdl.tar" | sha256sum -c -
mkdir "${WORK}/SDL"
tar xf "${WORK}/sdl.tar" -C "${WORK}/SDL"
lane="${PS5_NATIVE}/ps5-opengl/integration/SDL2"
(
    cd "${WORK}/SDL"
    git init -q .
    git apply "${lane}/static-ps5.patch"
    git apply "${lane}/ps5-joystick.patch"
)
cp -r "${lane}" "${WORK}/lane"
# mkxp renders on its own thread (see the patch)
patch -d "${WORK}/lane" -p3 < "${HERE}/sdl-g19-render-thread.patch"
# Same configuration as upstream's bridge, but keep SDL's audio subsystem
grep -q '^foreach(feature AUDIO RENDER ' "${WORK}/lane/CMakeLists.txt"
sed -i 's/^foreach(feature AUDIO RENDER /foreach(feature RENDER /' \
    "${WORK}/lane/CMakeLists.txt"

PS5_PAYLOAD_SDK="${PS5_PAYLOAD_SDK}" cmake -S "${WORK}/lane" -B "${WORK}/sdl-build" -G Ninja \
    -DSDL_SOURCE="${WORK}/SDL" -DPS5_OPENGL_PREFIX="${PS5_NATIVE}/gl" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_C_COMPILER="${bp}/tooling/prospero-clang18" \
    -DCMAKE_CXX_COMPILER="${bp}/tooling/prospero-clang18" \
    -DCMAKE_INSTALL_PREFIX="${SDL_PREFIX}" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="-D__PROSPERO__ -fPIC -ffunction-sections -fdata-sections"
PS5_PAYLOAD_SDK="${PS5_PAYLOAD_SDK}" cmake --build "${WORK}/sdl-build" --target SDL2-static
DESTDIR="${SYSROOT}" cmake --install "${WORK}/sdl-build"
grep -q '^#define SDL_AUDIO_DRIVER_PS5 1' "${SYSROOT}${SDL_PREFIX}/include/SDL2/SDL_config.h"

# Upstream's sdl2-config/sdl2.m4 don't describe this build (ps5-opengl's
# bridge removes them too)
rm -f "${SYSROOT}${SDL_PREFIX}/bin/sdl2-config" "${SYSROOT}${SDL_PREFIX}/share/aclocal/sdl2.m4"

# A pkg-config file in the sysroot convention of the other libraries.
# OpenGL itself is linked by native-link.sh.
cat > "${SYSROOT}${SDL_PREFIX}/lib/pkgconfig/sdl2.pc" <<EOF
prefix=${SDL_PREFIX}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: sdl2
Description: SDL2 with the ps5-opengl EGL video driver
Version: 2.30.12
Cflags: -I\${includedir} -I\${includedir}/SDL2 -DSDL_MAIN_HANDLED=1
Libs: -L\${libdir} -lSDL2
Libs.private: -lScePad -lSceUserService -lSceSystemService -lSceAudioOut
EOF

echo "==> native toolchain ready in ${PS5_NATIVE}"
